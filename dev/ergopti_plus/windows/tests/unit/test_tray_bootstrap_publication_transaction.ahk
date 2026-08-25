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
Test("tray bootstrap: invalid label is complete-or-absent (ahk-009-tray-bootstrap-publication)",
	_TBPT_InvalidLabelCannotPartiallyPublish)
Test("tray bootstrap: pre-i18n default truthfully says Starting (ahk-009-tray-bootstrap-publication)",
	_TBPT_DefaultLabelTruthfullySignalsStartup)
Test("tray bootstrap: failed detached build retains bootstrap until complete root (ahk-009-tray-bootstrap-publication)",
	_TBPT_BuildFailureRetainsBootstrapUntilCompletePublish)
