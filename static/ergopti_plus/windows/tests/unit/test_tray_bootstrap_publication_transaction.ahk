; tests/unit/test_tray_bootstrap_publication_transaction.ahk

; ==============================================================================
; MODULE: Cold Tray Bootstrap Behavior
; DESCRIPTION:
; AHK-009 behavioral regression. The bootstrap helper must publish exactly one
; inert status row through the injected menu port, never depend on a live tray
; during tests, and surface invalid input before any partial publication.
; ==============================================================================

#Requires AutoHotkey v2.0

class _TBPT_FakeMenu {
	__New() {
		this.Items := Map()
		this.Calls := []
		this.DeleteCalls := 0
		this.AddCalls := 0
		this.DisableCalls := 0
	}

	Delete() {
		this.DeleteCalls += 1
		this.Calls.Push("delete")
		this.Items.Clear()
	}

	Add(Label, Callback) {
		this.AddCalls += 1
		this.Calls.Push("add")
		this.Items[Label] := Map("callback", Callback, "enabled", true)
	}

	Disable(Label) {
		this.DisableCalls += 1
		this.Calls.Push("disable")
		if !this.Items.Has(Label)
			throw Error("cannot disable an absent item")
		this.Items[Label]["enabled"] := false
	}

	ApplyStage(Stage) {
		this.Calls.Push("publish")
		this.Items.Clear()
		for _, Entry in Stage {
			if (Entry["kind"] == "submenu" || Entry["kind"] == "action")
				this.Items[Entry["label"]] := Map("enabled", true)
			else if (Entry["kind"] == "disable"
				&& this.Items.Has(Entry["label"]))
				this.Items[Entry["label"]]["enabled"] := false
		}
		return true
	}
}

_TBPT_InstallsOneDisabledStatus() {
	MenuPort := _TBPT_FakeMenu()
	AssertTrue(_InstallSafeBootstrapTray("Starting…", MenuPort))
	AssertEqual(1, MenuPort.DeleteCalls,
		"the helper must own replacement of the old root, not rely on a caller-side Delete")
	AssertEqual(1, MenuPort.AddCalls,
		"the bootstrap must publish exactly one row")
	AssertEqual(1, MenuPort.DisableCalls,
		"the published status must be made inert")
	AssertEqual(1, MenuPort.Items.Count)
	AssertTrue(MenuPort.Items.Has("Starting…"))
	Item := MenuPort.Items["Starting…"]
	AssertFalse(Item["enabled"])
	AssertTrue(HasMethod(Item["callback"], "Call"))
	AssertEqual(0, Item["callback"].Call())
	AssertEqual(3, MenuPort.Calls.Length)
	AssertEqual("delete", MenuPort.Calls[1])
	AssertEqual("add", MenuPort.Calls[2])
	AssertEqual("disable", MenuPort.Calls[3],
		"the old root must be retired only inside the bootstrap publication transaction")
}

_TBPT_InvalidLabelCannotPartiallyPublish() {
	MenuPort := _TBPT_FakeMenu()
	ThrewValueError := false
	try _InstallSafeBootstrapTray("", MenuPort)
	catch as Err
		ThrewValueError := Err is ValueError
	AssertTrue(ThrewValueError,
		"an invalid bootstrap label must fail at the admission boundary")
	AssertEqual(0, MenuPort.DeleteCalls)
	AssertEqual(0, MenuPort.AddCalls)
	AssertEqual(0, MenuPort.DisableCalls)
	AssertEqual(0, MenuPort.Items.Count)
}

_TBPT_DefaultLabelTruthfullySignalsStartup() {
	MenuPort := _TBPT_FakeMenu()
	AssertTrue(_InstallSafeBootstrapTray(, MenuPort))
	AssertEqual(1, MenuPort.Items.Count)
	AssertTrue(MenuPort.Items.Has("ErgoptiPlus — Starting…"),
		"the pre-i18n bootstrap must describe startup, not expose an unexplained brand-only row")
	AssertFalse(MenuPort.Items["ErgoptiPlus — Starting…"]["enabled"])
}

_TBPT_BuildFailureRetainsBootstrapUntilCompletePublish() {
	global _TrayMenuStage
	SavedStage := _TrayMenuStage
	MenuPort := _TBPT_FakeMenu()
	try {
		_TrayMenuStage := false
		_InstallSafeBootstrapTray("Starting…", MenuPort)
		AssertEqual(1, MenuPort.Items.Count)

		; Detached work may fail or be cancelled before publication. The live root
		; must remain the bootstrap because staging never mutates MenuPort.
		TrayMenuStage_Begin()
		TrayMenuStage_Add("AI", 0)
		TrayMenuStage_Abort()
		AssertEqual(1, MenuPort.Items.Count)
		AssertTrue(MenuPort.Items.Has("Starting…"),
			"a failed detached build must retain the complete bootstrap root")

		TrayMenuStage_Begin()
		TrayMenuStage_Add("Global", 0)
		TrayMenuStage_Add("AI", 0)
		TrayMenuStage_Add("Quit", 0)
		AssertTrue(TrayMenuStage_Publish(0,
			ObjBindMethod(MenuPort, "ApplyStage")))
		AssertEqual(3, MenuPort.Items.Count,
			"the bootstrap may retire only when one complete staged root is ready")
		AssertFalse(MenuPort.Items.Has("Starting…"))
		AssertTrue(MenuPort.Items.Has("Global"))
		AssertTrue(MenuPort.Items.Has("AI"))
		AssertTrue(MenuPort.Items.Has("Quit"))
	} finally {
		_TrayMenuStage := SavedStage
	}
}

Test("tray bootstrap: helper publishes one disabled status (ahk-009-tray-bootstrap-publication)",
	_TBPT_InstallsOneDisabledStatus)

_TBPT_EarlyClickCannotEnterNativeMenuLoop() {
	State := Map("ready", false, "shown", 0, "scheduled", [])
	Gate := TrayStartupClick(() => State["ready"],
		() => State["shown"] += 1,
		(Fn, Delay) => State["scheduled"].Push([Fn, Delay]), (*) => 0)
	AssertEqual(0, Gate.OnTrayMessage(0, 0x205, 0x404, 0),
		"an early context request must be consumed before the native menu freezes bootstrap")
	AssertEqual(0, Gate.OnTrayMessage(0, 0x7B, 0x404, 0))
	AssertTrue(Gate.Pending)
	AssertEqual(2, Gate.RequestCount)
	AssertEqual(0, State["shown"])
	AssertEqual(0, State["scheduled"].Length)
	AssertEqual("", Gate.OnTrayMessage(0, 0x405, 0x404, 0),
		"updater balloon notifications must remain owned by the updater")
	Threw := false
	try Gate.NotifyReady()
	catch
		Threw := true
	AssertTrue(Threw, "a queued menu may not open before its root publishes")
	State["ready"] := true
	AssertTrue(Gate.NotifyReady())
	AssertFalse(Gate.Pending)
	AssertFalse(Gate.NotifyReady(), "multiple early clicks must open one menu")
	AssertEqual(1, State["scheduled"].Length)
	AssertEqual(-1, State["scheduled"][1][2])
	AssertEqual("", Gate.OnTrayMessage(0, 0x205, 0x404, 0),
		"ready clicks must use the ordinary native dispatcher")
	State["scheduled"][1][1].Call()
	AssertEqual(1, State["shown"])
}

Test("tray bootstrap: early clicks wait without blocking startup (tray-click-2026-10-02)",
	_TBPT_EarlyClickCannotEnterNativeMenuLoop)

_TBPT_ModelessCommandsRetainOneIntent() {
	State := Map("ready", false, "commands", [], "timers", [])
	Panel := TrayStartupPanel(() => State["ready"],
		(Id) => State["commands"].Push(Id),
		(Fn, Delay) => State["timers"].Push(Fn))
	AssertTrue(Panel.Request("suspend"))
	AssertFalse(Panel.Request("reload"), "one click owns one retained intent")
	AssertFalse(Panel.Dispatch(), "a modeless callback cannot enter partial lifecycle state")
	AssertEqual(0, State["timers"].Length)
	State["ready"] := true
	AssertTrue(Panel.NotifyReady())
	AssertTrue(Panel.NotifyReady())
	for Fn in State["timers"]
		Fn.Call()
	AssertEqual(1, State["commands"].Length, "repeated readiness cannot execute twice")
	AssertEqual("suspend", State["commands"][1])
	AssertTrue(Panel.Request("quit"))
	Panel.Retire()
	AssertFalse(Panel.Dispatch(), "retired startup surfaces reject outstanding callbacks")
	AssertFalse(Panel.Request("reload"))
	AssertEqual(1, State["commands"].Length)
}

_TBPT_ModelessClickReturnsBeforeNativeNavigation() {
	State := Map("ready", false, "popup", 0, "native", 0, "closed", 0, "timers", [])
	Gate := TrayStartupClick(() => State["ready"],
		() => State["native"] += 1,
		(Fn, Delay) => State["timers"].Push(Fn), (*) => 0,
		() => State["popup"] += 1, () => State["closed"] += 1)
	AssertEqual(0, Gate.OnTrayMessage(0, 0x205, 0x404, 0))
	AssertEqual(1, State["popup"], "the early click must produce immediate modeless feedback")
	AssertEqual(0, State["native"], "native navigation must not stall background construction")
	State["ready"] := true
	Gate.NotifyReady()
	State["timers"][1].Call()
	AssertEqual(1, State["closed"])
	AssertEqual(1, State["native"])
}

Test("tray bootstrap: modeless commands retain exactly one intent (tray-modeless-2026-10-02)",
	_TBPT_ModelessCommandsRetainOneIntent)

_TBPT_CancelInvalidatesScheduledMenu() {
	State := Map("ready", false, "native", 0, "timers", [])
	Gate := TrayStartupClick(() => State["ready"], () => State["native"] += 1,
		(Fn, Delay) => State["timers"].Push(Fn), (*) => 0)
	Gate.OnTrayMessage(0, 0x205, 0x404, 0)
	State["ready"] := true
	AssertTrue(Gate.NotifyReady())
	AssertEqual(1, State["timers"].Length)
	Gate.CancelPending()
	State["timers"][1].Call()
	AssertEqual(0, State["native"], "Escape or a command cancels even an already scheduled native menu")
}

_TBPT_PanelPositionClampsPhysicalCoordinates() {
	Pos := TrayStartupPanelPosition(1910, 1070, 300, 220, 0, 0, 1920, 1040)
	AssertEqual(1610, Pos.X)
	AssertEqual(820, Pos.Y, "the taskbar is excluded from the work area")
	Pos := TrayStartupPanelPosition(-1910, -790, 450, 330, -1920, -800, 0, 1040)
	AssertEqual(-1920, Pos.X)
	AssertEqual(-800, Pos.Y, "scaled native dimensions and negative origins stay physical")
	Pos := TrayStartupPanelPosition(1910, 10, 300, 220, 0, 0, 1920, 1040)
	AssertEqual(1610, Pos.X)
	AssertEqual(0, Pos.Y)
}

_TBPT_OnboardingOwnsEarlyClick() {
	State := Map("popup", 0)
	Gate := TrayStartupClick(() => false, (*) => 0, (*) => 0, (*) => 0,
		() => State["popup"] += 1, 0, () => true)
	AssertEqual(0, Gate.OnTrayMessage(0, 0x205, 0x404, 0))
	AssertFalse(Gate.Pending, "a first-run process never releases lifecycle intents")
	AssertEqual(0, State["popup"], "the wizard remains the only first-run command owner")
}

Test("tray bootstrap: cancellation invalidates scheduled navigation (tray-modeless-2026-10-02)",
	_TBPT_CancelInvalidatesScheduledMenu)
Test("tray bootstrap: physical panel geometry stays in the work area (tray-modeless-2026-10-02)",
	_TBPT_PanelPositionClampsPhysicalCoordinates)
Test("tray bootstrap: first-run setup owns early clicks (tray-modeless-2026-10-02)",
	_TBPT_OnboardingOwnsEarlyClick)
Test("tray bootstrap: modeless feedback precedes native navigation (tray-modeless-2026-10-02)",
	_TBPT_ModelessClickReturnsBeforeNativeNavigation)
Test("tray bootstrap: invalid label is complete-or-absent (ahk-009-tray-bootstrap-publication)",
	_TBPT_InvalidLabelCannotPartiallyPublish)
Test("tray bootstrap: pre-i18n default truthfully says Starting (ahk-009-tray-bootstrap-publication)",
	_TBPT_DefaultLabelTruthfullySignalsStartup)
Test("tray bootstrap: failed detached build retains bootstrap until complete root (ahk-009-tray-bootstrap-publication)",
	_TBPT_BuildFailureRetainsBootstrapUntilCompletePublish)
