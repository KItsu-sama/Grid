# Troubleshooting

## Malformed config

If `config\grid.json` exists but is invalid JSON or an unsupported `schemaVersion`, setup stops. It will not overwrite the file with the example. Fix the JSON or rename it and rerun.

## Temporary mode

`defaultMode: "temporary"` and `-Mode temporary` resolve a USB runtime root but then exit as unsupported. Tailscale is a system component; this release will not install a disposable tailnet client or tear one down on USB eject.

## AUTO drive selection

AUTO uses fixed local disks (`DriveType` 3) with free bytes above `persistent.minimumFreeBytes`. Removable and network drives are skipped. USB bootstrap media is not a valid persistent GridRoot.

To force a location, set `persistent.targetPath` in `config\grid.json` or pass `-TargetPath`.

## Missing packages

Setup looks in `<USB>\packages` then `<GridRoot>\packages`. If the zip/exe is absent or the SHA-256 is `REPLACE_ME` / mismatched, it prints the expected filename and stops. Copy a verified vendor file and update `packages\manifest.json`.

## Tailscale already installed

Setup uses the existing client and service. It will not disconnect an existing tailnet to make the installer look successful. If the client is not logged in and `authenticateInteractively` is true, it starts the vendor login flow.

## Syncthing identity changed

Identity lives in `<GridRoot>\.grid\syncthing`. Deleting that folder creates a new device and requires pairing again. `repair` and rerun `setup` keep an existing cert/key pair.

## PERSONAL GRID ONLINE not printed

That line is reserved for a passing audit: Tailscale connected, Syncthing API up, identity present, folders present, required peer configured **and** connected, folder sync not failed. A configured node with an offline peer is **degraded**, not a failed install. Saved state is kept.

## Pairing wait never finishes

Approve the printed device ID on the seed. Both devices need the same folder IDs from the transferred manifest. Check `.\Grid.ps1 audit`.

## Start without the USB

Persistent mode stores Syncthing, state, and a copy of the manifest under GridRoot. Windows user startup launches `bin\syncthing.exe --home .grid\syncthing` with the GUI on `127.0.0.1`. The USB is not required for daily sync after setup.
