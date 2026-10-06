; tests/unit/test_personal_file_controls.ahk

; ==============================================================================
; MODULE: Additional Personal TOML Native Controls Tests
; DESCRIPTION:
; Actual discovery, registration, preview and scoped publication; the replacement
; launch alone is injected. Generic provenance-only loader assertions stay intact.
; ==============================================================================

_PFC_Fixture(FixtureRootSpelling := "temp") {
	global ScriptInformation, ConfigurationFile, _HotstringRegistrar, CategoryEnabled
	if FixtureRootSpelling != "temp" && FixtureRootSpelling != "long" && FixtureRootSpelling != "dot"
		throw ValueError("Unknown fixture native root spelling")
	Fixture := _ScopeOwnerFixture()
	Fixture.savedInfo := ScriptInformation, Fixture.savedConfig := ConfigurationFile
	Fixture.savedOwners := PersonalFileControls.owners, Fixture.savedInventory := PersonalFileControls.inventory
	Fixture.savedRegistrar := _HotstringRegistrar, Fixture.savedGate := CategoryEnabled["Hotstrings"]
	Fixture.root := Fixture.directory . "\hotstrings"
	DirCreate(Fixture.root)
	try {
		if FixtureRootSpelling == "long"
			Fixture.root := FSResolveDirectoryPath(Fixture.root)
		else if FixtureRootSpelling == "dot"
			Fixture.root := Fixture.directory . "\.\hotstrings"
	} catch as RootResolutionError {
		_ScopeOwnerCleanup(Fixture)
		throw RootResolutionError
	}
	Fixture.file := Fixture.root . "\a__b.toml"
	Fixture.descriptor := PersonalFileDescribe(["a__b.toml"])
	Fixture.content := '[[live]]`n"abcd" = "first"`n[[quiet]]`n"qwer" = "second"`n'
		. '[_meta]`ndelay = 0.25`npriority = 61`ncolor = "123456"`nunknown = "keep"`n'
		. '[_meta.sections.live]`ndelay = 0.5`npriority = 67`nshow_tooltip = false`n'
	Assert(FSWriteDurable(Fixture.file, Fixture.content))
	Fixture.source := '[category_enabled]`nhotstrings = true`n[private]`ncredential = "keep"`n'
		. '[hotstrings.modules.' . TOML_RenderKey(Fixture.descriptor["id"]) . ']`nquiet = false`n'
	Assert(FSWriteDurable(Fixture.path, Fixture.source))
	ScriptInformation := Fixture.savedInfo.Clone()
	ScriptInformation["PersonalHotstringsDir"] := Fixture.root
	ScriptInformation["PersonalTomlPath"] := Fixture.root . "\personal_hotstrings.toml"
	ConfigurationFile := Fixture.path
	CategoryEnabled["Hotstrings"] := true
	_HotstringRegistrar := 0
	HSE_RegistryClear()
	PersonalFileControls.Refresh()
	Fixture.owner := PersonalFileControls.owners[Fixture.descriptor["id"]]
	return Fixture
}

_PFC_Cleanup(Fixture) {
	global ScriptInformation, ConfigurationFile, _HotstringRegistrar, CategoryEnabled
	ScriptInformation := Fixture.savedInfo, ConfigurationFile := Fixture.savedConfig
	PersonalFileControls.owners := Fixture.savedOwners, PersonalFileControls.inventory := Fixture.savedInventory
	_HotstringRegistrar := Fixture.savedRegistrar, CategoryEnabled["Hotstrings"] := Fixture.savedGate
	HSE_RegistryClear()
	HSE_FeedReset(true)
	_ScopeOwnerCleanup(Fixture)
}

_PFC_AdoptionVector(Vector) {
	Before := KL_JsonEncode(Vector["candidates"])
	Result := PersonalScopePlanAdoption(Vector["candidates"])
	AssertEqual(KL_JsonEncode(Vector["expected"]), KL_JsonEncode(Result))
	AssertEqual(Before, KL_JsonEncode(Vector["candidates"]))
	for Index, Record in Result {
		Assert(Record["source"] != Vector["candidates"][Index]["source"])
		AssertEqual(30, _HSE_SourcePriority(Record["owner"]))
	}
}
for _PFC_Vector in JsonParse(FileRead(_SharedDir . "\tests\corpus\hotstrings\personal_file_adoption.json", "UTF-8"))["vectors"]
	Test("personal-file-adoption: " . _PFC_Vector["name"], _PFC_AdoptionVector.Bind(_PFC_Vector))

_PFC_NativeRegistrationAndPreview() {
	global HSE_RegistryByGroup
	Fixture := _PFC_Fixture()
	try {
		AssertEqual(1, LoadExtTomlFile(Fixture.file, "a__b", "", Fixture.descriptor, Fixture.owner))
		AssertEqual(1, HSE_RegistryByGroup.Count)
		AssertEqual(1, PersonalFileControls.ActiveCount())
		Specs := HSE_RegistryByGroup[Fixture.descriptor["id"] . ".live"]
		AssertEqual(3, Specs.Length)
		for Spec in Specs {
			AssertEqual(Fixture.descriptor["id"], Spec.Category)
			AssertEqual("live", Spec.Section)
			AssertEqual(0.5, Spec.TimeActivationSeconds)
			AssertEqual(67, Spec.Priority)
			AssertEqual(Fixture.descriptor["id"], Spec.PersonalSource["id"])
		}
		Index := Map(), TriggerSet := Map()
		PersonalFileControls.BuildPreview(Index, TriggerSet)
		Assert(TriggerSet.Has("abcd"))
		Assert(!TriggerSet.Has("qwer"), "a disabled section must not reach the actual preview route")
		AssertEqual(67, TriggerSet["abcd"].Priority)
		Resolved := HotstringsResolve(Fixture.descriptor["id"], "live")
		AssertEqual(false, Resolved.ShowTooltip)
		AssertEqual("123456", Resolved.Color)
		AssertEqual(Fixture.file, HotstringsBundledTomlPath(Fixture.descriptor["id"]))
		HSE_RegistryClear()
		Assert(FSWriteDurable(Fixture.path, Fixture.source . '[hotstrings.groups]`n'
			. TOML_RenderKey(Fixture.descriptor["id"]) . ' = false`n'))
		PersonalFileControls.Refresh()
		Current := PersonalFileControls.owners[Fixture.descriptor["id"]]
		AssertEqual(0, LoadExtTomlFile(Fixture.file, "a__b", "", Fixture.descriptor, Current))
		AssertEqual(0, HSE_RegistryByGroup.Count)
		AssertEqual(0, PersonalFileControls.ActiveCount())
		Assert(Current.Selected("live"), "disabling a file retains its independent section choice")
		Index := Map(), TriggerSet := Map()
		PersonalFileControls.BuildPreview(Index, TriggerSet)
		AssertEqual(0, TriggerSet.Count)
		Assert(!Fixture.owner.Authorize(Fixture.file, Fixture.descriptor), "old generation capabilities refuse")
	} finally _PFC_Cleanup(Fixture)
}
Test("personal-file-controls: real runtime and preview share independent gates metadata and native IDs", _PFC_NativeRegistrationAndPreview)

_PFC_SourceCohortMutationRefuses() {
	Fixture := _PFC_Fixture()
	Launches := 0, Backups := 0
	Foreign := Fixture.content . "# externally edited after cohort planning`n"
	Backup(Path, Content) {
		Backups += 1
		if Backups == 1
			Assert(FSWriteDurable(Fixture.file, Foreign))
		return FSWriteCreateDurable(Path, Content)
	}
	Launch(*) {
		Launches += 1
		return false
	}
	Fixture.options["backup"] := Backup
	Fixture.options["reload"] := Launch
	try {
		Rows := _HS_PersonalFileControlRows(Fixture.owner, "", Fixture.options)
		Receipt := (Rows[1]["action"])()
		AssertEqual("refused", Receipt["status"])
		AssertEqual(0, Launches)
		AssertEqual(2, Backups, "the unchanged source must remain a guarded cohort member")
		AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
		AssertEqual(Foreign, FSReadUtf8Exact(Fixture.file), "foreign source bytes are retained")
		Assert(Fixture.owner.Enabled("live"), "refused publication keeps old runtime choices")
		Assert(PersonalFileControls.IsCurrent(Fixture.owner))
		Assert(!_ConfigWriteTerminalIsActive(), "ordinary precondition refusal leaves no cleanup debt")
	} finally _PFC_Cleanup(Fixture)
}
Test("personal-file-controls: menu gate refuses an external source edit during cohort publication", _PFC_SourceCohortMutationRefuses)

_PFC_MetadataRoundTrip() {
	Fixture := _PFC_Fixture()
	Borrowed := 0, Refusal := 0
	Launch(_Success, Bundle, Refused) {
		Borrowed := Bundle, Refusal := Refused
		return true
	}
	Fixture.options["reload"] := Launch
	try {
		Receipt := Fixture.owner.Commit("live", "priority", 71, Fixture.options)
		AssertEqual("pending", Receipt["status"])
		Changed := FSReadUtf8Exact(Fixture.file)
		AssertContains(Changed, 'priority = 71')
		AssertContains(Changed, '"abcd" = "first"')
		AssertContains(Changed, '"qwer" = "second"')
		AssertContains(Changed, 'unknown = "keep"')
		AssertEqual(67, Fixture.owner.Resolve("live").Priority, "old runtime stays committed until handoff")
		Refusal.Call("native replacement refused")
		AssertEqual("refused", Receipt["status"])
		AssertEqual(Fixture.content, FSReadUtf8Exact(Fixture.file))
		AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
		Patched := Fixture.owner.PatchMetadata("é.foo", "show_tooltip", false, Fixture.content)
		AssertContains(Patched, '[_meta.sections."é.foo"]')
		AssertEqual(false, Fixture.owner.ReadMetadata(Patched).Sections["é.foo"].ShowTooltip)
	} finally {
		if Borrowed is Object
			_ConfigWriteTerminalRelease(Borrowed)
		_PFC_Cleanup(Fixture)
	}
}
Test("personal-file-controls: exact source metadata and quoted sections survive native handoff refusal", _PFC_MetadataRoundTrip)

_PFC_CollidingLegacyNamesAndPhysicalAliases() {
	global HSE_RegistryByGroup, ScriptInformation
	Fixture := _PFC_Fixture()
	Nested := Fixture.root . "\a"
	DirCreate(Nested)
	Other := Nested . "\b.toml"
	Assert(FSWriteDurable(Other, '[[live]]`n"other" = "distinct"`n'))
	try {
		PersonalFileControls.Refresh()
		NestedId := "personal-file:61:622e746f6d6c"
		Assert(PersonalFileControls.owners.Has(Fixture.descriptor["id"]))
		Assert(PersonalFileControls.owners.Has(NestedId))
		OtherOwner := PersonalFileControls.owners[NestedId]
		AssertEqual(0, OtherOwner.Resolve("live").Delay, "historical whole-file packs retain zero delay")
		AssertEqual(30, OtherOwner.Resolve("live").Priority)
		Assert(OtherOwner.Enabled("live"), "the flat file's disabled sibling section never disables a nested file")
		Primary := Fixture.root . "\personal_hotstrings.toml"
		Assert(FSWriteDurable(Primary, '[[primary]]`n"primary" = "owned elsewhere"`n'))
		Alias := Fixture.root . "\alias.toml"
		AssertEqual(1, DllCall("CreateHardLinkW", "wstr", Alias, "wstr", Primary, "ptr", 0),
			"the native physical alias fixture requires a real NTFS hard link")
		AssertEqual(PersonalFileControls.Physical(Primary), PersonalFileControls.Physical(Alias))
		PersonalFileControls.Refresh()
		Assert(!PersonalFileControls.ForPath(Alias), "an additional alias of the primary source cannot gain scoped controls")
		Assert(PersonalFileControls.ForPath(Other) is PersonalFileAdoptedOwner,
			"refusing an unrelated alias retains the uniquely owned nested source")
	} finally _PFC_Cleanup(Fixture)
}
Test("personal-file-controls: flattened names retain distinct package owners and real primary aliases refuse", _PFC_CollidingLegacyNamesAndPhysicalAliases)

_PFC_NeutralProjectionIsNotAdmission() {
	Group := 'hotstrings.groups."personal-file:632e746f6d6c"'
	Section := 'hotstrings.modules."personal-file:632e746f6d6c"."é.foo"'
	AssertEqual(true, ManifestDefaultFor(Group))
	AssertEqual(true, ManifestDefaultFor(Section))
	AssertEqual("", PersonalFilePreferenceDefault('hotstrings.groups."personal-file:632e746F6d6c"'))
	AssertEqual("", PersonalFilePreferenceDefault("hotstrings.modules.personal-file:632e746f6d6c.é.foo"))
	AssertEqual("", PersonalFilePreferenceDefault('hotstrings.modules."personal-file:632e746f6d6c".""'))
	AssertEqual(false, ManifestDefaultFor("hotstrings.groups.foreign"), "unrelated dynamic groups keep their neutral baseline")
	Enable := ManifestSparseOperation(Group, true)
	Assert(Enable.HasOwnProp("Delete") && Enable.Delete == 1)
	Disable := ManifestSparseOperation(Section, false)
	Assert(!Disable.HasOwnProp("Delete"), "explicit false must persist for an additional-file defaulttrue gate")
	AssertEqual('hotstrings.modules."personal-file:632e746f6d6c"', Disable.Section)
	AssertEqual("é.foo", Disable.Key, "a dotted quoted section remains one preference key")
	AssertEqual(false, Disable.Value)
	Assert(!PersonalFileControls.owners.Has("personal-file:632e746f6d6c"), "policy classification must not create an activation capability")
}
Test("personal-file-controls: canonical sparse neutral paths preserve Boolean false and quoted sections", _PFC_NeutralProjectionIsNotAdmission)

_PFC_FreshReceiptRefusesCachedAmbiguityAndUnreadability() {
	Fixture := _PFC_Fixture(), Lock := 0
	try {
		AssertEqual(Fixture.content, ReadTomlFile(Fixture.file), "prime the independent historical content cache")
		Ambiguous := '[[Live]]`n"abcd" = "first"`n[[live]]`n"qwer" = "second"`n'
		Assert(FSWriteDurable(Fixture.file, Ambiguous))
		AssertEqual(Fixture.content, ReadTomlFile(Fixture.file), "the native legacy cache deliberately remains stale")
		PersonalFileControls.Refresh()
		Assert(!PersonalFileControls.ForPath(Fixture.file), "fresh ambiguous section owners must never gain a capability")
		AssertEqual("ambiguous-section-owner", PersonalFileControls.inventory[1]["reason"])
		Assert(FSWriteDurable(Fixture.file, Fixture.content))
		Record := PersonalFileControls.Scan()[1]
		Assert(FSWriteDurable(Fixture.file, Ambiguous))
		Refused := false
		try PersonalFileAdoptedOwner(Record, TOML_ParseFreshFileTyped(Fixture.path))
		catch
			Refused := true
		Assert(Refused, "constructor refuses an edit after the exact admitted discovery receipt")
		Assert(FSWriteDurable(Fixture.file, Fixture.content))
		Lock := DllCall("CreateFileW", "wstr", Fixture.file, "uint", 0x80000000,
			"uint", 0, "ptr", 0, "uint", 3, "uint", 0x80, "ptr", 0, "ptr")
		Assert(Lock && Lock != -1, "the native unreadability fixture requires an exclusive real file handle")
		PersonalFileControls.Refresh()
		Assert(!PersonalFileControls.ForPath(Fixture.file), "cached readable contents do not authorize a now unreadable source")
		AssertEqual("unreadable-source", PersonalFileControls.inventory[1]["reason"])
	} finally {
		if Lock && Lock != -1
			DllCall("CloseHandle", "ptr", Lock)
		_PFC_Cleanup(Fixture)
	}
}
Test("personal-file-controls: exact fresh source receipts refuse cache ambiguity races and unreadability", _PFC_FreshReceiptRefusesCachedAmbiguityAndUnreadability)

_PFC_BomFirstSectionAndRollback() {
	Fixture := _PFC_Fixture(), Borrowed := 0, Refusal := 0
	Launch(_Success, Bundle, Refused) {
		Borrowed := Bundle, Refusal := Refused
		return true
	}
	try {
		Fixture.content := Chr(0xFEFF) . Fixture.content
		Assert(FSWriteDurable(Fixture.file, Fixture.content))
		PersonalFileControls.Refresh()
		Current := PersonalFileControls.ForPath(Fixture.file)
		Assert(Current is PersonalFileAdoptedOwner)
		AssertEqual(Fixture.content, Current.content, "exact ownership preserves the UTF-8 BOM")
		AssertEqual(1, LoadExtTomlFile(Fixture.file, "a__b", "", Fixture.descriptor, Current))
		Index := Map(), TriggerSet := Map()
		PersonalFileControls.BuildPreview(Index, TriggerSet)
		Assert(TriggerSet.Has("abcd"), "the first BOM-prefixed section reaches actual native registration and preview")
		AssertEqual(1, Current.ActiveCount())
		Fixture.options["reload"] := Launch
		Receipt := Current.Commit("live", "priority", 71, Fixture.options)
		AssertEqual("pending", Receipt["status"])
		AssertEqual(Chr(0xFEFF), SubStr(FSReadUtf8Exact(Fixture.file), 1, 1))
		Refusal.Call("native replacement refused")
		AssertEqual("refused", Receipt["status"])
		AssertEqual(Fixture.content, FSReadUtf8Exact(Fixture.file), "rollback retains the exact BOM-bearing source receipt")
		AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
	} finally {
		if Borrowed is Object
			_ConfigWriteTerminalRelease(Borrowed)
		_PFC_Cleanup(Fixture)
	}
}
Test("personal-file-controls: BOM first section loads and exact metadata rollback preserves BOM bytes", _PFC_BomFirstSectionAndRollback)

_PFC_MalformedSourcesNeverAcquireControls() {
	Fixture := _PFC_Fixture()
	try {
		for Invalid in ['[[live]]`nnot an assignment`n', '[[live]`n"abcd" = "first"`n'] {
			Assert(FSWriteDurable(Fixture.file, Invalid))
			PersonalFileControls.Refresh()
			Assert(!PersonalFileControls.ForPath(Fixture.file), "a native parser's silent skip is never metadata ownership")
			AssertEqual("malformed-source", PersonalFileControls.inventory[1]["reason"])
			AssertEqual(Invalid, FSReadUtf8Exact(Fixture.file))
		}
	} finally _PFC_Cleanup(Fixture)
}
Test("personal-file-controls: opaque or malformed physical records remain read-only", _PFC_MalformedSourcesNeverAcquireControls)

_PFC_DirectoryCycleAndDepthRefuse() {
	global _HS_PreScanPersonalCacheLoaded, _PersonalExtTree, _ExtTotalPersonalCounterGlobal
	global _ParseExtTomlSectionsCache
	Fixture := _PFC_Fixture(), Cycle := Fixture.root . "\cycle"
	SavedLoaded := _HS_PreScanPersonalCacheLoaded, SavedTree := _PersonalExtTree
	SavedCount := _ExtTotalPersonalCounterGlobal.value
	HadSectionsCache := IsSet(_ParseExtTomlSectionsCache)
	SavedSectionsCache := HadSectionsCache ? _ParseExtTomlSectionsCache : 0
	try {
		AssertEqual(16, PersonalFileScanMaxDepth())
		Assert(HS_PersonalDirectoryAdmitted(Fixture.root, 1))
		Assert(!HS_PersonalDirectoryAdmitted(Fixture.root, 17), "native discovery and menus use the same bounded depth")
		ExitCode := RunWait('"' . A_ComSpec . '" /D /C mklink /J "' . Cycle . '" "' . Fixture.root . '"', , "Hide")
		AssertEqual(0, ExitCode, "the cycle fixture requires a real native directory junction")
		Assert(!HS_PersonalDirectoryAdmitted(Cycle, 2), "a directory junction cannot acquire recursive ownership")
		Packs := HS_EnumeratePersonalExtFiles()
		AssertEqual(1, Packs.Length, "the native registration/recheck walk terminates without cycle aliases")
		PersonalFileControls.Refresh()
		Assert(PersonalFileControls.ForPath(Fixture.file) is PersonalFileAdoptedOwner)
		; The tray owns this cache at boot; the headless fixture owns its snapshot.
		_ParseExtTomlSectionsCache := Map()
		_HS_PreScanPersonalCacheLoaded := false
		_HS_PreScanPersonal()
		Assert(_PersonalExtTree["cycle"]["unavailable"], "the real menu retains a read-only reason for a skipped directory")
	} finally {
		if DirExist(Cycle)
			DirDelete(Cycle)
		_HS_PreScanPersonalCacheLoaded := SavedLoaded, _PersonalExtTree := SavedTree
		_ExtTotalPersonalCounterGlobal.value := SavedCount
		if HadSectionsCache
			_ParseExtTomlSectionsCache := SavedSectionsCache
		else
			_ParseExtTomlSectionsCache := unset
		_PFC_Cleanup(Fixture)
	}
}
Test("personal-file-controls: real junction cycles are bounded and represented as unavailable menu folders", _PFC_DirectoryCycleAndDepthRefuse)

_PFC_UnreadablePrimaryReservationRefuses() {
	Fixture := _PFC_Fixture(), Lock := 0
	Primary := Fixture.root . "\personal_hotstrings.toml"
	PrimaryContent := '[[primary]]`n"primary" = "retained"`n'
	try {
		Assert(FSWriteDurable(Primary, PrimaryContent))
		Lock := DllCall("CreateFileW", "wstr", Primary, "uint", 0x80000000,
			"uint", 0, "ptr", 0, "uint", 3, "uint", 0x80, "ptr", 0, "ptr")
		Assert(Lock && Lock != -1)
		AssertThrows(() => PersonalFileControls.Refresh(), "an unreadable owned primary identity cannot silently disappear from alias admission")
		Assert(PersonalFileControls.IsCurrent(Fixture.owner), "a failed discovery retains its complete committed native capability generation")
		AssertEqual(Fixture.content, FSReadUtf8Exact(Fixture.file))
		AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
		DllCall("CloseHandle", "ptr", Lock)
		Lock := 0
		AssertEqual(PrimaryContent, FSReadUtf8Exact(Primary))
		PersonalFileControls.Refresh()
		Assert(PersonalFileControls.ForPath(Fixture.file) is PersonalFileAdoptedOwner, "the closed failed identity handle does not poison the next actual admission")
	} finally {
		if Lock && Lock != -1
			DllCall("CloseHandle", "ptr", Lock)
		_PFC_Cleanup(Fixture)
	}
}
Test("personal-file-controls: unreadable primary reservation refuses without partial capability publication", _PFC_UnreadablePrimaryReservationRefuses)

_PFC_PrefixedColorMatchesNativeDefaults() {
	Fixture := _PFC_Fixture()
	try {
		Launch(*) => false
		Fixture.options["reload"] := Launch
		Receipt := Fixture.owner.Commit("live", "color", "#123456", Fixture.options)
		AssertEqual("refused", Receipt["status"], "a valid prefixed native color reaches the real scoped owner before injected launch refusal")
		AssertEqual(Fixture.content, FSReadUtf8Exact(Fixture.file))
		AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
		AssertThrows(() => Fixture.owner.Commit("live", "color", "#12345Z", Fixture.options), "invalid hex never reaches publication")
	} finally _PFC_Cleanup(Fixture)
}
Test("personal-file-controls: native prefixed default colors are valid and exact launch refusal rolls back", _PFC_PrefixedColorMatchesNativeDefaults)

_PFC_DeclaredRowsAndStaleCallbackRefuse() {
	Fixture := _PFC_Fixture()
	try {
		Rows := _HS_PersonalFileControlRows(Fixture.owner, "live", Fixture.options)
		AssertEqual(5, Rows.Length, "the declared per-file menu exposes all five real native controls")
		ExpectedLabels := [t("menu.common.enabled"), t("hs_config.label_delay") . " : 500",
			t("hs_config.label_priority") . " : 67", t("hs_config.label_color") . " : 123456", t("hs_config.label_tooltip")]
		for Index, Expected in ExpectedLabels
			AssertEqual(Expected, Rows[Index]["label"], "fixed labels and order come from the shared declarations")
		AssertEqual(true, Rows[1]["checked"])
		AssertEqual(false, Rows[5]["checked"])
		PersonalFileControls.Refresh()
		AssertEqual(false, (Rows[1]["action"])(), "a retained declared provider callback refuses its stale capability before a scoped writer")
		AssertEqual(Fixture.content, FSReadUtf8Exact(Fixture.file))
		AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
		for Kind in ["file", "directory"] {
			Unavailable := _HS_PersonalUnavailableRow(Kind, "source-name")
			Assert(Unavailable is Map)
			AssertEqual(true, Unavailable["disabled"])
			Assert(!Unavailable.Has("action"), "shared refusal rows never retain an executable native command")
			AssertEqual("menu.hotstrings.personal_" . Kind . "_unavailable", Unavailable["disabled_reason_key"])
			AssertEqual("source-name — " . t("healthcheck.state.unavailable"), Unavailable["label"])
		}
	} finally _PFC_Cleanup(Fixture)
}
Test("personal-file-controls: declared native rows preserve order and stale callbacks refuse before publication", _PFC_DeclaredRowsAndStaleCallbackRefuse)

_PFC_BomFirstMetadataEditAndRollback() {
	Fixture := _PFC_Fixture(), Borrowed := 0, Refusal := 0
	Launch(_Success, Bundle, Refused) {
		Borrowed := Bundle, Refusal := Refused
		return true
	}
	try {
		Fixture.content := Chr(0xFEFF) . '[_meta]`ndelay = 0.25`npriority = 61`ncolor = "123456"`nunknown = "keep"`n'
			. '[_meta.sections.live]`ndelay = 0.5`npriority = 67`nshow_tooltip = false`n'
			. '[[live]]`n"abcd" = "first"`n[[quiet]]`n"qwer" = "second"`n'
		Expected := Chr(0xFEFF) . '[_meta]`ndelay = 0.25`npriority = 71`ncolor = "123456"`nunknown = "keep"`n'
			. '[_meta.sections.live]`ndelay = 0.5`npriority = 67`nshow_tooltip = false`n'
			. '[[live]]`n"abcd" = "first"`n[[quiet]]`n"qwer" = "second"`n'
		Assert(FSWriteDurable(Fixture.file, Fixture.content))
		PersonalFileControls.Refresh()
		Current := PersonalFileControls.ForPath(Fixture.file)
		Assert(Current is PersonalFileAdoptedOwner)
		AssertEqual(61, Current.Resolve().Priority)
		Fixture.options["reload"] := Launch
		Receipt := Current.Commit("", "priority", 71, Fixture.options)
		AssertEqual("pending", Receipt["status"], "the real source-first metadata header remains an addressable mutation owner")
		AssertEqual(Expected, FSReadUtf8Exact(Fixture.file), "the complete independent candidate preserves the original physical BOM header once")
		Document := TOML_ParseDocument(FSReadUtf8Exact(Fixture.file))
		AssertEqual(71, Document["_meta"]["priority"])
		AssertEqual("keep", Document["_meta"]["unknown"])
		AssertEqual(67, Current.Resolve("live").Priority, "old committed section choices survive pending metadata publication")
		AssertEqual(61, Current.Resolve().Priority, "old committed file choices survive pending metadata publication")
		Refusal.Call("native replacement refused")
		AssertEqual("refused", Receipt["status"])
		AssertEqual(Fixture.content, FSReadUtf8Exact(Fixture.file), "native handoff refusal restores all original BOM-bearing source bytes")
		AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
	} finally {
		if Borrowed is Object
			_ConfigWriteTerminalRelease(Borrowed)
		_PFC_Cleanup(Fixture)
	}
}
Test("personal-file-controls: first BOM metadata header remains owned through real edit and exact rollback", _PFC_BomFirstMetadataEditAndRollback)

/** The strict adapter preserves BOM-aware text and the real handle identity. */
_PFC_StrictReadAdapter() {
	Fixture := _PFC_Fixture()
	File := 0
	try {
		File := FSOpenReadStrict(Fixture.file)
		AssertTrue(IsObject(File), "the existing source acquires a real read handle")
		Snapshot := FSHandleSnapshot(File.Handle)
		AssertTrue(Snapshot.Get("ok", false), "the adapter exposes the original physical identity handle")
		AssertEqual(FSReadStrict(Fixture.file), File.Read(), "streamed UTF-8 keeps the same BOM-aware content")
	} finally {
		if IsObject(File)
			File.Close()
		_PFC_Cleanup(Fixture)
	}
}
Test("personal-file-controls: strict reader preserves source bytes and physical handle identity", _PFC_StrictReadAdapter)





; =============================================
; =============================================
; ======= 1/ Supplied native root route =======
; =============================================
; =============================================

_PFC_SuppliedRootRoute(RouteMode) {
	RouteFixture := _PFC_Fixture(RouteMode)
	try {
		RouteOwner := RouteFixture.owner
		AssertEqual(RouteFixture.file, RouteOwner.path,
			"native discovery must retain the caller-owned route spelling")
		AssertTrue(RouteOwner.Authorize(RouteFixture.file, RouteFixture.descriptor),
			"a discovered actual source must remain reachable through its original route")
		AssertEqual(RouteOwner, PersonalFileControls.ForPath(RouteFixture.file))
		RouteCanonicalFile := FSResolveDirectoryPath(RouteFixture.root) . "\a__b.toml"
		AssertEqual(PersonalFileControls.Physical(RouteCanonicalFile), RouteOwner.physical,
			"independent native long-path resolution must identify the same retained source")
		AssertEqual(1, LoadExtTomlFile(RouteFixture.file, "a__b", "", RouteFixture.descriptor, RouteOwner))
		AssertEqual(1, RouteOwner.ActiveCount())
		if RouteMode == "dot"
			AssertFalse(RouteCanonicalFile == RouteFixture.file,
				"the physical dot-route control must differ from the native canonical spelling")
	} finally _PFC_Cleanup(RouteFixture)
}
Test("personal-file-route: native long-root source retains exact loader and activation ownership",
	_PFC_SuppliedRootRoute.Bind("long"))
Test("personal-file-route: physically identical dot-root source retains its supplied logical route",
	_PFC_SuppliedRootRoute.Bind("dot"))
