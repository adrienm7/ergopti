#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_http_empty_headers.py
"""Owned wire fixture for native curl empty-header serialization and defaults."""

import http.server
import json
import os
import pathlib
import subprocess
import tempfile
import threading


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        self.respond()

    def do_POST(self):
        self.respond()

    def respond(self):
        method, mode = self.path.strip("/").split("/")
        assert method in ("get", "get_owned", "post", "postStream")
        assert self.command == ("POST" if method in ("post", "postStream") else "GET")
        assert self.rfile.read(int(self.headers.get("Content-Length", "0"))) == (
            b"literal-fixture-body" if self.command == "POST" else b""
        )
        wire = {name.lower(): self.headers.get_all(name) for name in self.headers}
        self.server.wire.append((method, mode, wire))
        expected = {
            "x-empty-fixture": None,
            "x-ordinary-fixture": None,
            "accept": ["*/*"],
            "content-type": ["application/x-www-form-urlencoded"]
            if self.command == "POST"
            else None,
            "authorization": None,
        }
        if mode == "ordinary":
            expected.update(
                {
                    "x-ordinary-fixture": ["literal-value"],
                    "accept": ["application/json"],
                    "content-type": ["application/json"],
                    "user-agent": ["Fixture/1"],
                }
            )
        elif mode == "empty-custom":
            expected.update({"x-empty-fixture": [""], "x-ordinary-fixture": ["literal-value"]})
        elif mode == "empty-defaults":
            expected.update(
                {name: [""] for name in ("x-empty-fixture", "accept", "content-type", "user-agent")}
            )
        elif mode == "empty-sensitive":
            expected.update({"x-empty-fixture": [""], "authorization": [""]})
        elif mode.startswith("ows-"):
            assert mode in ("ows-space", "ows-tab", "ows-mixed")
            expected.update(
                {name: [""] for name in ("x-empty-fixture", "accept", "content-type", "user-agent")}
            )
            expected.pop("x-ordinary-fixture")
        else:
            assert mode == "absent"
        valid = all(wire.get(name) == value for name, value in expected.items())
        if mode.startswith("ows-"):
            values = wire.get("x-ordinary-fixture", [])
            valid = valid and len(values) == 1 and values[0].strip(" \t") == "literal \t value"
        if "user-agent" not in expected:
            agents = wire.get("user-agent", [])
            valid = valid and len(agents) == 1 and agents[0].startswith("curl/")
        payload = json.dumps({"valid": valid, "wire": wire}, separators=(",", ":")).encode()
        self.send_response(302 if mode == "empty-sensitive" else 200)
        if mode == "empty-sensitive":
            self.send_header("Location", "/must-never-follow")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        print(f"wire {method} {mode} valid={valid} headers={wire!r}", flush=True)


def main():
    assert os.getuid() != 0
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.wire = []
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix="ergopti-http-empty-headers-") as folder:
            env = os.environ.copy()
            env.update(
                HTTP_EMPTY_HEADER_ORIGIN=f"http://127.0.0.1:{server.server_port}",
                NO_PROXY="127.0.0.1",
                no_proxy="127.0.0.1",
            )
            for name in ("CONFIG", "DATA", "CACHE", "STATE"):
                env[f"XDG_{name}_HOME"] = str(pathlib.Path(folder) / name.lower())
            run = subprocess.run(
                [
                    os.environ.get("ERGOPTI_HTTP_TEST_LUA", "luajit"),
                    str(pathlib.Path(__file__).with_name("http_empty_headers.lua")),
                ],
                env=env,
                timeout=20,
            )
            assert len(server.wire) == 32, (
                "all original 20 and new 12 OWS requests must reach the wire"
            )
            raise SystemExit(run.returncode)
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == "__main__":
    main()
