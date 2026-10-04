"""Grid device identity: a persistent device_id plus an Ed25519 signing key.

This is deliberately separate from WireGuard/Tailscale node keys. The transport key
can rotate or be replaced without changing who the device is in Grid.
"""
from __future__ import annotations

import base64
import json
import os
import uuid
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey


def b64(b: bytes) -> str:
    return base64.b64encode(b).decode()


def unb64(s: str) -> bytes:
    return base64.b64decode(s.encode())


def verify(pubkey_b64: str, message: bytes, sig_b64: str) -> bool:
    try:
        Ed25519PublicKey.from_public_bytes(unb64(pubkey_b64)).verify(unb64(sig_b64), message)
        return True
    except (InvalidSignature, ValueError):
        return False


def load_personal_grid_device_record() -> dict | None:
    """Read the authoritative device record from the active PersonalGrid installation."""
    grid_root = os.environ.get("PERSONAL_GRID_ROOT")
    if not grid_root:
        return None
    path = Path(grid_root) / ".grid" / "device.json"
    if not path.is_file():
        raise FileNotFoundError(f"PersonalGrid device record not found: {path}")
    document = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(document, dict):
        raise ValueError(f"PersonalGrid device record is not a JSON object: {path}")
    device_id = document.get("gridDeviceId")
    if not isinstance(device_id, str) or not device_id.strip():
        raise ValueError(f"PersonalGrid device record has no gridDeviceId: {path}")
    return document


def load_personal_grid_device_id() -> str | None:
    """Read the authoritative device ID from the active PersonalGrid installation."""
    device = load_personal_grid_device_record()
    return device["gridDeviceId"] if device else None


class DeviceIdentity:
    def __init__(self, device_id: str, key: Ed25519PrivateKey, path: Path | None = None):
        self.device_id = device_id
        self._key = key
        self._path = path

    @classmethod
    def load_or_create(cls, directory: Path, device_id: str | None = None) -> "DeviceIdentity":
        directory = Path(directory)
        directory.mkdir(parents=True, exist_ok=True)
        f = directory / "identity.json"
        if f.exists():
            d = json.loads(f.read_text())
            if device_id is not None and d["device_id"] != device_id:
                raise ValueError("Agent signing key is bound to a different PersonalGrid device ID")
            key = Ed25519PrivateKey.from_private_bytes(unb64(d["private_key"]))
            return cls(d["device_id"], key, f)
        ident = cls(device_id or uuid.uuid4().hex, Ed25519PrivateKey.generate(), f)
        ident._save()
        return ident

    def _save(self) -> None:
        raw = self._key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                                      serialization.NoEncryption())
        tmp = self._path.with_suffix(".tmp")
        # 0o600 is honoured on POSIX; on Windows rely on the per-user profile ACL
        # (TODO: wrap with DPAPI via win32crypt for at-rest protection).
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as fh:
            json.dump({"device_id": self.device_id, "private_key": b64(raw)}, fh)
        os.replace(tmp, self._path)

    @property
    def public_key(self) -> str:
        raw = self._key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        return b64(raw)

    def sign(self, message: bytes) -> str:
        return b64(self._key.sign(message))

    def rotate(self) -> dict:
        """Generate a new key; return a statement signed by the OLD key so peers can accept it."""
        new_key = Ed25519PrivateKey.generate()
        new_pub = b64(new_key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw))
        statement = rotation_statement(self.device_id, new_pub)
        sig = self.sign(statement)
        self._key = new_key
        if self._path:
            self._save()
        return {"device_id": self.device_id, "new_pubkey": new_pub, "signature": sig}


def rotation_statement(device_id: str, new_pub: str) -> bytes:
    return f"grid-key-rotation:v1:{device_id}:{new_pub}".encode()
