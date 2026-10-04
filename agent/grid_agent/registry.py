"""Device registry (SQLite). Source of truth for who is a Grid device and what they may do."""
from __future__ import annotations

import sqlite3
import threading
import time
from pathlib import Path

from .identity import rotation_statement, verify
from .protocol import AuthenticationError, DeviceRecord, DeviceState, Role

_SCHEMA = """
CREATE TABLE IF NOT EXISTS devices(
  device_id TEXT PRIMARY KEY, name TEXT, role TEXT, state TEXT, sign_pubkey TEXT,
  transport_id TEXT, wg_pubkey TEXT, address TEXT, version TEXT,
  last_seen REAL, online INTEGER, capabilities TEXT, suspended INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS grants(
  controller_id TEXT, pattern TEXT, effect TEXT, PRIMARY KEY(controller_id, pattern));
"""


class Registry:
    def __init__(self, path: Path | str):
        self._db = sqlite3.connect(str(path), check_same_thread=False)
        self._db.row_factory = sqlite3.Row
        self._lock = threading.RLock()
        with self._lock:
            self._db.executescript(_SCHEMA)

    # -- helpers
    @staticmethod
    def _rec(r: sqlite3.Row) -> DeviceRecord:
        return DeviceRecord(
            device_id=r["device_id"], name=r["name"], role=Role(r["role"]), state=DeviceState(r["state"]),
            sign_pubkey=r["sign_pubkey"], transport_id=r["transport_id"], wg_pubkey=r["wg_pubkey"] or "",
            address=r["address"] or "", version=r["version"] or "", last_seen=r["last_seen"] or 0.0,
            online=bool(r["online"]), capabilities=(r["capabilities"] or "").split(",") if r["capabilities"] else [])

    def get(self, device_id: str) -> DeviceRecord | None:
        with self._lock:
            r = self._db.execute("SELECT * FROM devices WHERE device_id=?", (device_id,)).fetchone()
        return self._rec(r) if r else None

    def by_transport_id(self, transport_id: str) -> DeviceRecord | None:
        with self._lock:
            r = self._db.execute("SELECT * FROM devices WHERE transport_id=?", (transport_id,)).fetchone()
        return self._rec(r) if r else None

    def list(self) -> list[DeviceRecord]:
        with self._lock:
            return [self._rec(r) for r in self._db.execute("SELECT * FROM devices ORDER BY name")]

    def is_suspended(self, device_id: str) -> bool:
        with self._lock:
            r = self._db.execute("SELECT suspended FROM devices WHERE device_id=?", (device_id,)).fetchone()
        return bool(r and r["suspended"])

    # -- lifecycle
    def register(self, *, device_id: str, name: str, sign_pubkey: str, transport_id: str,
                 wg_pubkey: str = "", address: str = "", version: str = "",
                 capabilities: list[str] | None = None) -> DeviceRecord:
        """A device announces itself. New devices are PENDING; they get no access until approved.
        An existing device_id can never silently change its identity key."""
        with self._lock:
            cur = self.get(device_id)
            if cur is None:
                self._db.execute(
                    "INSERT INTO devices VALUES(?,?,?,?,?,?,?,?,?,?,?,?,0)",
                    (device_id, name, Role.CLIENT.value, DeviceState.PENDING.value, sign_pubkey, transport_id,
                     wg_pubkey, address, version, time.time(), 1, ",".join(capabilities or [])))
            else:
                if cur.sign_pubkey != sign_pubkey:
                    raise AuthenticationError("identity key mismatch for existing device")
                if cur.transport_id != transport_id:
                    raise AuthenticationError("transport identity mismatch for existing device")
                self._db.execute(
                    "UPDATE devices SET name=?, wg_pubkey=?, address=?, version=?, capabilities=?, last_seen=? "
                    "WHERE device_id=?",
                    (name, wg_pubkey, address, version, ",".join(capabilities or []), time.time(), device_id))
            self._db.commit()
        return self.get(device_id)  # type: ignore[return-value]

    def approve(self, device_id: str, role: Role) -> DeviceRecord:
        with self._lock:
            rec = self.get(device_id)
            if rec is None:
                raise KeyError(device_id)
            if rec.state is DeviceState.REVOKED:
                raise AuthenticationError("revoked devices must re-register with a new identity")
            self._db.execute("UPDATE devices SET state=?, role=? WHERE device_id=?",
                             (DeviceState.APPROVED.value, role.value, device_id))
            self._db.commit()
        return self.get(device_id)  # type: ignore[return-value]

    def revoke(self, device_id: str) -> DeviceRecord:
        """Revocation is local and immediate; no other device needs reconfiguring."""
        with self._lock:
            if self.get(device_id) is None:
                raise KeyError(device_id)
            self._db.execute("UPDATE devices SET state=? WHERE device_id=?",
                             (DeviceState.REVOKED.value, device_id))
            self._db.execute("DELETE FROM grants WHERE controller_id=?", (device_id,))
            self._db.commit()
        return self.get(device_id)  # type: ignore[return-value]

    def set_suspended(self, device_id: str, suspended: bool) -> None:
        with self._lock:
            self._db.execute("UPDATE devices SET suspended=? WHERE device_id=?", (int(suspended), device_id))
            self._db.commit()

    def set_presence(self, device_id: str, online: bool, address: str | None = None,
                     wg_pubkey: str | None = None) -> None:
        with self._lock:
            if online:
                self._db.execute("UPDATE devices SET online=1, last_seen=? WHERE device_id=?",
                                 (time.time(), device_id))
            else:
                self._db.execute("UPDATE devices SET online=0 WHERE device_id=?", (device_id,))
            if address is not None:
                self._db.execute("UPDATE devices SET address=? WHERE device_id=?", (address, device_id))
            if wg_pubkey:
                self._db.execute("UPDATE devices SET wg_pubkey=? WHERE device_id=?", (wg_pubkey, device_id))
            self._db.commit()

    def apply_key_rotation(self, device_id: str, new_pubkey: str, signature: str) -> None:
        """Accept a new identity key only if the CURRENT key signed the statement."""
        with self._lock:
            rec = self.get(device_id)
            if rec is None or rec.state is not DeviceState.APPROVED:
                raise AuthenticationError("unknown or unapproved device")
            if not verify(rec.sign_pubkey, rotation_statement(device_id, new_pubkey), signature):
                raise AuthenticationError("bad rotation signature")
            self._db.execute("UPDATE devices SET sign_pubkey=? WHERE device_id=?", (new_pubkey, device_id))
            self._db.commit()

    # -- grants (who may do what to THIS device)
    def set_grant(self, controller_id: str, pattern: str, effect: str) -> None:
        if effect not in ("allow", "deny"):
            raise ValueError(effect)
        with self._lock:
            self._db.execute("INSERT OR REPLACE INTO grants VALUES(?,?,?)", (controller_id, pattern, effect))
            self._db.commit()

    def clear_grant(self, controller_id: str, pattern: str) -> None:
        with self._lock:
            self._db.execute("DELETE FROM grants WHERE controller_id=? AND pattern=?", (controller_id, pattern))
            self._db.commit()

    def grants(self, controller_id: str) -> list[tuple[str, str]]:
        with self._lock:
            return [(r["pattern"], r["effect"]) for r in
                    self._db.execute("SELECT pattern, effect FROM grants WHERE controller_id=?", (controller_id,))]
