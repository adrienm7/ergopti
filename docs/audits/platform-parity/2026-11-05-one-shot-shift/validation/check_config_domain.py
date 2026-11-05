#!/usr/bin/env python3
"""Assert original macOS numeric-domain observations over declared fixture ports."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(sys.argv[1]).resolve()
VALIDATION = Path(__file__).resolve().parent
OUT = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else VALIDATION
OUT.mkdir(parents=True, exist_ok=True)
CAMPAIGN = VALIDATION.parent
SUPPLEMENT = CAMPAIGN / "macos/validation"
PIN = "9c565c88c9a1366a2e9b18c1b9d2868509510975"


def sha256(raw):
    return hashlib.sha256(raw).hexdigest()


handoff_raw = (SUPPLEMENT / "handoff.sha256.json").read_bytes()
handoff = json.loads(handoff_raw)
for item in handoff["files"]:
    assert sha256((SUPPLEMENT / item["file"]).read_bytes()) == item["sha256"], item["file"]
receipts = json.loads((SUPPLEMENT / "source-receipts.json").read_text())
assert receipts["commit"] == PIN
assert (
    sha256((CAMPAIGN / "macos/public-probe.lua").read_bytes())
    == receipts["frozen_public_fixture_sha256"]
)
source_rows = {}
for receipt in [receipts, json.loads((CAMPAIGN / "macos/source-receipts.json").read_text())]:
    for item in receipt["files"]:
        path = item["path"]
        current = (ROOT / path).read_bytes()
        pinned = subprocess.check_output(["git", "show", PIN + ":" + path], cwd=ROOT)
        assert sha256(current) == item["sha256"] and current == pinned, path
        source_rows[path] = {
            "path": path,
            "sha256": sha256(current),
            "pinned_matches": True,
            "current_matches": True,
        }

runs = []
parsed = {}
env = dict(os.environ, LOGNAME="agent", PYTHONDONTWRITEBYTECODE="1")
env["PATH"] = "/workspace/scratch/parity-toolchain/ci-bin:" + env["PATH"]
version = subprocess.run(["lua", "-v"], env=env, capture_output=True, text=True, check=True)
for name in [
    "config-domain-boundaries",
    "public-arm-domain-boundaries",
    "logger-domain-boundaries",
]:
    program = SUPPLEMENT / (name + ".lua")
    command = ["lua", str(program), str(ROOT)]
    with tempfile.TemporaryDirectory(prefix="macos-config-domain-private-") as temporary:
        env["TMPDIR"] = temporary
        result = subprocess.run(command, cwd=ROOT, env=env, capture_output=True, timeout=30)
    output = result.stdout + result.stderr
    log = OUT / (name + "-current.log")
    log.write_bytes(output)
    assert result.returncode == 0, output.decode(errors="replace")
    parsed[name] = json.loads(result.stdout)
    runs.append(
        {
            "command": command,
            "runtime_version": (version.stdout + version.stderr).strip(),
            "exit": result.returncode,
            "log": log.name,
            "sha256": sha256(output),
            "program_sha256": sha256(program.read_bytes()),
            "fresh_private_tmpdir": True,
        }
    )

rows = parsed["config-domain-boundaries"]
assert len(rows) == 14 and len({row["name"] for row in rows}) == 14
by_name = {row["name"]: row for row in rows}
expected = {
    "nan": (True, {"type": "number", "class": "nan"}),
    "positive-infinity": (True, {"type": "number", "class": "positive-infinity"}),
    "negative-infinity": (False, None),
    "string-positive-infinity": (False, None),
    "string-nan": (False, None),
    "string-positive-integer": (True, 2000),
    "string-positive-fraction": (True, 0),
    "string-whitespace-positive-integer": (True, 1),
    "string-negative": (False, None),
    "string-nonnumeric": (False, None),
    "below-one": (True, 0),
    "one": (True, 1),
    "above-one": (True, 1),
    "one-point-nine": (True, 1),
}
assert set(by_name) == set(expected)
for name, (accepted, value) in expected.items():
    row = by_name[name]
    assert row["called"] and row["return_arity"] == 1, name
    assert row["returns"] == [{"type": "boolean", "text": str(accepted).lower()}], name
    assert row["before"] == {"type": "number", "class": "finite", "value": 1000}, name
    assert row["qualification"] == (
        "Original Remap setter/transaction; initially disabled; acknowledged save port only"
    )
    if accepted:
        want = (
            value
            if isinstance(value, dict)
            else {"type": "number", "class": "finite", "value": value}
        )
        assert row["save_calls"] == 1 and row["after"] == row["saved"] == want, name
    else:
        assert row["save_calls"] == 0 and row["after"] == row["before"], name
        assert row["saved"] == {"type": "nil", "text": "nil"}, name
assert by_name["nan"]["input"] == {"type": "number", "class": "nan"}
assert by_name["positive-infinity"]["input"] == {"type": "number", "class": "positive-infinity"}
assert by_name["negative-infinity"]["input"] == {"type": "number", "class": "negative-infinity"}
for name in [key for key in expected if key.startswith("string-")]:
    assert by_name[name]["input"]["type"] == "string", name
assert 0 < by_name["below-one"]["input"]["value"] < 1
assert by_name["one"]["input"]["value"] == 1
assert by_name["above-one"]["input"]["value"] > 1

arms = parsed["public-arm-domain-boundaries"]
assert len(arms) == 5 and len({row["name"] for row in arms}) == 5
arm = {row["name"]: row for row in arms}
assert set(arm) == {"nan", "positive-infinity", "negative-infinity", "zero", "one"}
for name in ["nan", "negative-infinity", "zero"]:
    assert arm[name]["called"] is False and arm[name]["return_arity"] == 1
    assert "invalid one-shot Shift timeout" in arm[name]["error"]
for name, output in [("positive-infinity", "A"), ("one", "a")]:
    assert arm[name]["called"] and arm[name]["accepted"] is True
    assert arm[name]["return_arity"] == 1
    assert arm[name]["first_character_at_clock_1e12"] == output

formatter = parsed["logger-domain-boundaries"]
assert len(formatter) == 2 and {row["name"] for row in formatter} == {"nan", "positive-infinity"}
for row in formatter:
    assert row["called"] is True
    assert row["result"] == "recorded-time [DEBUG] [domain-probe] Sticky timeout: %d ms."

receipt = {
    "source_commit": PIN,
    "sources": list(source_rows.values()),
    "supplement_handoff_sha256": sha256(handoff_raw),
    "frozen_supplement_authenticated": True,
    "frozen_public_fixture_authenticated": True,
    "runs": runs,
    "setter_rows_asserted": 14,
    "public_arm_rows_asserted": 5,
    "shared_formatter_rows_asserted": 2,
    "qualification": (
        "Original owners over declared ports; setter initially disabled and save acknowledged only; "
        "public arming and formatter execute independently; no real disk, menu, native receiving "
        "or full native logger transport claim. Same OSM-002 numeric-domain root."
    ),
}
(OUT / "config-domain-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
print("CONFIG_DOMAIN_ASSERTIONS=14 setter / 5 public arm / 2 shared formatter; all passed")
