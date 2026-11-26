; tests/unit/modules/keymap/test_emulation_quick_picker.ahk

; ==============================================================================
; MODULE: Layout To Emulate Quick Choices And Picker Tests (Windows)
; DESCRIPTION:
; « Layouts and emulation › Layout to emulate » draws one single-choice group
; of « None » and the layouts chosen last, then « Others… », which opens the
; picker of every layout (maintainer decision of 2026-11-25). Replays the
; shared recents vectors macOS and Linux replay, then drives the menu rows,
; the selection's write and the picker session.
; ==============================================================================

#Requires AutoHotkey v2.0

_EQP_Vectors() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\layouts\emulation_recents_vectors.json", "UTF-8"))
}

; The menu vocabulary holds "" for « None ».
_EQP_Choice(Id) => Id == "none" ? "" : Id

_EQP_Join(Items) {
	Joined := ""
	for Item in Items
		Joined .= (Joined == "" ? "" : ",") . Item
	return Joined
}

_EQP_ReplaysVectors() {
	Vectors := _EQP_Vectors()
	AssertEqual(Vectors["count"], EmulationRecents_Count(), "the shipped length is the one the vectors pin")
	for Vector in Vectors["after"]
		AssertEqual(_EQP_Join(Vector["expected"]),
			_EQP_Join(EmulationRecents_After(Vector["recents"], _EQP_Choice(Vector["choice"]), Vectors["count"])), Vector["name"])
	for Vector in Vectors["quick"] {
		Offered := Map()
		for Id in Vector["offered"]
			Offered[Id] := true
		AssertEqual(_EQP_Join(Vector["expected"]), _EQP_Join(EmulationRecents_Quick(_EQP_Choice(Vector["current"]),
			Vector["recents"], (Id) => Offered.Has(Id), Vectors["count"])), Vector["name"])
	}
	AssertFalse(EmulationRecents_IsValid(["bepo", "bepo"]), "a layout named twice is outdated")
	AssertFalse(EmulationRecents_IsValid(["none"]), "None is never recorded")
	AssertEqual(0, EmulationRecents_Read(Map("layout", Map("emulated_layout_recents", "bepo"))).Length,
		"a value in another shape reads as no recents")
}
Test("layout to emulate: the recent layouts replay the shared vectors (emulation-quick-picker)", _EQP_ReplaysVectors)

; The picker offers every layout but « None » and applies its choice as a row does.
_EQP_PickerChoices() {
	Index := Map("layouts", [Map("id", "bepo", "name", "BÉPO"), Map("id", "ergol", "name", "Ergo-L")])
	Installed := Map("bepo", Map("name", "BÉPO"), "ergol", Map("name", "Ergo-L"))
	Selected := []
	Opened := []
	Select := (Id) => (Selected.Push(Id), true)
	Others := (Choices, ChooseFn) => Opened.Push([Choices, ChooseFn])
	Features := Map("layout", Map("emulated_layout", "bepo", "emulated_layout_recents", ["bepo"]))
	Items := _LAY_EmulationChoiceRows(Features, Select, Index, Installed, (Message) => 0, 0, "", 0, Others)[1]["items"]
	Items[Items.Length]["action"].Call()
	Ids := []
	Current := ""
	for Choice in Opened[1][1] {
		Ids.Push(Choice["id"])
		if Choice["current"]
			Current := Choice["id"]
	}
	AssertEqual(ERGOPTI_LAYOUT_ID . "," . ERGOPTI_PLUS_LAYOUT_ID . ",bepo,ergol", _EQP_Join(Ids),
		"every layout, None left to the menu")
	AssertEqual("bepo", Current, "the layout in force is marked")
	AssertTrue(Opened[1][2].Call("ergol"), "a picker choice goes through the menu's selection")
	AssertEqual("ergol", _EQP_Join(Selected))
}
Test("layout to emulate: « Others… » hands the picker every layout and the menu's choice (emulation-quick-picker)",
	_EQP_PickerChoices)

_EQP_GroupRows() {
	Index := Map("layouts", [Map("id", "bepo", "name", "BÉPO"), Map("id", "ergol", "name", "Ergo-L"),
		Map("id", "colemak", "name", "Colemak")])
	Installed := Map("bepo", Map("name", "BÉPO"), "ergol", Map("name", "Ergo-L"), "colemak", Map("name", "Colemak"))
	Opened := []
	Others := (Choices, ChooseFn) => Opened.Push(Choices)
	Rows(Features) => _LAY_EmulationChoiceRows(Features, (Id) => true, Index, Installed, (Message) => 0, 0, "", 0, Others)
	Fresh := Rows(Map("layout", Map("emulated_layout", "", "ergopti_variant", "none")))[1]["items"]
	AssertEqual(3, Fresh.Length, "a fresh configuration offers None, a separator and « Others… »")
	Items := Rows(Map("layout", Map("emulated_layout", "colemak",
		"emulated_layout_recents", ["bepo", "ergol", "colemak"])))[1]["items"]
	Labels := []
	Checked := 0
	loop Items.Length - 2 {
		Labels.Push(Items[A_Index]["label"])
		Checked += Items[A_Index]["checked"] ? 1 : 0
	}
	AssertEqual(t("onboarding.layout.emulated_none") . ",Colemak,BÉPO,Ergo-L", _EQP_Join(Labels),
		"None, then the layout in force and the ones chosen last")
	AssertEqual(1, Checked, "exactly one row of the group is ticked")
	AssertTrue(Items[Items.Length - 1].Get("separator", false), "a separator closes the group")
	AssertEqual(t("menu.layout.emulation_others"), Items[Items.Length]["label"], "« Others… » is the manifest's row")
	Items[Items.Length]["action"].Call()
	AssertEqual(1, Opened.Length, "« Others… » opens the picker")
}
Test("layout to emulate: one ticked group of None and the recent layouts, then « Others… » (emulation-quick-picker)",
	_EQP_GroupRows)

; A selection leads the recent layouts in the same write; None is never recorded.
_EQP_SelectionRecords() {
	Snapshot := Map("valid", true, "path", "C:\c.toml", "presence", true, "content", "", "values", Map(),
		"recents", ["bepo", "ergol", "colemak"])
	Snap := (*) => Snapshot
	Operations := _LayMgrWeb_SelectionOperations("colemak", "C:\c.toml", Snapshot, Snap)
	AssertEqual(ConfigLeaf.EMULATED_LAYOUT_RECENTS, Operations[2].Key)
	AssertEqual("colemak,bepo,ergol", _EQP_Join(Operations[2].Value))
	Builtin := _LayMgrWeb_SelectionOperations(ERGOPTI_LAYOUT_ID, "C:\c.toml", Snapshot, Snap)
	AssertEqual(ERGOPTI_LAYOUT_ID . ",bepo,ergol", _EQP_Join(Builtin[3].Value), "a built-in variant is recorded too")
	for Operation in _LayMgrWeb_SelectionOperations("", "C:\c.toml", Snapshot, Snap)
		AssertFalse(Operation.Key == ConfigLeaf.EMULATED_LAYOUT_RECENTS, "None is never recorded")
}
Test("layout to emulate: a selection leads the recent layouts (emulation-quick-picker)", _EQP_SelectionRecords)

; The page contract the macOS and Linux hosts answer through picker_session.lua.
_EQP_PickerSession() {
	Chosen := []
	Answer := true
	Session := EmulationPickerSession([Map("id", "ergol", "label", "Ergo-L", "current", false)],
		(Id) => (Chosen.Push(Id), Answer))
	Ready := Session.Handle("ready")
	AssertContains(Ready["reply"], '"session":"' . Session.Token . '"')
	AssertContains(Ready["reply"], '"id":"ergol"')
	AssertFalse(Session.Handle(Map("action", "choose", "session", Session.Token, "id", "made_up"))["close"],
		"an id never offered is refused")
	AssertFalse(Session.Handle(Map("action", "choose", "session", "stale", "id", "ergol"))["close"],
		"a stale page is refused")
	AssertEqual(0, Chosen.Length)
	Answer := false
	Refused := Session.Handle(Map("action", "choose", "session", Session.Token, "id", "ergol"))
	AssertFalse(Refused["close"], "a refused choice keeps the window")
	AssertContains(Refused["reply"], '"refused":true')
	Answer := true
	AssertTrue(Session.Handle(Map("action", "choose", "session", Session.Token, "id", "ergol"))["close"],
		"an applied choice closes the window")
	AssertEqual("ergol,ergol", _EQP_Join(Chosen))
	AssertFalse(Session.Handle(Map("action", "cancel", "session", Session.Token))["close"], "a closed session answers nothing")
	Fresh := EmulationPickerSession([], (Id) => true)
	AssertTrue(Fresh.Handle(Map("action", "cancel", "session", ""))["close"], "Cancel before the choices arrived closes")
}
Test("emulation picker: the page contract admits only an offered choice of its session (emulation-quick-picker)",
	_EQP_PickerSession)

; The picker opens through the shared window host, named by the manifest.
_EQP_PickerOpens() {
	Requested := []
	Open := (Opts) => (Requested.Push(Opts), {})
	AssertTrue(EmulationPicker_Open([], (Id) => true, Open))
	AssertTrue(Requested[1]["RunsWhilePaused"], "the emulated layout is chosen while paused, as from the menu")
	AssertTrue(HasMethod(Requested[1]["OnReady"], "Call") && HasMethod(Requested[1]["OnMessage"], "Call"))
	AssertFalse(EmulationPicker_Open([], (Id) => true, (Opts) => ""), "a refused window is reported")
}
Test("emulation picker: opens through the shared WebView host (emulation-quick-picker)", _EQP_PickerOpens)
