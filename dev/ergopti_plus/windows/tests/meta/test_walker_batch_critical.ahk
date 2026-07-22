; tests/meta/test_walker_batch_critical.ahk

; ==============================================================================
; MODULE: KLW.batch Critical-Section Meta-Test
; DESCRIPTION:
; Structural regression for the torn-batch fix in the keylogger ingest path
; (keylogger.ahk).
;
; Before the fix, the walker loop that accumulates into KLW.batch ran without
; any preemption guard. The live-push debounce timer fires on its own AHK
; thread and calls KLW_ResetBatch(), which replaces the entire KLW.batch Map
; with a fresh empty one mid-walk. Any entries already accumulated by the
; for-loop up to that point were silently lost, producing incomplete UPSERT
; data for n-gram, burst, and session aggregates.
;
; The fix wraps the for-loop in a Critical("On") / finally { Critical(prior) }
; save-restore block so the timer interrupt is deferred until the batch
; accumulation completes atomically.
;
; This test inspects keylogger.ahk source and asserts:
;   1. Critical("On") appears in the ingest function near the walk loop.
;   2. A matching finally block with Critical(restore) follows.
;   3. The Critical call precedes the for-loop over entries.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===========================================================
; ===========================================================
; ======= 1/ Source-inspection helpers ======================
; ===========================================================
; ===========================================================

; Symbol-keyed source lookup keeps this guard coupled to the actual ingest
; function rather than a nearby implementation detail whose position can move.
_WBCR_ReadSource() {
	return _DriverFuncBody("KL_IngestOnce")
}


_WBCR_FindIngestBlock(src) {
	return src
}




; ===========================================================
; ===========================================================
; ======= 2/ Assertions =====================================
; ===========================================================
; ===========================================================

_WBCR_CriticalOnPresent() {
	block := _WBCR_FindIngestBlock(_WBCR_ReadSource())
	Assert(InStr(block, 'Critical("On")') > 0,
		"keylogger.ahk: walk-loop block must call Critical('On') to guard KLW.batch against timer preemption")
}
Test("KLW.batch walk: Critical('On') guard present in ingest block (walker-batch-critical)", _WBCR_CriticalOnPresent)


_WBCR_FinallyWithCriticalRestore() {
	block := _WBCR_FindIngestBlock(_WBCR_ReadSource())
	Assert(InStr(block, "finally") > 0,
		"keylogger.ahk: walk-loop Critical guard must use a finally block for safe restore")
	Assert(InStr(block, "Critical(_crit_walk)") > 0,
		"keylogger.ahk: finally block must restore prior Critical state via Critical(_crit_walk)")
}
Test("KLW.batch walk: finally { Critical(_crit_walk) } restore present (walker-batch-critical)", _WBCR_FinallyWithCriticalRestore)


_WBCR_CriticalBeforeForLoop() {
	block := _WBCR_FindIngestBlock(_WBCR_ReadSource())
	posCrit := InStr(block, 'Critical("On")')
	posFor  := InStr(block, "for _, entry in entries")
	Assert(posCrit > 0 and posFor > 0,
		"keylogger.ahk: both Critical guard and for-loop over entries must be present")
	Assert(posCrit < posFor,
		"keylogger.ahk: Critical guard must appear before the for-loop over entries")
}
Test("KLW.batch walk: Critical guard precedes for-loop over entries (walker-batch-critical)", _WBCR_CriticalBeforeForLoop)
