"""Typed capability catalogue: name -> argument spec. No generic 'run command' capability."""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable

from .protocol import ValidationError


@dataclass(frozen=True)
class Arg:
    type: type | tuple
    required: bool = True
    check: Callable[[Any], bool] | None = None
    default: Any = None


def _s(max_len=1024): return lambda v: 0 < len(v) <= max_len
def _rng(lo, hi): return lambda v: lo <= v <= hi


CATALOGUE: dict[str, dict[str, Arg]] = {
    "device.info": {},
    "files.list": {"path": Arg(str, False, lambda v: len(v) <= 1024, "")},
    "files.stat": {"path": Arg(str, check=_s())},
    "files.read": {"path": Arg(str, check=_s()), "offset": Arg(int, False, _rng(0, 2**62), 0),
                   "length": Arg(int, False, _rng(1, 16 * 1024 * 1024), 4 * 1024 * 1024)},
    "files.write": {"path": Arg(str, check=_s()), "data": Arg(str), "base_sha256": Arg((str, type(None)), False)},
    "files.mkdir": {"path": Arg(str, check=_s())},
    "files.move": {"src": Arg(str, check=_s()), "dst": Arg(str, check=_s())},
    "files.copy": {"src": Arg(str, check=_s()), "dst": Arg(str, check=_s())},
    "files.delete": {"path": Arg(str, check=_s()), "base_sha256": Arg((str, type(None)), False)},
    "transfer.begin": {"path": Arg(str, check=_s()), "size": Arg(int, check=_rng(0, 2**50)),
                       "sha256": Arg(str, check=lambda v: len(v) == 64),
                       "chunk_size": Arg(int, False, _rng(64 * 1024, 64 * 1024 * 1024), 4 * 1024 * 1024),
                       "base_sha256": Arg((str, type(None)), False), "mtime": Arg((int, float), False, None, 0)},
    "transfer.put_chunk": {"session": Arg(str, check=_s(64)), "index": Arg(int, check=_rng(0, 2**31)),
                           "data": Arg(str), "sha256": Arg(str, check=lambda v: len(v) == 64)},
    "transfer.commit": {"session": Arg(str, check=_s(64))},
    "transfer.abort": {"session": Arg(str, check=_s(64))},
    "transfer.status": {"session": Arg(str, check=_s(64))},
    "audio.volume.get": {},
    "audio.volume.set": {"volume": Arg(int, check=_rng(0, 100))},
    "audio.play": {"path": Arg(str, check=_s())},
    "audio.pause": {},
    "app.launch": {"app": Arg(str, check=_s(64))},        # id from the target's allowlist, never a path
    "process.read": {},
    "process.stop": {"pid": Arg(int, check=_rng(1, 2**31))},
    "power.sleep": {},
    "power.shutdown": {"delay_seconds": Arg(int, False, _rng(5, 3600), 30)},
    "environment.read": {"name": Arg(str, check=_s(256))},
    "environment.modify": {"name": Arg(str, check=_s(256)), "value": Arg(str, check=lambda v: len(v) <= 8192)},
}


def validate(capability: str, args: dict[str, Any]) -> dict[str, Any]:
    spec = CATALOGUE.get(capability)
    if spec is None:
        raise ValidationError(f"unknown capability {capability}")
    unknown = set(args) - set(spec)
    if unknown:
        raise ValidationError(f"unexpected arguments: {sorted(unknown)}")
    out: dict[str, Any] = {}
    for name, a in spec.items():
        if name not in args:
            if a.required:
                raise ValidationError(f"missing argument: {name}")
            out[name] = a.default
            continue
        v = args[name]
        if isinstance(v, bool) and a.type in (int, (int, float)):
            raise ValidationError(f"{name}: wrong type")
        if not isinstance(v, a.type):
            raise ValidationError(f"{name}: wrong type")
        if v is not None and a.check and not a.check(v):
            raise ValidationError(f"{name}: out of range or invalid")
        out[name] = v
    return out
