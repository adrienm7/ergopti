"""Two final dry, bounded source/data passes; retain exact outputs and identities."""

import hashlib
import json
import os
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).parent
ROOT = Path("/workspace/worktrees/parity-dead-keys-2026-11-05/windows")
ENV = dict(
    os.environ,
    PATH="/workspace/scratch/parity-toolchain/ci-bin:" + os.environ["PATH"],
    LOGNAME="agent",
    PYTHONDONTWRITEBYTECODE="1",
)
commands = [
    ("source-output.json", ["python", str(HERE / "source-contract.py"), str(ROOT)]),
    ("data-output.json", ["lua", str(HERE / "data-probe.lua"), str(ROOT)]),
    ("data-output.json", ["luajit", str(HERE / "data-probe.lua"), str(ROOT)]),
    ("false-green.txt", ["node", "tools/test/find-false-greens.cjs"]),
    ("source-clean.txt", ["git", "status", "--porcelain=v1"]),
]
passes = []
for index in range(2):
    runs = []
    with tempfile.TemporaryDirectory(prefix="dkw-sweep-") as temporary:
        env = dict(ENV, TMPDIR=temporary)
        for name, command in commands:
            result = subprocess.run(
                command, cwd=ROOT, env=env, capture_output=True, timeout=60, check=False
            )
            assert result.returncode == 0, (command, result.stderr)
            assert not result.stderr, (command, result.stderr)
            path = HERE / name
            if path.exists():
                assert path.read_bytes() == result.stdout, (name, "output drift")
            else:
                path.write_bytes(result.stdout)
            runs.append(
                {
                    "command": command,
                    "cwd": str(ROOT),
                    "exit_code": result.returncode,
                    "stderr": "",
                    "stdout_path": name,
                    "stdout_sha256": hashlib.sha256(result.stdout).hexdigest(),
                }
            )
    passes.append(
        {
            "pass": index + 1,
            "finished_utc": datetime.now(timezone.utc).isoformat(),
            "new_root_causes": 0,
            "runs": runs,
        }
    )
versions = {}
for name in ["lua", "luajit", "node", "python"]:
    command = [name, "-v" if name in ("lua", "luajit", "node") else "--version"]
    result = subprocess.run(command, env=ENV, capture_output=True, check=True)
    versions[name] = (result.stdout + result.stderr).decode().strip()
record = {
    "audited_sha": "f2c3ea43542c985fb20e5f0887976f1c02525341",
    "scope": "Two final bounded source/data sweeps after DKW-001; no Windows/native/AHK behavior execution.",
    "environment": {
        "PATH_prefix": "/workspace/scratch/parity-toolchain/ci-bin",
        "LOGNAME": "agent",
        "PYTHONDONTWRITEBYTECODE": "1",
        "TMPDIR": "fresh private temporary directory per pass",
    },
    "versions": versions,
    "passes": passes,
}
(HERE / "sweeps.json").write_text(json.dumps(record, indent=2) + "\n")
print(
    json.dumps(
        {
            "passes": len(passes),
            "commands_per_pass": len(commands),
            "new_root_causes": 0,
            "all_exit_codes": 0,
        }
    )
)
