<#
.SYNOPSIS
    Installs the OpenEndpointEvents Azure Blob uploader and config refresh scheduled tasks.

.DESCRIPTION
    Installs OpenEndpointEvents from PowerShell Gallery if needed, copies the embedded uploader scripts
    from the installed module to C:\ProgramData\OpenEndpointEvents\Scripts, writes config-refresh.json,
    locks down ACLs, and registers scheduled tasks.

.PARAMETER ConfigUri
    HTTPS URL to the protected remote uploader-config.json blob, including read-only SAS.

.PARAMETER UploadIntervalMinutes
    Upload scheduled task interval. Default: 60.

.PARAMETER ConfigRefreshIntervalHours
    Config refresh scheduled task interval. Default: 6.

.PARAMETER StartNow
    Refreshes config and starts upload immediately after installation.

.PARAMETER Force
    Overwrites existing local scripts and config-refresh.json.

.EXAMPLE
    .\Install-OpenEndpointEventsUploader.ps1 `
        -ConfigUri "https://storage.blob.core.windows.net/open-endpoint-events-config/uploader-config.json?<read-sas>" `
        -StartNow
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigUri,

    [int]$UploadIntervalMinutes = 60,

    [int]$ConfigRefreshIntervalHours = 6,

    [switch]$StartNow,

    [switch]$Force
)

$ErrorActionPreference = "Stop"

$BaseRoot = "C:\ProgramData\OpenEndpointEvents"
$LogRoot = Join-Path $BaseRoot "Logs"
$ConfigRoot = Join-Path $BaseRoot "Config"
$StateRoot = Join-Path $BaseRoot "State"
$ScriptRoot = Join-Path $BaseRoot "Scripts"

$RefreshConfigPath = Join-Path $ConfigRoot "config-refresh.json"
$UploaderConfigPath = Join-Path $ConfigRoot "uploader-config.json"
$ConfigRefreshStatePath = Join-Path $StateRoot "config-refresh-state.json"
$UploadScriptPath = Join-Path $ScriptRoot "Upload-EndpointEvents.ps1"
$ConfigRefreshScriptPath = Join-Path $ScriptRoot "Update-OpenEndpointEventsConfig.ps1"

function Set-OpenEndpointEventsConfigAcl {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    icacls $Path /inheritance:r | Out-Null
    icacls $Path /grant:r "SYSTEM:(OI)(CI)(F)" | Out-Null
    icacls $Path /grant:r "Administrators:(OI)(CI)(F)" | Out-Null
    icacls $Path /remove "Users" "Authenticated Users" "Everyone" 2>$null | Out-Null
}

if ($ConfigUri -notmatch "^https://") {
    throw "ConfigUri must use HTTPS."
}

foreach ($path in @($BaseRoot, $LogRoot, $ConfigRoot, $StateRoot, $ScriptRoot)) {
    if (-not (Test-Path -Path $path)) {
        New-Item -Path $path -ItemType Directory -Force | Out-Null
    }
}

$module = Get-Module -ListAvailable OpenEndpointEvents |
    Sort-Object Version -Descending |
    Select-Object -First 1

if (-not $module) {
    Install-Module -Name OpenEndpointEvents -Scope AllUsers -Force
    $module = Get-Module -ListAvailable OpenEndpointEvents |
        Sort-Object Version -Descending |
        Select-Object -First 1
}

if (-not $module) {
    throw "OpenEndpointEvents module could not be found or installed."
}

$embeddedScriptRoot = Join-Path $module.ModuleBase "Scripts"

if (-not (Test-Path -Path $embeddedScriptRoot)) {
    throw "Embedded Scripts folder not found in module package: $embeddedScriptRoot. Publish module version containing src\OpenEndpointEvents\Scripts."
}

$sourceUploadScript = Join-Path $embeddedScriptRoot "Upload-EndpointEvents.ps1"
$sourceConfigRefreshScript = Join-Path $embeddedScriptRoot "Update-OpenEndpointEventsConfig.ps1"

if (-not (Test-Path -Path $sourceUploadScript)) {
    throw "Upload script missing from module package: $sourceUploadScript"
}

if (-not (Test-Path -Path $sourceConfigRefreshScript)) {
    throw "Config refresh script missing from module package: $sourceConfigRefreshScript"
}

Copy-Item -Path $sourceUploadScript -Destination $UploadScriptPath -Force
Copy-Item -Path $sourceConfigRefreshScript -Destination $ConfigRefreshScriptPath -Force

if (-not (Test-Path -Path $RefreshConfigPath) -or $Force) {
    $refreshConfig = [ordered]@{
        ConfigUri                    = $ConfigUri
        LocalConfigPath              = $UploaderConfigPath
        StatePath                    = $ConfigRefreshStatePath
        MinimumRefreshIntervalHours  = $ConfigRefreshIntervalHours
        RestartUploadTaskAfterUpdate = $false
    }

    $refreshConfig |
        ConvertTo-Json -Depth 10 |
        Set-Content -Path $RefreshConfigPath -Encoding UTF8
}

Set-OpenEndpointEventsConfigAcl -Path $ConfigRoot

Import-Module OpenEndpointEvents -Force

Write-EndpointInfo `
    -Source "OpenEndpointEventsInstaller" `
    -EventName "UploaderInstallStarted" `
    -Message "OpenEndpointEvents uploader installation started" `
    -IncludeEndpointIdentity `
    -IncludeProcessInfo `
    -Data @{
        ModuleVersion              = $module.Version.ToString()
        ModuleBase                 = $module.ModuleBase
        ConfigUriConfigured        = $true
        UploadIntervalMinutes      = $UploadIntervalMinutes
        ConfigRefreshIntervalHours = $ConfigRefreshIntervalHours
    } | Out-Null

$ConfigTaskName = "OpenEndpointEvents Config Refresh"
$UploadTaskName = "OpenEndpointEvents Upload"

$ConfigAction = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$ConfigRefreshScriptPath`""

$ConfigTrigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).AddMinutes(2) `
    -RepetitionInterval (New-TimeSpan -Hours $ConfigRefreshIntervalHours) `
    -RepetitionDuration ([TimeSpan]::MaxValue)

$UploadAction = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$UploadScriptPath`" -Now -Window AllChanged"

$UploadTrigger = New-ScheduledTaskTrigger `
    -Once `
    -At (Get-Date).AddMinutes(5) `
    -RepetitionInterval (New-TimeSpan -Minutes $UploadIntervalMinutes) `
    -RepetitionDuration ([TimeSpan]::MaxValue)

$Principal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -RunLevel Highest

$Settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

Register-ScheduledTask `
    -TaskName $ConfigTaskName `
    -Action $ConfigAction `
    -Trigger $ConfigTrigger `
    -Principal $Principal `
    -Settings $Settings `
    -Force | Out-Null

Register-ScheduledTask `
    -TaskName $UploadTaskName `
    -Action $UploadAction `
    -Trigger $UploadTrigger `
    -Principal $Principal `
    -Settings $Settings `
    -Force | Out-Null

Write-EndpointInfo `
    -Source "OpenEndpointEventsInstaller" `
    -EventName "UploaderInstalled" `
    -Message "OpenEndpointEvents uploader and config refresh scheduled tasks installed" `
    -IncludeEndpointIdentity `
    -IncludeProcessInfo `
    -Data @{
        ConfigTaskName            = $ConfigTaskName
        UploadTaskName            = $UploadTaskName
        RefreshConfigPath         = $RefreshConfigPath
        UploaderConfigPath        = $UploaderConfigPath
        UploadScriptPath          = $UploadScriptPath
        ConfigRefreshScriptPath   = $ConfigRefreshScriptPath
        UploadIntervalMinutes     = $UploadIntervalMinutes
        ConfigRefreshIntervalHours = $ConfigRefreshIntervalHours
        Status                    = "Success"
    } | Out-Null

if ($StartNow) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ConfigRefreshScriptPath -Force -StartUploaderAfterUpdate

    Start-ScheduledTask -TaskName $UploadTaskName -ErrorAction SilentlyContinue
}

Write-Host "OpenEndpointEvents uploader installed."
Write-Host "Config refresh task: $ConfigTaskName"
Write-Host "Upload task: $UploadTaskName"
Write-Host "Config path: $RefreshConfigPath"