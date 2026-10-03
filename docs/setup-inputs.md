# Setup inputs

Use this page as the map of files and information needed before setup. For a first node, run `.\Grid.ps1 preflight -Seed`; for an additional node, run `.\Grid.ps1 preflight`. Preflight is read-only: it reports blockers and setup actions without installing software, starting services, or opening sign-in.

## File map

| Path | Purpose | Required input? |
| --- | --- | --- |
| `config/grid.example.json` | Safe default settings. Used automatically when `config/grid.json` is absent. | No editing required. |
| `config/grid.json` | Local settings override. Copy the example here only to customize values such as storage location or enabled folders. | Optional. |
| `config/syncconfig.example.json` | Template used to generate the first node's pairing manifest. | No editing required. |
| `config/syncconfig.json` | Generated on the seed; copy it to the USB for every additional node. | Required for an additional node. |
| `packages/manifest.json` | Package catalog and expected SHA-256 hashes. | Required when an installer is needed; keep hashes accurate. |
| `packages/<vendor installer>` | Offline vendor installer for Tailscale or Syncthing when it is not already installed. | Conditional. Setup does not download installers. |
| `tailscale.txt` | Optional Tailscale account-email metadata copied into local device metadata. | Optional; never used for sign-in. |

`config/grid.json` is a local override and `config/syncconfig.json` is generated on the seed. `config/secret.json` is not read by this release and is not required; do not put credentials there. Vendor installers and local metadata should stay out of Git.

`can_be_main` defaults to `false`. Set it to `true` only in the local settings of a trusted main-capable device; `device.isMain: true` requires this capability. Keep `is_root: false` for a fresh install unless you intentionally want to reset an existing root installation.

## Host and storage

Use Windows PowerShell 5.1. Persistent setup needs a fixed local drive with at least 10 GiB free by default. AUTO chooses the eligible drive with the most free space; use `-TargetPath` or `persistent.targetPath` in `config/grid.json` to choose another location.

## First and additional nodes

For the first node, run `.\Grid.ps1 setup -Seed`. It creates the seed manifest; no `syncconfig.json` needs to be provided in advance.

For an additional node, copy the seed's generated `config/syncconfig.json` onto this USB at that same path, then run `.\Grid.ps1 setup` without `-Seed`. On the seed, run `approve-peer` with the new node's printed Syncthing device ID to explicitly add the peer and share manifest folders. See [the pairing steps](pairing.md) for details.

## Tailscale sign-in

Have internet access for first-time authentication. If sign-in is needed, setup opens Tailscale's own UI. Choose an identity authorized for the tailnet; Google/Gmail is an option only if that tailnet offers it. Personal Grid does not ask for or store a Gmail password, Tailscale auth key, or other sign-in credential. `tailscale.txt` is optional metadata and is not an authentication method.

For exact installer names, versions, and checksums, see [the offline package guide](../packages/README.md). For supported settings and storage defaults, see [the example configuration](../config/grid.example.json).
