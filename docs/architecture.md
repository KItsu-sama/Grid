# Architecture

Personal Grid is one system with two storage targets. The USB holds the bootstrap (launcher, templates, verified packages). Runtime state lives under a resolved **GridRoot**.

| Mode | GridRoot | First release |
| --- | --- | --- |
| `persistent` | Selected local folder, typically `<fixed-drive>\PersonalGrid\` | Implemented |
| `temporary` | `<USB>\PersonalGrid\runtime\` | Path is resolved; install/start is rejected as unsupported |

Modules must not hardcode `D:\PersonalGrid`. They receive a context with `Mode`, `BootstrapRoot`, and `GridRoot`.

## Layout (persistent)

```
<GridRoot>\
  .grid\
    device.json
    install-state.json
    version.json
    syncconfig.json
    logs\
    syncthing\          # Syncthing --home (identity, config.xml, API key)
  bin\
    syncthing.exe
  packages\             # optional verified cache
  ZinoSync\
    Inbox\
    Camera\
    Documents\
    Projects\
    SecondBrain\
    Offline\
```

`config.xml` stays in `.grid\syncthing`. It is never copied into Git or into `syncconfig.json`.

Grid JSON state is written through a unique same-directory temporary file, flushed to disk, and atomically replaced. This prevents partial files and temp-name collisions; concurrent stale writers are still last-writer-wins.

The optional phone-facing API is under `api\`. It reads the active role from
`<GridRoot>\.grid\device.json` when `PERSONAL_GRID_ROOT` is set, falling back
to `config\grid.json`. The bootstrap does not start this service.

## Module flow

`Grid.ps1` parses the command, dotsources `bootstrap\*.ps1`, and calls stages in order:

1. **load** — settings, schema, paths
2. **detect** — OS, drives, network, existing components
3. **mode / GridRoot** — persistent vs temporary storage target
4. **install/prepare** — directories, state, folder templates
5. **tailscale** — detect or hash-verified local package; do not disturb an existing tailnet
6. **syncthing** — dedicated home, stable device identity
7. **configure** — folders, seed manifest, explicit pairing
8. **startup** — Tailscale via its service; Syncthing via current-user startup
9. **audit** — setup complete vs grid online

## Identity vs authorization

A Syncthing device ID identifies a node. It does not authorize a new node. Pairing is a one-time approval on the existing node. See [pairing.md](pairing.md).

## Git

Standard Syncthing project folders are for files, not Git remotes. Keep repositories outside `ZinoSync`.
