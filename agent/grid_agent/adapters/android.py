"""Android adapter contract.

Python cannot call Android APIs directly. The native Grid Android app (Kotlin) implements
these capabilities with AudioManager / Intents / Storage Access Framework and exposes them to
this process through a local bridge (e.g. loopback HTTP or Binder). This class is the
protocol-side seam: same capability names, no Android-specific logic leaking upward."""
from __future__ import annotations

from typing import Any, Callable

from ..protocol import UnsupportedCapability
from .base import PlatformAdapter

ANDROID_CAPS = {"audio.volume.get", "audio.volume.set", "audio.play", "audio.pause", "app.launch"}


class AndroidAdapter(PlatformAdapter):
    platform = "android"

    def __init__(self, bridge: Callable[[str, dict[str, Any]], Any], supported: set[str] | None = None):
        self.bridge = bridge
        self._caps = (supported or ANDROID_CAPS) & ANDROID_CAPS

    def capabilities(self) -> set[str]:
        return set(self._caps)

    def invoke(self, capability: str, args: dict[str, Any]) -> Any:
        if capability not in self._caps:
            raise UnsupportedCapability(capability)
        return self.bridge(capability, args)
