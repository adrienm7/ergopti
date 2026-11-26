; static/ergopti_plus/windows/tests/unit/modules/shortcuts/test_wrap_symbols_single_symbol.ahk

; ==============================================================================
; MODULE: Wrap-symbol single-symbol domain regression
; DESCRIPTION:
; A custom wrap symbol is one Unicode scalar, as on macOS and Linux. A
; supplementary scalar (two UTF-16 units) must be accepted, while an empty
; value, two scalars, a lone surrogate and a non-string stay refused.
; ==============================================================================

#Requires AutoHotkey v2.0

_WSSS_AcceptsOneScalar() {
	AssertEqual(true, WrapSymbols_IsSingleSymbol("("))
	AssertEqual(true, WrapSymbols_IsSingleSymbol("«"))
	AssertEqual(true, WrapSymbols_IsSingleSymbol(Chr(0x1F600)))
	AssertEqual(true, WrapSymbols_IsSingleSymbol(Chr(0x1D54F)))
}
Test("WrapSymbols_IsSingleSymbol: one scalar, supplementary included", _WSSS_AcceptsOneScalar)

_WSSS_RefusesOtherShapes() {
	AssertEqual(false, WrapSymbols_IsSingleSymbol(""))
	AssertEqual(false, WrapSymbols_IsSingleSymbol("ab"))
	AssertEqual(false, WrapSymbols_IsSingleSymbol(Chr(0x1F600) . Chr(0x1F600)))
	AssertEqual(false, WrapSymbols_IsSingleSymbol(Chr(0xD83D)))
	AssertEqual(false, WrapSymbols_IsSingleSymbol(5))
}
Test("WrapSymbols_IsSingleSymbol: refuses empty, several scalars, orphan surrogate", _WSSS_RefusesOtherShapes)
