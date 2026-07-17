<#
.SYNOPSIS
    Installs the OpenEndpointEvents Azure Blob uploader and config refresh scheduled tasks.

.DESCRIPTION
    Installs or verifies the OpenEndpointEvents module, copies the embedded uploader scripts
    to C:\ProgramData\OpenEndpointEvents\Scripts, writes config-refresh.json, locks down
    local config ACLs, and creates two scheduled tasks:

    - OpenEndpointEvents Config Refresh
    - OpenEndpointEvents Upload

    This version avoids Scheduled Task repetition intervals. It creates simple daily triggers
    at fixed times based on the supplied interval, plus startup and logon triggers.

.PARAMETER ConfigUri
    HTTPS URL to the protected remote uploader-config.json blob, including read-only SAS.

.PARAMETER UploadIntervalMinutes
    Upload scheduled task interval in minutes. Default is 60.
    Minimum is 15 to avoid creating excessive daily triggers.

.PARAMETER ConfigRefreshIntervalHours
    Config refresh scheduled task interval in hours. Default is 6.

.PARAMETER StartNow
    Runs config refresh immediately and runs the uploader immediately after installation.

.PARAMETER ForceInstall
    Rewrites local config-refresh.json if it already exists.

.EXAMPLE
    .\Install-OpenEndpointEventsUploader.ps1 `
        -ConfigUri "https://storageaccount.blob.core.windows.net/uploader-config/uploader-config.json?<read-only-config-sas>" `
        -UploadIntervalMinutes 60 `
        -ConfigRefreshIntervalHours 6 `
        -StartNow `
        -ForceInstall
#>

param(
    [string]$ConfigUri,
    [int]$UploadIntervalMinutes = 60,
    [int]$ConfigRefreshIntervalHours = 6,
    [switch]$StartNow,
    [switch]$ForceInstall
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# Validation
# ------------------------------------------------------------

if ([string]::IsNullOrWhiteSpace($ConfigUri)) {
    throw "ConfigUri is required."
}

if ($ConfigUri -notmatch "^https://") {
    throw "ConfigUri must use HTTPS."
}

if ($ConfigRefreshIntervalHours -lt 1 -or $ConfigRefreshIntervalHours -gt 24) {
    throw "ConfigRefreshIntervalHours must be between 1 and 24."
}

if ($UploadIntervalMinutes -lt 15 -or $UploadIntervalMinutes -gt 1440) {
    throw "UploadIntervalMinutes must be between 15 and 1440."
}

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
$isAdmin = $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    throw "This installer must be run as Administrator."
}

# ------------------------------------------------------------
# Paths
# ------------------------------------------------------------

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

$ConfigTaskName = "OpenEndpointEvents Config Refresh"
$UploadTaskName = "OpenEndpointEvents Upload"

# ------------------------------------------------------------
# Helper functions
# ------------------------------------------------------------

function Set-OpenEndpointEventsConfigAcl {
    param(
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }

    icacls $Path /inheritance:r | Out-Null
    icacls $Path /grant:r "SYSTEM:(OI)(CI)(F)" | Out-Null
    icacls $Path /grant:r "Administrators:(OI)(CI)(F)" | Out-Null
    icacls $Path /remove "Users" "Authenticated Users" "Everyone" 2>$null | Out-Null
}

function Write-InstallerInfo {
    param(
        [string]$EventName,
        [string]$Message,
        [hashtable]$Data
    )

    Import-Module OpenEndpointEvents -ErrorAction SilentlyContinue

    if (Get-Command Write-EndpointInfo -ErrorAction SilentlyContinue) {
        Write-EndpointInfo `
            -Source "OpenEndpointEventsInstaller" `
            -EventName $EventName `
            -Message $Message `
            -IncludeEndpointIdentity `
            -IncludeProcessInfo `
            -Data $Data | Out-Null
    }
}

function Write-InstallerError {
    param(
        [string]$EventName,
        [string]$Message,
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [hashtable]$Data
    )

    Import-Module OpenEndpointEvents -ErrorAction SilentlyContinue

    if (Get-Command Write-EndpointError -ErrorAction SilentlyContinue) {
        Write-EndpointError `
            -Source "OpenEndpointEventsInstaller" `
            -EventName $EventName `
            -Message $Message `
            -ErrorRecord $ErrorRecord `
            -IncludeEndpointIdentity `
            -IncludeProcessInfo `
            -Data $Data | Out-Null
    }
}

function New-DailyIntervalTriggers {
    param(
        [int]$IntervalMinutes,
        [switch]$IncludeStartup,
        [switch]$IncludeLogon
    )

    $triggers = New-Object System.Collections.Generic.List[object]

    if ($IncludeStartup) {
        $triggers.Add((New-ScheduledTaskTrigger -AtStartup))
    }

    if ($IncludeLogon) {
        $triggers.Add((New-ScheduledTaskTrigger -AtLogOn))
    }

    $minute = 0

    while ($minute -lt 1440) {
        $time = [datetime]::Today.AddMinutes($minute)
        $triggers.Add((New-ScheduledTaskTrigger -Daily -At $time))
        $minute += $IntervalMinutes
    }

    return $triggers.ToArray()
}

function Register-OpenEndpointEventsTask {
    param(
        [string]$TaskName,
        [string]$ScriptPath,
        [string[]]$ScriptArguments,
        [int]$IntervalMinutes
    )

    if (-not (Test-Path -Path $ScriptPath)) {
        throw "Task script path does not exist: $ScriptPath"
    }

    $argumentText = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`""

    if ($ScriptArguments -and $ScriptArguments.Count -gt 0) {
        $argumentText = "$argumentText $($ScriptArguments -join ' ')"
    }

    $action = New-ScheduledTaskAction `
        -Execute "powershell.exe" `
        -Argument $argumentText

    $triggers = New-DailyIntervalTriggers `
        -IntervalMinutes $IntervalMinutes `
        -IncludeStartup `
        -IncludeLogon

    $principal = New-ScheduledTaskPrincipal `
        -UserId "SYSTEM" `
        -RunLevel Highest

    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit (New-TimeSpan -Minutes 10)

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $triggers `
        -Principal $principal `
        -Settings $settings `
        -Force | Out-Null
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    foreach ($path in @($BaseRoot, $LogRoot, $ConfigRoot, $StateRoot, $ScriptRoot)) {
        if (-not (Test-Path -Path $path)) {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
        }
    }

    # --------------------------------------------------------
    # Ensure OpenEndpointEvents module is installed
    # --------------------------------------------------------

    $module = Get-Module -ListAvailable OpenEndpointEvents |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $module) {
        Install-Module `
            -Name OpenEndpointEvents `
            -Scope AllUsers `
            -Force

        $module = Get-Module -ListAvailable OpenEndpointEvents |
            Sort-Object Version -Descending |
            Select-Object -First 1
    }

    if (-not $module) {
        throw "OpenEndpointEvents module could not be found or installed."
    }

    Import-Module OpenEndpointEvents -Force

    # --------------------------------------------------------
    # Locate embedded scripts inside installed module
    # --------------------------------------------------------

    $embeddedScriptRoot = Join-Path $module.ModuleBase "Scripts"

    if (-not (Test-Path -Path $embeddedScriptRoot)) {
        throw "Embedded Scripts folder not found in module package: $embeddedScriptRoot"
    }

    $sourceUploadScript = Join-Path $embeddedScriptRoot "Upload-EndpointEvents.ps1"
    $sourceConfigRefreshScript = Join-Path $embeddedScriptRoot "Update-OpenEndpointEventsConfig.ps1"

    if (-not (Test-Path -Path $sourceUploadScript)) {
        throw "Upload script missing from module package: $sourceUploadScript"
    }

    if (-not (Test-Path -Path $sourceConfigRefreshScript)) {
        throw "Config refresh script missing from module package: $sourceConfigRefreshScript"
    }

    # --------------------------------------------------------
    # Copy runtime scripts to ProgramData
    # --------------------------------------------------------

    Copy-Item -Path $sourceUploadScript -Destination $UploadScriptPath -Force
    Copy-Item -Path $sourceConfigRefreshScript -Destination $ConfigRefreshScriptPath -Force

    # --------------------------------------------------------
    # Write config-refresh.json
    # --------------------------------------------------------

    if (-not (Test-Path -Path $RefreshConfigPath) -or $ForceInstall) {
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

    Write-InstallerInfo `
        -EventName "UploaderInstallStarted" `
        -Message "OpenEndpointEvents uploader installation started" `
        -Data @{
            ModuleVersion              = $module.Version.ToString()
            ModuleBase                 = $module.ModuleBase
            ConfigUriConfigured        = $true
            UploadIntervalMinutes      = $UploadIntervalMinutes
            ConfigRefreshIntervalHours = $ConfigRefreshIntervalHours
            BaseRoot                   = $BaseRoot
            Status                     = "Started"
        }

    # --------------------------------------------------------
    # Register scheduled tasks
    # --------------------------------------------------------

    $ConfigRefreshIntervalMinutes = $ConfigRefreshIntervalHours * 60

    Register-OpenEndpointEventsTask `
        -TaskName $ConfigTaskName `
        -ScriptPath $ConfigRefreshScriptPath `
        -ScriptArguments @() `
        -IntervalMinutes $ConfigRefreshIntervalMinutes

    Register-OpenEndpointEventsTask `
        -TaskName $UploadTaskName `
        -ScriptPath $UploadScriptPath `
        -ScriptArguments @("-Window", "AllChanged") `
        -IntervalMinutes $UploadIntervalMinutes

    Write-InstallerInfo `
        -EventName "UploaderInstalled" `
        -Message "OpenEndpointEvents uploader and config refresh scheduled tasks installed" `
        -Data @{
            ConfigTaskName              = $ConfigTaskName
            UploadTaskName              = $UploadTaskName
            RefreshConfigPath           = $RefreshConfigPath
            UploaderConfigPath          = $UploaderConfigPath
            UploadScriptPath            = $UploadScriptPath
            ConfigRefreshScriptPath     = $ConfigRefreshScriptPath
            UploadIntervalMinutes       = $UploadIntervalMinutes
            ConfigRefreshIntervalHours  = $ConfigRefreshIntervalHours
            ConfigRefreshIntervalMins   = $ConfigRefreshIntervalMinutes
            Status                      = "Success"
        }

    # --------------------------------------------------------
    # Optional immediate start
    # --------------------------------------------------------

    if ($StartNow) {
        & powershell.exe `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $ConfigRefreshScriptPath `
            -Force

        if ($LASTEXITCODE -ne 0) {
            throw "Initial config refresh failed with exit code $LASTEXITCODE."
        }

        & powershell.exe `
            -NoProfile `
            -ExecutionPolicy Bypass `
            -File $UploadScriptPath `
            -Now `
            -Window AllChanged

        if ($LASTEXITCODE -ne 0) {
            throw "Initial upload failed with exit code $LASTEXITCODE."
        }
    }

    Write-Host "OpenEndpointEvents uploader installed."
    Write-Host "Config refresh task: $ConfigTaskName"
    Write-Host "Upload task: $UploadTaskName"
    Write-Host "Refresh config path: $RefreshConfigPath"
    Write-Host "Uploader config path: $UploaderConfigPath"
    Write-Host "Upload script path: $UploadScriptPath"
    Write-Host "Config refresh script path: $ConfigRefreshScriptPath"

    exit 0
}
catch {
    Write-InstallerError `
        -EventName "UploaderInstallFailed" `
        -Message "OpenEndpointEvents uploader installation failed" `
        -ErrorRecord $_ `
        -Data @{
            ConfigUriConfigured        = -not [string]::IsNullOrWhiteSpace($ConfigUri)
            UploadIntervalMinutes      = $UploadIntervalMinutes
            ConfigRefreshIntervalHours = $ConfigRefreshIntervalHours
            BaseRoot                   = $BaseRoot
            Status                     = "Failed"
        }

    throw
}