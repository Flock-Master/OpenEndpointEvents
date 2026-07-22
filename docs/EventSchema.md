# Event Schema

OpenEndpointEvents writes one JSON object per line.

This format is called NDJSON.

## Common fields

| Field | Description |
|---|---|
| Timestamp | Event timestamp |
| Level | INFO, WARN, ERROR, DEBUG, TRACE, or FATAL |
| Message | Human-readable message |
| Source | Broad source of the event |
| EventName | Specific event name |
| CorrelationId | ID used to group related events |
| ComputerName | Endpoint computer name |
| SerialNumber | BIOS serial number |
| Manufacturer | Device manufacturer |
| Model | Device model |
| OSVersion | Operating system version |
| OSBuild | Operating system build |
| Domain | Domain or workgroup |

## Custom fields

Custom fields are supplied through the `-Data` parameter.

Example:

```powershell
Write-EndpointInfo `
    -Source "Inventory" `
    -EventName "AssetCaptured" `
    -Message "Asset inventory captured" `
    -Data @{
        AssetTag = "C001HT"
        Room     = "B12"
        Site     = "Auckland"
    }
```

## Recommended custom fields

Use consistent names:

```text
AssetTag
Room
Site
Status
Result
Drive
FreeGB
TotalGB
PercentFree
Application
Version
ExitCode
DurationMs
PolicyName
Expected
Actual
```
