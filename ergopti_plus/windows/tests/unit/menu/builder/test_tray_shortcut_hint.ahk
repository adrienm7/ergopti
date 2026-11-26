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
; that pauses, reloads or quits was written nowhere in the tray. Then the hint
; read the chord globals wherever a tray was staged, so a menu built before
; ReadScriptShortcutsConfig (and this harness, which never runs
; feature_state.ahk) threw an unset-global error instead of drawing its rows.
; Each case here stages the chord state a boot builds, and restores it after.
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

; The driver's declared slot list, read from feature_state.ahk: the harness does
; not run that file's declarations, and the boot runs exactly this block.
_TSH_DeclaredSlots() {
	Source := _StripFullLineComments(_DriverFileSource("feature_state.ahk"))
	Start := InStr(Source, "global SCRIPT_SHORTCUT_SLOTS := [")
	AssertTrue(Start > 0, "feature_state.ahk declares SCRIPT_SHORTCUT_SLOTS")
	Block := SubStr(Source, Start, InStr(Source, "]", , Start) - Start)
	Slots := []
	Pos := 1
	while (Pos := RegExMatch(Block, '"([a-z_]+)"', &Found, Pos)) {
		Slots.Push(Found[1])
		Pos += Found.Len
	}
	return Slots
}

; Runs Body with the chord state a boot builds (the declared slots and their
; labels, the read chords at Assignments and the switch at ChordsOn), then
; restores what the harness had, unset included.
_TSH_WithChords(Assignments, ChordsOn, Body) {
	global SCRIPT_SHORTCUT_SLOTS, SCRIPT_SHORTCUT_LABELS, ScriptShortcutAssignments, ScriptShortcutChordsOn
	global ScriptShortcutChordsRead
	SavedSlots := IsSet(SCRIPT_SHORTCUT_SLOTS) ? SCRIPT_SHORTCUT_SLOTS : unset
	SavedLabels := IsSet(SCRIPT_SHORTCUT_LABELS) ? SCRIPT_SHORTCUT_LABELS : unset
	Saved := IsSet(ScriptShortcutAssignments) ? ScriptShortcutAssignments : unset
	SavedOn := IsSet(ScriptShortcutChordsOn) ? ScriptShortcutChordsOn : unset
	SavedRead := IsSet(ScriptShortcutChordsRead) ? ScriptShortcutChordsRead : unset
	SCRIPT_SHORTCUT_SLOTS := _TSH_DeclaredSlots()
	SCRIPT_SHORTCUT_LABELS := Map()
	for Slot in SCRIPT_SHORTCUT_SLOTS
		SCRIPT_SHORTCUT_LABELS[Slot] := "sg_labels." . Slot
	ScriptShortcutAssignments := Assignments
	ScriptShortcutChordsOn := ChordsOn
	ScriptShortcutChordsRead := true
	try Body.Call()
	finally {
		SCRIPT_SHORTCUT_SLOTS := IsSet(SavedSlots) ? SavedSlots : unset
		SCRIPT_SHORTCUT_LABELS := IsSet(SavedLabels) ? SavedLabels : unset
		ScriptShortcutAssignments := IsSet(Saved) ? Saved : unset
		ScriptShortcutChordsOn := IsSet(SavedOn) ? SavedOn : unset
		ScriptShortcutChordsRead := IsSet(SavedRead) ? SavedRead : unset
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
	Slots := _TSH_Slots()
	Declared := _TSH_DeclaredSlots()
	AssertEqual(Slots.Length, Declared.Length, "the same slots")
	for Index, Slot in Slots
		AssertEqual(Slot, Declared[Index], "the hint reads the catalogue's order at " . Index)
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

; A tray staged before the boot read the chords draws its captions alone, and
; never touches the chord globals: here they are all unset, as in early boot's
; harness view, so reading one would throw.
_TSH_BeforeTheChordsAreRead() {
	global SCRIPT_SHORTCUT_SLOTS, SCRIPT_SHORTCUT_LABELS, ScriptShortcutAssignments, ScriptShortcutChordsOn
	global ScriptShortcutChordsRead, _TrayMenuStage
	SavedSlots := IsSet(SCRIPT_SHORTCUT_SLOTS) ? SCRIPT_SHORTCUT_SLOTS : unset
	SavedLabels := IsSet(SCRIPT_SHORTCUT_LABELS) ? SCRIPT_SHORTCUT_LABELS : unset
	Saved := IsSet(ScriptShortcutAssignments) ? ScriptShortcutAssignments : unset
	SavedOn := IsSet(ScriptShortcutChordsOn) ? ScriptShortcutChordsOn : unset
	SavedRead := IsSet(ScriptShortcutChordsRead) ? ScriptShortcutChordsRead : unset
	SavedStage := _TrayMenuStage
	try {
		SCRIPT_SHORTCUT_SLOTS := unset
		SCRIPT_SHORTCUT_LABELS := unset
		ScriptShortcutAssignments := unset
		ScriptShortcutChordsOn := unset
		ScriptShortcutChordsRead := unset
		AssertFalse(ScriptShortcutChordsAreRead(), "no chord is read before the boot reads them")
		AssertEqual(t("menu.global.reload"), ScriptShortcutTrayLabel(t("menu.global.reload"), "script_reload"),
			"the caption alone")
		_TrayMenuStage := false
		TrayMenuStage_Begin()
		_MI_StageSuspend()
		_MI_StageReload()
		_MI_StageQuit()
		AssertEqual(3, _TrayMenuStage.Length, "the three rows are staged without the chords")
		AssertEqual(t("menu.global.suspend"), _TrayMenuStage[1]["label"])
		AssertEqual(t("menu.global.quit"), _TrayMenuStage[3]["label"])
	} finally {
		_TrayMenuStage := SavedStage
		SCRIPT_SHORTCUT_SLOTS := IsSet(SavedSlots) ? SavedSlots : unset
		SCRIPT_SHORTCUT_LABELS := IsSet(SavedLabels) ? SavedLabels : unset
		ScriptShortcutAssignments := IsSet(Saved) ? Saved : unset
		ScriptShortcutChordsOn := IsSet(SavedOn) ? SavedOn : unset
		ScriptShortcutChordsRead := IsSet(SavedRead) ? SavedRead : unset
	}
}
Test("tray shortcut hint: a tray staged before the chords are read shows its captions (script-chord-tray-hint)",
	_TSH_BeforeTheChordsAreRead)
