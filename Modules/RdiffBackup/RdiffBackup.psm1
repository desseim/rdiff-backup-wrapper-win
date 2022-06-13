Set-Variable -Option Constant -Name RDIFFBACKUP_DATA_DIRECTORY_RELATIVE_PATH -Value "rdiff-backup-data"

# The type of API the `rdiff-backup` executable can be called with (cf. <https://github.com/rdiff-backup/rdiff-backup/blob/v2.1.0a1/docs/migration.md#migration-from-old-to-new-cli>)
enum RdiffBackupExeApi { OldAPI ; NewAPI }
# The OS environment of a given `rdiff-backup` executable instance
enum RdiffBackupExeEnv { Win ; WSL }

class RdiffBackupExe {
    [ValidateNotNullOrEmpty()]
    [String]$Executable
    [String[]]$FirstParameters
    [switch]$AlwaysForce
    [ValidateNotNull()]
    [RdiffBackupExeApi]$Api
    [ValidateNotNull()]
    [RdiffBackupExeEnv]$Environment

    # Constructor helpers (<https://stackoverflow.com/a/44414513>)
    hidden Init ([String]$e, [String[]]$fp, [switch]$af, [RdiffBackupExeApi]$a, [RDiffBackupExeEnv]$env) {
        $this.Executable = $e
        $this.FirstParameters = $fp
        $this.AlwaysForce = $af
        $this.Api = $a
        $this.Environment = $env
    }
    hidden Init ([String]$e, [String[]]$fp, [RdiffBackupExeApi]$a, [RDiffBackupExeEnv]$env) {
        $this.Init($e, $fp, $false, $a, $env)
    }
    hidden Init ([String]$e, [RdiffBackupExeApi]$a, [RdiffBackupExeEnv]$env) {
        $this.Init($e, @(), $a, $env)
    }

    # Constructors
    RdiffBackupExe ([String]$e, [String[]]$fp, [switch]$af, [RdiffBackupExeApi]$a, [RdiffBackupExeEnv]$env) { $this.Init($e, $fp, $af, $a, $env) }
    RdiffBackupExe ([String]$e, [String[]]$fp, [RdiffBackupExeApi]$a, [RdiffBackupExeEnv]$env)              { $this.Init($e, $fp, $a, $env) }
    RdiffBackupExe ([String]$e, [RdiffBackupExeApi]$a, [RdiffBackupExeEnv]$env)                             { $this.Init($e, $a, $env) }
}

# A dictionary holding all available `rdiff-backup` executables with their version name as keys
$RdiffBackupExes = @{
    # pre-v2.1.x often balks after a failed backup, as sometimes after a failed backup it can't assert whether the old running rdiff-backup process has terminated or is still running on the repository (even when it isn't, which should usually be the case), so we always use `--force ` :/
    v200     = [RdiffBackupExe]::new("${env:ProgramFiles(x86)}\rdiff-backup-2.0.0\rdiff-backup.exe", @(), $true, [RdiffBackupExeApi]::OldApi, [RDiffBackupExeEnv]::Win)
    v205     = [RdiffBackupExe]::new("${env:ProgramFiles(x86)}\rdiff-backup-2.0.5\rdiff-backup.exe", @(), $true, [RdiffBackupExeApi]::OldApi, [RDiffBackupExeEnv]::Win)

    v200_WSL = [RdiffBackupExe]::new('wsl', @('rdiff-backup'), [RdiffBackupExeApi]::OldApi, [RdiffBackupExeEnv]::WSL)
    v210a1   = [RdiffBackupExe]::new("${env:ProgramFiles}\rdiff-backup\rdiff-backup.exe", [RdiffBackupExeApi]::NewAPI, [RdiffBackupExeEnv]::Win)
}
Export-ModuleMember -Variable RdiffBackupExes

Set-Variable -Option Constant -Name DEFAULT_RDIFFBACKUPEXE -Value $RdiffBackupExes.v210a1


<#
.SYNOPSIS
Calls `rdiff-backup`.

.DESCRIPTION
Calls a given instance of the `rdiff-backup` executable.

.NOTES
Certain options are set automatically or sometimes overridden according to the `rdiff-backup` executable they will be passed to.
Force example, `:` characters in filenames are not translated well onto Windows file systems by WSL, so the `UseCompatibleTimestamps` switch is forcibly enabled for `rdiff-backup` executables which execute under WSL to increase backup compatibility with executables running under Windows or Linux.

.PARAMETER Backup
`rdiff-backup`'s `backup` option ; performs a backup.

.PARAMETER Remove
`rdiff-backup`'s `remove increments --older-than` option ; removes increments older than a given time period.
It automatically removes all matching increments (contrary to `rdiff-backup` which outputs a message and quits when there are more than one matching increment).

.PARAMETER Verify
`rdiff-backup`'s `verify` option ; checks the integrity of the last backup.

.PARAMETER IncludeGlobbingFilelist
Parameter to `rdiff-backup` `--include-globbing-filelist` option ; a file which defines include/exclude directive for the backup.

.PARAMETER Source
The path of the directory to backup.

.PARAMETER OlderThan
All backups older than this time period will be removed.
It must be formatted as the `time_spec` argument to `rdiff-backup`'s `--remove-older-than` option, i.e. an absolute (e.g. '1788-06-21' or 'w3-datetime strings') or relative (e.g. '1W3D8h') time, or a number of backup increments (e.g. '3B').
See `rdiff-backup` documentation for format details.

.PARAMETER Destination
The backup destination directory, where backup files and increments are / will be stored.

.PARAMETER Force
`rdiff-backup`'s `--force` option ; force it to take action.
It is always enabled when removing backups, as otherwise nothing would happen unless only one backup would match the removal criteria.

.PARAMETER UseCompatibleTimestamps
`rdiff-backup`'s `--usecompatibletimestamps` option ; will use `-` characters in filenames instead of default `:` character to increase file system and OS compatibility.

.PARAMETER VerboseLevel
Parameter to `rdiff-backup`'s `-v` option ; choose a level of verbosity for `rdiff-backup`'s execution.

.PARAMETER Exe
The `rdiff-backup` executable to call.

.EXAMPLE
PS> Invoke-RdiffBackup -Remove -OlderThan '40Y' -Destination "${DestPath}" -Exe $RdiffBackupExes['v205']
No increments older than Tue Jan 01 12:00:30 1980 found, exiting.
#>
function Invoke-RdiffBackup {
    [OutputType([int])]
    param (
        [Parameter(ParameterSetName = 'Backup', Mandatory)]
        [switch]$Backup,
        [Parameter(ParameterSetName = 'Backup')]
        [string]$IncludeGlobbingFilelist,
        [Parameter(ParameterSetName = 'Backup', Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Source,

        [Parameter(ParameterSetName = 'Remove', Mandatory)]
        [switch]$Remove,
        [Parameter(ParameterSetName = 'Remove', Mandatory)]  # mandatory for now as we support no other `remove` option
        [ValidateNotNullOrEmpty()]
        [string]$OlderThan,

        [Parameter(ParameterSetName = 'Verify', Mandatory)]
        [switch]$Verify,

        [Parameter(Mandatory)]  # required for all parameter sets
        [ValidateNotNullOrEmpty()]
        [string]$Destination,

        [switch]$Force,
        [switch]$UseCompatibleTimestamps,
        [ValidateRange(1,9)][int]$VerboseLevel,

        [ValidateNotNull()]
        [RdiffBackupExe]$Exe = $DEFAULT_RDIFFBACKUPEXE
    )

    begin {
        if ($Exe.AlwaysForce) { $Force = $true }
        if ($Remove) { $Force = $true }  # we always use `force` to `remove` older backups otherwise nothing happens when there is more than one to remove
        if ($Exe.Environment -eq [RdiffBackupExeEnv]::WSL) { $UseCompatibleTimestamps = $true }  # Under WSL, filenames containing a `:` character are translated to and from the `U+F03A` PUA Unicode character on the file system, creating non-valid backups (as their files are named incorrectly) which would only work under WSL, so we better force the use of `-` in filenames instead of `:` with this option
    }

    process {
        $CmdArgs = @()
        if ($VerboseLevel) { $CmdArgs += "-v${VerboseLevel}" }
        if ($Force) { $CmdArgs += '--force' }
        if ($UseCompatibleTimestamps) { $CmdArgs += '--use-compatible-timestamps' }
        if ($Backup) {
            if ($Exe.Api -eq [RdiffBackupExeApi]::NewApi) { $CmdArgs += @('backup') }
            if ($Exe.Environment -eq [RdiffBackupExeEnv]::Win) {
                # A few tweaks only necessary when running under Windows
                $CmdArgs += '--exclude-symbolic-links'  # automatically enabled by `rdiff-backup` on Windows, however [a bug](<https://github.com/rdiff-backup/rdiff-backup/issues/608>) in the argument order forces us to pass it explicitly so that it appears before any other include/exclude argument ; this line can be deleted for rdiff-backup exe versions where this bug is fixed
                $CmdArgs += '--no-acls'  # seems necessary to avoid "Ace Type 9 is not supported yet" error under Windows (cf. <https://www.backupcentral.com/forum/17/292720/exception_ace_type_9_is_not_supported_yet>)
            }
            if ($IncludeGlobbingFilelist) { $CmdArgs += @('--include-globbing-filelist', "${IncludeGlobbingFileList}") }
            $CmdArgs += "${Source}"
        } elseif ($Remove) {
            switch ($Exe.Api) {
                NewAPI { $CmdArgs += @('remove', 'increments', '--older-than') }
                OldAPI { $CmdArgs += @('--remove-older-than') }
            }
            $CmdArgs += "${OlderThan}"
        } elseif ($Verify) {
            switch ($Exe.Api) {
                NewApi { $CmdArgs += 'verify' }
                OldApi { $CmdArgs += '--verify' }
            }
        } else {
            throw (New-Object System.ArgumentException -ArgumentList "Method invoked without a command parameter")
        }
        $CmdArgs += "${Destination}"

        & $Exe.Executable $Exe.FirstParameters ${CmdArgs} | Out-Default  # be sure to not let the output of the native command "pollute" the return value of this function (<https://docs.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_return>)
        $CmdRes = $LASTEXITCODE

        return $CmdRes
    }
}

<#
.DESCRIPTION
Test whether a given path is that of an existing `rdiff-backup` backup destination.
#>
function Test-RdiffBackupDirectory {
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$TestPath
    )

    $TestPathRBDataDir = Join-Path -Path $TestPath -ChildPath $RDIFFBACKUP_DATA_DIRECTORY_RELATIVE_PATH
    return (Test-Path -Path $TestPathRBDataDir -PathType Container)
}
