<#
.SYNOPSIS
    Hotfixes OpenEndpointEvents v1.1 scripts to suppress repeated Import-Module verbose output.

.DESCRIPTION
    Adds Import-OpenEndpointEventsQuiet helper to the module runtime scripts and replaces repeated
    Import-Module OpenEndpointEvents calls with a quiet one-time import.

    This fixes repeated verbose output such as:
        VERBOSE: Loading module from path ...
        VERBOSE: Importing function ...

    Affects:
        Install-OpenEndpointEventsUploader.ps1
        Update-OpenEndpointEventsConfig.ps1
        Upload-EndpointEvents.ps1

.EXAMPLE
    .\Apply-OEEVerboseImportHotfix.ps1

.EXAMPLE
    .\Apply-OEEVerboseImportHotfix.ps1 -RepoRoot "C:\Temp\repos\OpenEndpointEvents"
#>

[CmdletBinding()]
param(
    [string]$RepoRoot
)

$ErrorActionPreference = "Stop"

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)

    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-LatestOpenEndpointEventsModuleBase {
    $module = Get-Module -ListAvailable OpenEndpointEvents |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if (-not $module) {
        throw "OpenEndpointEvents module is not installed."
    }

    return $module.ModuleBase
}

function Add-QuietImportHelper {
    param(
        [string]$Content
    )

    if ($Content -match "function\s+Import-OpenEndpointEventsQuiet") {
        return $Content
    }

    $helper = @'

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

'@

    if ($Content -match '\$ErrorActionPreference\s*=\s*"Stop"') {
        return ($Content -replace '(\$ErrorActionPreference\s*=\s*"Stop")', "`$1$helper")
    }

    return "$helper`r`n$Content"
}

function Repair-OEEScript {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        return [pscustomobject]@{
            Path   = $Path
            Status = "Missing"
        }
    }

    $original = Get-Content -Path $Path -Raw
    $content = $original

    $content = Add-QuietImportHelper -Content $content

    # Replace direct quiet-eligible imports.
    $content = $content -replace 'Import-Module\s+OpenEndpointEvents\s+-ErrorAction\s+SilentlyContinue', 'Import-OpenEndpointEventsQuiet'

    # Replace force imports in installer/update/upload scripts.
    $content = $content -replace 'Import-Module\s+OpenEndpointEvents\s+-Force', 'Import-OpenEndpointEventsQuiet'

    # Replace any already-expanded import blocks if present.
    $content = $content -replace 'Import-Module\s+\$module\.Path\s+`\s*\r?\n\s+-Force\s+`\s*\r?\n\s+-Global\s+`\s*\r?\n\s+-ErrorAction\s+Stop\s+`\s*\r?\n\s+-Verbose:\$false', 'Import-OpenEndpointEventsQuiet'

    if ($content -ne $original) {
        Copy-Item -Path $Path -Destination "$Path.bak" -Force
        Set-Content -Path $Path -Value $content -Encoding UTF8

        return [pscustomobject]@{
            Path   = $Path
            Status = "Updated"
        }
    }

    return [pscustomobject]@{
        Path   = $Path
        Status = "AlreadyPatched"
    }
}

function Test-PowerShellSyntax {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -Path $Path)) {
        return
    }

    $tokens = $null
    $errors = $null

    [System.Management.Automation.Language.Parser]::ParseFile(
        $Path,
        [ref]$tokens,
        [ref]$errors
    ) | Out-Null

    if ($errors.Count -gt 0) {
        throw "Syntax errors found in $Path. $($errors | Out-String)"
    }
}

if (-not (Test-IsAdministrator)) {
    throw "Run this hotfix from an elevated PowerShell session."
}

$targets = New-Object System.Collections.Generic.List[string]

# Installed module package scripts
$moduleBase = Get-LatestOpenEndpointEventsModuleBase
$moduleScriptRoot = Join-Path $moduleBase "Scripts"

$targets.Add((Join-Path $moduleScriptRoot "Install-OpenEndpointEventsUploader.ps1"))
$targets.Add((Join-Path $moduleScriptRoot "Update-OpenEndpointEventsConfig.ps1"))
$targets.Add((Join-Path $moduleScriptRoot "Upload-EndpointEvents.ps1"))

# ProgramData runtime scripts
$runtimeScriptRoot = "C:\ProgramData\OpenEndpointEvents\Scripts"

$targets.Add((Join-Path $runtimeScriptRoot "Install-OpenEndpointEventsUploader.ps1"))
$targets.Add((Join-Path $runtimeScriptRoot "Update-OpenEndpointEventsConfig.ps1"))
$targets.Add((Join-Path $runtimeScriptRoot "Upload-EndpointEvents.ps1"))

# Optional repo scripts
if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
    $repoModuleScriptRoot = Join-Path $RepoRoot "src\OpenEndpointEvents\Scripts"

    $targets.Add((Join-Path $repoModuleScriptRoot "Install-OpenEndpointEventsUploader.ps1"))
    $targets.Add((Join-Path $repoModuleScriptRoot "Update-OpenEndpointEventsConfig.ps1"))
    $targets.Add((Join-Path $repoModuleScriptRoot "Upload-EndpointEvents.ps1"))
}

$results = foreach ($target in ($targets | Select-Object -Unique)) {
    Repair-OEEScript -Path $target
}

foreach ($target in ($targets | Select-Object -Unique)) {
    if (Test-Path -Path $target) {
        Test-PowerShellSyntax -Path $target
    }
}

$results | Format-Table Path, Status -AutoSize

Write-Host ""
Write-Host "Hotfix completed." -ForegroundColor Green
Write-Host "Backups were created beside updated files with .bak extension." -ForegroundColor Yellow