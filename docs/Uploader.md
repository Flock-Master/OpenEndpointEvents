# Uploader

Uploading is handled by the separate module:

```text
OpenEndpointEvents.Uploader
```

## Install

```powershell
Install-Module OpenEndpointEvents.Uploader -Scope AllUsers
```

## Install uploader runtime

```powershell
Install-EndpointEventUploader `
    -ConfigUri "<remote-uploader-config-json-url>" `
    -StartNow `
    -ForceInstall `
    -Verbose
```

## Manual upload

```powershell
Invoke-EndpointEventUpload `
    -Now `
    -Window AllChanged `
    -ForceUpload `
    -Verbose
```

## Refresh config

```powershell
Update-EndpointEventUploaderConfig `
    -Force `
    -ApplySchedule `
    -Verbose
```

## Default paths

```text
C:\ProgramData\OpenEndpointEvents\Upload\Config
C:\ProgramData\OpenEndpointEvents\Upload\State
C:\ProgramData\OpenEndpointEvents\Upload\Scripts
```

## Initial target

The initial uploader target is Azure Blob Storage.

Future uploader targets may include:

```text
SMB
SFTP
generic HTTPS
S3-compatible storage
MinIO
OpenEndpointEvents platform services
```
