"""Prioritised transfer queue with pause/resume/cancel and an offline hold (persisted)."""
from __future__ import annotations

import json
import threading
import time
import uuid
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Callable

from .client import Cancelled, TransferControl

QUEUED, RUNNING, PAUSED, DONE, FAILED, CANCELLED, OFFLINE = (
    "queued", "running", "paused", "done", "failed", "cancelled", "waiting_offline")


@dataclass
class Job:
    kind: str                     # "upload" | "download"
    peer: str
    local: str
    remote: str
    priority: int = 5             # lower runs first
    id: str = field(default_factory=lambda: uuid.uuid4().hex[:10])
    state: str = QUEUED
    done: int = 0
    total: int = 0
    error: str | None = None


class TransferQueue:
    """`runner(job, control, progress)` performs the transfer; `is_online(peer)` gates starting it."""

    def __init__(self, runner: Callable[[Job, TransferControl, Callable[[int, int], None]], None],
                 is_online: Callable[[str], bool], store: Path | None = None):
        self.runner, self.is_online, self.store = runner, is_online, store
        self.jobs: dict[str, Job] = {}
        self._ctl: dict[str, TransferControl] = {}
        self._lock = threading.RLock()
        if store and Path(store).exists():
            for d in json.loads(Path(store).read_text()):
                j = Job(**d)
                if j.state in (RUNNING, QUEUED, OFFLINE, PAUSED):
                    j.state = QUEUED          # survive restarts: re-queue unfinished work
                self.jobs[j.id] = j

    def _persist(self) -> None:
        if self.store:
            Path(self.store).write_text(json.dumps([asdict(j) for j in self.jobs.values()]))

    def add(self, job: Job) -> str:
        with self._lock:
            self.jobs[job.id] = job
            self._persist()
        return job.id

    def pause(self, jid: str) -> None:
        with self._lock:
            j = self.jobs[jid]
            if j.state == RUNNING:
                self._ctl[jid].pause()
            if j.state in (RUNNING, QUEUED, OFFLINE):
                j.state = PAUSED
            self._persist()

    def resume(self, jid: str) -> None:
        with self._lock:
            j = self.jobs[jid]
            if j.state == PAUSED:
                if jid in self._ctl:          # a transfer is mid-flight: just unblock it
                    self._ctl[jid].resume()
                    j.state = RUNNING
                else:
                    j.state = QUEUED
            self._persist()

    def cancel(self, jid: str) -> None:
        with self._lock:
            j = self.jobs[jid]
            if jid in self._ctl:
                self._ctl[jid].cancel()
            if j.state not in (DONE, FAILED):
                j.state = CANCELLED
            self._persist()

    def _next(self) -> Job | None:
        cands = sorted((j for j in self.jobs.values() if j.state in (QUEUED, OFFLINE)),
                       key=lambda j: (j.priority, j.id))
        for j in cands:
            if self.is_online(j.peer):
                return j
            j.state = OFFLINE
        return None

    def run_once(self) -> bool:
        """Run the best runnable job to completion. Returns False if nothing could start."""
        with self._lock:
            j = self._next()
            if j is None:
                self._persist()
                return False
            j.state = RUNNING
            ctl = self._ctl[j.id] = TransferControl()
        def progress(done: int, total: int) -> None:
            j.done, j.total = done, total
        try:
            self.runner(j, ctl, progress)
            j.state = DONE if j.state != CANCELLED else CANCELLED
        except Cancelled:
            j.state = CANCELLED
        except Exception as e:
            j.error = str(e)
            j.state = FAILED
        finally:
            with self._lock:
                self._ctl.pop(j.id, None)
                self._persist()
        return True

    def run_until_idle(self, max_jobs: int = 1000) -> None:
        for _ in range(max_jobs):
            if not self.run_once():
                return
