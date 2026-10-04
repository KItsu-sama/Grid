"""Caller side: builds signed envelopes and sends them to a peer's Agent."""
from __future__ import annotations

import time
import uuid
from typing import Any, Callable

from .identity import DeviceIdentity
from .protocol import Envelope

Sender = Callable[[dict, str], dict]


class RemoteError(Exception):
    def __init__(self, result: dict):
        super().__init__(f"{result.get('error_code')}: {result.get('error')}")
        self.code = result.get("error_code")
        self.conflict = result.get("conflict")
        self.value = result.get("value")


class GridClient:
    def __init__(self, identity: DeviceIdentity, target_id: str, sender: Sender):
        self.identity, self.target_id, self.sender = identity, target_id, sender

    def call(self, capability: str, confirmation_id: str | None = None, **args: Any) -> Any:
        env = Envelope(self.identity.device_id, self.target_id, capability, args, ts=time.time(),
                       nonce=uuid.uuid4().hex, confirmation_id=confirmation_id)
        res = self.sender(env.to_dict(), self.identity.sign(env.signing_bytes()))
        if not res.get("ok"):
            raise RemoteError(res)
        return res.get("value")


def http_sender(base_url: str, timeout: float = 30.0) -> Sender:
    import httpx

    def send(env: dict, sig: str) -> dict:
        r = httpx.post(f"{base_url}/v1/invoke", json={"envelope": env, "signature": sig}, timeout=timeout)
        r.raise_for_status()
        return r.json()
    return send
