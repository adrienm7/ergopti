; tests/unit/ui/windows/test_hcw_palette_generated.ahk

; ==============================================================================
; MODULE: Hotstrings Window Palette Source Tests
; DESCRIPTION:
; The settings window's colour picker offers the palette generated from
; _shared/data/native_theme.toml, like the macOS and Linux windows. It used to
; type the 14 colours again and a node gate compared the copies; a generated
; palette has no copy to compare. test-drift-guard keeps the generated file
; current, these tests keep the window reading it.
; ==============================================================================

#Requires AutoHotkey v2.0

_HPG_WindowOffersTheGeneratedPalette() {
	global _HCW_COLOR_PRESETS
	Saved := _HCW_COLOR_PRESETS
	try {
		_HCW_InitLocaleStrings()
		Palette := NativeThemeHotstringPalette()
		AssertEqual(14, Palette.Length, "the three drivers offer the same 14 colours")
		AssertEqual(Palette.Length + 1, _HCW_COLOR_PRESETS.Length, "the inherit row, then the palette")
		AssertEqual("", _HCW_COLOR_PRESETS[1]["Hex"], "the first row inherits")
		for Index, Row in Palette {
			Offered := _HCW_COLOR_PRESETS[Index + 1]
			AssertEqual(Row["Hex"], Offered["Hex"], Row["Name"] . ": the hex of the source")
			AssertEqual(t(Row["I18n"]), Offered["Label"], Row["Name"] . ": the label of the source")
		}
	} finally _HCW_COLOR_PRESETS := Saved
}
Test("hotstrings window: the colour picker offers the generated palette in its order (palette-single-source)",
	_HPG_WindowOffersTheGeneratedPalette)

_HPG_NoColourIsTypedAgain() {
	Body := _DriverFuncBody("_HCW_InitLocaleStrings")
	Assert(Body != "", "_HCW_InitLocaleStrings must exist")
	Assert(InStr(Body, "NativeThemeHotstringPalette()") > 0, "the window must read the generated palette")
	AssertEqual(0, RegExMatch(Body, "#[0-9a-fA-F]{6}"), "no colour is typed beside the generated palette")
}
Test("hotstrings window: no palette colour is typed in the window helpers (palette-single-source)",
	_HPG_NoColourIsTypedAgain)
