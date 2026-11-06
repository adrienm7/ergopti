"""Authenticate single-use Shift source without executing or emulating AutoHotkey."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tomllib

PIN = "9c565c88c9a1366a2e9b18c1b9d2868509510975"
PREFIX = "static/ergopti_plus/windows/"
FILES = [
    "platform/remap/one_shot_shift.ahk",
    "infra/suppressive_inputhook_ownership.ahk",
    "platform/remap/tap_hold_loader.ahk",
    "platform/remap/constants.ahk",
    "platform/remap/lalt.ahk",
    "platform/remap/rctrl.ahk",
    "platform/remap/enter.ahk",
    "modules/gestures/actions.ahk",
    "infra/key_combinations.ahk",
    "infra/sticky_modifiers.ahk",
    "infra/hotstrings/hotstring_send.ahk",
    "infra/hotstrings/hotstring_engine.ahk",
    "adapters/text_sender.ahk",
    "adapters/key_state.ahk",
    "modules/keymap/layout.ahk",
    "infra/boot.ahk",
    "infra/lifecycle.ahk",
    "ErgoptiPlus.ahk",
    "tests/meta/platform/remap/keys/test_oneshotshift_endkeys.ahk",
    "tests/meta/platform/remap/keys/test_oneshotshift_lalt_lshift_stuck.ahk",
    "tests/meta/platform/remap/keys/test_oneshotshift_suspend_guard.ahk",
    "tests/meta/platform/remap/keys/test_rctrl_lalt_hotif_gated.ahk",
    "tests/unit/platform/remap/keys/test_timings_config.ahk",
    "tests/unit/adapters/input/test_one_shot_rearm_admission.ahk",
    "tests/fixtures/one_shot_rearm_admission_body.ahk",
    "tests/fixtures/suppressive_capture_settlement_body.ahk",
    "tests/fixtures/suppressive_capture_unicode_body.ahk",
]
SHARED = [
    "static/ergopti_plus/_shared/tap_hold/one_shot_shift.json",
    "static/ergopti_plus/_shared/lua/tap_hold/one_shot_shift.lua",
    "static/ergopti_plus/_shared/modules/timings/constants.toml",
    "static/ergopti_plus/_shared/modules/actions/actions.toml",
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


def reader_controls():
    """Reject empty, missing, malformed or ambiguous source before absence checks."""
    rows = []
    assert "return" in body('Real() {\n return "} ; {" ; comment }\n}', "Real")
    rows.append({"name": "literal-and-comment-braces", "passed": True})
    for name, source in [
        ("missing", "Other() { return 1 }"),
        ("empty", "Real() { ; empty\n}"),
        ("unclosed", "Real() { return 1"),
        ("duplicate", "Real() { return 1 }\nReal() { return 2 }"),
    ]:
        try:
            body(source, "Real")
        except AssertionError:
            rows.append({"name": name, "rejected": True})
        else:
            raise AssertionError(name)
    return rows


def main():
    """Print qualified lexical checks against authenticated, nonempty source."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("repository", type=Path)
    parser.add_argument("--sweep", default="root")
    args = parser.parse_args()
    root = args.repository.resolve()
    sources = {}
    receipts = []
    for name in [PREFIX + p for p in FILES] + SHARED:
        raw = (root / name).read_bytes()
        pinned = subprocess.check_output(["git", "show", f"{PIN}:{name}"], cwd=root)
        assert raw == pinned, name
        sources[name] = raw.decode("utf-8-sig")
        receipts.append({"path": name, "sha256": hashlib.sha256(raw).hexdigest()})

    def get(path):
        return sources[PREFIX + path]

    def fn(path, name):
        return body(get(path), name)

    checks = []

    def check(name, value):
        assert value, name
        checks.append({"name": name, "passed": True, "basis": "source"})

    owner = fn("platform/remap/one_shot_shift.ahk", "OneShotShift")
    fix = fn("platform/remap/one_shot_shift.ahk", "OneShotShiftFix")
    check(
        "entry refuses native suspended state before arming",
        owner.index("if A_IsSuspended") < owner.index("SIHO_StartOwned"),
    )
    check(
        "capture is exclusive and current scalar decoder based",
        'SIHO_StartOwned(ihvText, "one-shot-shift", true)' in owner
        and "_SIHO_ReadScalar(ihvText, NamedKeys)" in owner,
    )
    check(
        "positive timeout uses shared constant, otherwise finite2s",
        "ONE_SHOT_SHIFT_TIMEOUT_SEC > 0" in owner and ": 2" in owner,
    )
    check(
        "shared timeout source is2000ms",
        tomllib.loads(sources[SHARED[2]])["tap_hold"]["one_shot_shift_timeout_ms"] == 2000,
    )
    check(
        "magic key and table prepared before native capture",
        owner.index('MagicKey := ScriptInformation["MagicKey"]') < owner.index("SIHO_StartOwned")
        and owner.index("_TapHoldOneShotTable()") < owner.index("SIHO_StartOwned"),
    )
    check(
        "complete scalar capture, named controls exactly Backspace Enter Delete",
        'InputHook("L2 T"' in owner
        and "_SIHO_ScalarEndKeys()" in owner
        and 'NamedKeys := "{BackSpace}{Enter}{Delete}"' in owner
        and 'ihvText.KeyOpt(NamedKeys, "E")' in owner,
    )
    check(
        "refused rearm cannot change incumbent logical state",
        owner.index("if !OwnerToken") < owner.index("OneShotShiftEnabled := True"),
    )
    check(
        "exact-token publication and suspend guard share Critical",
        "Admitted := SIHO_IsOwned(OwnerToken, ihvText) && !A_IsSuspended" in owner
        and 'PreviousCritical := Critical("On")' in owner,
    )
    check(
        "Wait always settles exact token before dispatch",
        "CaptureSettled := SIHO_StopOwned(OwnerToken, ihvText)" in owner
        and owner.index("if !CaptureSettled") < owner.index("Capture := _SIHO_ReadScalar"),
    )
    check(
        "timeout and invalid capture do not emit",
        'if Capture.Kind == "timeout" || Capture.Kind == "invalid"' in owner,
    )
    check("invalid scalar produces warning", 'LoggerWarn("OneShotShift"' in owner)
    check(
        "named control branch replays key before text transform",
        owner.index('if Capture.Kind == "control"')
        < owner.index('SendNewResult("{" . Capture.Name . "}", False, False)')
        < owner.index("Scalar := Capture.Text"),
    )
    check(
        "OSW001 control replay lacks modifier attribution",
        'SendNewResult("{" . Capture.Name . "}", False, False)' in owner
        and "TapHoldAnyModifierHeld" not in executable(owner)
        and "TextPressKey" not in executable(owner)
        and "{Blind}" not in owner,
    )
    send = fn("infra/hotstrings/hotstring_send.ahk", "SendNewResult")
    check(
        "non-atomic nonliteral replay uses ordinary SendEvent",
        "SendNewResult(Text, OnlyText := True, UpdateRing := True, Atomic := False)"
        in get("infra/hotstrings/hotstring_send.ahk")
        and "SendEvent(Text)" in send,
    )
    check(
        "runtime primitive send hook defaults disabled",
        "global _SendHook := 0" in get("infra/hotstrings/hotstring_engine.ahk"),
    )
    blind = fn("platform/remap/constants.ahk", "_TapHoldKeyTapModifiers")
    check(
        "other native tap owner explicitly preserves held modifiers with Blind",
        "TapHoldAnyModifierHeld()" in blind
        and 'Words := "Blind"' in blind
        and "Send lifts the modifiers it did not press itself"
        in get("platform/remap/constants.ahk"),
    )
    check(
        "control completion is not an inferred Tab or Escape result",
        'NamedKeys := "{BackSpace}{Enter}{Delete}"' in owner
        and 'NamedKeys := "{BackSpace}{Enter}{Delete}{Tab}' not in owner,
    )
    check(
        "ordinary scalar path titlecases through native AHK Format",
        'Format("{:T}", Scalar)' in owner,
    )
    table = json.loads(sources[SHARED[0]])
    check(
        "shared table contains seven explicit punctuation/space replacements",
        len(table["results"]) == 7
        and {r["char"]: r["result"] for r in table["results"]}[" "] == "-",
    )
    result = fn("platform/remap/tap_hold_loader.ahk", "TapHoldOneShotResult")
    check(
        "chosen magic key result precedes fixed punctuation lookup",
        result.index("EndKey == MagicKey") < result.index('Table["results"].Has(EndKey)')
        and table["magic_key_result"] == "J",
    )
    check(
        "fixed chord cancellation changes only enable bit",
        "OneShotShiftEnabled := False" in fix and "SIHO_Stop" not in executable(fix),
    )
    check(
        "one-shot owner does not itself cancel CapsWord",
        "DisableCapsWord" not in executable(owner)
        and "DisableCapsWord" in fn("platform/remap/one_shot_shift.ahk", "ToggleCapsLock"),
    )
    check(
        "gesture catalogue directly exposes character one-shot action",
        '"one_shot_shift", {' in get("modules/gestures/actions.ahk")
        and "Fn: (*) => OneShotShift()" in get("modules/gestures/actions.ahk"),
    )
    actions = tomllib.loads(sources[SHARED[3]])["sg_actions"]
    check(
        "Windows/Linux action aliases macOS sticky Shift",
        actions["one_shot_shift"]["equivalent_hs"] == ["sticky_shift"]
        and actions["sticky_shift"]["equivalent_ahk"] == ["one_shot_shift"],
    )
    start = fn("infra/suppressive_inputhook_ownership.ahk", "SIHO_StartOwned")
    check(
        "suspended start and competing exclusivity checked inside Critical",
        "if A_IsSuspended" in start
        and 'if Exclusive || Record["exclusive"]' in start
        and 'PreviousCritical := Critical("On")' in start,
    )
    check(
        "start rollback retains failed native cleanup owner",
        "RollbackError := StopErr" in start
        and "if IsObject(RollbackError)" in start
        and "_SIHO_Owners.Delete(Token)" in start,
    )
    stop = fn("infra/suppressive_inputhook_ownership.ahk", "SIHO_StopOwned")
    unregister = fn("infra/suppressive_inputhook_ownership.ahk", "SIHO_Unregister")
    check(
        "only actual current terminal retirement permits producer output",
        "return SIHO_Unregister(Token, Hook)" in stop
        and 'if (Record["hook"] != Hook)' in unregister
        and "return false" in unregister,
    )
    read = fn("infra/suppressive_inputhook_ownership.ahk", "_SIHO_ReadScalar")
    check(
        "decoder distinguishes timeout controls complete BMP and surrogate pair",
        'Hook.EndReason == "Timeout"' in read
        and 'Result.Kind := "control"' in read
        and "Unit >= 0xDC00" in read
        and "High >= 0xD800" in read,
    )
    check(
        "named controls require exact explicit token list",
        'StrSplit(NamedKeys, ["{", "}"])' in read and 'Result.Reason := "unknown-end-key"' in read,
    )
    check(
        "shared EndChars excludes high halves but admits remaining BMP units",
        "Unit >= 0xD800 && Unit <= 0xDBFF"
        in fn("infra/suppressive_inputhook_ownership.ahk", "_SIHO_ScalarEndKeys")
        and "loop 0xFFFF" in fn("infra/suppressive_inputhook_ownership.ahk", "_SIHO_ScalarEndKeys"),
    )
    check(
        "lifecycle stop and logical latch cleanup coexist",
        "SIHO_StopAll" in get("infra/lifecycle.ahk")
        and "global OneShotShiftEnabled := False" in get("infra/lifecycle.ahk"),
    )
    check(
        "key-combination non-one-shot action cancels pending shift",
        "OneShotShiftFix()" in fn("infra/key_combinations.ahk", "_KeyCombinationRunTap")
        and 'ActionId != "one_shot_shift"'
        in fn("infra/key_combinations.ahk", "_KeyCombinationRunTap"),
    )
    check(
        "native scalar fixture refuses held modifiers",
        "Release physical modifiers and keep the explicit native fixture idle."
        in get("tests/fixtures/suppressive_capture_unicode_body.ahk"),
    )
    check(
        "named end-key regression is a source check, not modified receiving",
        '"{BackSpace}{Enter}{Delete}"'
        in get("tests/meta/platform/remap/keys/test_oneshotshift_endkeys.ahk")
        and '_DriverFuncBody("OneShotShift")'
        in get("tests/meta/platform/remap/keys/test_oneshotshift_endkeys.ahk"),
    )
    check(
        "existing rearm fixture distinguishes disabled incumbent",
        "incumbent-disabled" in get("tests/fixtures/one_shot_rearm_admission_body.ahk"),
    )
    check(
        "existing settlement fixture covers successor inserted during Stop",
        "completed-revoked" in get("tests/fixtures/suppressive_capture_settlement_body.ahk")
        and "SIHO_StartOwned" in get("tests/fixtures/suppressive_capture_settlement_body.ahk"),
    )
    dead = fn("modules/keymap/layout.ahk", "DeadKey")
    check(
        "OSW001 sibling dead-key capture replays named key without modifier attribution",
        "_SIHO_ReadScalar(ih, NamedKeys)" in dead
        and 'Send("{" . Capture.Name . "}")' in dead
        and "EndMods" not in executable(dead)
        and "{Blind}" not in dead,
    )
    check(
        "LAlt dedicated producer captures immediately then enters a bounded Shift hold",
        get("platform/remap/lalt.ahk").index("\n\tOneShotShift()\n")
        < get("platform/remap/lalt.ahk").index('if !TapHoldSyntheticKeyDown("LShift")')
        and 'KS_WaitReleased("SC038", STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)'
        in get("platform/remap/lalt.ahk")
        and 'TapHoldSyntheticKeyUp("LShift")' in get("platform/remap/lalt.ahk"),
    )
    check(
        "RCtrl dedicated producer distinguishes tap from long Shift hold",
        'TapHoldDispatchTap("right_ctrl", OneShotShift)' in get("platform/remap/rctrl.ahk")
        and 'KS_WaitReleased("SC11D", TapHoldDuration(TapHold, "right_ctrl"))'
        in get("platform/remap/rctrl.ahk")
        and 'KS_WaitReleased("SC11D", STUCK_MODIFIER_RELEASE_TIMEOUT_SEC)'
        in get("platform/remap/rctrl.ahk"),
    )
    check(
        "control decoder returns named identity without captured modifier fields",
        'Result := { Kind: "invalid", Text: "", Name: "", Reason:' in read
        and "EndMods" not in executable(read),
    )
    print(
        json.dumps(
            {
                "audited_sha": PIN,
                "sweep": args.sweep,
                "qualification": "Source structure and file identity only; no AHK execution, emulation, native hook scheduling, modifier receiving, allocation cost or editor consumption.",
                "sources": receipts,
                "checks": checks,
                "reader_controls": reader_controls(),
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
