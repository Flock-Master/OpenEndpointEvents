# OpenEndpointEvents

OpenEndpointEvents is a lightweight PowerShell module for writing user-defined endpoint events as daily NDJSON files.

It can also upload those logs to Azure Blob Storage using a scheduled uploader.

Version: **1.1.0**

---

## What it does

OpenEndpointEvents has two main parts:

1. **Endpoint event logging**
   - Writes structured events from PowerShell
   - Stores events as NDJSON
   - One JSON object per line
   - One daily file per endpoint

2. **Optional Azure Blob uploader**
   - Uploads local NDJSON files to Azure Blob Storage
   - Uses a scheduled task
   - Supports remote config refresh
   - Supports SAS token rotation
   - Uses the remote config as the source of truth

---

## Install the module

Install from PowerShell Gallery:

```powershell
Install-Module OpenEndpointEvents -Scope AllUsers -Force
```

Import the module:

```powershell
Import-Module OpenEndpointEvents
```

Check available commands:

```powershell
Get-Command -Module OpenEndpointEvents
```

---

## Basic logging example

```powershell
Write-EndpointInfo `
    -Source "Inventory" `
    -EventName "AssetCaptured" `
    -Message "Asset inventory captured" `
    -IncludeEndpointIdentity `
    -Data @{
        AssetTag = "C001HT"
        Room     = "B12"
        Site     = "Auckland"
    }
```

This writes a structured event to the local daily NDJSON log file.

---

## Default local log location

```text
C:\ProgramData\OpenEndpointEvents\Logs
```

Default file name format:

```text
yyyyMMdd-SerialNumber-ComputerName-endpoint-events.ndjson
```

Example:

```text
20260716-ABC123-LAB-PC-001-endpoint-events.ndjson
```

---

## Main commands

| Command | Purpose |
|---|---|
| `Write-EndpointEvent` | Writes a generic event with a selected level |
| `Write-EndpointInfo` | Writes an INFO event |
| `Write-EndpointWarn` | Writes a WARN event |
| `Write-EndpointError` | Writes an ERROR event |
| `New-EndpointEventLogPath` | Creates a standard log path |
| `Get-EndpointIdentity` | Gets endpoint identity information |

---

## Read local logs

Read the latest log file:

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

## Azure Blob uploader

The uploader is optional.

It uploads local NDJSON files to Azure Blob Storage.

The uploader scripts are included with the module package in:

```text
<ModuleBase>\Scripts
```

After installing the module, locate and run the uploader installer:

```powershell
$module = Get-Module -ListAvailable OpenEndpointEvents |
    Sort-Object Version -Descending |
    Select-Object -First 1

& "$($module.ModuleBase)\Scripts\Install-OpenEndpointEventsUploader.ps1" `
    -ConfigUri "<config-read-sas-url>" `
    -StartNow `
    -Verbose
```

---

## Uploader install behaviour

The installer:

1. Creates required folders under:

```text
C:\ProgramData\OpenEndpointEvents
```

2. Copies runtime scripts to:

```text
C:\ProgramData\OpenEndpointEvents\Scripts
```

3. Writes:

```text
C:\ProgramData\OpenEndpointEvents\Config\config-refresh.json
```

4. Downloads the remote uploader config.
5. Applies scheduled task settings from the remote config.
6. Optionally runs an immediate upload when `-StartNow` is used.

---

## Remote config is the source of truth

In v1.1.0, the remote uploader config controls:

- upload SAS
- upload interval
- config refresh interval
- blob folder layout
- retry settings
- upload behaviour

Example remote config:

```json
{
  "ConfigVersion": "2026.07.17.001",
  "GeneratedUtc": "2026-07-17T09:00:00Z",
  "UploadSasExpiresUtc": "2026-07-27T09:00:00Z",

  "LogRoot": "C:\\ProgramData\\OpenEndpointEvents\\Logs",
  "StateRoot": "C:\\ProgramData\\OpenEndpointEvents\\State",

  "ContainerSasUrl": "https://storageaccount.blob.core.windows.net/endpoint-events?<upload-sas>",

  "BlobPrefix": "open-endpoint-events",
  "DefaultWindow": "AllChanged",
  "BlobWriteMode": "OverwriteDailyFile",
  "BlobStoreGroupBy": ["Date"],

  "UploadIntervalMinutes": 1440,
  "MinimumUploadIntervalMinutes": 1440,
  "ConfigRefreshIntervalHours": 12,

  "MinimumFileAgeSeconds": 30,
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

## Default blob layout

Recommended default:

```json
"BlobStoreGroupBy": ["Date"]
```

Blob path:

```text
open-endpoint-events/yyyy/MM/dd/filename.ndjson
```

Example:

```text
open-endpoint-events/2026/07/16/20260716-ABC123-LAB-PC-001-endpoint-events.ndjson
```

---

## Scheduled tasks

The uploader creates two scheduled tasks:

```text
OpenEndpointEvents Config Refresh
OpenEndpointEvents Upload
```

Check them:

```powershell
Get-ScheduledTask -TaskName "OpenEndpointEvents*"
```

Run config refresh manually:

```powershell
Start-ScheduledTask -TaskName "OpenEndpointEvents Config Refresh"
```

Run upload manually:

```powershell
Start-ScheduledTask -TaskName "OpenEndpointEvents Upload"
```

---

## Manual upload

Run upload immediately:

```powershell
powershell.exe `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File "C:\ProgramData\OpenEndpointEvents\Scripts\Upload-EndpointEvents.ps1" `
    -Now `
    -Window AllChanged
```

Force upload even if files are already marked uploaded:

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

## Config refresh

Run config refresh immediately:

```powershell
powershell.exe `
    -NoProfile `
    -ExecutionPolicy Bypass `
    -File "C:\ProgramData\OpenEndpointEvents\Scripts\Update-OpenEndpointEventsConfig.ps1" `
    -Force `
    -ApplySchedule `
    -Verbose
```

---

## Secret rotation

The recommended v1.1 model uses two SAS URLs:

| SAS | Purpose |
|---|---|
| Config read SAS | Lets endpoints download the remote uploader config |
| Upload SAS | Lets endpoints upload logs to the upload container |

The upload SAS is stored in the remote uploader config.

Recommended rotation pattern:

```text
Upload SAS validity: 10 days
Upload SAS rotation: every 7 days
Config refresh interval: 12 hours
```

Do not commit real SAS tokens to GitHub.

---

## Security notes

Never commit:

```text
real SAS URLs
storage account keys
uploader-config.json
config-refresh.json
.env files
certificates
```

Only commit template files with placeholders.

Recommended upload SAS permissions:

```text
Create
Write
HTTPS only
```

Avoid unless required:

```text
Read
List
Delete
```

---

## Version 1.1.0 highlights

- Installer is included inside the PowerShell Gallery module package
- Remote config drives uploader scheduling
- Remote config drives config refresh interval
- Verbose logging added to installer/config/uploader scripts
- Correlation IDs link install, config refresh, and upload events
- `-StartNow` uploads install/config success events to Blob
- Blob path layout is configurable with `BlobStoreGroupBy`

---

## Project status

OpenEndpointEvents v1.1.0 is working and suitable for lab and pilot use.
