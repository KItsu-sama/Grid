"""Tailscale transport via the `tailscale` CLI (WireGuard, NAT traversal, DERP relay, IP
allocation, SSO login and 2FA are all handled by Tailscale; Grid never reimplements them).

Field names follow `tailscale status --json` / `tailscale whois --json`; parsing is defensive
because they vary slightly between Tailscale versions. Verify against your installed version.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import time
from datetime import datetime
from typing import Callable

from .base import PeerIdentity, PeerStatus, Transport, TransportStatus

Runner = Callable[[list[str], float], tuple[int, str]]


def _run(cmd: list[str], timeout: float) -> tuple[int, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, shell=False)
        return p.returncode, p.stdout if p.returncode == 0 else (p.stdout + p.stderr)
    except (OSError, subprocess.TimeoutExpired) as e:
        return 1, str(e)


def _ts(s: str | None) -> float:
    if not s or s.startswith("0001"):
        return 0.0
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return 0.0


class TailscaleTransport(Transport):
    def __init__(self, binary: str | None = None, runner: Runner = _run):
        self.binary = binary or shutil.which("tailscale") or "tailscale"
        self._run = runner

    def _json(self, *args: str, timeout: float = 5.0) -> dict | None:
        code, out = self._run([self.binary, *args], timeout)
        if code != 0:
            return None
        try:
            return json.loads(out)
        except json.JSONDecodeError:
            return None

    def status(self) -> TransportStatus:
        d = self._json("status", "--json")
        if d is None:
            return TransportStatus(False, False, detail="tailscale not running or not installed")
        me = d.get("Self") or {}
        users = d.get("User") or {}
        owner = (users.get(str(me.get("UserID"))) or {}).get("LoginName", "")
        state = d.get("BackendState", "")
        return TransportStatus(
            running=True, logged_in=state == "Running", self_id=me.get("ID", ""),
            self_name=me.get("HostName", ""), self_addresses=list(me.get("TailscaleIPs") or []),
            owner=owner, detail=state)

    def peers(self) -> list[PeerStatus]:
        d = self._json("status", "--json") or {}
        out = []
        for p in (d.get("Peer") or {}).values():
            out.append(PeerStatus(
                transport_id=p.get("ID", ""), name=p.get("HostName", ""),
                addresses=list(p.get("TailscaleIPs") or []), online=bool(p.get("Online")),
                wg_pubkey=p.get("PublicKey", ""), last_seen=_ts(p.get("LastSeen")),
                relayed=bool(p.get("Relay")) and not p.get("CurAddr")))
        return out

    def whois(self, remote_addr: str) -> PeerIdentity | None:
        host = remote_addr.rsplit(":", 1)[0] if remote_addr.count(":") == 1 else remote_addr
        d = self._json("whois", "--json", host)
        if not d or not d.get("Node"):
            return None
        node, user = d["Node"], d.get("UserProfile") or {}
        return PeerIdentity(
            transport_id=node.get("StableID", ""), owner=user.get("LoginName", ""),
            name=node.get("Name", ""), wg_pubkey=node.get("Key", ""),
            addresses=list(node.get("Addresses") or []))

    def ping(self, address: str, timeout: float = 3.0) -> float | None:
        t0 = time.monotonic()
        code, _ = self._run([self.binary, "ping", "--c", "1", f"--timeout={int(timeout)}s", address], timeout + 2)
        return time.monotonic() - t0 if code == 0 else None

    def reauthenticate(self) -> None:
        # Forces a fresh node key. Interactive: the IdP (Google/Microsoft) login + 2FA runs in the browser.
        self._run([self.binary, "up", "--force-reauth"], 300)
