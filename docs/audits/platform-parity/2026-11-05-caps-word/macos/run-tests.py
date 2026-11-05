"""Independently execute exact registered CapsWord modules and retain receipts."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

repository = Path(sys.argv[1]).resolve()
output = Path(__file__).resolve().parent
program = output / "run-module.lua"
modules = [
    "unit/platform/remap/watchers/test_watchers_capsword",
    "unit/platform/remap/watchers/test_watchers_capsword_auto_off",
    "unit/platform/remap/watchers/test_watchers_capsword_release_race",
    "unit/platform/remap/watchers/test_capsword_control_signal",
    "unit/platform/remap/watchers/test_caps_word_auto_off_policy",
    "unit/platform/remap/watchers/test_watchers_teardown_retry",
    "unit/platform/remap/generator/test_generator_capsword_setting_exits",
    "unit/infra/config/test_capsword_auto_off_settings",
    "unit/ui/menu/shortcuts/test_menu_caps_word",
    "unit/adapters/synthetic_input/test_text_sender_capsword_output",
    "unit/modules/gestures/actions/test_karabiner_actions_reachable",
    "unit/platform/remap/ke_lifecycle/test_ke_variables_serialized_batches",
    "meta/architecture/test_capsword_auto_off_single_source",
    "meta/architecture/test_karabiner_capsword_lock_release",
]
rows = []
for module in modules:
    command = ["lua", str(program), str(repository), "tests/" + module]
    result = subprocess.run(
        command, cwd=repository, capture_output=True, text=True, env=os.environ, check=False
    )
    log = output / "tests" / (module.replace("/", "_") + ".txt")
    log.parent.mkdir(exist_ok=True)
    log.write_text(result.stdout + result.stderr)
    counts = re.search(r"AUDIT_RESULT\s+(\d+)\s+(\d+)", result.stdout)
    rows.append(
        {
            "module": module,
            "exit_code": result.returncode,
            "passed": int(counts[1]) if counts else None,
            "failed": int(counts[2]) if counts else None,
            "log": str(log.relative_to(output)),
            "source_sha256": hashlib.sha256(
                (repository / "static/ergopti_plus/macos/tests" / (module + ".lua")).read_bytes()
            ).hexdigest(),
        }
    )
    print(module, result.returncode, rows[-1]["passed"], flush=True)
(output / "test-results.json").write_text(
    json.dumps(
        {
            "audited_sha": "f2a7dba5fc580aad61e6a0ed16ede84406aed2b0",
            "program_sha256": hashlib.sha256(program.read_bytes()).hexdigest(),
            "qualification": "Independent registered module execution over recorded native ports; meta modules are lexical controls; no macOS physical receiving.",
            "runs": rows,
        },
        indent=2,
    )
    + "\n"
)
raise SystemExit(any(row["exit_code"] for row in rows))
