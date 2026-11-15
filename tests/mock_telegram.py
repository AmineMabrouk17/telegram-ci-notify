#!/usr/bin/env python3
"""Minimal Telegram Bot API stand-in, used by scripts/test-local.sh.

    python3 tests/mock_telegram.py 8973

Tokens beginning with "ok" get 200 {"ok":true}; any other token gets
400 {"ok":false,...}, which is how Telegram answers a wrong token or a chat
the bot cannot reach. Nothing leaves the machine.
"""

import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("content-length", 0))
        body = self.rfile.read(length).decode("utf-8", "replace")
        chat_id = ""
        for part in body.split("&"):
            if part.startswith("chat_id="):
                chat_id = part.split("=", 1)[1]
        ok = self.path.split("/")[1].startswith("botok")
        if ok:
            payload = {"ok": True, "result": {"message_id": 1, "chat": {"id": chat_id}}}
        else:
            payload = {
                "ok": False,
                "error_code": 400,
                "description": "Bad Request: chat not found",
            }
        data = json.dumps(payload).encode()
        self.send_response(200 if ok else 400)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.send_response(200)
        self.send_header("content-length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *_args):
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
