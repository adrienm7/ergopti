; tests/meta/test_llm_api_no_entry_logged.ahk

; ==============================================================================
; MODULE: LLM API No Entry Logged Meta Test
; DESCRIPTION:
; Regression guard for AHK-27: when backend = "api" but no API entry is
; configured (empty api_entries array, or the user deleted all entries),
; LLM_Engine_FirePrediction returned silently with no log and no UI at
; prediction_engine.ahk:664-665. The request_id bump had already cleared any
; prior tooltip, so the user got a prediction-invisible state with zero
; diagnostics — a textbook fail-fast violation (§5.3). The logs showed a
; "Prediction request queued" line with no follow-up, indistinguishable from a
; working state that simply hadn't fired yet.
;
; The sibling early-returns all log before returning (disabled-app skip at
; line 462, warmup-defer at line 475, short-context skip at line 514) — the
; no-entry skip was the only unlogged one.
;
; The fix adds `try LoggerWarn("LLM", "API backend selected but no entry
; configured — prediction skipped.")` before the return at line 664.
;
; This test asserts (source introspection):
;   The body of LLM_Engine_FirePrediction contains a LoggerWarn (or LoggerInfo)
;   call adjacent to the `if (entry == "")` no-entry guard — encoding that the
;   no-entry skip is never silent.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================================
; ===================================================================
; ======= 1/ Test implementation ====================================
; ===================================================================
; ===================================================================

_TLANEL_CheckNoEntryLogged() {
	Body := _DriverFuncBody("LLM_Engine_FirePrediction")
	Assert(Body != "", "LLM_Engine_FirePrediction must exist in modules/llm/prediction_engine.ahk")

	; The no-entry guard pattern: "if (entry == "")" followed by a Logger call
	; Locate the guard and assert a Logger call is nearby
	GuardPos := InStr(Body, "entry == " Chr(34) Chr(34))
	Assert(GuardPos > 0,
		"AHK-27: LLM_Engine_FirePrediction must contain a guard for entry == empty string (the no-API-entry case)")

	; Assert a LoggerWarn or LoggerInfo appears within a short window after the guard
	; (both the guard block and the Logger call must be present)
	LocalBody := SubStr(Body, GuardPos, 300)
	Assert(InStr(LocalBody, "LoggerWarn") or InStr(LocalBody, "LoggerInfo"),
		"AHK-27: the entry == empty string branch in LLM_Engine_FirePrediction must call LoggerWarn or LoggerInfo before returning — a silent return here is a §5.3 fail-fast violation; the user gets no feedback that predictions are impossible in this configuration")
}


Test("meta ahk-27: LLM_Engine_FirePrediction logs a warning when API backend has no entry configured instead of returning silently",
	_TLANEL_CheckNoEntryLogged)
