"""Control all four Pi 5 root hubs to remove power from the radar."""
from __future__ import annotations

import json
import re
import subprocess
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

HUBS = (5, 4, 3, 2)  # The verified off/on sequence on this Pi; order matters.
PORT_COUNTS = {5: 1, 4: 2, 3: 1, 2: 2}


class PowerSwitch:
    def __init__(self, hubs=HUBS, run=subprocess.run, sleep=time.sleep):
        self.hubs = hubs
        self.run = run
        self.sleep = sleep

    def command(self, hub, action=None):
        args = ["uhubctl", "-e", "-l", str(hub)]
        if action:
            args.extend(["-a", action])
        try:
            return self.run(args, check=True, capture_output=True, text=True, timeout=8).stdout
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as exc:
            raise OSError(f"USB hub {hub}: {exc}") from exc

    def status(self):
        values = []
        for hub in self.hubs:
            ports = re.findall(r"^  Port \d+: [0-9a-fA-F]+ (off|power)\b", self.command(hub), re.M)
            if len(ports) != PORT_COUNTS[hub]:
                raise OSError(f"Cannot read USB hub {hub} port status")
            values.extend(ports)
        return "on" if all(value == "power" for value in values) else "off" if all(value == "off" for value in values) else "partial"

    def set(self, action):
        if action not in {"on", "off"}:
            raise ValueError("Unknown USB power action")
        before = self.status()
        if action == "on" and before != "on":
            # Always wait after the last off command, even across HTTP requests.
            self.sleep(5)
        for hub in self.hubs:
            self.command(hub, action)
        after = self.status()
        if after != action:
            raise OSError(f"USB power did not reach {action} state (state: {after})")
        return {"state": after, "board_power_cycled": action == "on" and before == "off"}


class Handler(BaseHTTPRequestHandler):
    switch = PowerSwitch()

    def respond(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path != "/status":
            return self.respond(404, {"detail": "Not found"})
        try:
            self.respond(200, {"state": self.switch.status()})
        except OSError as exc:
            self.respond(500, {"detail": str(exc)})

    def do_POST(self):
        if self.path not in {"/power/on", "/power/off"}:
            return self.respond(404, {"detail": "Not found"})
        try:
            self.respond(200, self.switch.set(self.path.rsplit("/", 1)[1]))
        except OSError as exc:
            self.respond(500, {"detail": str(exc)})


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8765), Handler).serve_forever()
