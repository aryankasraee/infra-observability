"""Minimal Alertmanager webhook receiver.

Prints one JSON line per alert to stdout. Docker keeps stdout as the
container log, Alloy ships it to Loki, Grafana shows it. No dependencies.
"""
import json
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
            return
        for alert in payload.get("alerts", []):
            print(json.dumps({
                "received_at": datetime.now(timezone.utc).isoformat(),
                "status": alert.get("status"),
                "alertname": alert.get("labels", {}).get("alertname"),
                "severity": alert.get("labels", {}).get("severity"),
                "labels": alert.get("labels", {}),
                "summary": alert.get("annotations", {}).get("summary"),
                "description": alert.get("annotations", {}).get("description"),
                "startsAt": alert.get("startsAt"),
                "endsAt": alert.get("endsAt"),
            }, ensure_ascii=False), flush=True)
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok")

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"alert-logger up")

    def log_message(self, *args):
        pass  # keep stdout for alerts only


if __name__ == "__main__":
    print("alert-logger listening on :8080", file=sys.stderr, flush=True)
    HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
