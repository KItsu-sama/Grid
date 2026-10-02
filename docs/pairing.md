# Pairing

A generated Syncthing device ID lets another node *identify* this machine. It does not make the two devices trust each other.

For the complete map of setup files and prerequisites, see [setup inputs](setup-inputs.md).

## First (seed) node

1. Copy vendor packages into `packages\` and fill SHA-256 values in `packages\manifest.json`.
2. From the USB: `.\Grid.ps1 setup -Seed`
3. Complete Tailscale sign-in if prompted. Setup will not log you out of an existing tailnet.
4. Syncthing creates an identity under `<GridRoot>\.grid\syncthing`. That identity is reused on later runs.
5. Setup writes `config\syncconfig.json` (on the USB, if writable) and `<GridRoot>\.grid\syncconfig.json`. The manifest contains the seed device ID and folder IDs. It does not contain private keys, GUI API keys, or Tailscale auth keys.

Machine-specific secrets stay in `config\secret.json`, while the generated `syncconfig.json` remains the non-secret pairing manifest. `syncconfig.json` is gitignored. Cloning the repo onto another PC does not transfer the seed.

## Second node

1. Copy the generated `syncconfig.json` onto the new USB (or next to the launcher at `config\syncconfig.json`).
2. Run `.\Grid.ps1 setup` **without** `-Seed`. Missing manifest is an error, not a second silent seed.
3. The launcher prints this node's Syncthing device ID.
4. On the seed, add/approve that device ID once (Syncthing UI on localhost, or equivalent).
5. The new node waits until it sees the seed connected and folder IDs match.
6. Later `.\Grid.ps1 start` reuses saved configuration and does not regenerate IDs.

## What this release will not do

- Auto-accept every device that knows the seed ID
- Trust a device ID as an authorization token
- Expose the Syncthing GUI on the tailnet
