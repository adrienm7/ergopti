"""Authenticate exact one-shot contracts; this program does not execute AHK."""

import hashlib
import json
from pathlib import Path
import subprocess
import sys

PIN = "9c565c88c9a1366a2e9b18c1b9d2868509510975"
root = Path(sys.argv[1]).resolve()
paths = [
    "static/ergopti_plus/_shared/tap_hold/one_shot_shift.json",
    "static/ergopti_plus/_shared/lua/tap_hold/one_shot_shift.lua",
    "static/ergopti_plus/_shared/lua/unicode_case/init.lua",
    "static/ergopti_plus/_shared/lua/unicode_case/data.lua",
    "static/ergopti_plus/_shared/lua/keymap/terminators.lua",
    "static/ergopti_plus/_shared/lua/keymap/terminators_catalogue.lua",
    "static/ergopti_plus/_shared/modules/actions/actions.toml",
    "static/ergopti_plus/_shared/tap_hold/defaults.toml",
    "static/ergopti_plus/_shared/modules/timings/constants.toml",
    "static/ergopti_plus/_shared/core/config_schema/config_key_extras.json",
    "static/ergopti_plus/_shared/modules/features/manifest.toml",
    "static/ergopti_plus/_shared/modules/menu/menu.toml",
    "static/ergopti_plus/windows/platform/remap/one_shot_shift.ahk",
    "static/ergopti_plus/windows/platform/remap/tap_hold_loader.ahk",
    "static/ergopti_plus/windows/platform/remap/constants.ahk",
    "static/ergopti_plus/windows/infra/sticky_modifiers.ahk",
    "static/ergopti_plus/windows/infra/suppressive_inputhook_ownership.ahk",
    "static/ergopti_plus/linux/platform/remap/tap_hold_manager.lua",
    "static/ergopti_plus/linux/platform/remap/tap_hold_engine.lua",
    "static/ergopti_plus/linux/ui/menu/menu_tap_holds.lua",
    "static/ergopti_plus/linux/modules/shortcuts/keyboard_shortcuts.lua",
    "static/ergopti_plus/macos/modules/keymap/one_shot_shift.lua",
    "static/ergopti_plus/macos/adapters/one_shot_shift.lua",
    "static/ergopti_plus/macos/modules/keymap/init.lua",
    "static/ergopti_plus/macos/platform/remap/defaults.lua",
    "static/ergopti_plus/macos/platform/remap/init.lua",
    "static/ergopti_plus/macos/platform/remap/config.lua",
    "static/ergopti_plus/macos/ui/menu/menu_tap_holds.lua",
    "static/ergopti_plus/macos/modules/gestures/actions.lua",
    "static/ergopti_plus/macos/modules/gestures/sticky_modifiers.lua",
    "static/ergopti_plus/macos/tests/unit/modules/keymap/synthetic/test_one_shot_shift.lua",
    "tools/test/test-tap-hold-one-shot-results-single-source.cjs",
    "tools/test/test-tap-hold-namespace-correspondence.cjs",
    "tools/codegen/codegen-feature-inventory.cjs",
    "tools/build/build-features-manifest.js",
    "src/routes/ergopti-plus/action-inventory.json",
]
paths += [
    path.relative_to(root).as_posix()
    for path in sorted((root / "static/ergopti_plus/_shared/data/locales").glob("*.json"))
]
texts = {}
sources = []
for path in paths:
    data = (root / path).read_bytes()
    pinned = subprocess.check_output(["git", "show", f"{PIN}:{path}"], cwd=root)
    if data != pinned:
        raise ValueError(f"Named source changed: {path}")
    texts[path] = data.decode("utf-8-sig")
    sources.append({"path": path, "sha256": hashlib.sha256(data).hexdigest()})


def text(suffix):
    """Refuse missing/ambiguous source names rather than scanning empty text."""
    matches = [value for path, value in texts.items() if path.endswith(suffix)]
    if len(matches) != 1 or not matches[0].strip():
        raise ValueError(f"Nonunique/nonempty source required: {suffix}")
    return matches[0]


checks = []


def check(condition, name):
    """Retain exact lexical relationships without calling them driver execution."""
    if not condition:
        raise ValueError(name)
    checks.append(name)


win = text("windows/platform/remap/one_shot_shift.ahk")
loader = text("windows/platform/remap/tap_hold_loader.ahk")
policy = text("_shared/lua/tap_hold/one_shot_shift.lua")
linux = text("linux/platform/remap/tap_hold_manager.lua")
state = text("macos/modules/keymap/one_shot_shift.lua")
check("OneShotShift() {" in win and "SIHO_StartOwned(" in win, "Windows public capture exists")
check(
    "TapHoldOneShotResult(Scalar, MagicKey)" in win,
    "Windows delegates full-scalar result selection",
)
check(
    loader.index('if (MagicKey != "" && EndKey == MagicKey)')
    < loader.index('if Table["results"].Has(EndKey)'),
    "Windows magic lookup precedes special lookup",
)
check(
    "static Cached" not in win and "_TapHoldOneShotTable()" in win,
    "Windows preloads its loader-owned catalogue",
)
check(
    "local set = { one_shot_shift = true }" in linux,
    "Linux tap namespace explicitly includes reserved single-use Shift",
)
check("tap_hold/one_shot_shift.json" in linux, "Linux reads the shared result file")
check(
    'if char == require("modules.hotstrings.magic_key").get()' in linux,
    "Linux asks the live magic owner",
)
check(
    'require("tap_hold.one_shot_shift")' in text("linux/platform/remap/tap_hold_engine.lua")
    and 'require("tap_hold.one_shot_shift")' in state,
    "Both Lua state consumers use the shared resolver",
)
check(
    "backspace = true, enter = true, delete = true, tab = true, escape = true" in policy,
    "Five editing controls share spend-without-shifting declaration",
)
check(
    "now_ms <= self.one_shot_until" in text("linux/platform/remap/tap_hold_engine.lua")
    and "now <= self.deadline" in state,
    "Lua owners use inclusive deadline comparison",
)
check(
    "results[entry.char] == nil" in state, "Mac actual owner rejects duplicate catalogue characters"
)
check(
    "OneShot.new(data)"
    in text("macos/tests/unit/modules/keymap/synthetic/test_one_shot_shift.lua"),
    "Registered Mac real-data unit invokes the actual validating owner",
)
check(
    "ONE_SHOT_SHIFT_TIMEOUT_SEC : 2" in win,
    "Windows fallback for an uninitialized/nonpositive constant is two seconds",
)
check(
    "value <= 0" in text("macos/platform/remap/init.lua")
    and "timeout_ms > 0" in text("macos/modules/keymap/init.lua"),
    "Mac source setter/arm contracts require positive timeout",
)
check(
    'reason_linux = "platform_reason.action_sticky_keys_are_the_systems"'
    in text("_shared/modules/actions/actions.toml"),
    "Action catalogue declares Linux system-sticky alternative, not its tap-only path",
)
one_shot_body = win[win.index("OneShotShift() {") : win.index("\nOneShotShiftFix() {")]
check(
    "SIHO_StartOwned(" in one_shot_body and "DisableCapsWord" not in one_shot_body,
    "Windows OneShotShift body does not own its sibling ToggleCapsLock CapsWord clear",
)
print(
    json.dumps(
        {
            "audited_sha": PIN,
            "sources": sources,
            "checks": checks,
            "qualification": "Named pinned/current source bytes and lexical relationships only. Actual shared policy, model and state execution are separate probes; no AHK or native desktop execution.",
        },
        indent="\t",
    )
)
