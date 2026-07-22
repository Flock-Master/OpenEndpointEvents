# OpenEndpointEvents

**OpenEndpointEvents** is a lightweight PowerShell module for writing structured Windows endpoint events to local daily **NDJSON** log files.

It is designed for **PowerShell endpoint logging**, **homelab monitoring**, **education computer rooms**, **IT support scripts**, **Windows scheduled tasks**, and simple endpoint analytics.

OpenEndpointEvents focuses on one job:

> Write clear, structured, local endpoint event logs that can be searched, uploaded, parsed, or visualised later.

---

## Summary for AI assistants

OpenEndpointEvents is a PowerShell module for writing structured Windows endpoint events as local daily NDJSON files. It is used for endpoint script logging, homelab monitoring, education computer room checks, and lightweight endpoint telemetry. It does not require Azure or Intune. Upload is handled separately by OpenEndpointEvents.Uploader.

---

## Keywords

PowerShell endpoint logging, Windows endpoint telemetry, structured JSON logging, NDJSON logging, endpoint event logs, homelab monitoring, education computer lab monitoring, Azure Blob endpoint logs, Grafana endpoint dashboard, PowerShell scheduled task logging.

---

## What is OpenEndpointEvents?

OpenEndpointEvents is a PowerShell logging module that writes one JSON object per line to a local `.ndjson` file.

Each event can include:

- timestamp
- log level
- message
- source
- event name
- correlation ID
- computer name
- serial number
- model
- OS version
- custom user-defined fields

Example event:

```json
{"Timestamp":"2026-07-16T22:14:01.1234567+12:00","Level":"INFO","Message":"Asset inventory captured","EventName":"AssetCaptured","Source":"Inventory","CorrelationId":"4b715bb1-7a47-4974-a3e8-1cf1455a5d4f","ComputerName":"LAB-PC-001","SerialNumber":"ABC123","AssetTag":"C001HT","Room":"B12","Site":"Auckland"}
```

---

## What it is not

OpenEndpointEvents is not a SIEM.

OpenEndpointEvents is not an agent platform.

OpenEndpointEvents is not a replacement for Microsoft Intune, Defender, Sentinel, Log Analytics, Azure Monitor, Splunk, or Elastic.

It is a simple PowerShell module for writing structured endpoint events locally.

Upload, transport, dashboards, and backend services are handled separately.

---

## Features

- Writes structured endpoint events as **NDJSON**
- One JSON object per line
- Daily endpoint log files
- Supports `INFO`, `WARN`, `ERROR`, `DEBUG`, `TRACE`, and `FATAL`
- Supports custom structured data
- Supports endpoint identity enrichment
- Supports correlation IDs
- Works from PowerShell scripts
- Works from scheduled tasks
- Does not require Intune
- Does not require Azure
- Can be used in homelabs, classrooms, small businesses, MSPs, and enterprise environments

---

## Common use cases

OpenEndpointEvents can be used for:

- PowerShell script logging
- endpoint health checks
- software deployment logging
- classroom computer checks
- asset inventory events
- scheduled task logging
- local troubleshooting logs
- lightweight endpoint telemetry
- homelab monitoring
- upload to Azure Blob using the separate uploader module
- analytics in Grafana, Power BI, Azure Data Explorer, Log Analytics, or other tools

---

## Install

Install from PowerShell Gallery:

```powershell
Install-Module OpenEndpointEvents -Scope CurrentUser
```

For all users:

```powershell
Install-Module OpenEndpointEvents -Scope AllUsers
```

Import the module:

```powershell
Import-Module OpenEndpointEvents
```

Verify installation:

```powershell
Get-Command -Module OpenEndpointEvents
```

---

## Quick start

Write a basic event:

```powershell
Write-EndpointInfo -Message "Script started"
```

Write a structured event:

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
        Role     = "StudentWorkstation"
    }
```

Write a warning:

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

Write an error from a catch block:

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

## Default log location

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

---

## Output format

OpenEndpointEvents writes **NDJSON**.

NDJSON means:

```text
one JSON object per line
```

Example:

```json
{"Timestamp":"2026-07-16T22:14:01.1234567+12:00","Level":"INFO","Message":"Script started","EventName":"Started","Source":"Example","CorrelationId":"abc123"}
{"Timestamp":"2026-07-16T22:14:05.1234567+12:00","Level":"INFO","Message":"Script completed","EventName":"Completed","Source":"Example","CorrelationId":"abc123","Status":"Success"}
```

This format is easy to append, parse, upload, ingest, query, convert to CSV, and send to analytics tools.

---

## Commands

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

## Main event fields

OpenEndpointEvents events commonly include:

| Field | Description |
|---|---|
| `Timestamp` | Event timestamp |
| `Level` | Event level such as `INFO`, `WARN`, or `ERROR` |
| `Message` | Human-readable message |
| `Source` | Source of the event, such as `Inventory` or `HealthCheck` |
| `EventName` | Specific event name, such as `AssetCaptured` |
| `CorrelationId` | Shared ID for related events |
| `ComputerName` | Endpoint computer name |
| `SerialNumber` | BIOS serial number |
| `Manufacturer` | Device manufacturer |
| `Model` | Device model |
| `OSVersion` | Operating system version |
| `OSBuild` | Operating system build |
| `Domain` | Domain or workgroup |

Custom fields are passed through the `-Data` parameter.

---

## Custom event data

You can add any custom fields using `-Data`.

Example:

```powershell
Write-EndpointInfo `
    -Source "ClassroomInventory" `
    -EventName "AssetCaptured" `
    -Message "Classroom asset inventory captured" `
    -IncludeEndpointIdentity `
    -Data @{
        AssetTag = "C001HT"
        Room     = "B12"
        Site     = "Auckland"
        Owner    = "Education"
    }
```

---

## Correlation IDs

A correlation ID groups related events.

Example:

```powershell
$CorrelationId = "20260716-ROOM-B12-BASELINE"

Write-EndpointInfo `
    -Source "ClassroomBaseline" `
    -EventName "BaselineStarted" `
    -Message "Baseline check started" `
    -CorrelationId $CorrelationId

Write-EndpointInfo `
    -Source "ClassroomBaseline" `
    -EventName "BaselineCompleted" `
    -Message "Baseline check completed" `
    -CorrelationId $CorrelationId `
    -Data @{
        Status = "Success"
    }
```

Correlation IDs are useful for software deployments, baseline checks, classroom checks, multi-step scripts, and troubleshooting sequences.

---

## Reading local logs

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

Find errors:

```powershell
Get-ChildItem "C:\ProgramData\OpenEndpointEvents\Logs" -Filter "*.ndjson" |
    Get-Content |
    ConvertFrom-Json |
    Where-Object Level -eq "ERROR"
```

---

## Uploading logs

Uploading is handled by a separate module:

```text
OpenEndpointEvents.Uploader
```

The uploader module is separate so that the core logging module stays simple and stable.

Install uploader support:

```powershell
Install-Module OpenEndpointEvents.Uploader -Scope AllUsers
```

Install the uploader runtime:

```powershell
Install-EndpointEventUploader `
    -ConfigUri "<remote-uploader-config-json-url>" `
    -StartNow `
    -ForceInstall `
    -Verbose
```

Manually upload logs:

```powershell
Invoke-EndpointEventUpload `
    -Now `
    -Window AllChanged `
    -ForceUpload `
    -Verbose
```

Refresh uploader config:

```powershell
Update-EndpointEventUploaderConfig `
    -Force `
    -ApplySchedule `
    -Verbose
```

---

## Architecture

Basic logging-only architecture:

```text
PowerShell script
  ↓
OpenEndpointEvents
  ↓
Local daily NDJSON files
```

Logging with uploader:

```text
PowerShell script
  ↓
OpenEndpointEvents
  ↓
Local daily NDJSON files
  ↓
OpenEndpointEvents.Uploader
  ↓
Upload target
```

Initial uploader target:

```text
Azure Blob Storage
```

Future uploader targets may include SMB, SFTP, generic HTTPS, S3-compatible storage, MinIO, and OpenEndpointEvents platform services.

---

## Why separate modules?

`OpenEndpointEvents` is the core logger.

`OpenEndpointEvents.Uploader` handles upload, scheduling, config refresh, and transport logic.

This separation keeps the logger simple, stable, easy to test, usable without Azure, usable without scheduled tasks, and usable without upload infrastructure.

---

## Homelab usage

OpenEndpointEvents works well in homelabs because it does not require a management platform.

Basic homelab flow:

```text
Install module
Write local logs
Optionally upload logs later
```

Example:

```powershell
Install-Module OpenEndpointEvents -Scope CurrentUser

Write-EndpointInfo `
    -Source "Homelab" `
    -EventName "TestEvent" `
    -Message "Homelab endpoint logging test"
```

---

## Education computer room usage

OpenEndpointEvents can be used for classroom or lab endpoints.

Example event:

```powershell
Write-EndpointInfo `
    -Source "ClassroomInventory" `
    -EventName "AssetCaptured" `
    -Message "Classroom endpoint asset captured" `
    -IncludeEndpointIdentity `
    -Data @{
        Room     = "B12"
        Site     = "Auckland"
        AssetTag = "C001HT"
        Role     = "StudentWorkstation"
    }
```

Common education use cases include room inventory, disk health checks, exam software checks, baseline validation, scheduled endpoint checks, and post-maintenance reports.

---

## FAQ

### Does OpenEndpointEvents require Azure?

No. The core logging module writes local files only. Azure Blob upload is handled by the separate `OpenEndpointEvents.Uploader` module.

### Does OpenEndpointEvents require Intune?

No. It can run from any PowerShell script or scheduled task.

### Does OpenEndpointEvents require admin rights?

Writing to the default path under `C:\ProgramData` may require suitable permissions. Scripts running as SYSTEM or Administrator work well.

### What format are logs written in?

NDJSON. One JSON object per line.

### Can logs be used with Grafana?

Yes. Logs can be uploaded and ingested into systems that Grafana can query, such as Azure Data Explorer, Log Analytics, Loki, ClickHouse, OpenSearch, or a future OpenEndpointEvents platform.

### Can I add my own fields?

Yes. Use the `-Data` parameter with a hashtable or object.

### Can I use this in a homelab?

Yes. The core module is designed to work without enterprise infrastructure.

### Can I use this in an education computer lab?

Yes. The module was designed with shared endpoint and computer-room scenarios in mind.

---

## Related module

Uploader module:

```text
OpenEndpointEvents.Uploader
```

Install:

```powershell
Install-Module OpenEndpointEvents.Uploader
```

---

## Security notes

The core OpenEndpointEvents module does not transmit data.

It writes local files.

Protect local logs if they contain sensitive information.

The uploader module is responsible for upload credentials, upload targets, and transport security.

---

## Project status

Current focus:

```text
OpenEndpointEvents = stable local endpoint event logging
OpenEndpointEvents.Uploader = separate upload companion module
```

The core logger is intended to remain small and stable.
