#!/usr/bin/env python3
"""Minimal Telegram Bot API stand-in, used by scripts/test-local.sh.

    python3 tests/mock_telegram.py /tmp/portfile

Binds an ephemeral port and writes it to the given file, so parallel or
interrupted runs never collide. Tokens beginning with "ok" get 200
{"ok":true}; a token beginning with "parse" gets a 400 "can't parse entities"
whenever the request carries a parse_mode, which is how Telegram answers
malformed HTML. Any other token gets a 400 "chat not found". Requests are
appended to $MOCK_LOG when it is set.
"""

import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("content-length", 0))
        body = self.rfile.read(length).decode("utf-8", "replace")

        log = os.environ.get("MOCK_LOG")
        if log:
            with open(log, "a", encoding="utf-8") as handle:
                handle.write(body + "\n")

        token = self.path.split("/")[1].removeprefix("bot")
        chat_id = ""
        for part in body.split("&"):
            if part.startswith("chat_id="):
                chat_id = part.split("=", 1)[1]

        if token.startswith("parse"):
            if "parse_mode=" in body:
                code, payload = 400, {
                    "ok": False,
                    "error_code": 400,
                    "description": "Bad Request: can't parse entities",
                }
            else:
                code, payload = 200, {
                    "ok": True,
                    "result": {"message_id": 1, "chat": {"id": chat_id}},
                }
        elif token.startswith("ok"):
            code, payload = 200, {
                "ok": True,
                "result": {"message_id": 1, "chat": {"id": chat_id}},
            }
        else:
            code, payload = 400, {
                "ok": False,
                "error_code": 400,
                "description": "Bad Request: chat not found",
            }

        data = json.dumps(payload).encode()
        self.send_response(code)
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
    server = HTTPServer(("127.0.0.1", 0), Handler)
    if len(sys.argv) > 1:
        with open(sys.argv[1], "w", encoding="utf-8") as handle:
            handle.write(str(server.server_address[1]))
    server.serve_forever()
