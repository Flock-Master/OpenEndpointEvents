# OpenEndpointEvents

OpenEndpointEvents is a lightweight PowerShell module for writing user-defined endpoint events as daily NDJSON files and optionally uploading them to Azure Blob Storage.

It is designed for:

- home labs
- education computer rooms
- shared endpoint environments
- small businesses
- MSPs
- endpoint administration scripts
- simple operational analytics

The project focuses on being simple, readable, and easy to operate.

---

## What it does

OpenEndpointEvents provides two main capabilities:

1. **Local endpoint event logging**
   - Writes structured endpoint events as NDJSON
   - One JSON object per line
   - One daily log file per endpoint
   - Supports custom user-defined fields

2. **Optional Azure Blob upload**
   - Uploads local NDJSON files to Azure Blob Storage
   - Uses a scheduled task
   - Supports remote uploader configuration
   - Supports SAS token rotation through a protected config blob

---

## Example event

```powershell
Import-Module OpenEndpointEvents

Write-EndpointInfo `
    -Source "Inventory" `
    -EventName "AssetCaptured" `
    -Message "Asset inventory captured" `
    -IncludeEndpointIdentity `
    -Data @{
        AssetTag = "C001HT"
        Room     = "B12"
        Site     = "Auckland"
        Role     = "StudentWorkstation"
    }
```

Example NDJSON output:

```json
{"Timestamp":"2026-07-16T22:14:01.1234567+12:00","Level":"INFO","Message":"Asset inventory captured","EventName":"AssetCaptured","Source":"Inventory","CorrelationId":"4b715bb1-7a47-4974-a3e8-1cf1455a5d4f","ComputerName":"LAB-PC-001","SerialNumber":"ABC123","Manufacturer":"Dell Inc.","Model":"OptiPlex 7010","OSVersion":"10.0.22631","OSBuild":"22631","Domain":"SCHOOL.local","AssetTag":"C001HT","Room":"B12","Site":"Auckland","Role":"StudentWorkstation"}
```

---

## Local log location

By default, logs are written to:

```text
C:\ProgramData\OpenEndpointEvents\Logs
```

The default daily file name format is:

```text
yyyyMMdd-SerialNumber-ComputerName-endpoint-events.ndjson
```

Example:

```text
C:\ProgramData\OpenEndpointEvents\Logs\20260716-ABC123-LAB-PC-001-endpoint-events.ndjson
```

Each line in the file is a complete JSON object.

---

## Install the module

Install from PowerShell Gallery:

```powershell
Install-Module -Name OpenEndpointEvents -Scope CurrentUser
```

For all users:

```powershell
Install-Module -Name OpenEndpointEvents -Scope AllUsers
```

Import the module:

```powershell
Import-Module OpenEndpointEvents
```

Verify commands:

```powershell
Get-Command -Module OpenEndpointEvents
```

---

## Main commands

| Command | Purpose |
|---|---|
| `Write-EndpointEvent` | Writes a generic endpoint event with a chosen level |
| `Write-EndpointInfo` | Writes an `INFO` event |
| `Write-EndpointWarn` | Writes a `WARN` event |
| `Write-EndpointError` | Writes an `ERROR` event |
| `New-EndpointEventLogPath` | Creates a standard NDJSON log file path |
| `Get-EndpointIdentity` | Gets endpoint identity information |
| `ConvertTo-SafeFilePart` | Sanitizes text for filenames |
| `ConvertTo-EndpointEventLevel` | Normalizes event level names |
| `ConvertTo-EndpointEventData` | Converts structured data into event fields |

---

## Basic usage

### Write an information event

```powershell
Write-EndpointInfo -Message "Script started"
```

### Write a warning event

```powershell
Write-EndpointWarn `
    -Source "HealthCheck" `
    -EventName "LowDiskSpace" `
    -Message "Free disk space is below threshold" `
    -IncludeEndpointIdentity `
    -Data @{
        Drive       = "C:"
        FreeGB      = 8.2
        ThresholdGB = 10
        Status      = "Warning"
    }
```

### Write an error event

```powershell
try {
    Get-Item "C:\Does\Not\Exist" -ErrorAction Stop
}
catch {
    Write-EndpointError `
        -Source "FileCheck" `
        -EventName "PathAccessFailed" `
        -Message "Failed to access path" `
        -ErrorRecord $_ `
        -IncludeEndpointIdentity `
        -Data @{
            Path = "C:\Does\Not\Exist"
        }
}
```

---

## Reading local logs

Read the latest local log file:

```powershell
Get-ChildItem "C:\ProgramData\OpenEndpointEvents\Logs" -Filter "*.ndjson" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 |
    Get-Content
```

Parse the latest log file:

```powershell
Get-ChildItem "C:\ProgramData\OpenEndpointEvents\Logs" -Filter "*.ndjson" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 |
    Get-Content |
    ConvertFrom-Json |
    Format-Table Timestamp, Level, Source, EventName, Message -AutoSize
```

---

## Azure Blob upload

OpenEndpointEvents can optionally upload local NDJSON files to Azure Blob Storage.

The uploader is separate from the logging module.

```text
PowerShell scripts
  ↓
OpenEndpointEvents local NDJSON logs
  ↓
Upload-EndpointEvents.ps1
  ↓
Azure Blob Storage
```

The uploader supports:

- scheduled upload
- manual upload
- confirmed Azure Blob upload
- retry behaviour
- local upload state tracking
- catch-up after failed uploads
- configurable blob folder layout
- remote uploader config refresh
- SAS token rotation through a protected config blob

---

## Uploader file locations

When installed, the uploader uses:

```text
C:\ProgramData\OpenEndpointEvents\Scripts\Upload-EndpointEvents.ps1
C:\ProgramData\OpenEndpointEvents\Scripts\Update-OpenEndpointEventsConfig.ps1
C:\ProgramData\OpenEndpointEvents\Config\config-refresh.json
C:\ProgramData\OpenEndpointEvents\Config\uploader-config.json
C:\ProgramData\OpenEndpointEvents\State\upload-state.json
C:\ProgramData\OpenEndpointEvents\State\config-refresh-state.json
```

---

## Uploader config

The uploader uses a local config file:

```text
C:\ProgramData\OpenEndpointEvents\Config\uploader-config.json
```

Example:

```json
{
  "ConfigVersion": "2026.07.16.001",
  "GeneratedUtc": "2026-07-16T09:00:00Z",
  "UploadSasExpiresUtc": "2026-07-26T09:00:00Z",

  "LogRoot": "C:\\ProgramData\\OpenEndpointEvents\\Logs",
  "StateRoot": "C:\\ProgramData\\OpenEndpointEvents\\State",

  "ContainerSasUrl": "https://storageaccount.blob.core.windows.net/endpoint-events?<upload-sas>",

  "BlobPrefix": "open-endpoint-events",
  "DefaultWindow": "AllChanged",
  "BlobWriteMode": "OverwriteDailyFile",
  "BlobStoreGroupBy": ["Date"],

  "MinimumFileAgeSeconds": 30,
  "MinimumUploadIntervalMinutes": 60,

  "MaxFilesPerRun": 100,
  "RetryCount": 3,
  "RetryDelaySeconds": 5,

  "DeleteAfterUpload": false,
  "IncludeCurrentFile": true,
  "LocalRetentionDays": 30,
  "CleanupUploadedFilesOnly": true
}
```

---

## Blob folder layout

The uploader supports configurable blob folder grouping through:

```json
"BlobStoreGroupBy": ["Date"]
```

Default recommended layout:

```text
open-endpoint-events/yyyy/MM/dd/filename.ndjson
```

Example:

```text
open-endpoint-events/2026/07/16/20260716-ABC123-LAB-PC-001-endpoint-events.ndjson
```

Other supported grouping options include:

```json
["Date", "ComputerName"]
```

```json
["Date", "SerialNumber"]
```

```json
["Date", "SerialNumber", "ComputerName"]
```

```json
["Flat"]
```

---

## Scheduled tasks

The uploader installer creates scheduled tasks:

```text
OpenEndpointEvents Config Refresh
OpenEndpointEvents Upload
```

View them:

```powershell
Get-ScheduledTask -TaskName "OpenEndpointEvents*"
```

Manually start config refresh:

```powershell
Start-ScheduledTask -TaskName "OpenEndpointEvents Config Refresh"
```

Manually start upload:

```powershell
Start-ScheduledTask -TaskName "OpenEndpointEvents Upload"
```

---

## Manual upload

Run an immediate upload:

```powershell
powershell.exe `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File "C:\ProgramData\OpenEndpointEvents\Scripts\Upload-EndpointEvents.ps1" `
    -Now `
    -Window AllChanged
```

Force upload even if state says files are unchanged:

```powershell
powershell.exe `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File "C:\ProgramData\OpenEndpointEvents\Scripts\Upload-EndpointEvents.ps1" `
    -Now `
    -Window AllChanged `
    -ForceUpload
```

---

## Secret rotation model

The recommended v1 model uses two SAS URLs:

| SAS | Purpose |
|---|---|
| Config read SAS | Allows endpoints to download the latest uploader config |
| Upload SAS | Allows endpoints to upload NDJSON files to the upload container |

The upload SAS is stored in the remote uploader config blob.

The endpoint stores a config refresh file pointing to the protected config blob:

```text
C:\ProgramData\OpenEndpointEvents\Config\config-refresh.json
```

Example:

```json
{
  "ConfigUri": "https://storageaccount.blob.core.windows.net/uploader-config/uploader-config.json?<read-only-config-sas>",
  "LocalConfigPath": "C:\\ProgramData\\OpenEndpointEvents\\Config\\uploader-config.json",
  "StatePath": "C:\\ProgramData\\OpenEndpointEvents\\State\\config-refresh-state.json",
  "MinimumRefreshIntervalHours": 6,
  "RestartUploadTaskAfterUpdate": false
}
```

Recommended initial rotation pattern:

```text
Upload SAS validity: 10 days
Upload SAS rotation: every 7 days
Config refresh interval: 6 hours
```

This gives overlap so endpoints can refresh before the old upload SAS expires.

---

## Security notes

Do not commit real secrets to GitHub.

Never commit:

```text
uploader-config.json
config-refresh.json
real SAS URLs
storage account keys
.env files
certificates
```

Only commit templates such as:

```text
config/uploader-config.remote.template.json
config/config-refresh.template.json
```

Recommended SAS permissions:

### Config blob SAS

```text
Read only
HTTPS only
Blob-level SAS preferred
```

### Upload container SAS

```text
Create
Write
HTTPS only
Container scoped
```

Avoid granting:

```text
Read
List
Delete
```

unless specifically required.

---

## Local config ACLs

The installer locks down:

```text
C:\ProgramData\OpenEndpointEvents\Config
```

to:

```text
SYSTEM
Administrators
```

This is required because the local config contains SAS URLs.

---

## Catch-up behaviour

The uploader tracks upload state locally.

If uploads fail for several days because of network issues, expired SAS, or Azure outage:

```text
local files remain on disk
failed files are not marked uploaded
next successful run uploads changed or missing files
```

Default upload window:

```json
"DefaultWindow": "AllChanged"
```

This is recommended for automatic catch-up.

---

## Version 1 scope

Version 1 focuses on:

- local NDJSON event logging
- simple structured event writing
- endpoint identity enrichment
- scheduled Azure Blob upload
- config refresh from protected blob
- basic SAS rotation support
- overwrite daily file upload mode

Future improvements may include:

- append-only segment uploads
- richer installer options
- direct Log Analytics or Azure Data Explorer ingestion
- improved reporting examples
- stronger secret handling options
- managed identity support where available

---

## Project status

This project is currently at version `1.0.0`.

It is functional and suitable for testing in lab environments.
