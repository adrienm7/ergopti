#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_storage_backup_race_receipts.py
#
# Delay the real publication syscall with strace, then create a competing backup
# from this process. Files, inodes, processes and recovery are native; only the
# syscall timing is controlled. No filesystem or process adapter is mocked.

import os
import pathlib
import subprocess
import tempfile
import time


WORKER = r"""
local Storage = require("adapters.storage")
print("ready"); io.stdout:flush()
assert(Storage.get("value", "default") == "default")
local recovery = assert(Storage.recovery_status())
assert(recovery.preserved == true, "backup collision prevented recovery")
assert(Storage.set("value", "replacement"))
print(recovery.path)
"""


def main():
    interpreter = os.environ.get("ERGOPTI_STORAGE_TEST_LUA", "luajit")
    checks, failures = 0, 0
    original = b"{Synthetic corrupt JSON bytes"
    history = b"Synthetic competing backup bytes"
    syscalls = "rename,renameat2,link,linkat"
    with tempfile.TemporaryDirectory(prefix="ergopti-storage-backup-race-") as folder:
        root = pathlib.Path(folder)

        def case(kind, depth):
            home = root / f"{kind}-{depth}"
            directory = home / "ergopti_plus"
            directory.mkdir(parents=True)
            store = directory / "storage.json"
            first = directory / "storage.json.corrupt"
            candidate = directory / ("storage.json.corrupt" + (".1" if depth else ""))
            target = home / "foreign"
            store.write_bytes(original)
            if depth:
                first.write_bytes(history)
            trace = home / "trace"
            env = dict(os.environ)
            env["XDG_CONFIG_HOME"] = str(home)
            env["LUA_PATH"] = (
                "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;"
            )
            with subprocess.Popen(
                [
                    "strace",
                    "-e",
                    "trace=" + syscalls,
                    "-e",
                    "inject=" + syscalls + ":delay_enter=1s",
                    "-o",
                    str(trace),
                    interpreter,
                    "-e",
                    WORKER,
                ],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            ) as child:
                try:
                    assert child.stdout.readline().strip() == "ready", "worker did not start"
                    deadline = time.monotonic() + 5
                    while True:
                        observed = trace.read_text() if trace.exists() else ""
                        if any(name + "(" in observed for name in syscalls.split(",")):
                            break
                        assert child.poll() is None, "worker exited before publication"
                        assert time.monotonic() < deadline, "publication syscall was not observed"
                        time.sleep(0.005)
                    if kind in ("symlink", "hardlink"):
                        target.write_bytes(history)
                    if kind in ("symlink", "dangling"):
                        candidate.symlink_to(target)
                    elif kind == "hardlink":
                        os.link(target, candidate)
                    elif kind == "fifo":
                        os.mkfifo(candidate)
                    elif kind == "directory":
                        candidate.mkdir()
                    else:
                        candidate.write_bytes(history)
                    identity = candidate.lstat()
                    stdout, stderr = child.communicate(timeout=8)
                    retained = candidate.lstat()
                    assert (retained.st_dev, retained.st_ino) == (
                        identity.st_dev,
                        identity.st_ino,
                    ), "concurrently created backup inode was overwritten"
                    if kind in ("regular", "hardlink"):
                        assert candidate.read_bytes() == history
                    if kind in ("symlink", "hardlink"):
                        assert target.read_bytes() == history
                    if kind in ("symlink", "dangling"):
                        assert candidate.is_symlink() and candidate.readlink() == target
                    if kind == "dangling":
                        assert not target.exists()
                    if depth:
                        assert first.read_bytes() == history
                    assert child.returncode == 0, (stdout + stderr)[-1200:]
                    next_backup = directory / f"storage.json.corrupt.{depth + 1}"
                    assert next_backup.read_bytes() == original
                    assert stdout.strip().endswith(str(next_backup))
                    assert '"replacement"' in store.read_text()
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.communicate()

        for depth in (0, 1):
            for kind in ("regular", "hardlink", "symlink", "dangling", "fifo", "directory"):
                checks += 1
                try:
                    case(kind, depth)
                    print(f"PASS real competing {kind} at suffix {depth}", flush=True)
                except (AssertionError, subprocess.TimeoutExpired) as failure:
                    failures += 1
                    print(f"FAIL real competing {kind} at suffix {depth}: {failure}", flush=True)
    print(f"Native JSON backup race receipts: {checks} checks, {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
