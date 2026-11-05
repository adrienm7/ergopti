"""Authenticate the bounded Windows word-reset source chains, without AHK execution."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

PIN = "b17e47ed3bb92c106703d3e3482b3c2973f5bc1e"
ROOT = Path(sys.argv[1]).resolve()
PREFIX = "static/ergopti_plus/windows/"
NAMES = [
    "infra/hotstrings/hotstring_engine_main.ahk",
    "infra/hotstrings/hotstring_inputhook.ahk",
    "infra/hotstrings/hotstring_buffer_effects.ahk",
    "infra/hotstrings/hotstring_send.ahk",
    "infra/hook_dispatcher.ahk",
    "infra/lifecycle.ahk",
    "infra/tick_count.ahk",
    "infra/send_input_parameter.ahk",
    "modules/keymap/llm_bridge.ahk",
    "adapters/key_state.ahk",
    "adapters/text_sender.ahk",
    "platform/remap/constants.ahk",
    "modules/gestures/actions.ahk",
    "ui/editors.ahk",
    "infra/feature_state.ahk",
    "tests/unit/modules/hotstrings/engine/test_hotstring_event_word_reset.ahk",
    "tests/unit/modules/hotstrings/engine/test_hotstring_idle_click_reset.ahk",
    "tests/unit/modules/hotstrings/engine/test_hotstring_backspace_word_start.ahk",
    "tests/unit/modules/llm/navigation/test_llm_nav_cycle_windows.ahk",
]
NAMES = [PREFIX + name for name in NAMES] + [
    "static/ergopti_plus/_shared/modules/features/manifest.toml",
    "static/ergopti_plus/_shared/modules/actions/send_keys.json",
    "static/ergopti_plus/_shared/modules/actions/actions.toml",
]
sources = {}
receipts = []
for name in NAMES:
    raw = (ROOT / name).read_bytes()
    pinned = subprocess.check_output(["git", "-C", str(ROOT), "show", f"{PIN}:{name}"])
    assert raw == pinned, f"source changed since audit pin: {name}"
    sources[name] = raw.decode("utf-8-sig")
    receipts.append({"path": name, "sha256": hashlib.sha256(raw).hexdigest()})


def get(name):
    return sources[PREFIX + name]


def body(text, start, end):
    assert text.count(start) == 1, start
    result = text[text.index(start) :]
    assert end in result, end
    result = result[: result.index(end)]
    assert len(result) > 80
    return "\n".join(line for line in result.splitlines() if not line.lstrip().startswith(";"))


hook = get("infra/hotstrings/hotstring_inputhook.ahk")
effects = get("infra/hotstrings/hotstring_buffer_effects.ahk")
bridge = get("modules/keymap/llm_bridge.ahk")
classifier = body(effects, "HS_SyntheticPayloadKind(Payload) {", "HS_ShortcutWordResetKey() {")
commit = body(
    effects,
    "HS_CommitSyntheticEffect(Payload, SendFailed := false) {",
    "HS_FinishSyntheticEffect(Token) {",
)
physical = body(hook, "_OnPrefixKeyDown(IH, VK, SC) {", "HotstringEndKeyCompletes(Char) {")
context = body(
    hook,
    "_PrefixCommitInputContext(FocusToken := 0, KnownBoundary := true, AtLineStart := false) {",
    "_PrefixFinishInputContext(Commit) {",
)
discard = body(
    bridge,
    "LLM_Bridge_DiscardIncompleteInput() {",
    "_LLM_Bridge_TextAdmissionMatches(Expected, Live) {",
)
fallback = body(bridge, "_LLM_Bridge_OnDispatcherKey(ih, vk, sc) {", "LLM_Bridge_Stop() {")
feed = body(
    bridge,
    "LLM_Bridge_FeedCharForPrefix(ch, ScheduleFn := TimerSetCallback, FocusFn := unset,",
    "_LLM_Bridge_SchedulePrefixObserver(ch, ScheduleFn, ReadFocus) {",
)
checks = {}
checks["public_send_shortcut_action_is_all_platform"] = (
    '[sg_actions.send_shortcut]\nplatform = "all"\nparameter = "shortcut"'
    in sources["static/ergopti_plus/_shared/modules/actions/actions.toml"]
)
checks["parsed_shortcut_reaches_textpresskey"] = (
    "return TextPressKey(_SendInputAhkKey(Parsed), Names)" in get("infra/send_input_parameter.ahk")
)
checks["textpresskey_modified_press_uses_effect_owner"] = '"modified key press"' in get(
    "adapters/text_sender.ahk"
) and "HS_RunSyntheticInputTransaction(Keys, _AHK_SendInput.Bind(Keys))" in get(
    "adapters/text_sender.ahk"
)
checks["alt_and_backspace_in_actual_vocabulary"] = any(
    row.get("id") == "alt" and row.get("ahk") == "Alt"
    for row in json.loads(sources["static/ergopti_plus/_shared/modules/actions/send_keys.json"])[
        "modifiers"
    ]
) and any(
    row.get("id") == "backspace" and row.get("ahk") == "Backspace"
    for row in json.loads(sources["static/ergopti_plus/_shared/modules/actions/send_keys.json"])[
        "keys"
    ]
)
checks["modified_backspace_excluded_from_configurable_shortcuts"] = (
    "BackSpace|BS|Delete|Del|Insert|Ins" in classifier and 'return "edit"' in classifier
)
checks["synthetic_successful_edit_asserts_boundary"] = (
    "KnownBoundary := !SendFailed && !IncompleteContext" in commit
    and "_PrefixCommitInputContext(0, KnownBoundary)" in commit
)
checks["synthetic_failed_edit_loses_boundary"] = (
    "if !SendFailed {" in commit and "!SendFailed && !IncompleteContext" in commit
)
checks["physical_modified_backspace_uses_live_ctrl_only_boundary"] = (
    "_PrefixInvalidateInputContext(_PrefixFocusedControlToken, _PrefixWordDeleteChordHeld())"
    in physical
)
checks["word_delete_disallows_alt_or_win"] = "return CtrlDown and !AltDown and !WinDown" in hook
checks["focus_rebind_preserves_unbound_boundary"] = (
    "KnownBoundary := Unbound ? HSE_StartIsWordBoundary : true" in hook
)
checks["physical_modified_branch_returns_before_ai_feed"] = (
    physical.index(
        "_PrefixInvalidateInputContext(_PrefixFocusedControlToken, _PrefixWordDeleteChordHeld())"
    )
    < physical.index(
        "return",
        physical.index(
            "_PrefixInvalidateInputContext(_PrefixFocusedControlToken, _PrefixWordDeleteChordHeld())"
        ),
    )
    < physical.index("LLM_Bridge_FeedKeyDownIfActive(VK, true)")
)
checks["physical_shortcut_branch_returns_before_ai_feed"] = (
    physical.index('HS_ApplyEventWordReset(HS_ShortcutWordResetKey(), "Shortcut", SelectsAll)')
    < physical.index(
        "return",
        physical.index('HS_ApplyEventWordReset(HS_ShortcutWordResetKey(), "Shortcut", SelectsAll)'),
    )
    < physical.index("LLM_Bridge_FeedKeyDownIfActive(VK, true)")
)
checks["prefix_context_only_discards_incomplete_ai"] = (
    "LLM_Bridge_DiscardIncompleteInput()" in context
    and "LLM_Bridge_ResetPredictions" not in context
    and "_LLM_Bridge_ClearBuffer" not in context
)
checks["complete_ai_context_survives_discard"] = (
    "if !IncompletePrediction && !IncompleteAgent\n\t\t\treturn false" in discard
)
checks["normal_hook_disables_bridge_key_fallback"] = (
    "(IsSet(_PrefixInputHook) && _PrefixInputHook)" in fallback
    and "return" in fallback[: fallback.index("LLM_Bridge_FeedKeyDownIfActive(vk)")]
)
checks["next_character_appends_to_existing_ai_context"] = (
    "_LLM_Bridge_ApplyBufferEdit(0, ch)" in feed and "LLM_Bridge_MirrorAgentEdit(0, ch)" in feed
)
checks["new_observer_captures_fresh_physical_generation"] = (
    "PhysicalGeneration: KS_GetPhysicalInputGeneration()" in bridge
)
checks["new_observer_forwards_current_retained_context"] = (
    "_LLM_Bridge_NotifyChar(Owner.Char, _LLM_Bridge_Buffer, CurrentFn)" in bridge
    and "LLM_Agent_OnTyping(_LLM_Bridge_AgentBuffer, CurrentFn)" in bridge
)
checks["prediction_engine_receives_buffer_unchanged"] = "LLM_Engine_OnKeystroke(Buffer," in bridge
checks["true_reset_on_nav_only_applies_when_called"] = (
    "ConfigLeaf.RESET_ON_NAV" in bridge
    and "LLM_Bridge_ResetPredictions()"
    not in physical[: physical.index("LLM_Bridge_FeedKeyDownIfActive(VK, true)")]
)
checks["genuine_physical_alt_backspace_test_has_unknown_control"] = (
    '"and promises no word start"'
    in get("tests/unit/modules/hotstrings/engine/test_hotstring_event_word_reset.ahk")
)
checks["idle_recovery_retains_generation_fence"] = (
    "Forgotten.ContentGeneration != _PrefixContentGeneration" in hook
    and "Forgotten.Generation != _PrefixInputContextGeneration" in hook
)
checks["arrows_keep_separate_config_under_modifiers"] = (
    "IsArrow := (VK >= 0x25 and VK <= 0x28)" in physical
    and "if (!IsArrow and !_PrefixIsModifierVK(VK)" in physical
)
checks["terminal_enter_distinguishes_shift"] = (
    '!_PrefixModifierIsDown.Call("LShift")' in physical
    and '!_PrefixModifierIsDown.Call("RShift") and _PrefixTerminalHostFocused()' in physical
)
assert all(checks.values()), checks
print(
    json.dumps(
        {
            "audited_sha": PIN,
            "basis": "exact-source authentication and lexical contracts only; zero AHK runtime tests or native receipts",
            "source_receipts": receipts,
            "checks": checks,
        },
        indent=2,
    )
)
