"""Filesystem abstraction + Grid roots.

The protocol only ever sees *virtual* paths like "shared/music/a.mp3": first segment is a
configured Grid root name. Absolute OS paths never cross the wire. Android implements the
same `FileSystem` interface on top of the Storage Access Framework (SAF).
"""
from __future__ import annotations

import abc
import hashlib
import os
import re
import shutil
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import BinaryIO

from .protocol import ValidationError

PART_SUFFIX = ".gridpart"
_RESERVED = {"CON", "PRN", "AUX", "NUL", *(f"COM{i}" for i in range(1, 10)), *(f"LPT{i}" for i in range(1, 10))}
_BAD_CHARS = re.compile(r'[<>:"|?*\\\x00-\x1f]')


@dataclass
class Entry:
    name: str
    is_dir: bool
    size: int
    mtime: float


class FileSystem(abc.ABC):
    @abc.abstractmethod
    def list(self, vpath: str) -> list[Entry]: ...
    @abc.abstractmethod
    def stat(self, vpath: str) -> Entry | None: ...
    @abc.abstractmethod
    def sha256(self, vpath: str) -> str | None: ...
    @abc.abstractmethod
    def read_range(self, vpath: str, offset: int, length: int) -> bytes: ...
    @abc.abstractmethod
    def mkdir(self, vpath: str) -> None: ...
    @abc.abstractmethod
    def move(self, src: str, dst: str) -> None: ...
    @abc.abstractmethod
    def copy(self, src: str, dst: str) -> None: ...
    @abc.abstractmethod
    def delete(self, vpath: str) -> None: ...
    @abc.abstractmethod
    def write_atomic(self, vpath: str, data: bytes, mtime: float | None = None) -> None: ...
    # partial files for resumable transfers
    @abc.abstractmethod
    def partial_create(self, vpath: str, session: str, size: int) -> str: ...
    @abc.abstractmethod
    def partial_write(self, handle: str, offset: int, data: bytes) -> None: ...
    @abc.abstractmethod
    def partial_sha256(self, handle: str) -> str: ...
    @abc.abstractmethod
    def partial_commit(self, handle: str, vpath: str, mtime: float | None) -> None: ...
    @abc.abstractmethod
    def partial_discard(self, handle: str) -> None: ...


class GridRoots:
    def __init__(self, roots: dict[str, Path | str]):
        self.roots: dict[str, Path] = {}
        for name, p in roots.items():
            self._check_segment(name)
            path = Path(p)
            path.mkdir(parents=True, exist_ok=True)
            self.roots[name] = path.resolve()

    @staticmethod
    def _check_segment(seg: str, allow_internal: bool = False) -> None:
        if not seg or seg in (".", "..") or _BAD_CHARS.search(seg):
            raise ValidationError(f"invalid path segment: {seg!r}")
        if seg != seg.rstrip(" .") or seg.split(".")[0].upper() in _RESERVED:
            raise ValidationError(f"invalid path segment: {seg!r}")
        if not allow_internal and (seg.startswith(".grid") or seg.endswith(PART_SUFFIX)):
            raise ValidationError("reserved name")

    def split(self, vpath: str, allow_internal: bool = False) -> tuple[str, list[str]]:
        if vpath.startswith("/") or "\\" in vpath or ":" in vpath:
            raise ValidationError("path must be relative and use '/'")
        parts = [p for p in vpath.split("/") if p != ""]
        if not parts:
            raise ValidationError("empty path")
        for seg in parts:
            self._check_segment(seg, allow_internal)
        if parts[0] not in self.roots:
            raise ValidationError(f"unknown root: {parts[0]}")
        return parts[0], parts[1:]

    def resolve(self, vpath: str, allow_internal: bool = False) -> Path:
        root_name, rest = self.split(vpath, allow_internal)
        root = self.roots[root_name]
        target = root.joinpath(*rest)
        # Resolve symlinks of the longest existing prefix, then verify containment.
        real = Path(os.path.realpath(target))
        if real != root and root not in real.parents:
            raise ValidationError("path escapes Grid root")
        return real


class LocalFS(FileSystem):
    def __init__(self, roots: GridRoots):
        self.roots = roots
        self._hash_cache: dict[tuple[str, int, int], str] = {}
        self._lock = threading.Lock()

    @staticmethod
    def _entry(p: Path) -> Entry:
        st = p.stat()
        return Entry(p.name, p.is_dir(), 0 if p.is_dir() else st.st_size, st.st_mtime)

    def list(self, vpath: str) -> list[Entry]:
        if not vpath.strip("/"):
            return [Entry(n, True, 0, p.stat().st_mtime) for n, p in sorted(self.roots.roots.items())]
        p = self.roots.resolve(vpath)
        if not p.is_dir():
            raise ValidationError("not a directory")
        return [self._entry(c) for c in sorted(p.iterdir())
                if not c.name.startswith(".grid") and not c.name.endswith(PART_SUFFIX)]

    def stat(self, vpath: str) -> Entry | None:
        p = self.roots.resolve(vpath)
        return self._entry(p) if p.exists() else None

    def _hash_path(self, p: Path) -> str:
        st = p.stat()
        key = (str(p), st.st_size, st.st_mtime_ns)
        with self._lock:
            if key in self._hash_cache:
                return self._hash_cache[key]
        h = hashlib.sha256()
        with p.open("rb") as f:
            for block in iter(lambda: f.read(1 << 20), b""):
                h.update(block)
        with self._lock:
            self._hash_cache[key] = h.hexdigest()
        return h.hexdigest()

    def sha256(self, vpath: str) -> str | None:
        p = self.roots.resolve(vpath)
        return self._hash_path(p) if p.is_file() else None

    def read_range(self, vpath: str, offset: int, length: int) -> bytes:
        p = self.roots.resolve(vpath)
        if not p.is_file():
            raise ValidationError("not a file")
        with p.open("rb") as f:
            f.seek(offset)
            return f.read(length)

    def mkdir(self, vpath: str) -> None:
        self.roots.resolve(vpath).mkdir(parents=True, exist_ok=True)

    def move(self, src: str, dst: str) -> None:
        s, d = self.roots.resolve(src), self.roots.resolve(dst)
        if d.exists():
            raise ValidationError("destination exists")
        d.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(s), str(d))

    def copy(self, src: str, dst: str) -> None:
        s, d = self.roots.resolve(src), self.roots.resolve(dst)
        if d.exists():
            raise ValidationError("destination exists")
        d.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(s, d) if s.is_dir() else shutil.copy2(s, d)

    def delete(self, vpath: str) -> None:
        p = self.roots.resolve(vpath)
        if p in self.roots.roots.values():
            raise ValidationError("cannot delete a Grid root")
        if p.is_dir():
            p.rmdir()                 # non-recursive on purpose; recursive delete is a sensitive capability
        else:
            p.unlink()

    def write_atomic(self, vpath: str, data: bytes, mtime: float | None = None) -> None:
        dest = self.roots.resolve(vpath)
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_name(f".{dest.name}.{os.getpid()}{PART_SUFFIX}")
        tmp.write_bytes(data)
        if mtime:
            os.utime(tmp, (mtime, mtime))
        os.replace(tmp, dest)

    # -- partial files
    def _part_vpath(self, vpath: str, session: str) -> str:
        parent, _, name = vpath.rpartition("/")
        return f"{parent}/.{name}.{session}{PART_SUFFIX}"

    def partial_create(self, vpath: str, session: str, size: int) -> str:
        self.roots.resolve(vpath)                               # validates the final path
        handle = self._part_vpath(vpath, session)
        p = self.roots.resolve(handle, allow_internal=True)
        p.parent.mkdir(parents=True, exist_ok=True)
        if not p.exists():
            with p.open("wb") as f:
                f.truncate(size)
        return handle

    def partial_write(self, handle: str, offset: int, data: bytes) -> None:
        with self.roots.resolve(handle, allow_internal=True).open("r+b") as f:
            f.seek(offset)
            f.write(data)

    def partial_sha256(self, handle: str) -> str:
        h = hashlib.sha256()
        with self.roots.resolve(handle, allow_internal=True).open("rb") as f:
            for block in iter(lambda: f.read(1 << 20), b""):
                h.update(block)
        return h.hexdigest()

    def partial_commit(self, handle: str, vpath: str, mtime: float | None) -> None:
        src = self.roots.resolve(handle, allow_internal=True)
        if mtime:
            os.utime(src, (mtime, mtime))
        os.replace(src, self.roots.resolve(vpath))

    def partial_discard(self, handle: str) -> None:
        self.roots.resolve(handle, allow_internal=True).unlink(missing_ok=True)
