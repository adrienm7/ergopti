"""Authenticate scoped Linux CapsWord source and positive wiring relationships."""

import argparse
import hashlib
import json
from pathlib import Path
import re
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
    "static/ergopti_plus/linux/adapters/keyboard_hook.lua",
    "static/ergopti_plus/linux/adapters/xkb_capture.lua",
    "static/ergopti_plus/linux/adapters/uinput_writer.lua",
    "static/ergopti_plus/linux/adapters/modifier_broker.lua",
    "static/ergopti_plus/linux/adapters/evdev_reader.lua",
    "static/ergopti_plus/linux/adapters/event_loop.lua",
    "static/ergopti_plus/linux/infra/input_event.lua",
    "static/ergopti_plus/linux/infra/evdev_codes.lua",
    "static/ergopti_plus/linux/infra/monotonic.lua",
    "static/ergopti_plus/linux/infra/hotstring_preferences.lua",
    "static/ergopti_plus/linux/infra/manifest_reader.lua",
    "static/ergopti_plus/linux/infra/manifest_menu.lua",
    "static/ergopti_plus/linux/modules/gestures/combo_emitter.lua",
    "static/ergopti_plus/linux/modules/hotstrings/device_finder.lua",
    "static/ergopti_plus/linux/modules/hotstrings/injector.lua",
    "static/ergopti_plus/linux/modules/hotstrings/magic_key.lua",
    "static/ergopti_plus/linux/modules/hotstrings/hotstrings_config.lua",
    "static/ergopti_plus/linux/ui/menu/menu_shortcuts.lua",
    "static/ergopti_plus/linux/ui/menu/builder.lua",
    "static/ergopti_plus/_shared/lua/caps_word/auto_off.lua",
    "static/ergopti_plus/_shared/lua/keymap/terminators.lua",
    "static/ergopti_plus/_shared/lua/keymap/terminators_catalogue.lua",
    "static/ergopti_plus/_shared/modules/features/manifest.toml",
    "static/ergopti_plus/_shared/tests/corpus/caps_word/auto_off_vectors.json",
]
rows = []
texts = {}
for name in paths:
    data = (args.repository / name).read_bytes()
    pinned = subprocess.check_output(["git", "show", f"{PIN}:{name}"], cwd=args.repository)
    assert data == pinned, name
    texts[name] = data.decode("utf-8-sig")
    rows.append({"path": name, "sha256": hashlib.sha256(data).hexdigest()})
hook = texts[paths[3]]
main = texts[paths[0]]
manager = texts[paths[1]]
settings = texts[paths[2]]
menu = texts[paths[20]]
body = hook.split("local function _dispatch_pointer(ev, slot)", 1)[1].split(
    "local function _read_source(source)", 1
)[0]
assert len(body) > 1000 and "if ev.type == InputEvent.EV_REL then" in body
assert '_on_pointer_event, "motion", ev.code, ev.value' in body
assert "EV_ABS" not in body
forward = main.split("local function on_pointer_event(kind_of_event, code, value)", 1)[1].split(
    "\n\tend", 1
)[0]
assert len(forward) > 100 and 'if kind_of_event == "frame" then return end' in forward
assert "shortcuts.caps_word_observe_pointer_event(kind_of_event, code)" in forward
assert "_caps_word_policy, _caps_word_last_ms = policy, Monotonic.now_ms()" in manager
assert "_settings, _policy = settings, policy" in settings
assert "applies to the CapsWord running now from its next event" in menu
assert "changed(AutoOff.set_pointer(kind, not settings.pointer[kind]))" in menu
assert "changed(AutoOff.set_terminator(key, not checked[key]))" in menu
assert "changed(AutoOff.set_idle_timeout_seconds(seconds))" in menu
checks = [
    "nonempty original pointer dispatch includes relative motion publication and omits absolute motion handling",
    "nonempty Main pointer callback forwards actual kinds and ignores report frames",
    "activation retains one policy object while settings publish replacement objects",
    "actual menu explicitly promises current-session application at its next event",
    "actual menu calls the actual public settings setters for all three setting families",
]
abi = {
    "qualification": "Linux UAPI constants corroborated against this host header, outside the audited Git source."
}
header = Path("/usr/include/linux/input-event-codes.h")
if header.is_file():
    data = header.read_bytes()
    text = data.decode()
    values = {"EV_ABS": 3, "ABS_X": 0, "ABS_Y": 1, "BTN_TOUCH": 0x14A}
    for name, value in values.items():
        literal = re.search(r"^#define\s+" + name + r"\s+(0x[0-9a-fA-F]+|[0-9]+)\b", text, re.M)
        assert literal and int(literal.group(1), 0) == value, name
    abi.update(path=str(header), sha256=hashlib.sha256(data).hexdigest(), constants=values)
args.output.write_text(
    json.dumps(
        {
            "audited_sha": PIN,
            "sources": rows,
            "checks": checks,
            "external_kernel_abi": abi,
            "qualification": "Selected source files only, not transitive whole-repository coverage. Source checks support public wiring; pointer/Main native receiving remains unexecuted.",
        },
        indent=2,
    )
    + "\n"
)
print(f"Authenticated {len(rows)} scoped source files and {len(checks)} wiring contracts.")
