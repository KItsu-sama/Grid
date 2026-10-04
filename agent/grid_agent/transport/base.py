"""Transport abstraction. Reachability + peer identity only; no Grid authorization here."""
from __future__ import annotations

import abc
from dataclasses import dataclass, field


@dataclass
class PeerIdentity:
    """What the transport can PROVE about the remote end of a connection."""
    transport_id: str          # stable across key rotation (Tailscale StableID)
    owner: str                 # identity-provider login that owns the node (e.g. you@gmail.com)
    name: str = ""
    wg_pubkey: str = ""
    addresses: list[str] = field(default_factory=list)


@dataclass
class PeerStatus:
    transport_id: str
    name: str
    addresses: list[str]
    online: bool
    wg_pubkey: str = ""
    last_seen: float = 0.0
    relayed: bool | None = None   # True when going through a relay (DERP) rather than direct


@dataclass
class TransportStatus:
    running: bool
    logged_in: bool
    self_id: str = ""
    self_name: str = ""
    self_addresses: list[str] = field(default_factory=list)
    owner: str = ""
    detail: str = ""


class Transport(abc.ABC):
    @abc.abstractmethod
    def status(self) -> TransportStatus: ...

    @abc.abstractmethod
    def peers(self) -> list[PeerStatus]: ...

    @abc.abstractmethod
    def whois(self, remote_addr: str) -> PeerIdentity | None:
        """Identify the peer behind a remote address, or None if it isn't a known peer."""

    @abc.abstractmethod
    def ping(self, address: str, timeout: float = 3.0) -> float | None:
        """Round-trip seconds, or None if unreachable."""

    def reauthenticate(self) -> None:  # optional: rotate the transport's node key
        raise NotImplementedError


class FakeTransport(Transport):
    """In-memory transport for tests and offline development."""

    def __init__(self, self_status: TransportStatus | None = None):
        self._self = self_status or TransportStatus(True, True, "self-stable", "self", ["100.64.0.1"], "me@example.com")
        self.peer_list: list[PeerStatus] = []
        self.identities: dict[str, PeerIdentity] = {}
        self.latency: dict[str, float | None] = {}

    def add_peer(self, ident: PeerIdentity, online: bool = True, addr: str | None = None) -> str:
        addr = addr or (ident.addresses[0] if ident.addresses else f"100.64.0.{len(self.peer_list) + 2}")
        ident.addresses = [addr]
        self.identities[addr] = ident
        self.peer_list.append(PeerStatus(ident.transport_id, ident.name, [addr], online, ident.wg_pubkey))
        self.latency[addr] = 0.01 if online else None
        return addr

    def status(self): return self._self
    def peers(self): return list(self.peer_list)
    def whois(self, remote_addr): return self.identities.get(remote_addr)
    def ping(self, address, timeout=3.0): return self.latency.get(address)
