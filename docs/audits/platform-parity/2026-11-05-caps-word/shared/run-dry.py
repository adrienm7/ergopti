"""Run two bounded final sweeps of retained shared CapsWord probes."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(sys.argv[1]).resolve()
output = Path(__file__).resolve().parent
names = [
    ("policy-lua54", "lua", "policy-probe.lua"),
    ("policy-luajit", "luajit", "policy-probe.lua"),
    ("magic-lua54", "lua", "magic-key-policy.lua"),
    ("magic-luajit", "luajit", "magic-key-policy.lua"),
    ("declarations", "node", "declaration-probe.cjs"),
    ("pinned-source", "python3", "source-contract.py"),
]
receipts = []
for sweep in ["A", "B"]:
    rows = []
    for name, executable, relative in names:
        program = output / relative
        command = [executable, str(program), str(root)]
        result = subprocess.run(command, cwd=root, capture_output=True, text=True)
        stdout = output / f"dry-{sweep}-{name}.txt"
        stderr = output / f"dry-{sweep}-{name}.stderr.txt"
        stdout.write_text(result.stdout)
        stderr.write_text(result.stderr)
        rows.append(
            {
                "name": name,
                "program": relative,
                "program_sha256": hashlib.sha256(program.read_bytes()).hexdigest(),
                "command": command,
                "exit_code": result.returncode,
                "stdout": stdout.name,
                "stdout_sha256": hashlib.sha256(stdout.read_bytes()).hexdigest(),
                "stderr": stderr.name,
                "stderr_sha256": hashlib.sha256(stderr.read_bytes()).hexdigest(),
            }
        )
        print(sweep, name, result.returncode)
    receipts.append(
        {
            "sweep": sweep,
            "new_confirmed_roots": 0,
            "processes": rows,
            "scope": "Shared policy/corpus, declared rows/requirements/site/menu/locales, source-only AHK relationships; native event and timer admission remains driver-owned.",
        }
    )
(output / "dry-receipts.json").write_text(
    json.dumps(
        {
            "audited_sha": "f2a7dba5fc580aad61e6a0ed16ede84406aed2b0",
            "qualification": "Two repetitions of the same bounded final scope after CW-S002; not additional distinct coverage or exhaustive native certification.",
            "sweeps": receipts,
        },
        indent=2,
    )
    + "\n"
)
assert all(row["exit_code"] == 0 for sweep in receipts for row in sweep["processes"])
