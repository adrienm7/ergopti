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
}
Test("a11y sources: the unlabelled native fields have a label (a11y-native-2026-11-17)", _A11yS_FieldsAreLabelled)

; A size given straight to SetFont ignores « Make text bigger »; every native
; window goes through Gui_SetFont (a11y-text-scale-2026-11-18). The tooltips
; scale their sizes through the style globals, the WPM pill keeps the canon's
; fixed geometry, and the helper itself is the one direct call.
_A11yS_FontSizesFollowTheTextScale() {
	; The helper and the WPM pill are found by the functions they define, so a
	; move cannot silently drop their exemption.
	ExemptFiles := [_DriverProductionFileForSymbol("Gui_SetFont"), _DriverProductionFileForSymbol("WPMWidget_BuildCompact")]
	static ExemptDirs := ["/core/ui/ui/tooltip/"]
	Offenders := [], Scanned := 0, Routed := 0
	for Path in _DriverProductionSourceCensus().Paths {
		Unix := StrReplace(Path, "\", "/")
		Src := _StripFullLineComments(FileRead(Path, "UTF-8"))
		Pos := 1
		while Pos := RegExMatch(Src, "Gui_SetFont\(", &M, Pos)
			Routed += 1, Pos += M.Len
		Skip := false
		for File in ExemptFiles
			Skip := Skip || (Path = File)
		for Part in ExemptDirs
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
	; The native fallbacks of WebView windows went on 2026-11-21, with their font calls.
	Assert(Routed >= 10, "the native windows must still set their fonts through Gui_SetFont, found " . Routed)
	AssertEqual(0, Offenders.Length, "a font size must go through Gui_SetFont: " . (Offenders.Length ? Offenders[1] : ""))
}
Test("a11y sources: native font sizes go through Gui_SetFont (a11y-text-scale-2026-11-18)",
	_A11yS_FontSizesFollowTheTextScale)

; A fixed text colour in a native window ignores a contrast theme, and the
; « Gray » of three status lines was 3.4:1 on the dialog face
; (a11y-cvd-2026-11-18). The tooltips and the WPM pill paint their own
; surfaces and follow high contrast through the style globals.
_A11yS_NativeTextKeepsTheSystemColour() {
	static Exempt := ["/core/ui/ui/tooltip/", "/ui/wpm/"]
	Offenders := [], Scanned := 0
	for Path in _DriverProductionSourceCensus().Paths {
		Unix := StrReplace(Path, "\", "/")
		Skip := false
		for Part in Exempt
			Skip := Skip || InStr(Unix, Part)
		if Skip
			continue
		Scanned += 1
		Src := _StripFullLineComments(FileRead(Path, "UTF-8"))
		Pos := 1
		while Pos := RegExMatch(Src, 'i)\.(?:Add(?:Text)?|SetFont)\((?:"Text",\s*)?"(?:[^"]*\s)?c(?:Gray|Grey|Silver|Red|Green|Blue|Navy|Maroon|Teal|[0-9A-F]{6})(?=[\s"])', &M, Pos) {
			Offenders.Push(Path . ": " . M[0])
			Pos += M.Len
		}
	}
	Assert(Scanned > 100, "the census must reach the driver's sources, scanned " . Scanned)
	AssertEqual(0, Offenders.Length, "native text keeps the system colour: " . (Offenders.Length ? Offenders[1] : ""))
}
Test("a11y sources: native window text keeps the system colour (a11y-cvd-2026-11-18)",
	_A11yS_NativeTextKeepsTheSystemColour)

; Only the tray owners draw the tray icon. Callers of their own drew a state's
; logo behind `if FileExist(...)`, so a missing paused logo left the running one
; on a paused driver without a word (TRAY-05): TrayApplyStateIcon logs it and
; draws the warning sign, and the port adapter refuses a missing file.
_A11yS_OnlyTheTrayOwnersDrawTheIcon() {
	Offenders := [], Scanned := 0, RunningDraws := 0, Owners := 0
	for Path in _DriverProductionSourceCensus().Paths {
		Src := _StripFullLineComments(FileRead(Path, "UTF-8"))
		; The owners are found by what they define, so the guard pins no path.
		if RegExMatch(Src, "m)^(?:TrayApplyStateIcon|TrayMenuSetIcon)\([^\n]*\)\s*\{") {
			Owners += 1
			continue
		}
		Scanned += 1
		if RegExMatch(Src, "(?<![\w.])TraySetIcon\(")
			Offenders.Push(Path)
		StrReplace(Src, "TrayApplyStateIcon(false, IconPath)", , , &Found)
		RunningDraws += Found
	}
	Assert(Scanned > 100, "the census must reach the driver's sources, scanned " . Scanned)
	AssertEqual(2, Owners, "the state icon owner and the TrayMenu adapter must still be found")
	AssertEqual(0, Offenders.Length, "the tray icon is drawn by TrayApplyStateIcon or the TrayMenu adapter: "
		. (Offenders.Length ? Offenders[1] : ""))
	Body := _DriverFuncBody("UpdateTrayIcon")
	Assert(InStr(Body, "TrayApplyStateIcon(true, IconPathDisabled)") && InStr(Body, "TrayApplyStateIcon(false, IconPath)"),
		"UpdateTrayIcon must draw each pause state from its own file")
	AssertEqual(2, RunningDraws, "the boot icon and the resume draw the running logo through its owner")
}
Test("a11y sources: only the tray owners draw the tray icon (tray-05-2026-11-21)", _A11yS_OnlyTheTrayOwnersDrawTheIcon)
