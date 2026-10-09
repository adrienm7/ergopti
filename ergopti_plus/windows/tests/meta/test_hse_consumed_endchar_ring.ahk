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

; Native completion records the actual committed scalar tail, never erase syntax.


_HCER_AssertNotepadBranchDoesNotCorruptRing() {
	_NHAB_AssertNativeRoute()
	Commit := _DriverFuncBody("_HSE_CommitNotepadOwner")
	Assert(Commit != "", "native Notepad canonical commit must exist")
	Code := _DriverMaskNonCode(&Commit)
	Assert(RegExMatch(Code, "im)^\s*InsertedText\s*:=\s*Owner\[", &Load),
		"native ring commit must load its owned inserted text")
	Assert(RegExMatch(SubStr(Commit, Load.Pos), 'i)^\s*InsertedText\s*:=\s*Owner\["PlainInsertedText"\]'),
		"native ring commit must load the exact visible literal, not a control sequence")
	Guard := InStr(Code, "if !A_IsCritical")
	Mirror := InStr(Code, "_HSE_MirrorCanonicalEffectToLlm(Effect)")
	Ring := InStr(Code, "UpdateLastSentCharacter(SubStr(InsertedText, -_TextTailCodeUnits(InsertedText, 1)))")
	Assert(Guard > 0 && Load.Pos > Guard && Mirror > Load.Pos && Ring > Mirror,
		"native Notepad ring must commit the scalar tail after its canonical mirror under Critical")
	Assert(!RegExMatch(Code, "i)\bSendNewResult\s*\("),
		"native Notepad ring commit must not send an erase control sequence")
}
Test("hotstrings: Notepad branch does not corrupt the last-sent ring with the backspace sequence (F8)", _HCER_AssertNotepadBranchDoesNotCorruptRing)
