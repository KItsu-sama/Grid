"""The Grid Device Agent: authenticate -> authorize -> validate -> (confirm) -> execute -> audit."""
from __future__ import annotations

import hashlib
import json
import threading
import time
import uuid
from typing import Any

from . import __version__, authz
from .adapters.base import PlatformAdapter
from .audit import AuditLog
from .capabilities import CATALOGUE, validate
from .files import FileService
from .identity import DeviceIdentity, verify
from .protocol import (AuthenticationError, ConfirmationRequired, ConflictError, DeviceState, Envelope,
                       GridError, PermissionDenied, Result, Role, UnsupportedCapability, ValidationError)
from .registry import Registry
from .transport.base import PeerIdentity, Transport

MAX_SKEW = 60.0
CONFIRM_TTL = 120.0
FILE_CAPS = {"files.list": "list", "files.stat": "stat", "files.read": "read", "files.write": "write",
             "files.mkdir": "mkdir", "files.move": "move", "files.copy": "copy", "files.delete": "delete",
             "transfer.begin": "begin", "transfer.put_chunk": "put_chunk", "transfer.commit": "commit",
             "transfer.abort": "abort", "transfer.status": "status"}


def _args_hash(args: dict) -> str:
    return hashlib.sha256(json.dumps(args, sort_keys=True).encode()).hexdigest()


class Agent:
    def __init__(self, *, identity: DeviceIdentity, name: str, role: Role, owner_login: str, registry: Registry,
                 transport: Transport, audit: AuditLog, files: FileService | None, adapter: PlatformAdapter):
        self.identity, self.name, self.role, self.owner = identity, name, role, owner_login
        self.registry, self.transport, self.audit, self.files, self.adapter = registry, transport, audit, files, adapter
        self._nonces: dict[str, float] = {}
        self._confirms: dict[str, dict] = {}
        self._lock = threading.Lock()

    @property
    def device_id(self) -> str:
        return self.identity.device_id

    def capabilities(self) -> list[str]:
        caps = set(self.adapter.capabilities()) & set(CATALOGUE)
        caps |= {"device.info"}
        if self.files:
            caps |= set(FILE_CAPS)
        return sorted(caps)

    # ------------------------------------------------------------------ confirmations (target-side human)
    def pending_confirmations(self) -> list[dict]:
        with self._lock:
            now = time.time()
            return [{"id": k, **{x: v[x] for x in ("source", "capability", "args", "approved")}}
                    for k, v in self._confirms.items() if v["expires"] > now]

    def decide_confirmation(self, cid: str, approve: bool) -> None:
        with self._lock:
            c = self._confirms.get(cid)
            if not c or c["expires"] < time.time():
                raise ValidationError("unknown or expired confirmation")
            if approve:
                c["approved"] = True
            else:
                del self._confirms[cid]
        self.audit.record(source=c["source"], target=self.device_id, capability=c["capability"], args=c["args"],
                          result="confirmation_approved" if approve else "confirmation_denied")

    # ------------------------------------------------------------------ main entry point
    def handle(self, env_dict: dict[str, Any], signature: str, peer: PeerIdentity | None) -> Result:
        src = str(env_dict.get("source", "?"))
        cap = str(env_dict.get("capability", "?"))
        args = env_dict.get("args") if isinstance(env_dict.get("args"), dict) else {}
        try:
            env = self._authenticate(env_dict, signature, peer)
            self._authorize(env)
            clean = validate(env.capability, env.args)
            self._confirm_if_needed(env, clean)
            value = self._execute(env, clean)
            self.audit.record(source=src, target=self.device_id, capability=cap, args=args, result="ok")
            return Result(True, value)
        except ConflictError as e:
            self.audit.record(source=src, target=self.device_id, capability=cap, args=args,
                              result="conflict", error=str(e))
            return Result(False, error_code=e.code, error=str(e), conflict=e.conflict.to_dict())
        except ConfirmationRequired as e:
            self.audit.record(source=src, target=self.device_id, capability=cap, args=args,
                              result="confirmation_required")
            return Result(False, value={"confirmation_id": str(e)}, error_code=e.code,
                          error="confirmation required on the target device")
        except GridError as e:
            self.audit.record(source=src, target=self.device_id, capability=cap, args=args,
                              result="denied" if isinstance(e, (AuthenticationError, PermissionDenied)) else "error",
                              error=f"{e.code}: {e}")
            return Result(False, error_code=e.code, error=str(e))
        except Exception as e:  # never leak internals to the caller
            self.audit.record(source=src, target=self.device_id, capability=cap, args=args,
                              result="error", error=f"internal: {type(e).__name__}")
            return Result(False, error_code="internal_error", error="internal error")

    # ------------------------------------------------------------------ steps
    def _authenticate(self, d: dict[str, Any], signature: str, peer: PeerIdentity | None) -> Envelope:
        try:
            env = Envelope(source=d["source"], target=d["target"], capability=d["capability"], args=d["args"],
                           ts=float(d["ts"]), nonce=str(d["nonce"]), confirmation_id=d.get("confirmation_id"))
        except (KeyError, TypeError, ValueError):
            raise ValidationError("malformed envelope")
        if peer is None or peer.owner.lower() != self.owner.lower():
            raise AuthenticationError("peer is not on this Grid's identity")
        if env.target != self.device_id:
            raise AuthenticationError("wrong target device")
        rec = self.registry.get(env.source)
        if rec is None or rec.state is not DeviceState.APPROVED:
            raise AuthenticationError("device not approved")
        if self.registry.is_suspended(env.source):
            raise AuthenticationError("peer disconnected")
        if rec.transport_id != peer.transport_id:
            raise AuthenticationError("transport identity does not match registered device")
        if not verify(rec.sign_pubkey, env.signing_bytes(), signature):
            raise AuthenticationError("bad signature")
        now = time.time()
        if abs(now - env.ts) > MAX_SKEW:
            raise AuthenticationError("stale request")
        with self._lock:
            self._nonces = {n: t for n, t in self._nonces.items() if now - t < 2 * MAX_SKEW}
            if env.nonce in self._nonces:
                raise AuthenticationError("replayed request")
            self._nonces[env.nonce] = now
        return env

    def _authorize(self, env: Envelope) -> None:
        rec = self.registry.get(env.source)
        assert rec is not None
        if not authz.is_allowed(rec, env.capability, self.registry.grants(env.source)):
            raise PermissionDenied(f"{rec.role.value} device may not use {env.capability}")
        if env.capability not in self.capabilities():      # checked after authz: don't leak capability lists
            raise UnsupportedCapability(env.capability)

    def _confirm_if_needed(self, env: Envelope, clean: dict) -> None:
        if not authz.is_sensitive(env.capability):
            return
        h = _args_hash(clean)
        with self._lock:
            c = self._confirms.get(env.confirmation_id or "")
            if c and c["approved"] and c["expires"] > time.time() and (c["source"], c["capability"], c["hash"]) == (
                    env.source, env.capability, h):
                del self._confirms[env.confirmation_id]          # single use
                return
            cid = uuid.uuid4().hex[:12]
            self._confirms[cid] = {"source": env.source, "capability": env.capability, "args": clean, "hash": h,
                                   "approved": False, "expires": time.time() + CONFIRM_TTL}
        raise ConfirmationRequired(cid)

    def _execute(self, env: Envelope, a: dict) -> Any:
        cap = env.capability
        if cap == "device.info":
            return {"device_id": self.device_id, "name": self.name, "role": self.role.value,
                    "platform": self.adapter.platform, "version": __version__, "capabilities": self.capabilities()}
        if cap in FILE_CAPS and self.files:
            return getattr(self.files, FILE_CAPS[cap])(env.source, a)
        return self.adapter.invoke(cap, a)
