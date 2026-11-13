; tests/meta/shortcuts/engine/test_wrap_remap_uses_saved_custom_pair.ahk

; ==============================================================================
; MODULE: Remapped Wrap Keys Honour a Saved Custom Pair Meta Test
; DESCRIPTION:
; Regression guard for the Windows wrap-symbols parity audit finding WSW-001.
; It is read from source because the remap chain ends in a real selection and a
; real SendInput burst.
;
; The Ergopti remap routes call WrapTextIfSelected with the delimiters their layout
; descriptor carries, which are the built-in ones. A pair saved from the tray
; (for example # ... ~) was published to the active pairs but never read there, so
; the key wrapped as # ... # while the prefix route wrapped as # ... ~.
; WrapTextIfSelected now asks WrapSymbols_CustomPairFor for the saved pair of the
; typed symbol before it builds the output. The built-in disable gate is unchanged.
; ==============================================================================

#Requires AutoHotkey v2.0

_WRC_RemapReadsSavedPair() {
	Body := _StripFullLineComments(_DriverFuncBody("WrapTextIfSelected"))
	Assert(Body != "", "WrapTextIfSelected must exist in the keymap layout module")
	GatePos := InStr(Body, "WrapSymbols_IsEnabled(LeftSymbol)")
	LookupPos := InStr(Body, "WrapSymbols_CustomPairFor(Symbol)")
	SendPos := InStr(Body, "SendInstant(LeftSymbol Selection RightSymbol,")
	Assert(GatePos > 0, "the built-in disable gate must stay in place")
	Assert(LookupPos > GatePos,
		"the saved custom pair must be resolved after the enable gate")
	Assert(SendPos > LookupPos,
		"the wrapped text must be built from the delimiters resolved from the saved pair")
	Assert(InStr(Body, "LeftSymbol := CustomPair[" . Chr(34) . "left" . Chr(34) . "]") > 0
		&& InStr(Body, "RightSymbol := CustomPair[" . Chr(34) . "right" . Chr(34) . "]") > 0,
		"both delimiters must come from the saved pair")
}
Test("wrap-remap: a saved custom pair overrides the layout descriptor delimiters", _WRC_RemapReadsSavedPair)

_WRC_LookupMatchesEitherEnd() {
	Body := _StripFullLineComments(_DriverFuncBody("WrapSymbols_CustomPairFor"))
	Assert(Body != "", "WrapSymbols_CustomPairFor must exist in the wrap-symbols config module")
	Assert(InStr(Body, "_WS_Custom") > 0, "the lookup must read the saved custom pairs")
	Assert(RegExMatch(Body, "s)Pair\[.left.\] == Symbol \|\| Pair\[.right.\] == Symbol") > 0,
		"a custom pair must match its opening and its closing character")
}
Test("wrap-remap: the custom pair lookup matches either end of the pair", _WRC_LookupMatchesEitherEnd)
