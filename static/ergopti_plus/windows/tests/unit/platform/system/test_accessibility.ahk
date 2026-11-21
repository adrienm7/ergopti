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

; The menu's hotstrings.preview_announcements switch (2026-11-21) silences the
; notices while a screen reader runs; the published switch value is what the
; announce path reads, so a menu toggle takes effect without a reload.
_A11yT_AnnounceHonoursTheSwitch() {
	global _TooltipLastAnnouncement, _TooltipLastAnnouncementTick, HSE_PreviewSwitches
	SavedText := _TooltipLastAnnouncement, SavedTick := _TooltipLastAnnouncementTick
	SavedSwitches := HSE_PreviewSwitches.Clone()
	Calls := []
	Record(Hwnd, Text) {
		Calls.Push(Text)
		return true
	}
	Items := [{Text: "a11y-switch-" . A_TickCount}]
	try {
		AssertTrue(ManifestDefaultFor(ConfigKey.HOTSTRINGS_PREVIEW_ANNOUNCEMENTS) == true,
			"the notices are on by default")
		HSE_PreviewSwitchPublish(ConfigLeaf.PREVIEW_ANNOUNCEMENTS, false)
		AssertEqual("", _TooltipAnnouncePresented(Items, 0, () => true, Record),
			"the switch off silences a running screen reader")
		HSE_PreviewSwitchPublish(ConfigLeaf.PREVIEW_ANNOUNCEMENTS, true)
		AssertEqual(Items[1].Text, _TooltipAnnouncePresented(Items, 0, () => true, Record),
			"the switch on lets the notice through")
		Sleep(50)
		AssertEqual(1, Calls.Length, "only the notice under the switch on is raised")
	} finally {
		HSE_PreviewSwitches := SavedSwitches
		_TooltipLastAnnouncement := SavedText, _TooltipLastAnnouncementTick := SavedTick
	}
}
Test("a11y tooltip: the screen-reader switch silences the notices (preview-announcements-2026-11-21)",
	_A11yT_AnnounceHonoursTheSwitch)

; A preview hidden before its announcement turn has nothing left on screen to
; read: the notice is skipped, not reported as an error (the resident driver
; opened the error window on « Gui has no window », 2026-11-18).
_A11yT_AnnounceSkipsADestroyedSurface() {
	global _TooltipLastAnnouncement, _TooltipLastAnnouncementTick
	SavedText := _TooltipLastAnnouncement, SavedTick := _TooltipLastAnnouncementTick
	Calls := []
	Record(Hwnd, Text) {
		Calls.Push(Text)
		return true
	}
	Gone := Gui()
	Gone.Destroy()
	Before := LoggerVolume()
	try {
		AssertEqual("", _TooltipAnnouncePresented([{Text: "a11y-gone-" . A_TickCount}], {Gui: Gone}, () => true, Record))
		Sleep(50)
		After := LoggerVolume()
		for Field in ["error", "dropped", "suppressed", "collapsed"]
			AssertEqual(Before[Field], After[Field], "no error is logged for a surface already gone (" . Field . ")")
		AssertEqual(0, Calls.Length, "nothing is announced for a surface already gone")
	} finally {
		_TooltipLastAnnouncement := SavedText, _TooltipLastAnnouncementTick := SavedTick
	}
}
Test("a11y tooltip: a surface destroyed before its notice is skipped quietly (a11y-gone-surface-2026-11-18)",
	_A11yT_AnnounceSkipsADestroyedSurface)

; A live surface is announced with its own window and logs nothing: the
; liveness probe once read Hwnd as a method call and failed on every tooltip.
_A11yT_AnnounceReadsALiveSurface() {
	global _TooltipLastAnnouncement, _TooltipLastAnnouncementTick
	SavedText := _TooltipLastAnnouncement, SavedTick := _TooltipLastAnnouncementTick
	Calls := []
	Record(Hwnd, Text) {
		Calls.Push({Hwnd: Hwnd, Text: Text})
		return true
	}
	Live := Gui()
	Text := "a11y-live-" . A_TickCount
	Before := LoggerVolume()
	try {
		AssertTrue(_TooltipAnnouncePresented([{Text: Text}], {Gui: Live}, () => true, Record) != "",
			"a live surface is announced")
		Sleep(50)
		After := LoggerVolume()
		for Field in ["error", "dropped", "suppressed", "collapsed"]
			AssertEqual(Before[Field], After[Field], "no error is logged for a live surface (" . Field . ")")
		AssertEqual(1, Calls.Length, "the notice is sent once")
		AssertEqual(Live.Hwnd, Calls[1].Hwnd, "the notice names the surface's own window")
	} finally {
		_TooltipLastAnnouncement := SavedText, _TooltipLastAnnouncementTick := SavedTick
		Live.Destroy()
	}
}
Test("a11y tooltip: a live surface is announced with its window (a11y-live-surface-2026-11-18)",
	_A11yT_AnnounceReadsALiveSurface)





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

; The icon is named before it appears: AutoHotkey names an unnamed icon by the
; script's file name, which a screen reader announced from the reveal on (TRAY-01).
_A11yT_IconIsNamedBeforeItIsShown() {
	Events := []
	SetFn(Text) {
		Events.Push("name:" . Text)
		return true
	}
	RevealFn() {
		Events.Push("reveal")
	}
	AssertTrue(TrayRevealNamed("Ergopti+", RevealFn, SetFn))
	AssertEqual(2, Events.Length)
	AssertEqual("name:Ergopti+", Events[1])
	AssertEqual("reveal", Events[2], "the icon appears only once it has its name")
	; A refused name still shows the driver's only control surface, and says so.
	Events.Length := 0
	AssertFalse(TrayRevealNamed("Ergopti+", RevealFn, (T) => false))
	AssertEqual("reveal", Events[Events.Length])
	Refused := false
	try TrayRevealNamed("", RevealFn, SetFn)
	catch ValueError
		Refused := true
	AssertTrue(Refused, "an icon without a name is refused before it is shown")
}
Test("a11y tray: the icon is named before it is shown (tray-01-2026-11-20)", _A11yT_IconIsNamedBeforeItIsShown)

; The first-run tray speaks the wizard's language, not the module default.
_A11yT_FirstRunInertRowFollowsItsLocale() {
	English := TrayBootstrapInertLabel("en")
	French := TrayBootstrapInertLabel("fr")
	AssertEqual("ErgoptiPlus — Starting…", English)
	AssertTrue(French != English, "the inert row is projected in the locale it is given")
}
Test("a11y tray: the first-run startup row follows the wizard's locale (tray-01-2026-11-20)",
	_A11yT_FirstRunInertRowFollowsItsLocale)

; A missing logo file is never drawn as the other state's logo: it is logged
; once, the warning sign is drawn, and the tray text says so (TRAY-05).
_A11yT_MissingLogoIsSaidNotSwapped() {
	Paused := "Z:\tray-05\missing-" . A_TickCount . "\logo_simple_disabled.ico"
	Present := Map(Paused, false)
	Exists(Path) => Present.Get(Path, false) ? "A" : ""
	Draws := [], Logs := []
	SetIcon(File, Number := "", Freeze := "") {
		Draws.Push([File, Number, Freeze])
	}
	Log(Path) {
		Logs.Push(Path)
	}
	try {
		AssertFalse(TrayApplyStateIcon(true, Paused, Exists, SetIcon, Log), "a missing logo is not reported as drawn")
		AssertEqual(1, Draws.Length)
		AssertEqual("user32.dll", Draws[1][1], "the warning sign is drawn, not the running logo")
		AssertEqual(-101, Draws[1][2])
		AssertEqual(true, Draws[1][3], "the paused icon stays frozen against AutoHotkey's own")
		AssertEqual(1, Logs.Length, "the missing file is logged")
		AssertEqual(Paused, Logs[1])
		AssertEqual(t("accessibility.tray_tip_paused_icon_missing"), TrayStateTipText(true),
			"the tray text says the paused logo is missing")
		AssertEqual(t("accessibility.tray_tip"), TrayStateTipText(false), "the running state is not affected")
		TrayApplyStateIcon(true, Paused, Exists, SetIcon, Log)
		AssertEqual(1, Logs.Length, "a missing file is logged once, not at every pause")
		Present[Paused] := true
		AssertTrue(TrayApplyStateIcon(true, Paused, Exists, SetIcon, Log))
		AssertEqual(Paused, Draws[Draws.Length][1], "a restored file is drawn again")
		AssertEqual(t("accessibility.tray_tip_paused"), TrayStateTipText(true))
	} finally {
		Present[Paused] := true
		TrayApplyStateIcon(true, Paused, Exists, SetIcon, Log)
	}
}
Test("a11y tray: a missing logo file is said, not drawn as the other state (tray-05-2026-11-21)",
	_A11yT_MissingLogoIsSaidNotSwapped)





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





; ===================================================
; ===================================================
; ======= 5/ WPM widget and Spotlight overlay =======
; ===================================================
; ===================================================

; The WPM pill and graph were nameless painted windows to a screen reader
; (a11y-readers-2026-11-18): while one runs, the shown window is named by the
; value it draws, once per change and never otherwise.
_A11yT_WpmSurfaceIsNamedForReaders() {
	Calls := []
	NameFn(Hwnd, Text) {
		Calls.Push(Text)
		return true
	}
	G := Gui()
	try {
		AssertFalse(_WPMWidget_NameForReaders(G, "72", () => false, NameFn), "no reader, no name")
		AssertEqual(0, Calls.Length)
		AssertTrue(_WPMWidget_NameForReaders(G, "72", () => true, NameFn), "a running reader gets the value")
		AssertFalse(_WPMWidget_NameForReaders(G, "72", () => true, NameFn), "the same value is not set again")
		AssertTrue(_WPMWidget_NameForReaders(G, "75", () => true, NameFn), "a new value is")
		AssertEqual(2, Calls.Length)
		AssertEqual("75 " . t("menu.metrics.wpm_unit"), Calls[2], "the value and its unit in the active language")
		AssertFalse(_WPMWidget_NameForReaders(G, "75", () => false, NameFn), "the reader stopping clears it")
		AssertTrue(_WPMWidget_NameForReaders(G, "75", () => true,
			(Hwnd, Text) => A11ySystem_SetAccessibleName(Hwnd, Text)), "the real annotation is accepted")
	} finally {
		G.Destroy()
		_WPMWidget_NameForReaders(0, "", () => false)
	}
}
Test("a11y readers: the WPM surface is named by its value while a screen reader runs (a11y-readers-2026-11-18)",
	_A11yT_WpmSurfaceIsNamedForReaders)

; The pill and the graph are two windows, and a discarded surface is rebuilt
; as a new one: a cache of the text alone left the next window nameless at the
; same speed, and the reader said the Gui title instead (met-08).
_A11yT_EveryWpmSurfaceIsNamed() {
	Calls := []
	NameFn(Hwnd, Text) {
		Calls.Push(Hwnd)
		return true
	}
	Pill := Gui(), Graph := Gui()
	try {
		AssertTrue(_WPMWidget_NameForReaders(Pill, "72", () => true, NameFn), "the pill is named")
		AssertTrue(_WPMWidget_NameForReaders(Graph, "72", () => true, NameFn),
			"the graph shown at the same speed is named too (met-08)")
		AssertFalse(_WPMWidget_NameForReaders(Graph, "72", () => true, NameFn), "and once only")
		AssertEqual(2, Calls.Length)
		AssertEqual(Graph.Hwnd, Calls[2], "the name goes to the window shown")
	} finally {
		Pill.Destroy(), Graph.Destroy()
		_WPMWidget_NameForReaders(0, "", () => false)
	}
}
Test("a11y readers: every WPM surface is named at the same speed (met-08)", _A11yT_EveryWpmSurfaceIsNamed)

; The Spotlight overlay told a screen reader nothing: while one runs, its
; circle window announces that the pointer is highlighted.
_A11yT_SpotlightIsAnnounced() {
	Heard := []
	AnnounceFn(Hwnd, Text) {
		Heard.Push(Hwnd . "|" . Text)
		return true
	}
	Receipt := Map("module", 0, "token", 0, "windows", [4242])
	AssertEqual("", _SpotlightAnnounce(Receipt, () => false, AnnounceFn), "no reader, nothing said")
	AssertEqual("", _SpotlightAnnounce(Map("windows", []), () => true, AnnounceFn), "no window, nothing said")
	Text := _SpotlightAnnounce(Receipt, () => true, AnnounceFn)
	AssertEqual(t("accessibility.spotlight_shown"), Text)
	AssertTrue(Text != "accessibility.spotlight_shown" && Text != "", "the notice is translated")
	Deadline := A_TickCount + 2000
	while (Heard.Length == 0 && A_TickCount < Deadline)
		Sleep(10)
	AssertEqual(1, Heard.Length, "the notice goes out on a timer turn")
	AssertEqual("4242|" . Text, Heard[1], "the circle's window says it")
}
Test("a11y readers: the Spotlight overlay is announced while a screen reader runs (a11y-readers-2026-11-18)",
	_A11yT_SpotlightIsAnnounced)
