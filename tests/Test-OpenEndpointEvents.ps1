<#
.SYNOPSIS
    Functional test script for the OpenEndpointEvents PowerShell module.

.DESCRIPTION
    Tests the main OpenEndpointEvents module functions and options:
    - Module import
    - Exported commands
    - Safe filename conversion
    - Event level normalization
    - Structured data conversion
    - Endpoint identity collection
    - Log path generation
    - Generic event writing
    - INFO/WARN/ERROR wrapper functions
    - Structured hashtable data
    - PSCustomObject data
    - Simple value data
    - Correlation IDs
    - Endpoint identity enrichment
    - Process info enrichment
    - ErrorRecord flattening
    - Collision handling for reserved field names
    - NDJSON validity
    - Multiple writes to one file

.PARAMETER ModulePath
    Optional explicit path to OpenEndpointEvents.psd1.

    Example:
    C:\Temp\repos\OpenEndpointEvents\src\OpenEndpointEvents\OpenEndpointEvents.psd1

.PARAMETER TestRoot
    Optional folder where test logs are written.

.PARAMETER KeepTestFiles
    Keeps the test output folder after completion.

.EXAMPLE
    .\tests\Test-OpenEndpointEvents.ps1

    Tests the installed OpenEndpointEvents module.

.EXAMPLE
    .\tests\Test-OpenEndpointEvents.ps1 -ModulePath "C:\Temp\repos\OpenEndpointEvents\src\OpenEndpointEvents\OpenEndpointEvents.psd1"

    Tests the module directly from a repo checkout.

.EXAMPLE
    .\tests\Test-OpenEndpointEvents.ps1 -KeepTestFiles

    Runs tests and keeps generated test logs.
#>

[CmdletBinding()]
param(
    [string]$ModulePath,

    [string]$TestRoot = (Join-Path $env:TEMP "OpenEndpointEvents-Test"),

    [switch]$KeepTestFiles
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$script:TestResults = New-Object System.Collections.Generic.List[object]

function Add-TestResult {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Details = $null
    )

    $script:TestResults.Add([pscustomobject]@{
        Name    = $Name
        Status  = $Status
        Details = $Details
    })
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param(
        [object]$Actual,
        [object]$Expected,
        [string]$Message
    )

    if ($Actual -ne $Expected) {
        throw "$Message Actual='$Actual' Expected='$Expected'"
    }
}

function Invoke-Test {
    param(
        [string]$Name,
        [scriptblock]$ScriptBlock
    )

    try {
        & $ScriptBlock
        Add-TestResult -Name $Name -Status "PASS"
        Write-Host "[PASS] $Name" -ForegroundColor Green
    }
    catch {
        Add-TestResult -Name $Name -Status "FAIL" -Details $_.Exception.Message
        Write-Host "[FAIL] $Name - $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Read-Ndjson {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    Get-Content -Path $Path |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object {
            $_ | ConvertFrom-Json
        }
}

Write-Host "OpenEndpointEvents functional test started." -ForegroundColor Cyan
Write-Host "Test root: $TestRoot" -ForegroundColor Cyan

if (Test-Path -Path $TestRoot) {
    Remove-Item -Path $TestRoot -Recurse -Force
}

New-Item -Path $TestRoot -ItemType Directory -Force | Out-Null

$TestLogPath = Join-Path $TestRoot "open-endpoint-events-test.ndjson"
$SecondLogPath = Join-Path $TestRoot "second-test-log.ndjson"

Invoke-Test -Name "Import module" -ScriptBlock {
    Remove-Module OpenEndpointEvents -Force -ErrorAction SilentlyContinue

    if (-not [string]::IsNullOrWhiteSpace($ModulePath)) {
        Assert-True -Condition (Test-Path -Path $ModulePath) -Message "ModulePath not found: $ModulePath"
        Import-Module $ModulePath -Force
    }
    else {
        Import-Module OpenEndpointEvents -Force
    }

    $module = Get-Module OpenEndpointEvents
    Assert-True -Condition ($null -ne $module) -Message "OpenEndpointEvents module was not imported."
}

Invoke-Test -Name "Exported commands exist" -ScriptBlock {
    $expectedCommands = @(
        "ConvertTo-SafeFilePart",
        "ConvertTo-EndpointEventLevel",
        "ConvertTo-EndpointEventData",
        "Get-EndpointIdentity",
        "New-EndpointEventLogPath",
        "Write-EndpointEvent",
        "Write-EndpointInfo",
        "Write-EndpointWarn",
        "Write-EndpointError"
    )

    foreach ($command in $expectedCommands) {
        $cmd = Get-Command -Name $command -Module OpenEndpointEvents -ErrorAction SilentlyContinue
        Assert-True -Condition ($null -ne $cmd) -Message "Missing exported command: $command"
    }
}

Invoke-Test -Name "ConvertTo-SafeFilePart sanitizes unsafe characters" -ScriptBlock {
    $safe = ConvertTo-SafeFilePart -Value "endpoint/001:health check"
    Assert-Equal -Actual $safe -Expected "endpoint_001_health_check" -Message "Safe filename conversion failed."
}

Invoke-Test -Name "ConvertTo-SafeFilePart handles empty value" -ScriptBlock {
    $safe = ConvertTo-SafeFilePart -Value ""
    Assert-Equal -Actual $safe -Expected "Unknown" -Message "Empty value was not converted to Unknown."
}

Invoke-Test -Name "ConvertTo-EndpointEventLevel normalizes aliases" -ScriptBlock {
    Assert-Equal -Actual (ConvertTo-EndpointEventLevel -Level "information") -Expected "INFO" -Message "Information normalization failed."
    Assert-Equal -Actual (ConvertTo-EndpointEventLevel -Level "warning") -Expected "WARN" -Message "Warning normalization failed."
    Assert-Equal -Actual (ConvertTo-EndpointEventLevel -Level "err") -Expected "ERROR" -Message "Err normalization failed."
    Assert-Equal -Actual (ConvertTo-EndpointEventLevel -Level "critical") -Expected "FATAL" -Message "Critical normalization failed."
    Assert-Equal -Actual (ConvertTo-EndpointEventLevel -Level "debug") -Expected "DEBUG" -Message "Debug normalization failed."
    Assert-Equal -Actual (ConvertTo-EndpointEventLevel -Level "trace") -Expected "TRACE" -Message "Trace normalization failed."
}

Invoke-Test -Name "ConvertTo-EndpointEventData handles hashtable" -ScriptBlock {
    $data = ConvertTo-EndpointEventData -Data @{
        AssetTag = "C001HT"
        Room     = "B12"
    }

    Assert-Equal -Actual $data["AssetTag"] -Expected "C001HT" -Message "Hashtable AssetTag conversion failed."
    Assert-Equal -Actual $data["Room"] -Expected "B12" -Message "Hashtable Room conversion failed."
}

Invoke-Test -Name "ConvertTo-EndpointEventData handles PSCustomObject" -ScriptBlock {
    $object = [pscustomobject]@{
        MachineName = "endpoint-001"
        AssetTag    = "C001HT"
    }

    $data = ConvertTo-EndpointEventData -Data $object

    Assert-Equal -Actual $data["MachineName"] -Expected "endpoint-001" -Message "PSCustomObject MachineName conversion failed."
    Assert-Equal -Actual $data["AssetTag"] -Expected "C001HT" -Message "PSCustomObject AssetTag conversion failed."
}

Invoke-Test -Name "ConvertTo-EndpointEventData handles simple value" -ScriptBlock {
    $data = ConvertTo-EndpointEventData -Data "simple value"
    Assert-Equal -Actual $data["Data"] -Expected "simple value" -Message "Simple value conversion failed."
}

Invoke-Test -Name "Get-EndpointIdentity returns expected base properties" -ScriptBlock {
    $identity = Get-EndpointIdentity

    Assert-True -Condition ($null -ne $identity.ComputerName) -Message "ComputerName missing."
    Assert-True -Condition ($null -ne $identity.SerialNumber) -Message "SerialNumber missing."

    $properties = $identity.PSObject.Properties.Name

    foreach ($property in @("ComputerName", "SerialNumber", "Manufacturer", "Model", "OSVersion", "OSBuild", "Domain")) {
        Assert-True -Condition ($properties -contains $property) -Message "Missing identity property: $property"
    }
}

Invoke-Test -Name "New-EndpointEventLogPath creates default path" -ScriptBlock {
    $path = New-EndpointEventLogPath -LogRoot $TestRoot
    Assert-True -Condition ($path -like "$TestRoot*") -Message "Generated path did not use TestRoot."
    Assert-True -Condition ($path -like "*.ndjson") -Message "Generated path does not end with .ndjson."
}

Invoke-Test -Name "New-EndpointEventLogPath supports date, serial, and computer name" -ScriptBlock {
    $path = New-EndpointEventLogPath `
        -Name "asset-inventory" `
        -LogRoot $TestRoot `
        -IncludeDate `
        -IncludeSerialNumber `
        -IncludeComputerName

    $fileName = Split-Path -Path $path -Leaf

    Assert-True -Condition ($fileName -like "*.ndjson") -Message "Generated filename does not end with .ndjson."
    Assert-True -Condition ($fileName -match "^\d{8}-") -Message "Generated filename does not start with yyyyMMdd."
    Assert-True -Condition ($fileName -like "*asset-inventory.ndjson") -Message "Generated filename does not include requested name."
}

Invoke-Test -Name "Write-EndpointEvent writes basic INFO event" -ScriptBlock {
    $resultPath = Write-EndpointEvent `
        -Path $TestLogPath `
        -Level INFO `
        -Message "Basic generic INFO event"

    Assert-Equal -Actual $resultPath -Expected $TestLogPath -Message "Write-EndpointEvent returned unexpected path."
    Assert-True -Condition (Test-Path -Path $TestLogPath) -Message "Log file was not created."

    $event = Read-Ndjson -Path $TestLogPath | Select-Object -Last 1

    Assert-Equal -Actual $event.Level -Expected "INFO" -Message "Event level incorrect."
    Assert-Equal -Actual $event.Message -Expected "Basic generic INFO event" -Message "Event message incorrect."
}

Invoke-Test -Name "Write-EndpointEvent writes structured hashtable data" -ScriptBlock {
    Write-EndpointEvent `
        -Path $TestLogPath `
        -Level INFO `
        -Source "Inventory" `
        -EventName "AssetCaptured" `
        -Message "Asset inventory captured" `
        -Data @{
            MachineName = "endpoint-001"
            AssetTag    = "C001HT"
            Room        = "B12"
            Site        = "Auckland"
        } | Out-Null

    $event = Read-Ndjson -Path $TestLogPath | Select-Object -Last 1

    Assert-Equal -Actual $event.Source -Expected "Inventory" -Message "Source incorrect."
    Assert-Equal -Actual $event.EventName -Expected "AssetCaptured" -Message "EventName incorrect."
    Assert-Equal -Actual $event.MachineName -Expected "endpoint-001" -Message "MachineName data missing."
    Assert-Equal -Actual $event.AssetTag -Expected "C001HT" -Message "AssetTag data missing."
    Assert-Equal -Actual $event.Room -Expected "B12" -Message "Room data missing."
    Assert-Equal -Actual $event.Site -Expected "Auckland" -Message "Site data missing."
}

Invoke-Test -Name "Write-EndpointEvent writes PSCustomObject data" -ScriptBlock {
    $data = [pscustomobject]@{
        CheckName = "DiskCheck"
        Status    = "Healthy"
        FreeGB    = 42.7
    }

    Write-EndpointEvent `
        -Path $TestLogPath `
        -Level INFO `
        -Source "HealthCheck" `
        -EventName "DiskCheckCompleted" `
        -Message "Disk check completed" `
        -Data $data | Out-Null

    $event = Read-Ndjson -Path $TestLogPath | Select-Object -Last 1

    Assert-Equal -Actual $event.CheckName -Expected "DiskCheck" -Message "CheckName missing."
    Assert-Equal -Actual $event.Status -Expected "Healthy" -Message "Status missing."
    Assert-Equal -Actual $event.FreeGB -Expected 42.7 -Message "FreeGB missing."
}

Invoke-Test -Name "Write-EndpointEvent writes simple object data" -ScriptBlock {
    Write-EndpointEvent `
        -Path $TestLogPath `
        -Level INFO `
        -Message "Simple data test" `
        -Data "simple value" | Out-Null

    $event = Read-Ndjson -Path $TestLogPath | Select-Object -Last 1

    Assert-Equal -Actual $event.Data -Expected "simple value" -Message "Simple data value missing."
}

Invoke-Test -Name "Write-EndpointEvent preserves supplied CorrelationId" -ScriptBlock {
    $correlationId = "20260716-TEST-CORRELATION"

    Write-EndpointEvent `
        -Path $TestLogPath `
        -Level INFO `
        -Message "Correlation test" `
        -CorrelationId $correlationId | Out-Null

    $event = Read-Ndjson -Path $TestLogPath | Select-Object -Last 1

    Assert-Equal -Actual $event.CorrelationId -Expected $correlationId -Message "CorrelationId was not preserved."
}

Invoke-Test -Name "Write-EndpointEvent generates CorrelationId when omitted" -ScriptBlock {
    Write-EndpointEvent `
        -Path $TestLogPath `
        -Level INFO `
        -Message "Generated correlation test" | Out-Null

    $event = Read-Ndjson -Path $TestLogPath | Select-Object -Last 1

    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($event.CorrelationId)) -Message "Generated CorrelationId missing."
}

Invoke-Test -Name "Write-EndpointEvent includes endpoint identity" -ScriptBlock {
    Write-EndpointEvent `
        -Path $TestLogPath `
        -Level INFO `
        -Message "Endpoint identity test" `
        -IncludeEndpointIdentity | Out-Null

    $event = Read-Ndjson -Path $TestLogPath | Select-Object -Last 1

    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($event.ComputerName)) -Message "ComputerName missing."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($event.SerialNumber)) -Message "SerialNumber missing."
}

Invoke-Test -Name "Write-EndpointEvent includes process info" -ScriptBlock {
    Write-EndpointEvent `
        -Path $TestLogPath `
        -Level INFO `
        -Message "Process info test" `
        -IncludeProcessInfo | Out-Null

    $event = Read-Ndjson -Path $TestLogPath | Select-Object -Last 1

    Assert-True -Condition ($null -ne $event.ProcessId) -Message "ProcessId missing."
    Assert-True -Condition ($null -ne $event.UserName) -Message "UserName missing."
}

Invoke-Test -Name "Write-EndpointEvent prefixes conflicting data fields" -ScriptBlock {
    Write-EndpointEvent `
        -Path $TestLogPath `
        -Level INFO `
        -Message "Collision test" `
        -Data @{
            Level     = "UserLevel"
            Message   = "UserMessage"
            Timestamp = "UserTimestamp"
        } | Out-Null

    $event = Read-Ndjson -Path $TestLogPath | Select-Object -Last 1

    Assert-Equal -Actual $event.Level -Expected "INFO" -Message "Base Level was overwritten."
    Assert-Equal -Actual $event.Message -Expected "Collision test" -Message "Base Message was overwritten."
    Assert-Equal -Actual $event.Data_Level -Expected "UserLevel" -Message "Data_Level missing."
    Assert-Equal -Actual $event.Data_Message -Expected "UserMessage" -Message "Data_Message missing."
    Assert-Equal -Actual $event.Data_Timestamp -Expected "UserTimestamp" -Message "Data_Timestamp missing."
}

Invoke-Test -Name "Write-EndpointInfo wrapper writes INFO" -ScriptBlock {
    Write-EndpointInfo `
        -Path $TestLogPath `
        -Message "Wrapper INFO test" | Out-Null

    $event = Read-Ndjson -Path $TestLogPath | Select-Object -Last 1

    Assert-Equal -Actual $event.Level -Expected "INFO" -Message "Write-EndpointInfo did not write INFO level."
}

Invoke-Test -Name "Write-EndpointWarn wrapper writes WARN" -ScriptBlock {
    Write-EndpointWarn `
        -Path $TestLogPath `
        -Message "Wrapper WARN test" | Out-Null

    $event = Read-Ndjson -Path $TestLogPath | Select-Object -Last 1

    Assert-Equal -Actual $event.Level -Expected "WARN" -Message "Write-EndpointWarn did not write WARN level."
}

Invoke-Test -Name "Write-EndpointError wrapper writes ERROR" -ScriptBlock {
    Write-EndpointError `
        -Path $TestLogPath `
        -Message "Wrapper ERROR test" | Out-Null

    $event = Read-Ndjson -Path $TestLogPath | Select-Object -Last 1

    Assert-Equal -Actual $event.Level -Expected "ERROR" -Message "Write-EndpointError did not write ERROR level."
}

Invoke-Test -Name "Write-EndpointError flattens ErrorRecord" -ScriptBlock {
    try {
        Get-Item "C:\Path\That\Should\Not\Exist\OpenEndpointEventsTest.txt" -ErrorAction Stop
    }
    catch {
        Write-EndpointError `
            -Path $TestLogPath `
            -Source "FileCheck" `
            -EventName "PathAccessFailed" `
            -Message "Expected path access failure" `
            -ErrorRecord $_ `
            -Data @{
                Path = "C:\Path\That\Should\Not\Exist\OpenEndpointEventsTest.txt"
            } | Out-Null
    }

    $event = Read-Ndjson -Path $TestLogPath | Select-Object -Last 1

    Assert-Equal -Actual $event.Level -Expected "ERROR" -Message "ErrorRecord event level incorrect."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($event.ExceptionMessage)) -Message "ExceptionMessage missing."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($event.ExceptionType)) -Message "ExceptionType missing."
    Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($event.FullyQualifiedErrorId)) -Message "FullyQualifiedErrorId missing."
}

Invoke-Test -Name "Write-EndpointInfo can use custom log root and name" -ScriptBlock {
    $customName = "custom-test-log"
    $resultPath = Write-EndpointInfo `
        -LogRoot $TestRoot `
        -Name $customName `
        -Message "Custom root and name test"

    Assert-True -Condition (Test-Path -Path $resultPath) -Message "Custom root/name log file not created."
    Assert-True -Condition ((Split-Path -Path $resultPath -Leaf) -like "*custom-test-log.ndjson") -Message "Custom name not used."
}

Invoke-Test -Name "Multiple writes produce multiple valid NDJSON lines" -ScriptBlock {
    if (Test-Path -Path $SecondLogPath) {
        Remove-Item -Path $SecondLogPath -Force
    }

    1..5 | ForEach-Object {
        Write-EndpointInfo `
            -Path $SecondLogPath `
            -Message "Multi-write test $_" `
            -Data @{
                Sequence = $_
            } | Out-Null
    }

    $lines = Get-Content -Path $SecondLogPath
    Assert-Equal -Actual $lines.Count -Expected 5 -Message "Unexpected NDJSON line count."

    $events = Read-Ndjson -Path $SecondLogPath
    Assert-Equal -Actual $events.Count -Expected 5 -Message "Unexpected parsed event count."
    Assert-Equal -Actual ($events | Select-Object -Last 1).Sequence -Expected 5 -Message "Final sequence value incorrect."
}

Invoke-Test -Name "Generated log file contains valid JSON on every line" -ScriptBlock {
    $lineNumber = 0

    foreach ($line in Get-Content -Path $TestLogPath) {
        $lineNumber++

        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        try {
            $null = $line | ConvertFrom-Json
        }
        catch {
            throw "Invalid JSON on line $lineNumber. $($_.Exception.Message)"
        }
    }
}

Invoke-Test -Name "Help examples are available" -ScriptBlock {
    $help = Get-Help Write-EndpointEvent -Examples

    Assert-True -Condition ($null -ne $help) -Message "Help not returned for Write-EndpointEvent."

    $helpText = $help | Out-String
    Assert-True -Condition ($helpText -match "Write-EndpointEvent") -Message "Help examples do not appear to include Write-EndpointEvent."
}

Write-Host ""
Write-Host "Test summary" -ForegroundColor Cyan
Write-Host "============" -ForegroundColor Cyan

$script:TestResults |
    Sort-Object Status, Name |
    Format-Table Name, Status, Details -AutoSize

$failed = @($script:TestResults | Where-Object { $_.Status -eq "FAIL" })
$passed = @($script:TestResults | Where-Object { $_.Status -eq "PASS" })

Write-Host ""
Write-Host "Passed: $($passed.Count)" -ForegroundColor Green
Write-Host "Failed: $($failed.Count)" -ForegroundColor $(if ($failed.Count -eq 0) { "Green" } else { "Red" })

if ($KeepTestFiles) {
    Write-Host "Test files kept at: $TestRoot" -ForegroundColor Yellow
}
else {
    Remove-Item -Path $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Test files removed." -ForegroundColor Yellow
}

if ($failed.Count -gt 0) {
    exit 1
}

exit 0