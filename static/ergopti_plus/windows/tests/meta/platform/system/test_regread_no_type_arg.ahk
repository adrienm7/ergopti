; tests/meta/platform/system/test_regread_no_type_arg.ahk

; ==============================================================================
; MODULE: Reg_ReadBinary No Third Argument Guard
; DESCRIPTION:
; Static source guard for the Reg_ReadBinary invalid third-argument fix in
; settings/engine/registry.ahk.
;
; ROOT CAUSE ENCODED:
; AHK v2's RegRead() accepts exactly two arguments: (KeyPath, ValueName). In
; AHK v1 there was a third argument for the value type, but v2 removed it and
; passing "REG_BINARY" as a third argument causes a runtime error. The fix
; removes the third argument from the RegRead call inside Reg_ReadBinary. This
; test verifies the bad call form is absent from the function body.
; ==============================================================================

#Requires AutoHotkey v2.0

; Reads the whole production file that defines Symbol, wherever it lives: a
; base name stops naming one file once the structure plan renames its owner.
_TRNTA_ReadSource(Symbol) {
	return _DriverResolveConstants(FileRead(_DriverProductionFileForSymbol(Symbol), "UTF-8"))
}

_TRNTA_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}





; ================================================================
; ================================================================
; ======= 1/ Reg_ReadBinary calls RegRead with 2 args only =======
; ================================================================
; ================================================================

_TRNTA_NoThirdArg() {
	Src := _TRNTA_StripLineComments(_TRNTA_ReadSource("Reg_ReadBinary"))
	Assert(Src != "", "settings/engine/registry.ahk must be readable")

	Body := _DriverFuncBody("Reg_ReadBinary")
	Assert(Body != "", "Reg_ReadBinary must be defined in settings/engine/registry.ahk")

	; The broken AHK v1 form passes "REG_BINARY" as third argument
	Assert(InStr(Body, "REG_BINARY") = 0,
		"Reg_ReadBinary must NOT pass REG_BINARY as a third arg to RegRead — AHK v2 RegRead takes only 2 arguments")

	; The correct 2-argument form must be present
	Assert(InStr(Body, "RegRead(keyPath, valueName)") > 0,
		"Reg_ReadBinary must call RegRead(keyPath, valueName) with exactly 2 arguments")
}
Test("registry: Reg_ReadBinary calls RegRead with 2 args only — no v1 REG_BINARY third arg", _TRNTA_NoThirdArg)
