@{
    RootModule        = 'OpenEndpointEvents.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '7f98bb9c-3c6a-4b65-9871-7e8e7f0a9d41'
    Author            = 'OpenEndpointEvents contributors'
    CompanyName       = 'OpenEndpointEvents'
    Copyright         = '(c) OpenEndpointEvents contributors'
    Description       = 'Lightweight PowerShell module for writing user-defined endpoint events as daily NDJSON files for simple analytics.'
    PowerShellVersion = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport = @(
        'ConvertTo-SafeFilePart',
        'ConvertTo-EndpointEventLevel',
        'ConvertTo-EndpointEventData',
        'Get-EndpointIdentity',
        'New-EndpointEventLogPath',
        'Write-EndpointEvent',
        'Write-EndpointInfo',
        'Write-EndpointWarn',
        'Write-EndpointError'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    PrivateData = @{
        PSData = @{
            Tags = @(
                'Logging',
                'JSON',
                'NDJSON',
                'Endpoint',
                'Events',
                'Telemetry',
                'Analytics',
                'Grafana',
                'AzureBlob',
                'LogAnalytics',
                'ADX',
                'Education',
                'Homelab'
            )

            ProjectUri   = 'https://github.com/Flock-Master/OpenEndpointEvents'
            LicenseUri   = 'https://github.com/Flock-Master/OpenEndpointEvents/blob/main/LICENSE'
            ReleaseNotes = 'Initial OpenEndpointEvents release with endpoint event logging, daily NDJSON output, endpoint identity enrichment, structured data support, and comment-based help.'
        }
    }
}