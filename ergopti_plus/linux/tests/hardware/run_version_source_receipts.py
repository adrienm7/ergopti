#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_version_source_receipts.py
#
# Resolve release versions through real native build-stamp endpoints. No file
# adapter, process, or stream syscall is mocked. A FIFO with a readable peer must
# still be refused before opening a blocking stdio stream.

import os
import pathlib
import socket
import subprocess
import tempfile

WORKER = r"""
local root = assert(os.getenv("ERGOPTI_VERSION_ROOT"))
local Version = require("infra.version")
local version, source = Version.resolve({ shared_root = root })
assert(version == os.getenv("ERGOPTI_VERSION_EXPECT"), "unexpected native version: " .. tostring(version))
assert(source == os.getenv("ERGOPTI_VERSION_SOURCE"), "unexpected native version source: " .. tostring(source))
"""


def main():
    interpreter = os.environ.get("ERGOPTI_VERSION_TEST_LUA", "luajit")
    checks, failures = 0, 0
    with tempfile.TemporaryDirectory(prefix="ergopti-native-version-source-") as folder:
        root = pathlib.Path(folder)
        for kind in (
            "regular",
            "regular-link",
            "malformed",
            "empty",
            "fifo",
            "fifo-link",
            "fifo-peer",
            "directory",
            "socket",
            "unreadable",
            "missing",
        ):
            checks += 1
            case = root / kind
            case.mkdir()
            stamp = case / "build_stamp.txt"
            owner = None
            descriptor = None
            content = b"version=1.2.3\ncommit=123456789abcdef\n"
            expected, source = "local", "local"
            if kind in ("regular", "regular-link", "malformed", "empty", "unreadable"):
                actual = case / "target" if kind == "regular-link" else stamp
                actual.write_bytes(
                    b"version=broken\n"
                    if kind == "malformed"
                    else b""
                    if kind == "empty"
                    else content
                )
                if kind == "regular-link":
                    stamp.symlink_to(actual)
                if kind == "unreadable":
                    actual.chmod(0)
                else:
                    expected, source = (
                        ("unknown", "unknown")
                        if kind in ("malformed", "empty")
                        else ("1.2.3", "build")
                    )
            elif kind in ("fifo", "fifo-link", "fifo-peer"):
                actual = case / "pipe" if kind == "fifo-link" else stamp
                os.mkfifo(actual)
                if kind == "fifo-link":
                    stamp.symlink_to(actual)
                if kind == "fifo-peer":
                    descriptor = os.open(actual, os.O_RDWR | os.O_NONBLOCK)
                    os.write(descriptor, content)
            elif kind == "directory":
                stamp.mkdir()
            elif kind == "socket":
                owner = socket.socket(socket.AF_UNIX)
                owner.bind(str(stamp))
            before = stamp.lstat() if stamp.exists() else None
            env = dict(os.environ)
            env.update(
                ERGOPTI_VERSION_ROOT=str(case),
                ERGOPTI_VERSION_EXPECT=expected,
                ERGOPTI_VERSION_SOURCE=source,
                XDG_CONFIG_HOME=str(root / "config"),
                LUA_PATH="./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;",
            )
            try:
                result = subprocess.run(
                    [interpreter, "-e", WORKER], env=env, capture_output=True, text=True, timeout=1
                )
                assert result.returncode == 0, (result.stdout + result.stderr)[-1000:]
                if before:
                    after = stamp.lstat()
                    assert (after.st_dev, after.st_ino, after.st_mode) == (
                        before.st_dev,
                        before.st_ino,
                        before.st_mode,
                    ), "version resolution changed its source"
                else:
                    assert not stamp.exists(), "version resolution created a missing stamp"
                if kind in ("regular", "regular-link"):
                    assert stamp.read_bytes() == content, "version resolution changed release bytes"
                print(f"PASS native version source {kind}", flush=True)
            except (AssertionError, subprocess.TimeoutExpired) as error:
                failures += 1
                print(f"FAIL native version source {kind}: {error}", flush=True)
            finally:
                if descriptor is not None:
                    os.close(descriptor)
                if owner is not None:
                    owner.close()
                if kind == "unreadable":
                    stamp.chmod(0o600)
    print(f"Native version sources: {checks} checks, {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
