#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_updater_temp_ownership_receipts.py
#
# Real TLS/curl, native temporary allocation, SHA-256 and public download/cancel
# paths must preserve the fixture-owned foreign names in the retained namespace.
# strace observes genuine allocation/publication; only this fixture removes its
# competitors after identity checks and before exact original cleanup retry.
# No process, filesystem, digest or HTTP adapter is mocked. No install runs.

import hashlib
import http.server
import os
import pathlib
import select
import shutil
import socketserver
import stat
import re
import ssl
import subprocess
import tempfile
import threading
import time


ARCHIVE = b"Synthetic download bytes; this fixture never installs them"
WORKER = r"""
local uv = require("luv")
local Manager = require("modules.updater.manager")
local ScriptActions = require("modules.shortcuts.script_actions")
local controller = ScriptActions.new({
 reset = function() assert(Manager.cancel_update()) end,
 reload = function() Manager.stop_background_checks(); assert(Manager.cancel_update()) end,
 quit = function() Manager.stop_background_checks(); assert(Manager.cancel_update()) end,
})
Manager.init({ is_paused = controller.is_paused })
assert(Manager.stop_background_checks() == true, "Actual updater background cancellation refused")
uv.run()
assert(not uv.loop_alive(), "Actual updater preparation retained native timer debt")
-- Prepare actual runtime libraries before the first native transfer.
-- These production factories acquire no archive/reader/EVP context or timer.
-- Keep them reachable through the original operation and native retirement.
local Output = require("infra.archive_output")
local prepared_artifact = assert(Output.native_artifact("ergopti-plus-linux.tar.gz"),
 "Actual native archive runtime preparation unavailable")
local prepared_output = Output.native()
local prepared_digest = require("infra.fd_sha256").native()
print("ready"); io.stdout:flush(); assert(io.read("*l") == "go")
local origin = assert(os.getenv("ERGOPTI_NATIVE_UPDATER_ORIGIN"))
local mode = assert(os.getenv("ERGOPTI_NATIVE_UPDATER_MODE"))
local count, path, failure = 0, nil, nil
assert(Manager.download_release({ tag = "v4.0.0", download_url = origin .. "/archive",
	checksum_url = origin .. "/checksum" }, function(received_path, err)
	count = count + 1; path, failure = received_path, err
end))
uv.run()
if mode ~= "healthy" then
 assert(count == 0 and not uv.loop_alive() and Manager.get_state() == "downloading",
  "foreign namespace debt was falsely acknowledged")
 assert(Manager.cancel_update() == true, "original transfer cancellation refused")
 assert(count == 0 and not uv.loop_alive() and Manager.get_state() == "downloading",
  "logical cancellation borrowed physical namespace settlement")
 print("namespace-conflict"); io.stdout:flush()
 assert(io.read("*l") == "competitors-retired")
 assert(Manager.cancel_update() == true, "original retained cleanup retry refused")
 uv.run()
else
 print("transfer-settled"); io.stdout:flush()
end
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
assert(type(prepared_artifact) == "table" and type(prepared_output) == "table"
 and type(prepared_digest) == "table", "Actual prepared runtime owners lost")
"""


def read_phase(child, deadline):
    """Read one fixed bounded phase line under the original operation deadline."""
    received = bytearray()
    while True:
        remaining = deadline - time.monotonic()
        assert remaining > 0 and select.select([child.stdout], [], [], remaining)[0], (
            "actual transfer did not publish its retirement phase"
        )
        block = os.read(child.stdout.fileno(), 65 - len(received))
        assert block, "native retirement phase ended before its complete line"
        received.extend(block)
        assert len(received) <= 64, "native retirement phase exceeded its fixed bound"
        if b"\n" in received:
            assert bytes(received) in (b"namespace-conflict\n", b"transfer-settled\n"), (
                "native retirement phase was malformed or unknown"
            )
            assert time.monotonic() < deadline, "original native phase deadline expired"
            return bytes(received).decode("ascii").strip()


class RetainedFixtureRoot:
    """Never recursively retire producer namespace debt after a failed case."""

    def __enter__(self):
        self.folder = tempfile.mkdtemp(prefix="ergopti-updater-temp-ownership-")
        self.path = pathlib.Path(self.folder)
        self.identity = self.path.lstat()
        self.complete = False
        self.temporary_parents = []
        return self

    def __exit__(self, error_type, _error, _traceback):
        if error_type is not None or not self.complete:
            print("RETAINED native updater fixture inputs: closure not qualified", flush=True)
            return False
        # Whole success plus actual absence of every producer namespace precedes
        # fixture-input retirement. No native path/FD cleanup is synthesized.
        retained = self.path.lstat()
        assert (retained.st_dev, retained.st_ino) == (self.identity.st_dev, self.identity.st_ino)
        assert stat.S_ISDIR(retained.st_mode) and not self.path.is_symlink()
        for parent, identity in self.temporary_parents:
            current = parent.lstat()
            assert (current.st_dev, current.st_ino) == (identity.st_dev, identity.st_ino)
            assert stat.S_ISDIR(current.st_mode) and not parent.is_symlink()
            assert not any(parent.iterdir()), "native producer namespace debt remains"
        shutil.rmtree(self.path)  # Fixture's proved-complete private inputs only.
        return False


def main():
    assert os.getuid() != 0, "native updater ownership receipts require an ordinary user"
    interpreter = os.environ.get("ERGOPTI_HTTP_TEST_LUA", "luajit")
    checks, failures = 0, 0
    active = {}
    history = b"Synthetic unrelated adjacent bytes"
    with RetainedFixtureRoot() as fixture_root:
        root = fixture_root.path
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
                            r'mkdirat\([^,\n]*, "(\.ergopti-transfer-[0-9a-f]{32})", 0700\)\s+=\s+0',
                            trace,
                        )
                        assert names, "native temporary allocation was not observed"
                        assert len(names) == 1, "native transfer namespace was ambiguous"
                        base = case["temporary_parent"] / names[0]
                        identity = base.lstat()
                        assert stat.S_ISDIR(identity.st_mode) and not base.is_symlink()
                        assert (
                            identity.st_uid == os.geteuid()
                            and stat.S_IMODE(identity.st_mode) == 0o700
                        )
                        assert re.search(
                            r"openat\([^,\n]*<"
                            + re.escape(str(base))
                            + r'>, "\.", [^\n]*O_TMPFILE[^\n]*\)\s+=\s+[0-9]+',
                            trace,
                        ), "actual anonymous output allocation was not observed"
                        case["base"], case["base_identity"] = base, identity
                        case["archive"] = base / "ergopti-plus-linux.tar.gz"
                        if mode != "healthy":
                            for suffix in (".tar.gz", ".tar.gz.part"):
                                candidate = base / ("ergopti-plus-linux" + suffix)
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

        def verify_foreign(case, alias):
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

        def retire_foreign(case):
            for candidate, identity, _target in case["foreign"]:
                retained = candidate.lstat()
                assert (retained.st_dev, retained.st_ino) == (identity.st_dev, identity.st_ino), (
                    "fixture competitor changed before its owned removal"
                )
                candidate.unlink()
                assert not candidate.exists() and not candidate.is_symlink(), (
                    "fixture-owned competitor retirement was not observed"
                )
            case["foreign_retired"] = True

        class Origin(http.server.HTTPServer):
            def server_bind(self):
                socketserver.TCPServer.server_bind(self)
                self.server_name, self.server_port = self.server_address

        server = Origin(("127.0.0.1", 0), Handler)
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
                temporary_parent = case_root / "tmp"
                temporary_parent.mkdir(mode=0o700)
                fixture_root.temporary_parents.append((temporary_parent, temporary_parent.lstat()))
                case = {
                    "root": case_root,
                    "trace": case_root / "trace",
                    "temporary_parent": temporary_parent,
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
                        "TMPDIR": str(temporary_parent),
                        "XDG_CONFIG_HOME": str(case_root / "config"),
                        "ERGOPTI_NATIVE_UPDATER_ORIGIN": f"https://127.0.0.1:{server.server_port}",
                        "ERGOPTI_NATIVE_UPDATER_MODE": mode,
                        "LUA_PATH": "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;",
                    }
                )
                child = None
                case_failed = False
                try:
                    child = subprocess.Popen(
                        [
                            "strace",
                            "-e",
                            "trace=mkdirat,openat,linkat,unlinkat",
                            "-yy",
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
                    deadline = time.monotonic() + 15
                    child.stdin.write("go\n")
                    child.stdin.flush()
                    phase = read_phase(child, deadline)
                    assert "error" not in active, str(active.get("error"))
                    assert "base" in case, "native checksum request was not received"
                    if mode != "healthy":
                        assert phase == "namespace-conflict", "original namespace debt phase absent"
                        retained = case["base"].lstat()
                        assert (retained.st_dev, retained.st_ino) == (
                            case["base_identity"].st_dev,
                            case["base_identity"].st_ino,
                        ), "original transfer namespace changed while cleanup was held"
                        if mode == "publication-collision":
                            trace = case["trace"].read_text()[case["position"] :]
                            assert re.search(
                                r"linkat\([^\n]*<"
                                + re.escape(str(case["base"]))
                                + r'>, "ergopti-plus-linux\.tar\.gz", AT_SYMLINK_FOLLOW\)'
                                + r"\s+=\s+-1 EEXIST",
                                trace,
                            ), "real canonical publication collision was not observed"
                        verify_foreign(case, alias)
                        retire_foreign(case)
                        response = "competitors-retired\n"
                    else:
                        assert phase == "transfer-settled", (
                            "actual transfer settlement phase absent"
                        )
                        verify_foreign(case, alias)
                        response = ""
                    remaining = deadline - time.monotonic()
                    assert remaining > 0, "original native operation budget expired"
                    stdout, stderr = child.communicate(input=response, timeout=remaining)
                    assert child.returncode == 0, (stdout + stderr)[-1200:]
                    assert not case["base"].exists(), "owned reserved file leaked"
                    expected = 0 if mode in ("checksum-http", "invalid-checksum") else 1
                    assert case["archive_requests"] == expected, "native archive dispatch diverged"
                    if mode == "healthy":
                        assert not case["archive"].exists(), (
                            "cancel leaked actual canonical archive"
                        )
                        assert not pathlib.Path(str(case["base"]) + ".tar.gz").exists(), (
                            "cancel leaked verified archive"
                        )
                    print(f"PASS native {mode} preserves {alias} ownership", flush=True)
                except (AssertionError, subprocess.TimeoutExpired) as error:
                    case_failed = True
                    failures += 1
                    print(f"FAIL native {mode} preserves {alias} ownership: {error}", flush=True)
                finally:
                    cleanup_failed = False
                    try:
                        if child and child.poll() is None:
                            child.kill()
                            child.communicate()
                    except BaseException:
                        cleanup_failed = True
                    if case["foreign"] and not case.get("foreign_retired"):
                        # Independently attempt only exact fixture-owned entries.
                        # A refusal preserves the body failure and whole input root.
                        for candidate, identity, _target in case["foreign"]:
                            try:
                                if candidate.exists() or candidate.is_symlink():
                                    retained = candidate.lstat()
                                    assert (retained.st_dev, retained.st_ino) == (
                                        identity.st_dev,
                                        identity.st_ino,
                                    )
                                    candidate.unlink()
                            except BaseException:
                                cleanup_failed = True
                    if cleanup_failed:
                        if not case_failed:
                            failures += 1
                        print(
                            f"FAIL native {mode} preserves {alias} ownership: owned cleanup refused",
                            flush=True,
                        )
        finally:
            server.shutdown()
            server.server_close()
            thread.join(timeout=2)
            assert not thread.is_alive(), "owned TLS server did not stop"
        fixture_root.complete = failures == 0 and checks == 12
    print(f"Native updater temporary ownership receipts: {checks} checks, {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
