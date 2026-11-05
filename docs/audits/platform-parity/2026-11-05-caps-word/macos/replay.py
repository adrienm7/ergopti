"""Replay frozen actual-owner CapsWord programs; no physical receiving claim."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("repository", type=Path)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
base = Path(__file__).resolve().parent
rows = []
for program in [
    "public-idle.lua",
    "public-admission.lua",
    "public-payload.lua",
    "public-magic-menu.lua",
    "activation-graph.lua",
]:
    path = base / program
    command = ["lua", str(path), str(args.repository.resolve())]
    result = subprocess.run(
        command, cwd=args.repository, capture_output=True, text=True, env=os.environ, check=False
    )
    (args.output / (program + ".stdout.txt")).write_text(result.stdout)
    (args.output / (program + ".stderr.txt")).write_text(result.stderr)
    rows.append(
        {
            "program": program,
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
            "command": command,
            "exit_code": result.returncode,
            "stdout_sha256": hashlib.sha256(result.stdout.encode()).hexdigest(),
            "stderr_sha256": hashlib.sha256(result.stderr.encode()).hexdigest(),
        }
    )
    print(program, result.returncode, flush=True)
(args.output / "receipt.json").write_text(
    json.dumps(
        {
            "audited_sha": "f2a7dba5fc580aad61e6a0ed16ede84406aed2b0",
            "qualification": "Actual Lua owners over explicit recorded native ports; generated graph/model is not native Karabiner; Windows not executed; no latency/memory measurement.",
            "new_confirmed_roots": 0,
            "processes": rows,
        },
        indent=2,
    )
    + "\n"
)
raise SystemExit(any(row["exit_code"] for row in rows))
