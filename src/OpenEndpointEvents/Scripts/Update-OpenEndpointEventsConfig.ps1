<#
.SYNOPSIS
    Refreshes the local OpenEndpointEvents uploader configuration from a protected HTTPS config blob.

.DESCRIPTION
    Downloads a remote uploader-config.json file, validates the content, writes it locally,
    locks down ACLs, updates refresh state, and optionally applies scheduled task settings
    from the remote config.

.PARAMETER RefreshConfigPath
    Local config-refresh.json path.

.PARAMETER Force
    Bypasses MinimumRefreshIntervalHours.

.PARAMETER ApplySchedule
    Applies scheduled task configuration from the downloaded remote uploader config.

.PARAMETER StartUploaderAfterUpdate
    Starts the upload task after successful config refresh.

.PARAMETER CorrelationId
    Optional shared correlation ID for installer/config/uploader event correlation.

.EXAMPLE
    .\Update-OpenEndpointEventsConfig.ps1 -Force -ApplySchedule -Verbose
#>

[CmdletBinding()]
param(
    [string]$RefreshConfigPath = "C:\ProgramData\OpenEndpointEvents\Config\config-refresh.json",
    [switch]$Force,
    [switch]$ApplySchedule,
    [switch]$StartUploaderAfterUpdate,
    [string]$CorrelationId
)

$ErrorActionPreference = "Stop"
$script:OpenEndpointEventsModuleImported = $false

function Import-OpenEndpointEventsQuiet {
    if ($script:OpenEndpointEventsModuleImported) {
        return
    }

    if (Get-Command Write-EndpointInfo -ErrorAction SilentlyContinue) {
        $script:OpenEndpointEventsModuleImported = $true
        return
    }

    $module = Get-Module -ListAvailable OpenEndpointEvents |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($module) {
        Import-Module $module.Path `
            -Force `
            -Global `
            -ErrorAction SilentlyContinue `
            -Verbose:$false | Out-Null

        $script:OpenEndpointEventsModuleImported = $true
    }
}


if ([string]::IsNullOrWhiteSpace($CorrelationId)) {
    $CorrelationId = "CONFIG-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))-$($env:COMPUTERNAME)-$(([guid]::NewGuid().ToString()).Substring(0,8))"
}

$BaseRoot = "C:\ProgramData\OpenEndpointEvents"
$ConfigRoot = Join-Path $BaseRoot "Config"
$StateRoot = Join-Path $BaseRoot "State"
$ScriptRoot = Join-Path $BaseRoot "Scripts"

$UploadScriptPath = Join-Path $ScriptRoot "Upload-EndpointEvents.ps1"
$ConfigRefreshScriptPath = Join-Path $ScriptRoot "Update-OpenEndpointEventsConfig.ps1"

$ConfigTaskName = "OpenEndpointEvents Config Refresh"
$UploadTaskName = "OpenEndpointEvents Upload"

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

    Write-Verbose "[OpenEndpointEventsConfig] $Message"

    Import-OpenEndpointEventsQuiet

    if (Get-Command Write-EndpointInfo -ErrorAction SilentlyContinue) {
        if ($null -eq $Data) {
            $Data = @{}
        }

        $Data["StepStatus"] = "Success"

        Write-EndpointInfo `
            -Source "OpenEndpointEventsConfig" `
            -EventName $EventName `
            -Message $Message `
            -CorrelationId $CorrelationId `
            -IncludeEndpointIdentity `
            -IncludeProcessInfo `
            -Data $Data | Out-Null
    }
}

function Write-StepWarn {
    param(
        [string]$EventName,
        [string]$Message,
        [hashtable]$Data
    )

    Write-Verbose "[OpenEndpointEventsConfig] WARNING: $Message"

    Import-OpenEndpointEventsQuiet

    if (Get-Command Write-EndpointWarn -ErrorAction SilentlyContinue) {
        if ($null -eq $Data) {
            $Data = @{}
        }

        $Data["StepStatus"] = "Warning"

        Write-EndpointWarn `
            -Source "OpenEndpointEventsConfig" `
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

    Write-Verbose "[OpenEndpointEventsConfig] ERROR: $Message"

    Import-OpenEndpointEventsQuiet

    if (Get-Command Write-EndpointError -ErrorAction SilentlyContinue) {
        if ($null -eq $Data) {
            $Data = @{}
        }

        $Data["StepStatus"] = "Failed"

        Write-EndpointError `
            -Source "OpenEndpointEventsConfig" `
            -EventName $EventName `
            -Message $Message `
            -CorrelationId $CorrelationId `
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

    if ($IntervalMinutes -lt 15 -or $IntervalMinutes -gt 1440) {
        throw "IntervalMinutes must be between 15 and 1440."
    }

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

function Apply-OpenEndpointEventsSchedule {
    param(
        [object]$Config
    )

    $uploadIntervalMinutes = if ($Config.UploadIntervalMinutes -ne $null) {
        [int]$Config.UploadIntervalMinutes
    }
    elseif ($Config.MinimumUploadIntervalMinutes -ne $null) {
        [int]$Config.MinimumUploadIntervalMinutes
    }
    else {
        60
    }

    $configRefreshIntervalHours = if ($Config.ConfigRefreshIntervalHours -ne $null) {
        [int]$Config.ConfigRefreshIntervalHours
    }
    else {
        6
    }

    if ($uploadIntervalMinutes -lt 15 -or $uploadIntervalMinutes -gt 1440) {
        throw "UploadIntervalMinutes must be between 15 and 1440."
    }

    if ($configRefreshIntervalHours -lt 1 -or $configRefreshIntervalHours -gt 24) {
        throw "ConfigRefreshIntervalHours must be between 1 and 24."
    }

    $configRefreshIntervalMinutes = $configRefreshIntervalHours * 60

    Write-StepInfo `
        -EventName "ScheduleApplyStarted" `
        -Message "Applying scheduled task configuration from remote config" `
        -Data @{
            UploadIntervalMinutes       = $uploadIntervalMinutes
            ConfigRefreshIntervalHours  = $configRefreshIntervalHours
            ConfigRefreshIntervalMins   = $configRefreshIntervalMinutes
            UploadTaskName              = $UploadTaskName
            ConfigTaskName              = $ConfigTaskName
        }

    Register-OpenEndpointEventsTask `
        -TaskName $ConfigTaskName `
        -ScriptPath $ConfigRefreshScriptPath `
        -ScriptArguments @("-ApplySchedule") `
        -IntervalMinutes $configRefreshIntervalMinutes

    Register-OpenEndpointEventsTask `
        -TaskName $UploadTaskName `
        -ScriptPath $UploadScriptPath `
        -ScriptArguments @("-Window", "AllChanged") `
        -IntervalMinutes $uploadIntervalMinutes

    Write-StepInfo `
        -EventName "ScheduleApplied" `
        -Message "Scheduled task configuration applied from remote config" `
        -Data @{
            UploadIntervalMinutes       = $uploadIntervalMinutes
            ConfigRefreshIntervalHours  = $configRefreshIntervalHours
            ConfigRefreshIntervalMins   = $configRefreshIntervalMinutes
            UploadTaskName              = $UploadTaskName
            ConfigTaskName              = $ConfigTaskName
            Status                      = "Success"
        }
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    Write-Verbose "[OpenEndpointEventsConfig] CorrelationId: $CorrelationId"

    Write-StepInfo `
        -EventName "ConfigRefreshStarted" `
        -Message "OpenEndpointEvents config refresh started" `
        -Data @{
            RefreshConfigPath = $RefreshConfigPath
            Force             = [bool]$Force
            ApplySchedule     = [bool]$ApplySchedule
        }

    if (-not (Test-Path -Path $RefreshConfigPath)) {
        throw "Refresh config file not found: $RefreshConfigPath"
    }

    $refreshConfig = Get-Content -Path $RefreshConfigPath -Raw | ConvertFrom-Json

    $configUri = [string]$refreshConfig.ConfigUri
    $localConfigPath = [string]$refreshConfig.LocalConfigPath
    $statePath = [string]$refreshConfig.StatePath

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

    $minimumRefreshIntervalHours = 6

    if ($refreshConfig.MinimumRefreshIntervalHours) {
        $minimumRefreshIntervalHours = [int]$refreshConfig.MinimumRefreshIntervalHours
    }
    elseif ($state -and $state.ConfigRefreshIntervalHours) {
        $minimumRefreshIntervalHours = [int]$state.ConfigRefreshIntervalHours
    }

    if (-not $Force -and $state -and $state.LastRefreshUtc -and $minimumRefreshIntervalHours -gt 0) {
        $lastRefresh = [datetime]$state.LastRefreshUtc
        $nextAllowed = $lastRefresh.ToUniversalTime().AddHours($minimumRefreshIntervalHours)

        if ((Get-Date).ToUniversalTime() -lt $nextAllowed) {
            Write-StepInfo `
                -EventName "ConfigRefreshSkipped" `
                -Message "OpenEndpointEvents config refresh skipped due to minimum refresh interval" `
                -Data @{
                    RefreshConfigPath = $RefreshConfigPath
                    LocalConfigPath   = $localConfigPath
                    LastRefreshUtc    = $lastRefresh.ToUniversalTime().ToString("o")
                    NextAllowedUtc    = $nextAllowed.ToString("o")
                    MinimumRefreshIntervalHours = $minimumRefreshIntervalHours
                    Status            = "Skipped"
                }

            exit 0
        }
    }

    $tempPath = Join-Path $env:TEMP "uploader-config-$([guid]::NewGuid()).json"

    try {
        Write-StepInfo `
            -EventName "RemoteConfigDownloadStarted" `
            -Message "Downloading remote uploader config" `
            -Data @{
                ConfigUriConfigured = $true
                TempPath            = $tempPath
            }

        $response = Invoke-WebRequest `
            -Uri $configUri `
            -OutFile $tempPath `
            -UseBasicParsing `
            -ErrorAction Stop

        Write-StepInfo `
            -EventName "RemoteConfigDownloaded" `
            -Message "Remote uploader config downloaded" `
            -Data @{
                StatusCode = [int]$response.StatusCode
                TempPath   = $tempPath
            }

        $downloadedConfigRaw = Get-Content -Path $tempPath -Raw
        $downloadedConfig = $downloadedConfigRaw | ConvertFrom-Json

        Write-StepInfo `
            -EventName "RemoteConfigValidationStarted" `
            -Message "Validating remote uploader config" `
            -Data @{
                ConfigVersion = $downloadedConfig.ConfigVersion
            }

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

        $uploadIntervalMinutes = if ($downloadedConfig.UploadIntervalMinutes -ne $null) { [int]$downloadedConfig.UploadIntervalMinutes } else { 60 }
        $configRefreshIntervalHours = if ($downloadedConfig.ConfigRefreshIntervalHours -ne $null) { [int]$downloadedConfig.ConfigRefreshIntervalHours } else { 6 }

        Write-StepInfo `
            -EventName "RemoteConfigValidated" `
            -Message "Remote uploader config validated" `
            -Data @{
                ConfigVersion              = $downloadedConfig.ConfigVersion
                UploadSasExpiresUtc        = $downloadedConfig.UploadSasExpiresUtc
                UploadIntervalMinutes      = $uploadIntervalMinutes
                ConfigRefreshIntervalHours = $configRefreshIntervalHours
                BlobStoreGroupBy           = ($downloadedConfig.BlobStoreGroupBy -join ",")
                BlobWriteMode              = $downloadedConfig.BlobWriteMode
            }

        Copy-Item -Path $tempPath -Destination $localConfigPath -Force
        Set-OpenEndpointEventsConfigAcl -Path $localConfigRoot

        $hash = (Get-FileHash -Path $localConfigPath -Algorithm SHA256).Hash

        Write-StepInfo `
            -EventName "LocalConfigWritten" `
            -Message "Local uploader config written" `
            -Data @{
                LocalConfigPath = $localConfigPath
                Sha256          = $hash
            }

        # Update config-refresh.json with current refresh interval from remote config.
        $updatedRefreshConfig = [ordered]@{
            ConfigUri                    = $configUri
            LocalConfigPath              = $localConfigPath
            StatePath                    = $statePath
            MinimumRefreshIntervalHours  = $configRefreshIntervalHours
            RestartUploadTaskAfterUpdate = [bool]$refreshConfig.RestartUploadTaskAfterUpdate
        }

        $updatedRefreshConfig |
            ConvertTo-Json -Depth 10 |
            Set-Content -Path $RefreshConfigPath -Encoding UTF8

        Set-OpenEndpointEventsConfigAcl -Path $localConfigRoot

        $newState = [ordered]@{
            LastRefreshUtc              = (Get-Date).ToUniversalTime().ToString("o")
            LocalConfigPath             = $localConfigPath
            ConfigVersion               = $downloadedConfig.ConfigVersion
            UploadSasExpiresUtc         = $downloadedConfig.UploadSasExpiresUtc
            UploadIntervalMinutes       = $uploadIntervalMinutes
            ConfigRefreshIntervalHours  = $configRefreshIntervalHours
            Sha256                      = $hash
            StatusCode                  = [int]$response.StatusCode
            Status                      = "Success"
        }

        $newState |
            ConvertTo-Json -Depth 10 |
            Set-Content -Path $statePath -Encoding UTF8

        Write-StepInfo `
            -EventName "ConfigStateWritten" `
            -Message "Config refresh state written" `
            -Data @{
                StatePath                   = $statePath
                ConfigVersion               = $downloadedConfig.ConfigVersion
                UploadIntervalMinutes       = $uploadIntervalMinutes
                ConfigRefreshIntervalHours  = $configRefreshIntervalHours
                Status                      = "Success"
            }

        if ($ApplySchedule) {
            Apply-OpenEndpointEventsSchedule -Config $downloadedConfig
        }

        Write-StepInfo `
            -EventName "ConfigRefreshCompleted" `
            -Message "OpenEndpointEvents uploader config refresh completed" `
            -Data @{
                LocalConfigPath             = $localConfigPath
                ConfigVersion               = $downloadedConfig.ConfigVersion
                UploadIntervalMinutes       = $uploadIntervalMinutes
                ConfigRefreshIntervalHours  = $configRefreshIntervalHours
                ApplySchedule               = [bool]$ApplySchedule
                Status                      = "Success"
            }

        if ($StartUploaderAfterUpdate -or [bool]$updatedRefreshConfig.RestartUploadTaskAfterUpdate) {
            Write-StepInfo `
                -EventName "StartUploaderRequested" `
                -Message "Starting uploader after config update" `
                -Data @{
                    UploadTaskName = $UploadTaskName
                }

            Start-ScheduledTask -TaskName $UploadTaskName -ErrorAction SilentlyContinue
        }
    }
    finally {
        Remove-Item -Path $tempPath -Force -ErrorAction SilentlyContinue
    }

    exit 0
}
catch {
    Write-StepError `
        -EventName "ConfigUpdateFailed" `
        -Message "OpenEndpointEvents uploader config update failed" `
        -ErrorRecord $_ `
        -Data @{
            RefreshConfigPath = $RefreshConfigPath
            ApplySchedule     = [bool]$ApplySchedule
            Status            = "Failed"
        }

    exit 1
}
