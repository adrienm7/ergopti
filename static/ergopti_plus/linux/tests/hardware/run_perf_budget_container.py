#!/usr/bin/env python3
# tests/hardware/run_perf_budget_container.py
"""The Linux latency budgets, measured on the real daemon in a container session.

Two checks, each able to fail on the code before the 2026-11-11 performance
pass:

1. Under Xvfb, layouts/run_xkb_source_read_cost.lua (a layout proof of an unchanged
   keymap no longer downloads it, and setxkbmap still invalidates what it
   reuses) and layouts/run_keymap_native_dump.lua (a resolve serializes the keymap in
   process instead of forking xkbcomp, parsed alike on five layouts).
2. tools/bench/linux-session-bench.py --budgets, reduced: spawn to ready, key
   press to output, tap-hold release to tap, typing per replacement character,
   and tray submenu and root re-opens, each against its budget.

Exit 0 = every budget held; 1 = a failure; 2 = no environment.
"""

import os
import subprocess
import sys
import time

import container_session as cs

BENCH = cs.DRIVER.parent.parent.parent / "tools" / "bench" / "linux-session-bench.py"


def source_read_cost():
    display = ":%d" % (40 + os.getpid() % 20)
    server = subprocess.Popen(
        ["Xvfb", display, "-screen", "0", "800x600x24", "-nolisten", "tcp"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        env = dict(os.environ, DISPLAY=display, LUA_PATH=cs.LUA_PATH, LUA_CPATH=cs.LUA_CPATH)
        ready = cs.wait_for(
            lambda: subprocess.run(["xdpyinfo"], env=env, capture_output=True).returncode == 0, 10
        )
        if not ready:
            raise RuntimeError("ENVIRONMENT: Xvfb did not start")
        for probe, claim in (
            (
                "layouts/run_xkb_source_read_cost.lua",
                "an unchanged keymap is proven without its download",
            ),
            (
                "layouts/run_keymap_native_dump.lua",
                "a resolve serializes the keymap without forking xkbcomp",
            ),
        ):
            result = subprocess.run(
                ["luajit", "tests/hardware/" + probe],
                cwd=cs.DRIVER,
                env=dict(env, XDG_SESSION_TYPE="x11"),
            )
            if result.returncode == 2:
                raise RuntimeError("ENVIRONMENT: %s cannot run here" % probe)
            cs.check(result.returncode == 0, claim)
    finally:
        server.terminate()
        server.wait(10)
        time.sleep(0.2)


def session_budgets():
    result = subprocess.run(
        [
            sys.executable,
            str(BENCH),
            "--runs",
            "3",
            "--keys",
            "80",
            "--hotstrings",
            "12",
            "--tap-holds",
            "10",
            "--tray-rounds",
            "3",
            "--budgets",
        ]
    )
    if result.returncode == 2:
        raise RuntimeError("ENVIRONMENT: the session bench cannot run here")
    cs.check(result.returncode == 0, "every session latency budget held")


def proof():
    source_read_cost()
    session_budgets()


if __name__ == "__main__":
    sys.exit(cs.run(proof))
