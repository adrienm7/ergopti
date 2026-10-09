; tests/unit/test_fire_log_callable_replacement.ahk

; ==============================================================================
; MODULE: Regression — a callable Replacement must never reach the fire-log
;         drain (fire-log-callable-replacement-drops-the-record)
; DESCRIPTION:
; The dynamic hotstrings (@dt, @date, @td and every phone / SSN / IBAN prefix)
; are all default-enabled and all store a CALLABLE in Spec.Replacement, resolved
; at fire time so the date is computed on the keystroke.
;
; ROOT CAUSE ENCODED: HSE_DispatchMatch resolves that callable into a LOCAL and
; never writes it back to the Spec, so the fire paths read the raw property and
; handed the Func object straight to the metrics queue. KL_LogHotstring opens
; with StrLen(replacement), which throws TypeError on a Func — inside the
; drain's try, with no catch. The result was silent and total: every date,
; phone, SSN and IBAN expansion vanished from the keylogger JSONL and from the
; WPM widget, with not one line in the error log, and the throw landed AFTER
; KL_FlushBuffer so the typing buffer had already been flushed without it.
;
; The legacy _HotstringDispatch path had guarded this for years
; (repl_str := HasMethod(Replacement) ? "" : Replacement); the two newer fire
; paths did not. Rather than repeat the guard at each of them, it belongs at
; _HSE_QueueFireLog — the one funnel they all share — so a future fire path
; inherits the fix instead of the bug.
; ==============================================================================

#Requires AutoHotkey v2.0






; ===============================================================
; ===============================================================
; ======= 1/ The queue neutralises a callable Replacement =======
; ===============================================================
; ===============================================================

_FLCR_QueueNeutralisesACallableReplacement() {
	global _HSE_FireLogQueue, _HSE_FireLogScheduled
	PrevQueue := _HSE_FireLogQueue
	PrevScheduled := _HSE_FireLogScheduled
	_HSE_FireLogQueue := []
	; Declare the drain already armed so this call leaves no live timer behind in
	; the runner; the queue itself is what is under test.
	_HSE_FireLogScheduled := true
	Trigger := "@dt" . Chr(0x2605)
	try {
		_HSE_QueueFireLog(Trigger, (*) => "29/07/2026", "star", "dynamic", "date_fr")
		AssertEqual(1, _HSE_FireLogQueue.Length,
			"the fire must reach the queue at all")
		Rec := _HSE_FireLogQueue[1]
		Assert(!HasMethod(Rec.Replacement),
			"a dynamic hotstring whose Replacement is resolved at fire time must still reach the metrics pipeline. Queueing the Func object makes KL_LogHotstring's StrLen() throw, and the drain swallows it, so every date / phone / SSN / IBAN expansion disappears from the JSONL and the WPM widget with nothing logged")
		Assert(Rec.Replacement is String,
			"the queued replacement must be a String, never the callable itself")
		Assert(Rec.Trigger == Trigger,
			"the trigger must survive so the metric still identifies which expansion fired — the resolved value is deliberately dropped rather than recorded, because it can be personal data")
	} finally {
		_HSE_FireLogQueue := PrevQueue
		_HSE_FireLogScheduled := PrevScheduled
	}
}
Test("hotstrings: the fire-log queue neutralises a callable Replacement (fire-log-callable-replacement-drops-the-record)",
	_FLCR_QueueNeutralisesACallableReplacement)

; A plain string replacement must still arrive untouched, or the guard above
; would be a regression dressed up as a fix.
_FLCR_QueueKeepsAStringReplacement() {
	global _HSE_FireLogQueue, _HSE_FireLogScheduled
	PrevQueue := _HSE_FireLogQueue
	PrevScheduled := _HSE_FireLogScheduled
	_HSE_FireLogQueue := []
	_HSE_FireLogScheduled := true
	try {
		_HSE_QueueFireLog("pex", "par exemple", "endchar", "magickey", "abbreviations")
		AssertEqual(1, _HSE_FireLogQueue.Length, "the fire must reach the queue")
		Assert(_HSE_FireLogQueue[1].Replacement == "par exemple",
			"an ordinary string replacement must pass through unchanged — the metrics pipeline measures saved keystrokes from it")
	} finally {
		_HSE_FireLogQueue := PrevQueue
		_HSE_FireLogScheduled := PrevScheduled
	}
}
Test("hotstrings: the fire-log queue keeps an ordinary string replacement",
	_FLCR_QueueKeepsAStringReplacement)






; =====================================================
; =====================================================
; ======= 2/ The drain no longer fails silently =======
; =====================================================
; =====================================================

_FLCR_DrainReportsAFailure() {
	Body := _DriverFuncBody("_HSE_DrainFireLog")
	Assert(Body != "", "_HSE_DrainFireLog() must exist in the driver source")
	Assert(InStr(Body, "catch") > 0,
		"the drain must catch its own failures — a bare try swallowed a TypeError for weeks, and the only visible symptom was a metric that never arrived")
	Assert(InStr(Body, "LoggerError") > 0,
		"and it must log them: the drain is the last stop before the metrics pipeline, so a failure there has to name itself instead of dropping the record")
}
Test("meta hotstrings: the fire-log drain reports a failed record instead of swallowing it",
	_FLCR_DrainReportsAFailure)
