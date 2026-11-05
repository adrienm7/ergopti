"""Authenticate the source-only Windows repeat audit; never execute AHK."""

import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

PIN = "b17e47ed3bb92c106703d3e3482b3c2973f5bc1e"
ROOT = Path(sys.argv[1]).resolve()
PREFIX = "static/ergopti_plus/windows/"
FILES = [
    "infra/hotstrings/hotstring_engine_main.ahk",
    "infra/hotstrings/hotstring_inputhook.ahk",
    "infra/hotstrings/hotstring_dispatch.ahk",
    "infra/hotstrings/hotstring_match.ahk",
    "infra/hotstrings/hotstring_cascade.ahk",
    "modules/dynamic_hotstrings/user_code.ahk",
    "modules/dynamic_hotstrings/dynamic_hotstrings.ahk",
    "modules/hotstrings/hotstrings_text_expansion.ahk",
    "modules/keystats/keystats_hotstring_log.ahk",
    "ui/wpm/wpm_display.ahk",
    "ui/wpm/wpm_config.ahk",
    "ui/editors.ahk",
    "infra/feature_state.ahk",
    "tests/unit/modules/hotstrings/engine/test_repeat_key_honours_rebuild_fence.ahk",
    "tests/unit/modules/hotstrings/preview/test_no_repeat_preview.ahk",
    "tests/unit/modules/hotstrings/engine/test_hotstring_fire_log_privacy.ahk",
]
FILES = [PREFIX + value for value in FILES] + [
    "static/ergopti_plus/_shared/modules/wpm_widget/constants.toml",
    "static/ergopti_plus/_shared/modules/features/manifest.toml",
    "static/layouts/registry/ergopti/hotstrings/repeatcorrections.toml",
]
texts = {}
receipts = []
for name in FILES:
    raw = (ROOT / name).read_bytes()
    pinned = subprocess.check_output(["git", "-C", str(ROOT), "show", f"{PIN}:{name}"])
    assert raw == pinned, f"source drift: {name}"
    texts[name] = raw.decode("utf-8-sig")
    receipts.append({"path": name, "sha256": hashlib.sha256(raw).hexdigest()})


def get(name):
    return texts[PREFIX + name]


def between(text, start, end):
    assert text.count(start) == 1, start
    result = text[text.index(start) :]
    assert end in result, end
    result = result[: result.index(end)]
    assert len(result) > 100
    # Source contracts are deliberately lexical receipts, not AHK semantics.
    return "\n".join(line for line in result.splitlines() if not line.lstrip().startswith(";"))


engine = get("infra/hotstrings/hotstring_engine_main.ahk")
repeat = between(engine, "HSE_TryRepeatKey(MagicKey) {", "HSE_TryPersonalInfoCombo(MagicKey) {")
commit = between(
    get("modules/dynamic_hotstrings/user_code.ahk"),
    "_UserHotstringsCommit(Result, Capture, Rule) {",
    "class UserHotstringWorker {",
)
apply = between(engine, "HSE_ApplyExpansion(Spec, Replacement, EndChar :=", "HSE_IsWordChar(Ch) {")
post = between(
    get("infra/hotstrings/hotstring_inputhook.ahk"),
    "_PrefixPostFireDecision(Effect, EngineBuffer, MaxBufferLen) {",
    "_PrefixCommitPostFireEffect(Effect) {",
)
dispatch = get("infra/hotstrings/hotstring_dispatch.ahk")
notepad = between(
    dispatch,
    "_HSE_NewNotepadOwner(Spec, Replacement, EndCharPart, EraseUnits, Backspaces,",
    "_HSE_NotepadOwnerIsCurrent(Owner) {",
)
finish = between(dispatch, "_HSE_FinishNotepadCommit(Owner) {", "_HSE_RecoverNotepadOwner(Owner,")
mirror = between(
    dispatch,
    "_HSE_MirrorCanonicalEffectToLlm(Effect) {",
    "_HSE_DispatchNotepadRawCallback(Spec, EndChar,",
)
checks = {}
checks["repeat_spec_marks_repeat_but_not_private"] = (
    "IsRepeat:    true" in repeat and "IsPrivate:" not in repeat
)
checks["repeat_spec_attributes_magic_key_corrections"] = (
    'Category:    "magickey"' in repeat and 'Section:     "repeat_corrections"' in repeat
)
checks["repeat_reads_resolved_tail"] = (
    "RepeatChar := _TextCompleteTailScalar(" in repeat
    and "Replacement: RepeatChar . RepeatChar" in repeat
)
checks["repeat_rebuild_pause_runtime_fences"] = all(
    x in repeat
    for x in [
        "HSE_RebuildInProgress",
        "HSE_RegistryTransitionDepth > 0",
        "!HSE_RepeatEnabled or HSE_Suppressed",
    ]
)
checks["programmable_commit_is_private_nonfinal_literal"] = (
    "OnlyText: true, IsPrivate: true" in commit
    and "FinalResult:" not in commit
    and "HSE_DispatchMatch(Spec" in commit
)
checks["literal_apply_retains_nonfinal_output"] = (
    "HSE_Buffer .= Effect.InsertedText" in apply
    and 'Spec.HasOwnProp("FinalResult") and Spec.FinalResult' in apply
)
checks["private_effect_clears_ai_only"] = (
    "ClearContext := Effect.IsPrivate or" in mirror
    and "_LLM_Bridge_ApplyBufferEdit(Effect.DeleteFromEnd, Effect.InsertedText)" in mirror
)
checks["postfire_does_not_retire_private_matcher"] = (
    "Effect.ClearAll or Effect.KnownBoundaryAfter" in post and "Effect.IsPrivate" not in post
)
checks["notepad_copies_raw_spec_category"] = (
    '"Category", Spec.HasOwnProp("Category") ? Spec.Category : ""' in notepad
)
checks["notepad_completion_queues_category_unchanged"] = (
    '_HSE_QueueFireLog(Owner["Trigger"], Owner["ReplacementForLog"],' in finish
    and 'Owner["HType"], Owner["Category"], Owner["Section"], Owner["IsPrivate"]' in finish
)
checks["terminal_copies_raw_spec_category"] = (
    len(re.findall(r'"Category", Spec\.HasOwnProp\("Category"\) \? Spec\.Category : ""', dispatch))
    >= 3
)
hook = get("infra/hotstrings/hotstring_inputhook.ahk")
checks["atomic_caller_normalizes_repeat_category"] = (
    'HotstringCategory := HSEMatch.HasOwnProp("IsRepeat") && HSEMatch.IsRepeat' in hook
    and "? MenuCommand.REPEAT_KEY" in hook
)
checks["queue_carries_explicit_private_bit"] = "IsPrivate: IsPrivate ? true : false })" in hook
checks["wpm_neutral_policy_is_explicit"] = "\nrepeat_key = true\n" in texts[
    "static/ergopti_plus/_shared/modules/wpm_widget/constants.toml"
] and "if (is_hs and _WPMWidget_NeutralCategory(category))" in get("ui/wpm/wpm_display.ahk")
checks["personal_prefixes_have_final_backstop"] = (
    '_DynPrivateOpts := Map("FinalResult", True'
    in get("modules/dynamic_hotstrings/dynamic_hotstrings.ahk")
)
sink = get("modules/keystats/keystats_hotstring_log.ahk")
checks["public_fire_row_preserves_unredacted_trigger_and_output"] = (
    "logged_trigger := is_private ? PersonalInfoRedactForLog(trigger) : trigger" in sink
    and "logged_replacement := is_private ? PersonalInfoRedactForLog(replacement) : replacement"
    in sink
    and '"tag",             "<hotstring>" . logged_replacement' in sink
)
checks["category_reaches_live_wpm_not_durable_category_field"] = (
    "WPMWidget_Push(true, false, false, category, section)" in sink
    and '"category",' not in sink
    and '"section",' not in sink
)
checks["repeat_cannot_cascade"] = 'Spec.HasOwnProp("IsRepeat") and Spec.IsRepeat' in get(
    "infra/hotstrings/hotstring_cascade.ahk"
)
assert all(checks.values()), checks
print(
    json.dumps(
        {
            "audited_sha": PIN,
            "basis": "exact-source authentication and lexical checks; no AHK execution, no behavioral simulation, no desktop receipt",
            "source_receipts": receipts,
            "checks": checks,
        },
        indent=2,
    )
)
