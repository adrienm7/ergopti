; tests/meta/test_hse_notepad_consumed_delimiter.ahk

; ==============================================================================
; MODULE: HSE Notepad Branch Consumed Delimiter Guard
; DESCRIPTION:
; Static source guard for the Notepad clipboard branch of HSE_DispatchMatch in
; infra/hotstrings/hotstring_engine_main.ahk.
;
; ROOT CAUSE ENCODED:
; The Notepad branch unconditionally sent `SendInstant(Replacement . EndChar)`,
; ignoring HSE_CONSUMED_DELIMITERS. The atomic branch and HSE_ApplyExpansion
; both guard with `!InStr(HSE_CONSUMED_DELIMITERS, EndChar)`. Without the same
; guard, a space (or any other consumed delimiter) was re-injected after the
; clipboard paste, producing a double-space or spurious character.
;
; The fix introduces EndCharEmitted in the Notepad branch with the same guard:
;   EndCharEmitted := (EndChar != "" and !InStr(HSE_CONSUMED_DELIMITERS, EndChar))
;                     ? EndChar : ""
; and uses `Replacement . EndCharEmitted` in the SendInstant call and SentBurst
; trace. This test asserts that the guard is present and the bare unguarded form
; does not appear in the Notepad branch.
; ==============================================================================

#Requires AutoHotkey v2.0


; ===========================================================
; ===========================================================
; ======= 1/ Source extraction helpers ======================
; ===========================================================
; ===========================================================

; Extracts the Notepad branch body from HSE_DispatchMatch: the block that starts
; with `if IsNotepadApp {` and ends at the matching closing brace before `} else {`.
_THNCD_ExtractNotepadBranch(Src) {
	; Locate the Notepad branch opener
	Marker := "if IsNotepadApp {"
	StartIdx := InStr(Src, Marker)
	if !StartIdx
		return ""
	; The Notepad block ends at the `} else {` that immediately follows it.
	ElseMarker := "} else {"
	ElseIdx := InStr(Src, ElseMarker, , StartIdx)
	if !ElseIdx
		return SubStr(Src, StartIdx)
	return SubStr(Src, StartIdx, ElseIdx - StartIdx + StrLen(ElseMarker))
}


; =========================================================
; =========================================================
; ======= 2/ Consumed-delimiter guard assertions ==========
; =========================================================
; =========================================================

_THNCD_NotepadBranchHasConsumedDelimiterGuard() {
	Src := _DriverDirConcat("infra/hotstrings")
	Assert(Src != "", "infra/hotstrings/hotstring_engine_main.ahk must be readable")

	Branch := _THNCD_ExtractNotepadBranch(Src)
	Assert(Branch != "", "Notepad branch (if IsNotepadApp) must exist in HSE_DispatchMatch")

	; The consumed-delimiter guard must be present in the Notepad branch so a
	; consumed end-char (e.g. Space) is not re-injected after the clipboard paste.
	Assert(InStr(Branch, "HSE_CONSUMED_DELIMITERS") > 0,
		"Notepad branch must contain HSE_CONSUMED_DELIMITERS guard (F30: re-emit consumed end-char fix)")

	; The guard variable computed from the consumed-delimiter check must be used
	; in place of the bare EndChar in the SendInstant call.
	Assert(InStr(Branch, "EndCharEmitted") > 0,
		"Notepad branch must use EndCharEmitted (consumed-delimiter-aware) instead of bare EndChar")

	; The bare unguarded form must NOT appear anywhere in the Notepad branch;
	; its presence would mean the guard was added but the call site was not updated.
	Assert(!InStr(Branch, "SendInstant(Replacement . EndChar)"),
		"Notepad branch must NOT contain bare SendInstant(Replacement . EndChar) — use EndCharEmitted instead")
}
Test("hotstring_engine_main: Notepad branch guards EndChar against HSE_CONSUMED_DELIMITERS (F30)", _THNCD_NotepadBranchHasConsumedDelimiterGuard)