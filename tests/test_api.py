import asyncio
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from pydantic import ValidationError
from fastapi.testclient import TestClient

from api import main as personal_grid_api
from api.main import AskRequest, RequestBodyLimitMiddleware


class AskRequestTests(unittest.TestCase):
    def test_accepts_messages_up_to_limit(self):
        request = AskRequest(message="x" * 8192)
        self.assertEqual(len(request.message), 8192)

    def test_rejects_empty_and_oversized_messages(self):
        with self.assertRaises(ValidationError):
            AskRequest(message="")
        with self.assertRaises(ValidationError):
            AskRequest(message="x" * 8193)

    def test_rejects_oversized_declared_and_streamed_bodies(self):
        for headers in ([(b"content-length", b"5")], []):
            status, body = asyncio.run(self._call_middleware(b"12345", headers))
            self.assertEqual(status, 413)
            self.assertIn(b"request body too large", body)

    def test_agent_admin_proxy_requires_token_and_forwards_to_loopback(self):
        class FakeResponse:
            content = b'{"devices": []}'
            headers = {"content-type": "application/json"}
            status_code = 200

        class FakeClient:
            forwarded = None

            def __init__(self, **kwargs):
                pass

            async def __aenter__(self):
                return self

            async def __aexit__(self, *args):
                return None

            async def request(self, method, url, **kwargs):
                type(self).forwarded = (method, url, kwargs)
                return FakeResponse()

        with tempfile.TemporaryDirectory() as temp_dir:
            token_path = Path(temp_dir) / ".grid" / "agent" / "admin.token"
            token_path.parent.mkdir(parents=True)
            token_path.write_text("test-token", encoding="utf-8")
            with patch.dict(os.environ, {"PERSONAL_GRID_ROOT": temp_dir}), \
                    patch("api.main.httpx.AsyncClient", FakeClient):
                client = TestClient(personal_grid_api.app)
                self.assertEqual(client.get("/agent-admin/devices").status_code, 401)
                response = client.get("/agent-admin/devices?limit=2",
                                      headers={"Authorization": "Bearer test-token"})

        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"devices": []})
        method, url, options = FakeClient.forwarded
        self.assertEqual((method, url), ("GET", "http://127.0.0.1:8765/devices"))
        self.assertEqual(options["headers"]["Authorization"], "Bearer test-token")

    @staticmethod
    async def _call_middleware(body, headers):
        sent = []
        request = {"type": "http.request", "body": body, "more_body": False}

        async def receive():
            return request

        async def send(message):
            sent.append(message)

        async def app(scope, app_receive, app_send):
            await app_receive()
            await app_send({"type": "http.response.start", "status": 200, "headers": []})
            await app_send({"type": "http.response.body", "body": b"ok"})

        scope = {
            "type": "http",
            "method": "POST",
            "path": "/ask",
            "headers": headers,
        }
        middleware = RequestBodyLimitMiddleware(app, max_bytes=4)
        await middleware(scope, receive, send)
        response_start = next(message for message in sent if message["type"] == "http.response.start")
        response_body = next(message for message in sent if message["type"] == "http.response.body")
        return response_start["status"], response_body["body"]


if __name__ == "__main__":
    unittest.main()
