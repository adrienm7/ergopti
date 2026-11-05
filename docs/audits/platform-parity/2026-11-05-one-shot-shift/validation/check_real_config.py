"""Assert original settings and public menu round trips through private real TOML."""

import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(sys.argv[1]).resolve()
validation = Path(__file__).resolve().parent
here = validation.parent / "macos/real-config-domain"
OUT = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else validation
OUT.mkdir(parents=True, exist_ok=True)
pin = "9c565c88c9a1366a2e9b18c1b9d2868509510975"
paths = [
    item["path"]
    for item in json.loads((here.parent / "ui-domain/source-and-replay-receipt.json").read_text())[
        "sources"
    ]
]
paths += [
    "static/ergopti_plus/macos/adapters/file_system.lua",
    "static/ergopti_plus/macos/adapters/write_lock_path.lua",
    "static/ergopti_plus/macos/infra/fs_dir.lua",
    "static/ergopti_plus/macos/tests/stubs/hs.lua",
    "static/ergopti_plus/_shared/lua/test/runner_home.lua",
]
paths += [
    str(path.relative_to(root))
    for path in sorted((root / "static/ergopti_plus/_shared/lua/toml_codec").glob("*.lua"))
]
sources = []
for path in dict.fromkeys(paths):
    raw = (root / path).read_bytes()
    pinned = subprocess.check_output(["git", "show", f"{pin}:{path}"], cwd=root)
    assert raw == pinned, path
    sources.append(
        {"path": path, "sha256": hashlib.sha256(raw).hexdigest(), "pinned_matches": True}
    )


def finite(value):
    return {"type": "number", "class": "finite", "value": value}


infinity = {"type": "number", "class": "positive-infinity"}
runs = []
for sweep in (1, 2):
    for name in ("real-config-domain", "real-menu-persistence"):
        with tempfile.TemporaryDirectory(prefix="macos-real-config-") as private:
            env = dict(os.environ, LOGNAME="agent", TMPDIR=private, PYTHONDONTWRITEBYTECODE="1")
            env["PATH"] = "/workspace/scratch/parity-toolchain/ci-bin:" + env["PATH"]
            result = subprocess.run(
                ["lua", str(here / (name + ".lua")), str(root), private],
                cwd=root,
                env=env,
                capture_output=True,
                timeout=60,
                check=False,
            )
        output = result.stdout + result.stderr
        log = OUT / f"sweep-{sweep}-{name}.log"
        log.write_bytes(output)
        assert result.returncode == 0, output.decode(errors="replace")
        rows = json.loads(result.stdout)
        assert len(rows) == 10
        if name == "real-config-domain":
            by_key = {(row["initially_enabled"], row["name"]): row for row in rows}
            assert len(by_key) == 10
            for enabled in (False, True):
                for case, want in [
                    ("control-2000", finite(2000)),
                    ("positive-infinity", infinity),
                    ("large-finite", finite(1e20)),
                    ("zero", finite(1000)),
                    ("fraction-to-zero", finite(0)),
                ]:
                    row = by_key[enabled, case]
                    assert row["actual_enabled"] is enabled
                    assert row["called"] and row["return_arity"] == 1
                    assert row["reload_called"] and row["reload_return_arity"] >= 1
                    assert row["before"] == finite(1000)
                    assert row["after"] == row["reloaded_sticky"] == want
                    assert row["generator_build_calls"] == row["generator_deploy_calls"] == 0
                    if case == "zero":
                        assert row["first_return"] == {"type": "boolean", "text": "false"}
                        assert row["save_calls"] == 0
                        assert row["published_bytes"] == row["original_bytes"]
                    else:
                        assert row["first_return"] == {"type": "boolean", "text": "true"}
                        assert row["save_calls"] == 1
                        assert row["published_bytes"] != row["original_bytes"]
                        if case == "control-2000":
                            assert "sticky_timeout_ms" not in row["published_bytes"]
                        else:
                            literal = {
                                "positive-infinity": "+inf",
                                "large-finite": "1e+20",
                                "fraction-to-zero": "0",
                            }[case]
                            assert f"sticky_timeout_ms = {literal}\n" in row["published_bytes"]
        else:
            by_key = {(row["initially_enabled"], row["text"]): row for row in rows}
            assert len(by_key) == 10
            for enabled in (False, True):
                for text in ("2000", "0.9", "1e309", "1e20", "invalid"):
                    row = by_key[enabled, text]
                    assert row["actual_enabled"] is enabled
                    assert row["action_called"] and row["action_return_arity"] == 0
                    assert row["rebuild_called"]
                    assert row["generator_build_calls"] == row["generator_deploy_calls"] == 0
                    obs = row["observations"]
                    persistence = row["real_persistence"]
                    want = {
                        "2000": finite(2000),
                        "0.9": finite(1000),
                        "1e309": infinity,
                        "1e20": finite(1e20),
                        "invalid": finite(1000),
                    }[text]
                    assert (
                        row["after"]
                        == row["after_reopen"]
                        == persistence["reloaded_sticky"]
                        == want
                    )
                    assert all(
                        reply == {"ok": True, "text_returned_type": "string", "text_returned": text}
                        for reply in obs["dialog_replies"]
                    )
                    if text in ("1e309", "1e20"):
                        assert row["save_calls"] == persistence["save_calls"] == 1
                        assert len(obs["dialogs"]) == len(obs["dialog_replies"]) == 1
                        assert not row["reopen_called"] and row["reopen_return_arity"] == 1
                        assert "number has no integer representation" in row["reopen_error"]
                        assert "text_utils/init.lua:716" in row["reopen_error"]
                        assert obs["regenerations"] == obs["refreshes"] == 1
                        assert obs["setter_inputs"] == [want]
                        assert obs["setter_returns"] == [
                            {"arity": 1, "first": {"type": "boolean", "text": "true"}}
                        ]
                        literal = "+inf" if text == "1e309" else "1e+20"
                        assert f"sticky_timeout_ms = {literal}\n" in persistence["published_bytes"]
                        assert row["rebuilt_label"] == (
                            "Sticky modifier delay: inf s"
                            if text == "1e309"
                            else "Sticky modifier delay: 1e+17 s"
                        )
                    else:
                        assert row["reopen_called"] and row["reopen_return_arity"] == 0
                        assert len(obs["dialogs"]) == len(obs["dialog_replies"]) == 2
                        if text == "2000":
                            assert row["save_calls"] == 1 and persistence["save_calls"] == 2
                            assert obs["regenerations"] == obs["refreshes"] == 2
                            assert "sticky_timeout_ms" not in persistence["published_bytes"]
                        else:
                            assert row["save_calls"] == persistence["save_calls"] == 0
                            assert obs["regenerations"] == obs["refreshes"] == 0
                            assert "sticky_timeout_ms = 1000\n" in persistence["published_bytes"]
                            if text == "invalid":
                                assert not obs["setter_inputs"] and not obs["setter_returns"]
                            else:
                                assert obs["setter_inputs"] == [finite(0)] * 2
                                assert all(
                                    ret
                                    == {"arity": 1, "first": {"type": "boolean", "text": "false"}}
                                    for ret in obs["setter_returns"]
                                )
        runs.append(
            {
                "sweep": sweep,
                "program": name,
                "exit": result.returncode,
                "asserted_rows": 10,
                "log": log.name,
                "sha256": hashlib.sha256(output).hexdigest(),
            }
        )
receipt = {
    "source_commit": pin,
    "sources": sources,
    "runs": runs,
    "frozen_ui_probe_sha256": hashlib.sha256(
        (here.parent / "ui-domain/menu-infinity-probe.lua").read_bytes()
    ).hexdigest(),
    "qualification": "Original menu/setter/Config/TOML/file_system owners with actual private Linux file writes/readbacks; original test HOME isolation; native Hammerspoon metadata/lease/dialog/regeneration/logging ports remain fixtures. No native macOS UI, application receiving or deployment proof.",
}
(OUT / "source-and-replay-receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
print("REAL_CONFIG_ASSERTIONS=10 direct rows +10 linked UI rows per sweep; two sweeps passed")
