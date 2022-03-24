Set-Variable -Option Constant -Scope Script -Name SCRIPT_SEND_SIGNAL -Value {
    param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$SignalName,

    [int]$WaitSeconds
    )

    Start-Sleep -Seconds $WaitSeconds
    waitfor /si "${SignalName}"
}

<#
.SYNOPSIS
Mock implementation of drive mounting/dismounting.

.DESCRIPTION
Asynchronously sends the given signal after the given time has passed.
No other work is performed.

.NOTES
This function returns immediately as the signal is sent asynchronously.
#>
function Mock-DriveMountDismount {
    param(
    [Parameter(Mandatory)]
    [ValidateLength(1,225)]
    [string]$SignalName,

    [int]$WaitSeconds = 5
    )

    Start-Job -ScriptBlock $SCRIPT_SEND_SIGNAL -ArgumentList "$SignalName", $WaitSeconds | Out-Null
}

<#
.SYNOPSIS
Mounts a given drive.

.DESCRIPTION
Asynchronously mounts a drive designated by an ID, and assign it a given label once mounted.

.NOTES
The function starts the mount procedure asynchronously and returns immediately.
The caller is notified of the completion of the mount procedure through a signal mechanism.
The signal can be listened to with `waitfor` ; see `waitfor` documentation for details.

.PARAMETER DriveId
The ID of the drive to mount.

.PARAMETER MountedDriveLabel
An arbitrary label to assign to the drive once opened/connected and mounted.
It shouldn't be longer than 32 or 11 characters for a drive hosting respectively an NTFS file system or an (ex)FAT file system.

.PARAMETER DriveMountedSignalName
The name of the signal sent to `waitfor` once the drive is mounted.
Must be a valid signal name as defined by `waitfor`, i.e. be <= 225 character long and only include [a-z][A-Z][0-9] or characters between EASCII codes 128 and 255 (if not, the behavior is undefined).

.EXAMPLE
PS> Mount-Drive -DriveId "ID000" -MountedDriveLabel "custom_label" -DriveMountedSignalName "customsignal0"
PS> waitfor /t 30 "customsignal0"
SUCCESS: Signal received.
PS> $?
True

.EXAMPLE
PS> Mount-Drive -DriveId "ID001" -MountedDriveLabel "custom_label" -DriveMountedSignalName "customsignal1"
PS> waitfor /t 30 "customsignal1"
ERROR: Timed out waiting for 'customsignal1'.
PS> $?
False
#>
function Mount-Drive {
    param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DriveId,

    [Parameter(Mandatory)]
    [ValidateLength(1,32)]
    [string]$MountedDriveLabel,

    [Parameter(Mandatory)]
    [ValidateLength(1,225)]
    [string]$DriveMountedSignalName
    )

    #TODO Implement the actual drive mounting.

    Mock-DriveMountDismount "$DriveMountedSignalName"
}

<#
.SYNOPSIS
Dismounts a drive.

.DESCRIPTION
Asynchronously dismounts a mounted drive.

.NOTES
The function starts the dismount procedure asynchronously and returns immediately.
The caller is notified of the completion of the dismount procedure through a signal mechanism.
The signal can be listened to with `waitfor` ; see `waitfor` documentation for details.

.PARAMETER DriveLetter
The letter assigned to the drive to dismount.
It can optionally include the ':' or ':\' suffixes (i.e. "C", "C:" and "C:\" are all accepted).

.PARAMETER DriveDismountedSignalName
The name of the signal sent to `waitfor` once the drive is dismounted.
Must be a valid signal name as defined by `waitfor`, i.e. be <= 225 character long and only include [a-z][A-Z][0-9] or characters between EASCII codes 128 and 255 (if not, the behavior is undefined).

.EXAMPLE
PS> Dismount-Drive -DriveLetter "C" -DriveDismountedSignalName "customsignal0"
PS> waitfor /t 30 "customsignal0"
SUCCESS: Signal received.
PS> $?
True

.EXAMPLE
PS> Dismount-Drive -DriveLetter "Z" -DriveDismountedSignalName "customsignal1"
PS> waitfor /t 30 "customsignal1"
ERROR: Timed out waiting for 'customsignal1'.
PS> $?
False
#>
function Dismount-Drive {
    param (
    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$DriveLetter,

    [Parameter(Mandatory)]
    [ValidateLength(1,225)]
    [string]$DriveDismountedSignalName
    )

    #TODO Implement the actual drive dismounting.

    Mock-DriveMountDismount "$DriveDismountedSignalName"
}
