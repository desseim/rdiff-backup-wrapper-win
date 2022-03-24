﻿using module "Modules\RdiffBackup"

param (
    [Parameter(Mandatory,
    HelpMessage="General label (name) to give to this backup")]
    [ValidateNotNullOrEmpty()]
    [string]$BackupLabel,

    [Parameter(Mandatory,
    HelpMessage="Absolute path to the source directory to backup")]
    [ValidateNotNullOrEmpty()]
    [string]$SrcFullPath,

    [Parameter(Mandatory,
    HelpMessage="The ID of the backup destination drive")]
    [ValidateNotNullOrEmpty()]
    [string]$DestDriveId,

    [Parameter(Mandatory,
    HelpMessage="An arbitrary (but unique) label to give the backup destination drive once opened and mounted ; shouldn't be longer than 32 or 11 characters for a drive hosting respectively an NTFS file system or an (ex)FAT file system")]
    [ValidateLength(1,32)]
    [string]$DestDriveLabel,

    [Parameter(Mandatory,
    HelpMessage="The path to the backup destination directory, relative to the destination drive root (e.g. '/' or '/path/to/backup_dir')")]
    [ValidateNotNullOrEmpty()]
    [string]$DestPath,

    [Parameter(HelpMessage="If present, forces the use of `-` characters instead of `:` in backup data filenames ; if absent, this will be automatically decided based on the environment")]
    [switch]$UseCompatibleTimestamps,

    [Parameter(HelpMessage="Absolute path of a file containing a list of include/exclude directives for the backup command")]
    [ValidateNotNullOrEmpty()]
    [string]$IncludeExcludeListFile,

    [Parameter(HelpMessage="All previous backups older than this value will be deleted (e.g. '1M' will delete all backups performed more than a month ago) ; see <https://duplicity.readthedocs.io/en/latest/_modules/duplicity/dup_time.html#genstrtotime> for acceptable time formats")]
    [ValidateNotNullOrEmpty()]
    [string]$RemoveOlderThan = '3M',

    [Parameter(HelpMessage="The version code of the `rdiff-backup` executable to execute")]
    [ValidateNotNullOrEmpty()]
    [string]$RdiffBackupVer = 'v205',

    [Parameter(HelpMessage="The version code of the `rdiff-backup` executable to use to remove old backups ; leave empty to use the same executable as for backups, or specify a given version when necessary")]
    [ValidateNotNullOrEmpty()]
    [string]$RdiffBackupRemoveVer = $RdiffBackupVer
)

Set-Variable -Option Constant -Name RDIFFBACKUP_EXITCODE_SUCCESS -Value 0
Set-Variable -Option Constant -Name ERROR_NOTIFICATION_RECOMMENDED_ACTION -Value "You can check the job result with 'Get-Job' and 'Receive-Job -Keep -Id', or check the scheduled job's output xml file"

### WSL mount options
# Backup source mount options are determined by `/etc/wsl.conf` and applied during automount at WSL startup
# Backup destination mount options:
Set-Variable -Option Constant -Name DEST_WSL_MOUNT_POINT_PREFIX -Value '/mnt/backup'
Set-Variable -Option Constant -Name DEST_WSL_MOUNT_UID -Value 1000  # needs to be the user under which `wsl` commands will run otherwise `rdiff-backup` may error when it tries to `chmod` backup files
Set-Variable -Option Constant -Name DEST_WSL_MOUNT_GID -Value 1000
Set-Variable -Option Constant -Name DEST_WSL_MOUNT_DMASK -Value 007
Set-Variable -Option Constant -Name DEST_WSL_MOUNT_FMASK -Value 117

### Modules
Set-Variable -Option Constant -Name MODULES_IMPORT_PREFIX -Value "RB"  # calls to module functions in this script will have to be renamed manually if this value is changed
Set-Variable -Option Constant -Name MODULES_REL_PATH -Value "Modules"
Set-Variable -Option Constant -Name MODULES_ABS_PATH -Value (Join-Path "${PSScriptRoot}" -ChildPath "${MODULES_REL_PATH}")

# Toast notification module
Set-Variable -Option Constant -Name MODULE_TOAST_NOTIFICATION_NAME -Value "ToastNotification"
Set-Variable -Option Constant -Name MODULE_TOAST_NOTIFICATION_PATH -Value (Join-Path -Path ${MODULES_ABS_PATH} -ChildPath ${MODULE_TOAST_NOTIFICATION_NAME})
Import-Module ${MODULE_TOAST_NOTIFICATION_PATH} -Prefix "${MODULES_IMPORT_PREFIX}"

Set-Variable -Option Constant -Name NOTIFICATION_APP_ID -Value "rdiff-backup"  # value seems stored at reg entry `Computer\HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Notifications\Settings`

# Drive mounting module
Set-Variable -Option Constant -Name MODULE_DRIVE_MOUNT_NAME -Value "DriveMount"
Set-Variable -Option Constant -Name MODULE_DRIVE_MOUNT_PATH -Value (Join-Path -Path ${MODULES_ABS_PATH} -ChildPath ${MODULE_DRIVE_MOUNT_NAME})
Import-Module ${MODULE_DRIVE_MOUNT_PATH} -Prefix "${MODULES_IMPORT_PREFIX}"

Set-Variable -Option Constant -Name DEST_MOUNT_TIMEOUT_SEC -Value 60
Set-Variable -Option Constant -Name SIGNAL_NAME_UNIQUE_SUFFIX -Value (New-Guid).ToString("N")  # only one instance of `waitfor` can wait for a same signal on a same computer at the same time, so we need to make the signal name unique to this script instance in case several script instances run at the same time
Set-Variable -Option Constant -Name DEST_MOUNT_SIGNAL_NAME -Value "RdiffBackupDestMounted${SIGNAL_NAME_UNIQUE_SUFFIX}"
Set-Variable -Option Constant -Name DEST_DISMOUNT_SIGNAL_NAME -Value "RdiffBackupDestDismounted${SIGNAL_NAME_UNIQUE_SUFFIX}"

# Drive management module
Set-Variable -Option Constant -Name MODULE_DRIVE_MANAGEMENT_NAME -Value "DriveManagement"
Set-Variable -Option Constant -Name MODULE_DRIVE_MANAGEMENT_PATH -Value (Join-Path -Path ${MODULES_ABS_PATH} -ChildPath ${MODULE_DRIVE_MANAGEMENT_NAME})
Import-Module ${MODULE_DRIVE_MANAGEMENT_PATH} -Prefix "${MODULES_IMPORT_PREFIX}"


try {
    ### Pre-processing

    # Verify destination label uniqueness
    if (Test-RBDrive -Label $DestDriveLabel) {
        throw (New-Object System.ArgumentException -ArgumentList "Drive labeled '${DestDriveLabel}' already exists: aborting backup to avoid overwriting it")
    }

    # Validate executable version code
    if (! $RdiffBackupExes.Contains($RdiffBackupVer)) {
        throw (New-Object System.ArgumentException -ArgumentList "Invalid rdiff-backup executable version ('$RdiffBackupVer') ; should be one of: $($RdiffBackupExes.Keys | ForEach-Object {"'"+$_+"'"})")
    }
    if (! $RdiffBackupExes.Contains($RdiffBackupRemoveVer)) {
        throw (New-Object System.ArgumentException -ArgumentList "Invalid rdiff-backup executable version for backup removal ('$RdiffBackupRemoveVer') ; should be one of: $($RdiffBackupExes.Keys | ForEach-Object {"'"+$_+"'"})")
    }

    ### Main

    $RdiffBackupExe = $RdiffBackupExes[$RdiffBackupVer]
    $RdiffBackupRemoveExe = $RdiffBackupExes[$RdiffBackupRemoveVer]

    #-- Mount destination disk

    Mount-RBDrive -DriveId "${DestDriveId}" -MountedDriveLabel "${DestDriveLabel}" -DriveMountedSignalName "${DEST_MOUNT_SIGNAL_NAME}"

    waitfor /t ${DEST_MOUNT_TIMEOUT_SEC} "${DEST_MOUNT_SIGNAL_NAME}"
    $MountSignalReceived = $?

    if (!$MountSignalReceived) {
        # the wait for the mount command exit signal timed out
        throw (New-Object System.TimeoutException -ArgumentList "Timed out waiting for mount signal of drive of ID '${DestDriveId}' ; '${BackupLabel}' backup aborted.")
    }
    
    #-- Prepare backup paths

    $DestDriveLetter = Get-RBDriveLetter -Label ${DestDriveLabel}
    $DestFullPath = $null         # the destination path in a format suitable to the `rdiff-backup` executable
    $DestFullWindowsPath = $null  # the destination path in a format suitable to Windows and PowerShell scripts
    $WslMountPointPreexisted = $true  # safest as a default choice: if `$true` the mount point directory will be ignored during cleanup
    if ($RdiffBackupExe.Environment -eq [RdiffBackupExeEnv]::Win) {
        $DestFullPath = "${DestDriveLetter}${DestPath}"

        $DestFullWindowsPath = "${DestFullPath}"
    } elseif ($RdiffBackupExe.Environment -eq [RdiffBackupExeEnv]::WSL) {  # if we run from WSL, we (assume we) need to mount the drive within WSL (to a WSL path)
        # Create WSL mount point
        $WslMountPoint = "${DEST_WSL_MOUNT_POINT_PREFIX}/${DestDriveLabel}"

        & wsl test -e "${WslMountPoint}"
        $WslMountPointPreexisted = ! $LASTEXITCODE  # logic inverted with linux return value (`0` == `True`)
        if ($WslMountPointPreexisted) {
            # if it exists, make sure it is a directory
            & wsl test -d "${WslMountPoint}"
            $WslMountPointIsDirectory = ! $LASTEXITCODE
            if (! $WslMountPointIsDirectory) { throw (New-Object System.IO.DirectoryNotFoundException -ArgumentList "WSL mount point '${WslMountPoint}' exists but is not a directory ; cannot proceed further.") }
        }

        & wsl mkdir -p "${WslMountPoint}"
        $WslMountPointMkdirRes = $LASTEXITCODE
        if ($WslMountPointMkdirRes -ne 0) { throw (New-Object System.IO.IOException -ArgumentList "Failed to create directory '${WslMountPoint}' in WSL: `mkdir` returned '${WslMountPointMkdirRes}' ; cannot proceed further.") }

        # Mount drive in WSL
        & wsl sudo mount -t drvfs "${DestDriveLetter}" "${WslMountPoint}" -o "uid=${DEST_WSL_MOUNT_UID},gid=${DEST_WSL_MOUNT_GID},dmask=${DEST_WSL_MOUNT_DMASK},fmask=${DEST_WSL_MOUNT_FMASK}"
        $WslMountRes = $LASTEXITCODE
        if ($WslMountRes -ne 0) { throw (New-Object System.IO.IOException -ArgumentList "Error mounting destination drive in WSL: `mount` returned '${WslMountRes}' ; cannot proceed further.") }

        $DestFullPath = "${WslMountPoint}${DestPath}"

        $DestFullWindowsPath = & wsl wslpath -w "${DestFullPath}"  # result will be `$null` if the path in `$DestFullPath` doesn't exist

        # Also convert source paths as they come in Windows path format:
        $SrcFullPath = & wsl wslpath -u "${SrcFullPath}"
        $ConvertSrcPathRes = $LASTEXITCODE
        if ($ConvertSrcPathRes -ne 0) { throw (New-Object System.IO.DirectoryNotFoundException -ArgumentList "Error converting source path '${SrcFullPath}' to a WSL path: `wslpath` returned '${ConvertSrcPathRes}' ; '${BackupLabel}' backup aborted.") }

        $IncludeExcludeListFile = & wsl wslpath -u "${IncludeExcludeListFile}"
        $ConvertIncludeListFileRes = $LASTEXITCODE
        if ($ConvertIncludeListFileRes -ne 0) { throw (New-Object System.IO.FileNotFoundException -ArgumentList "Error converting include/exclude file path '${IncludeExcludeListFile}' to a WSL path: `wslpath` returned '${ConvertIncludeListFileRes}' ; '${BackupLabel}' backup aborted.") }
    } else {
        throw (New-Object System.ComponentModel.InvalidEnumArgumentException -ArgumentList "Unknown environment for rdiff-backup executable: '$($RdiffBackupExe.Environment)' ; cannot proceed further.")
    }

    if (!(Test-Path -Path "${DestFullWindowsPath}" -PathType Container)) {
        throw (New-Object System.IO.DirectoryNotFoundException -ArgumentList "Destination path '${DestFullWindowsPath}' not found or not a directory ; '${BackupLabel}' backup aborted.")
    }

    #-- Backup

    # Delete older backups
    $DestIsRBBackupDir = Test-RdiffBackupDirectory "${DestFullWindowsPath}"
    if ($DestIsRBBackupDir) {  # if not, deleting old backups make no sense and would fail anyway
        $RemoveCmdRes = Invoke-RdiffBackup -Remove -OlderThan "${RemoveOlderThan}" -Destination "${DestFullPath}" -Exe $RdiffBackupRemoveExe
        if ($RemoveCmdRes -ne $RDIFFBACKUP_EXITCODE_SUCCESS) {  # remove failed
            Write-Error -Message "Removal of rdiff-backup increments older than '${RemoveOlderThan}' at '${DestFullPath}' failed: returned '${RemoveCmdRes}'." -Category InvalidResult -CategoryActivity "rdiff-backup remove" -CategoryTargetName "${DestFullPath}" -CategoryTargetType "rdiff-backup increment" -RecommendedAction "Remove or roll back last failed backup manually."
            Show-RBNotificationToLoggedInUser -Title "Removal of older '${BackupLabel}' backups failed" -Message "Removal of '${BackupLabel}' backups returned '${RemoveCmdRes}'`n${ERROR_NOTIFICATION_RECOMMENDED_ACTION}" -AppId "${NOTIFICATION_APP_ID}"
        }
    }

    # Backup current state
    $BackupCmdRes = Invoke-RdiffBackup -Backup -UseCompatibleTimestamps:$UseCompatibleTimestamps -IncludeGlobbingFilelist "${IncludeExcludeListFile}" -Source "${SrcFullPath}" -Destination "${DestFullPath}" -Exe ${RdiffBackupExe}
    if ($BackupCmdRes -ne $RDIFFBACKUP_EXITCODE_SUCCESS) {  # backup failed
        $BackupFailureMessage = "Backup '${BackupLabel}' failed: rdiff-backup returned '${BackupCmdRes}'"

        # We verify the state of the backup repository after the backup failure:
        $VerifyCmdRes = Invoke-RdiffBackup -Verify -Destination "${DestFullPath}" -Exe ${RdiffBackupExe}
        if ($VerifyCmdRes -ne $RDIFFBACKUP_EXITCODE_SUCCESS) {
            throw "${BackupFailureMessage} ; backup repository '${DestFullPath}' is left in inconsistent state."
        } else {
            throw "${BackupFailureMessage} ; backup repository '${DestFullPath}' seems however not to have been corrupted."
        }
    }
} catch {
    # Notify desktop user
    $NotificationTitle = "Error during backup '${BackupLabel}'"
    $ExceptionMessage = $_.Exception.Message
    $NotificationMessage = "${ExceptionMessage}`n${ERROR_NOTIFICATION_RECOMMENDED_ACTION}"
    Show-RBNotificationToLoggedInUser -Title ${NotificationTitle} -Message ${NotificationMessage} -AppId ${NOTIFICATION_APP_ID}

    # rethrow original exception
    throw
} finally {
    #-- Unmount destination and cleanup in WSL

    if ($RdiffBackupExe.Environment -eq [RdiffBackupExeEnv]::WSL) {
        & wsl mountpoint "${WslMountPoint}" | Out-Null
        $WslMountPointIsMounted = ! $LASTEXITCODE

        if ($WslMountPointIsMounted) {
            # Unmount backup destination
            & wsl sudo umount "${WslMountPoint}"
            $WslUnmountRes = $LASTEXITCODE
            if ($WslUnmountRes -ne 0) {
                Write-Error -Message "Error trying to unmount '${WslMountPoint}' in WSL after backup: `umount` result was '${WslUnmountRes}'." -Category CloseError -CategoryActivity "WSL unmount" -CategoryTargetName "${WslMountPoint}" -CategoryTargetType "Mount point" -RecommendedAction "Manually unmount from WSL"
                Show-RBNotificationToLoggedInUser -Title "Backup destination not unmounted in WSL" -Message "Error trying to unmount '${WslMountPoint}' in WSL after backup.`n${ERROR_NOTIFICATION_RECOMMENDED_ACTION}" -AppId "${NOTIFICATION_APP_ID}"
            }

            # Remove the mount point directory (if we created it)
            if (! $WslMountPointPreexisted) {
                & wsl rmdir "${WslMountPoint}"
            }
        }
    }

    #-- Dismount destination disk

    if (${DestDriveLetter} -and (Test-RBDrive -Letter ${DestDriveLetter})) {  # ensure it is valid before trying to dismount it
        Dismount-RBDrive -DriveLetter "${DestDriveLetter}" -DriveDismountedSignalName "${DEST_DISMOUNT_SIGNAL_NAME}"

        waitfor /t ${DEST_MOUNT_TIMEOUT_SEC} "${DEST_DISMOUNT_SIGNAL_NAME}"
        $DismountSignalReceived = $?

        # Dismount error handling
        if (!$DismountSignalReceived) {
            # dismount timed out
            Write-Error -Message "Timed out waiting for drive '${DestDriveLetter}' dismount signal ; drive not dismounted." -Category OperationTimeout -CategoryActivity "Dismount" -CategoryTargetName "${DestDriveLetter}" -CategoryTargetType "Drive" -RecommendedAction "Manually dismount drive"
            Show-RBNotificationToLoggedInUser -Title "Backup drive not dismounted" -Message "The dismount of backup drive '${DestDriveLetter}' timed out.`n${ERROR_NOTIFICATION_RECOMMENDED_ACTION}" -AppId "${NOTIFICATION_APP_ID}"
        } elseif (Test-RBDrive -Label ${DestDriveLabel}) {
            # drive still mounted
            Write-Error -Message "Drive '${DestDriveLetter}' not dismounted after backup." -Category CloseError -CategoryActivity "Dismount" -CategoryTargetName "${DestDriveLetter}" -CategoryTargetType "Drive" -RecommendedAction "Manually dismount drive"
            Show-RBNotificationToLoggedInUser -Title "Backup drive not dismounted" -Message "Backup drive '${DestDriveLetter}' was not dismounted after backup.`n${ERROR_NOTIFICATION_RECOMMENDED_ACTION}" -AppId "${NOTIFICATION_APP_ID}"
        }
    }
}