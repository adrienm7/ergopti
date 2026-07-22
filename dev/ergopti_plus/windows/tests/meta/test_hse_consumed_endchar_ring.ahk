; tests/meta/test_hse_consumed_endchar_ring.ahk

; ==============================================================================
; MODULE: HSE Consumed End-Char Ring Desync Meta Test
; DESCRIPTION:
; Static source guard for finding consumed-endchar-ring-desync (F-L02).
;
; In the atomic dispatch branch, EndCharPart correctly drops a CONSUMED delimiter
; (one the user opted into HSE_CONSUMED_DELIMITERS) so it is not emitted. But the
; last-sent ring update recorded the RAW EndChar, so after firing an end-char-gated
; trigger followed by a consumed delimiter the ring drifted from the screen by one
; character — and a later deadkey/ellipsis decision (which reads the ring) could
; mis-fire. The fix records the EMITTED end-char (EndCharPart) instead.
;
; The sibling screen-mirror HSE_Buffer already guards this exact case. Meta-static
; file scan so a regression to the raw EndChar fails the suite.
; ==============================================================================

#Requires AutoHotkey v2.0


_HCER_AssertRingUsesEmittedEndChar() {
	; Scan the whole driver source so the test survives a file move of the engine.
	Src := _DriverSourceConcat()
	Assert(InStr(Src, "UpdateLastSentCharacter(SubStr(EndCharPart") > 0,
		"the atomic-branch UpdateLastSentCharacter must record the EMITTED end-char (EndCharPart, which drops a consumed delimiter), not the raw EndChar (consumed-endchar-ring-desync)")
	Assert(!InStr(Src, "UpdateLastSentCharacter(SubStr(EndChar !="),
		"the atomic-branch UpdateLastSentCharacter must NOT record the raw EndChar — a consumed delimiter is not emitted, so recording it desyncs the last-sent ring from the screen (consumed-endchar-ring-desync)")
}
Test("hotstrings: atomic-branch ring records the emitted end-char, not the raw EndChar (consumed-endchar-ring-desync)", _HCER_AssertRingUsesEmittedEndChar)




; ===================================================================
; ===================================================================
; ======= 2/ Notepad-branch ring corruption guard (F8) =============
; ===================================================================
; ===================================================================

; Extracts the Notepad branch body from HSE_DispatchMatch: the block that
; starts with `if IsNotepadApp {` and ends at the matching `} else {` that
; opens the atomic branch. Mirrors _THNCD_ExtractNotepadBranch in
; tests/meta/test_hse_notepad_consumed_delimiter.ahk.
_HCER_ExtractNotepadBranch(Src) {
	Marker := "if IsNotepadApp {"
	StartIdx := InStr(Src, Marker)
	if !StartIdx
		return ""
	ElseMarker := "} else {"
	ElseIdx := InStr(Src, ElseMarker, , StartIdx)
	if !ElseIdx
		return SubStr(Src, StartIdx)
	return SubStr(Src, StartIdx, ElseIdx - StartIdx + StrLen(ElseMarker))
}

_HCER_AssertNotepadBranchDoesNotCorruptRing() {
	Src := _DriverSourceConcat()
	Branch := _HCER_ExtractNotepadBranch(Src)
	Assert(Branch != "", "HSE_DispatchMatch's Notepad branch (if IsNotepadApp) must exist")

    ; The erase is now part of SendInstant's one SendInput transaction. It must
    ; never pass through SendNewResult, whose normal ring update would record the
    ; control sequence's trailing "}" instead of a character visible in Notepad.
    Assert(InStr(Branch, "SendNewResult(BackSpaceSeq") = 0,
        "Notepad branch must not send BackSpaceSeq through SendNewResult; SendInstant owns the atomic erase+paste transaction (F8)")

	; The REAL emitted text (the clipboard paste) must feed the ring explicitly,
	; mirroring the atomic branch's UpdateLastSentCharacter(SubStr(EndCharPart ...))
	; call right after its SendInput burst.
	Assert(InStr(Branch, "UpdateLastSentCharacter(SubStr(EndCharEmitted") > 0,
		"Notepad branch must call UpdateLastSentCharacter with the real emitted text (EndCharEmitted / Replacement) after the paste, mirroring the atomic branch (F8)")
}
Test("hotstrings: Notepad branch does not corrupt the last-sent ring with the backspace sequence (F8)", _HCER_AssertNotepadBranchDoesNotCorruptRing)
