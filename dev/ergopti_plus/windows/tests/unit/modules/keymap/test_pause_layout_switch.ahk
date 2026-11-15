; tests/unit/modules/keymap/test_pause_layout_switch.ahk

; ==============================================================================
; MODULE: Pause Layout Switch (Windows)
; DESCRIPTION:
; PauseLayoutSwitch_Apply switches through the shared policy on a pause, a
; resume and a quit; the lifecycle runs it as owner "keyboard-layout" on all
; three, a user quit only; and the menu rows come from the shared frames with
; the installed layouts as choices.
; ==============================================================================

#Requires AutoHotkey v2.0




; Runs Body with Features["layout"] holding the three settings.
_PLS_WithSettings(Enabled, OnPause, OnResume, Body) {
	global Features
	Saved := Features
	Layout := Map("pause_switch_enabled", Enabled, "on_pause", OnPause, "on_resume", OnResume)
	Features := Map("layout", Layout)
	try Body.Call()
	finally Features := Saved
}

/** A pause, a resume and a quit select their layouts; off selects nothing. */
_PLS_Apply() {
	Selected := []
	Select(Id) {
		Selected.Push(Id)
		return 1
	}
	_PLS_WithSettings(true, "0000040C", "A000040C", () => (
		AssertEqual(1, PauseLayoutSwitch_Apply("pause", Select)),
		AssertEqual(1, PauseLayoutSwitch_Apply("resume", Select)),
		AssertEqual(1, PauseLayoutSwitch_Apply("quit", Select))))
	AssertEqual("0000040C,A000040C,0000040C", Selected[1] . "," . Selected[2] . "," . Selected[3])
	Selected := []
	_PLS_WithSettings(false, "0000040C", "A000040C", () => (
		AssertEqual(1, PauseLayoutSwitch_Apply("pause", Select), "nothing to switch is acknowledged")))
	_PLS_WithSettings(true, "", "A000040C", () => (
		AssertEqual(1, PauseLayoutSwitch_Apply("quit", Select), "no change on quit")))
	AssertEqual(0, Selected.Length)
}

/** A start applies the layout of the live pause state, once. */
_PLS_Startup() {
	Selected := []
	Select(Id) {
		Selected.Push(Id)
		return 1
	}
	Saved := PauseLayoutSwitchState.event_applied
	try {
		PauseLayoutSwitchState.event_applied := false
		_PLS_WithSettings(true, "0000040C", "A000040C", () => (
			AssertEqual(1, PauseLayoutSwitch_ApplyStartup(0, Select))))
		PauseLayoutSwitchState.event_applied := false
		_PLS_WithSettings(true, "0000040C", "A000040C", () => (
			AssertEqual(1, PauseLayoutSwitch_ApplyStartup(1, Select))))
		AssertEqual("A000040C,0000040C", Selected[1] . "," . Selected[2], "running then paused start")
		; A restored pause already switched: the start selects nothing more.
		_PLS_WithSettings(true, "0000040C", "A000040C", () => (
			AssertEqual(1, PauseLayoutSwitch_ApplyStartup(1, Select))))
		AssertEqual(2, Selected.Length, "a pause transition keeps its choice")
		_PLS_WithSettings(true, "0000040C", "A000040C", () => (
			AssertThrows(() => PauseLayoutSwitch_ApplyStartup("paused", Select), "a start state is a boolean")))
	} finally PauseLayoutSwitchState.event_applied := Saved
	Entry := FSReadUtf8Exact(A_ScriptDir . "\..\ErgoptiPlus.ahk")
	Ready := InStr(Entry, '`n_DriverBootPhase := "ready"`n')
	Start := InStr(Entry, "PauseLayoutSwitch_ApplyStartup(A_IsSuspended ? 1 : 0)")
	Assert(Ready > 0 && Start > Ready, "the boot applies the start layout once ready")
	AssertContains(SubStr(Entry, Ready, Start - Ready), "if !_DriverSmokeInputQuarantined", "a smoke run keeps the layout")
}

/** A refused switch is false, the debt of its lifecycle owner. */
_PLS_Refused() {
	Refuse(Id) => false
	_PLS_WithSettings(true, "0000040C", "", () => (
		AssertFalse(PauseLayoutSwitch_Apply("pause", Refuse))))
	_PLS_WithSettings(true, "0000040C", "", () => (
		AssertThrows(() => PauseLayoutSwitch_Apply("suspend", Refuse), "an unknown event is refused")))
}

/** Suspend, resume and a user quit run the owner; a reload is not a quit. */
_PLS_Lifecycle() {
	global LIFECYCLE_REQUIRED_OWNERS
	for Phase in ["suspend", "resume", "quit"] {
		Found := false
		for Owner in LIFECYCLE_REQUIRED_OWNERS[Phase]
			if (Owner == "keyboard-layout")
				Found := true
		AssertTrue(Found, Phase . " declares the keyboard-layout owner")
	}
	for Name, Event in Map("Ergopti_OnSuspendEnter", "pause", "Ergopti_OnSuspendResume", "resume",
			"_LifecycleApplyQuitLayout", "quit") {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must exist")
		AssertContains(Body, '"keyboard-layout"', Name . " runs the owner")
		AssertContains(Body, 'PauseLayoutSwitch_Apply("' . Event . '")', Name . " asks for its event")
	}
	; Not "Shutdown": a local must not shadow the built-in function of that name.
	ExitBody := _DriverFuncBody("Ergopti_OnShutdown")
	Assert(ExitBody != "", "Ergopti_OnShutdown must exist")
	; The terminal marker the other shutdown-order tests anchor on: no refusal follows it.
	Terminal := InStr(ExitBody, "ShutdownTerminal := true")
	QuitAt := InStr(ExitBody, "_LifecycleApplyQuitLayout()")
	Assert(Terminal > 0 && QuitAt > Terminal, "the quit switch runs past the last refusal gate")
	AssertContains(ExitBody, "PauseLayoutSwitch_IsUserQuit(reason)", "only a user quit switches")
	AssertTrue(PauseLayoutSwitch_IsUserQuit("Menu"), "the tray Exit item")
	AssertTrue(PauseLayoutSwitch_IsUserQuit("Exit"), "the quit action")
	for Reason in ["Reload", "Logoff", "Shutdown", "Single", "Error", "Close"]
		AssertFalse(PauseLayoutSwitch_IsUserQuit(Reason), Reason . " is no user quit")
}

/** The rows are the shared frames, captioned and filled from the installed layouts. */
_PLS_MenuRows() {
	Writes := []
	SetFn(Path, Value) {
		Writes.Push(Path . "=" . String(Value))
		return 1
	}
	Choices := () => [Map("id", "0000040C", "label", "French", "hkl", 0x040C040C),
		Map("id", "A000040C", "label", "Ergopti", "hkl", 0xF0C0040C)]
	Rows := []
	_PLS_WithSettings(true, "A000040C", "", () => (Rows := PauseLayoutSwitch_MenuRows(Choices, SetFn)))
	AssertEqual(3, Rows.Length, "the switch and two pickers")
	AssertTrue(Rows[1]["checked"], "the switch is ticked while on")
	AssertContains(Rows[2]["label"], "Ergopti", "the pause picker names the chosen layout")
	AssertContains(Rows[3]["label"], t("menu.layout.layout_auto"), "the resume picker shows no change")
	Pause := Rows[2]["items"]
	AssertEqual(4, Pause.Length, "no change, a separator and the two layouts")
	AssertFalse(Pause[1]["checked"])
	AssertTrue(Pause[4]["checked"], "the chosen layout is ticked")
	Pause[3]["action"].Call()
	Rows[3]["items"][1]["action"].Call()
	Rows[1]["action"].Call()
	AssertEqual("layout.on_pause=0000040C", Writes[1])
	AssertEqual("layout.on_resume=", Writes[2])
	AssertEqual("layout.pause_switch_enabled=0", Writes[3])
}

; Runs Body under one shipped locale, then restores the translation cache.
_PLS_WithLocale(Code, Body) {
	global _SharedDir, _I18nCache, _I18nCacheLoaded
	HadCache := IsSet(_I18nCache), OldCache := HadCache ? _I18nCache : false
	HadLoaded := IsSet(_I18nCacheLoaded), OldLoaded := HadLoaded ? _I18nCacheLoaded : false
	try {
		_I18nCache := JsonParse(FileRead(_SharedDir . "\core\i18n\data\locales\" . Code . ".json", "UTF-8"))
		_I18nCacheLoaded := true
		Body.Call()
	} finally {
		if HadCache
			_I18nCache := OldCache
		else
			_I18nCache := unset
		if HadLoaded
			_I18nCacheLoaded := OldLoaded
		else
			_I18nCacheLoaded := unset
	}
}

/**
 * The shared corpus captions every locale's switch and both pickers with no
 * layout chosen; the real Windows rows owner must draw those exact captions.
 */
_PLS_CorpusCaptions() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\layout_switching_captions.json", "UTF-8"))
	AssertEqual(21, Corpus.Count, "the corpus covers every shipped locale")
	for Code, Expected in Corpus
		_PLS_WithLocale(Code, _PLS_CheckCorpusCaptions.Bind(Code, Expected))
}

_PLS_CheckCorpusCaptions(Code, Expected) {
	Writes := []
	SetFn(Path, Value) {
		Writes.Push(Path . "=" . String(Value))
		return 1
	}
	Rows := []
	_PLS_WithSettings(true, "", "", () => (Rows := PauseLayoutSwitch_MenuRows(() => [], SetFn)))
	AssertEqual(3, Rows.Length, Code . ": the switch and two pickers")
	AssertEqual(Expected["switch"], Rows[1]["label"], Code . ": switch caption")
	AssertEqual(Expected["pause"], Rows[2]["label"], Code . ": pause picker caption")
	AssertEqual(Expected["resume"], Rows[3]["label"], Code . ": resume picker caption")
	AssertEqual(Expected["automatic"], Rows[2]["items"][1]["label"], Code . ": the no-change choice")
	AssertEqual(0, Writes.Length, Code . ": drawing the rows writes nothing")
}

Test("pause layout switch: each event selects its layout", _PLS_Apply)
Test("pause layout switch: a start applies the live pause state's layout", _PLS_Startup)
Test("pause layout switch: a refused switch is lifecycle debt", _PLS_Refused)
Test("pause layout switch: suspend, resume and user quit run the owner", _PLS_Lifecycle)
Test("pause layout switch: menu rows from the shared frames", _PLS_MenuRows)
Test("pause layout switch: the 21 corpus captions of the switch and pickers (layout-switching-captions)",
	_PLS_CorpusCaptions)
