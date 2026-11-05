"""Authenticate Windows repeat timing chains; this does not execute AutoHotkey."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

PIN = "b17e47ed3bb92c106703d3e3482b3c2973f5bc1e"
ROOT = Path(sys.argv[1]).resolve()
BASE = "static/ergopti_plus/windows/"
FILES = [
    BASE + "infra/hotstrings/hotstring_engine_main.ahk",
    BASE + "infra/hotstrings/hotstring_match.ahk",
    BASE + "infra/hotstrings/hotstring_dispatch.ahk",
    BASE + "infra/hotstrings/hotstring_inputhook.ahk",
    BASE + "modules/dynamic_hotstrings/user_code.ahk",
    "static/ergopti_plus/macos/modules/keymap/init.lua",
    "static/ergopti_plus/_shared/modules/features/manifest.toml",
    "docs/memory/text-input-and-config.md",
]
# This historical observation was corrected after the audit. Runtime owners
# remain live-checked; only this exact documentation claim reads its pinned blob.
HISTORICAL_DOCUMENTS = frozenset({"docs/memory/text-input-and-config.md"})
sources = {}
receipts = []
for name in FILES:
    live = (ROOT / name).read_bytes()
    pinned = subprocess.check_output(["git", "-C", str(ROOT), "show", f"{PIN}:{name}"])
    if name in HISTORICAL_DOCUMENTS:
        raw = pinned
        basis = "historical pinned Git blob; current documentation may be corrected"
    else:
        assert live == pinned, f"runtime source differs from audit pin: {name}"
        raw = live
        basis = "current runtime source is byte-identical to the pinned Git blob"
    sources[name] = raw.decode("utf-8-sig")
    receipts.append(
        {
            "path": name,
            "sha256": hashlib.sha256(raw).hexdigest(),
            "basis": basis,
            "live_sha256": hashlib.sha256(live).hexdigest(),
            "live_matches_pinned": live == pinned,
        }
    )


def section(text, start, end):
    assert text.count(start) == 1
    value = text[text.index(start) :]
    assert end in value
    value = value[: value.index(end)]
    assert len(value) > 100
    return "\n".join(line for line in value.splitlines() if not line.lstrip().startswith(";"))


engine = sources[BASE + "infra/hotstrings/hotstring_engine_main.ahk"]
repeat = section(engine, "HSE_TryRepeatKey(MagicKey) {", "HSE_TryPersonalInfoCombo(MagicKey) {")
oracle = engine[engine.index("HSE_PreviewNextDecision(Buffer, NextChar) {") :]
hook = sources[BASE + "infra/hotstrings/hotstring_inputhook.ahk"]
live = section(
    hook,
    "_OnPrefixChar(IH, Char, PrefeedFn := unset, ContextFn := unset) {",
    "_OnPrefixKeyDown(IH, VK, SC) {",
)
code = sources[BASE + "modules/dynamic_hotstrings/user_code.ahk"]
code_live = section(
    code, "UserHotstringsOnChar(BufferValue) {", "_UserHotstringsCurrent(Capture, Source) {"
)
preview = section(
    code,
    "UserHotstringsPreviewSpec(BufferBefore, Completion) {",
    "UserHotstringsPreviewStillCurrent(Decision) {",
)
dispatch = sources[BASE + "infra/hotstrings/hotstring_dispatch.ahk"]
checks = {
    "repeat_spec_has_no_activation_seconds_or_reference_key": "TimeActivationSeconds" not in repeat
    and "PrevCharKey" not in repeat,
    "dispatch_gate_requires_positive_spec_metadata": 'if Spec.HasOwnProp("TimeActivationSeconds")\n\t\t\t\tand Spec.TimeActivationSeconds > 0 {'
    in dispatch,
    "idle_zero_disables_reset": 'if (IdleSeconds == 0 or LastTick == "")' in engine,
    "registry_matcher_has_no_activation_time_gate": "TimeActivationSeconds"
    not in sources[BASE + "infra/hotstrings/hotstring_match.ahk"],
    "live_repeat_precedes_dispatch": live.index("HSEMatch := HSE_TryRepeatKey(")
    < live.index("_HseFired := HSE_DispatchMatch("),
    "live_registry_match_only_falls_back_if_empty": 'if (HSEMatch == "" and IsSet(ScriptInformation)'
    in live,
    "dispatch_refusal_does_not_retry_repeat": "HSE_TryRepeatKey"
    not in live[live.index("if !_HseFired {") :],
    "oracle_matches_before_gate_and_fallback_only_if_empty": oracle.index("Match := HSE_FeedChar(")
    < oracle.index("Match := HSE_TryRepeatKey(")
    < oracle.index("_HSE_PrepareDispatchDecision("),
    "oracle_uses_same_ungated_repeat_spec": "HSE_TryRepeatKey(MagicKey)" in oracle,
    "live_programmed_suffix_expires_before_claim": '_HSE_PrepareDispatchDecision(Spec, BufferValue, "")'
    in code_live
    and "return false" in code_live[code_live.index("_HSE_PrepareDispatchDecision") :],
    "preview_programmed_suffix_defers_time_gate_to_oracle": "TimeActivationSeconds:" in preview
    and "_HSE_PrepareDispatchDecision" not in preview,
    "historical_memory_names_windows_repeat_ungated": "The ungated repeat doubling"
    in sources["docs/memory/text-input-and-config.md"],
    "mac_public_fallback_has_a_separate_star_time_gate": sources[
        "static/ergopti_plus/macos/modules/keymap/init.lua"
    ].count("(star_allowed == 0 or _tc_dt <= star_allowed)")
    == 2,
}
assert all(checks.values()), checks
print(
    json.dumps(
        {
            "audited_sha": PIN,
            "basis": "source authentication and lexical chains; no AHK execution, no timing measurement or behavioral translation",
            "source_receipts": receipts,
            "checks": checks,
        },
        indent=2,
    )
)
