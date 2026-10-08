# Offline packages

The USB bootstrap prefers packages in this folder. It does not download installers from GitHub or the public internet during setup.

For how package files fit with configuration, pairing, and sign-in inputs, see the [setup inputs guide](../docs/setup-inputs.md).

Place vendor-signed installers here, then put the matching SHA-256 in `manifest.json`. Setup refuses to install if the file is missing or the computed hash does not match.

## Expected files (current USB image)

| ID | Architecture | Version | File name | SHA-256 |
| --- | --- | --- | --- | --- |
| syncthing | amd64 | SyncTrayzor Portable x64 | `SyncTrayzorPortable-x64.zip` | `2ed9cc53ac83c287e069f8dcfa3ac801daf7d2ac76c93457021f712ff6785662` |
| tailscale | amd64 | 1.102.4 | `tailscale-setup-1.102.4-amd64.msi` | `80eb007e39dfebe17299fa1a09c79a8e1d934f76e0246c0817ebe3af675b7ef6` |

## Sources (manual download, then copy onto the USB)

- SyncTrayzor: official portable x64 Windows zip for the Syncthing UI bundle. The archive is verified before extraction; the bootstrap supports portable archives and preserves the Grid root abstraction.
- Tailscale: [official Windows MSI for the pinned version](https://pkgs.tailscale.com/stable/tailscale-setup-1.102.4-amd64.msi). Setup sets `INSTALLDIR` to `<GridRoot>\bin\tailscale`; its Windows service and state remain system-managed. Setup starts an existing Windows service if Tailscale is already installed and does not log the user out.

## Cache order

1. `<USB>\packages\` (this folder)
2. `<GridRoot>\packages\` (local copy after a successful verify)

Never execute an unverified installer.

The current catalog contains amd64 artifacts only. On ARM64, preflight/setup stops with a missing architecture-specific package instead of substituting an x64 binary.
