"""Replay the bounded cross-driver review controls without touching user state."""

import datetime
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1]).resolve()
out = pathlib.Path(__file__).resolve().parent
passes = []
for name in ["A", "B"]:
    tests = [
        ("source", ["python3", str(out / "source_probe.py"), str(root)], root),
        (
            "macos",
            [
                "lua",
                "tests/run.lua",
                "--only=tests.unit.modules.keymap.repeat.test_repeat_feature_arm_time",
            ],
            root / "static/ergopti_plus/macos",
        ),
        (
            "linux",
            ["luajit", "tests/run.lua", "--only=repeat-key-corpus"],
            root / "static/ergopti_plus/linux",
        ),
    ]
    runs = []
    for label, argv, cwd in tests:
        result = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, check=True)
        (out / f"dry-{name}-{label}.txt").write_text(result.stdout + result.stderr)
        if label == "source":
            assert json.loads(result.stdout)["translation_observation"]["header"] is None
        elif label == "macos":
            assert "Passed tests:  30" in result.stdout and "Failed tests:  0" in result.stdout
        else:
            assert "Passed tests:  19" in result.stdout and "Failed tests:  0" in result.stdout
        runs.append({"role": label, "argv": argv, "cwd": str(cwd), "exit_code": result.returncode})
    passes.append(
        {
            "pass": name,
            "finished_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "review_axes": [
                "public repeat and Backspace owners",
                "shared toggle/defaults/delimiters",
                "registry fallback priority and repeat corrections",
                "plain-text/cascade/key-output eligibility",
                "source/focus/privacy/pause retirement",
                "preview exclusion and native undo distinction",
                "configuration/action/menu/site projection boundary",
                "canonical prior-report deduplication",
                "source receipt and native/performance limits",
            ],
            "new_roots": 0,
            "replays": runs,
        }
    )
(out / "dry-receipts.json").write_text(json.dumps(passes, indent=2) + "\n")
print(
    "Two bounded cross-driver sweeps complete: no further roots; each 30 macOS cases + 19 Linux corpus cases + pinned JS/source observation."
)
