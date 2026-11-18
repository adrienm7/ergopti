; tests/meta/platform/system/test_accessibility_sources.ahk

; ==============================================================================
; MODULE: Native Accessibility Source Guards
; DESCRIPTION:
; Source guards for native windows a screen reader read wrongly
; (a11y-native-2026-11-17): TrayTip calls that passed the title as the text
; (read in the wrong order), Edit and drop-down controls with no label before
; them, « ↺ » buttons read as a symbol and a colour swatch read as a progress
; bar. Each guard covers the whole class, not only the site found.
; ==============================================================================

#Requires AutoHotkey v2.0

; Every TrayTip in the driver takes (Text, Title): a translated *title key as the
; first argument is the swapped order.
_A11yS_NoTrayTipStartsWithATitle() {
	Offenders := []
	for Path in _DriverProductionSourceCensus().Paths {
		Src := FileRead(Path, "UTF-8")
		Pos := 1
		while Pos := RegExMatch(Src, 'TrayTip\(\s*t\("[A-Za-z0-9_.]*title"\)', &M, Pos) {
			Offenders.Push(Path . ": " . M[0])
			Pos += StrLen(M[0])
		}
	}
	AssertEqual(0, Offenders.Length, "TrayTip takes the text first, then the title: " . (Offenders.Length ? Offenders[1] : ""))
}
Test("a11y sources: no TrayTip passes its title as the text (a11y-native-2026-11-17)", _A11yS_NoTrayTipStartsWithATitle)

; The label text a screen reader names a control by must come just before it.
_A11yS_LabelPrecedes(FileName, LabelKey, ControlNeedle) {
	Src := _DriverFileSource(FileName)
	ControlPos := InStr(Src, ControlNeedle)
	Assert(ControlPos > 0, FileName . " must still create " . ControlNeedle)
	LabelPos := InStr(SubStr(Src, 1, ControlPos), 't("' . LabelKey . '")', , -1)
	Assert(LabelPos > 0 && ControlPos - LabelPos < 200,
		FileName . ": the label " . LabelKey . " must be added just before " . ControlNeedle)
}

_A11yS_FieldsAreLabelled() {
	_A11yS_LabelPrecedes("editors.ahk", "dialog.gpt_link.label", 'GuiToShow.Add("Edit"')
	_A11yS_LabelPrecedes("input_probe.ahk", "input_probe.field_label", "Window.AddEdit(")
	_A11yS_LabelPrecedes("changelog.ahk", "healthcheck.field.channel", 'G.Add("DropDownList"')
	Src := _DriverFileSource("changelog.ahk")
	Assert(InStr(Src, 'A11ySystem_SetAccessibleName(RightPaneEdit.Hwnd'), "the release notes must be named")
}
Test("a11y sources: the unlabelled native fields have a label (a11y-native-2026-11-17)", _A11yS_FieldsAreLabelled)

_A11yS_HotstringWindowControlsAreNamed() {
	Src := _DriverFileSource("hcw_helpers.ahk")
	Assert(!InStr(Src, 'G.Add("Progress"'), "the colour swatch must not be a progress bar")
	Resets := 0, Pos := 1
	while Pos := RegExMatch(Src, '(\w+) := G\.Add\("Button", "[^"]*", "↺"\)', &M, Pos) {
		Resets += 1
		Assert(RegExMatch(Src, "\[" . M[1] . ', "hs_config\.label_'), M[1] . " must be named by what it restores")
		Pos += StrLen(M[0])
	}
	AssertEqual(4, Resets, "the four « ↺ » buttons must still be found")
	Assert(InStr(Src, "A11ySystem_SetAccessibleName(Pair[1].Hwnd"), "the names must reach the controls")
}
Test("a11y sources: the hotstring window's symbol buttons are named (a11y-native-2026-11-17)",
	_A11yS_HotstringWindowControlsAreNamed)

; A size given straight to SetFont ignores « Make text bigger »; every native
; window goes through Gui_SetFont (a11y-text-scale-2026-11-18). The tooltips
; scale their sizes through the style globals, the WPM pill keeps the canon's
; fixed geometry, and the helper itself is the one direct call.
_A11yS_FontSizesFollowTheTextScale() {
	static Exempt := ["/core/ui/engine/font_scale.ahk", "/core/ui/ui/tooltip/", "/ui/wpm/wpm_widget.ahk"]
	Offenders := [], Scanned := 0, Routed := 0
	for Path in _DriverProductionSourceCensus().Paths {
		Unix := StrReplace(Path, "\", "/")
		Src := _StripFullLineComments(FileRead(Path, "UTF-8"))
		Pos := 1
		while Pos := RegExMatch(Src, "Gui_SetFont\(", &M, Pos)
			Routed += 1, Pos += M.Len
		Skip := false
		for Part in Exempt
			Skip := Skip || InStr(Unix, Part)
		if Skip
			continue
		Scanned += 1
		Pos := 1
		while Pos := RegExMatch(Src, 'i)\.SetFont\(\s*"(?:[^"]*\s)?s(?:\d|"\s*\.)', &M, Pos) {
			Offenders.Push(Path . ": " . M[0])
			Pos += M.Len
		}
	}
	Assert(Scanned > 100, "the census must reach the driver's sources, scanned " . Scanned)
	Assert(Routed >= 19, "the native windows must still set their fonts through Gui_SetFont, found " . Routed)
	AssertEqual(0, Offenders.Length, "a font size must go through Gui_SetFont: " . (Offenders.Length ? Offenders[1] : ""))
}
Test("a11y sources: native font sizes go through Gui_SetFont (a11y-text-scale-2026-11-18)",
	_A11yS_FontSizesFollowTheTextScale)
