#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/core/fake_ollama_server.py
"""A stand-in for the Ollama daemon, speaking its HTTP API on a real port.

The container proofs cannot download the pinned Ollama release, so this
program takes its place where the daemon would run. It answers the endpoints
the Linux driver calls (/api/version, /api/tags, /api/pull, /api/chat,
/api/delete) with Ollama's JSON and NDJSON shapes.

Run as `<prog> serve`, it binds the address of OLLAMA_HOST exactly as the
daemon does, so the address the driver passes is the one it listens on. Run
with --port, it plays a user's own system Ollama on the stock port.

A pull routes the registry the way Go's net/http does for the real daemon:
through HTTPS_PROXY unless NO_PROXY names the registry host. A proxied pull
first connects to the relay and fails as the daemon fails when the relay is
dead; a direct pull reaches the stand-in's registry and succeeds. Every
request and the route taken are appended to --log as JSON lines.

Usage: fake_ollama_server.py serve --log FILE [--version V] [--chat-delay-ms N]
       fake_ollama_server.py --port N --log FILE [--version V]
"""

import argparse
import json
import os
import socket
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

REGISTRY_HOST = "registry.ollama.ai"


def registry_route(environment):
    """The relay Go's ProxyFromEnvironment picks for the registry, or None."""
    proxy = environment.get("HTTPS_PROXY") or environment.get("https_proxy") or ""
    if not proxy:
        return None
    bypass = environment.get("NO_PROXY") or environment.get("no_proxy") or ""
    for entry in (item.strip().lower() for item in bypass.split(",")):
        if entry == "*" or entry and REGISTRY_HOST.endswith(entry.lstrip(".")):
            return None
    return proxy if "://" in proxy else "http://" + proxy


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", nargs="?")
    parser.add_argument("--port", type=int)
    parser.add_argument("--log", default=os.environ.get("ERGOPTI_FAKE_OLLAMA_LOG"))
    parser.add_argument(
        "--version", default=os.environ.get("ERGOPTI_FAKE_OLLAMA_VERSION", "0.40.6")
    )
    parser.add_argument(
        "--chat-delay-ms",
        type=int,
        default=int(os.environ.get("ERGOPTI_FAKE_OLLAMA_CHAT_DELAY_MS", "0")),
    )
    parser.add_argument("--models", default=os.environ.get("ERGOPTI_FAKE_OLLAMA_MODELS", ""))
    args = parser.parse_args()
    if not args.log:
        parser.error("--log (or ERGOPTI_FAKE_OLLAMA_LOG) is required")
    if args.command == "serve":
        host, _, port = os.environ.get("OLLAMA_HOST", "").rpartition(":")
        if not host or not port.isdigit():
            sys.stderr.write("Error: OLLAMA_HOST must name host:port\n")
            return 1
        address = (host, int(port))
    elif args.port:
        address = ("127.0.0.1", args.port)
    else:
        parser.error("either `serve` or --port is required")

    models = {name for name in args.models.split(",") if name}
    lock = threading.Lock()

    def record(entry):
        entry["at"] = time.time()
        with lock, open(args.log, "a", encoding="utf-8") as log:
            log.write(json.dumps(entry) + "\n")

    record(
        {
            "event": "start",
            "mode": args.command or "system",
            "address": f"{address[0]}:{address[1]}",
            "env": {
                name: os.environ.get(name)
                for name in ("OLLAMA_HOST", "HTTPS_PROXY", "NO_PROXY", "no_proxy", "https_proxy")
            },
        }
    )

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def reply(self, status, document):
            payload = json.dumps(document).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def stream(self, frames, delay_s=0.0):
            """NDJSON in chunked encoding, as Ollama streams progress and tokens."""
            self.send_response(200)
            self.send_header("Content-Type", "application/x-ndjson")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            try:
                for frame in frames:
                    if delay_s:
                        time.sleep(delay_s)
                    line = (json.dumps(frame) + "\n").encode()
                    self.wfile.write(f"{len(line):x}\r\n".encode() + line + b"\r\n")
                    self.wfile.flush()
                self.wfile.write(b"0\r\n\r\n")
            except (BrokenPipeError, ConnectionResetError):
                record({"event": "client_closed", "path": self.path})

        def body(self):
            length = int(self.headers.get("Content-Length", "0"))
            raw = self.rfile.read(length) if length else b""
            return json.loads(raw or b"{}")

        def do_GET(self):
            record({"event": "request", "method": "GET", "path": self.path})
            if self.path == "/api/version":
                self.reply(200, {"version": args.version})
            elif self.path == "/api/tags":
                with lock:
                    names = sorted(models)
                self.reply(
                    200,
                    {
                        "models": [
                            {"name": name, "model": name, "size": 1, "digest": "0" * 64}
                            for name in names
                        ]
                    },
                )
            elif self.path == "/":
                payload = b"Ollama is running"
                self.send_response(200)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
            else:
                self.reply(404, {"error": "404 page not found"})

        def do_DELETE(self):
            record({"event": "request", "method": "DELETE", "path": self.path})
            name = self.body().get("model") or ""
            with lock:
                present = name in models
                models.discard(name)
            if present:
                self.reply(200, {})
            else:
                self.reply(404, {"error": f"model '{name}' not found"})

        def do_POST(self):
            document = self.body()
            record({"event": "request", "method": "POST", "path": self.path})
            if self.path == "/api/pull":
                self.pull(document.get("model") or document.get("name") or "")
            elif self.path == "/api/chat":
                self.chat(document)
            else:
                self.reply(404, {"error": "404 page not found"})

        def pull(self, name):
            relay = registry_route(os.environ)
            if relay:
                parsed = urllib.parse.urlsplit(relay)
                try:
                    socket.create_connection(
                        (parsed.hostname, parsed.port or 80), timeout=3
                    ).close()
                    reached = True
                except OSError as error:
                    reached = False
                    reason = f"{error.strerror or error}"
                record({"event": "pull", "model": name, "route": "proxy", "relay_reached": reached})
                if not reached:
                    self.stream(
                        [
                            {"status": "pulling manifest"},
                            {
                                "error": f'pull model manifest: Get "https://{REGISTRY_HOST}/v2/library/'
                                f'{name}/manifests/latest": proxyconnect tcp: dial tcp '
                                f"{parsed.hostname}:{parsed.port}: connect: {reason}"
                            },
                        ]
                    )
                    return
            else:
                record({"event": "pull", "model": name, "route": "direct"})
            total = 4096
            frames = [{"status": "pulling manifest"}]
            frames += [
                {
                    "status": "pulling " + "a" * 12,
                    "digest": "sha256:" + "a" * 64,
                    "total": total,
                    "completed": done,
                }
                for done in (0, total // 2, total)
            ]
            frames += [
                {"status": "verifying sha256 digest"},
                {"status": "writing manifest"},
                {"status": "success"},
            ]
            with lock:
                models.add(name)
            self.stream(frames)

        def chat(self, document):
            name = document.get("model") or ""
            with lock:
                present = name in models
            if not present:
                self.reply(404, {"error": f"model '{name}' not found"})
                return
            words = ["bonjour", " à", " tous"]
            frames = [
                {"model": name, "message": {"role": "assistant", "content": word}, "done": False}
                for word in words
            ]
            frames.append(
                {
                    "model": name,
                    "message": {"role": "assistant", "content": ""},
                    "done": True,
                    "done_reason": "stop",
                }
            )
            # A slow model: every token waits, so a caller has time to cancel.
            self.stream(frames, args.chat_delay_ms / 1000.0)

    ThreadingHTTPServer.allow_reuse_address = True
    server = ThreadingHTTPServer(address, Handler)
    server.daemon_threads = True
    record({"event": "listening", "address": f"{address[0]}:{address[1]}"})
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
