"""Authenticate the separate CapsWord consumer-extension source and refutations."""

import argparse
import hashlib
import json
from pathlib import Path
import subprocess

PIN = "f2a7dba5fc580aad61e6a0ed16ede84406aed2b0"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("repository", type=Path)
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
paths = [
    "static/ergopti_plus/linux/ergopti_hotstrings.lua",
    "static/ergopti_plus/linux/modules/shortcuts/manager.lua",
    "static/ergopti_plus/linux/modules/shortcuts/caps_word_auto_off.lua",
    "static/ergopti_plus/linux/modules/shortcuts/action_handlers.lua",
    "static/ergopti_plus/linux/modules/shortcuts/keyboard_shortcuts.lua",
    "static/ergopti_plus/linux/modules/gestures/manager.lua",
    "static/ergopti_plus/linux/modules/gestures/combo_emitter.lua",
    "static/ergopti_plus/linux/modules/hotstrings/injector.lua",
    "static/ergopti_plus/linux/platform/remap/tap_hold_engine.lua",
    "static/ergopti_plus/linux/platform/remap/tap_hold_manager.lua",
    "static/ergopti_plus/linux/adapters/keyboard_hook.lua",
    "static/ergopti_plus/linux/adapters/keyboard_layout.lua",
    "static/ergopti_plus/linux/adapters/xkb_capture.lua",
    "static/ergopti_plus/linux/adapters/uinput_writer.lua",
    "static/ergopti_plus/linux/adapters/modifier_broker.lua",
    "static/ergopti_plus/linux/adapters/evdev_reader.lua",
    "static/ergopti_plus/linux/infra/input_event.lua",
    "static/ergopti_plus/linux/modules/hotstrings/word_reset.lua",
    "static/ergopti_plus/linux/_generated/gesture_emit_actions.lua",
    "static/ergopti_plus/_shared/lua/caps_word/auto_off.lua",
    "static/ergopti_plus/_shared/modules/features/manifest.toml",
    "static/ergopti_plus/_shared/modules/actions/actions.toml",
    "docs/audits/platform-parity/2026-11-05-word-reset/linux/findings.json",
]
rows = []
texts = {}
for path in paths:
    data = (args.repository / path).read_bytes()
    pinned = subprocess.check_output(["git", "show", f"{PIN}:{path}"], cwd=args.repository)
    assert data == pinned, path
    rows.append({"path": path, "sha256": hashlib.sha256(data).hexdigest()})
    texts[path] = data.decode("utf-8-sig")
main = texts[paths[0]]
catalogue = texts[paths[5]]
emitter = texts[paths[6]]
injector = texts[paths[7]]
tap = texts[paths[8]]
prior = json.loads(texts[paths[-1]])
assert prior["findings"][0]["id"] == "WRSL-001"
assert "WordReset/engine notification" in prior["findings"][0]["root_cause"]
branch = catalogue.split("local emit_combo = MODIFIER_ACTION_COMMANDS[action_name]", 1)[1].split(
    "local handler = _action_handlers[action_name]", 1
)[0]
assert len(branch) > 300 and "_press_combo(emit_combo)" in branch
assert "caps_word_observe" not in branch
assert "caps_word_observe" not in emitter and "output_observer" not in emitter
assert "M.KEY_TAPS = { enter = 28, tab = 15," in tap
assert "if result.ok then notify_output(text) end" in injector
assert "injector.set_output_observer(function(text)" in main
assert "shortcuts.caps_word_observe_text(text)" in main
callback = main.split("execute_action = function(action, binding)", 1)[1].split("\n\t\tend,", 1)[0]
assert len(callback) > 300 and "WordReset.apply_tap_action(engine, binding)" in callback
assert "caps_word_observe" not in callback
checks = [
    "Existing WRSL-001 identifies the same catalogue-output publication connector for the arrow/word/AI consumer.",
    "Nonempty original generic emission branch reaches ComboEmitter without CapsWord publication.",
    "Original emitter has no CapsWord/output observer publication hook.",
    "Ordinary tap Enter/Tab are KEY_TAPS native rows, refuting generalization to generic tap callbacks.",
    "Actual literal injector output notifies its owner; Main source forwards that text to CapsWord.",
    "Main generic tap callback applies WordReset, not an additional CapsWord notification; ordinary KEY_TAPS do not use this path.",
]
args.output.write_text(
    json.dumps(
        {
            "audited_sha": PIN,
            "sources": rows,
            "checks": checks,
            "qualification": "Scoped full-file source authentication and qualified lexical wiring checks. Actual Main closures, native compositor receiving and arbitrary layouts are not executed.",
        },
        indent=2,
    )
    + "\n"
)
print(f"Authenticated {len(rows)} files and {len(checks)} qualified source relationships.")
