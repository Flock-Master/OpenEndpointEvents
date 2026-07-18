<#
.SYNOPSIS
    Installs the OpenEndpointEvents Azure Blob uploader bootstrap.

.DESCRIPTION
    Installs or verifies the OpenEndpointEvents module, copies embedded runtime scripts
    to C:\ProgramData\OpenEndpointEvents\Scripts, writes config-refresh.json, locks down
    local config ACLs, then calls Update-OpenEndpointEventsConfig.ps1 to download and apply
    the remote uploader configuration.

    In v1.1, the remote uploader config is the source of truth for:
    - upload SAS
    - upload interval
    - config refresh interval
    - blob path layout
    - upload behaviour

.PARAMETER ConfigUri
    HTTPS URL to the protected remote uploader-config.json blob, including read-only SAS.

.PARAMETER StartNow
    Runs config refresh immediately, applies schedule, and performs an immediate upload.

.PARAMETER ForceInstall
    Rewrites local config-refresh.json if it already exists.

.EXAMPLE
    .\Install-OpenEndpointEventsUploader.ps1 `
        -ConfigUri "https://storageaccount.blob.core.windows.net/uploader-config/uploader-config.json?<read-only-config-sas>" `
        -StartNow `
        -Verbose
#>

[CmdletBinding()]
param(
    [string]$ConfigUri,
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

$CorrelationId = "INSTALL-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))-$($env:COMPUTERNAME)-$(([guid]::NewGuid().ToString()).Substring(0,8))"

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

function Write-StepInfo {
    param(
        [string]$EventName,
        [string]$Message,
        [hashtable]$Data
    )

    Write-Verbose "[OpenEndpointEventsInstaller] $Message"

    Import-Module OpenEndpointEvents -ErrorAction SilentlyContinue

    if (Get-Command Write-EndpointInfo -ErrorAction SilentlyContinue) {
        if ($null -eq $Data) {
            $Data = @{}
        }

        $Data["StepStatus"] = "Success"

        Write-EndpointInfo `
            -Source "OpenEndpointEventsInstaller" `
            -EventName $EventName `
            -Message $Message `
            -CorrelationId $CorrelationId `
            -IncludeEndpointIdentity `
            -IncludeProcessInfo `
            -Data $Data | Out-Null
    }
}

function Write-StepError {
    param(
        [string]$EventName,
        [string]$Message,
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [hashtable]$Data
    )

    Write-Verbose "[OpenEndpointEventsInstaller] ERROR: $Message"

    Import-Module OpenEndpointEvents -ErrorAction SilentlyContinue

    if (Get-Command Write-EndpointError -ErrorAction SilentlyContinue) {
        if ($null -eq $Data) {
            $Data = @{}
        }

        $Data["StepStatus"] = "Failed"

        Write-EndpointError `
            -Source "OpenEndpointEventsInstaller" `
            -EventName $EventName `
            -Message $Message `
            -CorrelationId $CorrelationId `
            -ErrorRecord $ErrorRecord `
            -IncludeEndpointIdentity `
            -IncludeProcessInfo `
            -Data $Data | Out-Null
    }
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Write-Verbose "[OpenEndpointEventsInstaller] CorrelationId: $CorrelationId"

    Write-StepInfo `
        -EventName "InstallStarted" `
        -Message "OpenEndpointEvents uploader installation started" `
        -Data @{
            ConfigUriConfigured = $true
            BaseRoot            = $BaseRoot
            StartNow            = [bool]$StartNow
            ForceInstall        = [bool]$ForceInstall
        }

    Write-StepInfo `
        -EventName "CreateFolderStructure" `
        -Message "Creating OpenEndpointEvents folder structure" `
        -Data @{
            BaseRoot   = $BaseRoot
            LogRoot    = $LogRoot
            ConfigRoot = $ConfigRoot
            StateRoot  = $StateRoot
            ScriptRoot = $ScriptRoot
        }

    foreach ($path in @($BaseRoot, $LogRoot, $ConfigRoot, $StateRoot, $ScriptRoot)) {
        if (-not (Test-Path -Path $path)) {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
        }
    }

    Write-StepInfo `
        -EventName "LocateModule" `
        -Message "Locating or installing OpenEndpointEvents module" `
        -Data @{}

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

    Write-StepInfo `
        -EventName "ModuleLocated" `
        -Message "OpenEndpointEvents module located" `
        -Data @{
            ModuleVersion = $module.Version.ToString()
            ModuleBase    = $module.ModuleBase
        }

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

    Write-StepInfo `
        -EventName "CopyRuntimeScripts" `
        -Message "Copying runtime uploader scripts to ProgramData" `
        -Data @{
            SourceUploadScript        = $sourceUploadScript
            SourceConfigRefreshScript = $sourceConfigRefreshScript
            UploadScriptPath          = $UploadScriptPath
            ConfigRefreshScriptPath   = $ConfigRefreshScriptPath
        }

    Copy-Item -Path $sourceUploadScript -Destination $UploadScriptPath -Force
    Copy-Item -Path $sourceConfigRefreshScript -Destination $ConfigRefreshScriptPath -Force

    Write-StepInfo `
        -EventName "WriteRefreshConfig" `
        -Message "Writing local config-refresh.json" `
        -Data @{
            RefreshConfigPath = $RefreshConfigPath
            ForceInstall      = [bool]$ForceInstall
        }

    if (-not (Test-Path -Path $RefreshConfigPath) -or $ForceInstall) {
        $refreshConfig = [ordered]@{
            ConfigUri       = $ConfigUri
            LocalConfigPath = $UploaderConfigPath
            StatePath       = $ConfigRefreshStatePath
        }

        $refreshConfig |
            ConvertTo-Json -Depth 10 |
            Set-Content -Path $RefreshConfigPath -Encoding UTF8
    }

    Write-StepInfo `
        -EventName "ApplyConfigAcl" `
        -Message "Applying ACLs to config folder" `
        -Data @{
            ConfigRoot = $ConfigRoot
        }

    Set-OpenEndpointEventsConfigAcl -Path $ConfigRoot

    Write-StepInfo `
        -EventName "RunConfigRefresh" `
        -Message "Running config refresh and applying schedule from remote config" `
        -Data @{
            ConfigRefreshScriptPath = $ConfigRefreshScriptPath
        }

    $updateArgs = @(
        "-NoProfile",
        "-ExecutionPolicy", "Bypass",
        "-File", $ConfigRefreshScriptPath,
        "-Force",
        "-ApplySchedule",
        "-CorrelationId", $CorrelationId
    )

    if ($VerbosePreference -eq "Continue") {
        $updateArgs += "-Verbose"
    }

    & powershell.exe @updateArgs

    if ($LASTEXITCODE -ne 0) {
        throw "Config refresh failed with exit code $LASTEXITCODE."
    }

    Write-StepInfo `
        -EventName "ConfigRefreshCompleted" `
        -Message "Config refresh completed and schedule was applied" `
        -Data @{
            UploaderConfigPath = $UploaderConfigPath
        }

    Write-StepInfo `
        -EventName "InstallCompleted" `
        -Message "OpenEndpointEvents uploader installation completed" `
        -Data @{
            RefreshConfigPath        = $RefreshConfigPath
            UploaderConfigPath       = $UploaderConfigPath
            UploadScriptPath         = $UploadScriptPath
            ConfigRefreshScriptPath  = $ConfigRefreshScriptPath
            Status                   = "Success"
        }

    if ($StartNow) {
        Write-StepInfo `
            -EventName "InitialUploadStarted" `
            -Message "Running immediate upload after installation" `
            -Data @{
                UploadScriptPath = $UploadScriptPath
            }

        $uploadArgs = @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $UploadScriptPath,
            "-Now",
            "-Window", "AllChanged",
            "-ForceUpload",
            "-CorrelationId", $CorrelationId
        )

        if ($VerbosePreference -eq "Continue") {
            $uploadArgs += "-Verbose"
        }

        & powershell.exe @uploadArgs

        if ($LASTEXITCODE -ne 0) {
            throw "Initial upload failed with exit code $LASTEXITCODE."
        }

        Write-StepInfo `
            -EventName "InitialUploadCompleted" `
            -Message "Immediate upload completed after installation" `
            -Data @{
                UploadScriptPath = $UploadScriptPath
                Status           = "Success"
            }
    }

    Write-Host "OpenEndpointEvents uploader installed."
    Write-Host "CorrelationId: $CorrelationId"
    Write-Host "Refresh config path: $RefreshConfigPath"
    Write-Host "Uploader config path: $UploaderConfigPath"
    Write-Host "Upload script path: $UploadScriptPath"
    Write-Host "Config refresh script path: $ConfigRefreshScriptPath"

    exit 0
}
catch {
    Write-StepError `
        -EventName "InstallFailed" `
        -Message "OpenEndpointEvents uploader installation failed" `
        -ErrorRecord $_ `
        -Data @{
            ConfigUriConfigured = -not [string]::IsNullOrWhiteSpace($ConfigUri)
            BaseRoot            = $BaseRoot
            Status              = "Failed"
        }

    throw
}