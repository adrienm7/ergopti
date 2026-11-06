#!/usr/bin/env python3
"""Portable, isolated replay of actual owners; no desktop/native delivery claim."""

import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
here = Path(__file__).resolve().parent
label = sys.argv[2]
out = here / label
out.mkdir(exist_ok=True)
modules = [
    "tests.unit.platform.remap.tap_hold.test_tap_hold_engine_modifier_key",
    "tests.unit.platform.remap.tap_hold.test_tap_hold_engine_under_modifier_layer",
    "tests.unit.platform.remap.tap_hold.test_tap_hold_integration",
    "tests.unit.adapters.keyboard_hook.test_keyboard_hook_tap_hold",
    "tests.unit.modules.shortcuts.key_combinations.test_key_combinations",
    "tests.unit.platform.remap.tap_hold.test_tap_hold_roll",
    "tests.meta.corpus.test_corpus_tap_hold_decisions",
]
jobs = [("source-contract", ["python3", str(here / "source-contract.py"), str(root)])]
for runtime in ["lua", "luajit"]:
    for probe in ["public-probe.lua", "channel-probe.lua"]:
        jobs.append((runtime + "-" + probe, [runtime, str(here / probe), str(root)]))
    for module in modules:
        jobs.append(
            (
                runtime + "-" + module,
                [runtime, str(here / "run-registered.lua"), str(root), module],
            )
        )


def run(job):
    name, command = job
    env = dict(os.environ, LOGNAME="agent", PYTHONDONTWRITEBYTECODE="1")
    env["PATH"] = "/workspace/scratch/parity-toolchain/ci-bin:" + env["PATH"]
    with tempfile.TemporaryDirectory(prefix="private-", dir=out) as temporary:
        env["TMPDIR"] = temporary
        completed = subprocess.run(
            command,
            cwd=root,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=90,
            check=False,
        )
    log = out / (name + ".txt")
    log.write_bytes(completed.stdout)
    return {
        "name": name,
        "command": command,
        "exit": completed.returncode,
        "log": str(log.relative_to(here)),
        "sha256": hashlib.sha256(completed.stdout).hexdigest(),
    }


with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    results = list(pool.map(run, jobs))
(out / "results.json").write_text(json.dumps(results, indent=2) + "\n")
print(
    json.dumps(
        {
            "label": label,
            "processes": len(results),
            "failed": [item["name"] for item in results if item["exit"] != 0],
        }
    )
)
sys.exit(any(item["exit"] != 0 for item in results))
