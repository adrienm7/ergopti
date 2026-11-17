; tests/unit/platform/remap/key_combinations/test_script_chords_follow_their_slot.ahk

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

; These chords are exempt from Suspend: a quarantined smoke must leave them to
; the resident driver.
global _DriverSmokeInputQuarantined := false
_SCFS_QuarantinedSmokeRunsNoChord() {
	global _DriverSmokeInputQuarantined
	_DriverSmokeInputQuarantined := true
	try _SCFS_WithAssignments(_SCFS_Assignments(""), _SCFS_GateQuarantined)
	finally _DriverSmokeInputQuarantined := false
	_SCFS_WithAssignments(_SCFS_Assignments(""), _SCFS_GateRecommended)
}
_SCFS_GateQuarantined() {
	for Slot in _SCFS_Slots()
		AssertFalse(ScriptShortcutSlotRunsAction(Slot, true), Slot . ": a quarantined smoke is always paused")
}
Test("script chords: a quarantined smoke runs no chord (smoke-input-quarantine-chords)",
	_SCFS_QuarantinedSmokeRunsNoChord)

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
	global TapHold, _ALTGR_PHYSICAL_STATE_QUERY, _ALTGR_PRIOR_KEY_QUERY
	Saved := { TapHold: TapHold, Family: _TestSetAltGrFamily(true), Query: _ALTGR_PHYSICAL_STATE_QUERY,
		Prior: _ALTGR_PRIOR_KEY_QUERY }
	try {
		TapHold := Map("keys", Map(), "layers", Map())
		_ALTGR_PHYSICAL_STATE_QUERY := (Key) => Pressed
		; A shortcut: AltGr pressed, then its key (altgr-shortcut-sequence-2026-11-17).
		_ALTGR_PRIOR_KEY_QUERY := () => "sc138"
		_SCFS_WithAssignments(_SCFS_Assignments("none"), _SCFS_CriteriaExpect.Bind(false))
		_SCFS_WithAssignments(_SCFS_Assignments(""), _SCFS_CriteriaExpect.Bind(Pressed))
		_SCFS_WithAssignments(_SCFS_Assignments(""), _SCFS_CriteriaExpect.Bind(false), false)
	} finally {
		_ALTGR_PHYSICAL_STATE_QUERY := Saved.Query
		_ALTGR_PRIOR_KEY_QUERY := Saved.Prior
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

; The maintainer's decision of 2026-11-14: a chord changed while paused is saved
; at once and takes effect only on resume. Every Windows chord change reloads,
; and a reload while paused came back suspended with the new chords at once, so
; a restore that moved the pause toggle left the paused driver without its way
; back (paused-chord-change).
_SCFS_WithPausedChords(Body) {
	global ScriptShortcutPausedChords, _ScriptShortcutPausedChordsFromReload, SCRIPT_SHORTCUT_SLOTS
	Saved := ScriptShortcutPausedChords, SavedFlag := _ScriptShortcutPausedChordsFromReload
	SavedSlots := IsSet(SCRIPT_SHORTCUT_SLOTS) ? SCRIPT_SHORTCUT_SLOTS : unset
	; The slots the boot reads from the manifest (feature_state.ahk).
	SCRIPT_SHORTCUT_SLOTS := _SCFS_Slots()
	try Body.Call()
	finally {
		ScriptShortcutPausedChords := Saved
		_ScriptShortcutPausedChordsFromReload := SavedFlag
		SCRIPT_SHORTCUT_SLOTS := IsSet(SavedSlots) ? SavedSlots : unset
	}
}

; Fake file ports over one Map, so the test never touches the disk.
_SCFS_Files() {
	Files := Map()
	return { files: Files,
		exists: (P) => Files.Has(P),
		read: (P) => Files.Has(P) ? Files[P] : "",
		write: (P, T) => (Files[P] := T, true),
		delete: (P) => (Files.Has(P) ? Files.Delete(P) : 0, true) }
}

_SCFS_PausedAssignments() {
	Assignments := _SCFS_Assignments("none")
	Assignments["script_altgr_enter"] := "script_pause_toggle"
	return Assignments
}

_SCFS_MovedAssignments() {
	Assignments := _SCFS_Assignments("none")
	Assignments["script_altgr_backspace"] := "script_pause_toggle"
	return Assignments
}

global _SCFS_FAKE_CHORDS_PATH := "C:\fake\suspend_restore.chords"

_SCFS_PausedChordsKeepTheResumeChord() {
	global ScriptShortcutPausedChords
	_SCFS_WithPausedChords(_SCFS_PausedChordsAcrossAReload)
	AssertFalse(ScriptShortcutPausedChords is Map, "the case leaves no chords of pause time behind")
}
_SCFS_PausedChordsAcrossAReload() {
	global _ScriptShortcutPausedChordsFromReload
	Fs := _SCFS_Files()
	_ScriptShortcutPausedChordsFromReload := false
	_SCFS_WithAssignments(_SCFS_PausedAssignments(), _SCFS_PauseThenReload.Bind(Fs))
	; The successor loads the configuration the restore wrote, then replays the pause.
	_SCFS_WithAssignments(_SCFS_MovedAssignments(), _SCFS_SuccessorKeepsPauseChords.Bind(Fs))
}
_SCFS_PauseThenReload(Fs) {
	ScriptShortcutPausedChordsBegin(_SCFS_FAKE_CHORDS_PATH, Fs.exists, Fs.read, Fs.delete)
	AssertTrue(ScriptShortcutPausedChordsPersist(_SCFS_FAKE_CHORDS_PATH, Fs.write, Fs.read),
		"a reload while paused writes the chords of pause time")
}
_SCFS_SuccessorKeepsPauseChords(Fs) {
	global _ScriptShortcutPausedChordsFromReload
	_ScriptShortcutPausedChordsFromReload := true
	ScriptShortcutPausedChordsBegin(_SCFS_FAKE_CHORDS_PATH, Fs.exists, Fs.read, Fs.delete)
	AssertTrue(ScriptShortcutSlotRunsAction("script_altgr_enter", true),
		"the chord active at pause time still resumes after a reload while paused")
	AssertFalse(ScriptShortcutSlotRunsAction("script_altgr_backspace", true),
		"the chord chosen while paused waits for the resume")
	AssertTrue(ScriptShortcutSlotRunsAction("script_altgr_backspace", false),
		"the configured chords are the new ones at once")
	ScriptShortcutPausedChordsEnd(_SCFS_FAKE_CHORDS_PATH, Fs.exists, Fs.delete)
	AssertFalse(Fs.files.Has(_SCFS_FAKE_CHORDS_PATH), "the resume removes the chords of pause time")
	AssertTrue(ScriptShortcutSlotRunsAction("script_altgr_backspace", true),
		"after the resume, the chord chosen while paused answers")
	AssertFalse(ScriptShortcutSlotRunsAction("script_altgr_enter", true),
		"after the resume, the old chord is given back")
}
Test("script chords: a reload while paused keeps the resume chord of pause time (paused-chord-change)",
	_SCFS_PausedChordsKeepTheResumeChord)

; A file no reload of this boot carried is stale: an ordinary pause takes the
; configured chords and removes it.
_SCFS_StaleFileIsRemoved() {
	global ScriptShortcutPausedChords
	_SCFS_WithPausedChords(_SCFS_StaleFileBody)
	AssertFalse(ScriptShortcutPausedChords is Map, "the case leaves no chords of pause time behind")
}
_SCFS_StaleFileBody() {
	global _ScriptShortcutPausedChordsFromReload
	Fs := _SCFS_Files()
	Fs.files[_SCFS_FAKE_CHORDS_PATH] := _SCFS_ChordsText(_SCFS_MovedAssignments())
	_ScriptShortcutPausedChordsFromReload := false
	_SCFS_WithAssignments(_SCFS_PausedAssignments(), _SCFS_OrdinaryPause.Bind(Fs))
}
_SCFS_OrdinaryPause(Fs) {
	ScriptShortcutPausedChordsBegin(_SCFS_FAKE_CHORDS_PATH, Fs.exists, Fs.read, Fs.delete)
	AssertFalse(Fs.files.Has(_SCFS_FAKE_CHORDS_PATH), "an ordinary pause removes a stale file")
	AssertTrue(ScriptShortcutSlotRunsAction("script_altgr_enter", true),
		"an ordinary pause answers with the configured chords")
}
Test("script chords: an ordinary pause ignores and removes a stale chords file (paused-chord-change)",
	_SCFS_StaleFileIsRemoved)

; The text of the given assignments with the switch on.
_SCFS_ChordsText(Assignments) {
	return ScriptShortcutPausedChordsText(Map("assignments", Assignments, "on", true))
}

_SCFS_ParseRefusesMalformedChords() {
	_SCFS_WithPausedChords(_SCFS_ParseBody)
	AssertEqual(4, _SCFS_Slots().Length, "the manifest declares the four slots the text holds")
}
_SCFS_ParseBody() {
	Good := _SCFS_ChordsText(_SCFS_PausedAssignments())
	Parsed := ScriptShortcutPausedChordsParse(Good)
	AssertEqual("script_pause_toggle", Parsed["assignments"]["script_altgr_enter"], "the text round-trips")
	AssertTrue(Parsed["on"], "the switch round-trips")
	AssertThrows(ScriptShortcutPausedChordsParse.Bind(StrReplace(Good, "chords_enabled=1`n", "")),
		"a file without its switch is refused")
	AssertThrows(ScriptShortcutPausedChordsParse.Bind(StrReplace(Good, "script_pause_toggle", "no_such_action")),
		"an unknown action is refused")
	AssertThrows(ScriptShortcutPausedChordsParse.Bind(Good . "foreign=1`n"), "an unknown key is refused")
}
Test("script chords: the chords of pause time refuse a malformed file (paused-chord-change)",
	_SCFS_ParseRefusesMalformedChords)
