"""Authorization: role baseline + explicit per-device grants. Deny always wins.

Everything not allowed is denied. Sensitive capabilities need an explicit `allow` grant
(a role alone is never enough) AND a confirmation from the human at the target device.
"""
from __future__ import annotations

from fnmatch import fnmatchcase

from .protocol import DeviceRecord, DeviceState, Role

# Baseline: what a role may request without any explicit grant. Intentionally small.
ROLE_BASELINE: dict[Role, tuple[str, ...]] = {
    Role.MAIN:   ("files.*", "transfer.*", "media.*", "audio.*", "app.launch", "process.read",
                  "device.info", "environment.read"),
    Role.WORKER: ("files.list", "files.stat", "files.read", "files.write", "files.mkdir", "transfer.*",
                  "device.info"),
    Role.CLIENT: ("files.list", "files.stat", "files.read", "transfer.*", "media.*", "audio.*", "device.info"),
}

# Sensitive: explicit allow grant + target-side human confirmation.
SENSITIVE: tuple[str, ...] = (
    "power.*", "environment.modify", "services.manage", "process.manage", "process.stop",
    "system.settings", "files.delete_recursive",
)


def _match(patterns, cap: str) -> bool:
    return any(fnmatchcase(cap, p) for p in patterns)


def is_sensitive(capability: str) -> bool:
    return _match(SENSITIVE, capability)


def is_allowed(controller: DeviceRecord, capability: str, grants: list[tuple[str, str]]) -> bool:
    if controller.state is not DeviceState.APPROVED:
        return False
    if _match([p for p, e in grants if e == "deny"], capability):
        return False
    if _match([p for p, e in grants if e == "allow"], capability):
        return True
    if is_sensitive(capability):
        return False
    return _match(ROLE_BASELINE.get(controller.role, ()), capability)
