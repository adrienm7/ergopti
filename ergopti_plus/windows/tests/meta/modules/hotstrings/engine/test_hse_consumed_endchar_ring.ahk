; tests/meta/modules/hotstrings/engine/test_hse_consumed_endchar_ring.ahk

; ==============================================================================
; MODULE: HSE Native Ring Commit Meta Test
; DESCRIPTION:
; Native completion records the actual committed scalar tail, never erase syntax,
; under the Critical section of its canonical commit. The atomic branch's ring is
; driven in unit/modules/hotstrings/engine/test_hse_dispatch_behaviour.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0


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
