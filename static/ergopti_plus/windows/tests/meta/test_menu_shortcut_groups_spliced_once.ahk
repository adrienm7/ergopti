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
	; initMenu dispatches every top-level row to a builder, so the SubMenus reads
	; live in those builders; _Updater_RebuildMenu reaches all of them.
	Body := _TrayRootBuilderBodies()
	Assert(Body != "", "the tray-root builders must exist in the driver source")

	Reads := 0
	for Line in StrSplit(Body, "`n", "`r") {
		if !InStr(Line, "SubMenus[")
			continue
		Reads += 1
		; TrayMenuStage_AddFeature is the head-row form of the same staging call
		; (it only records the row as a feature for pause greying).
		Assert(_MSG_RetainedSubmenuRead(Line, _DriverFuncBody("_MI_StageDeclaredFeature")),
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
	; MenuRenderer_Build creates a fresh Menu() by default -- so the duplication
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

	; The renderer must keep constructing a fresh Menu by default. If it ever started
	; caching and mutating one, every guarantee above would be void.
	RendererBody := _DriverFuncBody("MenuRenderer_Build")
	Assert(RendererBody != "", "MenuRenderer_Build() must exist in the driver source")
	Assert(RegExMatch(RendererBody, "Result\s*:=\s*Menu\(\)"),
		"MenuRenderer_Build must construct a fresh Menu by default -- a cached menu mutated in "
		. "place would duplicate rows exactly the way the old splice did")
}
Test("menu: the keyboard-shortcut groups come from the manifest, not a splice (menu-shortcut-groups-duplicated-on-updater-rebuild)",
	_MSG_GroupsComeFromTheManifest)


; Ignore executable spacing while retaining every quoted identity byte.
_MSG_ExecutableSpacing(Source) {
	Quote := Chr(34)
	Pattern := "(?:'(?:``[\s\S]|[^'``])*'|" . Quote
		. "(?:``[\s\S]|[^" . Quote . "``])*" . Quote . ")(*SKIP)(*F)|\s+"
	return RegExReplace(Source, Pattern, "")
}

; A retained child may join only the reviewed non-disposing feature adapter.
_MSG_RetainedFeatureAdapter(Body) {
	Expected := '_MI_StageDeclaredFeature(Receiver, Child, Getters, DisposeOnRefusal := false) {`n'
		. '	Published := false`n'
		. '	try {`n'
		. '		Row := Receiver.Call(Child, Getters)`n'
		. '		if !(Row is Map) || Row.Get("submenu", false) != Child`n'
		. '			throw Error("The canonical feature parent changed during native construction.")`n'
		. '		TrayMenuStage_AddFeature(Row["label"], Child)`n'
		. '		Published := true`n'
		. '		if Row.Get("checked", false)`n'
		. '			TrayMenuStage_Check(Row["label"])`n'
		. '		return true`n'
		. '	} finally {`n'
		. '		if DisposeOnRefusal && !Published {`n'
		. '			try Child.Delete()`n'
		. '			finally MenuDispatcher_PruneMenu(Child)`n'
		. '		}`n'
		. '	}`n'
		. '}`n'
	return _MSG_ExecutableSpacing(_StripFullLineComments(Body))
		== _MSG_ExecutableSpacing(Expected)
}

_MSG_RetainedSubmenuRead(Line, Adapter) {
	Code := _MSG_ExecutableSpacing(Line)
	; The legacy direct form also passes the original child as its only child use.
	if RegExMatch(Code, '^TrayMenuStage_Add(?:Feature)?\((?:[A-Za-z_][A-Za-z0-9_]*|t\("[^"\r\n]+"\)),SubMenus\["(?:Shortcuts|TapHolds)"\]\)$')
		return true
	if !_MSG_RetainedFeatureAdapter(Adapter)
		return false
	for Key, Gate in Map("Shortcuts", "shortcuts_enabled", "TapHolds", "tapholds_enabled") {
		Expected := '_MI_StageDeclaredFeature(Receiver,SubMenus["' . Key . '"],Map("'
			. Gate . '",()=>IsCategoryGated("' . Key . '")))'
		if Code == Expected
			return true
	}
	return false
}

_MSG_RetainedFeatureRejectsMutation() {
	Adapter := _DriverFuncBody("_MI_StageDeclaredFeature")
	AssertTrue(_MSG_RetainedFeatureAdapter(Adapter), "the actual default-false adapter retains its supplied child")
	for Name in ["_MI_StageShortcuts", "_MI_StageTapHolds"] {
		Body := _DriverFuncBody(Name), Calls := 0
		for Line in StrSplit(Body, "`n", "`r") {
			if !InStr(Line, "SubMenus[")
				continue
			Calls += 1
			AssertTrue(_MSG_RetainedSubmenuRead(Line, Adapter), "the real row retains its child with disposal omitted")
			AssertFalse(_MSG_RetainedSubmenuRead(SubStr(Line, 1, -1) . ", true)", Adapter), "explicit disposal cannot consume a retained submenu")
			AssertFalse(_MSG_RetainedSubmenuRead(StrReplace(Line, "SubMenus[", "CloneSubMenus["), Adapter), "a different child authority cannot pass")
			ChangedKey := StrReplace(StrReplace(Line, '"Shortcuts"', '"Short cuts"'), '"TapHolds"', '"Tap Holds"')
			AssertFalse(_MSG_RetainedSubmenuRead(ChangedKey, Adapter), "quoted child identities cannot be normalized into another key")
			AssertFalse(_MSG_RetainedSubmenuRead("; " . Line, Adapter), "a commented staging call is not executable")
		}
		AssertEqual(1, Calls, "each actual retained parent is scanned once")
	}
	for Mutant in [StrReplace(Adapter, "DisposeOnRefusal := false", "DisposeOnRefusal := true"),
		StrReplace(Adapter, "if DisposeOnRefusal && !Published", "if !Published"),
		StrReplace(Adapter, "TrayMenuStage_AddFeature(Row", 'Child.Insert("anchor")' . "`nTrayMenuStage_AddFeature(Row"),
		StrReplace(Adapter, 'Row.Get("submenu", false) != Child', 'Row.Get("submenu", false) != 0'),
		StrReplace(Adapter, 'Row.Get("submenu", false) != Child', 'Row.Get("sub menu", false) != Child'),
		StrReplace(Adapter, 'Row["label"], Child', 'Row["label"], Menu()')] {
		Assert(Mutant !== Adapter, "every source withdrawal changes the real adapter")
		AssertFalse(_MSG_RetainedFeatureAdapter(Mutant), "child mutation, substitution and disposal remain refused")
	}
}
Test("menu: retained feature staging refuses child substitution and implicit disposal", _MSG_RetainedFeatureRejectsMutation)
