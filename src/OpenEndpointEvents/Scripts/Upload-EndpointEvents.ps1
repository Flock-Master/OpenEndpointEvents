<#
.SYNOPSIS
    Uploads OpenEndpointEvents NDJSON log files to Azure Blob Storage.

.DESCRIPTION
    Uploads changed .ndjson files from the local OpenEndpointEvents log folder to Azure Blob Storage.

    Version 1 behaviour:
    - OverwriteDailyFile blob mode
    - AllChanged catch-up by default
    - Snapshot file before upload
    - Content-MD5 validation during upload
    - State updated only after confirmed upload
    - Upload failures logged locally using OpenEndpointEvents
    - Supports manual immediate upload with -Now
    - Supports script-side upload interval gating using MinimumUploadIntervalMinutes
    - Supports configurable blob path grouping using BlobStoreGroupBy

.PARAMETER ConfigPath
    Local uploader config file path.

.PARAMETER Window
    File selection window. AllChanged is recommended for catch-up.

.PARAMETER Since
    Date used when Window is SinceDate.

.PARAMETER Now
    Runs upload immediately and bypasses MinimumUploadIntervalMinutes.

.PARAMETER ForceUpload
    Uploads eligible files even if state indicates no change.

.PARAMETER MinimumFileAgeSeconds
    Skips files modified more recently than this unless IncludeCurrentFile is enabled.

.PARAMETER IncludeCurrentFile
    Allows uploading the active current daily file.

.EXAMPLE
    .\Upload-EndpointEvents.ps1 -Now -Window AllChanged

.EXAMPLE
    .\Upload-EndpointEvents.ps1 -Now -Window AllChanged -ForceUpload

.EXAMPLE
    .\Upload-EndpointEvents.ps1 -ConfigPath "C:\ProgramData\OpenEndpointEvents\Config\uploader-config.json"
#>

param(
    [string]$ConfigPath = "C:\ProgramData\OpenEndpointEvents\Config\uploader-config.json",

    [ValidateSet("Hourly", "Daily", "Weekly", "AllChanged", "SinceDate")]
    [string]$Window,

    [datetime]$Since,

    [switch]$Now,

    [switch]$ForceUpload,

    [switch]$IncludeCurrentFile,

    [int]$MinimumFileAgeSeconds = -1
)

$ErrorActionPreference = "Stop"

# ------------------------------------------------------------
# Logging helpers
# ------------------------------------------------------------

function Write-UploaderInfo {
    param(
        [string]$EventName,
        [string]$Message,
        [hashtable]$Data
    )

    Import-Module OpenEndpointEvents -ErrorAction SilentlyContinue

    if (Get-Command Write-EndpointInfo -ErrorAction SilentlyContinue) {
        Write-EndpointInfo `
            -Source "OpenEndpointEventsUploader" `
            -EventName $EventName `
            -Message $Message `
            -IncludeEndpointIdentity `
            -Data $Data | Out-Null
    }
}

function Write-UploaderWarn {
    param(
        [string]$EventName,
        [string]$Message,
        [hashtable]$Data
    )

    Import-Module OpenEndpointEvents -ErrorAction SilentlyContinue

    if (Get-Command Write-EndpointWarn -ErrorAction SilentlyContinue) {
        Write-EndpointWarn `
            -Source "OpenEndpointEventsUploader" `
            -EventName $EventName `
            -Message $Message `
            -IncludeEndpointIdentity `
            -Data $Data | Out-Null
    }
}

function Write-UploaderError {
    param(
        [string]$EventName,
        [string]$Message,
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [hashtable]$Data
    )

    Import-Module OpenEndpointEvents -ErrorAction SilentlyContinue

    if (Get-Command Write-EndpointError -ErrorAction SilentlyContinue) {
        Write-EndpointError `
            -Source "OpenEndpointEventsUploader" `
            -EventName $EventName `
            -Message $Message `
            -ErrorRecord $ErrorRecord `
            -IncludeEndpointIdentity `
            -Data $Data | Out-Null
    }
}

# ------------------------------------------------------------
# Path / identity helpers
# ------------------------------------------------------------

function ConvertTo-BlobPathSafePart {
    param(
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "Unknown"
    }

    return ($Value -replace '[^a-zA-Z0-9\-_\.]', '_')
}

function ConvertTo-BlobSafePath {
    param(
        [string]$BlobPath
    )

    $segments = $BlobPath -split "/"

    $encodedSegments = foreach ($segment in $segments) {
        [System.Uri]::EscapeDataString($segment)
    }

    return ($encodedSegments -join "/")
}

function Get-EndpointIdentitySafe {
    $identity = $null

    try {
        Import-Module OpenEndpointEvents -ErrorAction SilentlyContinue

        if (Get-Command Get-EndpointIdentity -ErrorAction SilentlyContinue) {
            $identity = Get-EndpointIdentity
        }
    }
    catch {}

    if ($null -eq $identity) {
        $identity = [pscustomobject]@{
            ComputerName = $env:COMPUTERNAME
            SerialNumber = "UnknownSerial"
        }
    }

    if ([string]::IsNullOrWhiteSpace($identity.ComputerName)) {
        $identity.ComputerName = $env:COMPUTERNAME
    }

    if ([string]::IsNullOrWhiteSpace($identity.SerialNumber)) {
        $identity.SerialNumber = "UnknownSerial"
    }

    return $identity
}

function Get-BlobPath {
    param(
        [System.IO.FileInfo]$File,
        [string]$BlobPrefix,
        [object[]]$BlobStoreGroupBy
    )

    if ($null -eq $BlobStoreGroupBy -or $BlobStoreGroupBy.Count -eq 0) {
        $BlobStoreGroupBy = @("Date")
    }

    $prefix = $BlobPrefix.Trim("/")
    $safeFileName = ConvertTo-BlobPathSafePart -Value $File.Name
    $pathParts = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($prefix)) {
        $pathParts.Add($prefix)
    }

    $date = $File.LastWriteTimeUtc
    $identity = $null

    foreach ($group in $BlobStoreGroupBy) {
        $groupValue = [string]$group

        switch -Regex ($groupValue) {
            "^(Flat)$" {
                # No grouping folder.
            }

            "^(Date)$" {
                $pathParts.Add($date.ToString("yyyy"))
                $pathParts.Add($date.ToString("MM"))
                $pathParts.Add($date.ToString("dd"))
            }

            "^(Year)$" {
                $pathParts.Add($date.ToString("yyyy"))
            }

            "^(Month)$" {
                $pathParts.Add($date.ToString("MM"))
            }

            "^(Day)$" {
                $pathParts.Add($date.ToString("dd"))
            }

            "^(ComputerName)$" {
                if ($null -eq $identity) {
                    $identity = Get-EndpointIdentitySafe
                }

                $pathParts.Add((ConvertTo-BlobPathSafePart -Value $identity.ComputerName))
            }

            "^(SerialNumber)$" {
                if ($null -eq $identity) {
                    $identity = Get-EndpointIdentitySafe
                }

                $pathParts.Add((ConvertTo-BlobPathSafePart -Value $identity.SerialNumber))
            }

            default {
                throw "Unsupported BlobStoreGroupBy value: $groupValue"
            }
        }
    }

    $pathParts.Add($safeFileName)

    return ($pathParts -join "/")
}

# ------------------------------------------------------------
# Upload helpers
# ------------------------------------------------------------

function Get-FileContentMD5Base64 {
    param(
        [string]$Path
    )

    $md5 = [System.Security.Cryptography.MD5]::Create()

    try {
        $stream = [System.IO.File]::OpenRead($Path)

        try {
            $hashBytes = $md5.ComputeHash($stream)
            return [Convert]::ToBase64String($hashBytes)
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $md5.Dispose()
    }
}

function Invoke-WithRetry {
    param(
        [scriptblock]$ScriptBlock,
        [int]$RetryCount = 3,
        [int]$RetryDelaySeconds = 5
    )

    $attempt = 0

    while ($true) {
        $attempt++

        try {
            return & $ScriptBlock
        }
        catch {
            if ($attempt -ge $RetryCount) {
                throw
            }

            Start-Sleep -Seconds $RetryDelaySeconds
        }
    }
}

function Invoke-ConfirmedBlobUpload {
    param(
        [string]$FilePath,
        [string]$ContainerSasUrl,
        [string]$BlobPath,
        [string]$ContentType = "application/x-ndjson"
    )

    if (-not (Test-Path -Path $FilePath)) {
        throw "Upload file does not exist: $FilePath"
    }

    if ($ContainerSasUrl -notmatch "\?") {
        throw "Container SAS URL is invalid. It must include the SAS query string."
    }

    $file = Get-Item -Path $FilePath -ErrorAction Stop
    $contentMd5 = Get-FileContentMD5Base64 -Path $FilePath

    $containerUrl, $sasToken = $ContainerSasUrl -split "\?", 2
    $containerUrl = $containerUrl.TrimEnd("/")

    $safeBlobPath = ConvertTo-BlobSafePath -BlobPath $BlobPath
    $uploadUri = "$containerUrl/$safeBlobPath`?$sasToken"

    $headers = @{
        "x-ms-blob-type" = "BlockBlob"
        "x-ms-version"   = "2023-11-03"
        "Content-MD5"    = $contentMd5
    }

    $response = Invoke-WebRequest `
        -Uri $uploadUri `
        -Method Put `
        -Headers $headers `
        -InFile $FilePath `
        -ContentType $ContentType `
        -UseBasicParsing `
        -ErrorAction Stop

    $statusCode = [int]$response.StatusCode

    if ($statusCode -lt 200 -or $statusCode -gt 299) {
        throw "Azure Blob upload returned unexpected HTTP status code: $statusCode"
    }

    [pscustomobject]@{
        Success          = $true
        StatusCode       = $statusCode
        StatusMessage    = $response.StatusDescription
        BlobPath         = $BlobPath
        FilePath         = $FilePath
        Length           = $file.Length
        LastWriteTimeUtc = $file.LastWriteTimeUtc.ToUniversalTime().ToString("o")
        ContentMD5       = $contentMd5
        ETag             = $response.Headers["ETag"]
        AzureRequestId   = $response.Headers["x-ms-request-id"]
        UploadedUtc      = (Get-Date).ToUniversalTime().ToString("o")
    }
}

function New-UploadSnapshot {
    param(
        [System.IO.FileInfo]$File,
        [string]$SnapshotRoot
    )

    if (-not (Test-Path -Path $SnapshotRoot)) {
        New-Item -Path $SnapshotRoot -ItemType Directory -Force | Out-Null
    }

    $snapshotName = "$($File.BaseName)-upload-$([guid]::NewGuid().ToString()).ndjson"
    $snapshotPath = Join-Path $SnapshotRoot $snapshotName

    Copy-Item -Path $File.FullName -Destination $snapshotPath -Force

    Get-Item -Path $snapshotPath -ErrorAction Stop
}

# ------------------------------------------------------------
# State helpers
# ------------------------------------------------------------

function Get-StateObject {
    param(
        [string]$StatePath
    )

    if (Test-Path -Path $StatePath) {
        return Get-Content -Path $StatePath -Raw | ConvertFrom-Json
    }

    return [pscustomobject]@{
        Files = [pscustomobject]@{}
    }
}

function Get-StateEntry {
    param(
        [object]$State,
        [string]$Key
    )

    $property = $State.Files.PSObject.Properties[$Key]

    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Set-StateEntry {
    param(
        [object]$State,
        [string]$Key,
        [object]$Value
    )

    $property = $State.Files.PSObject.Properties[$Key]

    if ($null -eq $property) {
        $State.Files | Add-Member -MemberType NoteProperty -Name $Key -Value $Value
    }
    else {
        $property.Value = $Value
    }
}

function Save-StateObject {
    param(
        [object]$State,
        [string]$StatePath
    )

    $stateRoot = Split-Path -Path $StatePath -Parent

    if (-not (Test-Path -Path $stateRoot)) {
        New-Item -Path $stateRoot -ItemType Directory -Force | Out-Null
    }

    $State |
        ConvertTo-Json -Depth 20 |
        Set-Content -Path $StatePath -Encoding UTF8
}

function Test-FileChanged {
    param(
        [System.IO.FileInfo]$File,
        [object]$StateEntry
    )

    if ($null -eq $StateEntry) {
        return $true
    }

    if ([int64]$StateEntry.Length -ne [int64]$File.Length) {
        return $true
    }

    $stateTime = [datetime]$StateEntry.LastWriteTimeUtc

    if ($File.LastWriteTimeUtc -gt $stateTime.ToUniversalTime()) {
        return $true
    }

    return $false
}

function Test-UploadDue {
    param(
        [string]$RunStatePath,
        [int]$MinimumUploadIntervalMinutes,
        [switch]$Now
    )

    if ($Now) {
        return $true
    }

    if (-not (Test-Path -Path $RunStatePath)) {
        return $true
    }

    $runState = Get-Content -Path $RunStatePath -Raw | ConvertFrom-Json

    if (-not $runState.LastRunUtc) {
        return $true
    }

    $lastRunUtc = [datetime]$runState.LastRunUtc
    $nextRunUtc = $lastRunUtc.ToUniversalTime().AddMinutes($MinimumUploadIntervalMinutes)

    if ((Get-Date).ToUniversalTime() -lt $nextRunUtc) {
        Write-UploaderInfo `
            -EventName "UploadSkipped" `
            -Message "OpenEndpointEvents upload skipped due to minimum upload interval" `
            -Data @{
                LastRunUtc                    = $lastRunUtc.ToUniversalTime().ToString("o")
                NextRunUtc                    = $nextRunUtc.ToString("o")
                MinimumUploadIntervalMinutes  = $MinimumUploadIntervalMinutes
                Status                        = "Skipped"
            }

        return $false
    }

    return $true
}

function Save-UploadRunState {
    param(
        [string]$RunStatePath,
        [int]$MinimumUploadIntervalMinutes,
        [string]$Status
    )

    $stateRoot = Split-Path -Path $RunStatePath -Parent

    if (-not (Test-Path -Path $stateRoot)) {
        New-Item -Path $stateRoot -ItemType Directory -Force | Out-Null
    }

    [ordered]@{
        LastRunUtc                    = (Get-Date).ToUniversalTime().ToString("o")
        MinimumUploadIntervalMinutes  = $MinimumUploadIntervalMinutes
        Status                        = $Status
    } |
        ConvertTo-Json -Depth 10 |
        Set-Content -Path $RunStatePath -Encoding UTF8
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    if (-not (Test-Path -Path $ConfigPath)) {
        throw "Uploader config file not found: $ConfigPath"
    }

    $config = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json

    $LogRoot = [string]$config.LogRoot
    $StateRoot = [string]$config.StateRoot
    $ContainerSasUrl = [string]$config.ContainerSasUrl
    $BlobPrefix = [string]$config.BlobPrefix
    $BlobWriteMode = [string]$config.BlobWriteMode

    $BlobStoreGroupBy = @("Date")

    if ($config.BlobStoreGroupBy) {
        $BlobStoreGroupBy = @($config.BlobStoreGroupBy)
    }

    if ([string]::IsNullOrWhiteSpace($Window)) {
        $Window = if ($config.DefaultWindow) { [string]$config.DefaultWindow } else { "AllChanged" }
    }

    if ($MinimumFileAgeSeconds -lt 0) {
        $MinimumFileAgeSeconds = if ($config.MinimumFileAgeSeconds -ne $null) { [int]$config.MinimumFileAgeSeconds } else { 30 }
    }

    if (-not $IncludeCurrentFile) {
        $IncludeCurrentFile = [bool]$config.IncludeCurrentFile
    }

    $MaxFilesPerRun = if ($config.MaxFilesPerRun -ne $null) { [int]$config.MaxFilesPerRun } else { 100 }
    $RetryCount = if ($config.RetryCount -ne $null) { [int]$config.RetryCount } else { 3 }
    $RetryDelaySeconds = if ($config.RetryDelaySeconds -ne $null) { [int]$config.RetryDelaySeconds } else { 5 }
    $MinimumUploadIntervalMinutes = if ($config.MinimumUploadIntervalMinutes -ne $null) { [int]$config.MinimumUploadIntervalMinutes } else { 60 }

    if ([string]::IsNullOrWhiteSpace($LogRoot)) {
        throw "LogRoot missing from uploader config."
    }

    if ([string]::IsNullOrWhiteSpace($StateRoot)) {
        throw "StateRoot missing from uploader config."
    }

    if ([string]::IsNullOrWhiteSpace($ContainerSasUrl)) {
        throw "ContainerSasUrl missing from uploader config."
    }

    if ([string]::IsNullOrWhiteSpace($BlobPrefix)) {
        $BlobPrefix = "open-endpoint-events"
    }

    if ([string]::IsNullOrWhiteSpace($BlobWriteMode)) {
        $BlobWriteMode = "OverwriteDailyFile"
    }

    if ($BlobWriteMode -ne "OverwriteDailyFile") {
        throw "Only BlobWriteMode 'OverwriteDailyFile' is supported in v1."
    }

    if (-not (Test-Path -Path $StateRoot)) {
        New-Item -Path $StateRoot -ItemType Directory -Force | Out-Null
    }

    $StatePath = Join-Path $StateRoot "upload-state.json"
    $RunStatePath = Join-Path $StateRoot "upload-run-state.json"
    $SnapshotRoot = Join-Path $StateRoot "Snapshots"

    if (-not (Test-UploadDue -RunStatePath $RunStatePath -MinimumUploadIntervalMinutes $MinimumUploadIntervalMinutes -Now:$Now)) {
        exit 0
    }

    if (-not (Test-Path -Path $LogRoot)) {
        Write-UploaderWarn `
            -EventName "LogRootMissing" `
            -Message "OpenEndpointEvents log root does not exist" `
            -Data @{
                LogRoot = $LogRoot
                Status  = "Skipped"
            }

        Save-UploadRunState -RunStatePath $RunStatePath -MinimumUploadIntervalMinutes $MinimumUploadIntervalMinutes -Status "SkippedLogRootMissing"
        exit 0
    }

    $state = Get-StateObject -StatePath $StatePath

    Write-UploaderInfo `
        -EventName "UploadStarted" `
        -Message "OpenEndpointEvents upload started" `
        -Data @{
            ConfigPath                    = $ConfigPath
            LogRoot                       = $LogRoot
            Window                        = $Window
            Now                           = [bool]$Now
            BlobPrefix                    = $BlobPrefix
            BlobStoreGroupBy              = ($BlobStoreGroupBy -join ",")
            MinimumUploadIntervalMinutes  = $MinimumUploadIntervalMinutes
            Status                        = "Started"
        }

    $files = Get-ChildItem -Path $LogRoot -Filter "*.ndjson" -File -ErrorAction SilentlyContinue

    switch ($Window) {
        "Hourly" {
            $cutoff = (Get-Date).AddHours(-1)
            $files = $files | Where-Object { $_.LastWriteTime -ge $cutoff }
        }

        "Daily" {
            $cutoff = (Get-Date).AddDays(-1)
            $files = $files | Where-Object { $_.LastWriteTime -ge $cutoff }
        }

        "Weekly" {
            $cutoff = (Get-Date).AddDays(-7)
            $files = $files | Where-Object { $_.LastWriteTime -ge $cutoff }
        }

        "SinceDate" {
            $files = $files | Where-Object { $_.LastWriteTime -ge $Since }
        }

        "AllChanged" {}
    }

    $minimumAgeTime = (Get-Date).AddSeconds(-$MinimumFileAgeSeconds)

    if (-not $IncludeCurrentFile) {
        $files = $files | Where-Object { $_.LastWriteTime -lt $minimumAgeTime }
    }

    $files = $files |
        Sort-Object LastWriteTimeUtc |
        Select-Object -First $MaxFilesPerRun

    $uploadedCount = 0
    $skippedCount = 0
    $failedCount = 0

    foreach ($file in $files) {
        $snapshot = $null
        $stateKey = $file.FullName
        $stateEntry = Get-StateEntry -State $state -Key $stateKey
        $changed = Test-FileChanged -File $file -StateEntry $stateEntry

        if (-not $ForceUpload -and -not $changed) {
            $skippedCount++
            continue
        }

        $blobPath = Get-BlobPath `
            -File $file `
            -BlobPrefix $BlobPrefix `
            -BlobStoreGroupBy $BlobStoreGroupBy

        try {
            $snapshot = New-UploadSnapshot -File $file -SnapshotRoot $SnapshotRoot

            $uploadResult = Invoke-WithRetry `
                -RetryCount $RetryCount `
                -RetryDelaySeconds $RetryDelaySeconds `
                -ScriptBlock {
                    Invoke-ConfirmedBlobUpload `
                        -FilePath $snapshot.FullName `
                        -ContainerSasUrl $ContainerSasUrl `
                        -BlobPath $blobPath `
                        -ContentType "application/x-ndjson"
                }

            $previousUploadCount = 0

            if ($stateEntry -and $stateEntry.UploadCount) {
                $previousUploadCount = [int]$stateEntry.UploadCount
            }

            $newStateEntry = [pscustomobject]@{
                Length           = $file.Length
                LastWriteTimeUtc = $file.LastWriteTimeUtc.ToUniversalTime().ToString("o")
                BlobPath         = $blobPath
                UploadedUtc      = $uploadResult.UploadedUtc
                UploadCount      = ($previousUploadCount + 1)
                ETag             = $uploadResult.ETag
                AzureRequestId   = $uploadResult.AzureRequestId
                ContentMD5       = $uploadResult.ContentMD5
                Status           = "Uploaded"
            }

            Set-StateEntry -State $state -Key $stateKey -Value $newStateEntry
            Save-StateObject -State $state -StatePath $StatePath

            $uploadedCount++

            Write-UploaderInfo `
                -EventName "UploadCompleted" `
                -Message "Endpoint event file uploaded successfully" `
                -Data @{
                    LocalPath      = $file.FullName
                    BlobPath       = $blobPath
                    Length         = $file.Length
                    ContentMD5     = $uploadResult.ContentMD5
                    ETag           = $uploadResult.ETag
                    AzureRequestId = $uploadResult.AzureRequestId
                    StatusCode     = $uploadResult.StatusCode
                    Status         = "Success"
                }
        }
        catch {
            $failedCount++

            Write-UploaderError `
                -EventName "UploadFailed" `
                -Message "Endpoint event file upload failed" `
                -ErrorRecord $_ `
                -Data @{
                    LocalPath = $file.FullName
                    BlobPath  = $blobPath
                    Status    = "Failed"
                }
        }
        finally {
            if ($snapshot -and (Test-Path -Path $snapshot.FullName)) {
                Remove-Item -Path $snapshot.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $finalStatus = if ($failedCount -gt 0) { "CompletedWithErrors" } else { "Success" }

    Write-UploaderInfo `
        -EventName "UploadFinished" `
        -Message "OpenEndpointEvents upload finished" `
        -Data @{
            UploadedCount = $uploadedCount
            SkippedCount  = $skippedCount
            FailedCount   = $failedCount
            Status        = $finalStatus
        }

    Save-UploadRunState -RunStatePath $RunStatePath -MinimumUploadIntervalMinutes $MinimumUploadIntervalMinutes -Status $finalStatus

    if ($failedCount -gt 0) {
        exit 1
    }

    exit 0
}
catch {
    Write-UploaderError `
        -EventName "UploaderFailed" `
        -Message "OpenEndpointEvents uploader failed" `
        -ErrorRecord $_ `
        -Data @{
            ConfigPath = $ConfigPath
            Status     = "Failed"
        }

    exit 1
}