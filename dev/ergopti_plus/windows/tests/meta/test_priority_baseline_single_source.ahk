; tests/meta/test_priority_baseline_single_source.ahk

; ==============================================================================
; MODULE: Priority Baseline Single-Source-Of-Truth Meta Test
; DESCRIPTION:
; Regression guard for driver-baseline-priority-reverted-to-normal: commit
; 3d27945be introduced ``try ProcessSetPriority("AboveNormal")`` as the boot
; baseline (hotpath-priority-starvation) but never audited the four
; pre-existing ``ProcessSetPriority("Normal")`` restore sites left over from
; the older Ollama-install High-priority boost (LLM_Deps_Fail, LLM_Deps_Cancel,
; _LLM_Deps_OnPollProbeResult, LLM_Menu_Init). ~16 ms after boot,
; BuildTrayMenuDeferred unconditionally calls LLM_Menu_Init, whose FIRST
; statement silently reverted the fresh AboveNormal boost back to Normal for
; the rest of the session.
;
; The fix introduces a single named constant, DRIVER_BASELINE_PRIORITY_CLASS,
; declared once in ErgoptiPlus.ahk and referenced by the boot-time boost AND
; every restore site, so there is exactly one place that decides what "back to
; baseline" means.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Single declaration of the constant ===
; ==================================================
; ==================================================

_PBSS_ConstantDeclaredOnce() {
	Src := _DriverSourceConcat()
	Needle := 'global DRIVER_BASELINE_PRIORITY_CLASS := "AboveNormal"'
	FirstIdx := InStr(Src, Needle)
	Assert(FirstIdx > 0,
		"ErgoptiPlus.ahk must declare `global DRIVER_BASELINE_PRIORITY_CLASS := " . Chr(34) . "AboveNormal" . Chr(34) . "` as the single source of truth for the driver's baseline process priority")
	SecondIdx := InStr(Src, Needle, , FirstIdx + 1)
	Assert(SecondIdx = 0,
		"DRIVER_BASELINE_PRIORITY_CLASS must be declared exactly ONCE — a second declaration would defeat the single-source-of-truth fix for driver-baseline-priority-reverted-to-normal")
}
Test("meta priority-baseline: DRIVER_BASELINE_PRIORITY_CLASS is declared exactly once as AboveNormal (driver-baseline-priority-reverted-to-normal)", _PBSS_ConstantDeclaredOnce)




; ==========================================================
; ==========================================================
; ======= 2/ Every restore site uses the constant ==========
; ==========================================================
; ==========================================================

_PBSS_CheckRestoreSite(FuncName) {
	Body := _DriverFuncBody(FuncName)
	Assert(Body != "", FuncName . " must exist in the driver source")
	Assert(InStr(Body, "ProcessSetPriority(DRIVER_BASELINE_PRIORITY_CLASS)") > 0,
		FuncName . " must restore priority via `ProcessSetPriority(DRIVER_BASELINE_PRIORITY_CLASS)` — a hardcoded "
		. "literal would silently diverge from the boot-time boost class again (driver-baseline-priority-reverted-to-normal)")
	Assert(InStr(Body, 'ProcessSetPriority("Normal")') = 0,
		FuncName . " must NOT restore via the literal `ProcessSetPriority(" . Chr(34) . "Normal" . Chr(34) . ")` — "
		. "that literal is what silently reverted the AboveNormal boot boost 16 ms after launch "
		. "(driver-baseline-priority-reverted-to-normal)")
}

_PBSS_LlmDepsFailRestoresBaseline() {
	_PBSS_CheckRestoreSite("LLM_Deps_Fail")
}
Test("meta priority-baseline: LLM_Deps_Fail restores via DRIVER_BASELINE_PRIORITY_CLASS, not a Normal literal", _PBSS_LlmDepsFailRestoresBaseline)

_PBSS_LlmDepsCancelRestoresBaseline() {
	_PBSS_CheckRestoreSite("LLM_Deps_Cancel")
}
Test("meta priority-baseline: LLM_Deps_Cancel restores via DRIVER_BASELINE_PRIORITY_CLASS, not a Normal literal", _PBSS_LlmDepsCancelRestoresBaseline)

_PBSS_PollProbeResultRestoresBaseline() {
	_PBSS_CheckRestoreSite("_LLM_Deps_OnPollProbeResult")
}
Test("meta priority-baseline: _LLM_Deps_OnPollProbeResult restores via DRIVER_BASELINE_PRIORITY_CLASS, not a Normal literal", _PBSS_PollProbeResultRestoresBaseline)

_PBSS_LlmMenuInitRestoresBaseline() {
	_PBSS_CheckRestoreSite("LLM_Menu_Init")
}
Test("meta priority-baseline: LLM_Menu_Init's defensive reset uses DRIVER_BASELINE_PRIORITY_CLASS, not a Normal literal — this is the finding's root cause (driver-baseline-priority-reverted-to-normal)", _PBSS_LlmMenuInitRestoresBaseline)




; ======================================================
; ======================================================
; ======= 3/ Boot boost also uses the constant ========
; ======================================================
; ======================================================

_PBSS_BootBoostUsesConstant() {
	Src := _DriverSourceConcat()
	Assert(InStr(Src, "try ProcessSetPriority(DRIVER_BASELINE_PRIORITY_CLASS)") > 0,
		"ErgoptiPlus.ahk's boot-time priority boost must go through DRIVER_BASELINE_PRIORITY_CLASS instead of a separate hardcoded " . Chr(34) . "AboveNormal" . Chr(34) . " literal — single source of truth")
}
Test("meta priority-baseline: ErgoptiPlus.ahk's boot boost uses DRIVER_BASELINE_PRIORITY_CLASS", _PBSS_BootBoostUsesConstant)
