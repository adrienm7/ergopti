; tests/meta/test_hook_dispatcher_err_cache_cap.ahk

; ==============================================================================
; MODULE: HookDispatcher _err_cache Cap Meta-Test
; DESCRIPTION:
; Structural regression for the unbounded-growth fix on HookDispatcher._err_cache.
;
; Before the fix, Dispatch() kept every distinct (event_type + error message)
; signature in a static Map forever. In a long-running session an unusual number
; of crashing subscribers — or a bug that cycles through many unique messages —
; could grow the Map without bound, leaking memory.
;
; The fix inserts a guard before each new entry: when the Map already holds
; 256 signatures the whole Map is cleared, bounding it to at most 257 entries
; between clear events (the 256 that triggered the clear plus the one entry
; written immediately after).
;
; This test reads hook_dispatcher.ahk source and asserts that:
;   1. The cap constant 256 is present (the guard exists).
;   2. A .Clear() call follows the cap check within the same Dispatch method
;      (the eviction is wired up, not just the check).
;   3. The cap check appears BEFORE the existing Has() de-dup guard (order
;      matters — clearing a full cache before testing membership prevents
;      re-insertion being skipped by the stale Has() result).
; ==============================================================================

#Requires AutoHotkey v2.0




; ======================================================
; ======================================================
; ======= 1/ Source-inspection helpers =================
; ======================================================
; ======================================================

_HDEC_ReadSource() {
	return _DriverDirConcat("infra")
}


_HDEC_FindDispatchBlock(src) {
	; Locate the Dispatch() method body — the guard lives inside it.
	start := InStr(src, "static Dispatch(event_type, args*)")
	if (!start)
		return ""
	; Return the next 800 characters — enough to capture the full catch block.
	return SubStr(src, start, 800)
}




; ======================================================
; ======================================================
; ======= 2/ Assertions ================================
; ======================================================
; ======================================================

_HDEC_CapConstantPresent() {
	block := _HDEC_FindDispatchBlock(_HDEC_ReadSource())
	Assert(InStr(block, "256") > 0,
		"hook_dispatcher.ahk: Dispatch() must reference the cap constant 256 to bound _err_cache growth")
}
Test("HookDispatcher: _err_cache cap constant 256 present in Dispatch() (err-cache-cap)", _HDEC_CapConstantPresent)


_HDEC_ClearCallPresent() {
	block := _HDEC_FindDispatchBlock(_HDEC_ReadSource())
	Assert(InStr(block, ".Clear()") > 0,
		"hook_dispatcher.ahk: Dispatch() must call .Clear() on _err_cache when the cap is reached")
}
Test("HookDispatcher: _err_cache .Clear() eviction present in Dispatch() (err-cache-cap)", _HDEC_ClearCallPresent)


_HDEC_ClearBeforeHasCheck() {
	block := _HDEC_FindDispatchBlock(_HDEC_ReadSource())
	posCount := InStr(block, ".Count")
	posClear := InStr(block, ".Clear()")
	posHas   := InStr(block, ".Has(sig)")
	Assert(posCount > 0 and posClear > 0 and posHas > 0,
		"hook_dispatcher.ahk: Dispatch() must contain .Count, .Clear(), and .Has(sig)")
	Assert(posCount < posHas and posClear < posHas,
		"hook_dispatcher.ahk: the cap check and .Clear() must appear before the .Has(sig) de-dup guard in Dispatch()")
}
Test("HookDispatcher: _err_cache cap check precedes .Has(sig) guard in Dispatch() (err-cache-cap)", _HDEC_ClearBeforeHasCheck)
