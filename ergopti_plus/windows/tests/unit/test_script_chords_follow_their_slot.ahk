; tests/unit/test_script_chords_follow_their_slot.ahk

; ==============================================================================
; MODULE: Script Chords Follow Their Slot
; DESCRIPTION:
; The script-management chords (AltGr+Enter, BackSpace, Delete, Escape) were
; registered under criteria that checked only the AltGr press and the layout,
; so a slot holding no action still took AltGr+Entrée and RunScriptShortcutAction
; retyped a bare Entrée: the maintainer saw the chords do nothing, and the
; application never got AltGr+Enter either (script-chord-slot-2026-09-30).
; Every chord hotkey now comes from ScriptAltGrChordPlan with a criterion bound
; to its slot, which asks ScriptShortcutSlotRunsAction. These tests evaluate
; the real plan and the real criteria; the source-level gate is
; tools/test/test-windows-script-chords-follow-their-slot.cjs.
; ==============================================================================

; The Windows script slots the manifest declares, in manifest order.
_SCFS_Slots() {
	Slots := []
	for Entry in ManifestFeaturesForSection("shortcuts.script_control") {
		if (Entry["type"] == "action")
			Slots.Push(Entry["id"])
	}
	return Slots
}

; The scan code of each slot's key, as the physical-key registry names them.
_SCFS_ScanCodes() {
	return Map("script_altgr_enter", "SC01C", "script_altgr_backspace", "SC00E",
		"script_altgr_delete", "SC153", "script_altgr_escape", "SC001")
}

; Assignments where every slot holds Value, or its manifest preset when Value is "".
_SCFS_Assignments(Value) {
	Assignments := Map()
	for Slot in _SCFS_Slots()
		Assignments[Slot] := (Value == "") ? ManifestRecommendedFor("shortcuts.script_control." . Slot) : Value
	return Assignments
}

; Runs Body with ScriptShortcutAssignments and the submenu's switch replaced,
; restoring both after.
_SCFS_WithAssignments(Assignments, Body, ChordsOn := true) {
	global ScriptShortcutAssignments, ScriptShortcutChordsOn
	Saved := IsSet(ScriptShortcutAssignments) ? ScriptShortcutAssignments : unset
	SavedOn := IsSet(ScriptShortcutChordsOn) ? ScriptShortcutChordsOn : unset
	ScriptShortcutAssignments := Assignments
	ScriptShortcutChordsOn := ChordsOn
	try Body.Call()
	finally {
		ScriptShortcutAssignments := IsSet(Saved) ? Saved : unset
		ScriptShortcutChordsOn := IsSet(SavedOn) ? SavedOn : unset
	}
}

_SCFS_PlanHasThreeHotkeysPerSlot() {
	Slots := _SCFS_Slots()
	AssertEqual(4, Slots.Length, "the manifest declares the four Windows script slots")
	Plan := ScriptAltGrChordPlan(Slots, _SCFS_ScanCodes())
	AssertEqual(3 * Slots.Length, Plan.Length, "one combination, one Kana twin and one paused twin per slot")
	for Index, Row in Plan {
		Slot := Slots[(Index - 1) // 3 + 1]
		Sc := _SCFS_ScanCodes()[Slot]
		AssertEqual(Slot, Row["slot"], "the plan runs its slots in order")
		AssertEqual(Sc, Row["scan_code"], Slot . " names its own key")
		Names := ["SC138 & " . Sc, "$" . Sc, "$*" . Sc]
		Expected := Names[Mod(Index - 1, 3) + 1]
		AssertEqual(Expected, Row["hotkey"], Slot . " registers the scan-code hotkey " . Expected)
		Assert(Row["criterion"] is BoundFunc, Slot . ": each hotkey's criterion is bound to its slot")
	}
}
Test("script chords: the plan registers three scan-code hotkeys per slot (script-chord-slot-2026-09-30)",
	_SCFS_PlanHasThreeHotkeysPerSlot)

_SCFS_PlanRefusesAMissingScanCode() {
	Codes := _SCFS_ScanCodes()
	Codes.Delete("script_altgr_delete")
	AssertThrows(ScriptAltGrChordPlan.Bind(_SCFS_Slots(), Codes),
		"a slot without its scan code must stop the registration")
}
Test("script chords: a slot without a scan code refuses the plan (script-chord-slot-2026-09-30)",
	_SCFS_PlanRefusesAMissingScanCode)

; The gate itself: an unassigned or unknown action leaves the chord native; a
; paused driver keeps only the script-management actions.
_SCFS_GateFollowsTheSlot() {
	_SCFS_WithAssignments(_SCFS_Assignments("none"), _SCFS_GateNone)
	_SCFS_WithAssignments(_SCFS_Assignments(""), _SCFS_GateRecommended)
	Mixed := _SCFS_Assignments("")
	Mixed["script_altgr_enter"] := "tab_next"
	Mixed["script_altgr_escape"] := "no_such_action"
	_SCFS_WithAssignments(Mixed, _SCFS_GateMixed)
}
_SCFS_GateNone() {
	for Slot in _SCFS_Slots() {
		AssertFalse(ScriptShortcutSlotRunsAction(Slot, false), Slot . ": an unassigned slot leaves its chord to the system")
		AssertFalse(ScriptShortcutSlotRunsAction(Slot, true), Slot . ": also while paused")
	}
}
_SCFS_GateRecommended() {
	for Slot in _SCFS_Slots() {
		AssertTrue(ScriptShortcutSlotRunsAction(Slot, false), Slot . ": its preset action runs")
		AssertTrue(ScriptShortcutSlotRunsAction(Slot, true), Slot . ": a script-management action runs while paused")
	}
	AssertThrows(ScriptShortcutSlotRunsAction.Bind("script_altgr_space", false),
		"a slot the table does not hold is a caller bug")
}
_SCFS_GateMixed() {
	AssertTrue(ScriptShortcutSlotRunsAction("script_altgr_enter", false), "any catalogue action runs while active")
	AssertFalse(ScriptShortcutSlotRunsAction("script_altgr_enter", true),
		"a paused driver leaves a chord that runs anything but script management to the system")
	AssertFalse(ScriptShortcutSlotRunsAction("script_altgr_escape", false), "an unknown action runs nothing")
}
Test("script chords: a slot runs its chord only with an action, while paused only script management (script-chord-slot-2026-09-30)",
	_SCFS_GateFollowsTheSlot)

; The switch at the head of « Raccourcis de gestion du script »: off leaves every
; chord to the system, running or paused, while the slots keep their actions.
_SCFS_SwitchOffLeavesEveryChord() {
	_SCFS_WithAssignments(_SCFS_Assignments(""), _SCFS_GateNone, false)
}
Test("script chords: the submenu switch off leaves every chord to the system (script-chords-switch-2026-09-30)",
	_SCFS_SwitchOffLeavesEveryChord)

; Evaluate the actual plan criteria with a modeled physical press, without
; injecting host input. The suffix-only twins retain their actual released-host
; check; this isolates the combination route and its slot ownership.
_SCFS_CriteriaAskTheSlot(Pressed := true) {
	global TapHold, _ALTGR_PHYSICAL_STATE_QUERY
	Saved := { TapHold: TapHold, Family: _TestSetAltGrFamily(true), Query: _ALTGR_PHYSICAL_STATE_QUERY }
	try {
		TapHold := Map("keys", Map(), "layers", Map())
		_ALTGR_PHYSICAL_STATE_QUERY := (Key) => Pressed
		_SCFS_WithAssignments(_SCFS_Assignments("none"), _SCFS_CriteriaExpect.Bind(false))
		_SCFS_WithAssignments(_SCFS_Assignments(""), _SCFS_CriteriaExpect.Bind(Pressed))
		_SCFS_WithAssignments(_SCFS_Assignments(""), _SCFS_CriteriaExpect.Bind(false), false)
	} finally {
		_ALTGR_PHYSICAL_STATE_QUERY := Saved.Query
		TapHold := Saved.TapHold
		_TestRestoreAltGrFamily(Saved.Family)
	}
}
_SCFS_CriteriaExpect(Assigned) {
	for Row in ScriptAltGrChordPlan(_SCFS_Slots(), _SCFS_ScanCodes()) {
		Live := Row["criterion"].Call(Row["hotkey"])
		if (SubStr(Row["hotkey"], 1, 8) == "SC138 & ")
			AssertEqual(Assigned, Live, Row["hotkey"] . " must be the driver's only while " . Row["slot"] . " runs an action")
		else
			AssertFalse(Live, Row["hotkey"] . " needs the physical SC138")
	}
}
Test("script chords: every chord criterion asks its own slot (script-chord-slot-2026-09-30)",
	_SCFS_CriteriaAskTheSlot)

Test("script chords: released AltGr never admits assigned chords (altgr-physical-eligibility)",
	_SCFS_CriteriaAskTheSlot.Bind(false))
