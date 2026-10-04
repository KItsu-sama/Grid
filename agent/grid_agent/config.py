from __future__ import annotations

import json
import os
import secrets
from dataclasses import dataclass, field, asdict
from pathlib import Path

from .protocol import Role


@dataclass
class GridConfig:
    state_dir: Path
    device_name: str
    role: Role = Role.CLIENT
    owner_login: str = ""                      # identity-provider login that owns this Grid (Google/Microsoft via Tailscale SSO)
    roots: dict[str, str] = field(default_factory=dict)   # Grid root name -> OS path (e.g. shared -> D:\PersonalGrid\shared)
    apps: dict[str, str] = field(default_factory=dict)    # app.launch allowlist: id -> executable
    env_readable: list[str] = field(default_factory=list)
    local_port: int = 8765                      # admin API, 127.0.0.1 only
    peer_port: int = 8766                       # peer API, bound to the private-network address only

    def save(self) -> None:
        self.state_dir.mkdir(parents=True, exist_ok=True)
        d = asdict(self)
        d["state_dir"], d["role"] = str(self.state_dir), self.role.value
        (self.state_dir / "config.json").write_text(json.dumps(d, indent=2))

    @classmethod
    def load(cls, state_dir: Path) -> "GridConfig":
        grid_root = os.environ.get("PERSONAL_GRID_ROOT")
        if grid_root:
            device_path = Path(grid_root) / ".grid" / "device.json"
            if not device_path.is_file():
                raise FileNotFoundError(f"PersonalGrid device record not found: {device_path}")
            device = json.loads(device_path.read_text(encoding="utf-8"))
            if not isinstance(device, dict) or not device.get("gridDeviceId"):
                raise ValueError(f"PersonalGrid device record has no gridDeviceId: {device_path}")
            role_name = str(device.get("gridRole", "")).upper()
            if not role_name:
                role_name = "MAIN" if device.get("isMain") else str(device.get("role", "CLIENT")).upper()
            try:
                role = Role(role_name)
            except ValueError:
                role = Role.CLIENT
            return cls(
                state_dir=Path(state_dir),
                device_name=str(device.get("deviceName") or "PersonalGrid device"),
                role=role,
                owner_login=str(device.get("tailscaleEmail") or ""),
            )
        d = json.loads((Path(state_dir) / "config.json").read_text())
        d["state_dir"], d["role"] = Path(d["state_dir"]), Role(d["role"])
        return cls(**d)

    def admin_token(self) -> str:
        """Bearer token for the local admin API; readable only by the local user."""
        p = self.state_dir / "admin.token"
        if not p.exists():
            self.state_dir.mkdir(parents=True, exist_ok=True)
            p.write_text(secrets.token_urlsafe(32))
        return p.read_text().strip()
