#!/usr/bin/env python3
# static/ergopti_plus/linux/tests/hardware/run_restart_zombie_receipts.py
#
# Execute production relay commands against owned native processes. prctl sets
# real kernel comm bytes; the parent deliberately retains an actual zombie.
# Native setsid/sh/sed, process groups and the wrapper run without adapter mocks.
# This tests relay handoff, not keyboard ownership or systemd restart behavior.

import ctypes
import itertools
import os
import pathlib
import signal
import subprocess
import tempfile
import time


WORKER = r"""
local R = require("modules.updater.restarter")
io.write(R.relay_command(tonumber(os.getenv("ERGOPTI_RELAY_TARGET")),
	os.getenv("ERGOPTI_RELAY_WRAPPER"),
	{os.getenv("ERGOPTI_RELAY_PAYLOAD"), os.getenv("ERGOPTI_RELAY_RECEIPT")}))
"""
PAYLOAD = "literal ' payload\nsecond line"
PR_SET_NAME, PR_SET_CHILD_SUBREAPER = 15, 36  # Native Linux prctl operations.


def wait_for(predicate, message):
    deadline = time.monotonic() + 2
    while not predicate():
        assert time.monotonic() < deadline, message
        time.sleep(0.01)


def zombie(pid):
    return "\nState:\tZ" in pathlib.Path(f"/proc/{pid}/status").read_text()


def check_case(root, interpreter, name, state):
    wrapper, receipt = root / "wrapper", root / "receipt"
    wrapper.write_text('#!/bin/sh\nprintf "%s" "$1" > "$2"\n')
    wrapper.chmod(0o700)
    ready_read, ready_write = os.pipe()
    release_read, release_write = os.pipe()
    target = os.fork()
    if target == 0:
        os.close(ready_read)
        os.close(release_write)
        result = ctypes.CDLL(None).prctl(PR_SET_NAME, ctypes.c_char_p(name.encode()), 0, 0, 0)
        if result != 0:
            os._exit(125)
        os.write(ready_write, b"R")
        os.close(ready_write)
        os.read(release_read, 1)
        os._exit(0)
    os.close(ready_write)
    os.close(release_read)
    relay = None
    try:
        assert os.read(ready_read, 1) == b"R", "native prctl setup failed"
        if state == "zombie":
            os.close(release_write)
            release_write = None
            wait_for(lambda: zombie(target), "owned target did not become a zombie")
        env = dict(os.environ)
        env.update(
            LUA_PATH="./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;",
            ERGOPTI_RELAY_TARGET=str(target),
            ERGOPTI_RELAY_WRAPPER=str(wrapper),
            ERGOPTI_RELAY_RECEIPT=str(receipt),
            ERGOPTI_RELAY_PAYLOAD=PAYLOAD,
            XDG_CONFIG_HOME=str(root / "config"),
        )
        command = subprocess.check_output(
            [interpreter, "-e", WORKER], env=env, text=True, timeout=5
        )
        # Observe the exact background PID without changing the relay script.
        launch = subprocess.run(
            ["sh", "-c", command + '\nprintf "%s\\n" "$!"'],
            capture_output=True,
            text=True,
            timeout=5,
            check=True,
        )
        relay = int(launch.stdout.strip())
        wait_for(lambda: os.getpgid(relay) == relay, "owned relay did not detach")
        if state == "alive":
            time.sleep(0.3)
            assert not receipt.exists(), "relay started the wrapper before the target exited"
            assert not zombie(target), "alive control already exited"
            os.close(release_write)
            release_write = None
            wait_for(lambda: zombie(target), "owned target did not exit after release")
        # Do not reap first: kill -0 must still see the real zombie.
        assert zombie(target)
        wait_for(receipt.exists, "relay waited indefinitely on an actual zombie")
        assert receipt.read_bytes() == PAYLOAD.encode(), "wrapper argument bytes were changed"
    finally:
        os.close(ready_read)
        if release_write is not None:
            os.close(release_write)
        if relay is not None:
            try:
                assert os.getpgid(relay) == relay, "refuse to signal an unowned process group"
                os.killpg(relay, signal.SIGTERM)
            except ProcessLookupError:
                pass
        os.waitpid(target, 0)
        # Subreaper ownership lets this fixture reap detached relays and sleeps,
        # instead of leaving their zombies to an unrelated container PID 1.
        while True:
            try:
                os.waitpid(-1, 0)
            except ChildProcessError:
                break


def main():
    assert ctypes.CDLL(None).prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) == 0, (
        "native subreaper setup failed"
    )
    interpreter = os.environ.get("ERGOPTI_RESTART_TEST_LUA", "luajit")
    checks, failures = 0, 0
    with tempfile.TemporaryDirectory(prefix="ergopti-native-relay-") as folder:
        for number, (name, state) in enumerate(
            itertools.product(
                (
                    "ordinary",
                    "space name",
                    "paren) name",
                    r"slash\name",
                    "line\rcomm",
                    "line\ncomm",
                    "paren)\ncomm",
                ),
                ("zombie", "alive"),
            )
        ):
            root = pathlib.Path(folder) / str(number)
            root.mkdir()
            checks += 1
            try:
                check_case(root, interpreter, name, state)
                print(f"PASS native relay {name!r} {state}", flush=True)
            except (AssertionError, subprocess.SubprocessError) as error:
                failures += 1
                print(f"FAIL native relay {name!r} {state}: {error}", flush=True)
    print(f"Native restart zombie receipts: {checks} checks, {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
