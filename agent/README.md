# Native Grid Agent

The PersonalGrid Agent runtime is built as a self-contained Go executable. Running the Agent requires neither Python nor a separately installed Go runtime. Go 1.26+ is needed only to build from source.

## Build and test

From `PersonalGrid/agent` in PowerShell:

```powershell
.\build.ps1
```

This runs `go test ./...` and writes `bin\grid-agent.exe`. `Grid.ps1 agent ...` launches this bundled executable; setup snapshots it under `.grid\bootstrap\agent\bin`.

## Runtime

The native daemon reads the authoritative device ID, name, role, and owner from `.grid\device.json`, stores its Ed25519 signing identity under `.grid\agent`, reuses the existing SQLite registry at `.grid\device_registry.db`, and writes the hash-chained audit log at `.grid\logs\agent-audit.log`.

The admin API binds to `127.0.0.1` and requires the bearer token in `.grid\agent\admin.token`. Its authenticated `POST /shutdown` route gracefully stops the daemon; `Grid.ps1 uninstall` uses it and refuses to remove state if the Agent does not stop. When Tailscale is running under the configured owner, the peer API binds only to the assigned Tailscale IPv4 address. Peer requests require Tailscale identity, an approved registry entry, a valid Ed25519 signature, a fresh timestamp and nonce, role/grant authorization, typed arguments, and target-side confirmation for sensitive operations.

Optional local adapter settings can be placed in `.grid\agent\config.json` using `apps` (application ID to executable path), `env_readable` (environment variable names), `local_port`, and `peer_port`. This file cannot override the authoritative device identity, role, name, or owner from `.grid\device.json`.

Implemented native capabilities are `device.info`, `process.read`, `process.stop`, `power.sleep`, `power.shutdown`, `environment.read`, and allowlisted `app.launch`. The native runtime does not yet port the Python runtime's file/transfer, media/audio, peer health monitoring, or sync features; it does not advertise those capabilities.
