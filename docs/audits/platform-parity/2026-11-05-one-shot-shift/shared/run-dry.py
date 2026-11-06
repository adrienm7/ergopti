"""Run two final bounded shared-policy sweeps with private process temporary roots."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
out = Path(__file__).resolve().parent
plans = [
    ("policy-lua54", "lua", out / "policy-probe.lua", [str(root)]),
    ("policy-luajit", "luajit", out / "policy-probe.lua", [str(root)]),
    ("catalogue-guard", "node", out / "catalogue-guard.cjs", [str(root)]),
    ("declarations", "node", out / "declaration-probe.cjs", [str(root)]),
    ("pinned-source", "python3", out / "source-contract.py", [str(root)]),
    (
        "single-source",
        "node",
        root / "tools/test/test-tap-hold-one-shot-results-single-source.cjs",
        [],
    ),
]
sweeps = []
for label in ["A", "B"]:
    processes = []
    for name, executable, program, arguments in plans:
        with tempfile.TemporaryDirectory(prefix="ergopti-one-shot-shared-") as private:
            env = dict(os.environ, TMPDIR=private, LOGNAME="agent", PYTHONDONTWRITEBYTECODE="1")
            command = [executable, str(program), *arguments]
            result = subprocess.run(
                command, cwd=root, env=env, capture_output=True, check=False, timeout=180
            )
        stdout = f"dry-{label}-{name}.stdout.txt"
        stderr = f"dry-{label}-{name}.stderr.txt"
        (out / stdout).write_bytes(result.stdout)
        (out / stderr).write_bytes(result.stderr)
        processes.append(
            {
                "name": name,
                "command": command,
                "program_sha256": hashlib.sha256(program.read_bytes()).hexdigest(),
                "exit_code": result.returncode,
                "stdout": stdout,
                "stdout_sha256": hashlib.sha256(result.stdout).hexdigest(),
                "stderr": stderr,
                "stderr_sha256": hashlib.sha256(result.stderr).hexdigest(),
            }
        )
        print(label, name, result.returncode, flush=True)
    sweeps.append(
        {
            "sweep": label,
            "new_independent_roots": 0,
            "processes": processes,
            "qualification": "Actual shared policy and state owner, model/projection and negative metadata controls; source checks are not AHK execution. No native receiving or exhaustive transitive scope.",
        }
    )
(out / "dry-receipts.json").write_text(
    json.dumps(
        {"audited_sha": "9c565c88c9a1366a2e9b18c1b9d2868509510975", "sweeps": sweeps}, indent="\t"
    )
    + "\n"
)
if any(row["exit_code"] for sweep in sweeps for row in sweep["processes"]):
    raise SystemExit(1)
