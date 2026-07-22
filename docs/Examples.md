# Examples

## Basic event

```powershell
Write-EndpointInfo -Message "Script started"
```

## Structured inventory event

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

## Health check event

```powershell
$drive = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'"

$totalGb = [math]::Round($drive.Size / 1GB, 2)
$freeGb = [math]::Round($drive.FreeSpace / 1GB, 2)
$percentFree = [math]::Round(($drive.FreeSpace / $drive.Size) * 100, 2)

Write-EndpointInfo `
    -Source "HealthCheck" `
    -EventName "DiskCheckCompleted" `
    -Message "Disk check completed" `
    -IncludeEndpointIdentity `
    -Data @{
        Drive       = "C:"
        TotalGB     = $totalGb
        FreeGB      = $freeGb
        PercentFree = $percentFree
        Status      = "Healthy"
    }
```

## Error event

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
