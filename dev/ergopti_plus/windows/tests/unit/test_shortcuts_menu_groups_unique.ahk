; tests/unit/test_shortcuts_menu_groups_unique.ahk

; ==============================================================================
; MODULE: Shortcuts Menu Groups Are Unique And Titled
; DESCRIPTION:
; Cheap structural guard for the Shortcuts submenu. The keyboard-slot groups
; (Alt / Ctrl / Ctrl+Shift / Win) are row data built by KeyboardSlotRows, and a
; native menu silently accepts two rows with the same label — the second one
; then shadows the first for every Menu.Rename / Check by label. A group with no
; row renders an empty, unclickable submenu, and a row whose label is a raw i18n
; key (or empty) is what a missing translation looks like in the tray.
;
; The rows are read from the real providers with the shipped assignments, so a
; new group, slot or locale key is covered without editing this file.
; ==============================================================================

#Requires AutoHotkey v2.0

_SMGU_AssertTitled(Label, Key, Where) {
	Assert(Label is String && Trim(Label) != "", Where . " must have a title")
	Assert(Label != Key, Where . " shows its raw i18n key '" . Key . "'")
}

_SMGU_KeyboardGroupsUniqueAndPopulated() {
	global KeyboardShortcutAssignments, KEYBOARD_SLOT_GROUPS
	Had := IsSet(KeyboardShortcutAssignments)
	Saved := Had ? KeyboardShortcutAssignments : 0
	; The shipped slots, read from the manifest that declares them.
	Shipped := ManifestBuildFeaturesMap()["shortcuts"]["keyboard"]
	Assert(Shipped.Count > 0, "the manifest must ship keyboard slots")
	try {
		KeyboardShortcutAssignments := Shipped.Clone()
		Rows := KeyboardSlotRows()
		AssertEqual(KEYBOARD_SLOT_GROUPS.Length, Rows.Length, "one row per declared keyboard group")
		Seen := Map()
		for Index, Row in Rows {
			_SMGU_AssertTitled(Row["label"], KEYBOARD_SLOT_GROUPS[Index]["group_key"],
				"keyboard group " . Index)
			AssertFalse(Seen.Has(Row["label"]), "duplicate keyboard group label '" . Row["label"] . "'")
			Seen[Row["label"]] := true
			Assert(Row.Has("items") && Row["items"].Length >= 1,
				"keyboard group '" . Row["label"] . "' must hold at least one row")
			ItemSeen := Map()
			for _, Item in Row["items"] {
				Assert(Trim(Item["label"]) != "", "every row of '" . Row["label"] . "' must have a label")
				AssertFalse(ItemSeen.Has(Item["label"]),
					"duplicate row '" . Item["label"] . "' in keyboard group '" . Row["label"] . "'")
				ItemSeen[Item["label"]] := true
			}
		}
		; Every shipped slot lands in exactly one group (the longest prefix wins).
		Placed := 0
		for _, Row in Rows
			Placed += Row["items"].Length - 1
		Active := 0
		for _, Action in Shipped
			Active += (Action != "none")
		AssertEqual(Active, Placed, "each assigned keyboard slot must appear in exactly one group")
	} finally {
		if Had
			KeyboardShortcutAssignments := Saved
		else
			KeyboardShortcutAssignments := unset
	}
}

_SMGU_WrapToggleRowTitled() {
	Entry := ManifestFindEntryByPath("shortcuts.wrap_text_if_selected")
	Assert(Entry is Map, "the wrap toggle must be declared in the features manifest")
	_SMGU_AssertTitled(t(Entry["description_key"]), Entry["description_key"], "the wrap toggle row")
	Rows := _SC_WrapSymbolRows()
	AssertEqual(1, Rows.Length, "the wrap-symbols picker is one row")
	_SMGU_AssertTitled(Rows[1]["label"], "menu.shortcuts.wrap_symbols_title", "the wrap-symbols row")
	Assert(Rows[1]["items"].Length >= 1, "the wrap-symbols picker must hold rows")
	Seen := Map()
	for _, Row in Rows[1]["items"] {
		if !Row.Has("items")
			continue
		Assert(Trim(Row["label"]) != "", "every wrap-symbol group must have a title")
		AssertFalse(Seen.Has(Row["label"]), "duplicate wrap-symbol group '" . Row["label"] . "'")
		Seen[Row["label"]] := true
		Assert(Row["items"].Length >= 1, "wrap-symbol group '" . Row["label"] . "' must hold rows")
	}
}

Test("shortcuts menu: keyboard groups are unique, titled and never empty (shortcuts-menu-groups-unique)",
	_SMGU_KeyboardGroupsUniqueAndPopulated)
Test("shortcuts menu: the wrap toggle and its picker rows are titled (shortcuts-menu-groups-unique)",
	_SMGU_WrapToggleRowTitled)
