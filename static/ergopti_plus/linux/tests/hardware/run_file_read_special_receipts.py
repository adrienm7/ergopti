#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_file_read_special_receipts.py
#
# Real endpoints exercise the generic native file adapter and the updater's
# production read port. No update transaction, TOML writer or adapter is mocked.
# Regular-file byte controls include empty, UTF-8, CRLF and NUL content.

import os
import pathlib
import socket
import subprocess
import tempfile


WORKER = r"""
local path = assert(os.getenv("ERGOPTI_FILE_SOURCE"))
local value
if os.getenv("ERGOPTI_FILE_PORT") == "updater" then
	value = require("modules.updater.installer").DEFAULT_OPS.read(path)
else value = require("adapters.file_system").read(path) end
if os.getenv("ERGOPTI_FILE_REGULAR") == "yes" then
	local expected = assert(io.open(assert(os.getenv("ERGOPTI_FILE_EXPECTED")), "rb"))
	local bytes = assert(expected:read("*a")); assert(expected:close())
	assert(value == bytes, "native file content bytes were changed")
else assert(value == nil, "a special endpoint was accepted as a regular file") end
"""


def main():
    interpreter = os.environ.get("ERGOPTI_FILE_READ_TEST_LUA", "luajit")
    checks, failures = 0, 0
    with tempfile.TemporaryDirectory(prefix="ergopti-native-file-source-") as folder:
        base = pathlib.Path(folder)
        for kind in (
            "regular",
            "regular-link",
            "fifo",
            "fifo-link",
            "fifo-with-peer",
            "directory",
            "socket",
        ):
            payloads = (
                (b"native \xc3\xa9\r\nbytes", b"", b"start\0end\r\n")
                if kind.startswith("regular")
                else (b"stream bytes",)
            )
            for payload in payloads:
                for port in ("filesystem", "updater"):
                    root = base / str(checks)
                    root.mkdir()
                    source, endpoint, expected = (
                        root / "source",
                        root / "endpoint",
                        root / "expected",
                    )
                    expected.write_bytes(payload)
                    peer, listener = None, None
                    if kind == "regular":
                        source.write_bytes(payload)
                    elif kind == "regular-link":
                        endpoint.write_bytes(payload)
                        source.symlink_to(endpoint)
                    elif kind in ("fifo", "fifo-with-peer"):
                        os.mkfifo(source)
                        if kind == "fifo-with-peer":
                            peer = os.open(source, os.O_RDWR | os.O_NONBLOCK)
                            os.write(peer, payload)
                    elif kind == "fifo-link":
                        os.mkfifo(endpoint)
                        source.symlink_to(endpoint)
                    elif kind == "directory":
                        source.mkdir()
                    else:
                        listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                        listener.bind(str(source))
                    before = source.lstat()
                    env = dict(os.environ)
                    env.update(
                        XDG_CONFIG_HOME=str(root / "config"),
                        LUA_PATH="./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;",
                        ERGOPTI_FILE_SOURCE=str(source),
                        ERGOPTI_FILE_EXPECTED=str(expected),
                        ERGOPTI_FILE_PORT=port,
                        ERGOPTI_FILE_REGULAR="yes" if kind.startswith("regular") else "no",
                    )
                    checks += 1
                    try:
                        child = subprocess.run(
                            [interpreter, "-e", WORKER],
                            env=env,
                            capture_output=True,
                            text=True,
                            timeout=2,
                        )
                        assert child.returncode == 0, (child.stdout + child.stderr)[-1000:]
                        after = source.lstat()
                        assert (after.st_ino, after.st_mode) == (before.st_ino, before.st_mode)
                        if kind.startswith("regular"):
                            assert source.read_bytes() == payload
                        print(
                            f"PASS native file read {kind} {port} bytes={len(payload)}", flush=True
                        )
                    except (AssertionError, subprocess.TimeoutExpired) as error:
                        failures += 1
                        print(f"FAIL native file read {kind} {port}: {error}", flush=True)
                    finally:
                        if peer is not None:
                            os.close(peer)
                        if listener is not None:
                            listener.close()
    print(f"Native special file read receipts: {checks} checks, {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
