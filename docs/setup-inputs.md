# Setup inputs

Use this page as the map of files and information needed before setup. For a first node, run `.\Grid.ps1 preflight -Seed`; for an additional node, run `.\Grid.ps1 preflight`. Preflight is read-only: it reports blockers and setup actions without installing software, starting services, or opening sign-in.

## File map

| Path | Purpose | Required input? |
| --- | --- | --- |
| `config/grid.example.json` | Safe default settings. Used automatically when `config/grid.json` is absent. | No editing required. |
| `config/grid.json` | Local settings override. Copy the example here only to customize values such as storage location or enabled folders. | Optional. |
| `config/secret.example.json` | Safe template for local machine-specific values such as the seed device ID and device name. | Optional template. |
| `config/secret.json` | Local-only secret store for machine-specific values. Keep only the real device name/ID and other secrets that must not be committed. | Required locally when the machine-specific secret values are used. |
| `config/syncconfig.example.json` | Template used to generate the first node's pairing manifest. | No editing required. |
| `config/syncconfig.json` | Generated on the seed; copy it to the USB for every additional node. | Required for an additional node. |
| `packages/manifest.json` | Package catalog and expected SHA-256 hashes. | Required when an installer is needed; keep hashes accurate. |
| `packages/<vendor installer>` | Offline vendor installer for Tailscale or Syncthing when it is not already installed. | Conditional. Setup does not download installers. |
| `tailscale.txt` | Optional Tailscale account-email metadata copied into local device metadata. | Optional; never used for sign-in. |

`config/grid.json` is a local override; `config/syncconfig.json` is generated on the seed; `config/secret.json` is the local-only machine-specific secret store. Vendor installers, local metadata, and machine-specific values should stay out of Git. Do not commit any of them.

## Host and storage

Use Windows PowerShell 5.1. Persistent setup needs a fixed local drive with at least 10 GiB free by default. AUTO chooses the eligible drive with the most free space; use `-TargetPath` or `persistent.targetPath` in `config/grid.json` to choose another location.

## First and additional nodes

For the first node, run `.\Grid.ps1 setup -Seed`. It creates the seed manifest; no `syncconfig.json` needs to be provided in advance.

For an additional node, copy the seed's generated `config/syncconfig.json` onto this USB at that same path, then run `.\Grid.ps1 setup` without `-Seed`. See [the pairing steps](pairing.md) for approval and connection checks.

## Tailscale sign-in

Have internet access for first-time authentication. If sign-in is needed, setup opens Tailscale's own UI. Choose an identity authorized for the tailnet; Google/Gmail is an option only if that tailnet offers it. Personal Grid does not ask for or store a Gmail password, Tailscale auth key, or other sign-in credential. `tailscale.txt` is optional metadata and is not an authentication method.

For exact installer names, versions, and checksums, see [the offline package guide](../packages/README.md). For supported settings and storage defaults, see [the example configuration](../config/grid.example.json).
