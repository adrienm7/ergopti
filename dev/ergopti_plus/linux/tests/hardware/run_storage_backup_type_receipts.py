#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_storage_backup_type_receipts.py
#
# Corrupt JSON recovery must inspect occupied backup paths without opening FIFO
# endpoints or following dangling/foreign symlinks. Actual files, socket nodes,
# permissions and named pipes exercise the production recovery path. No file,
# shell or process adapter is mocked; TOML is outside this fixture.

import os
import pathlib
import socket
import subprocess
import tempfile


WORKER = r"""
local Storage = require("adapters.storage")
assert(Storage.get("value", "default") == "default")
local recovery = assert(Storage.recovery_status())
if os.getenv("ERGOPTI_NATIVE_BACKUP_REFUSE") == "true" then
	assert(recovery.preserved == false and Storage.set("value", "replacement") == false)
else
	assert(recovery.preserved == true, "known occupied backup prevented safe recovery")
	assert(Storage.set("value", "replacement"))
	print(recovery.path)
end
"""


def main():
    assert os.getuid() != 0, "backup type receipts require an ordinary user"
    interpreter = os.environ.get("ERGOPTI_STORAGE_TEST_LUA", "luajit")
    checks, failures = 0, 0
    original = b"{synthetic invalid JSON retained bytes"
    history = b"Synthetic prior backup bytes"
    with tempfile.TemporaryDirectory(prefix="ergopti-storage-backup-type-") as folder:
        root = pathlib.Path(folder)

        def check(name, test):
            nonlocal checks, failures
            checks += 1
            try:
                test()
                print(f"PASS {name}", flush=True)
            except (AssertionError, subprocess.TimeoutExpired) as failure:
                failures += 1
                detail = (
                    "native recovery blocked beyond 2 seconds"
                    if isinstance(failure, subprocess.TimeoutExpired)
                    else str(failure)
                )
                print(f"FAIL {name}: {detail}", flush=True)

        def case(kind, depth):
            case_root = root / f"{kind}-{depth}"
            directory = case_root / "ergopti_plus"
            directory.mkdir(parents=True)
            store = directory / "storage.json"
            first = directory / "storage.json.corrupt"
            candidate = first if depth == 0 else directory / "storage.json.corrupt.1"
            target = case_root / "foreign"
            store.write_bytes(original)
            if depth:
                first.write_bytes(history)
            endpoint = None
            if kind in ("symlink", "dangling", "device"):
                if kind == "symlink":
                    target.write_bytes(history)
                candidate.symlink_to("/dev/null" if kind == "device" else target)
            elif kind == "fifo":
                os.mkfifo(candidate)
            elif kind == "directory":
                candidate.mkdir()
            elif kind == "socket":
                endpoint = socket.socket(socket.AF_UNIX)
                # A relative name avoids exceeding sun_path in long TMPDIRs.
                previous_directory = pathlib.Path.cwd()
                os.chdir(directory)
                try:
                    endpoint.bind(candidate.name)
                finally:
                    os.chdir(previous_directory)
            else:
                candidate.write_bytes(history)
            identity = candidate.lstat()
            refused = kind in ("unreadable", "denied-parent")
            if kind == "unreadable":
                candidate.chmod(0)
            if kind == "denied-parent":
                directory.chmod(0o555)
            env = dict(os.environ)
            env["XDG_CONFIG_HOME"] = str(case_root)
            env["ERGOPTI_NATIVE_BACKUP_REFUSE"] = "true" if refused else "false"
            env["LUA_PATH"] = (
                "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;"
            )
            try:
                child = subprocess.run(
                    [interpreter, "-e", WORKER], env=env, capture_output=True, text=True, timeout=2
                )
                assert candidate.exists() or candidate.is_symlink(), "occupied backup was removed"
                current = candidate.lstat()
                assert (current.st_dev, current.st_ino) == (identity.st_dev, identity.st_ino), (
                    "occupied backup path was overwritten"
                )
                if kind == "dangling":
                    assert not target.exists()
                if kind == "symlink":
                    assert target.read_bytes() == history
                if depth:
                    assert first.read_bytes() == history
                assert child.returncode == 0, (child.stdout + child.stderr)[-1200:]
                if refused:
                    assert store.read_bytes() == original
                else:
                    suffix = directory / f"storage.json.corrupt.{depth + 1}"
                    assert suffix.is_file() and suffix.read_bytes() == original
                    assert '"replacement"' in store.read_text()
            finally:
                directory.chmod(0o700)
                if kind == "unreadable":
                    candidate.chmod(0o600)
                if endpoint:
                    endpoint.close()

        for depth in (0, 1):
            for kind in ("dangling", "fifo", "socket", "directory", "device", "symlink"):
                check(
                    f"actual {kind} backup at suffix {depth} remains occupied",
                    lambda kind=kind, depth=depth: case(kind, depth),
                )
        for kind in ("regular", "unreadable", "denied-parent"):
            check(f"native {kind} backup policy is preserved", lambda kind=kind: case(kind, 0))
    print(f"Native JSON backup type receipts: {checks} checks, {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
