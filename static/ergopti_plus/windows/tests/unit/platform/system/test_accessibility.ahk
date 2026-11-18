; tests/unit/platform/system/test_accessibility.ahk

; ==============================================================================
; MODULE: Native Accessibility Tests
; DESCRIPTION:
; The native windows, tray icon and tooltips gave a screen reader nothing to
; say (an unnamed « ↺ », a tray icon named after the script file whatever the
; pause, previews that appear where no focus goes) and ignored Windows high
; contrast and « Make text bigger » (a11y-native-2026-11-17). These tests set
; a control's name annotation, announce a real live region,
; and pin the style a high-contrast or scaled system gets.
; ==============================================================================

#Requires AutoHotkey v2.0





; =======================================
; =======================================
; ======= 1/ Native adapter calls =======
; =======================================
; =======================================

_A11yT_SettingsAreReadable() {
	AssertTrue(A11ySystem_HighContrastOn() is Integer, "high contrast is a boolean")
	AssertTrue(A11ySystem_ScreenReaderOn() is Integer, "the screen-reader flag is a boolean")
	Scale := A11ySystem_TextScalePercent()
	AssertTrue(Scale >= 100 && Scale <= 225, "the text scale is 100 to 225 %, got " . Scale)
	AssertTrue(RegExMatch(A11ySystem_SysColorHex(A11Y_SYSINDEX_INFOBK), "^[0-9A-F]{6}$"), "a system colour is RRGGBB")
}
Test("a11y native: the system settings read as typed values (a11y-native-2026-11-17)", _A11yT_SettingsAreReadable)

; Reading the name back through MSAA blocks inside the test process (the
; proxy waits on the window's own thread), so this pins that oleacc accepts
; the annotation: a wrong property GUID or call layout is refused with
; E_INVALIDARG. The spoken name is a TODO-tests-windows.md check.
_A11yT_SymbolButtonGetsItsName() {
	G := Gui()
	try {
		Btn := G.Add("Button", "w28 h24", "↺")
		AssertTrue(A11ySystem_SetAccessibleName(Btn.Hwnd, "Restore default: Delay (ms)"),
			"oleacc must accept the name annotation of a live control")
		AssertFalse(A11ySystem_SetAccessibleName(0, "no window"), "a missing window is refused, not ignored")
	} finally G.Destroy()
}
Test("a11y native: a symbol button takes its given name (a11y-native-2026-11-17)", _A11yT_SymbolButtonGetsItsName)

_A11yT_NotificationIsAccepted() {
	G := Gui()
	try {
		AssertTrue(A11ySystem_Announce(G.Hwnd, "preview"),
			"a driver window must become a named live region and announce it")
		AssertFalse(A11ySystem_Announce(G.Hwnd, ""), "an empty text is not announced")
		AssertFalse(A11ySystem_Announce(0, "preview"), "no window, no announcement")
	} finally G.Destroy()
}
Test("a11y native: a live region is announced (a11y-native-2026-11-17)", _A11yT_NotificationIsAccepted)





; ================================
; ================================
; ======= 2/ Tooltip style =======
; ================================
; ================================

_A11yT_Base() {
	Base := Map("UI_BG_HEX", "242424", "UI_FONT_SIZE_MAIN", 12, "UI_FONT_SIZE_HINT", 10, "UI_FONT_SIZE_INFO", 8)
	for Name in UI_STYLE_TEXT_COLOR_NAMES
		Base[Name] := "ABCDEF"
	return Base
}

_A11yT_HighContrastRepaintsEveryText() {
	Values := UiStyle_AccessibleValues(_A11yT_Base(),
		{HighContrast: true, TextScalePercent: 100, InfoBkHex: "000000", InfoTextHex: "FFFF00"})
	AssertEqual("000000", Values["UI_BG_HEX"], "the theme's tooltip background")
	for Name in UI_STYLE_TEXT_COLOR_NAMES
		AssertEqual("FFFF00", Values[Name], Name . " must take the theme's tooltip text colour")
	AssertTrue(Values["UI_HIGH_CONTRAST"])
	AssertEqual(12, Values["UI_FONT_SIZE_MAIN"])
}
Test("a11y style: high contrast paints every tooltip text in the theme colour (a11y-native-2026-11-17)",
	_A11yT_HighContrastRepaintsEveryText)

_A11yT_TextScaleEnlargesFonts() {
	Values := UiStyle_AccessibleValues(_A11yT_Base(),
		{HighContrast: false, TextScalePercent: 150, InfoBkHex: "000000", InfoTextHex: "FFFF00"})
	AssertEqual(18, Values["UI_FONT_SIZE_MAIN"])
	AssertEqual(15, Values["UI_FONT_SIZE_HINT"])
	AssertEqual(12, Values["UI_FONT_SIZE_INFO"])
	AssertEqual("242424", Values["UI_BG_HEX"], "without high contrast the colours stay the shared ones")
	AssertFalse(Values["UI_HIGH_CONTRAST"])
}
Test("a11y style: « Make text bigger » enlarges the tooltip fonts (a11y-native-2026-11-17)", _A11yT_TextScaleEnlargesFonts)

; Applying high contrast then leaving it restores the shared values exactly.
_A11yT_ApplyRestoresBase() {
	global _UiStyleBase, _UiStyleAppliedKey
	SavedBase := _UiStyleBase, SavedKey := _UiStyleAppliedKey
	Before := _UiStyleSnapshot()
	try {
		_UiStyleBase := Before.Clone()
		_UiStyleAppliedKey := ""
		HC := {HighContrast: true, TextScalePercent: 100, InfoBkHex: "000000", InfoTextHex: "FFFF00"}
		AssertTrue(UiStyle_ApplySystemAccessibility(HC))
		Tooltip_UpdateStyles()
		AssertEqual("FFFF00", UI_TEXT_HEX)
		AssertEqual("000000", _TooltipMixTintHex("#FF0000"), "no hue wash under a contrast theme")
		AssertFalse(UiStyle_ApplySystemAccessibility(HC), "a repeated settings broadcast changes nothing")
		AssertTrue(UiStyle_ApplySystemAccessibility({HighContrast: false, TextScalePercent: 100,
			InfoBkHex: "000000", InfoTextHex: "FFFF00"}))
		for Name, Value in Before
			AssertEqual(Value, _UiStyleRead(Name), Name . " must come back to its shared value")
		AssertFalse(UI_HIGH_CONTRAST)
	} finally {
		for Name, Value in Before
			_UiStyleWrite(Name, Value)
		_UiStyleWrite("UI_HIGH_CONTRAST", false)
		_UiStyleBase := SavedBase, _UiStyleAppliedKey := SavedKey
		Tooltip_UpdateStyles()
	}
}
Test("a11y style: leaving high contrast restores the shared tooltip style (a11y-native-2026-11-17)", _A11yT_ApplyRestoresBase)





; ========================================
; ========================================
; ======= 3/ Tooltip announcements =======
; ========================================
; ========================================

_A11yT_AnnouncementSaysWhatIsRead() {
	Items := [{Text: "bonjour"}, {Text: "bonsoir", IsDimmed: true}, {Text: "bonne nuit"}]
	AssertEqual("bonjour`nbonne nuit", _TooltipAnnouncementText(Items, 0),
		"the struck-through alternates are not said")
	Streaming := {IsFinal: false, Slots: ["partial"], ActiveIdx: 1}
	AssertEqual("", _TooltipAnnouncementText([], Streaming), "a streaming prediction is not said")
	Final := {IsFinal: true, Slots: ["first", "second"], ActiveIdx: 2}
	AssertEqual("second", _TooltipAnnouncementText([], Final), "the selected final line is said")
}
Test("a11y tooltip: the notice says the previews and the final prediction (a11y-native-2026-11-17)",
	_A11yT_AnnouncementSaysWhatIsRead)

_A11yT_AnnounceOnlyWithScreenReader() {
	global _TooltipLastAnnouncement, _TooltipLastAnnouncementTick
	SavedText := _TooltipLastAnnouncement, SavedTick := _TooltipLastAnnouncementTick
	Calls := []
	Record(Hwnd, Text) {
		Calls.Push(Text)
		return true
	}
	Items := [{Text: "a11y-preview-" . A_TickCount}]
	try {
		AssertEqual("", _TooltipAnnouncePresented(Items, 0, () => false, Record), "no screen reader, no notice")
		Said := _TooltipAnnouncePresented(Items, 0, () => true, Record)
		AssertEqual(Items[1].Text, Said)
		AssertEqual("", _TooltipAnnouncePresented(Items, 0, () => true, Record),
			"a re-render of the same preview is not said twice")
		Sleep(50)
		AssertEqual(1, Calls.Length, "the notice is raised once, on a timer turn")
	} finally {
		_TooltipLastAnnouncement := SavedText, _TooltipLastAnnouncementTick := SavedTick
	}
}
Test("a11y tooltip: previews reach a running screen reader once (a11y-native-2026-11-17)", _A11yT_AnnounceOnlyWithScreenReader)





; =============================
; =============================
; ======= 4/ Tray state =======
; =============================
; =============================

_A11yT_TrayTipNamesThePause() {
	Running := TrayStateTipText(false), Paused := TrayStateTipText(true)
	AssertTrue(Running != "" && Paused != "" && Running != Paused, "the tray text differs when paused")
	Sets := []
	SetFn(Text) {
		Sets.Push(Text)
		return true
	}
	AssertTrue(TrayPublishStateTip(true, SetFn, (T) => false))
	AssertEqual(Paused, Sets[1])
	AssertTrue(TrayPublishStateTip(false, SetFn, (T) => true))
	AssertEqual(1, Sets.Length, "the navigation layer holds the tray: nothing is written")
}
Test("a11y tray: the tray text names the pause (a11y-native-2026-11-17)", _A11yT_TrayTipNamesThePause)

; A pause while the navigation layer shows its name in the tray must survive
; the layer's restoration.
_A11yT_LayerRestoresTheRebasedText() {
	Writes := []
	WriteTitle(Text) {
		Writes.Push(Text)
		return true
	}
	Label := () => "navigation layer"
	try {
		AssertTrue(NavigationLayerUpdateIndicator(true, () => "Ergopti+", WriteTitle, Label))
		AssertTrue(NavigationLayerIndicatorRebase("Ergopti+ (paused)"))
		AssertTrue(NavigationLayerUpdateIndicator(false, () => "unused", WriteTitle, Label))
		AssertEqual("Ergopti+ (paused)", Writes[Writes.Length])
		AssertFalse(NavigationLayerIndicatorRebase("Ergopti+"), "no layer, no rebase")
	} finally {
		NavigationLayerUpdateIndicator(false, () => "", WriteTitle, Label)
	}
}
Test("a11y tray: the navigation layer restores the pause text set meanwhile (a11y-native-2026-11-17)",
	_A11yT_LayerRestoresTheRebasedText)





; ======================================
; ======================================
; ======= 4/ Native window fonts =======
; ======================================
; ======================================

; « Make text bigger » left every native window's explicit size unchanged:
; « s10 » stayed 10 pt at 200 % (a11y-text-scale-2026-11-18).
_A11yT_FontOptionsFollowTheTextScale() {
	AssertEqual("s10 bold cFFFFFF", Gui_FontOptions("s10 bold cFFFFFF", 100), "100 % keeps the size")
	AssertEqual("s15 bold cFFFFFF", Gui_FontOptions("s10 bold cFFFFFF", 150))
	AssertEqual("s20 norm", Gui_FontOptions("s9 norm", 225), "9 pt at 225 % rounds to 20 pt")
	AssertEqual("w700 s25 c3A3A3A", Gui_FontOptions("w700 s11 c3A3A3A", 225), "a size after other options")
	AssertEqual("S14", Gui_FontOptions("S11", 125), "the option letter is case-insensitive")
	AssertEqual("cGray strike", Gui_FontOptions("cGray strike", 200), "no size, nothing to scale")
	AssertEqual("s2", Gui_FontOptions("s1", 200), "a 1 pt spacer stays at least 1 pt")
	AssertThrows(() => Gui_FontOptions("s10", 0), "a scale under 100 % is refused, not used")
	AssertThrows(() => Gui_FontOptions("s10", "150"), "a scale that is not an integer is refused")
}
Test("a11y fonts: native window sizes follow the system text scale (a11y-text-scale-2026-11-18)",
	_A11yT_FontOptionsFollowTheTextScale)

; The real setting reaches a real control: the font Windows returns for a
; control set through Gui_SetFont is the scaled size.
_A11yT_SetFontReachesTheControl() {
	G := Gui()
	try {
		Label := G.AddText("", "Aa")
		Gui_SetFont(Label, "s20", "Segoe UI")
		Font := SendMessage(0x0031, 0, 0, Label)   ; WM_GETFONT
		Info := Buffer(92, 0)                        ; LOGFONTW
		AssertTrue(DllCall("GetObjectW", "Ptr", Font, "Int", Info.Size, "Ptr", Info, "Int") > 0, "the control has a font")
		Px := Abs(NumGet(Info, 0, "Int"))
		Expected := Round(Round(20 * A11ySystem_TextScalePercent() / 100) * A_ScreenDPI / 72)
		AssertTrue(Abs(Px - Expected) <= 1, "the font must be the scaled size: " . Px . " px, expected " . Expected)
	} finally G.Destroy()
}
Test("a11y fonts: Gui_SetFont gives the control the scaled font (a11y-text-scale-2026-11-18)",
	_A11yT_SetFontReachesTheControl)
