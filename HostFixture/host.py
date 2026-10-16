#!/usr/bin/env python3
"""Synthetic, foreground Harklight loopback host. No enrollment or relay."""
import argparse
import base64
import hmac
import json
import os
import secrets
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ASSETS = Path(__file__).parent / "assets"
MAX_BODY = 8192


def random_secret(bits):
    return base64.urlsafe_b64encode(secrets.token_bytes(bits // 8)).decode().rstrip("=")


class State:
    def __init__(self, profile="synthetic-A", clock=time.monotonic, trace_file=None):
        self.lock = threading.RLock()
        self.clock = clock
        self.profile = profile
        self.generation = random_secret(128)
        self.pair_secret = None
        self.pair_deadline = 0
        self.pair_failures = 0
        self.sessions = {}
        self.intent = None
        self.revision = 0
        self.events = []
        self.trace_file = trace_file
        self.stream_gate = None

    def issue_pair_secret(self):
        with self.lock:
            self.pair_secret = random_secret(128)
            self.pair_deadline = self.clock() + 300
            self.pair_failures = 0
            return self.pair_secret

    def pair(self, candidate, profile):
        with self.lock:
            valid = (profile == self.profile and self.pair_secret is not None
                     and self.clock() < self.pair_deadline and self.pair_failures < 5
                     and isinstance(candidate, str)
                     and hmac.compare_digest(candidate, self.pair_secret))
            if not valid:
                self.pair_failures += 1
                return None
            self.pair_secret = None
            token = random_secret(256)
            self.sessions[token] = (profile, self.generation, self.clock() + 12 * 3600)
            return token

    def authorize(self, token, profile, generation):
        with self.lock:
            entry = self.sessions.get(token)
            return bool(entry and entry[0] == profile == self.profile
                        and entry[1] == generation == self.generation
                        and self.clock() < entry[2])

    def switch_profile(self, profile):
        with self.lock:
            if profile != self.profile:
                # This in-memory fixture has no cross-profile intent store.
                self.intent = None
                self.revision = 0
            self.profile = profile
            self.generation = random_secret(128)
            self.sessions.clear()
            self.pair_secret = None

    def revoke_access(self):
        self.switch_profile(self.profile)

    def submit_authorized(self, token, profile, generation, operation, text):
        with self.lock:
            if not self.authorize(token, profile, generation):
                return "unauthorized", None
            if self.intent and (self.intent["operation"] != operation or self.intent["text"] != text):
                return "conflict", None
            if not self.intent:
                self.intent = {"operation": operation, "item": "fixture-one",
                               "text": text, "state": "fixture-committed"}
                self.revision += 1
            return "ok", self.intent.copy()


class Host(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, port=0, state=None):
        self.state = state or State()
        super().__init__(("127.0.0.1", port), Handler)
        self.origin = f"http://127.0.0.1:{self.server_port}"


class Handler(BaseHTTPRequestHandler):
    server_version = "AttentionSyntheticHost"
    sys_version = ""

    def log_message(self, *_):
        pass

    def trace(self, route, checks, result):
        # Field names and booleans only. Never record credentials or payloads.
        state = self.server.state
        event = {"route": route, "checks": checks, "result": result}
        with state.lock:
            state.events.append(event)
            if state.trace_file:
                with state.trace_file.open("a") as output:
                    output.write(json.dumps(event, separators=(",", ":")) + "\n")

    def reply(self, code, value):
        body = json.dumps(value, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        names = {"/": ("index.html", "text/html; charset=utf-8"),
                 "/fixture-run-2": ("index.html", "text/html; charset=utf-8"),
                 "/app.js": ("app.js", "text/javascript; charset=utf-8")}
        if self.path not in names or self.headers.get_all("Host") != [self.server.origin.removeprefix("http://")]:
            self.reply(404, {"error": "not_found"})
            return
        name, mime = names[self.path]
        body = (ASSETS / name).read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Security-Policy", "default-src 'none'; script-src 'self'; connect-src 'self'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        route = self.path.split("?", 1)[0]
        checks = {
            "host": self.headers.get_all("Host") == [self.server.origin.removeprefix("http://")],
            "origin": self.headers.get_all("Origin") == [self.server.origin],
            "json": self.headers.get("Content-Type", "").split(";", 1)[0].strip() == "application/json",
            "path": self.path == route,
        }
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            length = -1
        checks["body_size"] = 0 <= length <= MAX_BODY
        if not all(checks.values()):
            self.trace(route, checks, "rejected")
            self.reply(403, {"error": "boundary_rejected"})
            return
        try:
            data = json.loads(self.rfile.read(length))
            if not isinstance(data, dict):
                raise ValueError()
        except (ValueError, UnicodeDecodeError):
            self.trace(route, checks, "invalid_json")
            self.reply(400, {"error": "invalid_json"})
            return
        state = self.server.state
        profile = data.get("profile")
        if route == "/api/pair":
            token = state.pair(data.get("secret"), profile)
            checks["pair"] = bool(token)
            self.trace(route, checks, "ok" if token else "rejected")
            self.reply(200 if token else 403, {"token": token, "generation": state.generation, "profile": profile} if token else {"error": "pair_rejected"})
            return
        auth_headers = self.headers.get_all("Authorization", [])
        auth = auth_headers[0] if len(auth_headers) == 1 else ""
        token = auth[7:] if auth.startswith("Bearer ") else ""
        checks["session"] = state.authorize(token, profile, data.get("generation"))
        if not checks["session"]:
            self.trace(route, checks, "rejected")
            self.reply(403, {"error": "session_rejected"})
            return
        if route in ("/api/inspect", "/api/observe"):
            with state.lock:
                if not state.authorize(token, profile, data.get("generation")):
                    self.trace(route, {"session": False}, "rejected")
                    self.reply(403, {"error": "session_rejected"})
                    return
                result = {"profile": state.profile, "generation": state.generation,
                          "revision": state.revision,
                          "item": {"id": "fixture-one", "text": "<img src=x onerror=alert(1)> inert fixture"},
                          "intent": state.intent}
                self.trace(route, checks, "ok")
                self.reply(200, result)
        elif route == "/api/submit":
            operation, text = data.get("operation"), data.get("text")
            checks["selector"] = data.get("item") == "fixture-one" and isinstance(operation, str) and len(operation) <= 80 and isinstance(text, str) and len(text) <= 1000
            if not checks["selector"]:
                self.trace(route, checks, "rejected")
                self.reply(400, {"error": "selector_rejected"})
                return
            outcome, result = state.submit_authorized(token, profile, data.get("generation"), operation, text)
            self.trace(route, checks, outcome)
            code = {"ok": 200, "conflict": 409, "unauthorized": 403}[outcome]
            self.reply(code, {"intent": result} if outcome == "ok" else {"error": outcome})
        elif route == "/api/lookup":
            with state.lock:
                if not state.authorize(token, profile, data.get("generation")):
                    self.trace(route, {"session": False}, "rejected")
                    self.reply(403, {"error": "session_rejected"})
                    return
                result = state.intent.copy() if state.intent and data.get("operation") == state.intent["operation"] else None
                self.trace(route, checks, "ok")
                self.reply(200, {"intent": result})
        elif route == "/api/logout":
            with state.lock:
                if not state.authorize(token, profile, data.get("generation")):
                    self.trace(route, {"session": False}, "rejected")
                    self.reply(403, {"error": "session_rejected"})
                    return
                state.sessions.pop(token, None)
                self.trace(route, checks, "ok")
                self.reply(200, {"ok": True})
        elif route == "/api/stream":
            self.trace(route, checks, "stream_started")
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            try:
                for index in range(4):
                    if state.stream_gate:
                        state.stream_gate(index)
                    if not state.authorize(token, profile, data.get("generation")):
                        self.trace(route, {"session": False}, "stream_fenced")
                        break
                    payload = (json.dumps({"snapshot": index, "profile": profile, "generation": state.generation}) + "\n").encode()
                    self.wfile.write(f"{len(payload):X}\r\n".encode() + payload + b"\r\n")
                    self.wfile.flush()
                    time.sleep(0.35)
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                self.trace(route, {"session": True}, "stream_disconnected")
        else:
            self.trace(route, checks, "not_found")
            self.reply(404, {"error": "not_found"})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--pair-secret-file", type=Path)
    parser.add_argument("--trace-file", type=Path)
    args = parser.parse_args()
    with Host(args.port, State(trace_file=args.trace_file)) as host:
        secret = host.state.issue_pair_secret()
        print(f"Synthetic Harklight host: {host.origin}", flush=True)
        if args.pair_secret_file:
            fd = os.open(args.pair_secret_file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w") as output:
                output.write(secret + "\n")
            print("Pairing secret issued to task-owned local file", flush=True)
        elif sys.stdout.isatty():
            print(f"Pairing secret for trusted local terminal only: {secret}", flush=True)
        else:
            raise SystemExit("Refusing to print pairing secret to noninteractive output")
        host.serve_forever()


if __name__ == "__main__":
    main()
