# Personal Grid

Windows-first(for now) USB bootstrap for a persistent Personal Grid node: Tailscale for the network, Syncthing for folders, explicit pairing, honest health.

Temporary USB runtime, Android onboarding, and remote command execution are **out of this release**. The optional phone-facing Grid API lives under `api\` and is not started by the bootstrap.

## USB layout

Copy this repository onto a USB stick. Add vendor packages under `packages\` and pin SHA-256 values in `packages\manifest.json` (see [packages/README.md](packages/README.md)). Do not commit `config\grid.json`, `config\syncconfig.json`, or `tailscale.txt`.

## Before setup

Run `.\Grid.ps1 preflight -Seed` for a first node, or `.\Grid.ps1 preflight` for an additional node. The single [setup inputs guide](docs/setup-inputs.md) maps configuration files, package files, optional metadata, and the information needed for Tailscale sign-in and pairing.
Set `can_be_main: true` only in the trusted main device's local `config/grid.json`; the example defaults to false.

## Commands

```powershell
.\Grid.ps1 preflight -Seed
powershell -ExecutionPolicy Bypass -File .\Grid.ps1 setup -Seed
.\Grid.ps1 start
.\Grid.ps1 stop
.\Grid.ps1 status
.\Grid.ps1 audit
.\Grid.ps1 repair
.\Grid.ps1 approve-peer -PeerId '<Syncthing device ID>' -PeerName 'Laptop'
.\Grid.ps1 uninstall
# Add a removal switch only when the corresponding user data should be deleted.
.\Grid.ps1 uninstall -RemoveData
.\Grid.ps1 uninstall -RemoveDefaultSync
```

| Command | Behavior |
| --- | --- |
| `preflight` | Report blockers only (or `No blockers found`); never installs, starts services, or opens sign-in |
| `setup` | Load → detect → persistent GridRoot → prepare → Tailscale → Syncthing identity → configure/pair → startup → audit |
| `start` | Start an already-installed Tailscale service if present and start Syncthing with `--home` under GridRoot; never install or sign in |
| `stop` | Stop this node's Syncthing only (does not log out Tailscale) |
| `status` / `audit` | Read-only health checks; they do not start Syncthing. Scanning/syncing folders are pending; actual failures return a nonzero exit code |
| `repair` | Recreate missing folders/files, restart components, keep Syncthing identity |
| `approve-peer` | On the seed, explicitly trust a supplied device ID and share only folders from the seed manifest |
| `uninstall` | Stop Syncthing and remove Grid runtime files/startup shortcut; preserve synced files and Tailscale. `-RemoveData` deletes configured Grid folders; `-RemoveDefaultSync` separately deletes `%USERPROFILE%\Sync` |

Optional: `-Mode persistent|temporary`, `-TargetPath D:\PersonalGrid`, `-NonInteractive`.

`can_be_main` defaults to false. Only the trusted main device should enable it. Non-main devices without this capability use send-only folders: they can submit local edits but cannot administer peers or apply remote file changes locally. This does not prevent a peer from changing shared content on the main.

## API

Install and run the optional FastAPI service with:

```powershell
python -m pip install -r .\api\requirements.txt
$env:PERSONAL_GRID_ROOT = 'D:\PersonalGrid'
$env:PERSONAL_GRID_API_HOST = '0.0.0.0'
python .\api\main.py
```

It exposes `/health` and the Phase 5 stub `/ask`. Keep the host at
`127.0.0.1` unless access over the private Tailscale network is intentional.

## Runtime

Persistent GridRoot is chosen with AUTO (fixed local disk, most free bytes above the configured minimum) unless `targetPath` / `-TargetPath` is set. Removable and network drives are excluded.

Syncthing GUI binds to `127.0.0.1` only. Identity lives in `<GridRoot>\.grid\syncthing` and is never written into the seed manifest.

## Tests

```powershell
Invoke-Pester .\tests
```

Tests use Pester 3.4-compatible assertions (`Should Be`) so they run on a stock Windows PowerShell module install.

## Common Commands

Run these commands from the Grid repository directory in **PowerShell**.

> For initial installation and operations that modify Windows services or system components, use **PowerShell as Administrator**.

### Check Before Installing

Run a preflight check without making changes:

```powershell
.\Grid.ps1 preflight -Seed
```

This checks whether the machine is ready for Grid setup and reports blockers without installing or changing the system.

---

### Install Grid

Install Grid as the main/seed node:

```powershell
.\Grid.ps1 setup -Seed
```

Install Grid as a normal node:

```powershell
.\Grid.ps1 setup
```

Persistent installation with a specific location:

```powershell
.\Grid.ps1 setup -Mode persistent -TargetPath "D:\PersonalGrid"
```

Temporary mode:

```powershell
.\Grid.ps1 setup -Mode temporary
```

For the first installation, use the normal interactive mode so that required authentication and pairing steps can be completed manually.

---

### Start / Stop Grid

Start Grid services:

```powershell
.\Grid.ps1 start
```

Stop Grid services:

```powershell
.\Grid.ps1 stop
```

Stopping Grid does **not** log the machine out of Tailscale.

---

### Check Grid Status

Show the current Grid state:

```powershell
.\Grid.ps1 status
```

Run a more complete health check:

```powershell
.\Grid.ps1 audit
```

Use `audit` when troubleshooting or verifying that the Grid is actually online.

---

### Grid Agent

The Agent is an optional native PersonalGrid subsystem. Build it once with Go 1.26+; running it has no Python or Go runtime dependency:

```powershell
.\agent\build.ps1
.\Grid.ps1 agent daemon run
```

The Agent reads its device ID, role, and owner from the active `.grid\device.json`. Its local admin API is loopback-only and bearer-protected; remote capability requests use the Tailscale-bound peer API. Manage devices, grants, confirmations, and audit through the PersonalGrid command surface:

```powershell
.\Grid.ps1 agent device list
.\Grid.ps1 agent device approve <device-id> --role CLIENT
.\Grid.ps1 agent device grant <device-id> app.launch
.\Grid.ps1 agent audit
```

Agent startup is currently explicit; the existing `Grid.ps1 start` and `stop` lifecycle remains unchanged.

---

### Syncthing Pairing

Show or obtain the local Syncthing device ID using the status/setup output, then approve another device explicitly:

```powershell
.\Grid.ps1 approve-peer -PeerId "<DEVICE_ID>" -PeerName "Laptop"
```

When the peer's Grid ID is known, record the association without granting Agent capabilities:

```powershell
.\Grid.ps1 approve-peer -PeerId "<SYNCTHING_DEVICE_ID>" -PeerName "Laptop" -GridDeviceId "<GRID_DEVICE_ID>"
```

Example:

```powershell
.\Grid.ps1 approve-peer -PeerId "ABC1234-..." -PeerName "My-Laptop"
```

Only approve devices that you recognize.

---

### Repair

Attempt to repair a previously installed Grid:

```powershell
.\Grid.ps1 repair
```

Use this when Grid was previously installed but a component is no longer working correctly.

---

### Uninstall

Remove the Grid installation:

```powershell
.\Grid.ps1 uninstall
```

Remove the Grid installation and its runtime data:

```powershell
.\Grid.ps1 uninstall -RemoveData
```

Use `-RemoveData` carefully because it removes Grid-managed runtime data.

---

### Non-Interactive Mode

For automation or scripted deployment:

```powershell
.\Grid.ps1 setup -NonInteractive
```

Non-interactive mode should only be used when all required configuration and authentication prerequisites are already available.

---

### Typical First-Time Setup

For a new Windows machine, the recommended sequence is:

```powershell
# 1. Check the machine
.\Grid.ps1 preflight -Seed

# 2. Install and configure Grid
.\Grid.ps1 setup -Seed

# 3. Start Grid if it is not already running
.\Grid.ps1 start

# 4. Check the result
.\Grid.ps1 status

# 5. Run the full health check
.\Grid.ps1 audit
```

If Syncthing requires another device to be approved:

```powershell
.\Grid.ps1 approve-peer -PeerId "<DEVICE_ID>" -PeerName "<DEVICE_NAME>"
```

Then run:

```powershell
.\Grid.ps1 audit
```

A successful installation should end with Grid reporting a healthy/online state.

---

### Troubleshooting Sequence

If something is not working, start with:

```powershell
.\Grid.ps1 status
```

Then:

```powershell
.\Grid.ps1 audit
```

If the installation itself is broken:

```powershell
.\Grid.ps1 repair
```

For a completely fresh installation, uninstall first:

```powershell
.\Grid.ps1 uninstall
```

Then run:

```powershell
.\Grid.ps1 preflight -Seed
.\Grid.ps1 setup -Seed
```

### Command Summary

| Command                 | Purpose                                         |
| ----------------------- | ----------------------------------------------- |
| `preflight`             | Check prerequisites without changing the system |
| `setup`                 | Install/configure Grid                          |
| `start`                 | Start Grid services                             |
| `stop`                  | Stop Grid services                              |
| `status`                | Show current Grid state                         |
| `audit`                 | Perform a complete health check                 |
| `approve-peer`          | Explicitly approve a Syncthing device           |
| `repair`                | Repair an existing installation                 |
| `uninstall`             | Remove Grid                                     |
| `uninstall -RemoveData` | Remove Grid and its runtime data                |

