"""Replay exact registered scope modules in fresh Lua processes, retaining receipts."""

import json
import os
import re
from pathlib import Path
import subprocess
import sys

repo = Path(sys.argv[1]).resolve()
out = Path(sys.argv[2]).resolve()
out.mkdir(parents=True, exist_ok=True)
modules = [
    "tests.unit.modules.keymap.repeat.test_repeat_feature_arm_time",
    "tests.unit.modules.keymap.repeat.test_repeat_replacement_transaction",
    "tests.unit.modules.keymap.repeat.test_repeat_neutral_config",
    "tests.unit.modules.keymap.repeat.test_star_validation_beats_repeat_key",
    "tests.unit.modules.keymap.preview.test_no_repeat_preview",
    "tests.unit.modules.keymap.llm_bridge.test_private_expansion_never_prompted",
    "tests.unit.modules.keymap.expansion.test_hotstring_chaining",
    "tests.unit.modules.keymap.registry.test_registry_bound_sections",
]
receipts = []
for module in modules:
    command = ["lua", "tests/run.lua", "--only=" + module]
    completed = subprocess.run(
        command,
        cwd=repo / "static/ergopti_plus/macos",
        env=os.environ.copy(),
        capture_output=True,
        text=True,
    )
    name = module.rsplit(".", 1)[-1] + ".log"
    (out / name).write_text(completed.stdout + completed.stderr)
    passed = re.findall(r"Passed tests:\s+(\d+)", completed.stdout)
    failed = re.findall(r"Failed tests:\s+(\d+)", completed.stdout)
    results = list(zip(passed, failed))
    receipts.append(
        {
            "module": module,
            "command": command,
            "exit_code": completed.returncode,
            "passed": int(results[-1][0]) if results else None,
            "failed": int(results[-1][1]) if results else None,
            "log": name,
        }
    )
(out / "receipts.json").write_text(json.dumps(receipts, indent=2) + "\n")
print(json.dumps(receipts))
sys.exit(
    any(item["exit_code"] != 0 or not item["passed"] or item["failed"] != 0 for item in receipts)
)
