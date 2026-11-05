"""Authenticate Windows CapsWord source relationships without executing AutoHotkey."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tomllib

PIN = "f2a7dba5fc580aad61e6a0ed16ede84406aed2b0"
PREFIX = "static/ergopti_plus/windows/"
FILES = [
    "modules/shortcuts/capsword.ahk",
    "modules/shortcuts/capsword_auto_off.ahk",
    "infra/capsword_state.ahk",
    "infra/hook_dispatcher.ahk",
    "infra/lifecycle.ahk",
    "infra/error_net.ahk",
    "infra/hotstrings/hotstring_buffer_effects.ahk",
    "infra/hotstrings/hotstring_dispatch.ahk",
    "infra/hotstrings/hotstring_send.ahk",
    "platform/remap/constants.ahk",
    "platform/remap/space.ahk",
    "platform/remap/tab.ahk",
    "platform/remap/altgr.ahk",
    "platform/remap/capslock.ahk",
    "platform/remap/one_shot_shift.ahk",
    "platform/remap/tap_hold_loader.ahk",
    "modules/gestures/actions.ahk",
    "modules/keymap/layout.ahk",
    "adapters/text_sender.ahk",
    "adapters/editor_replace.ahk",
    "adapters/key_state.ahk",
    "ui/menu/menu_shortcuts.ahk",
    "ErgoptiPlus.ahk",
    "tests/unit/modules/shortcuts/test_capsword_auto_off.ahk",
    "tests/unit/modules/shortcuts/test_capsword_auto_off_ownership.ahk",
    "tests/unit/modules/shortcuts/test_capsword_state.ahk",
    "tests/unit/platform/remap/keys/test_capsword_taphold_unlatch.ahk",
    "tests/meta/modules/shortcuts/test_capsword_auto_off_single_source.ahk",
]
SHARED = [
    "static/ergopti_plus/_shared/modules/features/manifest.toml",
    "static/ergopti_plus/_shared/modules/features/caps_word_auto_off_policy.ahk",
    "static/ergopti_plus/_shared/modules/actions/actions.toml",
    "static/ergopti_plus/_shared/tap_hold/defaults.toml",
]


def executable(source):
    """Mask strings/comments while keeping brace positions in the original text."""
    chars = list(source)
    quote = None
    comment = False
    index = 0
    while index < len(source):
        char = source[index]
        if comment:
            if char == "\n":
                comment = False
            else:
                chars[index] = " "
        elif quote:
            chars[index] = " " if char != "\n" else char
            if char == "`" and index + 1 < len(source):
                index += 1
                chars[index] = " "
            elif char == quote:
                quote = None
        elif char in "\"'":
            quote = char
            chars[index] = " "
        elif char == ";":
            comment = True
            chars[index] = " "
        index += 1
    assert not quote, "The source lexer encountered an unterminated string"
    return "".join(chars)


def body(source, name):
    """Require one real declaration and its matched, nonempty executable body."""
    masked = executable(source)
    matches = list(
        re.finditer(r"(?m)^\s*(?:static\s+)?" + re.escape(name) + r"\s*\([^\n]*\)\s*\{", masked)
    )
    assert len(matches) == 1, (name, len(matches))
    start = masked.index("{", matches[0].start())
    depth = 1
    end = start + 1
    while depth:
        assert end < len(masked), name
        if masked[end] == "{":
            depth += 1
        elif masked[end] == "}":
            depth -= 1
        end += 1
    assert masked[start + 1 : end - 1].strip(), name
    return source[start + 1 : end - 1]


def main():
    """Print checks whose truth is limited to authenticated source structure."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", type=Path)
    parser.add_argument("--sweep", default="root")
    args = parser.parse_args()
    root = args.repository.resolve()
    sources = {}
    receipts = []
    for name in [PREFIX + relative for relative in FILES] + SHARED:
        raw = (root / name).read_bytes()
        pinned = subprocess.check_output(["git", "show", f"{PIN}:{name}"], cwd=root)
        assert raw == pinned, f"A claimed source changed after review: {name}"
        sources[name] = raw.decode("utf-8-sig")
        receipts.append({"path": name, "sha256": hashlib.sha256(raw).hexdigest()})

    def source(relative):
        return sources[PREFIX + relative]

    def function(relative, name):
        return body(source(relative), name)

    checks = []

    def check(name, condition):
        assert condition, name
        checks.append({"name": name, "passed": True, "basis": "source"})

    policy_source = sources[SHARED[0]]
    manifest = tomllib.loads(policy_source)
    settings = next(
        entry["caps_word"] for entry in manifest["features"]["shortcuts"] if "caps_word" in entry
    )
    idle = next(row for row in settings if row["id"] == "idle_timeout_seconds")
    delimiters = next(row for row in settings if row["id"] == "terminators")
    check(
        "Shared defaults:10 seconds, eight typed delimiters, all three platforms",
        idle["default"] == 10
        and len(delimiters["default"]) == 8
        and idle["platforms"] == ["ahk", "hs", "linux"],
    )
    check(
        "Shared contract names actual typed character regardless source key/layer",
        "matches the character typed, whatever key" in policy_source
        and "ends CapsWord only while its own" in policy_source,
    )
    actions = tomllib.loads(sources[SHARED[2]])["sg_actions"]
    check(
        "Backspace and Enter are real all-platform unmodified keystroke actions",
        actions["backspace"]["platform"] == "all"
        and actions["backspace"]["emit_ahk_key"] == "BackSpace"
        and actions["enter"]["emit_ahk_key"] == "Enter"
        and actions["enter"]["emit_ahk_mods"] == [],
    )
    check(
        "CapsWord action is declared for Windows/Linux with macOS equivalent",
        actions["caps_word"]["platform"] == "ahk,linux"
        and actions["caps_word"]["equivalent_hs"] == ["capsword"],
    )
    loader = function("platform/remap/tap_hold_loader.ahk", "TapHoldEntryHasKnownAction")
    check(
        "Tap loader accepts live catalogue actions rather than only native physical key",
        'GESTURE_ACTIONS.Has(Entry["tap_action"])' in loader,
    )
    space = function("platform/remap/space.ahk", "_SpaceDispatch")
    check(
        "Space's custom action enters the generic tap-action path",
        'TapHoldTapAction(TapHold, "space")' in space
        and 'TapHoldDispatchTap("space", _SpaceTap)' in space
        and '_TapHoldFireAction("space")' in space,
    )
    tab = function("platform/remap/tab.ahk", "_TabDispatch")
    check(
        "Tab custom tap-only action reaches generic physical-tab dispatch",
        'TapHoldTapAction(TapHold, "tab")' in tab
        and '_TapHoldFireAction("tab")' in tab
        and 'TapHoldHoldModifier(TapHold, "tab") == ""' in source("platform/remap/tab.ahk"),
    )
    check(
        "An empty AI tooltip declines Tab acceptance before configured dispatch",
        'if LLM_Tooltip_GetText() == ""'
        in function("platform/remap/tab.ahk", "_TabAcceptVisiblePrediction")
        and "return false" in function("platform/remap/tab.ahk", "_TabAcceptVisiblePrediction"),
    )
    capslock = function("platform/remap/capslock.ahk", "_CapsLockInvokeTap")
    check(
        "CapsLock configured Enter takes generic branch without genuine CapsLock toggle",
        'action == "caps_lock" or action == "toggle_capslock"' in capslock
        and '_TapHoldInvokeConfiguredAction("caps_lock")' in capslock
        and "DisableCapsWord" not in executable(capslock),
    )
    check(
        "Native CapsWord delimiter bindings do not intercept physical Tab or CapsLock",
        "SC039::" in source("modules/shortcuts/capsword.ahk")
        and "SC01C::" in source("modules/shortcuts/capsword.ahk")
        and "SC00F::" not in source("modules/shortcuts/capsword.ahk")
        and "SC03A::" not in source("modules/shortcuts/capsword.ahk"),
    )
    fire = function("platform/remap/constants.ahk", "_TapHoldFireAction")
    check(
        "Generic tap forwards original physical carrier id into guarded dispatcher",
        "TapHoldDispatchTap(KeyId, _TapHoldInvokeConfiguredAction.Bind(KeyId))" in fire,
    )
    dispatch = function("platform/remap/constants.ahk", "TapHoldDispatchTap")
    check(
        "Tap guard rejects suspended/activity-cancelled presses before deactivation",
        dispatch.index("if A_IsSuspended") < dispatch.index("_TapHoldTapEndsCapsWord(KeyId)")
        and dispatch.index('if (CancelReason != "")')
        < dispatch.index("_TapHoldTapEndsCapsWord(KeyId)"),
    )
    check(
        "CW-W001:CapsWord deactivation precedes configured output callback",
        dispatch.index("_TapHoldTapEndsCapsWord(KeyId)")
        < dispatch.index("DisableCapsWord()")
        < dispatch.index("try TapFn.Call()"),
    )
    predicate = function("platform/remap/constants.ahk", "_TapHoldTapEndsCapsWord")
    check(
        "CW-W001:predicate asks physical KeyId,not configured action or sent key",
        "CapsWordAutoOffIsTerminatorKey(KeyId)" in predicate
        and "CapsWordAutoOffEndsOnNativeKey(KeyId)" in predicate
        and "TapHoldTapAction" not in executable(predicate),
    )
    invoke = function("platform/remap/constants.ahk", "_TapHoldInvokeConfiguredAction")
    check(
        "Configured action resolves its own emitted key after physical-id decision",
        "ActionId := TapHoldTapAction(TapHold, KeyId)" in invoke
        and "TapHoldEmitKeyTap(Action.Key, Action.Mods)" in invoke,
    )
    check(
        "Pure CapsWord toggle flips current state and synchronizes native CapsLock",
        "global CapsWordEnabled := not CapsWordEnabled"
        in function("infra/capsword_state.ahk", "CapsWordActivationToggle")
        and "SetCapsLockState(State)"
        in function("infra/capsword_state.ahk", "_CapsWordDefaultPorts"),
    )
    check(
        "Pure deactivation clears state before disarming and native state sync",
        "global CapsWordEnabled := False"
        in function("infra/capsword_state.ahk", "CapsWordDeactivate"),
    )
    altgr = function("platform/remap/altgr.ahk", "_AltGrHandleHold")
    check(
        "CW-W002:an accepted isolated AltGr tap unconditionally disables before dispatch",
        'if (Result["tap"] and TapHoldPriorKeyIsSelf("alt_gr"))' in altgr
        and altgr.index("DisableCapsWord()") < altgr.index("AltGrTapHoldDispatchV2()"),
    )
    check(
        "AltGr dispatch uses its configured generic action",
        '_TapHoldFireAction("alt_gr")'
        in function("platform/remap/altgr.ahk", "AltGrTapHoldDispatchV2"),
    )
    check(
        "Real Windows catalogue CapsWord action invokes ToggleCapsWord",
        re.search(
            r'"caps_word",\s*\{\s*Fn:\s*\(\*\)\s*=>\s*ToggleCapsWord\(\)',
            source("modules/gestures/actions.ahk"),
        )
        is not None,
    )
    check(
        "Existing tap regression passes marker callback rather than emitted action",
        "TapHoldDispatchTap(KeyId, (*) => (Ran := true))"
        in function(
            "tests/unit/platform/remap/keys/test_capsword_taphold_unlatch.ahk", "_CTU_DispatchWith"
        ),
    )
    sender = function("adapters/text_sender.ahk", "TextPressKey")
    tap = function("platform/remap/constants.ahk", "TapHoldEmitKeyTap")
    check(
        "Non-Tab keystroke tap emits its action key through TextPressKey",
        "return TextPressKey(Key, Modifiers)" in tap
        and 'return _TextSenderSendInput("{" . Key . "}", "key press")' in sender,
    )
    check(
        "Synthetic key sender runs level0; real dispatcher ignores that level",
        "global TEXT_SENDER_SEND_LEVEL := 0" in source("adapters/text_sender.ahk")
        and 'INPUT_HOOK_OPTS := "V L0 I1"' in source("infra/hook_dispatcher.ahk"),
    )
    check(
        "Synthetic key funnel/commit does not publish CapsWord literal output",
        "CapsWordAutoOffObserveOutput"
        not in executable(function("adapters/text_sender.ahk", "_TextSenderSendInput"))
        and "CapsWordAutoOffObserveOutput"
        not in executable(
            function("infra/hotstrings/hotstring_buffer_effects.ahk", "HS_CommitSyntheticEffect")
        ),
    )
    store = function("modules/shortcuts/capsword_auto_off.ahk", "CapsWordAutoOffStore")
    publish = function("modules/shortcuts/capsword_auto_off.ahk", "_CapsWordAutoOffPublish")
    check(
        "Setting write must succeed before next-activation policy publication",
        store.index("ConfigCommitUpdates(") < store.index("_CapsWordAutoOffPublish("),
    )
    check(
        "Documented config snapshot:publication changes Configured,not Armed or timers",
        "CapsWordAutoOff.Configured := Policy" in publish
        and "CapsWordAutoOff.Armed :=" not in executable(publish)
        and "SetTimer" not in executable(publish)
        and "TimerArmOneShotMs" not in executable(publish),
    )
    arm = function("modules/shortcuts/capsword_auto_off.ahk", "CapsWordAutoOffArm")
    check(
        "Activation snapshots configured policy and subscribes key-down only for nonzero idle",
        "CapsWordAutoOff.Armed := Policy" in arm and 'if Policy["idle_ms"] > 0' in arm,
    )
    check(
        "Every keyboard key-down rearms armed idle period",
        'TimerArmOneShotMs(_CapsWordAutoOffCallbacks()["idle"], CapsWordAutoOff.Armed["idle_ms"])'
        in function("modules/shortcuts/capsword_auto_off.ahk", "_CapsWordAutoOff_OnKeyDown"),
    )
    check(
        "Old callbacks require exact generation before borrowing active owner",
        "Generation != CapsWordAutoOff.Generation"
        in function("modules/shortcuts/capsword_auto_off.ahk", "_CapsWordAutoOffActive"),
    )
    end = function("modules/shortcuts/capsword_auto_off.ahk", "_CapsWordAutoOffEnd")
    check(
        "Retirement precedes logging; terminal callback rechecks its own retired generation",
        end.index("CapsWordAutoOffDisarm(Generation)")
        < end.index("LoggerInfo(")
        < end.index("CapsWordAutoOff.Generation == Retired"),
    )
    native = function("modules/shortcuts/capsword_auto_off.ahk", "CapsWordAutoOffNativeKey")
    check(
        "Native delimiter carries original generation across send/wait finally",
        "Generation := CapsWordAutoOff.Generation" in native
        and '_CapsWordAutoOffEnd(Generation, "native " . Key)' in native
        and "STUCK_MODIFIER_RELEASE_TIMEOUT_SEC" in native,
    )
    check(
        "Dispatcher gates all event callbacks while suspended",
        re.search(
            r"if A_IsSuspended\s+return", body(source("infra/hook_dispatcher.ahk"), "Dispatch")
        )
        is not None,
    )
    check(
        "Suspend explicitly deactivates CapsWord through required lifecycle step",
        '_LifecycleRunRequiredStep(Transition, "caps-word", () => DisableCapsWord())'
        in source("infra/lifecycle.ahk"),
    )
    check(
        "Genuine CapsLock intent seeded before write-owning includes",
        source("ErgoptiPlus.ahk").index("global _HardwareCapsLockOn := KS_CapsLockToggleState()")
        < source("ErgoptiPlus.ahk").index("#Include infra/capsword_state.ahk"),
    )
    check(
        "Native CapsLock intent flips recorded intent,not own LED feedback",
        "_HardwareCapsLockOn := !_HardwareCapsLockOn"
        in function("platform/remap/one_shot_shift.ahk", "ToggleCapsLock")
        and "GetKeyState("
        not in executable(function("platform/remap/one_shot_shift.ahk", "ToggleCapsLock")),
    )
    check(
        "Pointer scroll maps to pointer_motion and five declared Windows kinds",
        all(
            token
            in function("modules/shortcuts/capsword_auto_off.ahk", "CapsWordAutoOffPointerEvents")
            for token in [
                '"left_click"',
                '"right_click"',
                '"middle_click"',
                '"other_buttons"',
                '"pointer_motion"',
            ]
        ),
    )
    check(
        "Motion poll ignores unchanged coordinates and suspended state",
        "Position == CapsWordAutoOff.LastPointer"
        in function("modules/shortcuts/capsword_auto_off.ahk", "_CapsWordAutoOff_OnMotionPoll")
        and "A_IsSuspended"
        in function("modules/shortcuts/capsword_auto_off.ahk", "_CapsWordAutoOff_OnMotionPoll"),
    )
    check(
        "Typed callback evaluates entire payload through shared character policy",
        "CapsWordAutoOffEndsOnText(CapsWordAutoOff.Armed, Char)"
        in function("modules/shortcuts/capsword_auto_off.ahk", "_CapsWordAutoOff_OnChar"),
    )
    check(
        "Literal driver-output observer evaluates same armed delimiter policy",
        "CapsWordAutoOffEndsOnText(CapsWordAutoOff.Armed, Text)"
        in function("modules/shortcuts/capsword_auto_off.ahk", "CapsWordAutoOffObserveOutput"),
    )
    print(
        json.dumps(
            {
                "audited_sha": PIN,
                "sweep": args.sweep,
                "basis": "source",
                "qualification": "Python authenticates exact Git bytes and lexical relationships only. No AHK, native CapsLock, keyboard, editor or wall-clock behavior executed.",
                "sources": receipts,
                "checks": checks,
                "check_count": len(checks),
                "program_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
