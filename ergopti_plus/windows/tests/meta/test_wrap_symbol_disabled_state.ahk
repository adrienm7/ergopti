; tests/meta/test_wrap_symbol_disabled_state.ahk

; ==============================================================================
; MODULE: Wrap Symbol Disabled State Meta Test
; DESCRIPTION:
; Static source guard for the "wrap-symbol-disabled-state-roundtrip-loss" finding.
; ==============================================================================

#Requires AutoHotkey v2.0

_TWD_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_TWD_Check() {
	Src := _TWD_ReadSource("infra/wrap_symbols_config.ahk")
	Assert(Src != "", "Source file wrap_symbols_config.ahk must exist")
	Assert(InStr(Src, "[[disabled]]") > 0, "wrap_symbols_config.ahk must use [[disabled]] array format")
	Assert(InStr(Src, "char = ") > 0, "wrap_symbols_config.ahk must save char individually")
}

Test("WrapSymbols: persistence formats preserves whitespace tokens", _TWD_Check)
