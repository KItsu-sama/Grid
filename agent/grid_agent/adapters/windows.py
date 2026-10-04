"""Windows adapter. All commands are fixed argument lists (shell=False); remote callers
choose from typed capabilities only. app.launch uses an allowlist of app ids -> executables.

NOTE: not exercised on Windows in CI here; subprocess-based capabilities are unit-tested with an
injected runner. The pycaw volume code depends on your pycaw version, so test it on a real PC."""
from __future__ import annotations

import os
import subprocess
from typing import Any, Callable

from ..protocol import UnsupportedCapability, ValidationError
from .base import PlatformAdapter

Runner = Callable[[list[str]], Any]


def _default_runner(cmd: list[str]) -> Any:
    subprocess.run(cmd, check=True, shell=False, timeout=30)


class WindowsAdapter(PlatformAdapter):
    platform = "windows"

    def __init__(self, apps: dict[str, str] | None = None, resolve_path: Callable[[str], str] | None = None,
                 env_readable: set[str] | None = None, runner: Runner = _default_runner):
        self.apps = apps or {}
        self.resolve_path = resolve_path
        self.env_readable = env_readable or set()
        self.run = runner

    def capabilities(self) -> set[str]:
        caps = {"power.sleep", "power.shutdown", "process.read", "process.stop", "environment.read"}
        if self.apps:
            caps.add("app.launch")
        if self.resolve_path:
            caps.add("audio.play")
        try:
            import pycaw  # noqa: F401
            caps |= {"audio.volume.get", "audio.volume.set"}
        except ImportError:
            pass
        return caps

    def invoke(self, capability: str, args: dict[str, Any]) -> Any:
        if capability == "app.launch":
            exe = self.apps.get(args["app"])
            if exe is None:
                raise ValidationError("app not in allowlist")
            self.run([exe])
            return {"launched": args["app"]}
        if capability == "audio.play":
            if not self.resolve_path:
                raise UnsupportedCapability(capability)
            os.startfile(self.resolve_path(args["path"]))  # type: ignore[attr-defined]  # default player
            return {"playing": args["path"]}
        if capability in ("audio.volume.get", "audio.volume.set"):
            return self._volume(capability, args)
        if capability == "power.sleep":
            self.run(["rundll32.exe", "powrprof.dll,SetSuspendState", "0,1,0"])
            return {"done": True}
        if capability == "power.shutdown":
            self.run(["shutdown", "/s", "/t", str(args["delay_seconds"])])
            return {"scheduled_in": args["delay_seconds"]}
        if capability == "process.stop":
            if args["pid"] <= 4 or args["pid"] == os.getpid():
                raise ValidationError("refusing to stop protected process")
            self.run(["taskkill", "/PID", str(args["pid"])])      # graceful; no /F
            return {"stopped": args["pid"]}
        if capability == "process.read":
            import psutil
            return [{"pid": p.pid, "name": p.info["name"]} for p in psutil.process_iter(["name"])]
        if capability == "environment.read":
            if args["name"] not in self.env_readable:
                raise ValidationError("variable not readable")
            return {"value": os.environ.get(args["name"])}
        raise UnsupportedCapability(capability)

    def _volume(self, capability: str, args: dict[str, Any]) -> Any:
        try:
            from ctypes import POINTER, cast
            from comtypes import CLSCTX_ALL
            from pycaw.pycaw import AudioUtilities, IAudioEndpointVolume
        except ImportError as e:
            raise UnsupportedCapability(capability) from e
        dev = AudioUtilities.GetSpeakers()
        iface = dev.Activate(IAudioEndpointVolume._iid_, CLSCTX_ALL, None)
        vol = cast(iface, POINTER(IAudioEndpointVolume))
        if capability == "audio.volume.set":
            vol.SetMasterVolumeLevelScalar(args["volume"] / 100.0, None)
        return {"volume": round(vol.GetMasterVolumeLevelScalar() * 100)}
