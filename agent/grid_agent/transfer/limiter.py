from __future__ import annotations

import threading
import time
from typing import Callable


class TokenBucket:
    """Bandwidth limiter in bytes/second. rate<=0 means unlimited."""

    def __init__(self, rate: float, clock: Callable[[], float] = time.monotonic,
                 sleep: Callable[[float], None] = time.sleep):
        self.rate, self._clock, self._sleep = rate, clock, sleep
        self._allow, self._last = rate, clock()
        self._lock = threading.Lock()

    def set_rate(self, rate: float) -> None:
        with self._lock:
            self.rate = rate

    def consume(self, n: int) -> None:
        if self.rate <= 0:
            return
        with self._lock:
            now = self._clock()
            self._allow = min(self.rate, self._allow + (now - self._last) * self.rate)
            self._last = now
            self._allow -= n
            wait = -self._allow / self.rate if self._allow < 0 else 0.0
        if wait > 0:
            self._sleep(wait)
