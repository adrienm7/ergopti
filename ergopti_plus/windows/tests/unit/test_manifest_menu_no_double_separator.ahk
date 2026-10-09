; static/ergopti_plus/windows/tests/unit/test_manifest_menu_no_double_separator.ahk

; ==============================================================================
; MODULE: Manifest Menu Double Separator Regression
; DESCRIPTION:
; Renders every menu of the shared manifest and fails on any separator that
; does not sit between two real items: two in a row, or one at either end.
;
; The tray showed two lines in a row under « Disposition »: the category switch
; was inserted by hand with a separator of its own, and layout_menu declared a
; "---" right after its toggle for the Lua drivers — so MenuRenderer_Build added
; a second one. Every probe
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
	static MIIM_FTYPE := 0x100, MFT_SEPARATOR := 0x800
	HMENU := TargetMenu.Handle
	Count := DllCall("GetMenuItemCount", "ptr", HMENU, "int")
	Assert(Count >= 0, "the rendered menu '" . MenuName . "' must expose a usable HMENU")
	Defects := ""
	PrevWasSep := true
	; GetMenuState packs a submenu's child count into the flag word: ten children
	; set 0x800 without a separator. Query the actual item type independently.
	ItemInfo := Buffer(A_PtrSize == 8 ? 80 : 48, 0)
	NumPut("uint", ItemInfo.Size, "uint", MIIM_FTYPE, ItemInfo)
	loop Count {
		TypeRead := DllCall("GetMenuItemInfoW", "ptr", HMENU, "uint", A_Index - 1,
			"int", true, "ptr", ItemInfo, "int")
		Assert(TypeRead != 0, "the menu item type in '" . MenuName . "' must be acknowledged")
		IsSep := (NumGet(ItemInfo, 8, "uint") & MFT_SEPARATOR) != 0
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

; The bug as reported: layout_menu opens with its toggle, and a "---" closes that
; leading group. Rows may sit between them (the recommended restore does), but
; the group must still end in a declared separator, or the probe above no longer
; covers the reported case.
_MMNDS_LayoutMenuDeclaresToggleThenSeparator() {
	Def := _MR_GetMenuDef("layout_menu")
	Assert(Def.Length > 1, "layout_menu must be declared in the shared manifest")
	Assert(_MR_Get(Def[1], "type") == "toggle",
		"layout_menu must open with its toggle -- if that changed, "
		. "the probe above no longer covers the reported case")
	ClosingIndex := 0
	for Index, Item in Def {
		Type := _MR_Get(Item, "type")
		if (Type == "---") {
			ClosingIndex := Index
			break
		}
		Assert(Index == 1 or Type == "command",
			"layout_menu's leading group must hold only its toggle and commands before its '---', got '"
			. Type . "' at row " . Index)
	}
	Assert(ClosingIndex > 1,
		"layout_menu must close its toggle's group with '---' -- if that changed, "
		. "the probe above no longer covers the reported case")
}
Test("menu: layout_menu opens with a toggle group closed by '---' (layout-menu-double-separator)",
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

; A native submenu's high byte is a count, while real separator types must still
; expose every leading, trailing and doubled separator to the same walker.
_MMNDS_SubmenuCountDoesNotBecomeSeparator() {
	static MF_BYPOSITION := 0x400, MF_SEPARATOR := 0x800
	for ItemCount in [10, 11] {
		for Shape in ["only_submenu", "valid_separators", "leading", "trailing", "doubled"] {
			Child := Menu()
			loop ItemCount
				Child.Add("Choice " . A_Index, (*) => 0)
			Probe := Menu()
			if (Shape == "valid_separators" or Shape == "doubled") {
				Probe.Add("Before", (*) => 0)
				Probe.Add()
			}
			if (Shape == "leading" or Shape == "doubled")
				Probe.Add()
			Position := DllCall("GetMenuItemCount", "ptr", Probe.Handle, "int")
			Probe.Add("Choices", Child)
			if Shape == "valid_separators" {
				Probe.Add()
				Probe.Add("After", (*) => 0)
			} else if Shape == "trailing"
				Probe.Add()
			AssertEqual(ItemCount, DllCall("GetMenuItemCount", "ptr", Child.Handle, "int"),
				"the independent native child menu must contain the exact ten or eleven rows")
			AssertEqual(Child.Handle, DllCall("GetSubMenu", "ptr", Probe.Handle, "int", Position, "ptr"),
				"the packed state must belong to the actual child menu")
			Packed := DllCall("GetMenuState", "ptr", Probe.Handle, "uint", Position,
				"uint", MF_BYPOSITION, "uint")
			Assert(Packed != 0xFFFFFFFF, "the actual submenu must expose its packed native state")
			AssertEqual(ItemCount, (Packed >> 8) & 0xFF, "GetMenuState's high byte must be the native child count")
			Assert((Packed & MF_SEPARATOR) != 0, "ten and eleven children must reproduce the historical false separator bit")
			Defects := _MMNDS_Defects(Probe, "count-probe")
			if (Shape == "only_submenu" or Shape == "valid_separators")
				AssertEqual("", Defects, "a real submenu count must never become a misplaced separator")
			else if Shape == "leading"
				Assert(InStr(Defects, "separator at position 1;") > 0, "an actual leading separator must remain detectable")
			else if Shape == "trailing"
				Assert(InStr(Defects, "ends with a separator;") > 0, "an actual trailing separator must remain detectable")
			else
				Assert(InStr(Defects, "separator at position 3;") > 0, "an actual doubled separator must remain detectable")
		}
	}
}
Test("menu: native ten and eleven child counts preserve separator type checks (layout-menu-double-separator)",
	_MMNDS_SubmenuCountDoesNotBecomeSeparator)
