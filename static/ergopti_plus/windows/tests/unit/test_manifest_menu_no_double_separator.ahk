; static/ergopti_plus/windows/tests/unit/test_manifest_menu_no_double_separator.ahk

; ==============================================================================
; MODULE: Manifest Menu Double Separator Regression
; DESCRIPTION:
; Renders every menu of the shared manifest and fails on any separator that
; does not sit between two real items: two in a row, or one at either end.
;
; The tray showed two lines in a row under « Disposition »: AddCategoryToggleItem
; inserts its own separator after a category toggle, while the shared Lua
; renderer adds none, so layout_menu declares a "---" right after its toggle for
; the Lua drivers — and MenuRenderer_Build added that "---" as well. Every probe
; here brings a separator on both sides of its row, the worst case a driver row
; can produce. The Lua suites run the same check through test.menu_separators.
; ==============================================================================





; ===================================================
; ===================================================
; ======= 1/ Native separator walk ==================
; ===================================================
; ===================================================

; Returns every misplaced separator of a native menu as a readable string.
_MMNDS_Defects(TargetMenu, MenuName) {
	static MF_BYPOSITION := 0x400, MF_SEPARATOR := 0x800
	HMENU := TargetMenu.Handle
	Count := DllCall("GetMenuItemCount", "ptr", HMENU, "int")
	Assert(Count >= 0, "the rendered menu '" . MenuName . "' must expose a usable HMENU")
	Defects := ""
	PrevWasSep := true
	loop Count {
		State := DllCall("GetMenuState", "ptr", HMENU, "uint", A_Index - 1, "uint", MF_BYPOSITION, "uint")
		IsSep := (State != 0xFFFFFFFF) and (State & MF_SEPARATOR) != 0
		if (IsSep and PrevWasSep) {
			Defects .= MenuName . ": separator at position " . A_Index . "; "
		}
		PrevWasSep := IsSep
	}
	if (Count > 0 and PrevWasSep) {
		Defects .= MenuName . ": ends with a separator; "
	}
	return Defects
}




; ===================================================
; ===================================================
; ======= 2/ Worst-case probes ======================
; ===================================================
; ===================================================

; Rows whose rendering needs driver modules the harness does not load become a
; probe list at the same position — where separators land depends only on the
; sequence of rows, not on what each row is.
_MMNDS_ProbeDeclaration(Def, &Counter) {
	static NEEDS_DRIVER := Map("feature", true, "group", true, "letter_picker", true)
	Probe := []
	for Item in Def {
		Type := _MR_Get(Item, "type")
		if NEEDS_DRIVER.Has(Type) {
			Counter++
			Copy := Map("type", "list", "id", "probe_" . Counter)
			if Item.Has("platforms") {
				Copy["platforms"] := Item["platforms"]
			}
			Probe.Push(Copy)
		} else {
			Probe.Push(Item)
		}
	}
	return Probe
}

; Every renderer menu of the manifest: the arrays whose entries carry a type.
_MMNDS_MenuKeys(Root) {
	Keys := []
	for Key, Value in Root {
		if (Value is Array and Value.Length > 0 and Value[1] is Map and Value[1].Has("type")) {
			Keys.Push(Key)
		}
	}
	return Keys
}

_MMNDS_EveryMenuHasNoMisplacedSeparator() {
	static PROBE_KEY := "_test_separator_probe_menu"
	Root := _MR_GetManifestRoot()
	Assert(Root is Map, "the shared menu manifest must load")
	Keys := _MMNDS_MenuKeys(Root)
	Assert(Keys.Length > 10, "every renderer menu of the shared manifest must be found, got " . Keys.Length)

	Counter := 0
	Defects := ""
	for Key in Keys {
		Probe := _MMNDS_ProbeDeclaration(Root[Key], &Counter)
		Handlers := Map(), Providers := Map(), Commands := Map()
		for Item in Probe {
			Id := _MR_Get(Item, "id")
			if (Id == "") {
				continue
			}
			Label := "Probe " . Key . " " . Id
			Providers[Id] := ((L) => () => [Map("separator", true), Map("label", L), Map("separator", true)])(Label)
			Handlers[Id] := ((L) => (M, *) => (M.Add(), M.Add(L, (*) => 0), M.Add()))(Label)
			Commands[_MR_Get(Item, "command") != "" ? _MR_Get(Item, "command") : Id] := (*) => 0
		}
		Root[PROBE_KEY] := Probe
		try {
			Rendered := MenuRenderer_Build(PROBE_KEY, "Layout", Handlers, "", Providers, Commands)
		} finally {
			Root.Delete(PROBE_KEY)
		}
		Defects .= _MMNDS_Defects(Rendered, Key)
	}
	Assert(Defects == "", "a separator must sit between two real items -- " . Defects)
}
Test("menu: no manifest menu renders a misplaced separator (layout-menu-double-separator)",
	_MMNDS_EveryMenuHasNoMisplacedSeparator)

; The bug as reported: layout_menu opens with its toggle and then a "---".
_MMNDS_LayoutMenuDeclaresToggleThenSeparator() {
	Def := _MR_GetMenuDef("layout_menu")
	Assert(Def.Length > 1, "layout_menu must be declared in the shared manifest")
	Assert(_MR_Get(Def[1], "type") == "toggle" and _MR_Get(Def[2], "type") == "---",
		"layout_menu must open with its toggle followed by '---' -- if that changed, "
		. "the probe above no longer covers the reported case")
}
Test("menu: layout_menu opens with a toggle then '---' (layout-menu-double-separator)",
	_MMNDS_LayoutMenuDeclaresToggleThenSeparator)

_MMNDS_NormalizeDropsMisplacedSeparators() {
	Probe := Menu()
	Probe.Add()
	Probe.Add("A", (*) => 0)
	Probe.Add()
	Probe.Add()
	Probe.Add("B", (*) => 0)
	Probe.Add()
	_MR_NormalizeSeparators(Probe)
	Assert(_MMNDS_Defects(Probe, "probe") == "", "normalising must leave only A, separator, B")
	Assert(DllCall("GetMenuItemCount", "ptr", Probe.Handle, "int") == 3,
		"normalising must keep both rows and exactly one separator between them")
}
Test("menu: _MR_NormalizeSeparators keeps one separator between rows (layout-menu-double-separator)",
	_MMNDS_NormalizeDropsMisplacedSeparators)
