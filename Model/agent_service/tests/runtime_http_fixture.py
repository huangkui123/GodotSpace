"""Subprocess-only HTTP readiness fixture for service lifecycle regression."""
from __future__ import annotations

from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import os
import sys


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        payload = json.dumps(dict(status="ready", model="fixture", runtime_id=os.environ["LOCAL_AGENT_RUNTIME_ID"])).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args: object) -> None:
        pass


if __name__ == "__main__":
    HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
