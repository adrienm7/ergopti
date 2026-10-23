; tests/unit/modules/shortcuts/test_shortcuts_personal_data_frame.ahk

; ==============================================================================
; MODULE: Personal Shortcuts DATA Frame
; DESCRIPTION:
; The personal shortcuts DATA frame keeps its retained source and seeded
; population, its Build registration custody, the late-stage cleanup and
; native publication rollback, and the production Shortcuts order.
; ==============================================================================

#Requires AutoHotkey v2.0





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
	global KeyboardShortcutAssignments
	HadKeyboard := IsSet(KeyboardShortcutAssignments)
	SavedKeyboard := HadKeyboard ? KeyboardShortcutAssignments : false
	TeardownPrimary := false
	RestoreKeyboardInventory() {
		global KeyboardShortcutAssignments
		if HadKeyboard
			KeyboardShortcutAssignments := SavedKeyboard
		else
			KeyboardShortcutAssignments := unset
	}
	VerifyKeyboardInventory() {
		global KeyboardShortcutAssignments
		AssertEqual(HadKeyboard, IsSet(KeyboardShortcutAssignments), "the actual boot inventory retains its original presence after native teardown")
		if HadKeyboard
			AssertTrue(KeyboardShortcutAssignments == SavedKeyboard, "the exact original keyboard inventory owner is restored")
	}
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
		; run_all omits feature_state boot globals. Keep the real full keyboard
		; provider and populate its actual inventory from canonical shipped defaults.
		KeyboardShortcutAssignments := Map()
		for Entry in ManifestFeaturesForSection("shortcuts.keyboard")
			KeyboardShortcutAssignments[Entry["id"]] := ManifestDefaultFor(Entry["path"])
		AssertTrue(KeyboardSlotRows() is Array, "the genuine preceding keyboard provider receives its boot-owned inventory")
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
				; Surface any genuine prerequisite failure before the DATA observer,
				; instead of replacing its native diagnostic with a secondary count error.
				if Caught && Seen["calls"] == 0
					throw Caught
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
	} catch as Failure {
		TeardownPrimary := Failure
		throw Failure
	} finally {
		_SMB_FrameRunAllCleanup(TeardownPrimary,
			() => Definition[ScriptPosition] := ScriptRow,
			() => Root["personal_shortcuts_frame"] := Frame,
			() => _PersonalShortcutsRegistry := IsSet(SavedRegistry) ? SavedRegistry : unset,
			() => _MenuPopulationBuilding := SavedBuilding,
			() => _MenuPopulationPublished := SavedPublished,
			RestoreKeyboardInventory, VerifyKeyboardInventory)
	}
}
Test("personal DATA frame: actual full Build intercepts before separator flush on skip/refusal", _SMB_FrameBuildPreflushAndRefusal)





; ===============================================================
; ===============================================================
; ======= Pending-receipt walks follow foreign calls only =======
; ===============================================================
; ===============================================================

; The earlier deferred leaves' receipts were re-walked on all 32 liveness checks of one
; frame (about 1 s of boot). They are walked again only after a call out to code that is
; not a pure comparison, so a mutation made by such code is still refused.
_SMB_FramePendingWalkCounts() {
	Counts := _PerfCountersOwner().Counts
	return [Counts.Get("menu.frame_pending_walk", 0), Counts.Get("menu.frame_pending_skip", 0)]
}

_SMB_FramePendingWalksFollowForeignCalls() {
	global _MenuPopulationBuilding
	Previous := _MenuPopulationBuilding
	Owner := MenuPopulation(), Native := Menu(), Foreign := Menu()
	Action := (*) => 0
	ForeignRows := [Map("label", "Earlier seeded", "action", Action), Map("label", "Earlier pending", "action", Action)]
	Data := [Map("label", "Frame seeded", "action", Action), Map("label", "Frame pending", "action", Action)]
	try {
		_MenuPopulationBuilding := Owner
		Owner.Fill(Foreign, ForeignRows, "personal_shortcuts_frame", 2)
		Binding := Map("manifest_key", "personal_shortcuts_frame", "children_id", "personal_shortcuts_registered",
			"provider", () => Data)
		Before := _SMB_FramePendingWalkCounts()
		AssertEqual(1, MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts", Binding))
		After := _SMB_FramePendingWalkCounts()
		Walks := After[1] - Before[1], Skips := After[2] - Before[2]
		Assert(Skips >= 10, "checks with no foreign call in between reuse the last walk (skips=" . Skips . ")")
		Assert(Walks >= 1 && Walks <= 14, "walks stay bounded by the foreign calls (walks=" . Walks . ")")
		_CTC_ReleaseMenu(Native)
		Native := Menu()
		; An earlier pending entry changed by the provider, a foreign call, is still refused.
		Entry := Owner.Pending[Foreign.Handle]
		Binding["provider"] := () => (Entry.NextRow := 2, Data)
		AssertEqual(0, MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts", Binding, , , &Admitted),
			"a pending entry mutated by the provider is refused")
		AssertFalse(Admitted)
		Entry.NextRow := 1
		Binding["provider"] := () => (Owner.Pending.Delete(Foreign.Handle), Data)
		AssertEqual(0, MenuRenderer_AppendFrameData(Native, "shortcuts_menu", "personal_shortcuts", Binding, , , &Admitted),
			"a pending entry withdrawn by the provider is refused")
		AssertFalse(Admitted)
	} finally {
		Owner.Stop()
		Owner.Pending.Clear()
		_MenuPopulationBuilding := Previous
		_CTC_ReleaseMenu(Native)
		_CTC_ReleaseMenu(Foreign)
	}
}
Test("personal DATA frame: pending receipts are walked after foreign calls only and mutations stay refused (frame-pending-walk)",
	_SMB_FramePendingWalksFollowForeignCalls)
