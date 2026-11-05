#!/usr/bin/env python3
"""Replay reachable-preset channel admission in two fresh, isolated Lua owners."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
validation = Path(__file__).resolve().parent
OUT = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else validation
OUT.mkdir(parents=True, exist_ok=True)
campaign = validation.parent
pin = "9c565c88c9a1366a2e9b18c1b9d2868509510975"
program = validation / "public-channel-admission.lua"
receipts = json.loads((campaign / "linux/source-receipts.json").read_text())
paths = [item["path"] for item in receipts["sources"]]
paths += [
    "static/ergopti_plus/linux/infra/manifest_reader.lua",
    "static/ergopti_plus/_shared/lua/manifest_reader.lua",
    "static/ergopti_plus/_shared/lua/features/manifest.lua",
    "static/ergopti_plus/_shared/lua/features/manifest_data.lua",
]
sources = []
for path in dict.fromkeys(paths):
    raw = (root / path).read_bytes()
    pinned = subprocess.check_output(["git", "show", pin + ":" + path], cwd=root)
    assert raw == pinned, path
    sources.append(
        {
            "path": path,
            "sha256": hashlib.sha256(raw).hexdigest(),
            "pinned_matches": True,
            "current_matches": True,
        }
    )
fixture = (root / "static/ergopti_plus/linux/tests/support/input_owner_fixture.lua").read_text()
contracts = {
    "public_option_bypasses_unavailable_declaration_fixture": 'if options.public_chords ~= true then require("tests.support.key_combination_declaration_fixture").install_unavailable() end'
    in fixture,
    "before_manager_runs_before_actual_manager_init": fixture.index(
        "if options.before_manager then options.before_manager(s) end"
    )
    < fixture.index("assert(manager.init("),
    "real_source_reader_serves_s_bytes": "write(source_path, s.bytes)" in fixture,
    "actual_tap_document_explicitly_selects_shipped_preset": 'write(tap_path, require("tests.support.tap_hold_fixture").with_preset(""))'
    in fixture,
}
assert all(contracts.values())
runs = []
for runtime in ["lua", "luajit"]:
    env = dict(os.environ, LOGNAME="agent", PYTHONDONTWRITEBYTECODE="1")
    env["PATH"] = "/workspace/scratch/parity-toolchain/ci-bin:" + env["PATH"]
    version = subprocess.run([runtime, "-v"], env=env, capture_output=True, text=True, check=True)
    command = [runtime, str(program), str(root)]
    with tempfile.TemporaryDirectory(prefix="public-admission-private-") as temporary:
        env["TMPDIR"] = temporary
        done = subprocess.run(
            command, cwd=root, env=env, capture_output=True, timeout=30, check=False
        )
    output = done.stdout + done.stderr
    log = OUT / ("public-channel-admission-" + runtime + ".txt")
    log.write_bytes(output)
    assert done.returncode == 0, output.decode(errors="replace")
    rows = [
        line.split("=", 1)[1]
        for line in output.decode().splitlines()
        if line.startswith("PUBLIC_CHANNEL_ADMISSION=")
    ]
    assert len(rows) == 1
    parsed = json.loads(rows[0])
    assert len(parsed["observations"]) == 2
    healthy, repeated = parsed["observations"]
    for row in [healthy, repeated]:
        assert row["config_toml"] == "" and row["original_production_declarations"]
        assert not row["unavailable_declaration_fixture_loaded"]
        assert row["generic_action_calls"] == 0
        assert row["preset"] == {"right_ctrl_tap": "one_shot_shift", "right_ctrl_hold": "shift"}
    assert not healthy["repeated"] and healthy["chars"] == ["A", "a"]
    assert healthy["hook_running"] and not healthy["broker_debt"] and healthy["output_current"]
    assert healthy["reader_closes"] == healthy["output_closes"] == healthy["output_destroys"] == 0
    assert repeated["repeated"] and repeated["chars"] == ["A"]
    assert (
        not repeated["hook_running"] and repeated["broker_debt"] and not repeated["output_current"]
    )
    assert (
        repeated["reader_closes"] == 2
        and repeated["output_closes"] == repeated["output_destroys"] == 1
    )
    assert len(repeated["errors"]) == 1 and "code=30 value=2" in repeated["errors"][0]
    runs.append(
        {
            "runtime": runtime,
            "version": (version.stdout + version.stderr).strip(),
            "command": command,
            "exit": done.returncode,
            "log": log.name,
            "sha256": hashlib.sha256(output).hexdigest(),
            "parsed_assertions_passed": True,
            "observations": parsed["observations"],
            "qualification": parsed["qualification"],
        }
    )
result = {
    "audited_sha": pin,
    "finding": "OSL-002",
    "conclusion": "Confirmed reachable with valid empty config.toml and explicitly enabled shipped tap-hold preset, using unchanged production chord declarations. Repeat still retires original keyboard channel; matched no-repeat remains healthy.",
    "qualification": "Enabled shipped preset is a valid user configuration, not the neutral installation default. Existing original test fixture initially constructs an unused legacy owner and controlled base Engine; actual Manager then replaces them before all physical events. No unavailable declaration fixture, legacy action trigger or generic action dispatch occurs. Native ports are recording controls; no native input descriptor, libxkb inverse or receiving application is measured.",
    "production_or_registered_test_changes": False,
    "program": program.name,
    "program_sha256": hashlib.sha256(program.read_bytes()).hexdigest(),
    "source_contracts": contracts,
    "source_receipts": sources,
    "runs": runs,
}
output = OUT / "public-channel-admission-receipt.json"
output.write_text(json.dumps(result, indent=2) + "\n")
print(
    json.dumps(
        {
            "sources": len(sources),
            "fresh_processes": len(runs),
            "parsed_assertions_passed": all(item["parsed_assertions_passed"] for item in runs),
            "receipt": str(output),
        }
    )
)
