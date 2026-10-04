import json
import time

import pytest

from grid_agent.adapters.base import MemoryAdapter
from grid_agent.client import GridClient, RemoteError
from grid_agent.config import GridConfig
from grid_agent.daemon import build_state
from grid_agent.identity import DeviceIdentity
from grid_agent.protocol import AuthenticationError, DeviceState, Envelope, Role
from grid_agent.transport.base import FakeTransport, PeerIdentity


# ---------- identity & registry
def test_identity_persists_and_rotation_requires_old_key(tmp_path):
    a = DeviceIdentity.load_or_create(tmp_path / "x")
    assert DeviceIdentity.load_or_create(tmp_path / "x").device_id == a.device_id
    old_pub = a.public_key
    stmt = a.rotate()
    assert a.public_key != old_pub and stmt["new_pubkey"] == a.public_key


def test_agent_identity_uses_personal_grid_device_id(tmp_path, monkeypatch):
    grid_root = tmp_path / "personal-grid"
    device_file = grid_root / ".grid" / "device.json"
    device_file.parent.mkdir(parents=True)
    device_file.write_text(json.dumps({"gridDeviceId": "personal-grid-device", "gridRole": "MAIN",
                                       "deviceName": "personal-pc"}), encoding="utf-8")
    monkeypatch.setenv("PERSONAL_GRID_ROOT", str(grid_root))
    cfg = GridConfig(tmp_path / "agent-state", "pc", Role.CLIENT, "me@example.com")

    state = build_state(cfg, transport=FakeTransport(), adapter=MemoryAdapter())

    assert state.agent.device_id == "personal-grid-device"
    assert state.agent.role is Role.MAIN
    assert state.agent.name == "personal-pc"
    assert (device_file.parent / "device_registry.db").is_file()
    assert state.audit.path == device_file.parent / "logs" / "agent-audit.log"


def test_personal_grid_config_is_derived_from_device_record(tmp_path, monkeypatch):
    grid_root = tmp_path / "personal-grid"
    device_file = grid_root / ".grid" / "device.json"
    device_file.parent.mkdir(parents=True)
    device_file.write_text(json.dumps({"gridDeviceId": "grid-id", "gridRole": "WORKER",
                                       "deviceName": "workstation", "tailscaleEmail": "owner@example.com"}),
                           encoding="utf-8")
    monkeypatch.setenv("PERSONAL_GRID_ROOT", str(grid_root))
    state_dir = tmp_path / "agent-state"

    cfg = GridConfig.load(state_dir)

    assert cfg.state_dir == state_dir
    assert cfg.device_name == "workstation"
    assert cfg.role is Role.WORKER
    assert cfg.owner_login == "owner@example.com"
    assert not (state_dir / "config.json").exists()


def test_existing_agent_key_cannot_be_rebound_to_another_grid_device(tmp_path):
    identity = DeviceIdentity.load_or_create(tmp_path / "identity", device_id="grid-device-one")

    with pytest.raises(ValueError, match="different PersonalGrid device ID"):
        DeviceIdentity.load_or_create(tmp_path / "identity", device_id="grid-device-two")


def test_new_device_is_pending_with_no_access(pc, phone):
    rec = phone.register()
    assert rec.state is DeviceState.PENDING
    with pytest.raises(RemoteError) as e:
        phone.client().call("device.info")
    assert e.value.code == "unauthenticated"


def test_identity_key_cannot_be_swapped(pc, phone, tmp_path):
    phone.register()
    imposter = DeviceIdentity.load_or_create(tmp_path / "imposter")
    with pytest.raises(AuthenticationError):
        pc.registry.register(device_id=phone.identity.device_id, name="phone", sign_pubkey=imposter.public_key,
                             transport_id=phone.tid)


def test_key_rotation_accepted_only_if_signed_by_current_key(pc, phone, tmp_path):
    phone.approve()
    stmt = phone.identity.rotate()
    pc.registry.apply_key_rotation(stmt["device_id"], stmt["new_pubkey"], stmt["signature"])
    assert phone.client().call("device.info")["name"] == "pc"           # new key works
    other = DeviceIdentity.load_or_create(tmp_path / "other").rotate()
    with pytest.raises(AuthenticationError):
        pc.registry.apply_key_rotation(phone.identity.device_id, other["new_pubkey"], other["signature"])


# ---------- authentication of every request
def test_reachability_alone_is_not_trust(pc, phone):
    phone.approve()
    c = phone.client(PeerIdentity("stable-phone", "attacker@evil.com"))      # wrong IdP account
    with pytest.raises(RemoteError) as e:
        c.call("device.info")
    assert e.value.code == "unauthenticated"
    c = phone.client(PeerIdentity("some-other-node", "me@example.com"))                  # right owner, wrong node
    with pytest.raises(RemoteError):
        c.call("device.info")
    unresolved = GridClient(phone.identity, pc.agent.device_id,
                            lambda env, sig: pc.agent.handle(env, sig, None).to_dict())   # whois found nothing
    with pytest.raises(RemoteError):
        unresolved.call("device.info")


def test_bad_signature_replay_and_staleness(pc, phone):
    phone.approve()
    env = Envelope(phone.identity.device_id, pc.agent.device_id, "device.info", {})
    sig = phone.identity.sign(env.signing_bytes())
    assert pc.agent.handle(env.to_dict(), sig, phone.ident).ok
    assert pc.agent.handle(env.to_dict(), sig, phone.ident).error == "replayed request"
    env2 = Envelope(phone.identity.device_id, pc.agent.device_id, "device.info", {})
    assert pc.agent.handle(env2.to_dict(), "AAAA", phone.ident).error_code == "unauthenticated"
    old = Envelope(phone.identity.device_id, pc.agent.device_id, "device.info", {}, ts=time.time() - 600)
    r = pc.agent.handle(old.to_dict(), phone.identity.sign(old.signing_bytes()), phone.ident)
    assert r.error == "stale request"


def test_request_for_another_target_is_rejected(pc, phone):
    phone.approve()
    env = Envelope(phone.identity.device_id, "someone-else", "device.info", {})
    r = pc.agent.handle(env.to_dict(), phone.identity.sign(env.signing_bytes()), phone.ident)
    assert r.error_code == "unauthenticated"


def test_tampered_args_fail_signature(pc, phone):
    phone.approve(Role.MAIN)
    env = Envelope(phone.identity.device_id, pc.agent.device_id, "audio.volume.set", {"volume": 10})
    sig = phone.identity.sign(env.signing_bytes())
    d = env.to_dict(); d["args"]["volume"] = 100
    assert pc.agent.handle(d, sig, phone.ident).error_code == "unauthenticated"


# ---------- authorization
def test_role_baseline_least_privilege(pc, phone):
    phone.approve(Role.CLIENT)
    c = phone.client()
    assert c.call("device.info")["role"] == "MAIN"
    for cap, args in [("files.write", {"path": "shared/a.txt", "data": ""}), ("app.launch", {"app": "x"}),
                      ("power.sleep", {}), ("environment.read", {"name": "PATH"})]:
        with pytest.raises(RemoteError) as e:
            c.call(cap, **args)
        assert e.value.code == "permission_denied", cap


def test_explicit_deny_beats_role_and_unknown_capability_is_rejected(pc, phone):
    phone.approve(Role.MAIN)
    pc.registry.set_grant(phone.identity.device_id, "audio.*", "deny")
    with pytest.raises(RemoteError) as e:
        phone.client().call("audio.volume.set", volume=80)
    assert e.value.code == "permission_denied"
    r = pc.agent.handle(*_signed(phone, pc, "shell.exec", {"cmd": "calc"}), phone.ident)
    assert r.error_code == "permission_denied"            # no arbitrary-command capability exists


def _signed(phone, pc, cap, args, confirmation_id=None):
    env = Envelope(phone.identity.device_id, pc.agent.device_id, cap, args, confirmation_id=confirmation_id)
    return env.to_dict(), phone.identity.sign(env.signing_bytes())


def test_argument_validation(pc, phone):
    phone.approve(Role.MAIN)
    c = phone.client()
    for bad in ({"volume": 101}, {"volume": "80"}, {"volume": True}, {}, {"volume": 5, "x": 1}):
        with pytest.raises(RemoteError) as e:
            c.call("audio.volume.set", **bad)
        assert e.value.code == "invalid_arguments"
    assert c.call("audio.volume.set", volume=80) == {"volume": 80}
    assert pc.agent.adapter.volume == 80


def test_sensitive_needs_grant_and_target_side_confirmation(pc, phone):
    phone.approve(Role.MAIN)
    c = phone.client()
    with pytest.raises(RemoteError) as e:                          # role alone is never enough
        c.call("power.shutdown", delay_seconds=30)
    assert e.value.code == "permission_denied"
    pc.registry.set_grant(phone.identity.device_id, "power.shutdown", "allow")
    with pytest.raises(RemoteError) as e:
        c.call("power.shutdown", delay_seconds=30)
    assert e.value.code == "confirmation_required"
    cid = e.value.value["confirmation_id"]
    assert not any(call[0] == "power.shutdown" for call in pc.agent.adapter.calls)
    # the *source* cannot approve its own request; only the local human can
    with pytest.raises(RemoteError):
        c.call("power.shutdown", confirmation_id=cid, delay_seconds=30)
    pc.agent.decide_confirmation(cid, True)
    with pytest.raises(RemoteError):                               # approved for different args -> still blocked
        c.call("power.shutdown", confirmation_id=cid, delay_seconds=600)
    # the mismatch above issued a fresh pending request and did not consume cid
    assert c.call("power.shutdown", confirmation_id=cid, delay_seconds=30) == {"done": True}
    with pytest.raises(RemoteError) as e:                          # single use
        c.call("power.shutdown", confirmation_id=cid, delay_seconds=30)
    assert e.value.code == "confirmation_required"


def test_denied_confirmation_never_executes(pc, phone):
    phone.approve(Role.MAIN)
    pc.registry.set_grant(phone.identity.device_id, "power.sleep", "allow")
    with pytest.raises(RemoteError) as e:
        phone.client().call("power.sleep")
    pc.agent.decide_confirmation(e.value.value["confirmation_id"], False)
    with pytest.raises(RemoteError):
        phone.client().call("power.sleep", confirmation_id=e.value.value["confirmation_id"])
    assert pc.agent.adapter.calls == []


def test_revoking_one_device_leaves_others_untouched(pc, phone, laptop):
    phone.approve(Role.MAIN); laptop.approve(Role.MAIN)
    assert phone.client().call("device.info") and laptop.client().call("device.info")
    pc.registry.revoke(phone.identity.device_id)
    with pytest.raises(RemoteError):
        phone.client().call("device.info")
    assert laptop.client().call("device.info")["name"] == "pc"      # nothing reconfigured
    with pytest.raises(AuthenticationError):
        pc.registry.approve(phone.identity.device_id, Role.MAIN)    # cannot be silently re-approved


def test_disconnect_suspends_peer_without_revoking(pc, phone):
    phone.approve()
    pc.registry.set_suspended(phone.identity.device_id, True)
    with pytest.raises(RemoteError):
        phone.client().call("device.info")
    pc.registry.set_suspended(phone.identity.device_id, False)
    assert phone.client().call("device.info")


# ---------- audit
def test_audit_records_success_denial_and_redacts_bodies(pc, phone):
    phone.approve(Role.MAIN)
    c = phone.client()
    c.call("files.write", path="shared/secret.txt", data="aGVsbG8=")
    with pytest.raises(RemoteError):
        c.call("power.sleep")
    es = pc.audit.entries()
    assert [e["result"] for e in es][-2:] == ["ok", "denied"]
    assert es[-2]["args"]["data"] == "<redacted>"
    for e in es:
        assert {"ts", "source", "target", "capability", "args", "result"} <= set(e)
    assert pc.audit.verify() == (True, None)


def test_audit_chain_detects_tampering(pc, phone):
    phone.approve()
    for _ in range(3):
        phone.client().call("device.info")
    lines = pc.audit.path.read_text().splitlines()
    lines[1] = lines[1].replace('"result": "ok"', '"result": "denied"')
    pc.audit.path.write_text("\n".join(lines) + "\n")
    ok, bad = pc.audit.verify()
    assert not ok and bad == 1
