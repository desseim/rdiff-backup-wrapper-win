<#
.SYNOPSIS
Gets the letter of a drive.

.DESCRIPTION
Returns the `DriveLetter` property of a Win32 volume.

.PARAMETER Guid
The GUID of the volume to get the letter of.
This GUID is assigned dynamically at mount time and shouldn't be confused with the partition GPT GUID.

.PARAMETER Label
The label of the volume to get the letter of.
#>
function Get-DriveLetter {
    param (
        [Parameter(Mandatory,
            ParameterSetName="Guid")]
        [ValidateNotNullOrEmpty()]
        [String]$Guid,

        [Parameter(Mandatory,
            ParameterSetName="Label")]
        [ValidateNotNullOrEmpty()]
        [String]$Label
    )

    begin {
        if ($Guid) {
            $DeviceId = "\\?\Volume{${Guid}}\"
            $Filter = "DeviceId=""$(${DeviceId}.Replace('\','\\'))"""
        } elseif ($Label) {
            $Filter = "Label=""${Label}"""
        }
    }
    
    process {
        $DeviceDriveLetter = Get-WmiObject -Class win32_volume -Filter "${Filter}" | select -ExpandProperty "DriveLetter"

        return ${DeviceDriveLetter}
    }
}

<#
.SYNOPSIS
Determines whether a drive exists.

.DESCRIPTION
Determines whether a given Win32 volume exists by returning $true if it does and $false otherwise.

.PARAMETER Letter
The letter of the volume to determine the existence of.
It must be a full valid Win32 volume `DriveLetter` value ; for example, 'C:' is a valid drive letter but 'C' isn't.

.PARAMETER Label
The label of the volume to determine the existence of.
#>
function Test-Drive {
    param (
        [Parameter(Mandatory,
            ParameterSetName="Letter")]
        [ValidatePattern(":$")]  # so as to ensure we don't test the invalid letter (e.g. 'C') of an existing drive
        [String]$Letter,

        [Parameter(Mandatory,
            ParameterSetName="Label")]
        [ValidateNotNullOrEmpty()]
        [String]$Label
    )

    begin {
        if ($Letter) {
            $Filter = "DriveLetter=""${Letter}"""
        } elseif ($Label) {
            $Filter = "Label=""${Label}"""
        }
    }
    
    process {
        $Device = Get-WmiObject -Class win32_volume -Filter "${Filter}"

        return (${Device} -ne $null)
    }
}
