"""Replay retained audit programs without treating native ports as desktop receipts."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def main():
    """Record each independently replayed process and its actual program bytes."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    campaign = Path(__file__).resolve().parent
    repository = args.repository.resolve()
    args.output.mkdir(parents=True, exist_ok=True)
    plans = [
        ("windows-source", "python3", "windows/source-contract.py"),
        ("macos-context", "lua", "macos/public-context.lua"),
        ("macos-request", "lua", "macos/context-request.lua"),
        ("macos-edits", "lua", "macos/public-edits.lua"),
        ("macos-keypad", "lua", "macos/keypad-enter.lua"),
        ("linux-luajit", "luajit", "linux/continuity-probe.lua"),
        ("linux-lua54", "lua", "linux/continuity-probe.lua"),
        ("shared-lua54", "lua", "shared/context-controls.lua"),
        ("shared-luajit", "luajit", "shared/context-controls.lua"),
        ("root-matched-arrow-luajit", "luajit", "validation/root-physical-arrow.lua"),
        ("root-matched-arrow-lua54", "lua", "validation/root-physical-arrow.lua"),
        ("shared-source", "python3", "shared/source_probe.py"),
        ("metadata-controls", "python3", "check_project.py"),
    ]
    receipts = []
    for name, executable, relative in plans:
        program = campaign / relative
        command = [executable, str(program), str(repository)]
        result = subprocess.run(
            command, cwd=repository, capture_output=True, text=True, check=False
        )
        (args.output / f"{name}.stdout.txt").write_text(result.stdout, encoding="utf-8")
        (args.output / f"{name}.stderr.txt").write_text(result.stderr, encoding="utf-8")
        receipts.append(
            {
                "name": name,
                "program": relative,
                "program_sha256": hashlib.sha256(program.read_bytes()).hexdigest(),
                "command": command,
                "cwd": str(repository),
                "exit_code": result.returncode,
                "stdout_sha256": hashlib.sha256(result.stdout.encode()).hexdigest(),
                "stderr_sha256": hashlib.sha256(result.stderr.encode()).hexdigest(),
            }
        )
        print(f"{name}: exit {result.returncode}", flush=True)
    (args.output / "receipts.json").write_text(
        json.dumps(
            {
                "source_head": subprocess.check_output(
                    ["git", "rev-parse", "HEAD"], cwd=repository, text=True
                ).strip(),
                "logname": os.environ.get("LOGNAME"),
                "qualification": "Actual Lua owners over recorded native ports; Windows lexical only; shared probe reads pinned Git blobs; metadata controls are not driver tests.",
                "processes": receipts,
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    if any(receipt["exit_code"] for receipt in receipts):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
