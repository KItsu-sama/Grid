import json
import time

import pytest
from fastapi.testclient import TestClient

from grid_agent import cli
from grid_agent.adapters.android import AndroidAdapter
from grid_agent.adapters.windows import WindowsAdapter
from grid_agent.api import create_local_app, create_peer_app
from grid_agent.cli import Api
from grid_agent.identity import DeviceIdentity
from grid_agent.protocol import DeviceState, Envelope, Role, UnsupportedCapability, ValidationError
from grid_agent.transport.base import PeerIdentity
from grid_agent.transport.tailscale import TailscaleTransport


def local_client(pc):
    return TestClient(create_local_app(pc), headers={"Authorization": f"Bearer {pc.cfg.admin_token()}"})


def peer_client(pc, who):
    return TestClient(create_peer_app(pc, peer_resolver=lambda req: who))


# ---------- API surfaces
def test_local_api_requires_token_and_peer_api_has_no_admin_routes(pc):
    assert TestClient(create_local_app(pc)).get("/devices").status_code == 401
    bad = TestClient(create_local_app(pc), headers={"Authorization": "Bearer nope"})
    assert bad.get("/devices").status_code == 401
    paths = {r.path for r in create_peer_app(pc).routes}
    assert {"/v1/invoke", "/v1/hello", "/v1/rotate"} <= paths
    assert not any("approve" in p or "revoke" in p or "grants" in p or "confirm" in p for p in paths)
    assert peer_client(pc, None).post(f"/devices/x/approve", json={}).status_code == 404


def hello_body(ident, name="phone"):
    d = {"device_id": ident.device_id, "name": name, "sign_pubkey": ident.public_key, "version": "0.1",
         "capabilities": ["audio.volume.set"], "ts": time.time()}
    import json as j
    return {"device": d, "signature": ident.sign(j.dumps(d, sort_keys=True, separators=(",", ":")).encode())}


def test_hello_pending_approve_via_admin_api_then_invoke(pc, phone):
    pcli, adm = peer_client(pc, phone.ident), local_client(pc)
    r = pcli.post("/v1/hello", json=hello_body(phone.identity))
    assert r.status_code == 200 and r.json()["state"] == "pending"
    assert adm.get("/devices").json()[0]["state"] == "pending"
    env = Envelope(phone.identity.device_id, pc.agent.device_id, "device.info", {})
    body = {"envelope": env.to_dict(), "signature": phone.identity.sign(env.signing_bytes())}
    assert pcli.post("/v1/invoke", json=body).json()["error_code"] == "unauthenticated"     # still pending
    a = adm.post(f"/devices/{phone.identity.device_id[:8]}/approve", json={"role": "main"})
    assert a.status_code == 200 and a.json()["role"] == "MAIN"
    env = Envelope(phone.identity.device_id, pc.agent.device_id, "device.info", {})
    body = {"envelope": env.to_dict(), "signature": phone.identity.sign(env.signing_bytes())}
    assert pcli.post("/v1/invoke", json=body).json()["ok"] is True
    assert adm.post(f"/devices/phone/revoke").json()["state"] == "revoked"                  # by name
    env = Envelope(phone.identity.device_id, pc.agent.device_id, "device.info", {})
    body = {"envelope": env.to_dict(), "signature": phone.identity.sign(env.signing_bytes())}
    assert pcli.post("/v1/invoke", json=body).json()["ok"] is False


def test_hello_rejects_foreign_account_bad_proof_and_stale(pc, phone):
    assert peer_client(pc, PeerIdentity("stable-phone", "evil@x.com")).post("/v1/hello", json=hello_body(phone.identity)).status_code == 403
    other = DeviceIdentity.load_or_create(pc.tmp / "o")
    b = hello_body(phone.identity); b["signature"] = other.sign(b"zzz")
    assert peer_client(pc, phone.ident).post("/v1/hello", json=b).status_code == 403
    assert peer_client(pc, phone.ident).post("/v1/hello", json={"nonsense": 1}).status_code == 400
    assert pc.registry.list() == []


def test_rotation_endpoint(pc, phone):
    phone.approve()
    stmt = phone.identity.rotate()
    c = peer_client(pc, phone.ident)
    assert c.post("/v1/rotate", json=stmt).status_code == 200
    assert peer_client(pc, PeerIdentity("someone-else", "me@example.com")).post("/v1/rotate", json=stmt).status_code == 403


def test_grants_confirmations_status_diagnose_audit_endpoints(pc, phone):
    phone.approve(Role.MAIN)
    adm = local_client(pc)
    adm.post(f"/devices/phone/grants", json={"pattern": "power.sleep", "effect": "allow"})
    r = phone.client()
    from grid_agent.client import RemoteError
    with pytest.raises(RemoteError) as e:
        r.call("power.sleep")
    pend = adm.get("/confirmations").json()
    assert pend[0]["capability"] == "power.sleep"
    adm.post(f"/confirmations/{pend[0]['id']}/approve")
    assert r.call("power.sleep", confirmation_id=pend[0]["id"]) == {"done": True}
    s = adm.get("/status").json()
    assert s["network"]["owner"] == "me@example.com" and "device.info" in s["capabilities"]
    d = {c["check"]: c for c in adm.get("/diagnose").json()}
    assert d["network running"]["ok"] and d["audit log chain intact"]["ok"] and "peer phone" in d
    assert adm.get("/audit").json()["chain_ok"] is True


# ---------- CLI
def run_cli(pc, *argv):
    out = []
    api = lambda cfg: Api(cfg, client=local_client(pc))
    code = cli.main(["--state-dir", str(pc.cfg.state_dir), *argv], api_factory=api, out=out.append)
    return code, "\n".join(out)


def test_cli_commands(pc, phone, tmp_path):
    phone.register()
    assert "phone" in run_cli(pc, "device", "list")[1] and "pending" in run_cli(pc, "device", "list")[1]
    assert "approved phone as WORKER" in run_cli(pc, "device", "approve", "phone", "--role", "WORKER")[1]
    run_cli(pc, "device", "grant", "phone", "power.*", "--deny")
    code, out = run_cli(pc, "network", "status")
    assert code == 0 and "UP" in out and "pc [MAIN]" in out
    assert "phone" in run_cli(pc, "peer", "list")[1]
    assert json.loads(run_cli(pc, "--json", "peer", "connect", "phone")[1])["device_id"] == phone.identity.device_id
    assert "suspended" in run_cli(pc, "peer", "disconnect", "phone")[1]
    code, out = run_cli(pc, "network", "diagnose")
    assert "[ok] network running" in out
    assert "revoked phone" in run_cli(pc, "device", "revoke", "phone")[1]
    assert "chain OK" in run_cli(pc, "audit")[1]
    code, out = run_cli(pc, "network", "rotate-key")
    assert "rotated" in out


def test_cli_init_creates_identity_and_config(tmp_path):
    out = []
    assert cli.main(["--state-dir", str(tmp_path / "g"), "init", "--name", "laptop", "--role", "WORKER",
                     "--owner", "me@example.com", "--root", f"shared={tmp_path / 's'}"], out=out.append) == 0
    from grid_agent.config import GridConfig
    cfg = GridConfig.load(tmp_path / "g")
    assert cfg.role is Role.WORKER and cfg.roots["shared"] == str(tmp_path / "s")
    assert (tmp_path / "g" / "identity.json").exists()


# ---------- health monitoring (offline/online detection)
def test_health_monitor_transitions(pc, phone):
    phone.approve()
    events = []
    pc.monitor.on_change = events.append
    h = pc.monitor.poll_once()[0]
    assert h.online and pc.registry.get(phone.identity.device_id).online
    pc.transport.latency[phone.addr] = None                       # unreachable
    pc.transport.peer_list[0].online = False
    h = pc.monitor.poll_once()[0]
    assert not h.online and not pc.registry.get(phone.identity.device_id).online
    pc.transport.latency[phone.addr] = 0.02; pc.transport.peer_list[0].online = True
    assert pc.monitor.poll_once()[0].online
    assert [e.online for e in events] == [True, False, True]


def test_monitor_ignores_unapproved_devices(pc, phone):
    phone.register()
    assert pc.monitor.poll_once() == []


# ---------- platform adapters
def test_windows_adapter_uses_fixed_argument_lists_and_allowlist():
    calls = []
    w = WindowsAdapter(apps={"notepad": "C:/Windows/notepad.exe"}, runner=calls.append)
    w.invoke("power.shutdown", {"delay_seconds": 30})
    w.invoke("power.sleep", {})
    w.invoke("app.launch", {"app": "notepad"})
    w.invoke("process.stop", {"pid": 4242})
    assert calls == [["shutdown", "/s", "/t", "30"], ["rundll32.exe", "powrprof.dll,SetSuspendState", "0,1,0"],
                     ["C:/Windows/notepad.exe"], ["taskkill", "/PID", "4242"]]
    with pytest.raises(ValidationError):
        w.invoke("app.launch", {"app": "cmd /c calc"})                      # not in allowlist -> no arbitrary exec
    with pytest.raises(ValidationError):
        w.invoke("process.stop", {"pid": 4})
    with pytest.raises(ValidationError):
        w.invoke("environment.read", {"name": "SECRET"})
    with pytest.raises(UnsupportedCapability):
        w.invoke("environment.modify", {"name": "A", "value": "b"})          # not implemented in v0.1
    assert "environment.modify" not in w.capabilities()


def test_android_adapter_is_a_thin_bridge():
    seen = []
    a = AndroidAdapter(lambda cap, args: seen.append((cap, args)) or {"ok": 1})
    assert a.invoke("audio.volume.set", {"volume": 80}) == {"ok": 1} and seen == [("audio.volume.set", {"volume": 80})]
    assert "power.shutdown" not in a.capabilities()
    with pytest.raises(UnsupportedCapability):
        a.invoke("power.shutdown", {})


def test_same_controller_call_works_against_either_platform(pc, phone):
    """Controller code is platform-agnostic: only the adapter differs."""
    phone.approve(Role.MAIN)
    assert phone.client().call("audio.volume.set", volume=42) == {"volume": 42}


# ---------- Tailscale transport parsing (fake CLI)
STATUS = {"BackendState": "Running", "Self": {"ID": "nSELF", "HostName": "pc", "TailscaleIPs": ["100.64.0.1"], "UserID": 7},
          "User": {"7": {"LoginName": "me@example.com"}},
          "Peer": {"nodekey:abc": {"ID": "nPHONE", "HostName": "phone", "TailscaleIPs": ["100.64.0.2"], "Online": True,
                                   "PublicKey": "nodekey:abc", "LastSeen": "2026-10-04T10:00:00Z", "Relay": "sin", "CurAddr": ""}}}
WHOIS = {"Node": {"StableID": "nPHONE", "Name": "phone.tail.ts.net.", "Key": "nodekey:abc", "Addresses": ["100.64.0.2/32"]},
         "UserProfile": {"LoginName": "me@example.com"}}


def fake_runner(cmd, timeout):
    if cmd[1] == "status": return 0, json.dumps(STATUS)
    if cmd[1] == "whois": return (0, json.dumps(WHOIS)) if cmd[-1] == "100.64.0.2" else (1, "no match")
    if cmd[1] == "ping": return 0, "pong"
    return 1, "?"


def test_tailscale_transport_parsing():
    t = TailscaleTransport("tailscale", fake_runner)
    s = t.status()
    assert s.logged_in and s.owner == "me@example.com" and s.self_addresses == ["100.64.0.1"]
    p = t.peers()[0]
    assert p.transport_id == "nPHONE" and p.online and p.relayed is True and p.last_seen > 0
    w = t.whois("100.64.0.2:51234")
    assert w.transport_id == "nPHONE" and w.owner == "me@example.com"
    assert t.whois("100.64.0.99") is None and t.ping("100.64.0.2") is not None
    down = TailscaleTransport("tailscale", lambda c, t: (1, "not running"))
    assert not down.status().running and down.peers() == []
