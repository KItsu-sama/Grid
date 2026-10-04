"""Wiring: builds the Agent + monitor from a config, and runs the two API listeners."""
from __future__ import annotations

import sys
import threading
from dataclasses import dataclass
from pathlib import Path
import os

from .adapters.base import PlatformAdapter
from .agent import Agent
from .audit import AuditLog
from .config import GridConfig
from .files import FileService
from .fs import GridRoots, LocalFS
from .identity import DeviceIdentity, load_personal_grid_device_record
from .monitor import HealthMonitor
from .protocol import Role
from .registry import Registry
from .transport.base import Transport


@dataclass
class AppState:
    cfg: GridConfig
    agent: Agent
    registry: Registry
    audit: AuditLog
    transport: Transport
    monitor: HealthMonitor
    identity: DeviceIdentity


def default_adapter(cfg: GridConfig, roots: GridRoots) -> PlatformAdapter:
    if sys.platform == "win32":
        from .adapters.windows import WindowsAdapter
        return WindowsAdapter(apps=cfg.apps, resolve_path=lambda v: str(roots.resolve(v)),
                              env_readable=set(cfg.env_readable))
    from .adapters.base import MemoryAdapter
    return MemoryAdapter(caps=set())          # non-Windows dev hosts: no OS capabilities, files/transfer still work


def build_state(cfg: GridConfig, transport: Transport | None = None,
                adapter: PlatformAdapter | None = None) -> AppState:
    from .transport.tailscale import TailscaleTransport
    transport = transport or TailscaleTransport()
    sd = cfg.state_dir
    personal_device = load_personal_grid_device_record()
    identity = DeviceIdentity.load_or_create(sd, personal_device["gridDeviceId"] if personal_device else None)
    grid_root = os.environ.get("PERSONAL_GRID_ROOT")
    grid_state_dir = Path(grid_root) / ".grid" if grid_root else sd
    registry = Registry(grid_state_dir / "device_registry.db")
    audit = AuditLog(grid_state_dir / "logs" / "agent-audit.log")
    roots = GridRoots({k: Path(v) for k, v in cfg.roots.items()})
    files = FileService(LocalFS(roots), identity.device_id, sd) if cfg.roots else None
    adapter = adapter or default_adapter(cfg, roots)
    role = _personal_grid_role(personal_device, cfg.role)
    name = str(personal_device.get("deviceName") or cfg.device_name) if personal_device else cfg.device_name
    owner = str(personal_device.get("tailscaleEmail") or cfg.owner_login) if personal_device else cfg.owner_login
    agent = Agent(identity=identity, name=name, role=role, owner_login=owner,
                  registry=registry, transport=transport, audit=audit, files=files, adapter=adapter)
    return AppState(cfg, agent, registry, audit, transport, HealthMonitor(transport, registry), identity)


def _personal_grid_role(device: dict | None, fallback: Role) -> Role:
    if device is None:
        return fallback
    grid_role = device.get("gridRole")
    if grid_role is not None:
        try:
            return Role(str(grid_role).upper())
        except ValueError as exc:
            raise ValueError(f"unsupported PersonalGrid gridRole: {grid_role}") from exc
    if device.get("isMain"):
        return Role.MAIN
    try:
        return Role(str(device.get("role", "")).upper())
    except ValueError:
        return Role.CLIENT


def run(cfg: GridConfig) -> None:  # pragma: no cover - process wiring
    import uvicorn
    from .api import create_local_app, create_peer_app
    st = build_state(cfg)
    ts = st.transport.status()
    addr = next((a for a in ts.self_addresses if "." in a), None)
    if not (ts.running and ts.logged_in and addr):
        raise SystemExit("private network is not up; sign in first (tailscale up)")
    threading.Thread(target=st.monitor.run, daemon=True).start()
    # Peer API is bound ONLY to the private-network address, never 0.0.0.0.
    peer = uvicorn.Server(uvicorn.Config(create_peer_app(st), host=addr, port=cfg.peer_port, log_level="warning"))
    threading.Thread(target=peer.run, daemon=True).start()
    uvicorn.run(create_local_app(st), host="127.0.0.1", port=cfg.local_port, log_level="warning")
