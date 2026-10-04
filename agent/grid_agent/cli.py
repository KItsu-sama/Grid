"""`grid` command line. Talks only to the local admin API (127.0.0.1, bearer token)."""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

import httpx

from .config import GridConfig
from .identity import DeviceIdentity, load_personal_grid_device_id
from .protocol import Role


def default_state_dir() -> Path:
    if os.environ.get("GRID_STATE_DIR"):
        return Path(os.environ["GRID_STATE_DIR"])
    if os.environ.get("PERSONAL_GRID_ROOT"):
        return Path(os.environ["PERSONAL_GRID_ROOT"]) / ".grid" / "agent"
    base = os.environ.get("LOCALAPPDATA") if sys.platform == "win32" else None
    return Path(base or Path.home()) / ("Grid" if base else ".grid")


class Api:
    def __init__(self, cfg: GridConfig, client: httpx.Client | None = None):
        self.c = client or httpx.Client(base_url=f"http://127.0.0.1:{cfg.local_port}", timeout=15,
                                        headers={"Authorization": f"Bearer {cfg.admin_token()}"})

    def req(self, method: str, path: str, **kw):
        try:
            r = self.c.request(method, path, **kw)
        except httpx.HTTPError as e:
            raise SystemExit(f"cannot reach the Grid daemon ({e.__class__.__name__}); is `grid daemon run` running?")
        if r.status_code >= 400:
            raise SystemExit(f"error {r.status_code}: {r.json().get('detail', r.text) if r.content else ''}")
        return r.json()


def _table(rows: list[dict], cols: list[str]) -> str:
    if not rows:
        return "(none)"
    w = {c: max(len(c), *(len(str(r.get(c, ""))) for r in rows)) for c in cols}
    line = lambda r: "  ".join(str(r.get(c, "")).ljust(w[c]) for c in cols)
    return "\n".join([line({c: c.upper() for c in cols}), *map(line, rows)])


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="grid")
    p.add_argument("--state-dir", type=Path, default=None)
    p.add_argument("--json", action="store_true", help="machine-readable output")
    sub = p.add_subparsers(dest="group", required=True)

    i = sub.add_parser("init", help="create config + device identity")
    i.add_argument("--name", required=True)
    i.add_argument("--role", choices=[r.value for r in Role], default="CLIENT")
    i.add_argument("--owner", required=True, help="identity-provider login that owns this Grid (e.g. you@gmail.com)")
    i.add_argument("--root", action="append", default=[], metavar="NAME=PATH")

    d = sub.add_parser("daemon").add_subparsers(dest="cmd", required=True)
    d.add_parser("run")

    n = sub.add_parser("network").add_subparsers(dest="cmd", required=True)
    n.add_parser("status"); n.add_parser("diagnose")
    rk = n.add_parser("rotate-key"); rk.add_argument("--wireguard", action="store_true",
                                                     help="also force a fresh network node key (interactive IdP sign-in)")

    dv = sub.add_parser("device").add_subparsers(dest="cmd", required=True)
    dv.add_parser("list")
    a = dv.add_parser("approve"); a.add_argument("device"); a.add_argument("--role", choices=[r.value for r in Role], default="CLIENT")
    r = dv.add_parser("revoke"); r.add_argument("device")
    g = dv.add_parser("grant"); g.add_argument("device"); g.add_argument("pattern"); g.add_argument("--deny", action="store_true")

    pe = sub.add_parser("peer").add_subparsers(dest="cmd", required=True)
    pe.add_parser("list")
    for c in ("connect", "disconnect"):
        pe.add_parser(c).add_argument("device")

    cf = sub.add_parser("confirm").add_subparsers(dest="cmd", required=True)
    cf.add_parser("list")
    for c in ("approve", "deny"):
        cf.add_parser(c).add_argument("id")

    au = sub.add_parser("audit"); au.add_argument("--limit", type=int, default=20)
    return p


def main(argv: list[str] | None = None, api_factory=Api, out=print) -> int:
    ns = build_parser().parse_args(argv)
    sd = ns.state_dir or default_state_dir()
    show = (lambda o, text: out(json.dumps(o, indent=2))) if ns.json else (lambda o, text: out(text))

    if ns.group == "init":
        if os.environ.get("PERSONAL_GRID_ROOT"):
            raise SystemExit("Agent init is managed by PersonalGrid setup; use Grid.ps1 setup first.")
        roots = dict(x.split("=", 1) for x in ns.root)
        cfg = GridConfig(sd, ns.name, Role(ns.role), ns.owner, roots)
        cfg.save(); cfg.admin_token()
        ident = DeviceIdentity.load_or_create(sd, load_personal_grid_device_id())
        show({"device_id": ident.device_id, "state_dir": str(sd)}, f"initialised {ns.name} ({ident.device_id}) in {sd}")
        return 0

    cfg = GridConfig.load(sd)
    if ns.group == "daemon":
        from .daemon import run
        run(cfg)
        return 0
    api = api_factory(cfg)

    if ns.group == "network":
        if ns.cmd == "status":
            s = api.req("GET", "/status")
            n = s["network"]
            show(s, f"device   {s['name']} [{s['role']}] {s['device_id'][:8]}\n"
                    f"network  {'UP' if n['running'] and n['logged_in'] else 'DOWN'} ({n['detail']}) "
                    f"{','.join(n['addresses'])} owner={n['owner']}\n"
                    f"devices  {s['devices']}")
        elif ns.cmd == "diagnose":
            res = api.req("GET", "/diagnose")
            show(res, "\n".join(f"[{'ok' if c['ok'] else 'FAIL'}] {c['check']} {c['detail']}".rstrip() for c in res))
            return 0 if all(c["ok"] for c in res) else 1
        else:
            res = api.req("POST", "/identity/rotate")
            show(res, f"identity key rotated; announced to {res['announced_to']}, unreachable {res['unreachable']}")
            if ns.wireguard:
                from .transport.tailscale import TailscaleTransport
                TailscaleTransport().reauthenticate()
    elif ns.group == "device":
        if ns.cmd == "list":
            rows = api.req("GET", "/devices")
            show(rows, _table([{**r, "id": r["device_id"][:8]} for r in rows], ["id", "name", "role", "state", "online", "address"]))
        elif ns.cmd == "approve":
            r = api.req("POST", f"/devices/{ns.device}/approve", json={"role": ns.role})
            show(r, f"approved {r['name']} as {r['role']}")
        elif ns.cmd == "revoke":
            r = api.req("POST", f"/devices/{ns.device}/revoke")
            show(r, f"revoked {r['name']}")
        else:
            r = api.req("POST", f"/devices/{ns.device}/grants",
                        json={"pattern": ns.pattern, "effect": "deny" if ns.deny else "allow"})
            show(r, f"grants: {r['grants']}")
    elif ns.group == "peer":
        if ns.cmd == "list":
            rows = api.req("GET", "/peers")
            show(rows, _table([{**r, "id": r["device_id"][:8],
                                "latency": "-" if r["latency"] is None else f"{r['latency']*1000:.0f}ms",
                                "link": {None: "-", True: "relay", False: "direct"}[r["relayed"]]} for r in rows],
                              ["id", "name", "state", "online", "latency", "link", "suspended"]))
        else:
            r = api.req("POST", f"/peers/{ns.device}/{ns.cmd}")
            show(r, json.dumps(r))
    elif ns.group == "confirm":
        if ns.cmd == "list":
            rows = api.req("GET", "/confirmations")
            show(rows, _table(rows, ["id", "source", "capability", "args"]))
        else:
            show(api.req("POST", f"/confirmations/{ns.id}/{ns.cmd}"), f"{ns.cmd}d {ns.id}")
    elif ns.group == "audit":
        res = api.req("GET", "/audit", params={"limit": ns.limit})
        rows = [{"time": f"{e['ts']:.0f}", "source": e["source"][:8], "capability": e["capability"], "result": e["result"],
                 "error": e.get("error") or ""} for e in res["entries"]]
        show(res, f"chain {'OK' if res['chain_ok'] else 'BROKEN'}\n" + _table(rows, ["time", "source", "capability", "result", "error"]))
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
