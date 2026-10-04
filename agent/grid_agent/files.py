"""files.* and transfer.* capability handlers (receiver side). Platform independent."""
from __future__ import annotations

import base64
import hashlib
import json
import threading
import time
import uuid
from pathlib import Path
from typing import Any

from .fs import FileSystem
from .protocol import Conflict, ConflictError, FileVersion, ValidationError

CHUNK_DEFAULT = 4 * 1024 * 1024


class FileService:
    def __init__(self, fs: FileSystem, device_id: str, state_dir: Path):
        self.fs, self.device_id = fs, device_id
        self.dir = Path(state_dir) / "transfers"
        self.dir.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()

    # ---------------- plain files.*
    def list(self, source: str, a: dict) -> list[dict]:
        return [e.__dict__ for e in self.fs.list(a["path"])]

    def stat(self, source: str, a: dict) -> dict | None:
        e = self.fs.stat(a["path"])
        return None if e is None else {**e.__dict__, "sha256": None if e.is_dir else self.fs.sha256(a["path"])}

    def read(self, source: str, a: dict) -> dict:
        data = self.fs.read_range(a["path"], a["offset"], a["length"])
        return {"data": base64.b64encode(data).decode(), "offset": a["offset"], "length": len(data),
                "sha256": hashlib.sha256(data).hexdigest()}

    def mkdir(self, source: str, a: dict) -> None:
        self.fs.mkdir(a["path"])

    def move(self, source: str, a: dict) -> None:
        self.fs.move(a["src"], a["dst"])

    def copy(self, source: str, a: dict) -> None:
        self.fs.copy(a["src"], a["dst"])

    def delete(self, source: str, a: dict) -> None:
        self._check_base(source, a["path"], a.get("base_sha256"), incoming=None, deleting=True)
        self.fs.delete(a["path"])

    def write(self, source: str, a: dict) -> dict:
        data = base64.b64decode(a["data"], validate=True)
        sha = hashlib.sha256(data).hexdigest()
        self._check_base(source, a["path"], a.get("base_sha256"), incoming=(sha, len(data), time.time()))
        self.fs.write_atomic(a["path"], data)
        return {"sha256": sha, "size": len(data)}

    # ---------------- conflict detection (never overwrite blindly)
    def _check_base(self, source: str, path: str, base: str | None,
                    incoming: tuple[str, int, float] | None, deleting: bool = False) -> None:
        cur = self.fs.stat(path)
        if cur is None or cur.is_dir:
            return
        cur_sha = self.fs.sha256(path)
        if incoming and cur_sha == incoming[0]:
            return                                       # identical content: idempotent
        if base is not None and base == cur_sha:
            return                                       # sender saw the current version: safe
        remote = FileVersion(self.device_id, path, cur.size, cur.mtime, cur_sha or "")
        local = FileVersion(source, path, incoming[1] if incoming else 0,
                            incoming[2] if incoming else 0.0, incoming[0] if incoming else "")
        raise ConflictError(Conflict(source, self.device_id, path, local, remote, base))

    # ---------------- resumable chunked upload
    def _meta_path(self, sid: str) -> Path:
        return self.dir / f"{sid}.json"

    def _load(self, sid: str, source: str) -> dict:
        p = self._meta_path(sid)
        if not p.exists():
            raise ValidationError("unknown session")
        m = json.loads(p.read_text())
        if m["source"] != source:
            raise ValidationError("session belongs to another device")
        return m

    def _save(self, m: dict) -> None:
        tmp = self._meta_path(m["session"]).with_suffix(".tmp")
        tmp.write_text(json.dumps(m))
        tmp.replace(self._meta_path(m["session"]))

    @staticmethod
    def _expected_len(m: dict, index: int) -> int:
        return min(m["chunk_size"], m["size"] - index * m["chunk_size"])

    def begin(self, source: str, a: dict) -> dict:
        with self._lock:
            self._check_base(source, a["path"], a.get("base_sha256"),
                             incoming=(a["sha256"], a["size"], a.get("mtime") or time.time()))
            # Deterministic session id => the same upload resumes after a crash/reconnect.
            sid = hashlib.sha256(f"{source}|{a['path']}|{a['sha256']}|{a['size']}|{a['chunk_size']}".encode()).hexdigest()[:32]
            p = self._meta_path(sid)
            if p.exists():
                m = self._load(sid, source)
            else:
                handle = self.fs.partial_create(a["path"], sid, a["size"])
                m = {"session": sid, "source": source, "path": a["path"], "size": a["size"], "sha256": a["sha256"],
                     "chunk_size": a["chunk_size"], "base_sha256": a.get("base_sha256"), "mtime": a.get("mtime") or 0,
                     "handle": handle, "received": {}, "created": time.time()}
                self._save(m)
            return {"session": sid, "chunk_size": m["chunk_size"], "have": sorted(map(int, m["received"]))}

    def put_chunk(self, source: str, a: dict) -> dict:
        with self._lock:
            m = self._load(a["session"], source)
            n_chunks = max(1, -(-m["size"] // m["chunk_size"]))
            i = a["index"]
            if i >= n_chunks:
                raise ValidationError("chunk index out of range")
            data = base64.b64decode(a["data"], validate=True)
            if len(data) != self._expected_len(m, i):
                raise ValidationError("wrong chunk length")
            if hashlib.sha256(data).hexdigest() != a["sha256"]:
                raise ValidationError("chunk hash mismatch")
            self.fs.partial_write(m["handle"], i * m["chunk_size"], data)
            m["received"][str(i)] = a["sha256"]
            self._save(m)
            return {"received": len(m["received"]), "total": n_chunks}

    def commit(self, source: str, a: dict) -> dict:
        with self._lock:
            m = self._load(a["session"], source)
            n_chunks = max(1, -(-m["size"] // m["chunk_size"])) if m["size"] else 0
            missing = [i for i in range(n_chunks) if str(i) not in m["received"]]
            if missing:
                raise ValidationError(f"missing chunks: {missing[:10]}")
            if self.fs.partial_sha256(m["handle"]) != m["sha256"]:
                self.fs.partial_discard(m["handle"])
                self._meta_path(m["session"]).unlink(missing_ok=True)
                raise ValidationError("final hash mismatch; upload discarded")
            # Re-check at commit time: the target file may have changed since begin().
            self._check_base(source, m["path"], m["base_sha256"], incoming=(m["sha256"], m["size"], m["mtime"]))
            self.fs.partial_commit(m["handle"], m["path"], m["mtime"] or None)
            self._meta_path(m["session"]).unlink(missing_ok=True)
            return {"path": m["path"], "sha256": m["sha256"], "size": m["size"]}

    def abort(self, source: str, a: dict) -> None:
        with self._lock:
            m = self._load(a["session"], source)
            self.fs.partial_discard(m["handle"])
            self._meta_path(m["session"]).unlink(missing_ok=True)

    def status(self, source: str, a: dict) -> dict:
        m = self._load(a["session"], source)
        return {"received": len(m["received"]), "path": m["path"], "size": m["size"]}
