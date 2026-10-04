"""Platform-independent protocol types. No OS-specific code lives here."""
from __future__ import annotations

import enum
import json
import time
import uuid
from dataclasses import dataclass, field, asdict
from typing import Any


class Role(str, enum.Enum):
    MAIN = "MAIN"
    WORKER = "WORKER"
    CLIENT = "CLIENT"


class DeviceState(str, enum.Enum):
    PENDING = "pending"      # seen on the network, not yet approved by the user
    APPROVED = "approved"
    REVOKED = "revoked"


class GridError(Exception):
    code = "error"


class AuthenticationError(GridError):
    code = "unauthenticated"


class PermissionDenied(GridError):
    code = "permission_denied"


class ConfirmationRequired(GridError):
    code = "confirmation_required"


class ValidationError(GridError):
    code = "invalid_arguments"


class UnsupportedCapability(GridError):
    code = "unsupported_capability"


class ConflictError(GridError):
    code = "conflict"

    def __init__(self, conflict: "Conflict"):
        super().__init__(f"conflict on {conflict.path}")
        self.conflict = conflict


@dataclass
class DeviceRecord:
    device_id: str
    name: str
    role: Role
    state: DeviceState
    sign_pubkey: str                 # Grid identity key (Ed25519, base64). NOT a WireGuard key.
    transport_id: str                # stable id from the transport (Tailscale StableID)
    wg_pubkey: str = ""              # informational; may rotate without changing identity
    address: str = ""
    version: str = ""
    last_seen: float = 0.0
    online: bool = False
    capabilities: list[str] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        d = asdict(self)
        d["role"] = self.role.value
        d["state"] = self.state.value
        return d


@dataclass
class Envelope:
    """A signed request from one Grid device to another."""
    source: str
    target: str
    capability: str
    args: dict[str, Any]
    ts: float = field(default_factory=time.time)
    nonce: str = field(default_factory=lambda: uuid.uuid4().hex)
    confirmation_id: str | None = None   # issued by the TARGET after its human approves

    def signing_bytes(self) -> bytes:
        body = {
            "source": self.source, "target": self.target, "capability": self.capability,
            "args": self.args, "ts": self.ts, "nonce": self.nonce, "confirmation_id": self.confirmation_id,
        }
        return json.dumps(body, sort_keys=True, separators=(",", ":")).encode()

    def to_dict(self) -> dict[str, Any]:
        return json.loads(self.signing_bytes())


@dataclass
class Result:
    ok: bool
    value: Any = None
    error_code: str | None = None
    error: str | None = None
    conflict: dict[str, Any] | None = None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass
class FileVersion:
    device: str
    path: str
    size: int
    mtime: float
    sha256: str


@dataclass
class Conflict:
    """Returned instead of overwriting when two devices changed the same file."""
    source_device: str
    target_device: str
    path: str
    local: FileVersion
    remote: FileVersion
    base_sha256: str | None
    options: tuple[str, ...] = ("keep_local", "keep_remote", "keep_both", "inspect", "manual")

    def to_dict(self) -> dict[str, Any]:
        d = asdict(self)
        d["options"] = list(self.options)
        d["available_versions"] = [d["local"], d["remote"]]
        d["timestamps"] = {"local": self.local.mtime, "remote": self.remote.mtime}
        d["hashes"] = {"local": self.local.sha256, "remote": self.remote.sha256}
        d["sizes"] = {"local": self.local.size, "remote": self.remote.size}
        return d
