; static/ergopti_plus/windows/tests/unit/menu/test_manifest_menu_section_headers.ahk

; ==============================================================================
; MODULE: Manifest Menu Section Headers on Built Windows Menus
; DESCRIPTION:
; Renders every menu of the shared manifest through the real renderer and fails
; on a section header that titles nothing: one followed by a separator, by
; another header, or by the end of its menu. A header is recognised as the
; renderer draws it, a greyed row framed by the one shared format
; (_generated/menu_section_header.ahk), so a header framed by hand is not one.
; Driver rows become one plain probe row, the content a header titles; the
; fragments a driver splices into its own rows (include targets, templates with
; an inert label or ending with their header) are not rendered as roots. The Lua
; suites run the same check through test.menu_section_headers.
; ==============================================================================




; ===================================================
; ===================================================
; ======= 1/ Native header walk =====================
; ===================================================
; ===================================================

; Whether a native row is a section header drawn by the shared format.
_MMSH_IsHeader(Label, Greyed) {
	Prefix := MENU_SECTION_HEADER_PREFIX, Suffix := MENU_SECTION_HEADER_SUFFIX
	return Greyed && StrLen(Label) > StrLen(Prefix) + StrLen(Suffix)
		&& SubStr(Label, 1, StrLen(Prefix)) == Prefix && SubStr(Label, -StrLen(Suffix)) == Suffix
}

; The native rows of a menu: { label, separator, greyed }.
_MMSH_Rows(TargetMenu) {
	static MIIM_FTYPE := 0x100, MFT_SEPARATOR := 0x800
	Handle := TargetMenu.Handle
	ItemInfo := Buffer(A_PtrSize == 8 ? 80 : 48, 0)
	NumPut("uint", ItemInfo.Size, "uint", MIIM_FTYPE, ItemInfo)
	Rows := []
	loop TrayMenuItemCount(TargetMenu) {
		Assert(DllCall("GetMenuItemInfoW", "ptr", Handle, "uint", A_Index - 1, "int", true, "ptr", ItemInfo, "int") != 0,
			"the menu item type must be acknowledged")
		Rows.Push(Map("separator", (NumGet(ItemInfo, 8, "uint") & MFT_SEPARATOR) != 0,
			"label", TrayMenuHandleItemText(Handle, A_Index - 1),
			"greyed", (TrayMenuHandleItemState(Handle, A_Index - 1) & 3) != 0))
	}
	return Rows
}

; Returns every header of a built menu that titles nothing, as readable text.
_MMSH_Defects(Rows, MenuName) {
	Defects := ""
	for Index, Row in Rows {
		if Row["separator"] || !_MMSH_IsHeader(Row["label"], Row["greyed"])
			continue
		Cause := Index == Rows.Length ? "the end of the menu"
			: Rows[Index + 1]["separator"] ? "a separator"
			: _MMSH_IsHeader(Rows[Index + 1]["label"], Rows[Index + 1]["greyed"]) ? "another header" : ""
		if Cause != ""
			Defects .= MenuName . ": header '" . Row["label"] . "' is followed by " . Cause . "; "
	}
	return Defects
}




; ===================================================
; ===================================================
; ======= 2/ Every manifest menu ====================
; ===================================================
; ===================================================

; The menus only ever spliced into another: include targets, and templates that
; declare an inert label or end with their header on Windows.
_MMSH_Fragments(Root) {
	Fragments := Map()
	for Key, Value in Root {
		if !(Value is Array)
			continue
		Last := ""
		for Item in Value {
			if !(Item is Map)
				continue
			Type := _MR_Get(Item, "type")
			if Type == "include" && _MR_Get(Item, "section") != ""
				Fragments[Item["section"]] := true
			if Type == "label"
				Fragments[Key] := true
			if _MR_IsForAhk(Item) || _MR_Get(Item, "unavailable") == "grey"
				Last := Type
		}
		if Last == "section_header"
			Fragments[Key] := true
	}
	return Fragments
}

_MMSH_EveryHeaderTitlesRows() {
	static PROBE_KEY := "_test_section_header_probe_menu"
	Root := _MR_GetManifestRoot()
	Assert(Root is Map, "the shared menu manifest must load")
	Fragments := _MMSH_Fragments(Root)
	Counter := 0, Menus := 0, Headers := 0
	Defects := ""
	for Key in _MMNDS_MenuKeys(Root) {
		if Fragments.Has(Key)
			continue
		Probe := _MMNDS_ProbeDeclaration(Root[Key], &Counter)
		Handlers := Map(), Providers := Map(), Commands := Map()
		for Item in Probe {
			Id := _MR_Get(Item, "id")
			if Id == ""
				continue
			Label := "Probe " . Key . " " . Id
			Providers[Id] := ((L) => () => [Map("label", L)])(Label)
			Handlers[Id] := ((L) => (M, *) => M.Add(L, (*) => 0))(Label)
			Commands[_MR_Get(Item, "command") != "" ? _MR_Get(Item, "command") : Id] := (*) => 0
		}
		Root[PROBE_KEY] := Probe
		try {
			Rendered := MenuRenderer_Build(PROBE_KEY, "Layout", Handlers, "", Providers, Commands)
		} finally {
			Root.Delete(PROBE_KEY)
		}
		Rows := _MMSH_Rows(Rendered)
		for Row in Rows
			Headers += !Row["separator"] && _MMSH_IsHeader(Row["label"], Row["greyed"])
		Defects .= _MMSH_Defects(Rows, Key)
		Menus++
	}
	Assert(Menus > 10, "every renderer menu of the shared manifest must render, got " . Menus)
	Assert(Headers > 10, "the section headers must be drawn by the shared format, got " . Headers)
	Assert(Defects == "", "a section header must title real rows -- " . Defects)
}
Test("menu: every manifest section header titles real rows (section-header-titles-rows)",
	_MMSH_EveryHeaderTitlesRows)

; The walk itself: each misplaced header shape is reported, a titled one is not.
_MMSH_WalkReportsEachShape() {
	Title := MenuSectionTitle("Probe title")
	for Shape, Expected in Map("titled", "", "separator", "a separator", "header", "another header",
		"end", "the end of the menu") {
		Probe := Menu()
		Probe.Add(Title, (*) => 0)
		Probe.Disable(Title)
		if Shape == "titled"
			Probe.Add("Row", (*) => 0)
		else if Shape == "separator"
			Probe.Add(), Probe.Add("Row", (*) => 0)
		else if Shape == "header" {
			Second := MenuSectionTitle("Second title")
			Probe.Add(Second, (*) => 0)
			Probe.Disable(Second)
			Probe.Add("Row", (*) => 0)
		}
		Defects := _MMSH_Defects(_MMSH_Rows(Probe), "probe")
		if Expected == ""
			AssertEqual("", Defects, "a header over a real row is titled")
		else
			Assert(InStr(Defects, "followed by " . Expected) > 0, Shape . " must be reported, got: " . Defects)
	}
}
Test("menu: the header walk reports a separator, a header or the end after a header (section-header-titles-rows)",
	_MMSH_WalkReportsEachShape)
