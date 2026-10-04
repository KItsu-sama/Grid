# Personal Grid API

The API is a separate Python service that uses the active Grid configuration.
The Windows bootstrap remains responsible for Tailscale, Syncthing, storage,
and machine setup.

## Run locally

```powershell
python -m pip install -r .\api\requirements.txt
python .\api\main.py
```

The service binds to `127.0.0.1:8000` by default. To make it reachable over
the private Tailscale network, set `PERSONAL_GRID_API_HOST=0.0.0.0` before
starting it. `PERSONAL_GRID_ROOT` can point at the resolved GridRoot so the
API reads `.grid\device.json`; otherwise it reads `config\grid.json` and then
the checked-in example configuration.

Endpoints:

```text
GET  /health
POST /ask  {"message":"hi"}
GET  /agent-admin/status
GET  /agent-admin/devices
```

`/ask` is intentionally a stub until a local model is selected. Messages must
contain between 1 and 8,192 characters; larger messages are rejected during
validation, and all request bodies are limited to 16 KiB. Remote command
execution is not exposed. `/agent-admin/*` requires the same bearer token as the
Agent's loopback admin API and proxies only to `127.0.0.1:8765`; remote
capability requests still use the Tailscale-bound Agent peer API. Keep this
service on loopback or the private tailnet, never expose it publicly.
