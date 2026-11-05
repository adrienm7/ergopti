"""Replay actual CapsWord owners with one private temporary root per process."""

import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


def digest(data):
    """Return a receipt for the exact retained program or output bytes."""
    return hashlib.sha256(data).hexdigest()


def main():
    """Execute retained probes and registered modules without desktop claims."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    repository = args.repository.resolve()
    campaign = Path(__file__).resolve().parent
    args.output.mkdir(parents=True, exist_ok=True)
    plans = [("windows-source", "python3", "windows/source-contract.py", [])]
    for name in [
        "public-idle",
        "public-admission",
        "public-payload",
        "public-magic-menu",
        "activation-graph",
    ]:
        plans.append(("macos-" + name, "lua", "macos/" + name + ".lua", []))
    for runtime in ["lua", "luajit"]:
        plans.extend(
            [
                ("linux-owner-" + runtime, runtime, "linux/owner-probe.lua", []),
                ("shared-policy-" + runtime, runtime, "shared/policy-probe.lua", []),
                ("shared-magic-" + runtime, runtime, "shared/magic-key-policy.lua", []),
                ("root-policy-" + runtime, runtime, "validation/root-policy-boundaries.lua", []),
                ("root-fixed-exits-" + runtime, runtime, "validation/root-fixed-exits.lua", []),
            ]
        )
    plans.extend(
        [
            (
                "linux-source",
                "python3",
                "linux/source-probe.py",
                ["--output", str(args.output / "linux-source-claims.json")],
            ),
            ("shared-source", "python3", "shared/source-contract.py", []),
            ("shared-declarations", "node", "shared/declaration-probe.cjs", []),
            ("metadata-controls", "python3", "check_project.py", []),
        ]
    )
    for runtime in ["lua", "luajit"]:
        plans.append(
            ("linux-synthetic-" + runtime, runtime, "linux-synthetic-followup/probe.lua", [])
        )
    plans.append(
        (
            "linux-synthetic-source",
            "python3",
            "linux-synthetic-followup/source-probe.py",
            ["--output", str(args.output / "linux-synthetic-source-claims.json")],
        )
    )
    mac_modules = json.loads((campaign / "macos/test-results.json").read_text())["runs"]
    for index, item in enumerate(mac_modules):
        module = item["module"]
        if not re.fullmatch(r"(?:unit|meta)/[A-Za-z0-9_/]+", module):
            raise ValueError("Invalid registered macOS module")
        plans.append(
            (f"macos-registered-{index:02}", "lua", "macos/run-module.lua", ["tests/" + module])
        )
    linux_modules = sorted(
        {
            row["command"][-1]
            for row in json.loads((campaign / "linux/final-proofs/receipts.json").read_text())[
                "processes"
            ]
            if row["command"][-1].startswith("tests.unit.")
        }
    )
    for runtime in ["lua", "luajit"]:
        for index, module in enumerate(linux_modules):
            if not re.fullmatch(r"tests\.unit\.[A-Za-z0-9_.]+", module):
                raise ValueError("Invalid registered Linux module")
            plans.append(
                (
                    f"linux-registered-{runtime}-{index:02}",
                    runtime,
                    "linux/run-registered.lua",
                    [module],
                )
            )

    def run(plan):
        name, executable, relative, arguments = plan
        program = campaign / relative
        command = [executable, str(program), str(repository), *arguments]
        with tempfile.TemporaryDirectory(prefix="ergopti-capsword-root-") as private:
            environment = dict(
                os.environ, TMPDIR=private, LOGNAME="agent", PYTHONDONTWRITEBYTECODE="1"
            )
            result = subprocess.run(
                command,
                cwd=repository,
                env=environment,
                capture_output=True,
                timeout=300,
                check=False,
            )
        (args.output / (name + ".stdout.txt")).write_bytes(result.stdout)
        (args.output / (name + ".stderr.txt")).write_bytes(result.stderr)
        counts = None
        text = result.stdout.decode("utf-8", errors="replace")
        match = re.search(r"AUDIT_RESULT\s+(\d+)\s+(\d+)", text)
        if match:
            counts = {"passed": int(match[1]), "failed": int(match[2])}
        for line in text.splitlines():
            if line.startswith("AUDIT_RESULTS="):
                parsed = json.loads(line.split("=", 1)[1])
                counts = {key: parsed[key] for key in ["passed", "failed"]}
        return {
            "name": name,
            "program": relative,
            "program_sha256": digest(program.read_bytes()),
            "command": command,
            "exit_code": result.returncode,
            "registered_counts": counts,
            "stdout_sha256": digest(result.stdout),
            "stderr_sha256": digest(result.stderr),
        }

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        receipts = list(executor.map(run, plans))
    document = {
        "source_head": subprocess.check_output(
            ["git", "rev-parse", "HEAD"], cwd=repository, text=True
        ).strip(),
        "qualification": "Actual owners over controlled native ports and registered tests; Windows lexical only. Source checks authenticate their named owners, not every transitive dependency. Repeated registered cases are not additional unique coverage or desktop receiving.",
        "processes": receipts,
    }
    (args.output / "receipts.json").write_text(json.dumps(document, indent="\t") + "\n")
    failures = [
        row["name"]
        for row in receipts
        if row["exit_code"] or (row["registered_counts"] and row["registered_counts"]["failed"])
    ]
    print(f"CapsWord root replay: {len(receipts)} processes, {len(failures)} failures.")
    if failures:
        raise SystemExit(", ".join(failures))


if __name__ == "__main__":
    main()
