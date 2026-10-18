#!/usr/bin/env python3
# Native parent-death regression: stop the already-exec'd SQLite process, SIGKILL
# its Lua owner, and reap the exact child under a private subreaper. No orphan,
# process double, deadline change, SQL argv, or physical-input claim.
import argparse
import ctypes
import os
from pathlib import Path
import select
import signal
import subprocess
import tempfile
import time


def wait_until(predicate, message):
    end = time.monotonic() + 3
    while time.monotonic() < end:
        if predicate():
            return
        time.sleep(0.001)
    raise AssertionError(message)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--lua", default="luajit")
    options = parser.parse_args()
    libc = ctypes.CDLL(None, use_errno=True)
    assert libc.prctl(36, 1, 0, 0, 0) == 0  # PR_SET_CHILD_SUBREAPER
    child = None
    with tempfile.TemporaryDirectory(prefix="ergopti-sqlite-minimal-") as minimal:
        config = Path(minimal, "config", "ergopti")
        config.mkdir(parents=True)
        config.joinpath("config.toml").write_text("[metrics]\nenabled=true\n")
        environment = os.environ.copy()
        for kind in ("CONFIG", "DATA", "CACHE", "STATE"):
            environment["XDG_" + kind + "_HOME"] = str(Path(minimal, kind.lower()))
        result = subprocess.run(
            [
                options.lua,
                "tests/hardware/run_sqlite_owned_flush_receipts.lua",
                "--no-luv",
                minimal,
            ],
            env=environment,
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        print(result.stdout.strip())
    with tempfile.TemporaryDirectory(prefix="ergopti-sqlite-stale-clock-") as clock:
        result = subprocess.run(
            [
                options.lua,
                "tests/hardware/run_sqlite_owned_flush_receipts.lua",
                "--stale-clock",
                clock,
            ],
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        print(result.stdout.strip())
    with tempfile.TemporaryDirectory(prefix="ergopti-sqlite-parent-death-") as root:
        parent = subprocess.Popen(
            [
                options.lua,
                "tests/hardware/run_sqlite_owned_flush_receipts.lua",
                "--parent-death",
                root,
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            assert select.select([parent.stdout], [], [], 3)[0], "owner did not dispatch SQLite"
            receipt = parent.stdout.readline().strip().split()
            assert len(receipt) == 3 and receipt[0] == "READY"
            assert int(receipt[1]) == parent.pid
            child = int(receipt[2])
            proc = Path("/proc", str(child))
            wait_until(
                lambda: proc.joinpath("comm").read_text().strip() == "sqlite3",
                "SQLite exec never acknowledged",
            )
            os.kill(child, signal.SIGSTOP)
            wait_until(
                lambda: "\nState:\tT" in proc.joinpath("status").read_text(), "SQLite never stopped"
            )
            os.kill(parent.pid, signal.SIGKILL)
            assert parent.wait(timeout=3) == -signal.SIGKILL
            status = None

            def reaped():
                nonlocal status
                pid, value = os.waitpid(child, os.WNOHANG)
                if pid == child:
                    status = value
                    return True
                return False

            wait_until(reaped, "parent-bound SQLite survived its stopped owner SIGKILL")
            assert os.WIFSIGNALED(status) and os.WTERMSIG(status) == signal.SIGKILL
            assert not proc.exists(), "SQLite PID retained after exact reap"
            child = None
            print(
                "PASS native stopped SQLite dies on owner SIGKILL, exact child reaped; runtime="
                + options.lua
            )
        finally:
            if parent.poll() is None:
                parent.kill()
                parent.wait(timeout=3)
            if child is not None:
                try:
                    os.kill(child, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    os.waitpid(child, 0)
                except ChildProcessError:
                    pass
            parent.stdout.close()
            parent.stderr.close()


if __name__ == "__main__":
    main()
