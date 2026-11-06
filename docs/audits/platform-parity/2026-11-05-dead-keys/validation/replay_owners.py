"""Replay original owners independently; keep results outside frozen archives."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

# Set this before importing a local helper so replay creates no archive cache.
sys.dont_write_bytecode = True

from materialize import materialize  # noqa: E402

root = Path(sys.argv[1]).resolve()
archive = Path(sys.argv[2]).resolve()
out = Path(sys.argv[3]).resolve()
out.mkdir(parents=True, exist_ok=False)
# Source witnesses publish sibling receipts; every program runs on an exact
# private reconstruction, preserving the immutable archive and its encodings.
archive = materialize(archive, out / "workers")
private_source = archive / "windows/source-contract.py"
private_generated = archive / "linux/generated"
env = dict(os.environ, LOGNAME="agent", PYTHONDONTWRITEBYTECODE="1")
commands = [
    ("windows-source", ["python3", str(private_source), str(root)], root),
    ("windows-data-lua", ["lua", str(archive / "windows/data-probe.lua"), str(root)], root),
    ("windows-data-luajit", ["luajit", str(archive / "windows/data-probe.lua"), str(root)], root),
    ("macos-seeded", ["lua", str(archive / "macos/public-probe.lua"), str(root)], root),
    (
        "macos-unseeded",
        [
            "lua",
            str(archive / "macos/no-marker-control.lua"),
            str(root),
            str(archive / "macos/public-probe.lua"),
        ],
        root,
    ),
    (
        "macos-ordinary",
        [
            "lua",
            str(archive / "macos/ordinary-baseline-control.lua"),
            str(root),
            str(archive / "macos/public-probe.lua"),
        ],
        root,
    ),
    (
        "macos-check",
        [
            "python3",
            str(archive / "macos/check-record.py"),
            str(root),
            str(out / "macos-seeded.stdout.txt"),
            str(out / "macos-unseeded.stdout.txt"),
            str(out / "macos-ordinary.stdout.txt"),
        ],
        root,
    ),
    (
        "linux-public",
        ["luajit", str(archive / "linux/public-compose.lua"), str(root), str(private_generated)],
        root / "static/ergopti_plus/linux",
    ),
    (
        "linux-native",
        ["luajit", str(archive / "linux/native-controls.lua"), str(root), str(private_generated)],
        root / "static/ergopti_plus/linux",
    ),
    (
        "linux-tests-lua",
        ["lua", str(archive / "linux/selected-tests.lua"), str(root)],
        root / "static/ergopti_plus/linux",
    ),
    (
        "linux-tests-luajit",
        ["luajit", str(archive / "linux/selected-tests.lua"), str(root)],
        root / "static/ergopti_plus/linux",
    ),
]
results = []
for name, argv, cwd in commands:
    current = dict(env)
    if name.startswith("linux"):
        current["XCOMPOSEFILE"] = str(private_generated / "ergopti_plus.XCompose")
    done = subprocess.run(argv, cwd=cwd, env=current, capture_output=True, timeout=90)
    row = {"name": name, "argv": argv, "cwd": str(cwd), "exit": done.returncode, "outputs": {}}
    for kind, data in [("stdout", done.stdout), ("stderr", done.stderr)]:
        path = out / (name + "." + kind + ".txt")
        path.write_bytes(data)
        row["outputs"][kind] = {"path": path.name, "sha256": hashlib.sha256(data).hexdigest()}
    results.append(row)
    if done.returncode:
        raise RuntimeError(row)
(out / "receipt.json").write_text(
    json.dumps(
        {
            "head": subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=root, text=True
            ).strip(),
            "qualification": "Windows source/data only; macOS original Lua in-memory fixture; Linux original owners and native XKB component over controlled transport. No device or application receiving.",
            "runs": results,
        },
        indent=2,
    )
    + "\n"
)
print(json.dumps({"runs": len(results), "all_exit": 0, "output": str(out)}))
