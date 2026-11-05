"""Two fresh-process bounded dry sweeps; no production edits."""

import hashlib
import json
import os
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = Path("/workspace/worktrees/parity-dead-keys-2026-11-05/linux")
ENV = dict(
    os.environ,
    PATH="/workspace/scratch/parity-toolchain/ci-bin:" + os.environ["PATH"],
    LOGNAME="agent",
    PYTHONDONTWRITEBYTECODE="1",
    XCOMPOSEFILE=str(HERE / "generated/ergopti_plus.XCompose"),
)
COMMANDS = [
    ("public", ["luajit", str(HERE / "public-compose.lua"), str(ROOT)]),
    ("native", ["luajit", str(HERE / "native-controls.lua"), str(ROOT)]),
    ("lua", ["lua", str(HERE / "selected-tests.lua"), str(ROOT)]),
    ("luajit", ["luajit", str(HERE / "selected-tests.lua"), str(ROOT)]),
]
receipts = []
for sweep in (1, 2):
    runs = []
    for name, command in COMMANDS:
        result = subprocess.run(
            command,
            cwd=ROOT / "static/ergopti_plus/linux",
            env=ENV,
            capture_output=True,
            timeout=30,
        )
        row = {"name": name, "argv": command, "exit": result.returncode, "outputs": {}}
        for kind, data in [("stdout", result.stdout), ("stderr", result.stderr)]:
            path = HERE / f"sweep-{sweep}-{name}.{kind}"
            path.write_bytes(data)
            row["outputs"][kind] = {"path": path.name, "sha256": hashlib.sha256(data).hexdigest()}
        assert result.returncode == 0, row
        runs.append(row)
    receipts.append(
        {
            "sweep": sweep,
            "scope": "same four bounded fresh-process commands; 7 public/10 native/122 registered cases per runtime",
            "runs": runs,
        }
    )
(HERE / "sweeps.json").write_text(
    json.dumps(
        {
            "audited_sha": "f2c3ea43542c985fb20e5f0887976f1c02525341",
            "cwd": str(ROOT / "static/ergopti_plus/linux"),
            "environment": {
                k: ENV[k] for k in ("PATH", "LOGNAME", "XCOMPOSEFILE", "PYTHONDONTWRITEBYTECODE")
            },
            "sweeps": receipts,
        },
        indent=2,
    )
    + "\n"
)
