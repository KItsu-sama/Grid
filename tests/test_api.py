import asyncio
import unittest

from pydantic import ValidationError

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
