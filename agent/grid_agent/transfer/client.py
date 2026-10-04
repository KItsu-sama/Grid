"""Sender/receiver side of chunked, resumable, verified transfers."""
from __future__ import annotations

import base64
import hashlib
import os
import threading
import time
from pathlib import Path
from typing import Callable

from ..client import GridClient, RemoteError
from ..protocol import Conflict, ConflictError, FileVersion
from .limiter import TokenBucket

Progress = Callable[[int, int], None]


class Cancelled(Exception):
    pass


class TransferControl:
    def __init__(self):
        self._run = threading.Event()
        self._run.set()
        self.cancelled = False

    def pause(self): self._run.clear()
    def resume(self): self._run.set()
    def cancel(self): self.cancelled = True; self._run.set()

    def checkpoint(self) -> None:
        self._run.wait()
        if self.cancelled:
            raise Cancelled()


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()


def upload(client: GridClient, local: Path, remote: str, *, base_sha256: str | None = None,
           chunk_size: int = 4 * 1024 * 1024, progress: Progress | None = None,
           control: TransferControl | None = None, limiter: TokenBucket | None = None,
           retries: int = 3) -> dict:
    """Upload `local` to `remote`. Resumes automatically; raises RemoteError (with .conflict) on conflict."""
    control = control or TransferControl()
    local = Path(local)
    size, sha = local.stat().st_size, sha256_file(local)
    begin = client.call("transfer.begin", path=remote, size=size, sha256=sha, chunk_size=chunk_size,
                        base_sha256=base_sha256, mtime=local.stat().st_mtime)
    sid, cs, have = begin["session"], begin["chunk_size"], set(begin["have"])
    n = max(1, -(-size // cs)) if size else 0
    done = len(have) * cs
    with local.open("rb") as f:
        for i in range(n):
            if i in have:
                continue
            control.checkpoint()
            f.seek(i * cs)
            data = f.read(cs)
            if limiter:
                limiter.consume(len(data))
            for attempt in range(retries):
                try:
                    client.call("transfer.put_chunk", session=sid, index=i,
                                data=base64.b64encode(data).decode(), sha256=hashlib.sha256(data).hexdigest())
                    break
                except RemoteError as e:
                    if attempt == retries - 1 or e.code != "internal_error":
                        raise
                    time.sleep(0.2 * (attempt + 1))
            done = min(size, done + len(data))
            if progress:
                progress(done, size)
    control.checkpoint()
    return client.call("transfer.commit", session=sid)


def download(client: GridClient, remote: str, local: Path, *, base_sha256: str | None = None,
             chunk_size: int = 4 * 1024 * 1024, progress: Progress | None = None,
             control: TransferControl | None = None, limiter: TokenBucket | None = None,
             self_device: str = "local") -> dict:
    """Download with resume (via <local>.gridpart) and final SHA-256 verification.
    Refuses to overwrite a local file that changed since `base_sha256` (raises ConflictError)."""
    control = control or TransferControl()
    local = Path(local)
    st = client.call("files.stat", path=remote)
    if st is None or st["is_dir"]:
        raise FileNotFoundError(remote)
    size, rsha = st["size"], st["sha256"]
    if local.exists():
        lsha = sha256_file(local)
        if lsha == rsha:
            return {"path": str(local), "sha256": rsha, "size": size, "unchanged": True}
        if base_sha256 is None or base_sha256 != lsha:
            ls = local.stat()
            raise ConflictError(Conflict(
                self_device, client.target_id, remote,
                FileVersion(self_device, str(local), ls.st_size, ls.st_mtime, lsha),
                FileVersion(client.target_id, remote, size, st["mtime"], rsha), base_sha256))
    part = local.with_name(local.name + ".gridpart")
    local.parent.mkdir(parents=True, exist_ok=True)
    offset = (part.stat().st_size // chunk_size) * chunk_size if part.exists() else 0
    with part.open("r+b" if part.exists() else "wb") as f:
        f.truncate(offset)
        f.seek(offset)
        while offset < size:
            control.checkpoint()
            r = client.call("files.read", path=remote, offset=offset, length=min(chunk_size, size - offset))
            data = base64.b64decode(r["data"])
            if hashlib.sha256(data).hexdigest() != r["sha256"] or not data:
                raise IOError("chunk verification failed")
            if limiter:
                limiter.consume(len(data))
            f.write(data)
            offset += len(data)
            if progress:
                progress(offset, size)
    if sha256_file(part) != rsha:
        part.unlink()
        raise IOError("final hash mismatch; download discarded")
    os.replace(part, local)
    return {"path": str(local), "sha256": rsha, "size": size}
