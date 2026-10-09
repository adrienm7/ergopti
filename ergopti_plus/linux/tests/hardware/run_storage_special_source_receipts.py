#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_storage_special_source_receipts.py
#
# Real filesystem endpoints must never block JSON Storage or be replaced on read
# failure. Native FIFOs, symlinks, directories and Unix sockets are owned by this
# fixture; regular-file and symlink-to-file controls use the production adapter.
# No filesystem, storage or configuration adapter is mocked; no TOML is changed.

import itertools
import os
import pathlib
import socket
import stat
import subprocess
import tempfile


ORIGINAL = '{"preserve":"original"}'
WORKER = r"""
local baseline = os.getenv("ERGOPTI_STORAGE_BASELINE")
if baseline then
	package.preload["adapters.storage"] = function() return assert(loadfile(baseline))() end
end
local S = require("adapters.storage")
local regular = os.getenv("ERGOPTI_STORAGE_REGULAR") == "yes"
assert(S.get("preserve", "default") == (regular and "original" or "default"))
local operation = os.getenv("ERGOPTI_STORAGE_OPERATION")
local result
if operation == "set" then result = S.set("replacement", true)
elseif operation == "set_many" then result = S.set_many({replacement=true})
elseif operation == "delete" then result = S.delete("preserve")
elseif operation == "clear" then result = S.clear() end
assert(result == regular, "mutation admission did not preserve an unreadable endpoint")
if not regular then
	local recovery = assert(S.recovery_status())
	assert(recovery.reason == "read_failed" and recovery.preserved == true)
	assert(recovery.path == S.path())
end
"""


def main():
    interpreter = os.environ.get("ERGOPTI_STORAGE_TEST_LUA", "luajit")
    checks, failures = 0, 0
    with tempfile.TemporaryDirectory(prefix="ergopti-native-storage-source-") as folder:
        for number, (kind, operation) in enumerate(
            itertools.product(
                (
                    "regular",
                    "regular-link",
                    "fifo",
                    "fifo-link",
                    "fifo-with-peer",
                    "directory",
                    "socket",
                ),
                ("set", "set_many", "delete", "clear"),
            )
        ):
            root = pathlib.Path(folder) / str(number)
            source = root / "ergopti_plus" / "storage.json"
            source.parent.mkdir(parents=True)
            endpoint = root / "endpoint"
            native_socket = None
            peer_fd = None
            if kind == "regular":
                source.write_text(ORIGINAL)
            elif kind == "regular-link":
                endpoint.write_text(ORIGINAL)
                source.symlink_to(endpoint)
            elif kind in ("fifo", "fifo-with-peer"):
                os.mkfifo(source)
                if kind == "fifo-with-peer":
                    peer_fd = os.open(source, os.O_RDWR | os.O_NONBLOCK)
                    os.write(peer_fd, ORIGINAL.encode())
            elif kind == "fifo-link":
                os.mkfifo(endpoint)
                source.symlink_to(endpoint)
            elif kind == "directory":
                source.mkdir()
            else:
                native_socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                native_socket.bind(str(source))
            before = source.lstat()
            env = dict(os.environ)
            env.update(
                XDG_CONFIG_HOME=str(root),
                LUA_PATH="./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;",
                ERGOPTI_STORAGE_REGULAR="yes" if kind.startswith("regular") else "no",
                ERGOPTI_STORAGE_OPERATION=operation,
            )
            checks += 1
            try:
                child = subprocess.run(
                    [interpreter, "-e", WORKER], env=env, capture_output=True, text=True, timeout=2
                )
                assert child.returncode == 0, (child.stdout + child.stderr)[-1000:]
                if not kind.startswith("regular"):
                    after = source.lstat()
                    assert (after.st_ino, after.st_mode) == (before.st_ino, before.st_mode)
                    assert not pathlib.Path(str(source) + ".tmp").exists()
                    assert not pathlib.Path(str(source) + ".corrupt").exists()
                    if kind == "fifo-link":
                        assert source.readlink() == endpoint and stat.S_ISFIFO(
                            endpoint.stat().st_mode
                        )
                elif kind == "regular-link":
                    assert endpoint.read_text() == ORIGINAL, "symlink target bytes were changed"
                print(f"PASS native JSON source {kind} {operation}", flush=True)
            except (AssertionError, subprocess.TimeoutExpired) as error:
                failures += 1
                print(f"FAIL native JSON source {kind} {operation}: {error}", flush=True)
            finally:
                if native_socket is not None:
                    native_socket.close()
                if peer_fd is not None:
                    os.close(peer_fd)
    print(f"Native special storage source receipts: {checks} checks, {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
