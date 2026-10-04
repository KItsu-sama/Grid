"""Change detection + three-way diff for directory synchronisation.

Pure functions, no I/O beyond scanning a FileSystem: easy to test, and independent of whether
Syncthing or Grid's own engine moves the bytes. `base` is the last state both sides agreed on;
it is what lets us tell "changed on one side" from "changed on both" and propagate deletions
safely instead of resurrecting or silently dropping files.
"""
from __future__ import annotations

from dataclasses import dataclass

from .fs import FileSystem

Snapshot = dict[str, str]          # relative path -> sha256


def snapshot(fs: FileSystem, vroot: str) -> Snapshot:
    out: Snapshot = {}
    stack = [vroot.strip("/")]
    while stack:
        d = stack.pop()
        for e in fs.list(d):
            vp = f"{d}/{e.name}"
            if e.is_dir:
                stack.append(vp)
            else:
                h = fs.sha256(vp)
                if h:
                    out[vp[len(vroot.strip('/')) + 1:]] = h
    return out


@dataclass(frozen=True)
class Action:
    kind: str       # upload | download | delete_local | delete_remote | conflict
    path: str


def diff3(base: Snapshot, local: Snapshot, remote: Snapshot) -> list[Action]:
    acts: list[Action] = []
    for p in sorted(set(base) | set(local) | set(remote)):
        b, l, r = base.get(p), local.get(p), remote.get(p)
        if l == r:
            continue                                   # identical (or both absent)
        if l == b:                                     # only remote changed
            acts.append(Action("download" if r else "delete_local", p))
        elif r == b:                                   # only local changed
            acts.append(Action("upload" if l else "delete_remote", p))
        else:                                          # both changed differently (incl. edit vs delete)
            acts.append(Action("conflict", p))
    return acts
