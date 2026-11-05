"""Run bounded audit receipts without modifying repository source or tests."""

from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

repo = Path(sys.argv[1]).resolve()
base = Path(__file__).resolve().parent
label = sys.argv[2]
assert label in ("A", "B")
out = base / ("dry-" + label)
out.mkdir(exist_ok=True)
receipt = {
    "label": label,
    "started_at": datetime.now(timezone.utc).isoformat(),
    "commands": [],
    "axes": [
        "Public arrow/shortcut/click and next-edit independent AI option crossproduct",
        "Actual prediction request serialization over fake HTTP and directcaller qualification",
        "Bare/main/keypad Enter identity and conditional empty-promptBackspace owner",
        "Idle, deletion modifiers, selectedfield, browserlocation and multiline controls",
        "Escape visibility/quarantine/deferral, native eventprovenance and lifecycle",
        "Defaults, sparsepreferences, menus and explicit crossOSintent",
        "Privatebaseline, sharedcontextvectors, knownrootdedup and hypothesisrefutations",
    ],
    "new_roots": 0,
    "root_discovery_basis": "Manual bounded source review; zero is not inferred mechanically from green probes",
}
for name in ("public-context.lua", "context-request.lua", "public-edits.lua", "keypad-enter.lua"):
    command = ["lua", str(base / name), str(repo)]
    result = subprocess.run(
        command, cwd=repo, env=os.environ.copy(), capture_output=True, text=True
    )
    log = out / (name + ".log")
    log.write_text(result.stdout + result.stderr)
    receipt["commands"].append(
        {
            "command": command,
            "exit_code": result.returncode,
            "log": str(log.relative_to(base)),
            "sha256": hashlib.sha256(log.read_bytes()).hexdigest(),
        }
    )
    assert result.returncode == 0, log
command = ["python3", str(base / "run-isolated.py"), str(repo), str(out / "registered")]
result = subprocess.run(command, cwd=repo, env=os.environ.copy(), capture_output=True, text=True)
(out / "registered-summary.json").write_text(result.stdout + result.stderr)
receipt["commands"].append(
    {
        "command": command,
        "exit_code": result.returncode,
        "log": str((out / "registered-summary.json").relative_to(base)),
    }
)
assert result.returncode == 0
receipt["completed_at"] = datetime.now(timezone.utc).isoformat()
(out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(
    json.dumps(
        {
            "sweep": label,
            "exit_codes": [row["exit_code"] for row in receipt["commands"]],
            "new_roots": 0,
            "root_discovery_basis": "Manual bounded source review; zero is not inferred mechanically from green probes",
        }
    )
)
