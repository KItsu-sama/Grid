"""Connection health + offline/online detection. poll_once() is deterministic and testable."""
from __future__ import annotations

import threading
import time
from dataclasses import dataclass, field, replace
from typing import Callable

from .protocol import DeviceState
from .registry import Registry
from .transport.base import Transport


@dataclass
class Health:
    device_id: str
    online: bool
    latency: float | None = None
    relayed: bool | None = None
    consecutive_failures: int = 0
    changed_at: float = 0.0


class HealthMonitor:
    def __init__(self, transport: Transport, registry: Registry, on_change: Callable[[Health], None] | None = None,
                 offline_after: int = 2):
        self.transport, self.registry, self.on_change, self.offline_after = transport, registry, on_change, offline_after
        self.health: dict[str, Health] = {}
        self._stop = threading.Event()

    def poll_once(self) -> list[Health]:
        peers = {p.transport_id: p for p in self.transport.peers()}
        out = []
        for dev in self.registry.list():
            if dev.state is not DeviceState.APPROVED:
                continue
            p = peers.get(dev.transport_id)
            lat = self.transport.ping(p.addresses[0]) if p and p.online and p.addresses else None
            h = self.health.get(dev.device_id) or Health(dev.device_id, False, changed_at=time.time())
            was = h.online
            if lat is not None:
                h.consecutive_failures, h.online, h.latency = 0, True, lat
            else:
                h.consecutive_failures += 1
                h.latency = None
                if h.consecutive_failures >= self.offline_after or p is None or not p.online:
                    h.online = False
            h.relayed = p.relayed if p else None
            self.registry.set_presence(dev.device_id, h.online, address=p.addresses[0] if p and p.addresses else None,
                                       wg_pubkey=p.wg_pubkey if p else None)
            if h.online != was:
                h.changed_at = time.time()
                if self.on_change:
                    self.on_change(replace(h))      # snapshot, not the live object
            self.health[dev.device_id] = h
            out.append(h)
        return out

    def run(self, interval: float = 10.0) -> None:
        while not self._stop.wait(interval):
            try:
                self.poll_once()
            except Exception:
                pass

    def stop(self) -> None:
        self._stop.set()
