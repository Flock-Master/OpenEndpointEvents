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

function ConvertTo-SafeFilePart {
    <#
    .SYNOPSIS
        Converts a string into a filesystem-safe value.

    .DESCRIPTION
        Replaces characters that are unsafe or undesirable in filenames with underscores.

    .PARAMETER Value
        The string value to sanitize.

    .EXAMPLE
        ConvertTo-SafeFilePart -Value "endpoint/001:health check"
    #>

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

function ConvertTo-EndpointEventLevel {
    <#
    .SYNOPSIS
        Normalizes an endpoint event level.

    .DESCRIPTION
        Converts common level aliases into consistent uppercase endpoint event levels.

    .PARAMETER Level
        The event level value to normalize.

    .EXAMPLE
        ConvertTo-EndpointEventLevel -Level "warning"
    #>

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

function ConvertTo-EndpointEventData {
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
    #>

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

function Get-EndpointIdentity {
    <#
    .SYNOPSIS
        Gets basic endpoint identity information.

    .DESCRIPTION
        Collects common endpoint identity fields from WMI/CIM.

        Returned fields:
        - ComputerName
        - SerialNumber
        - DeviceId
        - Manufacturer
        - Model
        - OSVersion
        - OSBuild
        - Domain

        CIM verbose output is suppressed so parent scripts using -Verbose do not get noisy
        Get-CimInstance messages.

    .EXAMPLE
        Get-EndpointIdentity
    #>

    [CmdletBinding()]
    param()

    $previousVerbosePreference = $VerbosePreference
    $VerbosePreference = "SilentlyContinue"

    $serialNumber = "UnknownSerial"
    $manufacturer = $null
    $model = $null
    $osVersion = $null
    $osBuild = $null
    $domain = $null

    try {
        try {
            $bios = Get-CimInstance `
                -ClassName Win32_BIOS `
                -ErrorAction Stop `
                -Verbose:$false

            if (-not [string]::IsNullOrWhiteSpace($bios.SerialNumber)) {
                $serialNumber = $bios.SerialNumber
            }
        }
        catch {}

        try {
            $cs = Get-CimInstance `
                -ClassName Win32_ComputerSystem `
                -ErrorAction Stop `
                -Verbose:$false

            $manufacturer = $cs.Manufacturer
            $model = $cs.Model
            $domain = $cs.Domain
        }
        catch {}

        try {
            $os = Get-CimInstance `
                -ClassName Win32_OperatingSystem `
                -ErrorAction Stop `
                -Verbose:$false

            $osVersion = $os.Version
            $osBuild = $os.BuildNumber
        }
        catch {}

        $safeSerialNumber = ($serialNumber -replace '[^a-zA-Z0-9\-_]', '_')
        $computerName = $env:COMPUTERNAME

        $deviceId = if (-not [string]::IsNullOrWhiteSpace($safeSerialNumber) -and $safeSerialNumber -ne "UnknownSerial") {
            $safeSerialNumber
        }
        else {
            $computerName
        }

        [pscustomobject]@{
            ComputerName = $computerName
            SerialNumber = $safeSerialNumber
            DeviceId     = $deviceId
            Manufacturer = $manufacturer
            Model        = $model
            OSVersion    = $osVersion
            OSBuild      = $osBuild
            Domain       = $domain
        }
    }
    finally {
        $VerbosePreference = $previousVerbosePreference
    }
}

function New-EndpointEventLogPath {
    <#
    .SYNOPSIS
        Creates a standard OpenEndpointEvents NDJSON log file path.

    .DESCRIPTION
        Generates a log file path under the specified log root.

    .PARAMETER Name
        Base log filename. Defaults to endpoint-events.ndjson.

    .PARAMETER LogRoot
        Directory where logs are written.

    .PARAMETER IncludeDate
        Adds current date to the filename.

    .PARAMETER IncludeComputerName
        Adds computer name to the filename.

    .PARAMETER IncludeSerialNumber
        Adds BIOS serial number to the filename.

    .EXAMPLE
        New-EndpointEventLogPath -Name "health" -IncludeDate -IncludeSerialNumber -IncludeComputerName
    #>

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

function Add-EndpointIdentityToEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [System.Collections.Specialized.OrderedDictionary]$Entry
    )

    $identity = Get-EndpointIdentity

    $Entry["ComputerName"]  = $identity.ComputerName
    $Entry["SerialNumber"]  = $identity.SerialNumber
    $Entry["DeviceId"]      = $identity.DeviceId
    $Entry["Manufacturer"]  = $identity.Manufacturer
    $Entry["Model"]         = $identity.Model
    $Entry["OSVersion"]     = $identity.OSVersion
    $Entry["OSBuild"]       = $identity.OSBuild
    $Entry["Domain"]        = $identity.Domain
}

function Write-EndpointEvent {
    <#
    .SYNOPSIS
        Writes a generic structured endpoint event to an NDJSON file.

    .DESCRIPTION
        Writes one compressed JSON object per line to an NDJSON file.

        In v1.2.0, endpoint identity is included by default.
        Use -NoEndpointIdentity to opt out.

        When a -Data key collides with a reserved event field (base fields,
        identity fields, or process-info fields), the value is stored under a
        Data_<key> prefix and a warning is emitted. Suppress the warning with
        -WarningAction SilentlyContinue.

    .PARAMETER NoEndpointIdentity
        Prevents ComputerName, SerialNumber, DeviceId, Manufacturer, Model, OSVersion,
        OSBuild, and Domain from being added to the event.

    .PARAMETER IncludeEndpointIdentity
        Backward-compatible switch. Endpoint identity is now included by default.

    .EXAMPLE
        Write-EndpointEvent -Level INFO -Message "Script started"

    .EXAMPLE
        Write-EndpointEvent -Level INFO -Message "Anonymous local test" -NoEndpointIdentity
    #>

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

        [switch]$NoEndpointIdentity,

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

    if (-not $NoEndpointIdentity) {
        Add-EndpointIdentityToEvent -Entry $entry
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
            Write-Warning ("OpenEndpointEvents: -Data key '{0}' collides with a reserved event field and was stored as 'Data_{0}'. Rename the key in -Data to avoid silent relocation." -f $key)
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

function Write-EndpointInfo {
    <#
    .SYNOPSIS
        Writes an INFO-level endpoint event.

    .DESCRIPTION
        Convenience wrapper around Write-EndpointEvent.

        Endpoint identity is included by default.
        Use -NoEndpointIdentity to opt out.

    .EXAMPLE
        Write-EndpointInfo -Message "Script started"
    #>

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
        [switch]$NoEndpointIdentity,
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
        -NoEndpointIdentity:$NoEndpointIdentity `
        -IncludeProcessInfo:$IncludeProcessInfo
}

function Write-EndpointWarn {
    <#
    .SYNOPSIS
        Writes a WARN-level endpoint event.

    .DESCRIPTION
        Convenience wrapper around Write-EndpointEvent.

        Endpoint identity is included by default.
        Use -NoEndpointIdentity to opt out.

    .EXAMPLE
        Write-EndpointWarn -Message "Disk space below threshold"
    #>

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
        [switch]$NoEndpointIdentity,
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
        -NoEndpointIdentity:$NoEndpointIdentity `
        -IncludeProcessInfo:$IncludeProcessInfo
}

function Write-EndpointError {
    <#
    .SYNOPSIS
        Writes an ERROR-level endpoint event.

    .DESCRIPTION
        Convenience wrapper around Write-EndpointEvent.

        Can accept a PowerShell ErrorRecord and flatten useful error details into
        the JSON event.

        Endpoint identity is included by default.
        Use -NoEndpointIdentity to opt out.

    .EXAMPLE
        Write-EndpointError -Message "Upload failed"
    #>

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
        [switch]$NoEndpointIdentity,
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
        -NoEndpointIdentity:$NoEndpointIdentity `
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