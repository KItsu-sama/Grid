# Pairing

A generated Syncthing device ID lets another node *identify* this machine. It does not make the two devices trust each other.

For the complete map of setup files and prerequisites, see [setup inputs](setup-inputs.md).

## First (seed) node

Before setup, set `can_be_main: true` in the trusted seed's local `config/grid.json`. Leave `is_root: false` for a fresh install; `is_root` controls local reset behavior, not authority.

1. Copy vendor packages into `packages\` and fill SHA-256 values in `packages\manifest.json`.
2. From the USB: `.\Grid.ps1 setup -Seed`
3. Complete Tailscale sign-in if prompted. Setup will not log you out of an existing tailnet.
4. Syncthing creates an identity under `<GridRoot>\.grid\syncthing`. That identity is reused on later runs.
5. Setup writes `config\syncconfig.json` (on the USB, if writable) and `<GridRoot>\.grid\syncconfig.json`. The manifest contains the seed device ID and folder IDs. It does not contain private keys, GUI API keys, or Tailscale auth keys.

`config\secret.json` is not read by this release and is not required. Machine identity is saved under `<GridRoot>\.grid`; `syncconfig.json` is gitignored. Cloning the repo onto another PC does not transfer the seed.

## Second node

1. Copy the generated `syncconfig.json` onto the new USB (or next to the launcher at `config\syncconfig.json`).
2. Run `.\Grid.ps1 setup` **without** `-Seed`. Missing manifest is an error, not a second silent seed.
3. The launcher prints this node's Syncthing device ID.
4. On the seed, explicitly approve the printed device ID and share the manifest folders:

	```powershell
	.\Grid.ps1 approve-peer -PeerId '<printed device ID>' -PeerName 'Laptop'
	```

	This adds the device and shares only the folders named in `syncconfig.json`. It does not enable blanket folder auto-accept.
5. The new node waits until it sees the seed connected and the shared folders begin syncing. Audit reports initial scanning/syncing as pending.
6. Later `.\Grid.ps1 start` reuses saved configuration and does not regenerate IDs.

## What this release will not do

- Auto-accept every device that knows the seed ID
- Trust a device ID as an authorization token
- Expose the Syncthing GUI on the tailnet

Nodes with `can_be_main: false` cannot seed or approve peers. Their manifest folders are configured `sendonly`: local edits are submitted to peers, while remote changes are not applied locally. This is not a content sandbox; a peer can still submit edits or deletions to shared files on the main. Do not share authoritative data with a device you do not trust to edit it.
