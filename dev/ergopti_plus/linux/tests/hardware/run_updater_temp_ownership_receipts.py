#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_updater_temp_ownership_receipts.py
#
# Real TLS/curl, native temporary allocation, SHA-256 and public download/cancel
# paths must preserve unrelated names adjacent to the reserved file. strace only
# observes allocation; the TLS server creates competitors before its response.
# No process, filesystem, digest or HTTP adapter is mocked. No install runs.

import hashlib
import http.server
import os
import pathlib
import re
import ssl
import subprocess
import tempfile
import threading


ARCHIVE = b"Synthetic download bytes; this fixture never installs them"
WORKER = r"""
local uv = require("luv")
local Manager = require("modules.updater.manager")
print("ready"); io.stdout:flush(); assert(io.read("*l") == "go")
local origin = assert(os.getenv("ERGOPTI_NATIVE_UPDATER_ORIGIN"))
local mode = assert(os.getenv("ERGOPTI_NATIVE_UPDATER_MODE"))
local count, path, failure = 0, nil, nil
assert(Manager.download_release({ tag = "v4.0.0", download_url = origin .. "/archive",
	checksum_url = origin .. "/checksum" }, function(received_path, err)
	count = count + 1; path, failure = received_path, err
end))
uv.run()
assert(count == 1 and not uv.loop_alive(), "native download did not settle exactly once")
if mode == "healthy" then
	assert(path and not failure, "ordinary verified archive was refused")
	local file = assert(io.open(path, "rb")); local bytes = assert(file:read("*a")); assert(file:close())
	assert(bytes == "Synthetic download bytes; this fixture never installs them")
else
	assert(path == nil and failure, "occupied or invalid archive was published")
end
assert(Manager.cancel_update(), "native cancellation failed")
assert(Manager.get_state() == "idle" and not uv.loop_alive())
"""


def main():
    assert os.getuid() != 0, "native updater ownership receipts require an ordinary user"
    interpreter = os.environ.get("ERGOPTI_HTTP_TEST_LUA", "luajit")
    checks, failures = 0, 0
    active = {}
    history = b"Synthetic unrelated adjacent bytes"
    with tempfile.TemporaryDirectory(prefix="ergopti-updater-temp-ownership-") as folder:
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

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_args):
                pass

            def do_GET(self):
                try:
                    case = active["case"]
                    mode = case["mode"]
                    if self.path == "/checksum":
                        trace = case["trace"].read_text()[case["position"] :]
                        names = re.findall(
                            r'openat\([^,\n]*, "(/tmp/lua_[^"]+)", O_RDWR\|O_CREAT\|O_EXCL',
                            trace,
                        )
                        assert names, "native temporary allocation was not observed"
                        base = pathlib.Path(names[0])
                        case["base"] = base
                        if mode != "healthy":
                            for suffix in (".tar.gz", ".tar.gz.part"):
                                candidate = pathlib.Path(str(base) + suffix)
                                target = case["root"] / ("foreign" + suffix)
                                alias = case["alias"]
                                if alias in ("symlink", "hardlink"):
                                    target.write_bytes(history)
                                if alias in ("symlink", "dangling"):
                                    candidate.symlink_to(target)
                                elif alias == "hardlink":
                                    os.link(target, candidate)
                                else:
                                    candidate.write_bytes(history)
                                case["foreign"].append((candidate, candidate.lstat(), target))
                        digest = hashlib.sha256(
                            b"Different bytes" if mode == "digest-mismatch" else ARCHIVE
                        ).hexdigest()
                        body = (digest + "  ergopti-plus-linux.tar.gz\n").encode()
                        status = 200
                        if mode == "checksum-http":
                            status, body = 503, b"Synthetic unavailable checksum"
                        elif mode == "invalid-checksum":
                            body = b"Synthetic malformed checksum"
                    else:
                        assert self.path == "/archive"
                        case["archive_requests"] += 1
                        status, body = (
                            (503, b"Synthetic unavailable archive")
                            if mode == "archive-http"
                            else (200, ARCHIVE)
                        )
                    self.send_response(status)
                    self.send_header("Content-Length", str(len(body)))
                    self.send_header("Connection", "close")
                    self.end_headers()
                    self.wfile.write(body)
                except Exception as error:
                    active["error"] = error
                    self.close_connection = True

        server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        cases = [
            (mode, alias)
            for mode in ("checksum-http", "publication-collision")
            for alias in ("regular", "hardlink", "symlink", "dangling")
        ]
        cases += [
            (mode, "regular")
            for mode in ("invalid-checksum", "digest-mismatch", "archive-http", "healthy")
        ]
        try:
            for mode, alias in cases:
                checks += 1
                case_root = root / f"{mode}-{alias}"
                case_root.mkdir()
                case = {
                    "root": case_root,
                    "trace": case_root / "trace",
                    "mode": mode,
                    "alias": alias,
                    "foreign": [],
                    "archive_requests": 0,
                }
                active.clear()
                active["case"] = case
                env = dict(os.environ)
                env.update(
                    {
                        "CURL_CA_BUNDLE": str(cert),
                        "XDG_CONFIG_HOME": str(case_root / "config"),
                        "ERGOPTI_NATIVE_UPDATER_ORIGIN": f"https://127.0.0.1:{server.server_port}",
                        "ERGOPTI_NATIVE_UPDATER_MODE": mode,
                        "LUA_PATH": "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;",
                    }
                )
                child = None
                try:
                    child = subprocess.Popen(
                        [
                            "strace",
                            "-e",
                            "trace=openat",
                            "-o",
                            str(case["trace"]),
                            interpreter,
                            "-e",
                            WORKER,
                        ],
                        env=env,
                        stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        text=True,
                    )
                    assert child.stdout.readline().strip() == "ready", "native worker did not start"
                    case["position"] = len(case["trace"].read_text())
                    stdout, stderr = child.communicate(input="go\n", timeout=15)
                    assert "error" not in active, str(active.get("error"))
                    assert "base" in case, "native checksum request was not received"
                    for candidate, identity, target in case["foreign"]:
                        assert candidate.exists() or candidate.is_symlink(), (
                            "unrelated adjacent path was deleted"
                        )
                        retained = candidate.lstat()
                        assert (retained.st_dev, retained.st_ino) == (
                            identity.st_dev,
                            identity.st_ino,
                        ), "unrelated adjacent inode was replaced"
                        if alias in ("symlink", "dangling"):
                            assert candidate.is_symlink() and candidate.readlink() == target
                        if alias in ("regular", "hardlink"):
                            assert candidate.read_bytes() == history
                        if alias in ("symlink", "hardlink"):
                            assert target.read_bytes() == history
                        if alias == "dangling":
                            assert not target.exists()
                    assert child.returncode == 0, (stdout + stderr)[-1200:]
                    assert not case["base"].exists(), "owned reserved file leaked"
                    expected = 0 if mode in ("checksum-http", "invalid-checksum") else 1
                    assert case["archive_requests"] == expected, "native archive dispatch diverged"
                    if mode == "healthy":
                        assert not pathlib.Path(str(case["base"]) + ".tar.gz").exists(), (
                            "cancel leaked verified archive"
                        )
                    print(f"PASS native {mode} preserves {alias} ownership", flush=True)
                except (AssertionError, subprocess.TimeoutExpired) as error:
                    failures += 1
                    print(f"FAIL native {mode} preserves {alias} ownership: {error}", flush=True)
                finally:
                    if child and child.poll() is None:
                        child.kill()
                        child.communicate()
                    for candidate, _, _ in case["foreign"]:
                        candidate.unlink(missing_ok=True)
                    if "base" in case:
                        case["base"].unlink(missing_ok=True)
                        pathlib.Path(str(case["base"]) + ".tar.gz").unlink(missing_ok=True)
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
            assert not thread.is_alive(), "owned TLS server did not stop"
    print(f"Native updater temporary ownership receipts: {checks} checks, {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
