"""Phone-facing Personal Grid API."""

import json
import os
import time
from pathlib import Path
from typing import Any

from fastapi import FastAPI
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field


PROJECT_ROOT = Path(__file__).resolve().parents[1]
START_TIME = time.time()
MAX_REQUEST_BODY_BYTES = 16 * 1024
app = FastAPI(title="Personal Grid API")


class RequestBodyTooLarge(Exception):
    pass


class RequestBodyLimitMiddleware:
    def __init__(self, app: Any, max_bytes: int) -> None:
        self.app = app
        self.max_bytes = max_bytes

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        content_length = next(
            (value for name, value in scope.get("headers", []) if name.lower() == b"content-length"),
            None,
        )
        if content_length is not None:
            try:
                if int(content_length) > self.max_bytes:
                    response = JSONResponse({"detail": "request body too large"}, status_code=413)
                    await response(scope, receive, send)
                    return
            except ValueError:
                pass

        received_bytes = 0

        async def limited_receive() -> dict[str, Any]:
            nonlocal received_bytes
            message = await receive()
            if message["type"] == "http.request":
                received_bytes += len(message.get("body", b""))
                if received_bytes > self.max_bytes:
                    raise RequestBodyTooLarge
            return message

        try:
            await self.app(scope, limited_receive, send)
        except RequestBodyTooLarge:
            response = JSONResponse({"detail": "request body too large"}, status_code=413)
            await response(scope, receive, send)


app.add_middleware(RequestBodyLimitMiddleware, max_bytes=MAX_REQUEST_BODY_BYTES)


def _read_json(path: Path) -> dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def load_role() -> dict[str, Any]:
    """Load role data from the active Grid installation or project config."""
    configured_path = os.environ.get("PERSONAL_GRID_ROLE_FILE")
    candidates = []
    if configured_path:
        candidates.append(Path(configured_path))

    grid_root = os.environ.get("PERSONAL_GRID_ROOT")
    if grid_root:
        candidates.append(Path(grid_root) / ".grid" / "device.json")

    candidates.extend(
        [
            PROJECT_ROOT / "config" / "grid.json",
            PROJECT_ROOT / "config" / "grid.example.json",
        ]
    )

    for path in candidates:
        document = _read_json(path)
        if not document:
            continue
        device = document.get("device", document)
        if not isinstance(device, dict):
            continue
        return {
            "device_name": device.get("deviceName", device.get("name")) or "unknown",
            "is_main": bool(device.get("isMain", device.get("is_main", False))),
        }

    return {"device_name": "unknown", "is_main": False}


class AskRequest(BaseModel):
    message: str = Field(min_length=1, max_length=8192)


class AskResponse(BaseModel):
    response: str
    status: str
    device: str


@app.get("/health")
def health() -> dict[str, Any]:
    role = load_role()
    return {
        "status": "ok",
        "device": role["device_name"],
        "is_main": role["is_main"],
        "uptime_seconds": round(time.time() - START_TIME, 1),
    }


@app.post("/ask", response_model=AskResponse)
def ask(request: AskRequest) -> AskResponse:
    role = load_role()
    return AskResponse(
        response=generate_response(request.message),
        status="ok",
        device=role["device_name"],
    )


def generate_response(message: str) -> str:
    """Return the stable Phase 5 stub until a local model is selected."""
    return f"(stub) received: {message!r} — no local model wired in yet."


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        app,
        host=os.environ.get("PERSONAL_GRID_API_HOST", "127.0.0.1"),
        port=int(os.environ.get("PERSONAL_GRID_API_PORT", "8000")),
    )