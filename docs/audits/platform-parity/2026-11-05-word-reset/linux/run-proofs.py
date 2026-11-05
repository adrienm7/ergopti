"""Run bounded audit programs and existing modules; never touch production files."""

import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("root")
parser.add_argument("--pass-name", default="initial")
args = parser.parse_args()
here = Path(__file__).resolve().parent
env = os.environ.copy()
env["PATH"] = "/workspace/scratch/parity-toolchain/ci-bin:" + env["PATH"]
env["LOGNAME"] = "agent"
modules = [
    "modules.hotstrings.engine.test_word_reset",
    "modules.hotstrings.engine.test_word_reset_events",
    "modules.llm.context.test_ai_typing_context",
    "modules.llm.context.test_context_buffer_vectors",
    "modules.llm.prediction.test_prediction_control_retirement",
    "modules.llm.settings.test_llm_settings",
    "modules.shortcuts.keyboard.test_keyboard_shortcuts_late_contextual_delivery",
    "platform.remap.tap_hold.test_tap_hold_manager_lifecycle",
    "modules.gestures.engine.test_combo_press_order",
    "modules.gestures.engine.test_combo_emitter",
    "infra.scope.test_hotstrings_scope",
]
rows = []
for runtime in ["luajit", "lua"]:
    command = [runtime, str(here / "continuity-probe.lua"), args.root]
    output = here / f"{args.pass_name}-{runtime}-owner.txt"
    run = subprocess.run(
        command,
        cwd=str(Path(args.root) / "static/ergopti_plus/linux"),
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=120,
    )
    output.write_text(run.stdout)
    assert run.returncode == 0, run.stderr
    payload = json.loads(run.stdout)
    assert len(payload["cases"]) == 43
    rows.append(
        {
            "command": command,
            "exit_code": run.returncode,
            "owner_cases": len(payload["cases"]),
            "output": output.name,
            "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
        }
    )
for module in modules:
    command = ["luajit", str(here / "run-registered.lua"), args.root, "tests.unit." + module]
    output = here / f"{args.pass_name}-{module.rsplit('.', 1)[1]}.txt"
    run = subprocess.run(
        command,
        cwd=str(Path(args.root) / "static/ergopti_plus/linux"),
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=180,
    )
    output.write_text(run.stdout)
    summaries = [
        line.removeprefix("AUDIT_RESULTS=")
        for line in run.stdout.splitlines()
        if line.startswith("AUDIT_RESULTS=")
    ]
    assert len(summaries) == 1, output
    counts = json.loads(summaries[0])
    rows.append(
        {
            "command": command,
            "exit_code": run.returncode,
            "passed": counts["passed"],
            "failed": counts["failed"],
            "output": output.name,
            "sha256": hashlib.sha256(output.read_bytes()).hexdigest(),
        }
    )
    assert run.returncode == 0 and counts["failed"] == 0, output
receipt = {
    "pass": args.pass_name,
    "audited_sha": "b17e47ed3bb92c106703d3e3482b3c2973f5bc1e",
    "rows": rows,
    "registered_case_count": sum(row.get("passed", 0) for row in rows),
}
(here / f"{args.pass_name}-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(
    json.dumps(
        {
            "pass": args.pass_name,
            "owner_cases_per_runtime": 43,
            "registered_modules": len(modules),
            "registered_case_count": receipt["registered_case_count"],
            "failed": 0,
        }
    )
)
