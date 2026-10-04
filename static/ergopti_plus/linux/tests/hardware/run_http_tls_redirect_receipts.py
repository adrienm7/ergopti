#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_http_tls_redirect_receipts.py
#
# Native production curl requests use an actual certificate-verifying TLS
# session and independent loopback HTTP/HTTPS origins. Secure redirects must
# never send a request or its POST body to HTTP. Public HTTPS redirects,
# plaintext-to-TLS upgrades and certificate refusal are healthy controls.
# Only synthetic data is used; no curl, TLS, Lua or socket adapter is mocked.

import http.server
import os
import pathlib
import ssl
import subprocess
import tempfile
import threading


LUA_REQUEST = r"""
local uv = require("luv")
local HTTP = require("adapters.http_client")
assert(uv.getuid() ~= 0, "native TLS checks require an ordinary user")
local url = assert(os.getenv("ERGOPTI_NATIVE_TLS_URL"))
local method = assert(os.getenv("ERGOPTI_NATIVE_TLS_METHOD"))
local expected = assert(os.getenv("ERGOPTI_NATIVE_TLS_EXPECTED"))
local destination = assert(os.getenv("ERGOPTI_NATIVE_TLS_DOWNLOAD"))
local result, callbacks, chunks = nil, 0, ""
local options = {
	owner = "native-tls-redirect-receipt", timeout_ms = 2000,
	follow_redirects = os.getenv("ERGOPTI_NATIVE_TLS_FOLLOW") == "true",
	https_only = os.getenv("ERGOPTI_NATIVE_TLS_HTTPS_ONLY") == "true",
}
local follows = options.follow_redirects
local function complete(value) result = value; callbacks = callbacks + 1 end
local headers = { Accept = "application/json" }
local payload = "Synthetic native POST data"
local dispatched
if method == "get" then dispatched = HTTP.get(url, headers, options, complete)
elseif method == "post" then dispatched = HTTP.post(url, headers, payload, complete, options)
elseif method == "download" then dispatched = HTTP.download(url, headers, destination, options, complete)
else dispatched = HTTP.postStream(url, headers, payload, options,
	function(chunk) chunks = chunks .. chunk end, complete) end
assert(dispatched, "original native TLS request was refused")
uv.run()
assert(result and callbacks == 1 and not HTTP.isActive(options.owner), "native TLS owner did not settle once")
assert(not uv.loop_alive(), "native TLS request retained native handles")
assert(options.follow_redirects == follows, "adapter changed caller-owned options")
if expected == "blocked" then
	assert(result.ok == false and result.status == 307 and result.error == "HTTP 307",
		"native curl accepted a downgrade instead of retaining its original HTTPS refusal receipt")
elseif expected == "tls-refused" then
	assert(result.ok == false and result.status == 0 and type(result.error) == "string",
		"native certificate validation was bypassed")
else
	assert(result.ok and result.status == 200, "healthy native TLS response was refused")
	if method == "postStream" then assert(chunks == "abc")
	elseif method == "download" then
		local file = assert(io.open(destination, "rb"))
		assert(file:read("*a") == "abc" and file:close())
	else assert(result.body == "abc") end
end
"""


def main():
    """Exercise real TLS and production request methods with owned resources."""
    assert os.getuid() != 0, "native TLS checks require an ordinary user"
    os.umask(0o077)
    checks, failures = 0, 0
    with tempfile.TemporaryDirectory(prefix="ergopti-http-tls-redirect-") as root:
        directory = pathlib.Path(root)
        cert, key = directory / "cert.pem", directory / "key.pem"
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
        assert key.stat().st_mode & 0o777 == 0o600, "synthetic TLS key is not private"
        receipts = {"plain": [], "secure": [], "second-secure": []}
        urls = {}

        def handler(role):
            class Handler(http.server.BaseHTTPRequestHandler):
                def log_message(self, *_):
                    pass

                def respond(self):
                    length = int(self.headers.get("Content-Length", "0"))
                    body = self.rfile.read(length)
                    receipts[role].append((self.command, self.path, body))
                    if self.path == "/downgrade":
                        location = urls["plain"] + "/final"
                    elif self.path == "/same-secure":
                        location = urls["secure"] + "/final"
                    elif self.path == "/cross-secure":
                        location = urls["second-secure"] + "/final"
                    elif self.path == "/upgrade":
                        location = urls["secure"] + "/final"
                    else:
                        location = None
                    self.send_response(307 if location else 200)
                    if location:
                        self.send_header("Location", location)
                    self.send_header("Content-Length", "0" if location else "3")
                    self.send_header("Connection", "close")
                    self.end_headers()
                    if not location:
                        self.wfile.write(b"abc")

                do_GET = respond
                do_POST = respond

            return Handler

        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        servers, threads = [], []
        for role in receipts:
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler(role))
            server.daemon_threads = True
            if role != "plain":
                server.socket = context.wrap_socket(server.socket, server_side=True)
            urls[role] = (
                f"{'http' if role == 'plain' else 'https'}://127.0.0.1:{server.server_port}"
            )
            servers.append(server)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            threads.append(thread)

        def request(name, method, url, expected, follow=True, https_only=False):
            nonlocal checks, failures
            checks += 1
            before = {role: len(values) for role, values in receipts.items()}
            env = os.environ.copy()
            env.update(
                CURL_CA_BUNDLE=str(cert),
                NO_PROXY="127.0.0.1,localhost",
                no_proxy="127.0.0.1,localhost",
                LUA_PATH="./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;",
                ERGOPTI_NATIVE_TLS_URL=url,
                ERGOPTI_NATIVE_TLS_METHOD=method,
                ERGOPTI_NATIVE_TLS_EXPECTED=expected,
                ERGOPTI_NATIVE_TLS_DOWNLOAD=str(directory / "download"),
                ERGOPTI_NATIVE_TLS_FOLLOW=str(follow).lower(),
                ERGOPTI_NATIVE_TLS_HTTPS_ONLY=str(https_only).lower(),
            )
            try:
                result = subprocess.run(
                    [os.getenv("ERGOPTI_HTTP_TEST_LUA", "luajit"), "-e", LUA_REQUEST],
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=8,
                )
                assert result.returncode == 0, result.stderr.strip()
                if expected == "blocked":
                    assert len(receipts["plain"]) == before["plain"], (
                        "request or POST body reached the downgraded HTTP origin"
                    )
                    assert len(receipts["secure"]) == before["secure"] + 1, (
                        "original certificate-verifying HTTPS request was not observed"
                    )
                elif expected == "tls-refused":
                    assert all(len(receipts[role]) == before[role] for role in receipts), (
                        "HTTP data was sent after certificate refusal"
                    )
                elif url.startswith(urls["plain"]):
                    assert len(receipts["plain"]) == before["plain"] + 1
                    assert len(receipts["secure"]) == before["secure"] + 1
                else:
                    assert len(receipts["plain"]) == before["plain"], (
                        "healthy HTTPS control used plaintext"
                    )
                    if "/cross-secure" in url:
                        assert len(receipts["second-secure"]) == before["second-secure"] + 1
                    if "/same-secure" in url:
                        assert len(receipts["secure"]) == before["secure"] + 2
                print("PASS " + name)
            except (AssertionError, OSError, subprocess.SubprocessError) as error:
                failures += 1
                print("FAIL " + name + ": " + str(error), flush=True)

        try:
            for method in ("get", "post", "postStream", "download"):
                request(
                    method + " refuses actual HTTPS-to-HTTP downgrade",
                    method,
                    urls["secure"] + "/downgrade",
                    "blocked",
                )
                request(
                    method + " follows same-origin HTTPS redirect",
                    method,
                    urls["secure"] + "/same-secure",
                    "ok",
                )
                request(
                    method + " follows public cross-origin HTTPS redirect",
                    method,
                    urls["secure"] + "/cross-secure",
                    "ok",
                )
                request(
                    method + " retains direct certificate-verified response",
                    method,
                    urls["secure"] + "/direct",
                    "ok",
                )
            request(
                "uppercase HTTPS also refuses downgrade",
                "get",
                urls["secure"].replace("https:", "HTTPS:") + "/downgrade",
                "blocked",
            )
            request(
                "certificate hostname mismatch sends no HTTP data",
                "get",
                urls["secure"].replace("127.0.0.1", "localhost") + "/direct",
                "tls-refused",
            )
            request(
                "public HTTP-to-HTTPS upgrade remains usable",
                "get",
                urls["plain"] + "/upgrade",
                "ok",
            )
            request(
                "explicit no-follow retains the secure redirect receipt",
                "get",
                urls["secure"] + "/downgrade",
                "blocked",
                follow=False,
            )
            request(
                "existing https_only also rejects the insecure hop",
                "get",
                urls["secure"] + "/downgrade",
                "blocked",
                https_only=True,
            )
        finally:
            for server in servers:
                server.shutdown()
                server.server_close()
            for thread in threads:
                thread.join(timeout=2)
                assert not thread.is_alive(), "native TLS listener did not stop"
    print(f"Native HTTP TLS redirect receipts: {checks} checks, {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
