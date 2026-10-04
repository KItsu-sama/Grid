"""Append-only, hash-chained audit log (JSON lines). Tampering breaks the chain."""
from __future__ import annotations

import hashlib
import json
import threading
import time
from pathlib import Path
from typing import Any

GENESIS = "0" * 64


class AuditLog:
    def __init__(self, path: Path):
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._last = self._load_last()

    def _load_last(self) -> str:
        if not self.path.exists():
            return GENESIS
        last = GENESIS
        with self.path.open("rb") as f:
            for line in f:
                if line.strip():
                    last = json.loads(line)["hash"]
        return last

    @staticmethod
    def _digest(prev: str, body: dict[str, Any]) -> str:
        blob = json.dumps(body, sort_keys=True, separators=(",", ":"), default=str).encode()
        return hashlib.sha256(prev.encode() + blob).hexdigest()

    def record(self, *, source: str, target: str, capability: str, args: Any,
               result: str, error: str | None = None, **extra: Any) -> dict[str, Any]:
        body = {"ts": time.time(), "source": source, "target": target, "capability": capability,
                "args": _redact(args), "result": result, "error": error, **extra}
        with self._lock:
            h = self._digest(self._last, body)
            entry = {**body, "prev": self._last, "hash": h}
            with self.path.open("a", encoding="utf-8") as f:
                f.write(json.dumps(entry, sort_keys=True, default=str) + "\n")
            self._last = h
        return entry

    def entries(self) -> list[dict[str, Any]]:
        if not self.path.exists():
            return []
        with self.path.open("r", encoding="utf-8") as f:
            return [json.loads(l) for l in f if l.strip()]

    def verify(self) -> tuple[bool, int | None]:
        """Return (ok, index_of_first_bad_entry)."""
        prev = GENESIS
        for i, e in enumerate(self.entries()):
            body = {k: v for k, v in e.items() if k not in ("prev", "hash")}
            if e["prev"] != prev or self._digest(prev, body) != e["hash"]:
                return False, i
            prev = e["hash"]
        return True, None


_SECRET_KEYS = {"content", "data", "token", "secret", "password"}


def _redact(args: Any) -> Any:
    """Never write file bodies or secrets into the audit log."""
    if isinstance(args, dict):
        return {k: ("<redacted>" if k in _SECRET_KEYS else _redact(v)) for k, v in args.items()}
    if isinstance(args, list):
        return [_redact(v) for v in args]
    return args
