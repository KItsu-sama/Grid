import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from grid_agent.adapters.base import MemoryAdapter
from grid_agent.client import GridClient
from grid_agent.config import GridConfig
from grid_agent.daemon import build_state
from grid_agent.identity import DeviceIdentity
from grid_agent.protocol import Role
from grid_agent.transport.base import FakeTransport, PeerIdentity

OWNER = "me@example.com"


class Peer:
    """A second Grid device (e.g. the phone) talking to the PC's agent over a loopback 'network'."""

    def __init__(self, pc, tmp, name, transport_id, addr, owner=OWNER):
        self.identity = DeviceIdentity.load_or_create(tmp / name)
        self.name = name
        self.ident = PeerIdentity(transport_id, owner, name, f"wg-{name}")
        self.addr = pc.transport.add_peer(self.ident, addr=addr)
        self.pc = pc
        self.tid = transport_id

    def register(self):
        return self.pc.registry.register(device_id=self.identity.device_id, name=self.name,
                                         sign_pubkey=self.identity.public_key, transport_id=self.tid)

    def approve(self, role=Role.CLIENT):
        self.register()
        return self.pc.registry.approve(self.identity.device_id, role)

    def sender(self, peer_identity=None):
        who = peer_identity or self.ident
        return lambda env, sig: self.pc.agent.handle(env, sig, who).to_dict()

    def client(self, peer_identity=None):
        return GridClient(self.identity, self.pc.agent.device_id, self.sender(peer_identity))


@pytest.fixture
def pc(tmp_path):
    cfg = GridConfig(tmp_path / "pc", "pc", Role.MAIN, OWNER,
                     {"shared": str(tmp_path / "grid" / "shared"), "inbox": str(tmp_path / "grid" / "inbox")})
    cfg.save()
    st = build_state(cfg, transport=FakeTransport(), adapter=MemoryAdapter())
    st.tmp = tmp_path
    return st


@pytest.fixture
def phone(pc, tmp_path):
    return Peer(pc, tmp_path, "phone", "stable-phone", "100.64.0.2")


@pytest.fixture
def laptop(pc, tmp_path):
    return Peer(pc, tmp_path, "laptop", "stable-laptop", "100.64.0.3")
