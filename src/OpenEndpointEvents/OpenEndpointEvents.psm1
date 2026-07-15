# OpenEndpointEvents.psm1
# Lightweight PowerShell module for writing user-defined endpoint events as daily NDJSON files.

Set-StrictMode -Version Latest

$script:DefaultLogRoot = "C:\ProgramData\OpenEndpointEvents\Logs"
$script:DefaultLogName = "endpoint-events.ndjson"

function Get-EndpointEventMutexName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $normalizedPath = $Path.ToLowerInvariant()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($normalizedPath)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()

    try {
        $hashBytes = $sha256.ComputeHash($bytes)
        $hash = ([System.BitConverter]::ToString($hashBytes)).Replace("-", "")
        return "Global\OpenEndpointEvents_$hash"
    }
    finally {
        $sha256.Dispose()
    }
}

<#
.SYNOPSIS
    Converts a string into a filesystem-safe value.

.DESCRIPTION
    Replaces characters that are unsafe or undesirable in filenames with underscores.
    Useful when generating log filenames from dynamic values such as computer name,
    serial number, source name, event name, room name, site name, or asset tag.

.PARAMETER Value
    The string value to sanitize.

.EXAMPLE
    ConvertTo-SafeFilePart -Value "endpoint/001:health check"

    Returns a sanitized value suitable for use in a filename.

.EXAMPLE
    $safeComputerName = ConvertTo-SafeFilePart -Value $env:COMPUTERNAME

    Converts the local computer name into a safe filename component.

.OUTPUTS
    System.String
#>
function ConvertTo-SafeFilePart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return "Unknown"
    }

    return ($Value -replace '[^a-zA-Z0-9\-_\.]', '_')
}

<#
.SYNOPSIS
    Normalizes an endpoint event level.

.DESCRIPTION
    Converts common level aliases into consistent uppercase endpoint event levels.

    Normalized values include:
    - INFO
    - WARN
    - ERROR
    - DEBUG
    - TRACE
    - FATAL

.PARAMETER Level
    The event level value to normalize.

.EXAMPLE
    ConvertTo-EndpointEventLevel -Level "warning"

    Returns:
    WARN

.EXAMPLE
    ConvertTo-EndpointEventLevel -Level "Information"

    Returns:
    INFO

.EXAMPLE
    ConvertTo-EndpointEventLevel -Level "critical"

    Returns:
    FATAL

.OUTPUTS
    System.String
#>
function ConvertTo-EndpointEventLevel {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Level
    )

    switch -Regex ($Level.Trim().ToUpperInvariant()) {
        '^(INFO|INFORMATION)$' { return "INFO" }
        '^(WARN|WARNING)$'     { return "WARN" }
        '^(ERR|ERROR)$'        { return "ERROR" }
        '^(DEBUG)$'            { return "DEBUG" }
        '^(TRACE)$'            { return "TRACE" }
        '^(FATAL|CRITICAL)$'   { return "FATAL" }
        default                { return $Level.Trim().ToUpperInvariant() }
    }
}

<#
.SYNOPSIS
    Converts structured input data into ordered endpoint event data.

.DESCRIPTION
    Accepts hashtables, ordered dictionaries, PSCustomObjects, or simple objects
    and converts them into a consistent ordered structure suitable for merging into
    an endpoint event.

.PARAMETER Data
    Structured data to include in an endpoint event.

.EXAMPLE
    ConvertTo-EndpointEventData -Data @{ AssetTag = "C001HT"; Room = "B12" }

    Converts a hashtable into ordered endpoint event data.

.EXAMPLE
    $object = [pscustomobject]@{
        MachineName = "endpoint-001"
        AssetTag    = "C001HT"
    }

    ConvertTo-EndpointEventData -Data $object

    Converts a PSCustomObject into ordered endpoint event data.

.EXAMPLE
    ConvertTo-EndpointEventData -Data "simple value"

    Converts a simple value into an object with a Data property.

.OUTPUTS
    System.Collections.Specialized.OrderedDictionary
#>
function ConvertTo-EndpointEventData {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $false)]
        [object]$Data
    )

    if ($null -eq $Data) {
        return [ordered]@{}
    }

    if ($Data -is [hashtable]) {
        $ordered = [ordered]@{}

        foreach ($key in $Data.Keys) {
            $ordered[[string]$key] = $Data[$key]
        }

        return $ordered
    }

    if ($Data -is [System.Collections.Specialized.OrderedDictionary]) {
        $ordered = [ordered]@{}

        foreach ($key in $Data.Keys) {
            $ordered[[string]$key] = $Data[$key]
        }

        return $ordered
    }

    if ($Data -is [pscustomobject]) {
        $ordered = [ordered]@{}

        foreach ($property in $Data.PSObject.Properties) {
            $ordered[$property.Name] = $property.Value
        }

        return $ordered
    }

    return [ordered]@{
        Data = $Data
    }
}

<#
.SYNOPSIS
    Gets basic endpoint identity information.

.DESCRIPTION
    Collects common endpoint identity fields from WMI/CIM, including:
    - ComputerName
    - SerialNumber
    - Manufacturer
    - Model
    - OSVersion
    - OSBuild
    - Domain

    This function is used by Write-EndpointEvent when -IncludeEndpointIdentity is specified.

.EXAMPLE
    Get-EndpointIdentity

    Returns endpoint identity information for the current machine.

.EXAMPLE
    $identity = Get-EndpointIdentity
    $identity.SerialNumber

    Gets the local endpoint serial number.

.EXAMPLE
    $identity = Get-EndpointIdentity

    Write-EndpointInfo `
        -Message "Identity captured" `
        -Data @{
            ComputerName = $identity.ComputerName
            SerialNumber = $identity.SerialNumber
            Model        = $identity.Model
        }

    Writes endpoint identity details as a custom event.

.OUTPUTS
    PSCustomObject
#>
function Get-EndpointIdentity {
    [CmdletBinding()]
    param()

    $serialNumber = "UnknownSerial"
    $manufacturer = $null
    $model = $null
    $osVersion = $null
    $osBuild = $null
    $domain = $null

    try {
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop

        if (-not [string]::IsNullOrWhiteSpace($bios.SerialNumber)) {
            $serialNumber = $bios.SerialNumber
        }
    }
    catch {}

    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $manufacturer = $cs.Manufacturer
        $model = $cs.Model
        $domain = $cs.Domain
    }
    catch {}

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $osVersion = $os.Version
        $osBuild = $os.BuildNumber
    }
    catch {}

    [pscustomobject]@{
        ComputerName = $env:COMPUTERNAME
        SerialNumber = ($serialNumber -replace '[^a-zA-Z0-9\-_]', '_')
        Manufacturer = $manufacturer
        Model        = $model
        OSVersion    = $osVersion
        OSBuild      = $osBuild
        Domain       = $domain
    }
}

<#
.SYNOPSIS
    Creates a standard OpenEndpointEvents NDJSON log file path.

.DESCRIPTION
    Generates a log file path under the specified log root.

    The filename can optionally include:
    - Current date
    - BIOS serial number
    - Computer name

    The generated file extension is always .ndjson if no .ndjson extension is provided.

.PARAMETER Name
    The base log filename. Defaults to endpoint-events.ndjson.

.PARAMETER LogRoot
    The directory where logs are written.
    Defaults to C:\ProgramData\OpenEndpointEvents\Logs.

.PARAMETER IncludeDate
    Adds the current date to the filename using yyyyMMdd format.

.PARAMETER IncludeComputerName
    Adds the local computer name to the filename.

.PARAMETER IncludeSerialNumber
    Adds the BIOS serial number to the filename.

.EXAMPLE
    New-EndpointEventLogPath

    Creates a default path:
    C:\ProgramData\OpenEndpointEvents\Logs\endpoint-events.ndjson

.EXAMPLE
    New-EndpointEventLogPath -Name "health.ndjson" -IncludeDate -IncludeComputerName

    Creates a path similar to:
    C:\ProgramData\OpenEndpointEvents\Logs\20260619-LAB-PC-001-health.ndjson

.EXAMPLE
    $logPath = New-EndpointEventLogPath `
        -Name "asset-inventory" `
        -IncludeDate `
        -IncludeSerialNumber `
        -IncludeComputerName

    Creates a date, serial, and computer-specific NDJSON log path.

.EXAMPLE
    $logPath = New-EndpointEventLogPath -Name "room-b12" -LogRoot "D:\EndpointEvents" -IncludeDate

    Creates a custom daily log path under D:\EndpointEvents.

.OUTPUTS
    System.String
#>
function New-EndpointEventLogPath {
    [CmdletBinding()]
    param(
        [string]$Name = $script:DefaultLogName,

        [string]$LogRoot = $script:DefaultLogRoot,

        [switch]$IncludeDate,

        [switch]$IncludeComputerName,

        [switch]$IncludeSerialNumber
    )

    if (-not (Test-Path -Path $LogRoot)) {
        New-Item -Path $LogRoot -ItemType Directory -Force | Out-Null
    }

    $safeName = ConvertTo-SafeFilePart -Value $Name

    if ($safeName -notmatch '\.ndjson$') {
        $safeName = "$safeName.ndjson"
    }

    $nameWithoutExtension = [System.IO.Path]::GetFileNameWithoutExtension($safeName)
    $extension = [System.IO.Path]::GetExtension($safeName)

    $parts = New-Object System.Collections.Generic.List[string]

    if ($IncludeDate) {
        $parts.Add((Get-Date -Format "yyyyMMdd"))
    }

    if ($IncludeSerialNumber -or $IncludeComputerName) {
        $identity = Get-EndpointIdentity

        if ($IncludeSerialNumber) {
            $parts.Add((ConvertTo-SafeFilePart -Value $identity.SerialNumber))
        }

        if ($IncludeComputerName) {
            $parts.Add((ConvertTo-SafeFilePart -Value $identity.ComputerName))
        }
    }

    $parts.Add($nameWithoutExtension)

    $fileName = (($parts | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "-") + $extension

    Join-Path -Path $LogRoot -ChildPath $fileName
}

<#
.SYNOPSIS
    Writes a generic structured endpoint event to an NDJSON file.

.DESCRIPTION
    Writes one compressed JSON object per line to an NDJSON file.

    Supports:
    - INFO, WARN, ERROR, DEBUG, TRACE, FATAL levels
    - Plain text messages
    - Arbitrary structured data
    - Endpoint identity enrichment
    - Process/user enrichment
    - Shared correlation IDs
    - Mutex-based safe concurrent writes
    - Daily endpoint event files

    The function returns the path to the log file used.

.PARAMETER Path
    Explicit path to the NDJSON log file.

    If omitted, a standard daily path is generated using New-EndpointEventLogPath.

.PARAMETER LogRoot
    Directory where logs are written when Path is not specified.
    Defaults to C:\ProgramData\OpenEndpointEvents\Logs.

.PARAMETER Name
    Base log filename when Path is not specified.
    Defaults to endpoint-events.ndjson.

.PARAMETER Level
    Event level.

    Common values:
    - INFO
    - WARN
    - ERROR
    - DEBUG
    - TRACE
    - FATAL

    Aliases such as Information, Warning, Err, and Critical are normalized.

.PARAMETER Message
    Human-readable message for the endpoint event.

.PARAMETER Data
    Optional structured data.

    Accepts:
    - Hashtable
    - Ordered hashtable
    - PSCustomObject
    - Simple object

.PARAMETER EventName
    Optional event name, such as DiskCheck, UploadStarted, InventoryCollected, or TaskFailed.

.PARAMETER Source
    Optional source name, such as HealthCheck, BlobUploader, InventoryScript, ScheduledTask, or ClassroomBaseline.

.PARAMETER CorrelationId
    Optional shared ID used to group related events.

    If omitted, a new GUID is generated for the event.

.PARAMETER IncludeEndpointIdentity
    Adds endpoint identity fields:
    - ComputerName
    - SerialNumber
    - Manufacturer
    - Model
    - OSVersion
    - OSBuild
    - Domain

.PARAMETER IncludeProcessInfo
    Adds process execution fields:
    - ProcessId
    - ProcessName
    - UserName

.PARAMETER Depth
    JSON serialization depth. Defaults to 20.

.EXAMPLE
    Write-EndpointEvent -Level INFO -Message "Script started"

    Writes a basic INFO event to the default daily NDJSON log path.

.EXAMPLE
    Write-EndpointEvent -Level WARN -Message "Disk space below threshold"

    Writes a basic WARN event.

.EXAMPLE
    Write-EndpointEvent -Level ERROR -Message "Blob upload failed"

    Writes a basic ERROR event.

.EXAMPLE
    Write-EndpointEvent `
        -Level INFO `
        -Message "Asset inventory captured" `
        -Data @{
            MachineName = "endpoint-001"
            AssetTag    = "C001HT"
            Room        = "B12"
            Site        = "Auckland"
        }

    Writes a structured inventory event.

.EXAMPLE
    Write-EndpointEvent `
        -Level INFO `
        -Source "HealthCheck" `
        -EventName "DiskCheckCompleted" `
        -Message "Disk check completed" `
        -IncludeEndpointIdentity `
        -Data @{
            Drive       = "C:"
            FreeGB      = 42.7
            TotalGB     = 237.8
            PercentFree = 17.9
            Status      = "Healthy"
        }

    Writes a structured health check event with endpoint identity.

.EXAMPLE
    $correlationId = "20260619-DAILY-HEALTHCHECK"

    Write-EndpointEvent `
        -Level INFO `
        -Source "HealthCheck" `
        -EventName "Started" `
        -Message "Daily health check started" `
        -CorrelationId $correlationId

    Write-EndpointEvent `
        -Level INFO `
        -Source "HealthCheck" `
        -EventName "Completed" `
        -Message "Daily health check completed" `
        -CorrelationId $correlationId `
        -Data @{
            Status = "Success"
        }

    Writes multiple related events with the same correlation ID.

.EXAMPLE
    $logPath = New-EndpointEventLogPath `
        -Name "asset-inventory" `
        -IncludeDate `
        -IncludeSerialNumber `
        -IncludeComputerName

    Write-EndpointEvent `
        -Path $logPath `
        -Level INFO `
        -Message "Asset inventory captured" `
        -Data @{
            AssetTag = "C001HT"
        }

    Writes to an explicitly generated log path.

.EXAMPLE
    Write-EndpointEvent `
        -Level INFO `
        -Message "Scheduled task started" `
        -IncludeEndpointIdentity `
        -IncludeProcessInfo `
        -Data @{
            TaskName = "OpenEndpointEvents Upload"
        }

    Writes an event with endpoint identity and process context.

.OUTPUTS
    System.String
#>
function Write-EndpointEvent {
    [CmdletBinding()]
    param(
        [string]$Path,

        [ValidateNotNullOrEmpty()]
        [string]$LogRoot = $script:DefaultLogRoot,

        [string]$Name = $script:DefaultLogName,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$Level,

        [string]$Message,

        [object]$Data,

        [string]$EventName,

        [string]$Source,

        [string]$CorrelationId,

        [switch]$IncludeEndpointIdentity,

        [switch]$IncludeProcessInfo,

        [int]$Depth = 20
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = New-EndpointEventLogPath `
            -Name $Name `
            -LogRoot $LogRoot `
            -IncludeDate `
            -IncludeSerialNumber `
            -IncludeComputerName
    }

    $directory = Split-Path -Path $Path -Parent

    if (-not (Test-Path -Path $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }

    if ([string]::IsNullOrWhiteSpace($CorrelationId)) {
        $CorrelationId = [guid]::NewGuid().ToString()
    }

    $entry = [ordered]@{
        Timestamp     = (Get-Date).ToString("o")
        Level         = ConvertTo-EndpointEventLevel -Level $Level
        Message       = $Message
        EventName     = $EventName
        Source        = $Source
        CorrelationId = $CorrelationId
    }

    if ($IncludeEndpointIdentity) {
        $identity = Get-EndpointIdentity

        $entry["ComputerName"]  = $identity.ComputerName
        $entry["SerialNumber"]  = $identity.SerialNumber
        $entry["Manufacturer"]  = $identity.Manufacturer
        $entry["Model"]         = $identity.Model
        $entry["OSVersion"]     = $identity.OSVersion
        $entry["OSBuild"]       = $identity.OSBuild
        $entry["Domain"]        = $identity.Domain
    }

    if ($IncludeProcessInfo) {
        $process = Get-Process -Id $PID -ErrorAction SilentlyContinue
        $processName = $null

        if ($null -ne $process) {
            $processName = $process.ProcessName
        }

        $entry["ProcessId"]   = $PID
        $entry["ProcessName"] = $processName
        $entry["UserName"]    = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    }

    $structuredData = ConvertTo-EndpointEventData -Data $Data

    foreach ($key in $structuredData.Keys) {
        if ($entry.Contains($key)) {
            $entry["Data_$key"] = $structuredData[$key]
        }
        else {
            $entry[$key] = $structuredData[$key]
        }
    }

    $json = $entry | ConvertTo-Json -Compress -Depth $Depth

    $mutexName = Get-EndpointEventMutexName -Path $Path
    $mutex = New-Object System.Threading.Mutex($false, $mutexName)

    try {
        $lockAcquired = $mutex.WaitOne(30000)

        if (-not $lockAcquired) {
            throw "Timed out waiting for log file lock: $Path"
        }

        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::AppendAllText($Path, $json + [Environment]::NewLine, $utf8NoBom)
    }
    finally {
        try {
            $mutex.ReleaseMutex()
        }
        catch {}

        $mutex.Dispose()
    }

    return $Path
}

<#
.SYNOPSIS
    Writes an INFO-level endpoint event.

.DESCRIPTION
    Convenience wrapper around Write-EndpointEvent that writes with Level set to INFO.

.PARAMETER Message
    Human-readable message for the endpoint event.

.PARAMETER Data
    Optional structured data to merge into the JSON event.

.PARAMETER Path
    Explicit path to the NDJSON log file.

.PARAMETER Name
    Base log filename when Path is not specified.

.PARAMETER LogRoot
    Directory where logs are written when Path is not specified.

.PARAMETER EventName
    Optional event name.

.PARAMETER Source
    Optional source name.

.PARAMETER CorrelationId
    Optional shared ID used to group related events.

.PARAMETER IncludeEndpointIdentity
    Adds endpoint identity fields.

.PARAMETER IncludeProcessInfo
    Adds process execution fields.

.EXAMPLE
    Write-EndpointInfo -Message "Script started"

    Writes a simple INFO event.

.EXAMPLE
    Write-EndpointInfo `
        -Source "Inventory" `
        -EventName "AssetCaptured" `
        -Message "Asset inventory captured" `
        -Data @{
            MachineName = "endpoint-001"
            AssetTag    = "C001HT"
            Room        = "B12"
        }

    Writes a structured INFO event.

.EXAMPLE
    Write-EndpointInfo `
        -Message "Scheduled task started" `
        -IncludeEndpointIdentity `
        -IncludeProcessInfo

    Writes an INFO event with endpoint and process details.

.OUTPUTS
    System.String
#>
function Write-EndpointInfo {
    [CmdletBinding()]
    param(
        [string]$Message,
        [object]$Data,
        [string]$Path,
        [string]$Name = $script:DefaultLogName,
        [string]$LogRoot = $script:DefaultLogRoot,
        [string]$EventName,
        [string]$Source,
        [string]$CorrelationId,
        [switch]$IncludeEndpointIdentity,
        [switch]$IncludeProcessInfo
    )

    Write-EndpointEvent `
        -Path $Path `
        -Name $Name `
        -LogRoot $LogRoot `
        -Level "INFO" `
        -Message $Message `
        -Data $Data `
        -EventName $EventName `
        -Source $Source `
        -CorrelationId $CorrelationId `
        -IncludeEndpointIdentity:$IncludeEndpointIdentity `
        -IncludeProcessInfo:$IncludeProcessInfo
}

<#
.SYNOPSIS
    Writes a WARN-level endpoint event.

.DESCRIPTION
    Convenience wrapper around Write-EndpointEvent that writes with Level set to WARN.

.PARAMETER Message
    Human-readable warning message.

.PARAMETER Data
    Optional structured data to merge into the JSON event.

.PARAMETER Path
    Explicit path to the NDJSON log file.

.PARAMETER Name
    Base log filename when Path is not specified.

.PARAMETER LogRoot
    Directory where logs are written when Path is not specified.

.PARAMETER EventName
    Optional event name.

.PARAMETER Source
    Optional source name.

.PARAMETER CorrelationId
    Optional shared ID used to group related events.

.PARAMETER IncludeEndpointIdentity
    Adds endpoint identity fields.

.PARAMETER IncludeProcessInfo
    Adds process execution fields.

.EXAMPLE
    Write-EndpointWarn -Message "Disk space below threshold"

    Writes a simple WARN event.

.EXAMPLE
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

    Writes a structured WARN event.

.EXAMPLE
    Write-EndpointWarn `
        -Source "ClassroomBaseline" `
        -EventName "ConfigurationDriftDetected" `
        -Message "Classroom endpoint configuration drift detected" `
        -Data @{
            Room       = "B12"
            Setting    = "WallpaperLock"
            Expected   = "Enabled"
            Actual     = "Disabled"
            Status     = "NonCompliant"
        }

    Writes a warning event for an education computer room baseline check.

.OUTPUTS
    System.String
#>
function Write-EndpointWarn {
    [CmdletBinding()]
    param(
        [string]$Message,
        [object]$Data,
        [string]$Path,
        [string]$Name = $script:DefaultLogName,
        [string]$LogRoot = $script:DefaultLogRoot,
        [string]$EventName,
        [string]$Source,
        [string]$CorrelationId,
        [switch]$IncludeEndpointIdentity,
        [switch]$IncludeProcessInfo
    )

    Write-EndpointEvent `
        -Path $Path `
        -Name $Name `
        -LogRoot $LogRoot `
        -Level "WARN" `
        -Message $Message `
        -Data $Data `
        -EventName $EventName `
        -Source $Source `
        -CorrelationId $CorrelationId `
        -IncludeEndpointIdentity:$IncludeEndpointIdentity `
        -IncludeProcessInfo:$IncludeProcessInfo
}

<#
.SYNOPSIS
    Writes an ERROR-level endpoint event.

.DESCRIPTION
    Convenience wrapper around Write-EndpointEvent that writes with Level set to ERROR.

    Can also accept a PowerShell ErrorRecord and flatten useful error details into
    the JSON event.

.PARAMETER Message
    Human-readable error message.

.PARAMETER Data
    Optional structured data to merge into the JSON event.

.PARAMETER Path
    Explicit path to the NDJSON log file.

.PARAMETER Name
    Base log filename when Path is not specified.

.PARAMETER LogRoot
    Directory where logs are written when Path is not specified.

.PARAMETER EventName
    Optional event name.

.PARAMETER Source
    Optional source name.

.PARAMETER CorrelationId
    Optional shared ID used to group related events.

.PARAMETER IncludeEndpointIdentity
    Adds endpoint identity fields.

.PARAMETER IncludeProcessInfo
    Adds process execution fields.

.PARAMETER ErrorRecord
    PowerShell error record, usually passed from a catch block using $_.

.EXAMPLE
    Write-EndpointError -Message "Upload failed"

    Writes a simple ERROR event.

.EXAMPLE
    try {
        Get-Item "C:\Does\Not\Exist" -ErrorAction Stop
    }
    catch {
        Write-EndpointError `
            -Source "FileCheck" `
            -EventName "PathAccessFailed" `
            -Message "Failed to access path" `
            -ErrorRecord $_ `
            -Data @{
                Path = "C:\Does\Not\Exist"
            } `
            -IncludeEndpointIdentity
    }

    Writes an ERROR event with exception details from a catch block.

.EXAMPLE
    Write-EndpointError `
        -Source "BlobUploader" `
        -EventName "UploadFailed" `
        -Message "Blob upload failed" `
        -Data @{
            BlobName   = "endpoint-events.ndjson"
            StatusCode = 403
            Reason     = "SAS token expired"
        }

    Writes a structured ERROR event.

.EXAMPLE
    $correlationId = "20260619-ROOM-B12-BASELINE"

    Write-EndpointError `
        -Source "ClassroomBaseline" `
        -EventName "BaselineFailed" `
        -Message "Endpoint failed classroom baseline validation" `
        -CorrelationId $correlationId `
        -IncludeEndpointIdentity `
        -Data @{
            Room        = "B12"
            AssetTag    = "C001HT"
            FailedCheck = "RequiredApplication"
            Application = "Exam Browser"
            Status      = "Failed"
        }

    Writes a correlated baseline failure event.

.OUTPUTS
    System.String
#>
function Write-EndpointError {
    [CmdletBinding()]
    param(
        [string]$Message,
        [object]$Data,
        [string]$Path,
        [string]$Name = $script:DefaultLogName,
        [string]$LogRoot = $script:DefaultLogRoot,
        [string]$EventName,
        [string]$Source,
        [string]$CorrelationId,
        [switch]$IncludeEndpointIdentity,
        [switch]$IncludeProcessInfo,
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    $errorData = [ordered]@{}

    if ($Data) {
        $inputData = ConvertTo-EndpointEventData -Data $Data

        foreach ($key in $inputData.Keys) {
            $errorData[$key] = $inputData[$key]
        }
    }

    if ($ErrorRecord) {
        $errorData["ExceptionMessage"] = $ErrorRecord.Exception.Message
        $errorData["ExceptionType"] = $ErrorRecord.Exception.GetType().FullName
        $errorData["CategoryInfo"] = $ErrorRecord.CategoryInfo.ToString()
        $errorData["FullyQualifiedErrorId"] = $ErrorRecord.FullyQualifiedErrorId
        $errorData["ScriptStackTrace"] = $ErrorRecord.ScriptStackTrace
    }

    Write-EndpointEvent `
        -Path $Path `
        -Name $Name `
        -LogRoot $LogRoot `
        -Level "ERROR" `
        -Message $Message `
        -Data $errorData `
        -EventName $EventName `
        -Source $Source `
        -CorrelationId $CorrelationId `
        -IncludeEndpointIdentity:$IncludeEndpointIdentity `
        -IncludeProcessInfo:$IncludeProcessInfo
}

Export-ModuleMember -Function `
    ConvertTo-SafeFilePart, `
    ConvertTo-EndpointEventLevel, `
    ConvertTo-EndpointEventData, `
    Get-EndpointIdentity, `
    New-EndpointEventLogPath, `
    Write-EndpointEvent, `
    Write-EndpointInfo, `
    Write-EndpointWarn, `
    Write-EndpointError