# Architecture

OpenEndpointEvents is split into separate responsibilities.

## Core logger

```text
OpenEndpointEvents
```

Purpose:

```text
Write structured local endpoint events to daily NDJSON files.
```

The core module does not upload data and does not require Azure.

## Uploader

```text
OpenEndpointEvents.Uploader
```

Purpose:

```text
Upload local OpenEndpointEvents NDJSON files to a configured target.
```

Initial target:

```text
Azure Blob Storage
```

## Basic flow

```text
PowerShell script
  ↓
OpenEndpointEvents
  ↓
C:\ProgramData\OpenEndpointEvents\Logs
  ↓
OpenEndpointEvents.Uploader
  ↓
Upload target
```

## Design principle

The logger should stay simple and stable.

Upload, scheduling, config refresh, secrets, and transport are separate concerns.
