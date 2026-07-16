<#
.SYNOPSIS
    Refreshes the local OpenEndpointEvents uploader configuration from a protected HTTPS config blob.

.DESCRIPTION
    Downloads a remote uploader-config.json file, validates the content, writes it locally,
    locks down ACLs, and logs success or failure using OpenEndpointEvents.

.PARAMETER RefreshConfigPath
    Local config-refresh.json path.

.PARAMETER Force
    Bypasses MinimumRefreshIntervalHours.

.PARAMETER StartUploaderAfterUpdate
    Starts the upload scheduled task after a successful config update.

.EXAMPLE
    .\Update-OpenEndpointEventsConfig.ps1 -Force -StartUploaderAfterUpdate
#>

[CmdletBinding()]
param(
    [string]$RefreshConfigPath = "C:\ProgramData\OpenEndpointEvents\Config\config-refresh.json",

    [switch]$Force,

    [switch]$StartUploaderAfterUpdate
)

$ErrorActionPreference = "Stop"

function Set-OpenEndpointEventsConfigAcl {
    param(
        [Parameter(Mandatory = $true)]
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

function Write-ConfigInfo {
    param(
        [string]$EventName,
        [string]$Message,
        [hashtable]$Data
    )

    Import-Module OpenEndpointEvents -ErrorAction SilentlyContinue

    if (Get-Command Write-EndpointInfo -ErrorAction SilentlyContinue) {
        Write-EndpointInfo `
            -Source "OpenEndpointEventsConfig" `
            -EventName $EventName `
            -Message $Message `
            -IncludeEndpointIdentity `
            -Data $Data | Out-Null
    }
}

function Write-ConfigError {
    param(
        [string]$EventName,
        [string]$Message,
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [hashtable]$Data
    )

    Import-Module OpenEndpointEvents -ErrorAction SilentlyContinue

    if (Get-Command Write-EndpointError -ErrorAction SilentlyContinue) {
        Write-EndpointError `
            -Source "OpenEndpointEventsConfig" `
            -EventName $EventName `
            -Message $Message `
            -ErrorRecord $ErrorRecord `
            -IncludeEndpointIdentity `
            -Data $Data | Out-Null
    }
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    if (-not (Test-Path -Path $RefreshConfigPath)) {
        throw "Refresh config file not found: $RefreshConfigPath"
    }

    $refreshConfig = Get-Content -Path $RefreshConfigPath -Raw | ConvertFrom-Json

    $configUri = [string]$refreshConfig.ConfigUri
    $localConfigPath = [string]$refreshConfig.LocalConfigPath
    $statePath = [string]$refreshConfig.StatePath
    $minimumRefreshIntervalHours = [int]$refreshConfig.MinimumRefreshIntervalHours

    if ([string]::IsNullOrWhiteSpace($configUri)) {
        throw "ConfigUri is missing from $RefreshConfigPath"
    }

    if ($configUri -notmatch "^https://") {
        throw "ConfigUri must use HTTPS."
    }

    if ([string]::IsNullOrWhiteSpace($localConfigPath)) {
        $localConfigPath = "C:\ProgramData\OpenEndpointEvents\Config\uploader-config.json"
    }

    if ([string]::IsNullOrWhiteSpace($statePath)) {
        $statePath = "C:\ProgramData\OpenEndpointEvents\State\config-refresh-state.json"
    }

    $localConfigRoot = Split-Path -Path $localConfigPath -Parent
    $stateRoot = Split-Path -Path $statePath -Parent

    New-Item -Path $localConfigRoot -ItemType Directory -Force | Out-Null
    New-Item -Path $stateRoot -ItemType Directory -Force | Out-Null

    Set-OpenEndpointEventsConfigAcl -Path $localConfigRoot

    $state = $null

    if (Test-Path -Path $statePath) {
        $state = Get-Content -Path $statePath -Raw | ConvertFrom-Json
    }

    if (-not $Force -and $state -and $state.LastRefreshUtc -and $minimumRefreshIntervalHours -gt 0) {
        $lastRefresh = [datetime]$state.LastRefreshUtc
        $nextAllowed = $lastRefresh.ToUniversalTime().AddHours($minimumRefreshIntervalHours)

        if ((Get-Date).ToUniversalTime() -lt $nextAllowed) {
            Write-ConfigInfo `
                -EventName "ConfigRefreshSkipped" `
                -Message "OpenEndpointEvents config refresh skipped due to minimum refresh interval" `
                -Data @{
                    RefreshConfigPath = $RefreshConfigPath
                    LocalConfigPath   = $localConfigPath
                    LastRefreshUtc    = $lastRefresh.ToUniversalTime().ToString("o")
                    NextAllowedUtc    = $nextAllowed.ToString("o")
                    Status            = "Skipped"
                }

            exit 0
        }
    }

    $tempPath = Join-Path $env:TEMP "uploader-config-$([guid]::NewGuid()).json"

    try {
        $response = Invoke-WebRequest `
            -Uri $configUri `
            -OutFile $tempPath `
            -UseBasicParsing `
            -ErrorAction Stop

        $downloadedConfigRaw = Get-Content -Path $tempPath -Raw
        $downloadedConfig = $downloadedConfigRaw | ConvertFrom-Json

        if ([string]::IsNullOrWhiteSpace($downloadedConfig.ContainerSasUrl)) {
            throw "Downloaded uploader config does not contain ContainerSasUrl."
        }

        if ($downloadedConfig.ContainerSasUrl -notmatch "^https://") {
            throw "ContainerSasUrl must use HTTPS."
        }

        if ($downloadedConfig.ContainerSasUrl -notmatch "\?") {
            throw "ContainerSasUrl does not contain a SAS query string."
        }

        if ([string]::IsNullOrWhiteSpace($downloadedConfig.LogRoot)) {
            throw "Downloaded uploader config does not contain LogRoot."
        }

        if ([string]::IsNullOrWhiteSpace($downloadedConfig.StateRoot)) {
            throw "Downloaded uploader config does not contain StateRoot."
        }

        if ([string]::IsNullOrWhiteSpace($downloadedConfig.BlobPrefix)) {
            throw "Downloaded uploader config does not contain BlobPrefix."
        }

        if ($downloadedConfig.UploadSasExpiresUtc) {
            $expiry = [datetime]$downloadedConfig.UploadSasExpiresUtc

            if ($expiry.ToUniversalTime() -lt (Get-Date).ToUniversalTime()) {
                throw "Downloaded upload SAS is already expired. UploadSasExpiresUtc=$($expiry.ToUniversalTime().ToString('o'))"
            }
        }

        Copy-Item -Path $tempPath -Destination $localConfigPath -Force
        Set-OpenEndpointEventsConfigAcl -Path $localConfigRoot

        $hash = (Get-FileHash -Path $localConfigPath -Algorithm SHA256).Hash

        $newState = [ordered]@{
            LastRefreshUtc      = (Get-Date).ToUniversalTime().ToString("o")
            LocalConfigPath     = $localConfigPath
            ConfigVersion       = $downloadedConfig.ConfigVersion
            UploadSasExpiresUtc = $downloadedConfig.UploadSasExpiresUtc
            Sha256              = $hash
            StatusCode          = [int]$response.StatusCode
            Status              = "Success"
        }

        $newState |
            ConvertTo-Json -Depth 10 |
            Set-Content -Path $statePath -Encoding UTF8

        Write-ConfigInfo `
            -EventName "ConfigUpdated" `
            -Message "OpenEndpointEvents uploader config updated from remote config blob" `
            -Data @{
                RefreshConfigPath   = $RefreshConfigPath
                LocalConfigPath     = $localConfigPath
                ConfigVersion       = $downloadedConfig.ConfigVersion
                UploadSasExpiresUtc = $downloadedConfig.UploadSasExpiresUtc
                Sha256              = $hash
                Status              = "Success"
            }

        if ($StartUploaderAfterUpdate -or [bool]$refreshConfig.RestartUploadTaskAfterUpdate) {
            Start-ScheduledTask -TaskName "OpenEndpointEvents Upload" -ErrorAction SilentlyContinue
        }
    }
    finally {
        Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
    }

    exit 0
}
catch {
    Write-ConfigError `
        -EventName "ConfigUpdateFailed" `
        -Message "OpenEndpointEvents uploader config update failed" `
        -ErrorRecord $_ `
        -Data @{
            RefreshConfigPath = $RefreshConfigPath
            Status            = "Failed"
        }

    exit 1
}