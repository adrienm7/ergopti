"""Replay the separate synthetic-output follow-up without altering initial receipts."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("repository", type=Path)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
program = Path(__file__).resolve().parent / "probe.lua"
digest = hashlib.sha256(program.read_bytes()).hexdigest()
rows = []
for sweep in ["A", "B"]:
    for runtime in ["lua", "luajit"]:
        name = f"{sweep}-{runtime}"
        command = [runtime, str(program), str(args.repository)]
        with tempfile.TemporaryDirectory(prefix="ergopti-caps-synthetic-") as private:
            env = dict(os.environ, TMPDIR=private, LOGNAME="agent")
            result = subprocess.run(
                command,
                cwd=args.repository / "static/ergopti_plus/linux",
                env=env,
                capture_output=True,
                text=True,
                timeout=120,
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
        if result.returncode == 0:
            prefix = "CAPS_SYNTHETIC_OBSERVATIONS="
            output = [s[len(prefix) :] for s in result.stdout.splitlines() if s.startswith(prefix)]
            assert len(output) == 1
            observations = json.loads(output[0])
            assert len(observations["cases"]) == 12
            row["observation_rows"] = len(observations["cases"])
        rows.append(row)
        print(name, result.returncode, flush=True)
assert hashlib.sha256(program.read_bytes()).hexdigest() == digest
(args.output / "receipts.json").write_text(
    json.dumps(
        {
            "audited_sha": "f2a7dba5fc580aad61e6a0ed16ede84406aed2b0",
            "program_sha256": digest,
            "replay_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "qualification": "Separate completed-scope follow-up: two bounded full-program sweeps; actual owners over native recording ports; no native desktop receiving.",
            "processes": rows,
        },
        indent=2,
    )
    + "\n"
)
raise SystemExit(any(row["exit_code"] for row in rows))
