"""Two separate HTTP surfaces.

* local admin API  - 127.0.0.1 only, bearer token. Approve/revoke/grant/confirm live HERE and nowhere else.
* peer API         - bound to the private-network address. Only /hello, /invoke and /rotate; identity of
                     the caller comes from the transport (whois), then the Agent authenticates and authorizes.
"""
from __future__ import annotations

import json
import secrets
import time
from typing import Any, Callable

from fastapi import Body, Depends, FastAPI, HTTPException, Request

from .daemon import AppState
from .identity import verify
from .protocol import AuthenticationError, DeviceState, GridError, Role
from .transport.base import PeerIdentity


def create_local_app(st: AppState) -> FastAPI:
    app = FastAPI(title="PersonalGrid Agent admin API")
    token = st.cfg.admin_token()

    def auth(request: Request) -> None:
        got = request.headers.get("authorization", "")
        if not secrets.compare_digest(got, f"Bearer {token}"):
            raise HTTPException(401, "unauthorized")

    dep = [Depends(auth)]

    def _dev(device_id: str):
        rec = st.registry.get(device_id)
        if rec is None:  # allow unambiguous prefix or name
            m = [d for d in st.registry.list() if d.device_id.startswith(device_id) or d.name == device_id]
            rec = m[0] if len(m) == 1 else None
        if rec is None:
            raise HTTPException(404, "unknown device")
        return rec

    @app.get("/status", dependencies=dep)
    def status() -> dict:
        ts = st.transport.status()
        return {"device_id": st.agent.device_id, "name": st.cfg.device_name, "role": st.cfg.role.value,
                "network": {"running": ts.running, "logged_in": ts.logged_in, "addresses": ts.self_addresses,
                            "owner": ts.owner, "detail": ts.detail},
                "capabilities": st.agent.capabilities(),
                "devices": {s.value: sum(1 for d in st.registry.list() if d.state is s) for s in DeviceState}}

    @app.get("/devices", dependencies=dep)
    def devices() -> list[dict]:
        return [d.to_dict() for d in st.registry.list()]

    @app.post("/devices/{device_id}/approve", dependencies=dep)
    def approve(device_id: str, body: dict = Body(...)) -> dict:
        rec = _dev(device_id)
        try:
            role = Role(str(body.get("role", "CLIENT")).upper())
            out = st.registry.approve(rec.device_id, role)
        except (ValueError, AuthenticationError) as e:
            raise HTTPException(400, str(e))
        st.audit.record(source="local-admin", target=rec.device_id, capability="admin.approve",
                        args={"role": role.value}, result="ok")
        return out.to_dict()

    @app.post("/devices/{device_id}/revoke", dependencies=dep)
    def revoke(device_id: str) -> dict:
        rec = _dev(device_id)
        out = st.registry.revoke(rec.device_id)
        st.audit.record(source="local-admin", target=rec.device_id, capability="admin.revoke", args={}, result="ok")
        return out.to_dict()

    @app.post("/devices/{device_id}/grants", dependencies=dep)
    def grant(device_id: str, body: dict = Body(...)) -> dict:
        rec = _dev(device_id)
        st.registry.set_grant(rec.device_id, str(body["pattern"]), str(body["effect"]))
        st.audit.record(source="local-admin", target=rec.device_id, capability="admin.grant", args=body, result="ok")
        return {"grants": st.registry.grants(rec.device_id)}

    @app.get("/peers", dependencies=dep)
    def peers() -> list[dict]:
        out = []
        for d in st.registry.list():
            h = st.monitor.health.get(d.device_id)
            out.append({**d.to_dict(), "latency": h.latency if h else None, "relayed": h.relayed if h else None,
                        "suspended": st.registry.is_suspended(d.device_id)})
        return out

    @app.post("/peers/{device_id}/connect", dependencies=dep)
    def connect(device_id: str) -> dict:
        rec = _dev(device_id)
        if rec.state is not DeviceState.APPROVED:
            raise HTTPException(400, "device is not approved")
        lat = st.transport.ping(rec.address) if rec.address else None
        st.registry.set_suspended(rec.device_id, False)
        return {"device_id": rec.device_id, "reachable": lat is not None, "latency": lat}

    @app.post("/peers/{device_id}/disconnect", dependencies=dep)
    def disconnect(device_id: str) -> dict:
        rec = _dev(device_id)
        st.registry.set_suspended(rec.device_id, True)
        return {"device_id": rec.device_id, "suspended": True}

    @app.get("/diagnose", dependencies=dep)
    def diagnose() -> list[dict]:
        ts, checks = st.transport.status(), []
        add = lambda n, ok, d="": checks.append({"check": n, "ok": bool(ok), "detail": d})
        add("network running", ts.running, ts.detail)
        add("network signed in", ts.logged_in)
        add("owner identity matches config", ts.owner.lower() == st.cfg.owner_login.lower(),
            f"network={ts.owner!r} config={st.cfg.owner_login!r}")
        add("private address assigned", bool(ts.self_addresses), ",".join(ts.self_addresses))
        ok, bad = st.audit.verify()
        add("audit log chain intact", ok, "" if ok else f"first bad entry: {bad}")
        add("grid roots configured", bool(st.cfg.roots), ",".join(st.cfg.roots))
        for d in st.monitor.poll_once():
            dev = st.registry.get(d.device_id)
            add(f"peer {dev.name if dev else d.device_id}", d.online,
                f"latency={d.latency:.3f}s relayed={d.relayed}" if d.online else "offline")
        pend = [d.name for d in st.registry.list() if d.state is DeviceState.PENDING]
        add("no devices awaiting approval", not pend, ",".join(pend))
        return checks

    @app.post("/identity/rotate", dependencies=dep)
    def rotate() -> dict:
        stmt = st.identity.rotate()
        st.audit.record(source="local-admin", target=st.agent.device_id, capability="admin.rotate_key",
                        args={}, result="ok")
        pushed, failed = [], []
        import httpx
        for d in st.registry.list():
            if d.state is DeviceState.APPROVED and d.address:
                try:
                    r = httpx.post(f"http://{d.address}:{st.cfg.peer_port}/v1/rotate", json=stmt, timeout=5)
                    (pushed if r.status_code == 200 else failed).append(d.name)
                except Exception:
                    failed.append(d.name)
        return {"rotated": True, "announced_to": pushed, "unreachable": failed}

    @app.get("/confirmations", dependencies=dep)
    def confirmations() -> list[dict]:
        return st.agent.pending_confirmations()

    @app.post("/confirmations/{cid}/{decision}", dependencies=dep)
    def decide(cid: str, decision: str) -> dict:
        if decision not in ("approve", "deny"):
            raise HTTPException(404)
        try:
            st.agent.decide_confirmation(cid, decision == "approve")
        except GridError as e:
            raise HTTPException(400, str(e))
        return {"ok": True}

    @app.get("/audit", dependencies=dep)
    def audit(limit: int = 50) -> dict:
        ok, bad = st.audit.verify()
        return {"chain_ok": ok, "entries": st.audit.entries()[-limit:]}

    return app


def create_peer_app(st: AppState, peer_resolver: Callable[[Request], PeerIdentity | None] | None = None) -> FastAPI:
    app = FastAPI(title="PersonalGrid Agent peer API", docs_url=None, redoc_url=None, openapi_url=None)

    def resolve(request: Request) -> PeerIdentity | None:
        if peer_resolver:
            return peer_resolver(request)
        return st.transport.whois(request.client.host) if request.client else None

    @app.post("/v1/invoke")
    def invoke(request: Request, body: dict = Body(...)) -> dict:
        res = st.agent.handle(body.get("envelope") or {}, str(body.get("signature", "")), resolve(request))
        return res.to_dict()

    @app.post("/v1/hello")
    def hello(request: Request, body: dict = Body(...)) -> dict:
        """A new device announces itself. It lands as PENDING with zero access until approved locally."""
        peer = resolve(request)
        try:
            d, sig = body["device"], body["signature"]
            if peer is None or peer.owner.lower() != st.agent.owner.lower():
                raise AuthenticationError("peer is not on this Grid's identity")
            if abs(time.time() - float(d["ts"])) > 60:
                raise AuthenticationError("stale hello")
            if not verify(d["sign_pubkey"], json.dumps(d, sort_keys=True, separators=(",", ":")).encode(), sig):
                raise AuthenticationError("bad signature (no proof of key possession)")
            rec = st.registry.register(device_id=d["device_id"], name=str(d["name"])[:64], sign_pubkey=d["sign_pubkey"],
                                       transport_id=peer.transport_id, wg_pubkey=peer.wg_pubkey,
                                       address=peer.addresses[0] if peer.addresses else "",
                                       version=str(d.get("version", ""))[:32],
                                       capabilities=list(d.get("capabilities", []))[:64])
        except (KeyError, TypeError, ValueError):
            raise HTTPException(400, "malformed hello")
        except AuthenticationError as e:
            st.audit.record(source=str((body.get("device") or {}).get("device_id", "?")), target=st.agent.device_id,
                            capability="hello", args={}, result="denied", error=str(e))
            raise HTTPException(403, str(e))
        st.audit.record(source=rec.device_id, target=st.agent.device_id, capability="hello", args={"name": rec.name},
                        result="pending_approval")
        return {"state": rec.state.value, "device_id": st.agent.device_id, "name": st.agent.name,
                "sign_pubkey": st.identity.public_key}

    @app.post("/v1/rotate")
    def rotate(request: Request, body: dict = Body(...)) -> dict:
        peer = resolve(request)
        try:
            rec = st.registry.get(body["device_id"])
            if peer is None or rec is None or rec.transport_id != peer.transport_id:
                raise AuthenticationError("transport identity mismatch")
            st.registry.apply_key_rotation(body["device_id"], body["new_pubkey"], body["signature"])
        except KeyError:
            raise HTTPException(400, "malformed")
        except AuthenticationError as e:
            raise HTTPException(403, str(e))
        st.audit.record(source=body["device_id"], target=st.agent.device_id, capability="peer.rotate_key",
                        args={}, result="ok")
        return {"ok": True}

    return app
