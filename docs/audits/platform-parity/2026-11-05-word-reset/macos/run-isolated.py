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
    "tests.unit.modules.keymap.terminators.test_arrow_shortcut_word_reset",
    "tests.unit.modules.keymap.terminators.test_word_reset_policy",
    "tests.unit.infra.preferences.test_preferences_word_reset",
    "tests.unit.modules.keymap.terminators.test_nav_invalidates_hotstring_buffer",
    "tests.unit.modules.keymap.terminators.test_escape_invalidates_hotstring_buffer",
    "tests.unit.modules.keymap.terminators.test_escape_context_fixture_scope",
    "tests.unit.modules.llm.vectors.test_context_buffer_vectors",
    "tests.unit.modules.keymap.eventtap.test_tap_outage_invalidates_context",
    "tests.unit.modules.keymap.synthetic.test_action_epoch_reconciliation",
    "tests.unit.modules.keymap.llm_bridge.test_private_expansion_never_prompted",
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
