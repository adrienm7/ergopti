; tests/meta/test_logger_dedup_tick.ahk

; ==============================================================================
; MODULE: Logger Error Deduplication Tick Guard
; DESCRIPTION:
; Static source guard for the logger deduplication tick-time fix in
; lib/logger.ahk.
;
; ROOT CAUSE ENCODED:
; The original error deduplication only compared the tag and body strings, so a
; recurring error that was silent for more than a minute would be suppressed
; forever once it had fired once. The fix adds a _LastErrTime static (storing
; A_TickCount) and only suppresses a repeat if the same tag+body occurred within
; the last 5000 ms, so identical errors are de-bounced rather than permanently
; silenced.
; ==============================================================================

#Requires AutoHotkey v2.0

_TLDT_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}





; ==============================================================
; ==============================================================
; ======= 1/ _LastErrTime static and 5000ms window check =======
; ==============================================================
; ==============================================================

_TLDT_DedupTickTime() {
	; Move-resilient: scan the lib dir via the framework helper. "_LastErrTime"
	; and "A_TickCount - _LastErrTime" are unique to logger.ahk within lib.
	Src := _TLDT_StripLineComments(_DriverDirConcat("lib"))

	; The static must be declared
	Assert(InStr(Src, "_LastErrTime") > 0,
		"lib/logger.ahk must declare _LastErrTime static to track when the last error was logged (logger-dedup-tick)")

	; The 5000 ms window must be present
	Assert(InStr(Src, "5000") > 0,
		"lib/logger.ahk must use a 5000 ms suppression window for error deduplication (logger-dedup-tick)")

	; A_TickCount must be used in the dedup logic
	Assert(InStr(Src, "A_TickCount - _LastErrTime") > 0,
		"lib/logger.ahk must compare (A_TickCount - _LastErrTime) to enforce the 5000 ms dedup window")
}
Test("logger: error deduplication uses _LastErrTime tick-time with 5000 ms window", _TLDT_DedupTickTime)
