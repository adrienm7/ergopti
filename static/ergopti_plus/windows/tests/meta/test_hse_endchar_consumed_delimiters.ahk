; tests/meta/test_hse_endchar_consumed_delimiters.ahk

; ==============================================================================
; MODULE: HSE_ApplyExpansion Consumed Delimiters Guard
; DESCRIPTION:
; Static source guard for the HSE_ApplyExpansion EndChar handling fix in
; lib/hotstrings/hotstring_engine_main.ahk.
;
; ROOT CAUSE ENCODED:
; The original expansion logic unconditionally appended EndChar to the output,
; which caused double-emission when the triggering EndChar was a delimiter that
; the OS hotstring machinery had already consumed (e.g. Space consumed by the
; hotstring trigger itself). The fix wraps the EndChar append in a guard:
;   EndCharPart := (EndChar != "" and !InStr(HSE_CONSUMED_DELIMITERS, EndChar))
;                  ? EndChar : ""
; so consumed delimiters are not re-emitted. This test checks that both the
; constant name and the guard form are present in the source.
; ==============================================================================

#Requires AutoHotkey v2.0

_THECE_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}


; ==========================================================================
; ==========================================================================
; ======= 1/ HSE_CONSUMED_DELIMITERS constant and guard are present =========
; ==========================================================================
; ==========================================================================

_THECE_ConsumedDelimitersGuard() {
	Src := _THECE_StripLineComments(_DriverDirConcat("lib/hotstrings"))
	Assert(Src != "", "lib/hotstrings/hotstring_engine_main.ahk must be readable")

	; The constant must be declared
	Assert(InStr(Src, "HSE_CONSUMED_DELIMITERS") > 0,
		"hotstring_engine_main.ahk must define HSE_CONSUMED_DELIMITERS (hse-endchar-consumed-delimiters)")

	; The guard form must be present in the expansion logic
	Assert(InStr(Src, "!InStr(HSE_CONSUMED_DELIMITERS, EndChar)") > 0,
		"hotstring_engine_main.ahk must guard EndChar append with !InStr(HSE_CONSUMED_DELIMITERS, EndChar) to avoid double-emitting consumed delimiters")
}
Test("hotstring_engine_main: EndChar is not appended when it is in HSE_CONSUMED_DELIMITERS", _THECE_ConsumedDelimitersGuard)
