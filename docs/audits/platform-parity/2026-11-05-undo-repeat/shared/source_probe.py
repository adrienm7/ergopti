"""Authenticate the pinned review and inspect actual exported site translations."""

import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile

root = pathlib.Path(sys.argv[1]).resolve()
sha = "b17e47ed3bb92c106703d3e3482b3c2973f5bc1e"
paths = [
    "tools/codegen/codegen-feature-inventory.cjs",
    "static/ergopti_plus/_shared/modules/features/manifest.toml",
    "static/ergopti_plus/_shared/core/features.json",
    "static/ergopti_plus/_shared/modules/menu/menu_manifest.json",
    "src/routes/ergopti-plus/feature-inventory.json",
    "src/routes/ergopti-plus/action-inventory.json",
    "src/routes/ergopti-plus/menu-gaps.json",
    "src/routes/ergopti-plus/input-inventory.json",
    "src/routes/ergopti-plus/locales/en.js",
    "static/ergopti_plus/linux/ergopti_hotstrings.lua",
    "static/ergopti_plus/linux/modules/hotstrings/repeat_key.lua",
    "static/ergopti_plus/macos/modules/keymap/expander.lua",
    "static/ergopti_plus/macos/modules/keymap/init.lua",
    "static/ergopti_plus/windows/infra/hotstrings/hotstring_engine_main.ahk",
    "static/ergopti_plus/windows/infra/hotstrings/hotstring_inputhook.ahk",
    "static/ergopti_plus/_shared/tests/corpus/hotstrings/repeat_key_vectors.json",
    "static/layouts/registry/ergopti/hotstrings/repeatcorrections.toml",
    "TODO.md",
]
sources = {p: subprocess.check_output(["git", "show", sha + ":" + p], cwd=root) for p in paths}
with tempfile.TemporaryDirectory(prefix="parity-translation-import-") as temp:
    p = pathlib.Path(temp) / "en.mjs"
    p.write_bytes(sources["src/routes/ergopti-plus/locales/en.js"])
    js = (
        "import en from "
        + json.dumps(p.as_uri())
        + "; console.log(JSON.stringify({header:en['Inventaire des réglages et fonctionnalités']??null,legend:en['✓ déclaré pour ce système']??null,control:en['Pour qui ?']??null}));"
    )
    translations = json.loads(
        subprocess.check_output(["node", "--input-type=module", "-e", js], text=True)
    )
assert translations == {"header": None, "legend": None, "control": "Who for?"}
linux = sources["static/ergopti_plus/linux/ergopti_hotstrings.lua"].decode()
assert "if one_character and _undoable and not opts.dry_run then" in linux
assert (
    "injector.inject(remaining - 1, undo.trigger, undo.is_private, nil, undo.destination)" in linux
)
assert all(
    "backspace_restore" not in sources[p].decode() for p in paths if p.endswith("-inventory.json")
)
corpus = json.loads(
    sources["static/ergopti_plus/_shared/tests/corpus/hotstrings/repeat_key_vectors.json"]
)
assert len(corpus["vectors"]) == 19
result = {
    "audited_sha": sha,
    "basis": "actual JS module import plus authenticated source review; no AHK/native desktop execution",
    "translation_observation": translations,
    "repeat_corpus_vectors": 19,
    "repeat_corpus_scope": "pure decision/single repeat; no consecutive-owner publication coverage",
    "backspace_owner": "Linux Main only; corpus is not proof of native receiving",
    "sources": {p: hashlib.sha256(v).hexdigest() for p, v in sources.items()},
}
print(json.dumps(result, indent=2))
