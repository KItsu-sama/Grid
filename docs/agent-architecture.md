# PersonalGrid Agent subsystem: architecture and status (v0.1)

The Agent is a subsystem of PersonalGrid, not a separate product or trust authority. PersonalGrid's `.grid/device.json` owns the stable `gridDeviceId`; the Agent's local signing key is bound to that ID and remains separate from Tailscale and Syncthing identities. The supported runtime is the native Go executable; running it requires no Python installation.

The Agent device registry and role/grant authorization live in PersonalGrid's `.grid` state and govern remote capability access. The PowerShell launcher is the product CLI entry point; its Agent subcommand uses the authenticated local admin API. The PersonalGrid API proxies `/agent-admin/*` through the same bearer token to that loopback API. Remote capability requests remain on the Tailscale-bound peer API. Syncthing pairing remains a separate sync-layer approval. The sync manifest can record an explicit Syncthing-ID-to-Grid-ID association, but that metadata does not approve Agent access.

The implementation lives under `PersonalGrid/agent/`; this document is the current architecture reference. Do not install or operate a sibling `grid-agent` product.

## The key decision: Tailscale is the network, Grid is the authority

Your repo already bootstraps Tailscale + Syncthing, and your last note says Tailscale = networking, Syncthing = sync, Grid owns identity/devices/capabilities/permissions/audit. This build follows that. I did **not** build a WireGuard control plane (key distribution, NAT traversal, relays, IP allocation, SSO login, 2FA, node-key expiry). Tailscale already does all of it on top of WireGuard, and reimplementing it is the riskiest thing you could do in a security project.

What Grid adds on top:

```
Identity provider (Google/Microsoft, 2FA)   <- done by Tailscale SSO
  -> Tailscale node (WireGuard keys, rotates on its own)
     -> Grid device identity (device_id + Ed25519 key, separate from WireGuard keys)
        -> Grid approval + role + grants (local registry)
           -> typed capability, validated, audited
```

A request is accepted only if **all** hold: the transport proves the caller (`tailscale whois`) belongs to your IdP account; the node's stable ID matches the registered device; the Ed25519 signature verifies; the timestamp/nonce are fresh; the device is APPROVED and not suspended; the role/grants allow the capability; arguments validate; sensitive ops are confirmed by the human at the target. Reachability alone grants nothing.

`Transport` (`transport/base.py`) is the seam. `TailscaleTransport` is the only real backend; a raw-WireGuard backend could be written later without touching anything above it.

## Layers (as requested)

| Layer | Module |
|---|---|
| Transport | `transport/base.py`, `transport/tailscale.py` |
| Control plane / registry | `internal/agent/registry.go` (SQLite devices, roles, keys, grants) |
| Authentication | `internal/agent/identity.go`, `runtime.go` (Ed25519 and replay checks) |
| Authorization | `internal/agent/policy.go` (role baseline, explicit allow/deny, sensitive set) |
| Capabilities | `internal/agent/policy.go` (typed catalogue; no shell capability) |
| Windows adapter | `internal/agent/adapter.go` (fixed-argument process and power operations) |
| Agent | `internal/agent/runtime.go` (authenticate, authorize, validate, confirm, execute, audit) |
| Audit | `internal/agent/audit.go` (append-only hash chain, redacted bodies) |
| Local API | `internal/agent/local_api.go` (127.0.0.1, bearer token) |
| Peer API | `internal/agent/peer_api.go` (Tailscale-bound `/v1/hello`, `/v1/invoke`, `/v1/rotate`) |
| CLI and daemon | `cmd/grid-agent/`, `internal/agent/cli.go`, `daemon.go` |

Approve, revoke, grants and confirmations exist **only** on the local admin API. A remote device can never approve itself or confirm its own request.

## PersonalGrid CLI

Run Agent administration and local API operations through the PersonalGrid launcher:

```powershell
.\Grid.ps1 agent device list
.\Grid.ps1 agent device approve <device-id> --role CLIENT
.\Grid.ps1 agent device grant <device-id> audio.play
.\Grid.ps1 agent daemon run
```

The launcher supplies the resolved Grid root and the Agent derives local identity, role, and owner from `.grid/device.json`. Agent `init` is disabled in this mode. The API continues to bind admin operations to loopback with a bearer token and peer requests to the Tailscale address. Syncthing pairing remains a separate sync-transport operation; its device ID is not an Agent approval or capability grant.

## Agent command reference

```
.\Grid.ps1 agent daemon run
.\Grid.ps1 agent network status
.\Grid.ps1 agent device list | approve <id|name> --role MAIN|WORKER|CLIENT | revoke <id|name> | grant <id|name> <pattern> [--deny]
.\Grid.ps1 agent confirm list | approve <id> | deny <id>
.\Grid.ps1 agent audit [--limit N]
```

The native CLI currently supports status, device approval/revocation/grants, local confirmation, and audit operations. Peer health controls, diagnostics, and initiating identity-key rotation have not been ported. Revocation is permanent for that identity and clears its grants.

## Roles and capabilities

The authorization policy retains the existing role baselines: MAIN gets files/transfer/media/audio/app.launch/process.read/device.info/environment.read; WORKER gets files list/stat/read/write/mkdir + transfer; CLIENT gets files list/stat/read + transfer/media/audio. The native Windows adapter currently implements only device.info, process.read, process.stop, power.sleep, power.shutdown, environment.read, and allowlisted app.launch; it advertises no other capabilities. Unsupported capabilities remain unavailable even with a grant. Sensitive implemented capabilities require an explicit allow grant **and** a one-time confirmation approved locally at the target (bound to the exact arguments, 120 s, single use). Deny always wins.

Example "phone -> PC": allow `app.launch` only when an application allowlist is configured; sensitive actions such as `power.sleep` require a grant and local confirmation.

## Files and transfer

* Only configured Grid roots are visible; paths are virtual (`shared/music/a.mp3`). Rejected: `..`, absolute paths, drive letters, backslashes, NTFS alternate streams, reserved device names (CON, NUL...), trailing dot/space, `.grid*`, symlink escapes, deleting a root.
* Chunked upload with deterministic session IDs (resume after crash/reconnect), per-chunk SHA-256, whole-file SHA-256 verified before an atomic replace, partial files never visible.
* Conflicts are returned, never silently resolved: the writer sends the hash it last saw (`base_sha256`); if the target differs (checked at begin **and again at commit**, and blind overwrites of different content count too) you get a conflict object with source/target device, path, timestamps, hashes, sizes and both versions plus the options keep_local / keep_remote / keep_both / inspect / manual. Deletes are conflict-checked the same way.
* Download resumes from `.gridpart`, verifies each range and the final hash, and refuses to clobber locally modified files.
* Pause/resume/cancel (`TransferControl`), token-bucket bandwidth limit, priority queue, offline hold + persisted queue (`transfer/queue.py`).
* `sync.diff3(base, local, remote)` gives upload/download/delete/conflict actions with correct deletion propagation. It does not move bytes yet; that is Syncthing's job for now.

## Honest status: what is NOT done

* **Native capability coverage is intentionally limited.** File/transfer, media/audio, peer health monitoring, diagnostics, and initiating identity-key rotation remain in the legacy Python implementation and are not available through the native launcher yet.
* **Android:** only the contract (`AndroidAdapter` + bridge). The real work is a Kotlin app (AudioManager, Intents, Storage Access Framework `FileSystem` implementation) speaking the same `/v1/invoke` envelope. Not started.
* **Not implemented:** filesystem watching, media.stream, file/transfer capabilities, wiring `sync` to actions, `environment.modify`, `services.manage`, `system.settings`, peer health controls, local identity-key rotation, and a Windows service wrapper (`Grid.ps1 start` lifecycle integration is deferred).
* **Transport details:** the peer API is plain HTTP inside the WireGuard tunnel (confidential on the wire via WireGuard; Grid signatures give request authenticity, not extra encryption). Chunks are base64 in JSON (~33% overhead); a binary endpoint is a later optimisation. No rate limiting on the peer API yet.
* **Tailscale JSON field names** (`StableID`, `Peer`, `UserProfile`...) were written from memory of the CLI output and tested against fixtures I wrote, not a live tailnet. Run `tailscale status --json` and `tailscale whois --json <ip>` once and compare.
* Identity key is stored in a user-only file; on Windows wrapping it with DPAPI is a TODO.

## Run the tests

```
cd agent
go test ./...
go build -trimpath -ldflags "-s -w" -o .\bin\grid-agent.exe .\cmd\grid-agent
```

The native Go runtime replaces Python for the Agent daemon and its local/peer APIs. The separate optional PersonalGrid API service under `api/` remains Python-based.
