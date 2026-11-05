"""Retain exact source provenance and actual declaration-model observations."""

import hashlib
import json
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1]).resolve()
sha = "b17e47ed3bb92c106703d3e3482b3c2973f5bc1e"
paths = [
    "static/ergopti_plus/_shared/modules/features/manifest.toml",
    "static/ergopti_plus/_shared/modules/menu/menu_manifest.json",
    "static/ergopti_plus/_shared/lua/hotstring_engine/init.lua",
    "static/ergopti_plus/_shared/lua/llm/context_buffer.lua",
    "static/ergopti_plus/_shared/tests/corpus/hotstrings/idle_reset_vectors.json",
    "static/ergopti_plus/_shared/tests/corpus/llm/context_buffer_vectors.json",
    "static/ergopti_plus/linux/modules/hotstrings/word_reset.lua",
    "static/ergopti_plus/linux/modules/hotstrings/engine.lua",
    "static/ergopti_plus/linux/modules/llm/context.lua",
    "static/ergopti_plus/linux/modules/llm/settings.lua",
    "static/ergopti_plus/linux/ergopti_hotstrings.lua",
    "static/ergopti_plus/linux/ui/menu/menu_hotstrings.lua",
    "static/ergopti_plus/macos/modules/keymap/init.lua",
    "static/ergopti_plus/macos/modules/keymap/state.lua",
    "static/ergopti_plus/macos/modules/keymap/llm_bridge.lua",
    "static/ergopti_plus/macos/ui/menu/menu_hotstrings_management.lua",
    "static/ergopti_plus/macos/tests/unit/modules/keymap/terminators/test_nav_invalidates_hotstring_buffer.lua",
    "static/ergopti_plus/windows/infra/hotstrings/hotstring_engine_main.ahk",
    "static/ergopti_plus/windows/infra/hotstrings/hotstring_inputhook.ahk",
    "tools/build/build-features-manifest.js",
]
sources = {}
for file in paths:
    pinned = subprocess.check_output(["git", "show", sha + ":" + file], cwd=root)
    assert (root / file).read_bytes() == pinned, f"Review source changed: {file}"
    sources[file] = hashlib.sha256(pinned).hexdigest()
script = """
const model = require(process.argv[2]).loadFeatureModel();
const wanted = ['hotstrings.idle_reset_seconds','hotstrings.click_resets_word',
 'hotstrings.arrow_resets_word','hotstrings.shortcut_resets_word',
 'hotstrings.tap_hold_resets_word','llm.generation.reset_on_nav'];
console.log(JSON.stringify(model.features.filter(row=>wanted.includes(row.path))
 .map(row=>({path:row.path,default:row.default,platforms:row.platforms,reason_key:row.reason_key??null}))));
"""
rows = json.loads(
    subprocess.check_output(
        [
            "node",
            "-e",
            script,
            "audit-source-probe",
            str(root / "tools/build/build-features-manifest.js"),
        ],
        text=True,
    )
)
assert len(rows) == 6
for row in rows:
    assert row["default"] == (3 if row["path"].endswith("idle_reset_seconds") else True)
    if row["path"] == "hotstrings.tap_hold_resets_word":
        assert set(row["platforms"]) == {"ahk", "linux"}
        assert row["reason_key"] == "platform_reason.tap_hold_word_reset_not_on_macos"
    else:
        assert set(row["platforms"]) == {"ahk", "hs", "linux"}
print(
    json.dumps(
        {
            "audited_sha": sha,
            "source_files": sources,
            "actual_declaration_model": rows,
            "basis": "authenticated exact source plus actual declaration-model code; no native AHK execution",
            "corpus_limit": "Shared pure policy success does not certify caller state after the next key.",
            "known_differences": [
                "macOS tap-hold origin is unavailable by explicit Karabiner policy",
                "Linux modifier-free newline cannot distinguish terminal Shift+Enter",
                "Linux coarse clock subtracts its measured resolution when high-resolution backend is absent",
            ],
        },
        indent=2,
    )
)
