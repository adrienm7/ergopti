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

Test("pause layout switch: each event selects its layout", _PLS_Apply)
Test("pause layout switch: a refused switch is lifecycle debt", _PLS_Refused)
Test("pause layout switch: suspend, resume and user quit run the owner", _PLS_Lifecycle)
Test("pause layout switch: menu rows from the shared frames", _PLS_MenuRows)
