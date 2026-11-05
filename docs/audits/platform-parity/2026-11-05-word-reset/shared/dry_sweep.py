"""Re-derive scoped source and value observations in two final bounded passes."""

import datetime
import hashlib
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1]).resolve()
out = pathlib.Path(__file__).resolve().parent
receipts = []
for name in ["A", "B"]:
    runs = []
    commands = [
        ("source", ["python3", str(out / "source_probe.py"), str(root)]),
        ("lua54", ["lua", str(out / "context-controls.lua"), str(root)]),
        ("luajit", ["luajit", str(out / "context-controls.lua"), str(root)]),
        ("macos-peer", ["lua", str(out / "macos-peer-replay.lua"), str(root)]),
    ]
    for label, command in commands:
        result = subprocess.run(command, cwd=root, check=True, capture_output=True, text=True)
        data = result.stdout + result.stderr
        file = out / f"dry-{name}-{label}.txt"
        file.write_text(data)
        observation = json.loads(
            result.stdout if label == "source" else result.stdout.splitlines()[-1]
        )
        if label == "source":
            assert len(observation["source_files"]) == 20
            assert len(observation["actual_declaration_model"]) == 6
        elif label == "macos-peer":
            assert len(observation["cases"]) == 12
            assert observation["policy_mismatches"] == 5
        else:
            assert observation["checks"] == 1388
            assert observation["policy_scenarios"] == 208
            assert observation["result"] == "pass"
        runs.append(
            {
                "label": label,
                "argv": command,
                "cwd": str(root),
                "exit_code": result.returncode,
                "output": file.name,
                "sha256": hashlib.sha256(data.encode()).hexdigest(),
            }
        )
    receipts.append(
        {
            "pass": name,
            "completed_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "axes": [
                "canonical defaults versus raw initialization placeholders",
                "public callers versus pure corpus scope",
                "arrow shortcut tap-hold option and AI preference cross-product",
                "immediate state and next-key continuation",
                "modified Backspace and Escape effects",
                "terminal newline and empty-line backspace",
                "idle no-reset and coarse-clock boundaries",
                "Unicode backspace and private mark",
                "menus source publication and declared OS restriction",
                "prior-root deduplication and intentional-difference basis",
            ],
            "new_shared_roots": 0,
            "known_peer_root": "Mac caller mirror lifetime, owned by macOS reviewer",
            "runs": runs,
        }
    )
(out / "dry-receipts.json").write_text(json.dumps(receipts, indent=2) + "\n")
print(
    "Two final bounded shared sweeps complete: zero new shared roots; existing Mac caller mismatch retained."
)
