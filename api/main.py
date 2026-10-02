"""Phone-facing Personal Grid API."""

import json
import os
import time
from pathlib import Path
from typing import Any

from fastapi import FastAPI
from pydantic import BaseModel


PROJECT_ROOT = Path(__file__).resolve().parents[1]
START_TIME = time.time()
app = FastAPI(title="Personal Grid API")


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
    message: str


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