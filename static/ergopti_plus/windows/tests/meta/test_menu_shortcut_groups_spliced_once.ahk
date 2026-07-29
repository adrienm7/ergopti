; tests/meta/test_menu_shortcut_groups_spliced_once.ahk

; ==============================================================================
; MODULE: Keyboard-Shortcut Group Splice Idempotence Meta Test
; DESCRIPTION:
; Regression guard for menu-shortcut-groups-duplicated-on-updater-rebuild.
;
; InsertKeyboardShortcutGroups splices the Alt / Ctrl / Ctrl+Shift / Win group
; submenus in above the modifier-combos anchor with a plain Menu.Insert sequence
; and no idempotence check. AHK v2's Menu.Insert APPENDS on an existing label --
; it does not merge the way Menu.Add does -- so running the splice twice on the
; SAME Menu object adds five more rows (four groups plus a separator).
;
; The splice used to run from initMenu(), against SubMenus["Shortcuts"] -- a
; persistent object built once per InitSubMenus(). _Updater_RebuildMenu calls
; initMenu() ALONE, with no InitSubMenus(), and is armed from ten SetTimer sites
; (check-interval change, background poller, one-click update, download
; start/end). Every one of those refreshes therefore grew the Raccourcis submenu
; by five more rows, unbounded until the next Reload.
;
; ROOT CAUSE ENCODED: initMenu() must only READ SubMenus, and the splice belongs
; to the single construction point in InitSubMenus(). Both properties are derived
; from driver source, so a new mutation of a SubMenus entry inside initMenu(), or
; a second splice call site anywhere in the driver, fails here automatically.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================================
; ==================================================================
; ======= 1/ Prerequisite: Menu.Insert is not idempotent ===========
; ==================================================================
; ==================================================================

; Returns the live item count of a Menu via its native HMENU, or -1 when the
; handle is unavailable (which makes the caller fail loudly rather than pass).
_MSG_MenuItemCount(MenuObj) {
	try {
		HMENU := MenuObj.Handle
		if (HMENU)
			return DllCall("GetMenuItemCount", "ptr", HMENU, "int")
	}
	return -1
}

; This is the mechanism the whole finding rests on, so it is measured rather
; than asserted from memory: if AHK ever started merging on Insert the way it
; merges on Add, sections 2 and 3 would be guarding nothing and should be
; revisited instead of silently kept.
_MSG_MenuInsertIsNotIdempotent() {
	Anchor := "ANCHOR"
	Probe  := Menu()
	Probe.Add(Anchor, (*) => 0)

	Probe.Insert(Anchor)
	Probe.Insert(Anchor, "GrpA", Menu())
	First := _MSG_MenuItemCount(Probe)
	Assert(First > 1, "the probe menu must expose a usable HMENU and hold the spliced rows")

	Probe.Insert(Anchor)
	Probe.Insert(Anchor, "GrpA", Menu())
	Second := _MSG_MenuItemCount(Probe)

	Assert(Second > First,
		"PREREQUISITE: AHK v2 Menu.Insert appends on an existing label instead of merging, so a "
		. "second splice pass on the same Menu duplicates every group row -- that is exactly why the "
		. "splice must run once per menu CONSTRUCTION and never from a bare initMenu() "
		. "(menu-shortcut-groups-duplicated-on-updater-rebuild)")
}
Test("menu: Menu.Insert duplicates rows on a repeated splice (menu-shortcut-groups-duplicated-on-updater-rebuild)",
	_MSG_MenuInsertIsNotIdempotent)





; =========================================================
; =========================================================
; ======= 2/ initMenu() only READS SubMenus entries =======
; =========================================================
; =========================================================

_MSG_InitMenuOnlyReadsSubMenus() {
	Body := _DriverFuncBody("initMenu")
	Assert(Body != "", "initMenu() must exist in the driver source")

	Reads := 0
	for Line in StrSplit(Body, "`n", "`r") {
		if !InStr(Line, "SubMenus[")
			continue
		Reads += 1
		Assert(RegExMatch(Line, "^\s*TrayMenuStage_Add\("),
			"initMenu() must only READ a SubMenus entry (hand it to TrayMenuStage_Add) and never call "
			. "anything that MUTATES one. _Updater_RebuildMenu calls initMenu() alone, so a mutation "
			. "here is replayed on every updater tray refresh and never undone by a rebuild of the "
			. "submenu -- offending line: " . Trim(Line))
	}
	Assert(Reads >= 2,
		"initMenu() must still consume the SubMenus entries (Shortcuts, TapHolds) -- an empty scan "
		. "would make this check vacuous")
}
Test("menu: initMenu() never mutates a SubMenus entry (menu-shortcut-groups-duplicated-on-updater-rebuild)",
	_MSG_InitMenuOnlyReadsSubMenus)





; ================================================================
; ================================================================
; ======= 3/ The splice belongs to the construction point =========
; ================================================================
; ================================================================

_MSG_SpliceRunsOncePerConstruction() {
	Body := _DriverFuncBody("InitSubMenus")
	Assert(Body != "", "InitSubMenus() must exist in the driver source")

	BuildPos  := InStr(Body, 'SubMenus["Shortcuts"] := _BuildShortcutsSubmenu()')
	SplicePos := InStr(Body, 'InsertKeyboardShortcutGroups(SubMenus["Shortcuts"]')
	Assert(BuildPos > 0, "InitSubMenus() must build the Shortcuts submenu")
	Assert(SplicePos > BuildPos,
		"the keyboard-shortcut groups must be spliced into the Shortcuts submenu right where that "
		. "submenu is CONSTRUCTED, so the splice runs exactly once per menu object")

	; One definition plus exactly one call site. A second call site anywhere is
	; either a duplicate splice into the same object or a new menu that needs the
	; idempotence question answered first.
	Src := _DriverSourceNoComments()
	Occurrences := 0
	Pos := 1
	while (Found := InStr(Src, "InsertKeyboardShortcutGroups(", , Pos)) {
		Occurrences += 1
		Pos := Found + 1
	}
	Assert(Occurrences == 2,
		"InsertKeyboardShortcutGroups must appear exactly twice in driver source -- its definition "
		. "plus the single splice at the Shortcuts submenu construction point. Any further call site "
		. "re-splices a menu that already carries the groups, and Menu.Insert appends rather than "
		. "merges -- found " . Occurrences)
}
Test("menu: the keyboard-shortcut groups are spliced once, at construction (menu-shortcut-groups-duplicated-on-updater-rebuild)",
	_MSG_SpliceRunsOncePerConstruction)
