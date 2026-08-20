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
; ======= 3/ There is no splice left to run twice ================
; ================================================================
; ================================================================

_MSG_GroupsComeFromTheManifest() {
	; The bug was a splice that could run more than once against a persistent Menu
	; object. The groups now come from a manifest "list" entry, and
	; MenuRenderer_Build creates a fresh Menu() on every call -- so the duplication
	; is not merely avoided, it has no place left to happen. This asserts that
	; structural fact rather than the old "splice exactly once" arrangement, which
	; would still be one careless call site away from the original bug.
	Src := _DriverSourceNoComments()

	Assert(!InStr(Src, "InsertKeyboardShortcutGroups("),
		"the InsertKeyboardShortcutGroups splice must stay gone -- reintroducing any Menu.Insert pass "
		. "over a persistent SubMenus entry brings back the unbounded row growth "
		. "(menu-shortcut-groups-duplicated-on-updater-rebuild)")

	Body := _DriverFuncBody("_BuildShortcutsSubmenu")
	Assert(Body != "", "_BuildShortcutsSubmenu() must exist in the driver source")
	Assert(InStr(Body, '"keyboard_slots"') > 0,
		"_BuildShortcutsSubmenu must register the keyboard_slots list provider, or the section is "
		. "skipped with a warning and simply vanishes from the tray")
	Assert(InStr(Body, "MenuRenderer_Build(") > 0,
		"_BuildShortcutsSubmenu must build through the manifest renderer")

	; The renderer must keep constructing a fresh Menu per call. If it ever started
	; caching and mutating one, every guarantee above would be void.
	RendererBody := _DriverFuncBody("MenuRenderer_Build")
	Assert(RendererBody != "", "MenuRenderer_Build() must exist in the driver source")
	Assert(RegExMatch(RendererBody, "Result\s*:=\s*Menu\(\)"),
		"MenuRenderer_Build must construct a fresh Menu on every call -- a cached menu mutated in "
		. "place would duplicate rows exactly the way the old splice did")
}
Test("menu: the keyboard-shortcut groups come from the manifest, not a splice (menu-shortcut-groups-duplicated-on-updater-rebuild)",
	_MSG_GroupsComeFromTheManifest)
