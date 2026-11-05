"""Replay original public menu callback plus actual setter over recorded ports."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
here = Path(__file__).resolve().parent
program = here / "menu-infinity-probe.lua"
pin = "9c565c88c9a1366a2e9b18c1b9d2868509510975"
paths = [
    "static/ergopti_plus/macos/ui/menu/menu_tap_holds.lua",
    "static/ergopti_plus/macos/tests/unit/ui/menu/keyboard_layout/test_karabiner_timeout_regenerates.lua",
    "static/ergopti_plus/macos/tests/helpers/init.lua",
    "static/ergopti_plus/macos/tests/support/remap_transaction_fixture.lua",
    "static/ergopti_plus/macos/platform/remap/init.lua",
    "static/ergopti_plus/macos/platform/remap/config.lua",
    "static/ergopti_plus/macos/infra/text_utils.lua",
    "static/ergopti_plus/_shared/lua/text_utils/init.lua",
    "static/ergopti_plus/_shared/data/locales/en.json",
]
sources = []
for path in paths:
    raw = (root / path).read_bytes()
    pinned = subprocess.check_output(["git", "show", f"{pin}:{path}"], cwd=root)
    assert raw == pinned, path
    sources.append(
        {"path": path, "sha256": hashlib.sha256(raw).hexdigest(), "pinned_matches": True}
    )
runs = []
for sweep in (1, 2):
    env = dict(os.environ, LOGNAME="agent", PYTHONDONTWRITEBYTECODE="1")
    env["PATH"] = "/workspace/scratch/parity-toolchain/ci-bin:" + env["PATH"]
    with tempfile.TemporaryDirectory(prefix="macos-menu-domain-") as temporary:
        env["TMPDIR"] = temporary
        result = subprocess.run(
            ["lua", str(program), str(root)],
            cwd=root,
            env=env,
            capture_output=True,
            timeout=30,
            check=False,
        )
    output = result.stdout + result.stderr
    log = here / f"sweep-{sweep}-menu-domain.log"
    log.write_bytes(output)
    assert result.returncode == 0, output.decode(errors="replace")
    rows = json.loads(result.stdout)
    assert len(rows) == 10
    indexed = {(r["initially_enabled"], r["text"]): r for r in rows}
    assert len(indexed) == 10
    for enabled in (False, True):
        for text in ("2000", "0.9", "1e309", "1e20", "invalid"):
            row = indexed[enabled, text]
            assert row["actual_enabled"] is enabled
            assert row["before"] == {"type": "number", "class": "finite", "value": 1000}
            assert row["action_called"] and row["action_return_arity"] == 0
            assert row["rebuild_called"]
            assert row["generator_build_calls"] == row["generator_deploy_calls"] == 0
            obs = row["observations"]
            assert len(obs["dialogs"]) == len(obs["dialog_replies"])
            assert 'default answer "1000"' in obs["dialogs"][0]
            assert all(
                reply == {"ok": True, "text_returned_type": "string", "text_returned": text}
                for reply in obs["dialog_replies"]
            )
            if text in ("1e309", "1e20"):
                expected = (
                    {"type": "number", "class": "positive-infinity"}
                    if text == "1e309"
                    else {"type": "number", "class": "finite", "value": 1e20}
                )
                assert (
                    row["parsed"] == row["after"] == row["saved"] == row["after_reopen"] == expected
                )
                assert obs["setter_inputs"] == [expected]
                assert obs["setter_returns"] == [
                    {"arity": 1, "first": {"type": "boolean", "text": "true"}}
                ]
                assert row["save_calls"] == row["save_calls_after_reopen"] == 1
                assert obs["regenerations"] == obs["refreshes"] == 1
                assert len(obs["dialogs"]) == 1
                assert not row["reopen_called"] and row["reopen_return_arity"] == 1
                assert "number has no integer representation" in row["reopen_error"]
                assert "text_utils/init.lua:716" in row["reopen_error"]
                assert row["rebuilt_label"] == (
                    "Sticky modifier delay: inf s"
                    if text == "1e309"
                    else "Sticky modifier delay: 1e+17 s"
                )
            else:
                assert row["reopen_called"] and row["reopen_return_arity"] == 0
                assert len(obs["dialogs"]) == 2
                if text == "2000":
                    assert (
                        row["after"]
                        == row["saved"]
                        == {"type": "number", "class": "finite", "value": 2000}
                    )
                    assert row["save_calls"] == 1 and row["save_calls_after_reopen"] == 2
                    assert obs["regenerations"] == obs["refreshes"] == 2
                    assert all(
                        ret == {"arity": 1, "first": {"type": "boolean", "text": "true"}}
                        for ret in obs["setter_returns"]
                    )
                else:
                    assert row["after"] == row["after_reopen"] == row["before"]
                    assert row["save_calls"] == row["save_calls_after_reopen"] == 0
                    assert obs["regenerations"] == obs["refreshes"] == 0
                    if text == "0.9":
                        assert (
                            obs["setter_inputs"]
                            == [{"type": "number", "class": "finite", "value": 0}] * 2
                        )
                        assert all(
                            ret == {"arity": 1, "first": {"type": "boolean", "text": "false"}}
                            for ret in obs["setter_returns"]
                        )
                    else:
                        assert not obs["setter_inputs"] and not obs["setter_returns"]
    runs.append(
        {
            "sweep": sweep,
            "exit": result.returncode,
            "asserted_rows": len(rows),
            "log": log.name,
            "sha256": hashlib.sha256(output).hexdigest(),
        }
    )
receipt = {
    "source_commit": pin,
    "sources": sources,
    "runs": runs,
    "program_sha256": hashlib.sha256(program.read_bytes()).hexdigest(),
    "qualification": "Original menu build/callback and original Remap setter in both disabled and enabled fixture states; acknowledged save and regeneration ports; recorded valid AppleScript dialog strings; no native UI, disk, lease regeneration, or application proof.",
}
(here / "source-and-replay-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
print("MENU_DOMAIN_ASSERTIONS=10 rows per sweep; two sweeps passed")
