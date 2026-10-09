; tests/meta/test_hse_notepad_consumed_delimiter.ahk

; ==============================================================================
; MODULE: HSE Notepad Branch Consumed Delimiter Guard
; DESCRIPTION:
; Consumption is resolved once before dispatch branches. The native edit owner
; must retain that filtered literal and must not re-emit a consumed delimiter.
; This guards F30 after asynchronous receiving replaced the clipboard strategy.
; ==============================================================================

#Requires AutoHotkey v2.0


; ===========================================================
; ===========================================================
; ======= 1/ Source extraction helpers ======================
; ===========================================================
; ===========================================================

; Native output receives the shared consumption decision before owner creation.



; =========================================================
; =========================================================
; ======= 2/ Consumed-delimiter guard assertions ==========
; =========================================================
; =========================================================

_THNCD_NotepadBranchHasConsumedDelimiterGuard() {
	_NHAB_AssertNativeRoute()
	Dispatch := _DriverFuncBody("HSE_DispatchMatch")
	Constructor := _DriverFuncBody("_HSE_NewNotepadOwner")
	Assert(Dispatch != "" && Constructor != "", "native delimiter owners must exist")
	Code := _DriverMaskNonCode(&Dispatch)
	Assert(RegExMatch(Code, "i)\bEndCharPart\s*:=([^\n]*(?:\n[^\n]*)?)", &Assignment),
		"dispatch must derive the shared emitted delimiter")
	Branch := _NHAB_NativeBranch(Dispatch)
	BranchCode := _DriverMaskNonCode(&Branch)
	Assert(RegExMatch(Assignment[1], "i)!ForceConsumeEndChar[\s\S]*!InStr\(HSE_CONSUMED_DELIMITERS,\s*EndChar\)"),
		"the shared delimiter must honor both explicit consumption authorities")
	Assert(Assignment.Pos < InStr(Code, "if IsNotepadApp {"),
		"delimiter consumption must be resolved before the native branch")
	Assert(RegExMatch(BranchCode, "i)_HSE_NewNotepadOwner\(\s*Spec,\s*Replacement,\s*EndCharPart,"),
		"native output must receive the centrally filtered delimiter")
	ConstructorCode := _DriverMaskNonCode(&Constructor)
	Assert(RegExMatch(ConstructorCode, "i)Replacement\s*\.\s*EndCharPart"),
		"the native owner must retain replacement plus the filtered delimiter")
	AssertContains(Constructor, '"PlainInsertedText", Replacement . EndCharPart',
		"the visible literal field must bind that filtered delimiter")
}
Test("hotstring_engine_main: Notepad branch guards EndChar against HSE_CONSUMED_DELIMITERS (F30)", _THNCD_NotepadBranchHasConsumedDelimiterGuard)