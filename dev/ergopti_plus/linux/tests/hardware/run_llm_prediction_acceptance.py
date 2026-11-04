#!/usr/bin/env python3
# tests/hardware/run_llm_prediction_acceptance.py
"""Verify native NDJSON acceptance against an independently checked HTTP server."""

import http.server
import json
import os
import pathlib
import subprocess
import tempfile
import threading
import time


def main():
    requests, server_errors = [], []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            try:
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                assert self.path == "/api/chat"
                assert body["model"] == "native-model" and body["stream"] is True
                assert "Bonjour à tous" in body["messages"][-1]["content"]
                requests.append(body)
                first = (
                    json.dumps(
                        {"message": {"content": " que tout le monde aille bien"}, "done": False}
                    ).encode()
                    + b"\n"
                )
                last = (
                    json.dumps({"message": {"content": " demain"}, "done": True}).encode() + b"\n"
                )
                self.send_response(200)
                self.send_header("Content-Length", str(len(first) + len(last)))
                self.end_headers()
                self.wfile.write(first)
                self.wfile.flush()
                # Leave the real curl stream in flight when the partial is accepted.
                time.sleep(0.4)
                try:
                    self.wfile.write(last)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError):
                    pass
            except BaseException as error:
                server_errors.append(error)
                raise

        def log_message(self, *args):
            pass

    proof = pathlib.Path(__file__).resolve().parent
    driver = proof.parent.parent
    with tempfile.TemporaryDirectory(prefix="ergopti-ai-accept-") as folder:
        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        env = os.environ.copy()
        env["ERGOPTI_ACCEPT_ORIGIN"] = "http://127.0.0.1:" + str(server.server_port)
        for name in ("CONFIG", "DATA", "CACHE", "STATE"):
            env["XDG_" + name + "_HOME"] = folder + "/" + name.lower()
        env["NO_PROXY"] = env["no_proxy"] = "127.0.0.1"
        env["LUA_PATH"] = ";".join(
            [
                str(driver / "?.lua"),
                str(driver / "?" / "init.lua"),
                str(driver.parent / "_shared" / "lua" / "?.lua"),
                str(driver.parent / "_shared" / "lua" / "?" / "init.lua"),
                env.get("LUA_PATH", ";"),
            ]
        )
        try:
            result = subprocess.run(
                [
                    env.get("ERGOPTI_HTTP_TEST_LUA", "luajit"),
                    str(proof / "llm_prediction_acceptance.lua"),
                ],
                cwd=driver,
                env=env,
                capture_output=True,
                text=True,
                timeout=10,
            )
            print(result.stdout, end="")
            print(result.stderr, end="")
        finally:
            server.shutdown()
            server.server_close()
            thread.join(2)
        assert not thread.is_alive() and not server_errors, server_errors
        assert len(requests) == 1, "acceptance must not start another prediction"
        raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
