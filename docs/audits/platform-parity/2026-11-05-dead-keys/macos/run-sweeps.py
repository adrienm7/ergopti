"""Two safe bounded final passes over in-memory fixture and canonical unit suites."""

import hashlib
import json
import os
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).parent
ROOT = Path("/workspace/worktrees/parity-dead-keys-2026-11-05/macos")
DRIVER = ROOT / "static/ergopti_plus/macos"
ENV = dict(
    os.environ,
    PATH="/workspace/scratch/parity-toolchain/ci-bin:" + os.environ["PATH"],
    LOGNAME="agent",
    PYTHONDONTWRITEBYTECODE="1",
)
PROBE = HERE / "public-probe.lua"
PROBE_SHA = "083421e74856cdef69a2ceb5795551313a747bf06ffe5e3b9869617c7de490b8"
assert hashlib.sha256(PROBE.read_bytes()).hexdigest() == PROBE_SHA
commands = [
    ("root-observed.json", ["lua", str(PROBE), str(ROOT)], ROOT, False),
    (
        "no-marker-observed.json",
        ["lua", str(HERE / "no-marker-control.lua"), str(ROOT), str(PROBE)],
        ROOT,
        False,
    ),
    (
        "ordinary-baseline-observed.json",
        ["lua", str(HERE / "ordinary-baseline-control.lua"), str(ROOT), str(PROBE)],
        ROOT,
        False,
    ),
    (
        "semantic-output.json",
        [
            "python",
            str(HERE / "check-record.py"),
            str(ROOT),
            str(HERE / "root-observed.json"),
            str(HERE / "no-marker-observed.json"),
            str(HERE / "ordinary-baseline-observed.json"),
        ],
        ROOT,
        False,
    ),
    (
        "source-output.json",
        ["python", str(HERE / "source-check.py"), str(ROOT)],
        ROOT,
        False,
    ),
]
for name, module in [
    ("nav", "terminators.test_nav_invalidates_hotstring_buffer"),
    ("registry", "registry.test_registry"),
    ("expander", "expansion.test_expander"),
    ("delete-count", "expansion.test_expander_delete_count_sanity"),
]:
    commands.append(
        (
            name + ".txt",
            ["lua", "tests/run.lua", "--only=tests.unit.modules.keymap." + module],
            DRIVER,
            True,
        )
    )
commands.append(("source-clean.txt", ["git", "status", "--porcelain=v1"], ROOT, False))
passes = []
for index in range(2):
    runs = []
    with tempfile.TemporaryDirectory(prefix="dkm-dry-sweep-") as temporary:
        env = dict(ENV, TMPDIR=temporary)
        for name, command, cwd, variable in commands:
            result = subprocess.run(
                command, cwd=cwd, env=env, capture_output=True, check=False, timeout=60
            )
            assert result.returncode == 0, (command, result.returncode, result.stderr)
            assert not result.stderr, (command, result.stderr)
            if variable:
                assert b"[OK] All Lua unit tests passed." in result.stdout
                assert b"Failed tests:  0" in result.stdout
                path = HERE / ("pass" + str(index + 1) + "-" + name)
            else:
                path = HERE / name
            if path.exists():
                assert path.read_bytes() == result.stdout, (
                    name,
                    "unexpected output drift",
                )
            else:
                path.write_bytes(result.stdout)
            runs.append(
                {
                    "command": command,
                    "cwd": str(cwd),
                    "exit_code": result.returncode,
                    "stderr": "",
                    "stdout_path": path.name,
                    "stdout_sha256": hashlib.sha256(result.stdout).hexdigest(),
                }
            )
    assert hashlib.sha256(PROBE.read_bytes()).hexdigest() == PROBE_SHA
    passes.append(
        {
            "pass": index + 1,
            "finished_utc": datetime.now(timezone.utc).isoformat(),
            "new_root_causes": 0,
            "runs": runs,
        }
    )
versions = {}
for command in [["lua", "-v"], ["python", "--version"]]:
    result = subprocess.run(command, env=ENV, capture_output=True, check=True)
    versions[command[0]] = (result.stdout + result.stderr).decode().strip()
record = {
    "audited_sha": "f2c3ea43542c985fb20e5f0887976f1c02525341",
    "qualification": "Safe registered unit fixtures and original Lua production owners; no device/native input, dead-key state or application reception measured.",
    "environment": {
        "PATH_prefix": "/workspace/scratch/parity-toolchain/ci-bin",
        "LOGNAME": "agent",
        "PYTHONDONTWRITEBYTECODE": "1",
        "TMPDIR": "fresh private directory per pass; canonical runner isolates its own HOME",
    },
    "original_probe_unchanged_sha256": PROBE_SHA,
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
