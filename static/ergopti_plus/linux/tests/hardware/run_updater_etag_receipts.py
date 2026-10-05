#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_updater_etag_receipts.py
#
# Production release-page fetching uses real curl/libuv, certificate-verifying
# TLS, JSON parsing and ETag files. Origin/home providers route requests into
# this owned fixture; those providers are simulated, not the fetch/cache logic,
# transport or filesystem. No release, install, TOML write or physical input runs.

import http.server
import json
import os
import pathlib
import ssl
import subprocess
import tempfile
import threading
import urllib.parse


WORKER = r"""
local uv = require("luv")
local root = assert(os.getenv("ERGOPTI_NATIVE_UPDATER_ROOT"))
local mode = assert(os.getenv("ERGOPTI_NATIVE_UPDATER_MODE"))
local Paths = require("infra.config_paths")
local owned_paths = {}
for key, value in pairs(Paths) do owned_paths[key] = value end
owned_paths.home = function() return root end
package.loaded["infra.config_paths"] = owned_paths
local Manager = require("modules.updater.manager")
local original_url = Manager.release_api_url()
local count = assert(original_url:match("per_page=(%d+)"))
Manager.release_api_url = function() return assert(os.getenv("ERGOPTI_NATIVE_UPDATER_URL")) .. "?per_page=" .. count end
local function fetch()
	local result, callbacks = nil, 0
	assert(Manager._fetch_releases("main", function(body, status, err, reason)
		result = { body = body, status = status, error = err, reason = reason }; callbacks = callbacks + 1
	end))
	uv.run()
	assert(result and callbacks == 1 and not uv.loop_alive(), "actual fetch did not settle exactly once")
	return result
end
local first = fetch()
assert(first.body and first.body:find("v1.0.0", 1, true) and first.status == 200)
local second = fetch()
if mode == "not-modified" then
	assert(second.status == 304 and second.body == first.body)
elseif mode == "updated" then
	assert(second.status == 200 and second.body and second.body:find("v2.0.0", 1, true))
else
	assert(second.body == nil and second.error, "failed transport/JSON was accepted")
	local _, _, options = Manager._build_fetch_request("main", 1)
	local file = assert(io.open(options.etag_save, "rb"))
	local etag = assert(file:read("*a")); assert(file:close())
	if mode == "http-error" or mode == "http-error-new-validator" then
		assert(etag == assert(os.getenv("ERGOPTI_NATIVE_UPDATER_FAILED_ETAG")),
			"HTTP-error validator differs from the independent native curl receipt")
	else assert(etag:find("E2", 1, true), "failed native response did not actually change the file validator") end
	local third = fetch()
	if mode == "truncated" then
		assert(third.status == 200 and third.body and third.body:find("v2.0.0", 1, true),
			"new native validator falsely acknowledges the cached older page")
	else
		assert(third.body == nil and third.error, "failed new representation acknowledged an older cached page")
		local fourth = fetch()
		assert(fourth.status == 200 and fourth.body and fourth.body:find("v3.0.0", 1, true))
	end
end
"""


def main():
    assert os.getuid() != 0, "native updater receipts require an ordinary user"
    os.umask(0o077)
    interpreter = os.environ.get("ERGOPTI_HTTP_TEST_LUA", "luajit")
    checks, failures = 0, 0
    records = {}
    with tempfile.TemporaryDirectory(prefix="ergopti-updater-etag-") as folder:
        root = pathlib.Path(folder)
        cert, key = root / "cert.pem", root / "key.pem"
        subprocess.run(
            [
                "openssl",
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-days",
                "1",
                "-subj",
                "/CN=127.0.0.1",
                "-addext",
                "subjectAltName=IP:127.0.0.1",
                "-keyout",
                str(key),
                "-out",
                str(cert),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        assert key.stat().st_mode & 0o777 == 0o600

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                route = urllib.parse.urlparse(self.path).path.strip("/")
                mode = route.removeprefix("oracle/")
                receipts = records.setdefault(route, [])
                receipts.append(self.headers.get("If-None-Match"))
                phase = len(receipts)
                tag = (
                    '"E1"'
                    if phase == 1 or mode == "not-modified"
                    else '"E3"'
                    if phase == 4
                    else '"E2"'
                )
                body = json.dumps(
                    [
                        {
                            "tag_name": "v1.0.0"
                            if phase == 1
                            else "v3.0.0"
                            if phase == 4
                            else "v2.0.0"
                        }
                    ],
                    separators=(",", ":"),
                ).encode()
                status = 200
                if (
                    phase > 1
                    and self.headers.get("If-None-Match") == tag
                    and mode not in ("http-error", "http-error-new-validator")
                ):
                    status, body = 304, b""
                elif phase in (2, 3) and mode == "invalid-json":
                    body = b"{synthetic malformed JSON"
                elif phase in (2, 3) and mode == "oversized-page":
                    body = json.dumps(
                        [{"tag_name": f"v2.0.{index}"} for index in range(21)],
                        separators=(",", ":"),
                    ).encode()
                elif phase in (2, 3) and mode in ("http-error", "http-error-new-validator"):
                    # The unchanged-validator control supplies its original tag
                    # explicitly: curl versions differ on saving ETags from 503.
                    if mode == "http-error":
                        tag = '"E1"'
                    status, body = 503, b"Synthetic unavailable response"
                self.send_response(status)
                self.send_header("ETag", tag)
                self.send_header(
                    "Content-Length",
                    str(len(body) + (10 if phase == 2 and mode == "truncated" else 0)),
                )
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)

        server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()

        def failed_validator_oracle(mode, case_root, env):
            # Curl versions disagree on saving a response ETag when
            # --fail-with-body reports 503. Measure the real binary directly,
            # independently of the updater/cache code, with the same TLS and
            # conditional-file options. Its two requests use a separate route.
            etag_path = case_root / "oracle-etag.txt"
            for phase, expected_status in ((1, 200), (2, 503)):
                arguments = [
                    "curl",
                    "--disable",
                    "--globoff",
                    "--silent",
                    "--show-error",
                    "--no-buffer",
                    "--fail-with-body",
                    "--max-time",
                    "10",
                    "--proto",
                    "=https",
                    "--request",
                    "GET",
                    "--location",
                    "--proto-redir",
                    "=https",
                    "--tlsv1.2",
                    "--etag-save",
                    str(etag_path),
                    "--write-out",
                    "\nERGOPTI_ORACLE_STATUS=%{http_code}\n",
                    "--config",
                    "-",
                ]
                if phase == 2:
                    arguments.extend(["--etag-compare", str(etag_path)])
                target = f"https://127.0.0.1:{server.server_port}/oracle/{mode}?per_page=20&page=1"
                oracle = subprocess.run(
                    arguments,
                    input=f'url = "{target}"\n',
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=10,
                )
                body, marker, status = oracle.stdout.rpartition("\nERGOPTI_ORACLE_STATUS=")
                assert marker and status == f"{expected_status}\n", oracle.stdout
                assert oracle.returncode == (0 if phase == 1 else 22), oracle.stderr
                if phase == 1:
                    assert json.loads(body) == [{"tag_name": "v1.0.0"}]
                    assert etag_path.read_bytes() == b'"E1"\n'
                else:
                    assert body == "Synthetic unavailable response"
            assert records["oracle/" + mode] == [None, '"E1"']
            actual = etag_path.read_bytes()
            assert actual in (b'"E1"\n', b'"E2"\n'), actual
            print(f"ORACLE native curl {mode} rejected503 validator={actual!r}", flush=True)
            return actual.decode("ascii")

        try:
            for mode in (
                "truncated",
                "invalid-json",
                "oversized-page",
                "http-error",
                "not-modified",
                "updated",
                "http-error-new-validator",
            ):
                checks += 1
                case_root = root / mode
                (case_root / ".cache").mkdir(parents=True)
                (case_root / "config").mkdir()
                env = dict(os.environ)
                env.update(
                    {
                        "CURL_CA_BUNDLE": str(cert),
                        "ERGOPTI_NATIVE_UPDATER_ROOT": str(case_root),
                        "ERGOPTI_NATIVE_UPDATER_MODE": mode,
                        "ERGOPTI_NATIVE_UPDATER_URL": f"https://127.0.0.1:{server.server_port}/{mode}",
                        "XDG_CONFIG_HOME": str(case_root / "config"),
                        "LUA_PATH": "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;",
                    }
                )
                try:
                    if mode in ("http-error", "http-error-new-validator"):
                        env["ERGOPTI_NATIVE_UPDATER_FAILED_ETAG"] = failed_validator_oracle(
                            mode, case_root, env
                        )
                    child = subprocess.run(
                        [interpreter, "-e", WORKER],
                        env=env,
                        capture_output=True,
                        text=True,
                        timeout=10,
                    )
                    assert child.returncode == 0, (child.stdout + child.stderr)[-1400:]
                    expected = [None, '"E1"']
                    if mode == "truncated":
                        expected.append(None)
                    elif mode not in ("not-modified", "updated"):
                        expected.extend([None, None])
                    assert records[mode] == expected, (
                        f"native conditional validators diverged: {records[mode]}"
                    )
                    print(f"PASS native updater validator association after {mode}", flush=True)
                except (AssertionError, subprocess.TimeoutExpired) as failure:
                    failures += 1
                    print(
                        f"FAIL native updater validator association after {mode}: {failure}",
                        flush=True,
                    )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
            assert not thread.is_alive(), "owned native TLS listener did not stop"
    print(f"Native updater ETag receipts: {checks} checks, {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
