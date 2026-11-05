#!/usr/bin/env python3
"""Replay the bounded control set; source hash inventory is provenance, never runtime proof."""

import argparse, datetime, hashlib, json, pathlib, subprocess

p = argparse.ArgumentParser()
p.add_argument("source_root")
p.add_argument("artifact_root")
p.add_argument("pass_name")
a = p.parse_args()
r = pathlib.Path(a.source_root).resolve()
o = pathlib.Path(a.artifact_root).resolve()
lua = "/workspace/scratch/parity-toolchain/ci-bin/lua"
commands = [
    ["git", "rev-parse", "HEAD"],
    [lua, str(o / "probes/runtime-probes.lua"), str(r)],
    [lua, str(o / "probes/approval-wall-clock.lua"), str(r)],
    ["python3", str(o / "probes/source-joins.py"), str(r)],
    [lua, str(o / "probes/run-group.lua"), str(r), str(o)],
    ["git", "status", "--porcelain"],
]
ledger = {
    "pass": a.pass_name,
    "start_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "source_root": str(r),
    "new_confirmed_roots": 0,
    "commands": [],
}
for i, c in enumerate(commands):
    completed = subprocess.run(
        c, cwd=r / "static/ergopti_plus/macos" if c[0] == lua else r, capture_output=True, text=True
    )
    log = o / "logs" / f"{a.pass_name}-{i}.log"
    log.write_text(completed.stdout + completed.stderr)
    ledger["commands"].append(
        {"argv": c, "exit_code": completed.returncode, "log": str(log.relative_to(o))}
    )
    assert completed.returncode == 0, (c, log)
ledger["end_utc"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
(o / "logs" / f"{a.pass_name}-ledger.json").write_text(json.dumps(ledger, indent=2) + "\n")
print(json.dumps(ledger, indent=2))
