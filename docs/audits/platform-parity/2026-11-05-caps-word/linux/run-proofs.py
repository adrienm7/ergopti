"""Replay actual CapsWord owners and isolated registered modules twice."""

import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("repository", type=Path)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
program = Path(__file__).resolve().parent
modules = [
    "tests.unit.modules.shortcuts.caps_word.test_caps_word_auto_off",
    "tests.unit.modules.shortcuts.caps_word.test_caps_word_auto_off_policy",
    "tests.unit.adapters.keyboard_hook.test_keyboard_hook_caps_word_lock",
    "tests.unit.adapters.keyboard_hook.test_keyboard_hook_caps_lock_state",
    "tests.unit.adapters.keyboard_hook.test_keyboard_hook_caps_lock_seed",
    "tests.unit.modules.hotstrings.injector.test_injector_caps_lock",
    "tests.unit.modules.hotstrings.injector.test_injector_output_observer",
    "tests.unit.ui.menu.shortcuts.test_caps_word_auto_off_menu",
]
env = os.environ.copy()
env.update(LOGNAME="agent", PYTHONDONTWRITEBYTECODE="1")
receipts = []
for sweep in ["A", "B"]:
    plans = []
    for runtime in ["lua", "luajit"]:
        plans.append(
            (
                f"{sweep}-{runtime}-owner",
                [runtime, str(program / "owner-probe.lua"), str(args.repository)],
            )
        )
        for module in modules:
            plans.append(
                (
                    f"{sweep}-{runtime}-{module.rsplit('.', 1)[1]}",
                    [runtime, str(program / "run-registered.lua"), str(args.repository), module],
                )
            )

    def run(plan):
        name, command = plan
        with tempfile.TemporaryDirectory(prefix="ergopti-capsword-audit-") as tmp:
            process_env = dict(env, TMPDIR=tmp)
            result = subprocess.run(
                command,
                cwd=args.repository / "static/ergopti_plus/linux",
                env=process_env,
                capture_output=True,
                text=True,
                timeout=300,
            )
        stdout = args.output / (name + ".stdout.txt")
        stderr = args.output / (name + ".stderr.txt")
        stdout.write_text(result.stdout)
        stderr.write_text(result.stderr)
        row = {
            "name": name,
            "command": command,
            "exit_code": result.returncode,
            "stdout": stdout.name,
            "stderr": stderr.name,
            "stdout_sha256": hashlib.sha256(stdout.read_bytes()).hexdigest(),
            "stderr_sha256": hashlib.sha256(stderr.read_bytes()).hexdigest(),
        }
        prefix = "CAPS_WORD_OBSERVATIONS=" if name.endswith("-owner") else "AUDIT_RESULTS="
        data = [
            line[len(prefix) :] for line in result.stdout.splitlines() if line.startswith(prefix)
        ]
        if result.returncode == 0:
            assert len(data) == 1, name
            observed = json.loads(data[0])
            row["observations"] = len(observed["cases"]) if name.endswith("-owner") else observed
        return row

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        current = list(pool.map(run, plans))
    receipts.extend(current)
    print(
        sweep,
        "processes",
        len(current),
        "nonzero",
        sum(r["exit_code"] != 0 for r in current),
        flush=True,
    )
    if any(r["exit_code"] for r in current):
        break
(args.output / "receipts.json").write_text(
    json.dumps(
        {
            "audited_sha": subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=args.repository, text=True
            ).strip(),
            "program_sha256": hashlib.sha256(
                (program / "owner-probe.lua").read_bytes()
            ).hexdigest(),
            "runner_sha256": hashlib.sha256(
                (program / "run-registered.lua").read_bytes()
            ).hexdigest(),
            "qualification": "Actual Lua owners over controlled native ports; no native compositor or receiving application. Registered cases are existing test coverage, not new independently observed defects.",
            "processes": receipts,
        },
        indent=2,
    )
    + "\n"
)
raise SystemExit(any(r["exit_code"] for r in receipts))
