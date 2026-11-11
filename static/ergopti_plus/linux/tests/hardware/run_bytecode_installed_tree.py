#!/usr/bin/env python3
# tests/hardware/run_bytecode_installed_tree.py
"""The installed-tree bytecode package, booted for real in a container session.

Builds an installed tree the way install.sh lays it out (linux/, _shared/ and
the ownership receipt written by install/ownership.sh), compiles it with
install/compile_bytecode.lua, then boots the real daemon from that tree through
tools/bench/linux-session-bench.py --boot-only, twice:

1. With its package: the daemon says it loads from the bytecode package and
   warns nothing.
2. With the package moved away: it loads from source, warns once per boot, and
   reaches Daemon ready later than with the package (2026-11-11: 488 -> 355 ms
   median, the load phase 200 -> 90 ms).

Exit 0 = every claim held; 1 = a failure; 2 = no environment.
"""

import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

import container_session as cs

BENCH = cs.DRIVER.parent.parent.parent / "tools" / "bench" / "linux-session-bench.py"
SHARED = cs.DRIVER.parent / "_shared"
BOOTS = "5"


def build_tree(root):
    """An installed tree beside its receipt, compiled; returns the package path."""
    shutil.copytree(cs.DRIVER, root / "linux", symlinks=True)
    shutil.copytree(SHARED, root / "_shared", symlinks=True)
    (root / "bin").mkdir()
    subprocess.run(
        [
            "bash",
            str(root / "linux/install/ownership.sh"),
            str(root / "linux"),
            str(root / "_shared"),
            str(root),
        ],
        check=True,
    )
    subprocess.run(
        ["luajit", str(root / "linux/install/compile_bytecode.lua"), str(root)], check=True
    )
    return root / ".bytecode"


def boot(root, scratch, label):
    """Boots the tree's daemon; returns the bench's boot report."""
    output = scratch / (label + ".json")
    result = subprocess.run(
        [
            sys.executable,
            str(BENCH),
            "--runs",
            BOOTS,
            "--boot-only",
            "--driver",
            str(root / "linux"),
            "--json",
            str(output),
        ],
        stdout=subprocess.DEVNULL,
    )
    if result.returncode == 2:
        raise RuntimeError("ENVIRONMENT: the session bench cannot run here")
    cs.check(result.returncode == 0 and output.exists(), "the %s boots completed" % label)
    return json.loads(output.read_text())


def proof():
    scratch = pathlib.Path(tempfile.mkdtemp(prefix="ergopti-bytecode-proof-"))
    try:
        # The physical spelling, as install/launch.sh launches the daemon.
        root = pathlib.Path(os.path.realpath(scratch)) / "lib"
        root.mkdir()
        package = build_tree(root)
        compiled = boot(root, scratch, "bytecode")
        cs.check(
            compiled["bytecode_package_used"], "the installed tree loads from its bytecode package"
        )
        cs.check(compiled["bytecode_fallback_warnings"] == 0, "a trusted package warns nothing")
        package.rename(scratch / "held-package")
        source = boot(root, scratch, "source")
        cs.check(
            not source["bytecode_package_used"], "without its package the tree loads from source"
        )
        cs.check(source["bytecode_fallback_warnings"] == 1, "and says so once per boot")
        faster = compiled["startup_spawn_to_ready_ms"]["median"]
        slower = source["startup_spawn_to_ready_ms"]["median"]
        print("  spawn to ready: %.0f ms from source, %.0f ms from bytecode" % (slower, faster))
        cs.check(faster < slower, "the package brings Daemon ready sooner")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(cs.run(proof))
