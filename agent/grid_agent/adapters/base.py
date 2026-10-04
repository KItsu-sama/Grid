"""Platform adapter contract. The Agent protocol never imports anything OS-specific."""
from __future__ import annotations

import abc
from typing import Any


class PlatformAdapter(abc.ABC):
    platform: str = "unknown"

    @abc.abstractmethod
    def capabilities(self) -> set[str]:
        """Platform capabilities this adapter really implements (files.* / transfer.* are core)."""

    @abc.abstractmethod
    def invoke(self, capability: str, args: dict[str, Any]) -> Any: ...


class MemoryAdapter(PlatformAdapter):
    """Test double that records calls."""
    platform = "memory"

    def __init__(self, caps: set[str] | None = None):
        self._caps = caps or {"audio.volume.get", "audio.volume.set", "audio.play", "audio.pause", "app.launch",
                              "process.read", "process.stop", "power.sleep", "power.shutdown"}
        self.calls: list[tuple[str, dict]] = []
        self.volume = 50

    def capabilities(self): return set(self._caps)

    def invoke(self, capability, args):
        self.calls.append((capability, dict(args)))
        if capability == "audio.volume.set":
            self.volume = args["volume"]
        return {"volume": self.volume} if capability.startswith("audio.volume") else {"done": True}
