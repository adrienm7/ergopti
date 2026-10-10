; static/ergopti_plus/windows/tests/unit/test_shortcuts_menu_blocks.ahk

; ==============================================================================
; MODULE: Shortcuts Menu Blocks And Tap Keys
; DESCRIPTION:
; Two reported defects of the Shortcuts submenu.
;
; 1. The rows acting on typed or selected text (wrap a selection, type a framed
;    symbol) ran straight into the user's Alt / Ctrl / Ctrl+Shift / Win groups
;    with no separator: the "---" between them was declared for Linux only.
; 2. The instant-screenshot row read « Capture d'ecran instantanee » without
;    naming its key. The key left of 1 is one of three tap keys now, each row
;    named by the character the key types under the layout in use.
; ==============================================================================

_SMB_SeparatorBeforeModifierGroups() {
	Def := _MR_GetMenuDef("shortcuts_menu")
	Index := 0
	for Position, Item in Def {
		if (_MR_Get(Item, "id") == "keyboard_slots") {
			Index := Position
		}
	}
	Assert(Index > 1, "shortcuts_menu must declare the keyboard_slots list")
	Before := Def[Index - 1]
	Assert(_MR_Get(Before, "type") == "---",
		"a '---' must separate the text rows from the modifier shortcut groups")
	Assert(!Before.Has("platforms"),
		"that separator must apply on every platform, not on Linux only")
}
Test("personal DATA frame: real native factory admission, hostile metadata refusal and exact repair",
	_SMB_FrameNativeConstructorRefusal)

Test("shortcuts menu: a separator splits text rows from modifier groups (shortcuts-menu-blocks)",
	_SMB_SeparatorBeforeModifierGroups)

; The key left of 1 used to be one fixed row, "instant screenshot", labelled by
; a legend written for two layouts. It is one of three tap keys now: the
; manifest lists them, and the provider names each by what it types (see
; unit/test_tap_keys.ahk for the labels themselves).
_SMB_TapKeysReplaceTheScreenshotRow() {
	Assert(!(ManifestFindEntryByPath("shortcuts.screen_instant") is Map),
		"the fixed instant-screenshot feature must be gone: the key is a tap key")
	for _, Id in ["number_row_left", "number_row_right_1", "number_row_right_2"] {
		Entry := ManifestFindEntryByPath("shortcuts.tap_keys." . Id)
		Assert(Entry is Map, "shortcuts.tap_keys." . Id . " must be declared in the features manifest")
		Assert(Entry["type"] == "action", "a tap key holds an action")
	}
	Def := _MR_GetMenuDef("shortcuts_menu")
	Found := false
	for _, Row in Def {
		if (_MR_Get(Row, "type") == "list" && _MR_Get(Row, "id") == "tap_keys")
			Found := true
	}
	Assert(Found, "the shortcuts menu must list the tap keys through a provider")
}
Test("shortcuts menu: the tap keys replace the fixed screenshot row (shortcuts-menu-blocks)",
	_SMB_TapKeysReplaceTheScreenshotRow)


/** Exercises the real extension allocator, physical scan and native fallback submenu. */
_SMB_ExtensionBoundary() {
	global _ExtensionsDir, _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\shortcut_extension_boundary.json", "UTF-8"))
	Root := A_Temp . "\ergopti-shortcut-boundary-" . DllCall("GetCurrentProcessId") . "-" . A_TickCount
	Saved := _ExtensionsDir
	Definition := _MM_GetManifestRoot()
	Frame := _MR_GetMenuDef(Corpus["section"])
	Heading := Frame[2]
	Native := 0, Submenus := [], Released := Map()
	ReadRows() {
		Rows := _SC_ExtensionRows()
		for Row in Rows {
			if Row.Has("submenu")
				Submenus.Push(Row["submenu"])
		}
		return Rows
	}
	try {
		_ExtensionsDir := Root
		DirCreate(Root)
		AssertEqual(0, ReadRows().Length, "an empty real source has no presentation boundary")
		DirCreate(Root . "\boundary-missing-builder\shortcuts")
		FileAppend("; This physical source intentionally has no compiled extension builder.`n",
			Root . "\boundary-missing-builder\shortcuts\menu.ahk", "UTF-8")
		FileAppend('name = "Boundary fixture"`n', Root . "\boundary-missing-builder\manifest.toml", "UTF-8")
		Rows := ReadRows()
		AssertEqual(3, Rows.Length)
		AssertTrue(Rows[1]["separator"])
		AssertEqual(MenuSectionTitle(t(Corpus["caption_key"])), Rows[2]["label"])
		AssertTrue(Rows[2]["disabled"])
		AssertFalse(Rows[2].Has("action"))
		AssertEqual("Boundary fixture", Rows[3]["label"])
		AssertEqual(1, DllCall("GetMenuItemCount", "ptr", Rows[3]["submenu"].Handle, "int"))
		AssertEqual(t("menu.extensions.empty"), _CTC_LabelAt(Rows[3]["submenu"], 0))
		Native := Menu()
		MenuRenderer_AppendRows(Native, "shortcuts_menu", "extensions_shortcuts", Rows)
		AssertEqual(3, DllCall("GetMenuItemCount", "ptr", Native.Handle, "int"))
		Flags := DllCall("GetMenuState", "ptr", Native.Handle, "uint", 0, "uint", 0x400, "uint")
		Assert(Flags != 0xFFFFFFFF && (Flags & 0x800) != 0, "the native boundary starts with a separator")
		Frame[2] := Map("type", "section_header", "id", Corpus["heading_id"], "i18n", Corpus["published_marker_key"],
			"platforms", Heading["platforms"], "unavailable", "hide")
		Rows := ReadRows()
		AssertEqual(MenuSectionTitle(t(Corpus["published_marker_key"])), Rows[2]["label"],
			"the actual native provider consumes its current declared heading")
		AssertTrue(Rows[2]["disabled"])
		AssertEqual("Boundary fixture", Rows[3]["label"])
		Definition.Delete(Corpus["section"])
		AssertEqual(0, ReadRows().Length, "a withdrawn boundary has no native fallback")
		Definition[Corpus["section"]] := [Map("type", "command", "id", "unowned_extension_boundary", "i18n", Corpus["caption_key"])]
		AssertEqual(0, ReadRows().Length, "an unbound command cannot become a heading")
		Definition[Corpus["section"]] := Frame
		Frame[2] := Heading
		Rows := ReadRows()
		AssertEqual(3, Rows.Length, "repair retains the same real source allocator")
		AssertEqual(MenuSectionTitle(t(Corpus["caption_key"])), Rows[2]["label"])
		AssertEqual("Boundary fixture", Rows[3]["label"])
		Assert(FileExist(Root . "\boundary-missing-builder\shortcuts\menu.ahk"), "presentation preserves the source")
	} finally {
		Definition[Corpus["section"]] := Frame
		Frame[2] := Heading
		_ExtensionsDir := Saved
		if Native is Menu
			_CTC_ReleaseMenu(Native, Released)
		for Submenu in Submenus
			_CTC_ReleaseMenu(Submenu, Released)
		if DirExist(Root)
			DirDelete(Root, true)
	}
}
Test("shortcut extension boundary: authentic allocator and native submenu (extension-boundary)", _SMB_ExtensionBoundary)


/** Exercises the real personal registry and native submenu through its shared frame. */
_SMB_PersonalShortcutFrame() {
	global _PersonalShortcutsRegistry, Features, CategoryEnabled, _SharedDir
	global _MenuPopulationBuilding, _MenuPopulationPublished, _MenuDispatchCallbacks
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\personal_shortcuts_frame.json", "UTF-8"))
	SavedRegistry := IsSet(_PersonalShortcutsRegistry) ? _PersonalShortcutsRegistry : unset
	SavedFeatures := Features, SavedCategories := CategoryEnabled
	State := MasterGateState(), SavedState := State.Clone()
	SavedBuilding := _MenuPopulationBuilding, SavedPublished := _MenuPopulationPublished
	Definition := _MM_GetManifestRoot(), Frame := _MR_GetMenuDef(Corpus["section"])
	Heading := Frame[2]
	Native := Menu()
	try {
		_MenuPopulationBuilding := false, _MenuPopulationPublished := false
		State["initialized"] := false
		Features := Map("shortcuts", Map("personal", Map()))
		CategoryEnabled := Map("Shortcuts", true)
		_PersonalShortcutsRegistry := Map()
		_SMB_AppendPersonalFrameData(Native)
		AssertEqual(Corpus["absent_registry_count"], _MenuItemCount(Native))
		_PersonalShortcutsRegistry := Map("__Order", [])
		_SMB_AppendPersonalFrameData(Native)
		AssertEqual(Corpus["empty_registry_count"], _MenuItemCount(Native))
		RegisterPersonalFeature(Corpus["registered_names"][1], true, Corpus["registered_labels"][1])
		RegisterPersonalFeature(Corpus["registered_names"][2], true)
		AssertEqual(false, Features["shortcuts"]["personal"][Corpus["registered_names"][1]])
		AssertEqual(false, Features["shortcuts"]["personal"][Corpus["registered_names"][2]])
		_SMB_AppendPersonalFrameData(Native)
		AssertEqual(Corpus["populated_frame_count"], _MenuItemCount(Native))
		AssertTrue(TrayMenuIsSeparatorAt(Native, 0))
		AssertEqual(t(Heading["i18n"]), _MP_ReadLabel(Native, 1))
		ChildHandle := DllCall("GetSubMenu", "ptr", Native.Handle, "int", 1, "ptr")
		Assert(ChildHandle != 0, "the registered rows remain an actual submenu")
		AssertEqual(2, DllCall("GetMenuItemCount", "ptr", ChildHandle, "int"))
		for Index, ExpectedLabel in Corpus["registered_labels"] {
			Text := Buffer(512, 0)
			DllCall("GetMenuStringW", "ptr", ChildHandle, "uint", Index - 1, "ptr", Text,
				"int", 256, "uint", 0x400)
			AssertEqual(ExpectedLabel, StrGet(Text, "UTF-16"))
			CommandId := DllCall("GetMenuItemID", "ptr", ChildHandle, "int", Index - 1, "uint")
			Assert(_MenuDispatchCallbacks.Has(CommandId), "every real switch retains a dispatch callback")
		}
		_CTC_ReleaseMenu(Native)
		Native := Menu()
		Frame[2] := Map("type", "group", "id", Heading["id"], "i18n", Corpus["marker_key"],
			"platforms", Heading["platforms"], "unavailable", "hide")
		_SMB_AppendPersonalFrameData(Native)
		AssertEqual(t(Corpus["marker_key"]), _MP_ReadLabel(Native, 1),
			"the actual provider consumes the current shared caption")
		_CTC_ReleaseMenu(Native)
		Native := Menu()
		Definition.Delete(Corpus["section"])
		_SMB_AppendPersonalFrameData(Native)
		AssertEqual(0, _MenuItemCount(Native), "a missing frame cannot synthesize native fixed rows")
		Definition[Corpus["section"]] := [Map("type", "command", "id", Heading["id"], "i18n", Heading["i18n"])]
		_SMB_AppendPersonalFrameData(Native)
		AssertEqual(0, _MenuItemCount(Native), "an unbound command cannot become a child group")
		Definition[Corpus["section"]] := Frame
		Frame[2] := Heading
		_SMB_AppendPersonalFrameData(Native)
		AssertEqual(Corpus["populated_frame_count"], _MenuItemCount(Native), "repair keeps the real registry")
		AssertEqual(t(Heading["i18n"]), _MP_ReadLabel(Native, 1))
		AssertEqual(2, _PersonalShortcutsRegistry["__Order"].Length)
	} finally {
		Definition[Corpus["section"]] := Frame
		Frame[2] := Heading
		_CTC_ReleaseMenu(Native)
		_PersonalShortcutsRegistry := IsSet(SavedRegistry) ? SavedRegistry : unset
		Features := SavedFeatures, CategoryEnabled := SavedCategories
		State.Clear()
		for Key, Value in SavedState
			State[Key] := Value
		_MenuPopulationBuilding := SavedBuilding, _MenuPopulationPublished := SavedPublished
	}
}
Test("personal shortcut frame: real registration, shared caption and refusal repair", _SMB_PersonalShortcutFrame)

/** Keeps actual child callbacks and a valid empty group when projecting the fixed frame. */
_SMB_PersonalShortcutFrameChildren() {
	Children := [], Callback := (*) => true
	Rows := MenuRenderer_TemplateRows("personal_shortcuts_frame", Map(), Map(),
		Map("personal_shortcuts_registered", Children))
	AssertEqual(2, Rows.Length)
	Assert(ObjPtr(Children) == ObjPtr(Rows[2]["items"]), "empty data is the existing actual child array")
	Children.Push(Map("label", "Child callback", "action", Callback, "checked", true))
	Rows := MenuRenderer_TemplateRows("personal_shortcuts_frame", Map(), Map(),
		Map("personal_shortcuts_registered", Children))
	Assert(ObjPtr(Callback) == ObjPtr(Rows[2]["items"][1]["action"]))
	AssertTrue(Rows[2]["items"][1]["checked"])
	AssertFalse(MenuRenderer_TemplateRows("personal_shortcuts_frame", Map(), Map(), Map()))
}
Test("personal shortcut frame: original child identity, callbacks and empty array", _SMB_PersonalShortcutFrameChildren)

_SMB_WrapFrameUsesCurrentDeclaration() {
	Root := _MR_GetManifestRoot()
	Original := Root["shortcut_wrap_frame"]
	try {
		Current := _SC_WrapSymbolRows()
		AssertEqual(1, Current.Length)
		AssertEqual(t("menu.shortcuts.wrap_symbols_title"), Current[1]["label"])
		Assert(Current[1]["items"] is Array && Current[1]["items"].Length > 0,
			"the actual canonical wrap catalogue and controls remain reachable")
		Root.Delete("shortcut_wrap_frame")
		AssertEqual(0, _SC_WrapSymbolRows().Length, "no undeclared fixed parent is fabricated")
		Root["shortcut_wrap_frame"] := Original
		AssertEqual(1, _SC_WrapSymbolRows().Length, "the actual repaired source restores the parent")
	} finally {
		Root["shortcut_wrap_frame"] := Original
	}
}
Test("shortcut wrap frame: actual native children, current declaration withdrawal and repair", _SMB_WrapFrameUsesCurrentDeclaration)

/** Native late declaration refusal keeps borrowed children and primary failure. */
_SMB_ExtensionMarkerLifetime(CleanupRefuses := false) {
	global _ExtensionsDir, _MenuDispatchCallbacks
	global _SMB_MarkerBuildCalls, _SMB_MarkerMenus, _SMB_MarkerBorrowed, _SMB_MarkerCleanupRefuses
	Root := A_Temp . "\ergopti-shortcut-marker-" . DllCall("GetCurrentProcessId") . "-" . A_TickCount
	SavedDir := _ExtensionsDir
	SavedCalls := IsSet(_SMB_MarkerBuildCalls) ? _SMB_MarkerBuildCalls : unset
	SavedMenus := IsSet(_SMB_MarkerMenus) ? _SMB_MarkerMenus : unset
	SavedBorrowed := IsSet(_SMB_MarkerBorrowed) ? _SMB_MarkerBorrowed : unset
	SavedCleanup := IsSet(_SMB_MarkerCleanupRefuses) ? _SMB_MarkerCleanupRefuses : unset
	Definition := _MM_GetManifestRoot()
	ErrorFrame := _MR_GetMenuDef("shortcut_extension_error_frame")
	EmptyFrame := _MR_GetMenuDef("shortcut_extension_empty_frame")
	Borrowed := Menu(), Menus := [], Failure := "", ResultReturned := false
	try {
		_ExtensionsDir := Root
		_SMB_MarkerBuildCalls := 0, _SMB_MarkerMenus := Menus
		_SMB_MarkerBorrowed := Borrowed, _SMB_MarkerCleanupRefuses := CleanupRefuses
		DirCreate(Root . "\g1-shortcut-marker\shortcuts")
		FileAppend("; Uses the real compiled BuildExtMenu_g1_shortcut_marker below.`n",
			Root . "\g1-shortcut-marker\shortcuts\menu.ahk", "UTF-8")
		RegisterMenuItem(Borrowed, "Borrowed native callback", _SMB_MarkerBorrowedCallback)
		BorrowedId := DllCall("GetMenuItemID", "ptr", Borrowed.Handle, "int", 0, "uint")
		BorrowedCallback := _MenuDispatchCallbacks[BorrowedId]
		Definition.Delete("shortcut_extension_empty_frame")
		AssertEqual(0, _SC_ExtensionRows().Length, "missing complete marker refuses before native allocation or builder")
		AssertEqual(0, _SMB_MarkerBuildCalls)
		AssertEqual(0, Menus.Length)
		Definition["shortcut_extension_empty_frame"] := EmptyFrame
		try {
			_SC_ExtensionRows()
			ResultReturned := true
		} catch as Err {
			Failure := Err.Message
		}
		AssertFalse(ResultReturned, "late refusal must not publish a partial extension list")
		AssertEqual("Shortcut extension error marker was withdrawn during its native builder", Failure,
			"cleanup failure must preserve the actual primary declaration refusal")
		AssertEqual(1, _SMB_MarkerBuildCalls, "actual physical source invokes the genuine compiled builder once")
		AssertEqual(1, Menus.Length)
		AssertEqual(CleanupRefuses ? 1 : 0, _ExtMenuItemCount(Menus[1]),
			"only the explicitly allocated owner is deleted; a forced cleanup failure remains observable")
		AssertEqual(1, _ExtMenuItemCount(Borrowed), "borrowed child remains intact")
		AssertTrue(_MenuDispatchCallbacks.Has(BorrowedId))
		Assert(_MenuDispatchCallbacks[BorrowedId] == BorrowedCallback, "borrowed native callback identity remains exact")
	} finally {
		Definition["shortcut_extension_error_frame"] := ErrorFrame
		Definition["shortcut_extension_empty_frame"] := EmptyFrame
		_ExtensionsDir := SavedDir
		_SMB_MarkerBuildCalls := IsSet(SavedCalls) ? SavedCalls : unset
		_SMB_MarkerMenus := IsSet(SavedMenus) ? SavedMenus : unset
		_SMB_MarkerBorrowed := IsSet(SavedBorrowed) ? SavedBorrowed : unset
		_SMB_MarkerCleanupRefuses := IsSet(SavedCleanup) ? SavedCleanup : unset
		for Owned in Menus {
			if Owned.HasOwnProp("Delete")
				Owned.DeleteProp("Delete")
			try Owned.Delete()
			finally MenuDispatcher_PruneMenu(Owned)
		}
		_CTC_ReleaseMenu(Borrowed)
		if DirExist(Root)
			DirDelete(Root, true)
	}
}

BuildExtMenu_g1_shortcut_marker(ExtMenu, ExtName) {
	global _SMB_MarkerBuildCalls, _SMB_MarkerMenus, _SMB_MarkerBorrowed, _SMB_MarkerCleanupRefuses
	_SMB_MarkerBuildCalls += 1
	_SMB_MarkerMenus.Push(ExtMenu)
	ExtMenu.Add("Borrowed child", _SMB_MarkerBorrowed)
	if _SMB_MarkerCleanupRefuses
		ExtMenu.DefineProp("Delete", {Call: _SMB_MarkerDeleteRefuses})
	_MM_GetManifestRoot().Delete("shortcut_extension_error_frame")
	throw Error("The real fixture builder fails after attaching a borrowed child")
}

_SMB_MarkerDeleteRefuses(OwnedMenu, *) {
	throw Error("The real owned native menu cleanup refuses")
}
_SMB_MarkerBorrowedCallback(*) => 7

Test("shortcut extension frame: genuine late refusal preserves borrowed native menus", (*) => _SMB_ExtensionMarkerLifetime())
Test("shortcut extension frame: genuine cleanup failure preserves primary refusal", (*) => _SMB_ExtensionMarkerLifetime(true))

; The registry subject uses the same genuine provider/frame binding as Build.
_SMB_AppendPersonalFrameData(Native) {
	return MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts",
		Map("manifest_key", "personal_shortcuts_frame", "children_id", "personal_shortcuts_registered",
			"provider", _PersonalShortcutRows))
}

; Genuine canonical frame, real native destination, and pure registered DATA ports.
_SMB_FrameDataRetainedControls() {
	Root := _MR_GetManifestRoot(), Definition := _MR_GetMenuDef("shortcuts_menu")
	Frame := _MR_GetMenuDef("personal_shortcuts_frame"), Selected := false
	for Item in Definition
		if Item.Get("id", "") == "personal_shortcuts"
			Selected := Item
	Calls := Map("provider", 0, "foreign", 0, "actions", 0)
	Action := (*) => Calls["actions"] += 1
	Data := [Map("label", "Retained DATA child", "action", Action, "checked", true)]
	Native := Menu(), Child := false
	Binding := Map("manifest_key", "personal_shortcuts_frame", "children_id", "personal_shortcuts_registered")
	SavedType := Selected["type"]
	try {
		RegisterMenuItem(Native, "Existing retained destination", Action)
		Original := _MR_FrameDestinationSnapshot(Native)
		Binding["provider"] := () => _SMB_FrameWithdrawBeforeData(Calls, Selected, Data)
		AssertEqual(0, MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts", Binding, , , &Admitted))
		AssertFalse(Admitted, "withdrawn owning list cannot be accepted as DATA")
		AssertEqual(1, Calls["provider"])
		AssertTrue(_MR_FrameNativeImageEqual(Original, _MR_FrameDestinationSnapshot(Native)),
			"source refusal adds no destination separator or partial parent")
		Selected["type"] := SavedType
		Provider := () => Data
		Binding["provider"] := Provider
		Provider.DefineProp("Call", {Call: (*) => Calls["foreign"] += 1})
		try {
			AssertEqual(0, MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts", Binding))
			AssertEqual(0, Calls["foreign"], "same-object provider Call is refused before invocation")
		} finally Provider.DeleteProp("Call")
		Binding["provider"] := () => [Data[1], false]
		AssertEqual(0, MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts", Binding))
		AssertTrue(_MR_FrameNativeImageEqual(Original, _MR_FrameDestinationSnapshot(Native)),
			"a later malformed child never publishes the earlier real callback")
		Named := [Data[1]]
		Named.DefineProp("Length", {Get: (*) => Calls["foreign"] += 1})
		Binding["provider"] := () => Named
		AssertEqual(0, MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts", Binding))
		AssertEqual(0, Calls["foreign"], "foreign Array readers cannot receive observer credit")
		Named.DeleteProp("Length")
		Action.DefineProp("Call", {Call: (*) => Calls["foreign"] += 1})
		try {
			Binding["provider"] := () => Data
			AssertEqual(0, MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts", Binding))
			AssertEqual(0, Calls["foreign"], "DATA callbacks retain intrinsic Call custody")
		} finally Action.DeleteProp("Call")
		Binding["provider"] := () => false
		AssertEqual(0, MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts", Binding, , , &Admitted))
		AssertTrue(Admitted, "a current absent registry is a deliberate skip")
		AssertTrue(_MR_FrameNativeImageEqual(Original, _MR_FrameDestinationSnapshot(Native)))
		Binding["provider"] := () => []
		AssertEqual(1, MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts", Binding, , , &Admitted))
		AssertTrue(Admitted, "present empty DATA retains its declared group")
		AssertEqual(3, TrayMenuItemCount(Native))
		AssertTrue(TrayMenuIsSeparatorAt(Native, 1))
		Child := MenuFromHandle(TrayMenuSubmenuHandle(Native.Handle, 2))
		AssertEqual(0, TrayMenuItemCount(Child))
		_CTC_ReleaseMenu(Native)
		Native := Menu(), Child := false
		Binding["provider"] := () => Data
		AssertEqual(1, MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts", Binding))
		AssertTrue(TrayMenuIsSeparatorAt(Native, 0))
		Child := MenuFromHandle(TrayMenuSubmenuHandle(Native.Handle, 1))
		ChildId := DllCall("GetMenuItemID", "ptr", Child.Handle, "int", 0, "uint")
		global _MenuDispatchCallbacks
		Assert(_MenuDispatchCallbacks.Has(ChildId) && _MenuDispatchCallbacks[ChildId] == Action,
			"native staging retains the exact supplied real callback")
		AssertEqual(0, Calls["actions"], "collect/admit/stage/publish never executes the child")
		_MenuDispatchCallbacks[ChildId].Call()
		AssertEqual(1, Calls["actions"])
	} finally {
		Selected["type"] := SavedType
		Root["personal_shortcuts_frame"] := Frame
		if Object.Prototype.HasOwnProp.Call(Action, "Call")
			Action.DeleteProp("Call")
		_CTC_ReleaseMenu(Native)
	}
}

_SMB_FrameWithdrawBeforeData(Calls, Selected, Data) {
	Calls["provider"] += 1
	Selected["type"] := "dynamic"
	return Data
}
Test("personal DATA frame: retained source, pure provider, whole admission and empty distinction", _SMB_FrameDataRetainedControls)

; The original population owner retains its seeded leaf and exact pending remainder.
_SMB_FrameDataPopulationControls() {
	global _MenuPopulationBuilding, _MenuDispatchCallbacks, _MenuDispatchOwnerHandles
	Previous := _MenuPopulationBuilding
	Owner := MenuPopulation(), Native := Menu(), Foreign := Menu(), Child := false
	Calls := Map("actions", 0)
	Callback := (*) => Calls["actions"] += 1
	Data := [Map("label", "Seeded original child", "action", Callback),
		Map("label", "Original pending child", "action", Callback)]
	try {
		_MenuPopulationBuilding := Owner
		Owner.Fill(Foreign, Data, "personal_shortcuts_frame", 2)
		ForeignEntry := Owner.Pending[Foreign.Handle]
		Binding := Map("manifest_key", "personal_shortcuts_frame", "children_id", "personal_shortcuts_registered",
			"provider", () => Data)
		AssertEqual(1, MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts", Binding))
		Child := MenuFromHandle(TrayMenuSubmenuHandle(Native.Handle, 1))
		AssertEqual(1, TrayMenuItemCount(Child), "the existing first-row seed remains native")
		Assert(Owner.Pending.Has(Child.Handle), "remaining actual choices stay build-local")
		Assert(Owner.Pending[Child.Handle].MenuObj == Child)
		Assert(Owner.Pending[Foreign.Handle] == ForeignEntry, "a previous detached picker is not reset")
		AssertEqual(0, Calls["actions"])
		AssertTrue(Owner.Complete(Child.Handle))
		AssertEqual(2, TrayMenuItemCount(Child))
		AssertFalse(Owner.Pending.Has(Child.Handle))
		Assert(Owner.Pending[Foreign.Handle] == ForeignEntry)
		for Position in [0, 1] {
			Id := DllCall("GetMenuItemID", "ptr", Child.Handle, "int", Position, "uint")
			Assert(_MenuDispatchCallbacks.Has(Id) && _MenuDispatchCallbacks[Id] == Callback)
		}
	} finally {
		Owner.Stop()
		Owner.Pending.Clear()
		_MenuPopulationBuilding := Previous
		_CTC_ReleaseMenu(Native)
		_CTC_ReleaseMenu(Foreign)
	}
}
Test("personal DATA frame: original seeded population and previous pending owner retained", _SMB_FrameDataPopulationControls)

; Bind the current case while preserving the actual Func provider contract.
_SMB_FrameBindCaseObserver(Observer, Value) {
	BoundObserver := Observer.Bind(Value)
	return (Args*) => BoundObserver.Call(Args*)
}

; Registration changes remain subject to the same held Build receipts during collection.
_SMB_FrameDataRegistrationLifecycle() {
	for Mutation in ["frame", "handler", "provider"] {
		Native := Menu(), Calls := Map("collect", 0, "foreign", 0)
		Action := (*) => Calls["foreign"] += 1
		Data := [Map("label", "Registered DATA", "action", Action)]
		Binding := Map("manifest_key", "personal_shortcuts_frame", "children_id", "personal_shortcuts_registered")
		Frames := Map("personal_shortcuts", Binding), Handlers := Map(), Providers := Map()
		Collect(CurrentMutation) {
			Calls["collect"] += 1
			if CurrentMutation == "frame"
				Frames.Delete("personal_shortcuts")
			else if CurrentMutation == "handler"
				Handlers["personal_shortcuts"] := Action
			else
				Providers["personal_shortcuts"] := Action
			return Data
		}
		Binding["provider"] := _SMB_FrameBindCaseObserver(Collect, Mutation)
		Receipts := [_MR_ReasonedGroupSnapshot(Frames), _MR_ReasonedGroupSnapshot(Handlers),
			_MR_ReasonedGroupSnapshot(Providers)]
		try {
			RegisterMenuItem(Native, "Previous DATA destination", Action)
			Before := _MR_FrameDestinationSnapshot(Native)
			AssertEqual(0, MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts",
				Binding, , , &Admitted, Receipts), Mutation . " withdrawal refuses collected DATA")
			AssertFalse(Admitted)
			AssertEqual(1, Calls["collect"])
			AssertEqual(0, Calls["foreign"], "competing registrations never execute")
			AssertTrue(_MR_FrameNativeImageEqual(Before, _MR_FrameDestinationSnapshot(Native)),
				"registration change adds neither deferred separator nor destination group")
			Frames["personal_shortcuts"] := Binding, Handlers.Clear(), Providers.Clear()
			Binding["provider"] := () => Data
			Receipts := [_MR_ReasonedGroupSnapshot(Frames), _MR_ReasonedGroupSnapshot(Handlers),
				_MR_ReasonedGroupSnapshot(Providers)]
			AssertEqual(1, MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts",
				Binding, , , &Admitted, Receipts), "fresh actual registration repairs the same destination")
			AssertTrue(Admitted)
		} finally _CTC_ReleaseMenu(Native)
	}
}
Test("personal DATA frame: Build registration custody survives collection and repairs", _SMB_FrameDataRegistrationLifecycle)

; Each observer forwards the original population Fill BEFORE changing a held owner.
; The strict receiver therefore has a real seeded native leaf and actual pending remainder.
_SMB_FrameDataLateStageLifecycle() {
	global _MenuPopulationBuilding, _MenuDispatchCallbacks, _MenuDispatchOwnerHandles
	Previous := _MenuPopulationBuilding
	FillDesc := Object.Prototype.GetOwnPropDesc.Call(MenuPopulation.Prototype, "Fill")
	OriginalFill := FillDesc.Call
	Root := _MR_GetManifestRoot(), Frame := _MR_GetMenuDef("personal_shortcuts_frame")
	for Mutation in ["declaration", "callback", "registration", "registry", "caption_case", "pending_method", "child_method", "child_handle", "primary_error"] {
		Owner := MenuPopulation(), Native := Menu(), Foreign := Menu()
		Calls := Map("action", 0, "observer", 0), Stage := Map()
		HeldCallbacks := _MenuDispatchCallbacks
		Callback := (*) => Calls["action"] += 1
		Rows := [Map("label", "Owned seed", "action", Callback),
			Map("label", "Owned remainder", "action", Callback)]
		Binding := Map("manifest_key", "personal_shortcuts_frame", "children_id", "personal_shortcuts_registered",
			"provider", () => Rows)
		Frames := Map("personal_shortcuts", Binding), Handlers := Map(), Providers := Map()
		Primary := Error("Actual post-Fill failure")
		Primary.DefineProp("Extra", {Get: (*) => _SMB_FrameForbiddenExtraRead(),
			Set: (*) => _SMB_FrameForbiddenExtraRead()})
		ObserveFill(CurrentMutation, Population, Child, Data, ListId, Depth) {
			Result := OriginalFill.Call(Population, Child, Data, ListId, Depth)
			Calls["observer"] += 1
			Stage["child"] := Child, Stage["handle"] := Child.Handle
			Stage["command"] := DllCall("GetMenuItemID", "ptr", Child.Handle, "int", 0, "uint")
			Stage["entry"] := Population.Pending[Child.Handle]
			if CurrentMutation == "declaration"
				Root.Delete("personal_shortcuts_frame")
			else if CurrentMutation == "callback"
				Callback.DefineProp("Call", {Call: (*) => Calls["action"] += 1})
			else if CurrentMutation == "registration"
				Handlers["personal_shortcuts"] := Callback
			else if CurrentMutation == "registry"
				_MenuDispatchCallbacks := Map(ForeignId, Callback)
			else if CurrentMutation == "caption_case"
				Child.Rename("Owned seed", "owned seed")
			else if CurrentMutation == "pending_method"
				Foreign.DefineProp("Add", {Call: (*) => Calls["action"] += 1})
			else if CurrentMutation == "child_method"
				Child.DefineProp("Add", {Call: (*) => Calls["action"] += 1})
			else if CurrentMutation == "child_handle"
				Child.DefineProp("Handle", {Get: (*) => Calls["action"] += 1})
			else
				throw Primary
			return Result
		}
		TeardownPrimary := false
		try {
			_MenuPopulationBuilding := Owner
			OriginalFill.Call(Owner, Foreign, Rows, "personal_shortcuts_frame", 2)
			ForeignEntry := Owner.Pending[Foreign.Handle]
			ForeignId := DllCall("GetMenuItemID", "ptr", Foreign.Handle, "int", 0, "uint")
			RegisterMenuItem(Native, "Previous native DATA target", Callback)
			Before := _MR_FrameDestinationSnapshot(Native)
			MenuPopulation.Prototype.DefineProp("Fill", {Call: _SMB_FrameBindCaseObserver(ObserveFill, Mutation)})
			Receipts := [_MR_ReasonedGroupSnapshot(Frames), _MR_ReasonedGroupSnapshot(Handlers),
				_MR_ReasonedGroupSnapshot(Providers)]
			Caught := false
			try Added := MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts",
				Binding, , , &Admitted, Receipts)
			catch as Failure
				Caught := Failure
			if Mutation == "primary_error"
				Assert(Caught == Primary, "cleanup rethrows the actual provider/staging failure object")
			else {
				AssertFalse(Caught, "current owner withdrawal is a refusal, not a foreign callback")
				AssertEqual(0, Added)
				AssertFalse(Admitted)
			}
			AssertEqual(1, Calls["observer"], "the actual native Fill completed before withdrawal")
			AssertEqual(0, Calls["action"], "staging/refusal never invokes real or replaced callbacks")
			if Mutation == "registry" {
				After := _MR_FrameDestinationSnapshot(Native)
				AssertEqual(Before.Length, After.Length)
				for Index, PreviousRow in Before {
					for Field in [1, 2, 3, 4]
						AssertEqual(PreviousRow[Field], After[Index][Field], "real native destination fields remain unchanged")
					Assert(HeldCallbacks.Get(PreviousRow[2], false) == PreviousRow[5], "original callback authority retains the destination")
					global _MenuDispatchTokens
					Assert(_MenuDispatchTokens.Get(PreviousRow[2], false) == PreviousRow[6])
				}
			} else
				AssertTrue(_MR_FrameNativeImageEqual(Before, _MR_FrameDestinationSnapshot(Native)))
			if Mutation == "child_handle"
				AssertEqual(0, TrayMenuHandleItemCount(Stage["handle"]), "actual owned native handle is retired without the foreign getter")
			else
				AssertEqual(0, TrayMenuItemCount(Stage["child"]), "owned unpublished native leaf is retired")
			AssertFalse(Owner.Pending.Has(Stage["handle"]), "only the exact staged pending entry is retired")
			AssertFalse(HeldCallbacks.Has(Stage["command"]), "exact original staged callback registry ownership is retired")
			if Mutation == "registry" {
				Assert(_MenuDispatchCallbacks != HeldCallbacks, "late replacement is a distinct foreign registry")
				AssertEqual(1, _MenuDispatchCallbacks.Count, "cleanup does not prune or write the foreign replacement")
				Assert(_MenuDispatchCallbacks.Has(ForeignId) && _MenuDispatchCallbacks[ForeignId] == Callback)
			}
			AssertFalse(_MenuDispatchOwnerHandles.Has(Stage["handle"]))
			Assert(Owner.Pending.Has(Foreign.Handle) && Owner.Pending[Foreign.Handle] == ForeignEntry,
				"previous detached picker entry retains its exact identity")
			Assert(_MenuDispatchCallbacks.Has(ForeignId) && _MenuDispatchCallbacks[ForeignId] == Callback)
			AssertEqual(1, TrayMenuItemCount(Foreign))
			Root["personal_shortcuts_frame"] := Frame
			if Object.Prototype.HasOwnProp.Call(Callback, "Call")
				Callback.DeleteProp("Call")
			Handlers.Clear()
			for Name in ["Handle", "Add"]
				if Object.Prototype.HasOwnProp.Call(Stage["child"], Name)
					Stage["child"].DeleteProp(Name)
			if Object.Prototype.HasOwnProp.Call(Foreign, "Add")
				Foreign.DeleteProp("Add")
			_MenuDispatchCallbacks := HeldCallbacks
			_SMB_FrameRestoreOwnDescriptor(MenuPopulation.Prototype, "Fill", true, FillDesc)
			_SMB_FrameAssertOwnDescriptor(MenuPopulation.Prototype, "Fill", true, FillDesc)
			Receipts := [_MR_ReasonedGroupSnapshot(Frames), _MR_ReasonedGroupSnapshot(Handlers),
				_MR_ReasonedGroupSnapshot(Providers)]
			AssertEqual(1, MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts",
				Binding, , , &Admitted, Receipts), "real native repair uses the original population owner")
			AssertTrue(Admitted)
		} catch as Failure {
			TeardownPrimary := Failure
			throw Failure
		} finally {
			_SMB_FrameRunAllCleanup(TeardownPrimary,
				() => _MenuDispatchCallbacks := HeldCallbacks,
				() => _SMB_FrameRestoreOwnDescriptor(MenuPopulation.Prototype, "Fill", true, FillDesc),
				() => Root["personal_shortcuts_frame"] := Frame,
				() => _SMB_FrameRestoreOwnDescriptor(Callback, "Call", false, false),
				() => Stage.Has("child") ? _SMB_FrameRestoreOwnDescriptor(Stage["child"], "Handle", false, false) : false,
				() => Stage.Has("child") ? _SMB_FrameRestoreOwnDescriptor(Stage["child"], "Add", false, false) : false,
				() => _SMB_FrameRestoreOwnDescriptor(Foreign, "Add", false, false),
				() => Owner.Stop(),
				() => _CTC_ReleaseMenu(Native),
				() => _CTC_ReleaseMenu(Foreign),
				() => Stage.Has("child") ? _CTC_ReleaseMenu(Stage["child"]) : false,
				() => Owner.Pending.Clear(),
				() => _MenuPopulationBuilding := Previous,
				() => _SMB_FrameAssertOwnDescriptor(MenuPopulation.Prototype, "Fill", true, FillDesc))
		}
	}
}
_SMB_FrameForbiddenExtraRead() {
	throw Error("Primary Extra diagnostics must remain best-effort")
}
Test("personal DATA frame: actual post-Fill withdrawal, owned cleanup and original exception", _SMB_FrameDataLateStageLifecycle)

; These controls fault the internal LIVE publication operation AFTER real native Add.
; They qualify its rollback semantics, not external DATA/source admission or OS origin.
_SMB_FrameNativePublicationFaults() {
	for Mode in ["separator", "new_parent", "replaced_parent", "rollback_reporting"] {
		Native := Menu(), Child := Menu(), PreviousChild := false
		Calls := Map("actions", 0, "faults", 0, "rollback_faults", 0)
		Callback := (*) => Calls["actions"] += 1
		FrameRows := MenuRenderer_TemplateRows("personal_shortcuts_frame", Map(), Map(),
			Map("personal_shortcuts_registered", []))
		Label := StrReplace(FrameRows[FrameRows.Length]["label"], "&", "&&")
		NativeMethods := Map()
		for Name in ["Add", "Delete", "Check", "Uncheck", "Enable", "Disable", "SetIcon"]
			NativeMethods[Name] := Object.Prototype.GetOwnPropDesc.Call(Menu.Prototype, Name).Call
		OriginalAdd := NativeMethods["Add"], OriginalDelete := NativeMethods["Delete"]
		Primary := Error("Injected failure after real native publication effect")
		Primary.DefineProp("Extra", {Get: (*) => _SMB_FrameForbiddenExtraRead(),
			Set: (*) => _SMB_FrameForbiddenExtraRead()})
		StartCount := 0
		ObservedAdd(CurrentMode, Target, Args*) {
			Result := OriginalAdd.Call(Target, Args*)
			if Calls["faults"] == 0 && ((CurrentMode == "separator" && Args.Length == 0)
				|| (CurrentMode != "separator" && Args.Length == 2 && Args[2] == Child)) {
				Calls["faults"] += 1
				throw Primary
			}
			return Result
		}
		ObservedDelete(CurrentMode, Target, Args*) {
			Result := OriginalDelete.Call(Target, Args*)
			if CurrentMode == "rollback_reporting" && TrayMenuItemCount(Target) == StartCount {
				Calls["rollback_faults"] += 1
				throw Error("Injected failure after real native rollback effect")
			}
			return Result
		}
		try {
			RegisterMenuItem(Native, "Original publication destination", Callback)
			if Mode == "replaced_parent" {
				PreviousChild := Menu()
				RegisterMenuItem(PreviousChild, "Previous child action", Callback)
				OriginalAdd.Call(Native, Label, PreviousChild)
				NativeMethods["Check"].Call(Native, Label)
				NativeMethods["Disable"].Call(Native, Label)
			}
			Before := _MR_FrameDestinationSnapshot(Native), StartCount := Before.Length, OldFlags := 0
			if PreviousChild
				OldFlags := Before[2][3]
			NativeMethods["Add"] := _SMB_FrameBindCaseObserver(ObservedAdd, Mode)
			NativeMethods["Delete"] := _SMB_FrameBindCaseObserver(ObservedDelete, Mode)
			Caught := false
			try _MR_FramePublish(Native, Child, FrameRows, Label, Before, NativeMethods,
				PreviousChild, OldFlags, () => true)
			catch as Failure
				Caught := Failure
			Assert(Caught == Primary, "native-effect and rollback-reporting faults preserve the primary object")
			AssertEqual(1, Calls["faults"], "the real native publication effect occurred before the fault")
			AssertEqual(Mode == "rollback_reporting" ? 1 : 0, Calls["rollback_faults"])
			AssertTrue(_MR_FrameNativeImageEqual(Before, _MR_FrameDestinationSnapshot(Native)),
				"actual suffix effects and replacement flags are fully restored")
			AssertEqual(0, Calls["actions"], "publication and repair never execute existing callbacks")
			if PreviousChild {
				AssertEqual(PreviousChild.Handle, TrayMenuSubmenuHandle(Native.Handle, 1))
				AssertEqual(1, TrayMenuItemCount(PreviousChild), "the previous actual child survives rollback")
			}
		} finally {
			_CTC_ReleaseMenu(Native)
			_CTC_ReleaseMenu(Child)
		}
	}
}
Test("personal DATA frame: real native publication effects, owned rollback and primary fault", _SMB_FrameNativePublicationFaults)

; The complete production Shortcuts builder uses the shipped declarations/providers.
; Expectations for this added frame come from the immutable original registry corpus.
_SMB_FrameProductionBuildSequence() {
	; The unit runner intentionally omits boot-owned feature_state globals.
	; Reuse the real script submenu fixture owner; its complete slots, labels,
	; assignments and switch are restored with their original presence.
	_SCSM_WithState(ManifestDefaultFor("shortcuts.script_control.chords_enabled"),
		_SMB_FrameProductionBuildSequenceWithBootState)
}

_SMB_FrameProductionBuildSequenceWithBootState() {
	global _PersonalShortcutsRegistry, Features, CategoryEnabled, _SharedDir
	global KeyboardShortcutAssignments
	global _MenuPopulationBuilding, _MenuPopulationPublished
	SavedRegistry := IsSet(_PersonalShortcutsRegistry) ? _PersonalShortcutsRegistry : unset, SavedFeatures := Features, SavedCategories := CategoryEnabled
	HadKeyboard := IsSet(KeyboardShortcutAssignments)
	SavedKeyboard := HadKeyboard ? KeyboardShortcutAssignments : false
	SavedBuilding := _MenuPopulationBuilding, SavedPublished := _MenuPopulationPublished
	State := MasterGateState(), SavedState := State.Clone()
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\personal_shortcuts_frame.json", "UTF-8"))
	Menus := [], Caption := StrReplace(t("menu.shortcuts.personal"), "&", "&&")
	try {
		Features := ManifestBuildFeaturesMap()
		Features["shortcuts"]["personal"] := Map()
		; Populate the actual native keyboard inventory from the same canonical
		; defaults as ReadKeyboardShortcutsConfig, keeping every real provider.
		KeyboardShortcutAssignments := Map()
		for Entry in ManifestFeaturesForSection("shortcuts.keyboard")
			KeyboardShortcutAssignments[Entry["id"]] := ManifestDefaultFor(Entry["path"])
		CategoryEnabled := SavedCategories.Clone(), CategoryEnabled["Shortcuts"] := true
		State["initialized"] := false
		_MenuPopulationBuilding := false, _MenuPopulationPublished := false
		_PersonalShortcutsRegistry := Map()
		Absent := _BuildShortcutsSubmenu(), Menus.Push(Absent)
		AssertEqual(-1, _SMB_FrameCaptionPosition(Absent, Caption))
		_PersonalShortcutsRegistry := Map("__Order", [])
		Empty := _BuildShortcutsSubmenu(), Menus.Push(Empty)
		AssertEqual(_SMB_FrameNativeCaptionSequence(Absent), _SMB_FrameNativeCaptionSequence(Empty),
			"an actual empty registry preserves the complete original Shortcuts sequence")
		RegisterPersonalFeature(Corpus["registered_names"][1], true, Corpus["registered_labels"][1])
		RegisterPersonalFeature(Corpus["registered_names"][2], true)
		Populated := _BuildShortcutsSubmenu(), Menus.Push(Populated)
		Position := _SMB_FrameCaptionPosition(Populated, Caption)
		Assert(Position >= 2, "the actual complete builder publishes its personal frame")
		AssertTrue(TrayMenuIsSeparatorAt(Populated, Position - 1))
		AssertEqual(StrReplace(t("menu.shortcuts.script_shortcuts"), "&", "&&"),
			TrayMenuItemCaption(Populated, Position - 2), "the original preceding management group retains its order")
		AssertEqual(StrReplace(t("menu.global.edit_shortcuts"), "&", "&&"),
			TrayMenuItemCaption(Populated, Position + 1), "the original following editor retains its order")
		AssertEqual(_SMB_FrameNativeCaptionSequence(Absent),
			_SMB_FrameNativeCaptionSequence(Populated, Position - 1, Position),
			"every unrelated actual provider remains in the same sequence")
		Child := MenuFromHandle(TrayMenuSubmenuHandle(Populated.Handle, Position))
		AssertEqual(Corpus["registered_labels"].Length, TrayMenuItemCount(Child))
		for Index, Label in Corpus["registered_labels"]
			AssertEqual(Label, TrayMenuItemCaption(Child, Index - 1), "original registry order and description fallback remain native")
		AssertFalse(TrayMenuIsSeparatorAt(Populated, 0))
		AssertFalse(TrayMenuIsSeparatorAt(Populated, TrayMenuItemCount(Populated) - 1))
	} finally {
		for Native in Menus
			_CTC_ReleaseMenu(Native)
		_PersonalShortcutsRegistry := IsSet(SavedRegistry) ? SavedRegistry : unset
		Features := SavedFeatures, CategoryEnabled := SavedCategories
		if HadKeyboard
			KeyboardShortcutAssignments := SavedKeyboard
		else
			KeyboardShortcutAssignments := unset
		State.Clear()
		for Key, Value in SavedState
			State[Key] := Value
		_MenuPopulationBuilding := SavedBuilding, _MenuPopulationPublished := SavedPublished
	}
}

_SMB_FrameCaptionPosition(Native, Caption) {
	Position := -1
	loop TrayMenuItemCount(Native)
		if TrayMenuItemCaption(Native, A_Index - 1) == Caption {
			if Position != -1
				throw Error("A personal frame caption is not unique in the actual native menu")
			Position := A_Index - 1
		}
	return Position
}
_SMB_FrameNativeCaptionSequence(Native, SkipFirst := -1, SkipLast := -1) {
	Text := ""
	loop TrayMenuItemCount(Native) {
		Position := A_Index - 1
		if Position >= SkipFirst && Position <= SkipLast
			continue
		Text .= (Text == "" ? "" : "`n") . (TrayMenuIsSeparatorAt(Native, Position)
			? "---" : TrayMenuItemCaption(Native, Position))
	}
	return Text
}
Test("personal DATA frame: complete actual production Shortcuts order and original registry projection", _SMB_FrameProductionBuildSequence)

; This actual Build call uses the real full declaration and existing native providers.
; Only the personal DATA port observes collection/withdrawal; no generic owner is invented.
_SMB_FrameFullBuildIntoTarget(Target, Provider) {
	return MenuRenderer_Build("shortcuts_menu", "Shortcuts", Map(),
		Map("key_combinations", () => _SC_KeyCombinationsSubmenu(), "script_control", () => _SC_ScriptControlSubmenu()),
		Map("keyboard_slots", () => KeyboardSlotRows(), "tap_keys", () => TapKeyRows(),
			"wrap_symbols_menu", () => _SC_WrapSymbolRows(), "extensions_shortcuts", () => _SC_ExtensionRows()),
		_SC_ScopeCommands(), _SC_Getters(), Target, ,
		Map("personal_shortcuts", Map("manifest_key", "personal_shortcuts_frame",
			"children_id", "personal_shortcuts_registered", "provider", Provider)))
}

; Changing a real preceding declaration to its existing inert separator type creates
; the deferred-separator state. It does not create a command, provider or fixture owner.
_SMB_FrameBuildPreflushAndRefusal() {
	global _PersonalShortcutsRegistry, _MenuPopulationBuilding, _MenuPopulationPublished
	SavedRegistry := IsSet(_PersonalShortcutsRegistry) ? _PersonalShortcutsRegistry : unset
	SavedBuilding := _MenuPopulationBuilding, SavedPublished := _MenuPopulationPublished
	Root := _MR_GetManifestRoot(), Definition := _MR_GetMenuDef("shortcuts_menu")
	Frame := _MR_GetMenuDef("personal_shortcuts_frame"), ScriptPosition := 0
	for Index, Item in Definition
		if Item.Get("id", "") == "script_control"
			ScriptPosition := Index
	Assert(ScriptPosition > 0, "the genuine previous declaration must exist")
	ScriptRow := Definition[ScriptPosition]
	try {
		_MenuPopulationBuilding := false, _MenuPopulationPublished := false
		_PersonalShortcutsRegistry := Map()
		Definition[ScriptPosition] := Map("type", "---")
		for Mode in ["skip", "refuse"] {
			Native := Menu(), Seen := Map("calls", 0)
			ObservePersonal(CurrentMode) {
				Seen["calls"] += 1
				Seen["before"] := _MR_FrameDestinationSnapshot(Native)
				Assert(Seen["before"].Length > 0, "actual previous providers populated the real target")
				AssertFalse(TrayMenuIsSeparatorAt(Native, Seen["before"].Length - 1),
					"strict collection runs BEFORE generic deferred-separator flush")
				if CurrentMode == "refuse"
					Root.Delete("personal_shortcuts_frame")
				return _PersonalShortcutRows()
			}
			try {
				Caught := false
				try Result := _SMB_FrameFullBuildIntoTarget(Native, _SMB_FrameBindCaseObserver(ObservePersonal, Mode))
				catch as Failure
					Caught := Failure
				AssertEqual(1, Seen["calls"], "the full renderer reaches the registered DATA mode")
				if Mode == "refuse" {
					Assert(Caught is Error, "a withdrawn current frame refuses the genuine Build")
					AssertTrue(_MR_FrameNativeImageEqual(Seen["before"], _MR_FrameDestinationSnapshot(Native)),
						"refusal leaves the actual prior destination intact, with no flushed separator")
				} else {
					AssertFalse(Caught)
					Assert(Result == Native, "the actual Build preserves supplied native destination identity")
					AssertEqual(-1, _SMB_FrameCaptionPosition(Native, StrReplace(t("menu.shortcuts.personal"), "&", "&&")))
					AssertFalse(TrayMenuIsSeparatorAt(Native, 0))
					AssertFalse(TrayMenuIsSeparatorAt(Native, TrayMenuItemCount(Native) - 1))
				}
			} finally {
				Root["personal_shortcuts_frame"] := Frame
				_CTC_ReleaseMenu(Native)
			}
		}
	} finally {
		Definition[ScriptPosition] := ScriptRow
		Root["personal_shortcuts_frame"] := Frame
		_PersonalShortcutsRegistry := IsSet(SavedRegistry) ? SavedRegistry : unset
		_MenuPopulationBuilding := SavedBuilding, _MenuPopulationPublished := SavedPublished
	}
}
Test("personal DATA frame: actual full Build intercepts before separator flush on skip/refusal", _SMB_FrameBuildPreflushAndRefusal)


; The module bootstrap owns the interpreter-created constructor before this subject.
; Its first own receiver call is hostile; preceding run_all modules may call it too.
_SMB_FrameNativeConstructorRefusal() {
	global _SharedDir, _MenuPopulationBuilding
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\personal_shortcuts_frame.json", "UTF-8"))
	SavedBuilding := _MenuPopulationBuilding
	OriginalCall := Object.Prototype.GetOwnPropDesc.Call(Menu, "Call")
	Factory := OriginalCall.Call
	AssertTrue(Factory is Func, "the real Menu class has its interpreter-created factory")
	OriginalName := Object.Prototype.GetOwnPropDesc.Call(Func.Prototype, "Name").Get
	OriginalBuiltIn := Object.Prototype.GetOwnPropDesc.Call(Func.Prototype, "IsBuiltIn").Get
	AssertTrue(OriginalBuiltIn.Call(Factory), "the untouched factory is genuinely interpreter-created")
	AssertEqual("Menu.Call", OriginalName.Call(Factory), "the genuine Menu constructor retains its intrinsic name")
	AssertTrue(OriginalBuiltIn.Call(DllCall), "the different-constructor control uses a real alternative builtin")
	PreviousCritical := Critical("On")
	TeardownPrimary := false
	try {
		_MenuPopulationBuilding := false
		for Fault in ["class lambda", "class other builtin", "class accessor", "factory Call",
			"factory Name", "factory IsBuiltIn", "intrinsic Name getter", "intrinsic IsBuiltIn getter"]
			_SMB_FrameNativeConstructorFault(Fault, Corpus, Factory)
	} catch as Failure {
		TeardownPrimary := Failure
		throw Failure
	} finally {
		_SMB_FrameRunAllCleanup(TeardownPrimary,
			() => _SMB_FrameRestoreOwnDescriptor(Menu, "Call", true, OriginalCall),
			() => _MenuPopulationBuilding := SavedBuilding,
			() => Critical(PreviousCritical),
			() => _SMB_FrameAssertOwnDescriptor(Menu, "Call", true, OriginalCall))
	}
}

; Every observer closes over this fresh case parameter, never an AHK loop variable.
_SMB_FrameNativeConstructorFault(Fault, Corpus, Factory) {
	global _MenuDispatchCallbacks
	Calls := Map("provider", 0, "foreign", 0, "actions", 0)
	Callback := (*) => Calls["actions"] += 1
	Data := []
	for Label in Corpus["registered_labels"]
		Data.Push(Map("label", Label, "action", Callback))
	Provider := () => (Calls["provider"] += 1, Data)
	Binding := Map("manifest_key", "personal_shortcuts_frame", "children_id", "personal_shortcuts_registered",
		"provider", Provider)
	Native := Menu()
	RegisterMenuItem(Native, "Original constructor destination", Callback)
	Before := _MR_FrameDestinationSnapshot(Native)
	if InStr(Fault, "class ", true) == 1 {
		Owner := Menu, Name := "Call"
		if Fault == "class other builtin"
			Replacement := {Call: DllCall}
		else if Fault == "class accessor"
			Replacement := {Get: (*) => (Calls["foreign"] += 1, Factory)}
		else
			Replacement := {Call: (*) => (Calls["foreign"] += 1, false)}
	} else if InStr(Fault, "factory ", true) == 1 {
		Owner := Factory, Name := SubStr(Fault, 9)
		if Name == "Call"
			Replacement := {Call: (*) => (Calls["foreign"] += 1, false)}
		else
			Replacement := {Get: (*) => (Calls["foreign"] += 1, Name == "Name" ? "Menu.Call" : true)}
	} else {
		Owner := Func.Prototype, Name := Fault == "intrinsic Name getter" ? "Name" : "IsBuiltIn"
		Replacement := {Get: (*) => (Calls["foreign"] += 1, Name == "Name" ? "Menu.Call" : true)}
	}
	HadProperty := Object.Prototype.HasOwnProp.Call(Owner, Name)
	SavedDescriptor := HadProperty ? Object.Prototype.GetOwnPropDesc.Call(Owner, Name) : false
	TeardownPrimary := false
	try {
		Object.Prototype.DefineProp.Call(Owner, Name, Replacement)
		if Fault == "class accessor" {
			WithdrawnDescriptor := Object.Prototype.GetOwnPropDesc.Call(Owner, Name)
			AssertTrue(Object.Prototype.HasOwnProp.Call(WithdrawnDescriptor, "Get"),
				"the real native class fault installed an actual hostile getter")
			AssertTrue(WithdrawnDescriptor.Get == Replacement.Get,
				"the accessor descriptor retains its exact observer without executing it")
			AssertTrue(Object.Prototype.HasOwnProp.Call(WithdrawnDescriptor, "Call") && WithdrawnDescriptor.Call == Factory,
				"the actual DefineProp API merges Get while retaining the original native Call")
		}
		try Refused := MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts", Binding, , , &Admitted)
		finally {
			_SMB_FrameRestoreOwnDescriptor(Owner, Name, HadProperty, SavedDescriptor)
		}
		_SMB_FrameAssertOwnDescriptor(Owner, Name, HadProperty, SavedDescriptor)
		AssertEqual(0, Refused, Fault . ": the real receiver refuses the withdrawn native factory cohort")
		AssertFalse(Admitted, Fault . ": constructor withdrawal cannot be acknowledged as an intentional skip")
		AssertEqual(0, Calls["provider"], Fault . ": refusal precedes actual DATA provider execution")
		AssertEqual(0, Calls["foreign"], Fault . ": foreign factory and metadata observers never execute")
		AssertTrue(_MR_FrameNativeImageEqual(Before, _MR_FrameDestinationSnapshot(Native)),
			Fault . ": actual retained destination flags, callbacks and child handles remain unchanged")
		AssertEqual(1, TrayMenuItemCount(Native))
		AssertTrue(_MR_FrameNativeConstructorCurrent(Menu),
			Fault . ": exact saved descriptor fields restore genuine constructor admission")
		AssertEqual(1, MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts", Binding, , , &Admitted),
			Fault . ": exact original descriptor/presence repair restores the real native constructor")
		AssertTrue(Admitted)
		AssertEqual(1, Calls["provider"], "the repaired original factory receives the same genuine DATA provider once")
		AssertEqual(0, Calls["foreign"], "repair does not run a withdrawn observer")
		AssertEqual(3, TrayMenuItemCount(Native))
		AssertTrue(TrayMenuIsSeparatorAt(Native, 1))
		ChildHandle := TrayMenuSubmenuHandle(Native.Handle, 2)
		AssertTrue(ChildHandle != 0, "the repaired interpreter-created factory publishes an actual native child")
		Child := MenuFromHandle(ChildHandle)
		AssertEqual(Corpus["registered_labels"].Length, TrayMenuItemCount(Child))
		for Index, Label in Corpus["registered_labels"] {
			AssertEqual(Label, TrayMenuItemCaption(Child, Index - 1), "the untouched independent original labels reach the native child")
			Id := DllCall("GetMenuItemID", "ptr", Child.Handle, "int", Index - 1, "uint")
			AssertTrue(_MenuDispatchCallbacks.Has(Id) && _MenuDispatchCallbacks[Id] == Callback,
				"the repaired real child retains the original actual callback")
		}
		AssertEqual(0, Calls["actions"], "refusal, actual constructor repair and publication never invoke DATA actions")
	} catch as Failure {
		TeardownPrimary := Failure
		throw Failure
	} finally {
		_SMB_FrameRunAllCleanup(TeardownPrimary,
			() => _SMB_FrameRestoreOwnDescriptor(Owner, Name, HadProperty, SavedDescriptor),
			() => _CTC_ReleaseMenu(Native),
			() => _SMB_FrameAssertOwnDescriptor(Owner, Name, HadProperty, SavedDescriptor),
			() => AssertTrue(_MR_FrameNativeConstructorCurrent(Menu), "native teardown preserves the exact repaired constructor cohort"))
	}
}

; Each case enters the genuine native receipt and the original production DATA receiver.
; A poisoned cleanup callable has bounded residue until exact repair; it is not retired.
_SMB_FrameNativePortLifecycle() {
	global _MenuPopulationBuilding
	SavedBuilding := _MenuPopulationBuilding
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\personal_shortcuts_frame.json", "UTF-8"))
	PreviousCritical := Critical("On")
	try {
		; Native names are observed before and after the actual retained nested guards.
		NameGetter := Object.Prototype.GetOwnPropDesc.Call(Func.Prototype, "Name").Get
		Factory := Object.Prototype.GetOwnPropDesc.Call(Menu, "Call").Call
		AssertTrue(NameGetter is Func && ObjGetBase(NameGetter) == Func.Prototype)
		AssertEqual("DllCall", NameGetter.Call(DllCall), "the genuine DLL intrinsic has its interpreter-created name")
		AssertEqual("Menu.Call", NameGetter.Call(Factory), "the genuine factory has its interpreter-created name")
		AssertTrue(TrayMenuFrameNative("current"), "the actual adapter retains its native cohort without clobbering the observed DLL name")
		AssertTrue(TrayMenuFrameNative("current"), "repeated actual guard evaluation preserves DLL result custody")
		AssertTrue(_MR_FrameNativeConstructorCurrent(Menu), "the actual constructor preserves its observed intrinsic name")
		AssertEqual("DllCall", NameGetter.Call(DllCall))
		AssertEqual("Menu.Call", NameGetter.Call(Factory))
		for Fault in ["before dll Call", "before handle intrinsic Call", "before delete intrinsic Call",
			"before adapter Call", "before metadata intrinsic Call", "after adapter Call", "after dll Call",
			"after constructor Call", "after provider Call", "after child Handle", "after child Delete",
			"after registry", "after primary"]
			_SMB_FrameNativePortFault(Fault, Corpus)
	} finally {
		_MenuPopulationBuilding := SavedBuilding
		Critical(PreviousCritical)
	}
}
Test("personal DATA native port: genuine intrinsics, temporal custody, refusal and exact recovery", _SMB_FrameNativePortLifecycle)

; Fresh parameter ownership prevents the observer from reading a mutable loop variable.
_SMB_FrameNativePortFault(Fault, Corpus) {
	global _MenuPopulationBuilding, _MenuDispatchCallbacks, _MenuDispatchTokens, _MenuDispatchOwnerHandles
	global _MenuDispatchLastFire, _MenuDispatchClickSequences
	SavedBuilding := _MenuPopulationBuilding
	HeldRegistries := [_MenuDispatchCallbacks, _MenuDispatchTokens, _MenuDispatchOwnerHandles,
		_MenuDispatchLastFire, _MenuDispatchClickSequences]
	OriginalPort := TrayMenuFrameNative
	HandleGetter := Object.Prototype.GetOwnPropDesc.Call(Menu.Prototype, "Handle").Get
	DeleteMethod := Object.Prototype.GetOwnPropDesc.Call(Menu.Prototype, "Delete").Call
	NameGetter := Object.Prototype.GetOwnPropDesc.Call(Func.Prototype, "Name").Get
	FillDescriptor := Object.Prototype.GetOwnPropDesc.Call(MenuPopulation.Prototype, "Fill")
	OriginalFill := FillDescriptor.Call
	Population := MenuPopulation(), Native := Menu(), Foreign := Menu(), Stage := Map()
	Calls := Map("provider", 0, "fill", 0, "foreign", 0, "actions", 0)
	Callback := (*) => Calls["actions"] += 1
	Rows := []
	for Label in Corpus["registered_labels"]
		Rows.Push(Map("label", Label, "action", Callback))
	Provider := () => (Calls["provider"] += 1, Rows)
	Binding := Map("manifest_key", "personal_shortcuts_frame", "children_id", "personal_shortcuts_registered",
		"provider", Provider)
	DescriptorOwner := false, DescriptorName := "", HadDescriptor := false, SavedDescriptor := false
	Primary := Error("Real post-Fill native port fault")
	Primary.DefineProp("Extra", {Get: (*) => (Calls["foreign"] += 1, _SMB_FrameForbiddenExtraRead()),
		Set: (*) => (Calls["foreign"] += 1, _SMB_FrameForbiddenExtraRead())})
	RestoreFault() {
		if !DescriptorOwner
			return
		_SMB_FrameRestoreOwnDescriptor(DescriptorOwner, DescriptorName, HadDescriptor, SavedDescriptor)
	}
	Withdraw(CurrentFault, Child := false) {
		if CurrentFault == "after registry" {
			_MenuDispatchCallbacks := Map(Stage["foreign_id"], Callback)
			return
		}
		if CurrentFault == "after primary"
			throw Primary
		if InStr(CurrentFault, "dll Call", true)
			DescriptorOwner := DllCall, DescriptorName := "Call"
		else if CurrentFault == "before handle intrinsic Call"
			DescriptorOwner := HandleGetter, DescriptorName := "Call"
		else if CurrentFault == "before delete intrinsic Call"
			DescriptorOwner := DeleteMethod, DescriptorName := "Call"
		else if CurrentFault == "before metadata intrinsic Call"
			DescriptorOwner := NameGetter, DescriptorName := "Call"
		else if InStr(CurrentFault, "adapter Call", true)
			DescriptorOwner := OriginalPort, DescriptorName := "Call"
		else if CurrentFault == "after constructor Call"
			DescriptorOwner := Menu, DescriptorName := "Call"
		else if CurrentFault == "after provider Call"
			DescriptorOwner := Provider, DescriptorName := "Call"
		else if CurrentFault == "after child Handle"
			DescriptorOwner := Child, DescriptorName := "Handle"
		else if CurrentFault == "after child Delete"
			DescriptorOwner := Child, DescriptorName := "Delete"
		else
			throw Error("Unknown finite native port fault")
		HadDescriptor := Object.Prototype.HasOwnProp.Call(DescriptorOwner, DescriptorName)
		SavedDescriptor := HadDescriptor ? Object.Prototype.GetOwnPropDesc.Call(DescriptorOwner, DescriptorName) : false
		Replacement := DescriptorName == "Handle" ? {Get: (*) => (Calls["foreign"] += 1, 0)}
			: {Call: (*) => (Calls["foreign"] += 1, false)}
		Object.Prototype.DefineProp.Call(DescriptorOwner, DescriptorName, Replacement)
	}
	ObserveFill(CurrentFault, Owner, Child, Data, ListId, Depth) {
		Result := OriginalFill.Call(Owner, Child, Data, ListId, Depth)
		Calls["fill"] += 1
		Stage["child"] := Child, Stage["handle"] := Child.Handle
		Stage["id"] := DllCall("GetMenuItemID", "ptr", Stage["handle"], "int", 0, "uint")
		Stage["token"] := Map.Prototype.Get.Call(HeldRegistries[2], Stage["id"])
		Stage["entry"] := Population.Pending[Stage["handle"]]
		AssertTrue(Map.Prototype.Get.Call(HeldRegistries[1], Stage["id"]) == Callback,
			"the observer sees the actual first native seed and original dispatch authority")
		Withdraw(CurrentFault, Child)
		return Result
	}
	TeardownPrimary := false
	try {
		_MenuPopulationBuilding := Population
		OriginalFill.Call(Population, Foreign, Rows, "personal_shortcuts_frame", 2)
		Stage["foreign_entry"] := Population.Pending[Foreign.Handle]
		Stage["foreign_id"] := DllCall("GetMenuItemID", "ptr", Foreign.Handle, "int", 0, "uint")
		RegisterMenuItem(Native, "Retained native port destination", Callback)
		Native.Check("Retained native port destination")
		Native.Disable("Retained native port destination")
		Before := _MR_FrameDestinationSnapshot(Native)
		Captured := OriginalPort.Call("capture", Native)
		AssertEqual(Native.Handle, Captured[1], "the native port retains the actual HMENU")
		AssertEqual(1, Captured[2].Length)
		for Field in [1, 2, 3, 4]
			AssertEqual(Before[1][Field], Captured[2][1][Field], "caption, command id, native flags and child handle are genuine")
		Ids := OriginalPort.Call("ids", Native, Native.Handle)
		AssertEqual(1, Ids.Length)
		AssertEqual(Before[1][2], Ids[1], "retirement enumerates the exact receiving command id")
		AssertEqual(1, OriginalPort.Call("count", Native, Native.Handle))
		BeforeProvider := InStr(Fault, "before ", true) == 1
		if BeforeProvider {
			Withdraw(Fault)
			if Fault != "before adapter Call" {
				AssertFalse(OriginalPort.Call("current"), Fault . ": actual native authority is unavailable")
				AssertFalse(OriginalPort.Call("capture", Native), Fault . ": no native receipt from withdrawn intrinsics")
			}
		} else
			MenuPopulation.Prototype.DefineProp("Fill", {Call: _SMB_FrameBindCaseObserver(ObserveFill, Fault)})
		Caught := false, Added := -1
		try Added := MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts", Binding, , , &Admitted)
		catch as Failure
			Caught := Failure
		; Restore before observing native state so no test assertion invokes a poisoned DLL.
		RestoreFault()
		_SMB_FrameRestoreOwnDescriptor(MenuPopulation.Prototype, "Fill", true, FillDescriptor)
		if DescriptorOwner
			_SMB_FrameAssertOwnDescriptor(DescriptorOwner, DescriptorName, HadDescriptor, SavedDescriptor)
		_SMB_FrameAssertOwnDescriptor(MenuPopulation.Prototype, "Fill", true, FillDescriptor)
		Residue := Fault == "after adapter Call" || Fault == "after dll Call"
		if Fault == "after primary"
			Assert(Caught == Primary, "the actual primary failure object survives native retirement unchanged")
		else if Residue {
			ExpectedMessage := Fault == "after adapter Call" ? "Owned DATA stage cleanup lost its native cohort"
				: "Owned native menu operation lost its retained intrinsics"
			AssertEqual("Error", Type(Caught), "withdrawing genuine cleanup authority throws its actual Error")
			AssertEqual(ExpectedMessage, Caught.Message, "the exact production cleanup failure propagates without a fallback")
			AssertEqual(-1, Added, "failed cleanup never returns a fabricated success or refusal receipt")
			AssertFalse(Admitted, "native residue cannot be acknowledged as admitted publication")
		} else {
			AssertFalse(Caught, Fault . ": source withdrawal remains a refusal")
			AssertEqual(0, Added)
			AssertFalse(Admitted)
		}
		AssertEqual(BeforeProvider ? 0 : 1, Calls["provider"], "native refusal has the required provider boundary")
		AssertEqual(BeforeProvider ? 0 : 1, Calls["fill"], "post-effect faults follow the actual production Fill")
		AssertEqual(0, Calls["foreign"], "no native callable, metadata, child or provider observer executes")
		AssertEqual(0, Calls["actions"], "receipt, retirement and repair do not execute actions")
		if !BeforeProvider {
			AssertFalse(Population.Pending.Has(Stage["handle"]), "the exact owned pending entry retires independently of native authority")
			if Residue {
				AssertEqual(1, DllCall("GetMenuItemCount", "ptr", Stage["handle"], "int"),
					"withdrawing the cleanup callable leaves honest native residue until exact repair")
				AssertTrue(Map.Prototype.Get.Call(HeldRegistries[1], Stage["id"]) == Callback)
				AssertTrue(Map.Prototype.Get.Call(HeldRegistries[2], Stage["id"]) == Stage["token"],
					"unsafe cleanup does not pretend that the staged registration is retired")
				_MR_FrameReleaseChild(Stage["child"], Stage["handle"], HeldRegistries, [Callback], OriginalPort, MenuDispatcher_PruneMenu)
			}
			AssertEqual(0, DllCall("GetMenuItemCount", "ptr", Stage["handle"], "int"),
				Residue ? "exact repair permits genuine native retirement" : "held native intrinsics automatically retire the unpublished child")
			AssertFalse(Map.Prototype.Has.Call(HeldRegistries[1], Stage["id"]))
			AssertFalse(Map.Prototype.Has.Call(HeldRegistries[2], Stage["id"]))
			AssertFalse(Map.Prototype.Has.Call(HeldRegistries[3], Stage["handle"]))
			if Fault == "after registry" {
				Assert(_MenuDispatchCallbacks != HeldRegistries[1])
				AssertEqual(1, _MenuDispatchCallbacks.Count, "the replacement global registry remains foreign and untouched")
				Assert(_MenuDispatchCallbacks[Stage["foreign_id"]] == Callback)
			}
		}
		_MenuDispatchCallbacks := HeldRegistries[1]
		AssertTrue(_MR_FrameNativeImageEqual(Before, _MR_FrameDestinationSnapshot(Native)),
			"native destination flags, caption, callback and token remain unchanged across real refusal")
		Assert(Population.Pending[Foreign.Handle] == Stage["foreign_entry"], "the previous detached picker retains its exact entry")
		AssertTrue(Map.Prototype.Get.Call(HeldRegistries[1], Stage["foreign_id"]) == Callback)
		AssertTrue(Map.Prototype.Has.Call(HeldRegistries[2], Stage["foreign_id"]))
		AssertEqual(1, TrayMenuItemCount(Foreign))
		AssertTrue(OriginalPort.Call("current"), "exact descriptor repair restores the actual native port")
		AssertEqual(1, MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts", Binding, , , &Admitted))
		AssertTrue(Admitted)
		AssertEqual(3, TrayMenuItemCount(Native))
		AssertTrue(TrayMenuIsSeparatorAt(Native, 1))
		Child := MenuFromHandle(TrayMenuSubmenuHandle(Native.Handle, 2))
		AssertEqual(1, TrayMenuItemCount(Child), "repair publishes the original native seed")
		AssertTrue(Population.Complete(Child.Handle))
		AssertEqual(Corpus["registered_labels"].Length, TrayMenuItemCount(Child))
		CompletedReceipt := OriginalPort.Call("capture", Native)
		AssertEqual(3, CompletedReceipt[2].Length)
		AssertEqual(Child.Handle, CompletedReceipt[2][3][4], "the actual native submenu handle belongs to the published repaired child")
		ChildIds := OriginalPort.Call("ids", Child, Child.Handle)
		AssertEqual(Corpus["registered_labels"].Length, ChildIds.Length)
		AssertEqual(Corpus["registered_labels"].Length, OriginalPort.Call("count", Child, Child.Handle))
		for Index, Label in Corpus["registered_labels"] {
			AssertEqual(Label, TrayMenuItemCaption(Child, Index - 1), "the unchanged independent corpus reaches the repaired native child")
			Id := DllCall("GetMenuItemID", "ptr", Child.Handle, "int", Index - 1, "uint")
			AssertEqual(Id, ChildIds[Index], "the adapter command ID is independently received from Win32")
			Assert(_MenuDispatchCallbacks[Id] == Callback)
			AssertTrue(_MenuDispatchTokens.Has(Id))
		}
		AssertEqual(0, Calls["foreign"])
		AssertEqual(0, Calls["actions"])
	} catch as Failure {
		TeardownPrimary := Failure
		throw Failure
	} finally {
		_SMB_FrameRunAllCleanup(TeardownPrimary,
			RestoreFault,
			() => _SMB_FrameRestoreOwnDescriptor(MenuPopulation.Prototype, "Fill", true, FillDescriptor),
			() => _MenuDispatchCallbacks := HeldRegistries[1],
			() => Population.Stop(),
			() => Population.Pending.Clear(),
			() => _MenuPopulationBuilding := SavedBuilding,
			() => Stage.Has("child") ? _CTC_ReleaseMenu(Stage["child"]) : false,
			() => _CTC_ReleaseMenu(Native),
			() => _CTC_ReleaseMenu(Foreign),
			() => DescriptorOwner ? _SMB_FrameAssertOwnDescriptor(DescriptorOwner, DescriptorName, HadDescriptor, SavedDescriptor) : false,
			() => _SMB_FrameAssertOwnDescriptor(MenuPopulation.Prototype, "Fill", true, FillDescriptor))
	}
}

; DefineProp updates only supplied dynamic fields. Exact repair first removes the
; withdrawn own property, then reinstates the saved descriptor and verifies it.
_SMB_FrameRestoreOwnDescriptor(Owner, Name, HadProperty, SavedDescriptor) {
	if Object.Prototype.HasOwnProp.Call(Owner, Name)
		Object.Prototype.DeleteProp.Call(Owner, Name)
	if HadProperty
		Object.Prototype.DefineProp.Call(Owner, Name, SavedDescriptor)
}

_SMB_FrameAssertOwnDescriptor(Owner, Name, HadProperty, SavedDescriptor) {
	AssertEqual(HadProperty, Object.Prototype.HasOwnProp.Call(Owner, Name),
		"native fixture repair restores exact own-property presence")
	if !HadProperty
		return
	ActualDescriptor := Object.Prototype.GetOwnPropDesc.Call(Owner, Name)
	ExpectedCount := 0, ActualCount := 0
	for Field, Expected in ObjOwnProps(SavedDescriptor) {
		ExpectedCount += 1
		AssertTrue(Object.Prototype.HasOwnProp.Call(ActualDescriptor, Field),
			"native fixture repair retains each original descriptor field")
		AssertTrue(ActualDescriptor.%Field% == Expected,
			"native fixture repair retains exact original getter, setter, method or value identity")
	}
	for Field in ObjOwnProps(ActualDescriptor)
		ActualCount += 1
	AssertEqual(ExpectedCount, ActualCount,
		"native fixture repair removes all omitted hostile descriptor fields")
}

; Test-owned teardown invokes every genuine cleanup operation, even after a failed
; verification or restore. It never reads or replaces a pending primary Error.
_SMB_FrameRunAllCleanup(OriginalFailure, Cleanup*) {
	CleanupFailure := false
	for Operation in Cleanup {
		try Operation.Call()
		catch as Failure {
			if !CleanupFailure
				CleanupFailure := Failure
		}
	}
	if !OriginalFailure && CleanupFailure
		throw CleanupFailure
}
