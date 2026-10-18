; tests/unit/infra/config/scope/test_personal_frame_native.ahk

; ==============================================================================
; MODULE: Personal Menu Frame Native Ownership
; DESCRIPTION:
; The shared personal frame disposes new native children on source
; withdrawal, releases them on a late label failure, keeps foreign owners on
; cleanup and repairs the default choice exactly.
; ==============================================================================

#Requires AutoHotkey v2.0





; Actual file-backed reconstruction must dispose only the menus it allocated.
_HSCS_PersonalFrameNativeRefusal() {
	global ScriptInformation, Features, CategoryEnabled, ConfigurationFile
	global _ReadPersonalTomlCache, _PersonalExtTree, _FmtCountCache, _PrevDefaultLabel, _TomlUnreadableFiles
	global _MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatchTokens
	global _MenuDispatchClickSequences, _MenuDispatchOwnerHandles
	Fixture := _ScopeOwnerFixture(), PersonalPath := Fixture.path . ".personal.toml"
	Source := Chr(0xFEFF) . '[personal_editor]`nDefaultSection = "beta"`nclose_on_add = "1"`n[private]`nkeep = "personal-frame-source"`n'
	PersonalSource := '[[alpha]]`n[[beta]]`n'
	SavedInfo := ScriptInformation, SavedFeatures := Features, SavedCategories := CategoryEnabled
	SavedConfig := IsSet(ConfigurationFile) ? ConfigurationFile : unset
	SavedCache := _ReadPersonalTomlCache, SavedUnreadable := _TomlUnreadableFiles
	SavedTree := IsSet(_PersonalExtTree) ? _PersonalExtTree : unset
	SavedCounts := IsSet(_FmtCountCache) ? _FmtCountCache : unset
	SavedDefaultLabel := IsSet(_PrevDefaultLabel) ? _PrevDefaultLabel : unset
	State := MasterGateState(), SavedState := State.Clone()
	Root := _MR_GetManifestRoot(), Owned := [], Originals := Map()
	for Key in ["hotstring_personal_default_frame", "hotstring_personal_controls_frame",
		"hotstring_personal_content_frame", "hotstring_personal_directory_frame", "hotstring_personal_default_parent"]
		Originals[Key] := Root[Key]
	ReadRows() {
		Rows := _HS_PersonalRows(Fixture.options)
		if Rows is Array {
			for Row in Rows
				if Row is Map && Row.Has("submenu") && Row["submenu"] is Menu
					Owned.Push(Row["submenu"])
		}
		return Rows
	}
	ReleaseRows() {
		Failure := 0
		for Child in Owned {
			try _HS_PersonalReleaseMenus([Child])
			catch as ErrorInfo {
				if !Failure
					Failure := ErrorInfo
			}
		}
		Owned := []
		if Failure
			throw Failure
	}
	try {
		Source := _CMJFixtureCurrentSource(Source)
		Assert(FSWriteDurable(Fixture.path, Source))
		Assert(FSWriteDurable(PersonalPath, PersonalSource))
		ConfigurationFile := Fixture.path
		ScriptInformation := ScriptInformation.Clone()
		ScriptInformation["PersonalTomlPath"] := PersonalPath
		_ReadPersonalTomlCache := false, _TomlUnreadableFiles := Map()
		_PersonalExtTree := Map(), _FmtCountCache := Map()
		Features := ManifestBuildFeaturesMap()
		for Name in ["alpha", "beta"]
			_ConfigSeedPersonalHotstring(Features, Name)
		CategoryEnabled := Map("Hotstrings", false)
		State["initialized"] := false
		MasterGateInitialize(Features, Map("keys", Map()), (*) => false)
		Cleaner := Menu()
		try Cleaner.Delete()
		finally MenuDispatcher_PruneMenu(Cleaner)
		Tables := [_MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatchTokens,
			_MenuDispatchClickSequences, _MenuDispatchOwnerHandles], Before := []
		for Table in Tables
			Before.Push(Table.Clone())
		Rows := ReadRows()
		Assert(Rows is Array && Rows.Length == 1, "the genuine personal source produces one caller-owned native parent")
		AssertEqual(1, Owned.Length)
		Assert(_MenuDispatchCallbacks.Count > Before[1].Count, "real native children register actual callbacks")
		DefaultCaption := t("menu.hotstrings.default_category_prefix") . "beta"
		AssertEqual(1, _CTC_CountLabel(Owned[1], DefaultCaption))
		AssertEqual(1, _CTC_CountLabel(Owned[1], t("menu.hotstrings.close_on_add")))
		; Keep the actual native child and its original selection callback alive.
		LivePersonal := Owned[1], LiveHandle := LivePersonal.Handle, LiveDefault := false
		loop TrayMenuItemCount(LivePersonal) {
			if _MUR_LabelAt(LivePersonal, A_Index - 1) == DefaultCaption {
				ChildHandle := DllCall("GetSubMenu", "ptr", LiveHandle, "int", A_Index - 1, "ptr")
				Assert(ChildHandle != 0, "the genuine declared parent owns a native default child")
				LiveDefault := MenuFromHandle(ChildHandle)
				break
			}
		}
		Assert(LiveDefault is Menu, "the original finished default Menu is retained")
		DefaultHandle := LiveDefault.Handle, BeforeFlags := []
		loop TrayMenuItemCount(LiveDefault) {
			Flags := DllCall("GetMenuState", "ptr", DefaultHandle, "uint", A_Index - 1, "uint", 0x400, "uint")
			Assert(Flags != 0xFFFFFFFF, "the actual native child acknowledges each item flag read")
			BeforeFlags.Push(Flags)
		}
		TomlModel := ReadPersonalToml(), LabelMap := _HS_BuildDisambiguatedSectionLabels(TomlModel)
		ParentKey := "hotstring_personal_default_parent", ParentDefinition := Root[ParentKey]
		BeforeSource := FSReadUtf8Exact(Fixture.path), BeforeCaption := _PrevDefaultLabel
		try {
			Root.Delete(ParentKey)
			AssertFalse(_SetPersonalDefaultSection("alpha", LivePersonal, TomlModel, LiveDefault, LabelMap),
				"withdrawn old/new caption admission refuses before the original setter")
			AssertEqual(BeforeSource, FSReadUtf8Exact(Fixture.path), "caption refusal performs no preference write")
			AssertEqual(BeforeCaption, _PrevDefaultLabel)
			AssertEqual(1, _CTC_CountLabel(LivePersonal, DefaultCaption), "caption refusal does not rename the retained parent")
			loop TrayMenuItemCount(LiveDefault)
				AssertEqual(BeforeFlags[A_Index], DllCall("GetMenuState", "ptr", DefaultHandle, "uint", A_Index - 1, "uint", 0x400, "uint"),
					"caption refusal performs no Check or Uncheck")
			Root[ParentKey] := ParentDefinition
			BadLabels := LabelMap.Clone(), BadLabels["alpha"] := false
			AssertFalse(_SetPersonalDefaultSection("alpha", LivePersonal, TomlModel, LiveDefault, BadLabels),
				"a refused second caption receipt performs no setter after admitting the original caption")
			AssertEqual(BeforeSource, FSReadUtf8Exact(Fixture.path))
			AssertEqual(BeforeCaption, _PrevDefaultLabel)
			loop TrayMenuItemCount(LiveDefault)
				AssertEqual(BeforeFlags[A_Index], DllCall("GetMenuState", "ptr", DefaultHandle, "uint", A_Index - 1, "uint", 0x400, "uint"))
			AssertEqual(1, _CTC_CountLabel(LivePersonal, DefaultCaption))
			AlphaCallback := false
			loop TrayMenuItemCount(LiveDefault) {
				if _MUR_LabelAt(LiveDefault, A_Index - 1) == LabelMap["alpha"] {
					AlphaId := DllCall("GetMenuItemID", "ptr", DefaultHandle, "int", A_Index - 1, "uint")
					Assert(_MenuDispatchCallbacks.Has(AlphaId), "the actual default choice has its original registered callback")
					AlphaCallback := _MenuDispatchCallbacks[AlphaId]
					break
				}
			}
			Assert(HasMethod(AlphaCallback, "Call"))
			AlphaCallback.Call()
			AssertEqual("alpha", _EditorPrefGet("DefaultSection", ""), "the original callback still reaches the genuine native preference writer")
			AssertEqual(LabelMap["alpha"], _PrevDefaultLabel)
			AssertEqual(1, _CTC_CountLabel(LivePersonal, t("menu.hotstrings.default_category_prefix") . LabelMap["alpha"]))
			AssertEqual(LiveHandle, LivePersonal.Handle, "repaint keeps the exact original native parent")
			AssertEqual(DefaultHandle, LiveDefault.Handle, "repaint keeps the exact original native default child")
			AssertTrue(_MenuDispatchCallbacks.Has(AlphaId) && _MenuDispatchCallbacks[AlphaId] == AlphaCallback,
				"repaint retains the same actual callback and target instead of rebuilding")
			Assert(InStr(FSReadUtf8Exact(Fixture.path), 'keep = "personal-frame-source"'), "the genuine write preserves unknown source data")
			; Restore the fixture's original desired default through that same native UI owner.
			_SetPersonalDefaultSection("beta", LivePersonal, TomlModel, LiveDefault, LabelMap)
			AssertEqual("beta", _EditorPrefGet("DefaultSection", ""))
		} finally {
			Root[ParentKey] := ParentDefinition
		}
		ReleaseRows()
		for Key, Original in Originals {
			Root.Delete(Key)
			loop 2 {
				_PreviousCaption := _PrevDefaultLabel
				Refused := ReadRows()
				Assert(Refused is Array && Refused.Length == 0, "whole-frame withdrawal has no partial native handoff")
				AssertEqual(0, Owned.Length)
				AssertEqual(_PreviousCaption, _PrevDefaultLabel, "refused reconstruction cannot replace a retained live menu caption")
				for Index, Table in Tables {
					AssertEqual(Before[Index].Count, Table.Count, "every newly returned personal child has been disposed and pruned")
					for Id, Callback in Before[Index]
						Assert(Table.Has(Id) && Table[Id] == Callback, "unrelated dispatcher owner identities remain exact")
				}
				AssertEqual(Source, FSReadUtf8Exact(Fixture.path))
				AssertEqual(PersonalSource, FSReadUtf8Exact(PersonalPath))
			}
			Root[Key] := Original
			AssertEqual(1, ReadRows().Length, "exact declaration repair restores the same source-backed provider")
			ReleaseRows()
		}
	} finally {
		try ReleaseRows()
		finally {
			for Key, Original in Originals
				Root[Key] := Original
			ScriptInformation := SavedInfo, Features := SavedFeatures, CategoryEnabled := SavedCategories
			ConfigurationFile := IsSet(SavedConfig) ? SavedConfig : unset
			_ReadPersonalTomlCache := SavedCache, _TomlUnreadableFiles := SavedUnreadable
			_PersonalExtTree := IsSet(SavedTree) ? SavedTree : unset
			_FmtCountCache := IsSet(SavedCounts) ? SavedCounts : unset
			_PrevDefaultLabel := IsSet(SavedDefaultLabel) ? SavedDefaultLabel : unset
			State.Clear()
			for Key, Value in SavedState
				State[Key] := Value
			try FileDelete(PersonalPath)
			_ScopeOwnerCleanup(Fixture)
		}
	}
}
Test("shared-personal-frame: real source withdrawal disposes new native children and preserves existing dispatcher owners",
	_HSCS_PersonalFrameNativeRefusal)


; The actual adopted file owner can fail while the final native label is formed.
; Ownership transfers only after the complete result has been constructed.
_HSCS_PersonalFileLateLabelFailure(Kind) {
	global ScriptInformation, ConfigurationFile, CategoryEnabled, _FmtCountCache
	global _MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatchTokens
	global _MenuDispatchClickSequences, _MenuDispatchOwnerHandles
	SavedInfo := ScriptInformation, SavedConfig := IsSet(ConfigurationFile) ? ConfigurationFile : unset
	SavedCategories := CategoryEnabled, SavedCounts := IsSet(_FmtCountCache) ? _FmtCountCache : unset
	SavedOwners := PersonalFileControls.owners, SavedInventory := PersonalFileControls.inventory
	Fixture := _ScopeOwnerFixture(), Owner := false, OwnerOverride := false, ExtraHandles := Map()
	LateCalls := 0, PrimaryFailure := Error("personal late stem failure"), ThrowingMenus := []
	ThrowAfterDelete(This, *) {
		Menu.Prototype.Delete.Call(This)
		throw Error("owned cleanup failure after native delete")
	}
	ThrowStem(This, *) {
		LateCalls += 1
		if Kind == "cleanup" {
			for Handle in _MenuDispatchOwnerHandles {
				if Before[5].Has(Handle)
					continue
				Child := MenuFromHandle(Handle)
				if Child is Menu {
					Child.DefineProp("Delete", {Call: ThrowAfterDelete})
					ThrowingMenus.Push(Child)
				}
			}
		}
		throw PrimaryFailure
	}
	ThrowActiveCount(This, *) {
		LateCalls += 1
		throw Error("personal late ActiveCount failure")
	}
	CountHas(This, N) {
		if N == 2 {
			LateCalls += 1
			throw Error("personal late FmtCount failure")
		}
		return Map.Prototype.Has.Call(This, N)
	}
	try {
		Root := Fixture.directory . "\personal"
		DirCreate(Root)
		FilePath := Root . "\late_label.toml"
		Content := '[[alpha]]`n"abcd" = "first"`n[[beta]]`n"qwer" = "second"`n'
		Source := '[category_enabled]`nhotstrings = true`n[private]`nkeep = "late-label"`n'
		Assert(FSWriteDurable(FilePath, Content))
		Source := _CMJFixtureCurrentSource(Source)
		Assert(FSWriteDurable(Fixture.path, Source))
		ScriptInformation := SavedInfo.Clone()
		ScriptInformation["PersonalHotstringsDir"] := Root
		ScriptInformation["PersonalTomlPath"] := Root . "\personal_hotstrings.toml"
		ConfigurationFile := Fixture.path
		CategoryEnabled := SavedCategories.Clone(), CategoryEnabled["Hotstrings"] := true
		PersonalFileControls.owners := Map(), PersonalFileControls.inventory := []
		PersonalFileControls.Refresh()
		Owner := PersonalFileControls.ForPath(FilePath)
		Assert(Owner is PersonalFileAdoptedOwner && PersonalFileControls.IsCurrent(Owner),
			"the failure control uses the genuine file-backed adopted owner")
		AssertEqual(2, Owner.ActiveCount())
		_FmtCountCache := Map(1, "1")
		TF := {path: FilePath, stem: "late_label", sections: [], count: 2}
		if Kind == "stem" || Kind == "cleanup" {
			TF.DeleteProp("stem")
			TF.DefineProp("stem", {Get: ThrowStem})
		} else if Kind == "format"
			_FmtCountCache.DefineProp("Has", {Call: CountHas})
		else {
			AssertFalse(Owner.HasOwnProp("ActiveCount"), "the real owner starts with its native class method")
			Owner.DefineProp("ActiveCount", {Call: ThrowActiveCount})
			OwnerOverride := true
		}
		Cleaner := Menu()
		try Cleaner.Delete()
		finally MenuDispatcher_PruneMenu(Cleaner)
		Tables := [_MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatchTokens,
			_MenuDispatchClickSequences, _MenuDispatchOwnerHandles], Before := []
		for Table in Tables
			Before.Push(Table.Clone())
		loop 2 {
			Caught := false
			try Result := _HS_TomlFileRow(TF)
			catch as Failure {
				Caught := true
				Assert(InStr(Failure.Message, "personal late"), "the genuine late label failure is propagated")
				if Kind == "cleanup"
					Assert(Failure == PrimaryFailure, "cleanup failure cannot replace the original native construction exception")
			}
			AssertTrue(Caught, "the actual producer must propagate the label failure")
			AssertEqual(A_Index, LateCalls, "each construction reaches exactly one native late label operation")
			for Index, Table in Tables {
				AssertEqual(Before[Index].Count, Table.Count,
					"a thrown final label releases and prunes the actual owned native child before handoff")
				for Id, Value in Before[Index]
					Assert(Table.Has(Id) && Table[Id] == Value, "unrelated dispatcher identities remain exact")
			}
			AssertEqual(Content, FSReadUtf8Exact(FilePath))
			AssertEqual(Source, FSReadUtf8Exact(Fixture.path))
		}
	} finally {
		for Child in ThrowingMenus
			if Child.HasOwnProp("Delete")
				Child.DeleteProp("Delete")
		; A regression control may leave a returned native owner: dispose only
		; its newly registered handles, after the assertions have observed it.
		try {
		if IsSet(Before) {
			for Handle in _MenuDispatchOwnerHandles
				if !Before[5].Has(Handle)
					ExtraHandles[Handle] := true
			for Handle in ExtraHandles {
				Child := MenuFromHandle(Handle)
				if Child is Menu {
					try Child.Delete()
					finally MenuDispatcher_PruneMenu(Child)
				}
			}
		}
		} finally {
		for Child in ThrowingMenus
			if Child.HasOwnProp("Delete")
				Child.DeleteProp("Delete")
		if OwnerOverride
			Owner.DeleteProp("ActiveCount")
		ScriptInformation := SavedInfo, ConfigurationFile := IsSet(SavedConfig) ? SavedConfig : unset
		CategoryEnabled := SavedCategories, _FmtCountCache := IsSet(SavedCounts) ? SavedCounts : unset
		PersonalFileControls.owners := SavedOwners, PersonalFileControls.inventory := SavedInventory
		_ScopeOwnerCleanup(Fixture)
	}
		}
}
for _HSCS_LateLabelKind in ["stem", "format", "active", "cleanup"]
	Test("shared-personal-frame: genuine native late label failure releases child " . _HSCS_LateLabelKind,
		_HSCS_PersonalFileLateLabelFailure.Bind(_HSCS_LateLabelKind))


; Dispose only a fresh owned tree; a foreign detached command stays live.
_HSCS_PersonalOwnedTreeRelease(ThrowCleanup) {
	global _MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatchTokens
	global _MenuDispatchClickSequences, _MenuDispatchOwnerHandles
	Root := Menu(), Child := Menu(), Grandchild := Menu(), Sibling := Menu(), Foreign := Menu()
	CleanupFailure := Error("owned child cleanup failed"), Deletes := 0
	ThrowAfterDelete(This, *) {
		Deletes += 1
		Menu.Prototype.Delete.Call(This)
		throw CleanupFailure
	}
	try {
		AssertEqual(1, RegisterMenuItem(Foreign, "foreign detached action", _CTC_OwnedMenuProbe.Bind(Foreign, Foreign)))
		ForeignId := DllCall("GetMenuItemID", "ptr", Foreign.Handle, "int", 0, "uint")
		Assert(ForeignId != 0xFFFFFFFF && _MenuDispatchCallbacks.Has(ForeignId))
		ForeignCallback := _MenuDispatchCallbacks[ForeignId]
		Cleaner := Menu()
		try Cleaner.Delete()
		finally MenuDispatcher_PruneMenu(Cleaner)
		Tables := [_MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatchTokens,
			_MenuDispatchClickSequences, _MenuDispatchOwnerHandles], Before := []
		for Table in Tables
			Before.Push(Table.Clone())
		AssertEqual(1, RegisterMenuItem(Child, "owned child action", _CTC_OwnedMenuProbe.Bind(Child, Root)))
		AssertEqual(1, RegisterMenuItem(Grandchild, "owned grandchild action", _CTC_OwnedMenuProbe.Bind(Grandchild, Child)))
		AssertEqual(1, RegisterMenuItem(Sibling, "owned sibling action", _CTC_OwnedMenuProbe.Bind(Sibling, Root)))
		Child.Add("owned grandchild", Grandchild)
		Root.Add("owned child", Child)
		Root.Add("owned sibling", Sibling)
		Handles := [Root.Handle, Child.Handle, Grandchild.Handle, Sibling.Handle]
		if ThrowCleanup
			Child.DefineProp("Delete", {Call: ThrowAfterDelete})
		Caught := false
		try _HS_PersonalReleaseMenus([Root, Child, Sibling])
		catch as Failure {
			Caught := true
			Assert(ThrowCleanup && Failure == CleanupFailure, "attempt-all cleanup retains the exact first failure")
		}
		AssertEqual(ThrowCleanup, Caught)
		AssertEqual(ThrowCleanup ? 1 : 0, Deletes)
		for Handle in Handles {
			AssertEqual(0, DllCall("GetMenuItemCount", "ptr", Handle, "int"), "every strongly retained owned native menu was emptied")
			AssertFalse(_MenuDispatchOwnerHandles.Has(Handle), "only the known empty owned handle is retired")
		}
		AssertEqual(1, TrayMenuItemCount(Foreign), "foreign detached native rows survive")
		Assert(_MenuDispatchCallbacks.Has(ForeignId) && _MenuDispatchCallbacks[ForeignId] == ForeignCallback,
			"the exact foreign callback survives every owned descendant release")
		for Index, Table in Tables {
			AssertEqual(Before[Index].Count, Table.Count, "all owned dispatcher resources return to the captured baseline")
			for Key, Value in Before[Index]
				Assert(Table.Has(Key) && Table[Key] == Value, "every pre-existing dispatcher identity is retained")
		}
	} finally {
		if Child.HasOwnProp("Delete")
			Child.DeleteProp("Delete")
		try _HS_PersonalReleaseMenus([Root, Child, Grandchild, Sibling])
		finally _HS_PersonalReleaseMenus([Foreign])
	}
}
for _HSCS_ThrowCleanup in [false, true]
	Test("shared-personal-frame: owned deep tree cleanup preserves foreign native owner " . _HSCS_ThrowCleanup,
		_HSCS_PersonalOwnedTreeRelease.Bind(_HSCS_ThrowCleanup))


; Actual native leaf receiving retains the original source writer and menu owners.
_HSCS_DefaultChoiceSourceReceiving(Kind) {
	global ScriptInformation, Features, CategoryEnabled, ConfigurationFile
	global _ReadPersonalTomlCache, _PersonalExtTree, _FmtCountCache, _PrevDefaultLabel, _TomlUnreadableFiles
	global _MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatchTokens
	global _MenuDispatchClickSequences, _MenuDispatchOwnerHandles
	Fixture := _ScopeOwnerFixture(), PersonalPath := Fixture.path . ".personal.toml"
	Source := Chr(0xFEFF) . '[personal_editor]`nDefaultSection = "beta"`nclose_on_add = "1"`n[private]`nkeep = "personal-frame-source"`n'
	PersonalSource := '[[alpha]]`n[[beta]]`n'
	SavedInfo := ScriptInformation, SavedFeatures := Features, SavedCategories := CategoryEnabled
	SavedConfig := IsSet(ConfigurationFile) ? ConfigurationFile : unset
	SavedCache := _ReadPersonalTomlCache, SavedUnreadable := _TomlUnreadableFiles
	SavedTree := IsSet(_PersonalExtTree) ? _PersonalExtTree : unset
	SavedCounts := IsSet(_FmtCountCache) ? _FmtCountCache : unset
	SavedDefaultLabel := IsSet(_PrevDefaultLabel) ? _PrevDefaultLabel : unset
	State := MasterGateState(), SavedState := State.Clone()
	Root := _MR_GetManifestRoot(), Owned := [], Originals := Map()
	for Key in ["hotstring_personal_default_frame", "hotstring_personal_controls_frame",
		"hotstring_personal_content_frame", "hotstring_personal_directory_frame", "hotstring_personal_default_parent"]
		Originals[Key] := Root[Key]
	ReadRows() {
		Rows := _HS_PersonalRows(Fixture.options)
		if Rows is Array {
			for Row in Rows
				if Row is Map && Row.Has("submenu") && Row["submenu"] is Menu
					Owned.Push(Row["submenu"])
		}
		return Rows
	}
	ReleaseRows() {
		Failure := 0
		for Child in Owned {
			try _HS_PersonalReleaseMenus([Child])
			catch as ErrorInfo {
				if !Failure
					Failure := ErrorInfo
			}
		}
		Owned := []
		if Failure
			throw Failure
	}
	try {
		Source := _CMJFixtureCurrentSource(Source)
		Assert(FSWriteDurable(Fixture.path, Source))
		Assert(FSWriteDurable(PersonalPath, PersonalSource))
		ConfigurationFile := Fixture.path
		ScriptInformation := ScriptInformation.Clone()
		ScriptInformation["PersonalTomlPath"] := PersonalPath
		_ReadPersonalTomlCache := false, _TomlUnreadableFiles := Map()
		_PersonalExtTree := Map(), _FmtCountCache := Map()
		Features := ManifestBuildFeaturesMap()
		for Name in ["alpha", "beta"]
			_ConfigSeedPersonalHotstring(Features, Name)
		CategoryEnabled := Map("Hotstrings", false)
		State["initialized"] := false
		MasterGateInitialize(Features, Map("keys", Map()), (*) => false)
		Cleaner := Menu()
		try Cleaner.Delete()
		finally MenuDispatcher_PruneMenu(Cleaner)
		Tables := [_MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatchTokens,
			_MenuDispatchClickSequences, _MenuDispatchOwnerHandles], Before := []
		for Table in Tables
			Before.Push(Table.Clone())
		LeafKey := "hotstring_personal_default_choice"
		Assert(Root.Has(LeafKey), "the genuine generated leaf declaration exists")
		Originals[LeafKey] := Root[LeafKey]
		NativeChoice := _MR_FindItemById(LeafKey, "personal_default_section")
		Assert(NativeChoice is Map, "the genuine leaf has its unique native-visible owner")
		Rows := ReadRows()
		Assert(Rows is Array && Rows.Length == 1 && Owned.Length == 1)
		LivePersonal := Owned[1], DefaultCaption := t("menu.hotstrings.default_category_prefix") . "beta"
		LiveDefault := false
		loop TrayMenuItemCount(LivePersonal) {
			if _MUR_LabelAt(LivePersonal, A_Index - 1) == DefaultCaption {
				ChildHandle := DllCall("GetSubMenu", "ptr", LivePersonal.Handle, "int", A_Index - 1, "ptr")
				Assert(ChildHandle != 0)
				LiveDefault := MenuFromHandle(ChildHandle)
				break
			}
		}
		Assert(LiveDefault is Menu)
		Labels := _HS_BuildDisambiguatedSectionLabels(ReadPersonalToml())
		AlphaId := 0, AlphaCallback := false, LiveFlags := []
		loop TrayMenuItemCount(LiveDefault) {
			Flags := DllCall("GetMenuState", "ptr", LiveDefault.Handle, "uint", A_Index - 1, "uint", 0x400, "uint")
			Assert(Flags != 0xFFFFFFFF)
			LiveFlags.Push(Flags)
			if _MUR_LabelAt(LiveDefault, A_Index - 1) == Labels["alpha"] {
				AlphaId := DllCall("GetMenuItemID", "ptr", LiveDefault.Handle, "int", A_Index - 1, "uint")
				Assert(_MenuDispatchCallbacks.Has(AlphaId))
				AlphaCallback := _MenuDispatchCallbacks[AlphaId]
			}
		}
		Assert(HasMethod(AlphaCallback, "Call"))
		LiveTables := []
		for Table in Tables
			LiveTables.Push(Table.Clone())
		BeforeSource := FSReadUtf8Exact(Fixture.path), BeforeCaption := _PrevDefaultLabel
		Changed := []
		if Kind != "missing" {
			ChangedRow := NativeChoice.Clone()
			if Kind == "kind"
				ChangedRow["type"] := "label"
			else
				ChangedRow["caption_getter"] := "unavailable_default_caption"
			for OriginalChoice in Originals[LeafKey]
				Changed.Push(OriginalChoice == NativeChoice ? ChangedRow : OriginalChoice)
		}
		Root[LeafKey] := Changed
		Refused := ReadRows()
		Assert(Refused is Array && Refused.Length == 0, "a refused choice source cannot hand off a partial personal menu")
		AssertEqual(1, Owned.Length, "only the earlier complete caller-owned parent survives")
		for Index, Table in Tables {
			AssertEqual(LiveTables[Index].Count, Table.Count, "all newly refused menus are disposed and pruned")
			for Id, Callback in LiveTables[Index]
				Assert(Table.Has(Id) && Table[Id] == Callback, "earlier actual native dispatcher owners remain exact")
		}
		AssertEqual(BeforeSource, FSReadUtf8Exact(Fixture.path))
		AssertEqual(BeforeCaption, _PrevDefaultLabel)
		if Kind == "missing" {
			AssertFalse(AlphaCallback.Call(), "a retained actual choice refuses before the original writer when its declaration is absent")
			AssertEqual(BeforeSource, FSReadUtf8Exact(Fixture.path))
			AssertEqual("beta", _EditorPrefGet("DefaultSection", ""))
			loop TrayMenuItemCount(LiveDefault)
				AssertEqual(LiveFlags[A_Index], DllCall("GetMenuState", "ptr", LiveDefault.Handle, "uint", A_Index - 1, "uint", 0x400, "uint"))
		}
		Root[LeafKey] := Originals[LeafKey]
		AssertEqual(1, ReadRows().Length, "exact declaration repair restores the actual native provider")
		AlphaCallback.Call()
		AssertEqual("alpha", _EditorPrefGet("DefaultSection", ""), "the retained original writer publishes through genuine native preference IO")
		Assert(InStr(FSReadUtf8Exact(Fixture.path), 'keep = "personal-frame-source"'))
		AssertTrue(_MenuDispatchCallbacks.Has(AlphaId) && _MenuDispatchCallbacks[AlphaId] == AlphaCallback)

	} finally {
		try ReleaseRows()
		finally {
			for Key, Original in Originals
				Root[Key] := Original
			ScriptInformation := SavedInfo, Features := SavedFeatures, CategoryEnabled := SavedCategories
			ConfigurationFile := IsSet(SavedConfig) ? SavedConfig : unset
			_ReadPersonalTomlCache := SavedCache, _TomlUnreadableFiles := SavedUnreadable
			_PersonalExtTree := IsSet(SavedTree) ? SavedTree : unset
			_FmtCountCache := IsSet(SavedCounts) ? SavedCounts : unset
			_PrevDefaultLabel := IsSet(SavedDefaultLabel) ? SavedDefaultLabel : unset
			State.Clear()
			for Key, Value in SavedState
				State[Key] := Value
			try FileDelete(PersonalPath)
			_ScopeOwnerCleanup(Fixture)
		}
	}
}
for _HSCS_DefaultChoiceKind in ["missing", "kind", "caption"]
	Test("shared-personal-default-choice: native source refusal and exact repair " . _HSCS_DefaultChoiceKind,
		_HSCS_DefaultChoiceSourceReceiving.Bind(_HSCS_DefaultChoiceKind))
