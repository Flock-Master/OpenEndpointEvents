# \# OpenEndpointEvents

# 

# OpenEndpointEvents is a lightweight PowerShell module for writing user-defined endpoint events as daily NDJSON files for simple analytics.

# 

# It is designed for home labs, education computer rooms, small businesses, MSPs, AVD estates, and enterprise endpoints.

# 

# \## Features

# 

# \- Writes one JSON event per line using NDJSON

# \- Supports INFO, WARN, ERROR, DEBUG, TRACE, and FATAL levels

# \- Supports arbitrary structured data

# \- Can enrich events with endpoint identity

# \- Creates daily endpoint event files

# \- Works with scheduled tasks

# \- Designed for Azure Blob Storage, Log Analytics, Azure Data Explorer, Grafana, and Power BI

# 

# \## Quick start

# 

# ```powershell

# Install-Module OpenEndpointEvents

# Import-Module OpenEndpointEvents

# 

# Write-EndpointInfo -Message "Script started"

