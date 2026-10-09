#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_http_curlrc_receipts.py
#
# Actual production curl must honor the application request policy even when
# an owned CURL_HOME/.curlrc enables redirects, injected headers, insecure TLS
# or output redirection. Existing native receipts exercise the actual effects.
# A real environment-proxy control verifies that bypassing personal curl config
# preserves native proxy transport. No adapter, curl or socket API is mocked.

import http.server
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading


PROXY_REQUEST = r"""
local uv = require("luv")
local HTTP = require("adapters.http_client")
local result, callbacks = nil, 0
assert(HTTP.get("http://ergopti-native-proxy.invalid/native", {},
	{ owner = "native-curlrc-proxy", timeout_ms = 2000 },
	function(value) result = value; callbacks = callbacks + 1 end))
uv.run()
assert(result and result.ok and result.status == 200 and result.body == "abc" and callbacks == 1)
assert(not HTTP.isActive("native-curlrc-proxy") and not uv.loop_alive())
"""


def main():
    assert os.getuid() != 0, "native curlrc receipts require an ordinary user"
    interpreter = os.environ.get("ERGOPTI_HTTP_TEST_LUA", "luajit")
    checks, failures = 0, 0
    with tempfile.TemporaryDirectory(prefix="ergopti-http-curlrc-") as folder:
        root = pathlib.Path(folder)
        config = root / ".curlrc"
        destination = root / "retained-output"
        retained = b"Synthetic retained output bytes"
        env = dict(os.environ)
        env["CURL_HOME"] = str(root)
        env["LUA_PATH"] = "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;"

        def check(name, test):
            nonlocal checks, failures
            checks += 1
            try:
                test()
                print(f"PASS {name}", flush=True)
            except (AssertionError, subprocess.TimeoutExpired) as failure:
                failures += 1
                print(f"FAIL {name}: {failure}", file=sys.stderr, flush=True)

        def receipt(contents, command, expected):
            config.write_text(contents, encoding="utf-8")
            config.chmod(0o600)
            destination.write_bytes(retained)
            child = subprocess.run(command, env=env, capture_output=True, text=True, timeout=45)
            assert destination.read_bytes() == retained, (
                "personal curl config overwrote retained native output"
            )
            assert config.read_text(encoding="utf-8") == contents, (
                "native client altered personal config"
            )
            assert child.returncode == 0, (child.stdout + child.stderr)[-1600:]
            assert expected in child.stdout, "native child did not execute its complete receipt set"

        check(
            "personal location cannot override credential or no-follow policy (native40)",
            lambda: receipt(
                "location\n",
                [interpreter, "tests/hardware/run_http_redirect_receipts.lua"],
                "Native HTTP redirect receipts: 40 checks, 0 failures",
            ),
        )
        check(
            "personal header cannot inject application wire headers (native36)",
            lambda: receipt(
                'header = "X-Injected: synthetic"\n',
                [interpreter, "tests/hardware/run_http_header_receipts.lua"],
                "Native HTTP header boundary receipts: 36 checks, 0 failures",
            ),
        )
        check(
            "personal output cannot overwrite files or consume response bodies (native24)",
            lambda: receipt(
                "output = " + json.dumps(str(destination)) + "\n",
                [interpreter, "tests/hardware/run_http_literal_body_receipts.lua"],
                "Native literal HTTP body receipts: 24 checks, 0 failures",
            ),
        )
        check(
            "personal insecure cannot bypass certificate validation (native21)",
            lambda: receipt(
                "insecure\n",
                [sys.executable, "tests/hardware/run_http_tls_redirect_receipts.py"],
                "Native HTTP TLS redirect receipts: 21 checks, 0 failures",
            ),
        )

        def environment_proxy():
            config.write_text("", encoding="utf-8")
            records = []

            class Proxy(http.server.BaseHTTPRequestHandler):
                def log_message(self, *_args):
                    pass

                def do_GET(self):
                    records.append((self.path, self.headers.get("Host")))
                    self.send_response(200)
                    self.send_header("Content-Length", "3")
                    self.end_headers()
                    self.wfile.write(b"abc")

            server = http.server.HTTPServer(("127.0.0.1", 0), Proxy)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            proxy_env = dict(env)
            proxy_env["http_proxy"] = f"http://127.0.0.1:{server.server_port}"
            proxy_env["NO_PROXY"] = ""
            proxy_env["no_proxy"] = ""
            try:
                child = subprocess.run(
                    [interpreter, "-e", PROXY_REQUEST],
                    env=proxy_env,
                    capture_output=True,
                    text=True,
                    timeout=8,
                )
                assert child.returncode == 0, (child.stdout + child.stderr)[-1600:]
                assert records == [
                    ("http://ergopti-native-proxy.invalid/native", "ergopti-native-proxy.invalid")
                ]
            finally:
                server.shutdown()
                server.server_close()
                thread.join(timeout=2)
                assert not thread.is_alive(), "native environment proxy did not stop"

        check("native environment proxy survives personal-config isolation", environment_proxy)
    print(f"Native HTTP curlrc isolation receipts: {checks} checks, {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
