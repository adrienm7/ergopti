; tests/unit/menu/builder/test_tray_shortcut_hint.ahk

; ==============================================================================
; MODULE: Tray Shortcut Hints (Windows)
; DESCRIPTION:
; The tray shows, beside « Suspendre », « Recharger » and « Quitter », the
; chord bound to the same action after a tab, which Windows right-aligns as the
; row's accelerator (maintainer, 2026-11-24), named as « Raccourcis de gestion
; du script » names its slot; no hint when no chord runs the action. Replays
; _shared/tests/corpus/shortcuts/script_chord_hint_vectors.json through
; ScriptChordHintSlot, as _shared/tests/lua/keyboard/script_chord_hint_contract.lua
; does on macOS and Linux, then stages the real rows.
;
; ROOT CAUSE ENCODED: the three rows showed their caption only, so the chord
; that pauses, reloads or quits was written nowhere in the tray.
; ==============================================================================

#Requires AutoHotkey v2.0

_TSH_Read(Relative) {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\" . Relative, "UTF-8"))
}

; The slot ids of script_chords.json, in catalogue order.
_TSH_Slots() {
	Slots := []
	for Slot in _TSH_Read("shortcuts\data\actions\script_chords.json")["slots"]
		Slots.Push(Slot["id"])
	return Slots
}

_TSH_Presets() {
	return Map("script_altgr_enter", "script_pause_toggle", "script_altgr_backspace", "script_reload",
		"script_altgr_delete", "open_personal_shortcuts", "script_altgr_escape", "script_quit")
}

; Runs Body with the live chords replaced, restoring them after.
_TSH_WithChords(Assignments, ChordsOn, Body) {
	global ScriptShortcutAssignments, ScriptShortcutChordsOn
	Saved := ScriptShortcutAssignments
	SavedOn := ScriptShortcutChordsOn
	ScriptShortcutAssignments := Assignments
	ScriptShortcutChordsOn := ChordsOn
	try Body.Call()
	finally {
		ScriptShortcutAssignments := Saved
		ScriptShortcutChordsOn := SavedOn
	}
}

_TSH_Vectors() {
	Slots := _TSH_Slots()
	Vectors := _TSH_Read("tests\corpus\shortcuts\script_chord_hint_vectors.json")["vectors"]
	AssertTrue(Vectors.Length >= 9, "the corpus holds its nine vectors")
	for Vector in Vectors {
		Assignments := Map()
		for Slot, Action in Vector["assignments"]
			Assignments[Slot] := Action
		AssertEqual(Vector["expected"],
			ScriptChordHintSlot(Slots, Assignments, Vector["chords_on"], Vector["action"]), Vector["id"])
	}
	AssertThrows(() => ScriptChordHintSlot(Slots, Map(), true, "none"), "a row without an action id")
	AssertThrows(() => ScriptChordHintSlot(Slots, 0, true, "script_quit"), "no assignments")
}
Test("tray shortcut hint: the shared vectors (script-chord-tray-hint)", _TSH_Vectors)

_TSH_CatalogueOrderIsTheDriverOrder() {
	global SCRIPT_SHORTCUT_SLOTS
	Slots := _TSH_Slots()
	AssertEqual(Slots.Length, SCRIPT_SHORTCUT_SLOTS.Length, "the same slots")
	for Index, Slot in Slots
		AssertEqual(Slot, SCRIPT_SHORTCUT_SLOTS[Index], "the hint reads the catalogue's order at " . Index)
}
Test("tray shortcut hint: the driver's slots are the catalogue's, in its order (script-chord-tray-hint)",
	_TSH_CatalogueOrderIsTheDriverOrder)

_TSH_StagedRowsCarryTheirChord() {
	global _TrayMenuStage, MenuSuspend
	SavedStage := _TrayMenuStage
	try {
		_TrayMenuStage := false
		TrayMenuStage_Begin()
		_MI_StageSuspend()
		_MI_StageReload()
		_MI_StageQuit()
		AssertEqual(3, _TrayMenuStage.Length, "the three rows are staged")
		AssertEqual(t("menu.global.suspend") . "`t" . t("sg_labels.script_altgr_enter"), _TrayMenuStage[1]["label"])
		AssertEqual(MenuSuspend, _TrayMenuStage[1]["label"], "the pause checkmark addresses the hinted row")
		AssertEqual(t("menu.global.reload") . "`t" . t("sg_labels.script_altgr_backspace"), _TrayMenuStage[2]["label"])
		AssertEqual(t("menu.global.quit") . "`t" . t("sg_labels.script_altgr_escape"), _TrayMenuStage[3]["label"])
	} finally _TrayMenuStage := SavedStage
}
Test("tray shortcut hint: the staged rows name their preset chord after a tab (script-chord-tray-hint)",
	(*) => _TSH_WithChords(_TSH_Presets(), true, _TSH_StagedRowsCarryTheirChord))

_TSH_MovedChord() {
	AssertEqual(t("menu.global.quit") . "`t" . t("sg_labels.script_altgr_enter"),
		ScriptShortcutTrayLabel(t("menu.global.quit"), "script_quit"), "the first of two slots")
	AssertEqual(t("menu.global.reload"), ScriptShortcutTrayLabel(t("menu.global.reload"), "script_reload"),
		"an unbound action has no hint")
}
Test("tray shortcut hint: follows a chord moved to another slot (script-chord-tray-hint)",
	(*) => _TSH_WithChords(Map("script_altgr_enter", "script_quit", "script_altgr_backspace", "none",
		"script_altgr_delete", "none", "script_altgr_escape", "script_quit"), true, _TSH_MovedChord))

_TSH_SwitchOff() {
	for Key, Action in Map("menu.global.suspend", "script_pause_toggle", "menu.global.reload", "script_reload",
		"menu.global.quit", "script_quit")
		AssertEqual(t(Key), ScriptShortcutTrayLabel(t(Key), Action), Key . ": no hint while the switch is off")
}
Test("tray shortcut hint: none while the chords' switch is off (script-chord-tray-hint)",
	(*) => _TSH_WithChords(_TSH_Presets(), false, _TSH_SwitchOff))
