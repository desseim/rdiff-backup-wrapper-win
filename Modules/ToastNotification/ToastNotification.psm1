Set-Variable -Option Constant -Scope Script -Name NOTIFICATION_TASK_NAME_PREFIX -Value "toast_notification"
Set-Variable -Option Constant -Scope Script -Name NOTIFICATION_TASK_PATH -Value "\ToastNotification"
Set-Variable -Option Constant -Scope Script -Name NOTIFICATION_TASK_DESCRIPTION -Value "Temporary task to show a toast notification to the currently logged in user. Should be automatically deleted once run."
Set-Variable -Option Constant -Scope Script -Name POWERSHELL_APP_ID -Value "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe"  # found with `Get-StartApps -Name`


<#
.Description
Returns the name of the user currently logged in, or $null if no user is currently logged in.
#>
function Get-LoggedinUser {
    return (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
}

<#
.SYNOPSIS
Doubles all instances of a character in a string.

.Description
Particularly useful to escape quoting characters the string will be enclosed by, by doubling them.
This might be necessary e.g. when the string will be passed down to another shell to be later interpreted.

.PARAMETER Character
The character to double.

.PARAMETER Text
The string within which to double all instances of $Character.

.EXAMPLE
PS> $Txt
a "quoted" text
PS> """$Txt"""
"a "quoted" text"
PS> """$(Format-DoubleCharacter($Txt)"""
"a ""quoted"" text"
#>
function Format-DoubleCharacter {
    param (
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [char]$Character,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$Text
    )

    return $Text -replace ${Character}, "$&$&"
}

function New-NotificationTask {
    param (
        [Parameter(Mandatory)]
        [String]$Title,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$Message,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$AppId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$User
    )

    Set-Variable -Option Constant -Name CMD_ARG_QUOTE -Value '"'

    $TitleEscaped = Format-DoubleCharacter -Character "${CMD_ARG_QUOTE}" -Text "${Title}"
    $MessageEscaped = Format-DoubleCharacter -Character "${CMD_ARG_QUOTE}" -Text "${Message}"

    $NotificationTaskExe = "powershell.exe"
    $NotificationTaskExeArg = "-NoLogo -NonInteractive -WindowStyle Hidden -ExecutionPolicy RemoteSigned"
    $NotificationTaskExeCmd = @"
Import-Module ${PSCommandPath} ; Show-NotificationToast -Title ${CMD_ARG_QUOTE}${TitleEscaped}${CMD_ARG_QUOTE} -Message ${CMD_ARG_QUOTE}${MessageEscaped}${CMD_ARG_QUOTE} -AppId "${AppId}"
"@
    $NotificationTaskExeCmdEncoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($NotificationTaskExeCmd))
    $NotificationTaskAction = New-ScheduledTaskAction -Execute $NotificationTaskExe -Argument "${NotificationTaskExeArg} -EncodedCommand ${NotificationTaskExeCmdEncoded}"

    $NotificationTaskPrincipal = New-ScheduledTaskPrincipal -UserId $User

    $NotificationTask = New-ScheduledTask -Action $NotificationTaskAction -Principal $NotificationTaskPrincipal -Description $NOTIFICATION_TASK_DESCRIPTION

    return $NotificationTask
}

function New-NotificationTaskName {
    param ([String]$Prefix)

    if (![String]::IsNullOrEmpty($Prefix)) {
        $TaskName = "${Prefix}-"
    }

    $Guid = New-Guid
    $TaskName += "${Guid}"

    return $TaskName
}

function Show-NotificationTask {
    param (
        [Parameter(Mandatory)]
        [Microsoft.Management.Infrastructure.CimInstance]$NotificationTask,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$NotificationTaskName,

        [String]$NotificationTaskPath
    )

    $ScheduledTask = $null
    try {
        $ScheduledTask = Register-ScheduledTask -InputObject $NotificationTask -TaskName $NotificationTaskName -TaskPath $NotificationTaskPath
        Start-ScheduledTask -InputObject $ScheduledTask
    } finally {
        if ($ScheduledTask) {
            Unregister-ScheduledTask -InputObject $ScheduledTask -Confirm:$false
        }
    }
}

function Show-Notification {
    param (
        [Parameter(Mandatory)]
        [String]$Title,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$Message,

        [ValidateNotNullOrEmpty()]
        [String]$AppId = $POWERSHELL_APP_ID,
        
        [ValidateNotNullOrEmpty()]
        [String]$User
    )

    $NotificationTask = New-NotificationTask -Title $Title -Message $Message -AppId $AppId -User $User

    $NotificationTaskName = New-NotificationTaskName -Prefix $NOTIFICATION_TASK_NAME_PREFIX

    Show-NotificationTask -NotificationTask $NotificationTask -NotificationTaskName $NotificationTaskName -NotificationTaskPath $NOTIFICATION_TASK_PATH
}

<#
.Description
Displays a notification to the user currently logged in, if any.
If none, a warning with the notification title and message is logged.
#>
function Show-NotificationToLoggedInUser {
    param (
        [Parameter(Mandatory)]
        [String]$Title,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$Message,

        [ValidateNotNullOrEmpty()]
        [String]$AppId = $POWERSHELL_APP_ID
    )

    $LoggedInUser = Get-LoggedinUser
    if ($LoggedInUser) {
        Show-Notification -Title $Title -Message $Message -AppId $AppId -User $LoggedInUser
    } else {
        Write-Warning "The following user notification was not shown since there is currently no logged-in user ; <Title>: ""$Title"" <Message>: ""$Message"""
    }
}

function Show-NotificationToast {
    param (
        [Parameter(Mandatory)]
        [String]$Title,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [String]$Message,

        [ValidateNotNullOrEmpty()]
        [String]$AppId
    )

    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

    $ToastXml = @"
<toast>
  <visual>
    <binding template="ToastText02">
      <text id="1">$Title</text>
      <text id="2">$Message</text>
    </binding>
  </visual>
</toast>
"@

    $ToastXmlDoc = New-Object -TypeName Windows.Data.Xml.Dom.XmlDocument
    $ToastXmlDoc.LoadXml($ToastXml)
    $Toast = New-Object -TypeName Windows.UI.Notifications.ToastNotification -ArgumentList $ToastXmlDoc
    $ToastNotifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($AppId)
    $ToastNotifier.Show($Toast)
}
