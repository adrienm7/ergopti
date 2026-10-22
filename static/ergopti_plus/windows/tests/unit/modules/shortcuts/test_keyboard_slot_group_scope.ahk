; tests/unit/modules/shortcuts/test_keyboard_slot_group_scope.ahk

; ==============================================================================
; MODULE: Each Modifier Group Restores And Clears Its Own Slots
; DESCRIPTION:
; The keyboard-slot groups (Alt / Ctrl / Ctrl+Shift / Win) only offered their
; Add row: putting one group back to Ergopti's preset or emptying it took one
; picker per slot. Each group now opens with « ↺ Restaurer les valeurs
; conseillées » and « ✕ Tout effacer », then a separator, the Shortcuts scope
; narrowed to that group's slots and their action parameters. These tests
; render the real rows and run the real scope owner over a private
; configuration file (keyboard-group-scope-2026-10-22).
; ==============================================================================

#Requires AutoHotkey v2.0

; Every bindable group of the tray opens with its restore, clear and separator;
; the contextual group keeps its one slot and nothing else.
_KGS_RowsOpenWithRestoreAndClear() {
	global KeyboardShortcutAssignments, KEYBOARD_SLOT_GROUPS
	Had := IsSet(KeyboardShortcutAssignments)
	Saved := Had ? KeyboardShortcutAssignments : 0
	try {
		KeyboardShortcutAssignments := ManifestBuildFeaturesMap()["shortcuts"]["keyboard"].Clone()
		Rows := KeyboardSlotRows()
		AssertEqual(KEYBOARD_SLOT_GROUPS.Length, Rows.Length, "one row per declared keyboard group")
		Bindable := 0
		for Index, Row in Rows {
			Items := Row["items"]
			if KEYBOARD_SLOT_GROUPS[Index]["prefix"] == "magic_" {
				Assert(Items[1].Get("label", "") != t("common.restore_recommended"),
					"the contextual slot has no modifier group to restore")
				continue
			}
			Bindable += 1
			Assert(Items.Length >= 4, Row["label"] . " holds its scope rows and its Add row")
			AssertEqual(t("common.restore_recommended"), Items[1]["label"], Row["label"] . " opens with its restore")
			AssertEqual(t("common.clear_to_system"), Items[2]["label"], Row["label"] . " follows with its clear")
			Assert(Items[3].Get("separator", false), Row["label"] . " closes its first group")
			Assert(HasMethod(Items[1]["action"], "Call") && HasMethod(Items[2]["action"], "Call"),
				Row["label"] . " scope rows are clickable")
			AssertEqual(t(KEYBOARD_SLOT_GROUPS[Index]["add_key"]), Items[Items.Length]["label"],
				Row["label"] . " keeps its Add row")
		}
		AssertEqual(4, Bindable, "the four modifier groups carry the scope rows")
	} finally {
		if Had
			KeyboardShortcutAssignments := Saved
		else
			KeyboardShortcutAssignments := unset
	}
}
Test("keyboard-group-scope: every modifier group opens with its restore and clear", _KGS_RowsOpenWithRestoreAndClear)

; The group's clear and restore touch its slots and their parameters only.
_KGS_ScopeTouchesOneGroup() {
	global KeyboardShortcutAssignments, GestureActionParameters
	HadAssignments := IsSet(KeyboardShortcutAssignments)
	SavedAssignments := HadAssignments ? KeyboardShortcutAssignments : 0
	SavedParameters := GestureActionParameters
	Source := '[shortcuts.keyboard]`nwin_b = "open_url"`nctrl_q = "open_url"`nctrl_shift_q = "select_line"`n'
		. '[action_parameters]`nkeyboard__win_b__open_url = "https://example.com/b"`n'
		. 'keyboard__ctrl_q__open_url = "https://example.com/q"`n[llm]`nenabled = true`n'
	Fixture := _ScopeOwnerFixture(Source)
	Source := Fixture.source
	Assert(FSWriteDurable(Fixture.path, Source))
	Assignments := ManifestBuildFeaturesMap()["shortcuts"]["keyboard"].Clone()
	Assignments["win_b"] := "open_url", Assignments["ctrl_q"] := "open_url", Assignments["ctrl_shift_q"] := "select_line"
	KeyboardShortcutAssignments := Assignments
	GestureActionParameters := Map("keyboard__win_b__open_url", "https://example.com/b",
		"keyboard__ctrl_q__open_url", "https://example.com/q")
	Refusal := 0, Bundle := 0
	Launch(_Success, Borrowed, Refused) {
		Bundle := Borrowed
		Refusal := Refused
		return true
	}
	Fixture.options["reload"] := Launch
	try {
		for Mode in ["clear", "recommended"] {
			Fixture.options["stamp"] := "group-" . Mode
			Receipt := KeyboardSlotGroupApplyScope("win_", Mode, Fixture.options)
			AssertEqual("pending", Receipt["status"], "the Win group " . Mode . " is published")
			Parsed := TOML_ParseFreshFile(Fixture.path)
			Keyboard := Parsed["shortcuts.keyboard"]
			Assert(!Keyboard.Has("win_b"), "the user's Win slot leaves with the " . Mode)
			Assert(!Parsed["action_parameters"].Has("keyboard__win_b__open_url"), "its parameter goes with it")
			AssertEqual("open_url", Keyboard["ctrl_q"], "the Ctrl group is untouched")
			AssertEqual("select_line", Keyboard["ctrl_shift_q"], "the Ctrl+Shift group is untouched")
			AssertEqual("https://example.com/q", Parsed["action_parameters"]["keyboard__ctrl_q__open_url"])
			AssertEqual(true, Parsed["llm"]["enabled"], "another scope is untouched")
			Assert(!Keyboard.Has("ctrl_b"), "another group's preset is not applied")
			if Mode == "recommended"
				AssertEqual(ManifestRecommendedFor("shortcuts.keyboard.win_a"), Keyboard["win_a"],
					"a shipped Win slot takes its recommended action")
			else
				Assert(!Keyboard.Has("win_a"), "the clear empties the shipped Win slots")
			Refusal.Call("refused")
			AssertEqual("refused", Receipt["status"])
			AssertEqual(Source, FSReadUtf8Exact(Fixture.path), "the refusal restores the exact source")
			if Bundle is Object
				_ConfigWriteTerminalRelease(Bundle)
			Bundle := 0
		}
		Threw := false
		try KeyboardSlotGroupScopeRows("magic_", "clear")
		catch ValueError
			Threw := true
		Assert(Threw, "the contextual group has no modifier scope")
	} finally {
		GestureActionParameters := SavedParameters
		if HadAssignments
			KeyboardShortcutAssignments := SavedAssignments
		else
			KeyboardShortcutAssignments := unset
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_ScopeOwnerCleanup(Fixture)
	}
}
Test("keyboard-group-scope: the Win group's clear and restore touch its slots and parameters only",
	_KGS_ScopeTouchesOneGroup)
