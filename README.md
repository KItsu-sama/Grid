# Personal Grid

Windows-first USB bootstrap for a persistent Personal Grid node: Tailscale for the network, Syncthing for folders, explicit pairing, honest health.

Temporary USB runtime, Android onboarding, and remote command execution are **out of this release**. The optional phone-facing Grid API lives under `api\` and is not started by the bootstrap.

## USB layout

Copy this repository onto a USB stick. Add vendor packages under `packages\` and pin SHA-256 values in `packages\manifest.json` (see [packages/README.md](packages/README.md)). Do not commit `config\grid.json`, `config\syncconfig.json`, or `tailscale.txt`.

## Before setup

Run `.\Grid.ps1 preflight -Seed` for a first node, or `.\Grid.ps1 preflight` for an additional node. The single [setup inputs guide](docs/setup-inputs.md) maps configuration files, package files, optional metadata, and the information needed for Tailscale sign-in and pairing.

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
