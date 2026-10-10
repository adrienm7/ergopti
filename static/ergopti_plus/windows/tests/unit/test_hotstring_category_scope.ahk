; tests/unit/test_hotstring_category_scope.ahk

; ==============================================================================
; MODULE: Hotstring Category Selection Parity (Windows)
; DESCRIPTION:
; Replays the independent shared corpus through the native policy port. A
; refused scope cannot emit a partial batch, and every valid category/section
; choice matches both Lua drivers, including the extension's native replacement.
; ==============================================================================

_HSCS_CheckVector(Vector) {
	Inventory := Vector["inventory"]
	Targets := Vector["targets"].Clone()
	Before := Map()
	for Id, Sections in Inventory
		Before[Id] := Sections.Clone()
	Choices := HotstringsCategoryScopePlan(Inventory, Vector["targets"], Vector["enabled"], &Reason,
		Vector.Get("bound_sections", []))
	if Vector.Has("refusal") {
		AssertFalse(Choices, "no partial batch may escape a refusal")
		AssertEqual(Vector["refusal"], Reason)
	} else {
		Assert(Choices is Array, "a valid scope must produce its complete choice batch")
		AssertEqual("", Reason)
		Expected := Vector["expected"]
		AssertEqual(Expected.Length, Choices.Length)
		for Index, Want in Expected {
			Got := Choices[Index]
			AssertEqual(Want.Count, Got.Count, "every emitted field must belong to the corpus")
			for Key, Value in Want {
				Assert(Got.Has(Key), "the choice must contain " . Key)
				AssertEqual(Value, Got[Key])
			}
		}
	}
	AssertEqual(Targets.Length, Vector["targets"].Length)
	for Index, Id in Targets
		AssertEqual(Id, Vector["targets"][Index], "the caller's scope must remain unchanged")
	AssertEqual(Before.Count, Inventory.Count)
	for Id, Sections in Before {
		AssertEqual(Sections.Length, Inventory[Id].Length)
		for Index, Name in Sections
			AssertEqual(Name, Inventory[Id][Index], "the discovered catalogue must remain unchanged")
	}
}

; Registered individually so native CI names the exact cross-driver vector.
for _HSCS_Vector in JsonParse(FileRead(_SharedDir . "\tests\corpus\hotstrings\bulk_scope_vectors.json", "UTF-8"))["vectors"]
	Test("hotstring-category-scope: " . _HSCS_Vector["name"], _HSCS_CheckVector.Bind(_HSCS_Vector))

; Independent bound-leaf batches match the shared extension-selection contract.
_HSCS_BoundVector(Enabled) {
	Bindings := [Map("group", "magickey", "section", "replace"),
		Map("group", "magickey", "section", "repeat_corrections")]
	Expected := Enabled ? [Map("group", "rolls", "enabled", true),
		Map("group", "rolls", "section", "hc", "enabled", true),
		Map("group", "magickey", "enabled", true),
		Map("group", "magickey", "section", "replace", "enabled", true),
		Map("group", "magickey", "section", "repeat_corrections", "enabled", true)]
		: [Map("group", "magickey", "section", "replace", "enabled", false),
		Map("group", "magickey", "section", "repeat_corrections", "enabled", false)]
	_HSCS_CheckVector(Map("inventory", Map("rolls", ["hc"],
		"magickey", ["replace", "repeat_corrections", "symbols"]),
		"targets", Enabled ? ["rolls"] : [], "enabled", Enabled,
		"bound_sections", Bindings, "expected", Expected))
	AssertEqual(2, Bindings.Length)
	AssertEqual("replace", Bindings[1]["section"], "the bound catalogue remains unchanged")
}
for _HSCS_Enabled in [true, false]
	Test("hotstring-extension-scope: exact bound batch " . _HSCS_Enabled, _HSCS_BoundVector.Bind(_HSCS_Enabled))

_HSCS_BoundRefusal(Bound, ExpectedReason) {
	_HSCS_CheckVector(Map("inventory", Map("magickey", ["replace"]), "targets", [],
		"enabled", true, "bound_sections", Bound, "refusal", ExpectedReason))
}
Test("hotstring-extension-scope: missing native category refuses without a partial batch",
	_HSCS_BoundRefusal.Bind([Map("group", "missing", "section", "replace")], "unknown-category"))
Test("hotstring-extension-scope: missing section refuses without a partial batch",
	_HSCS_BoundRefusal.Bind([Map("group", "magickey", "section", "missing")], "invalid-section"))
Test("hotstring-extension-scope: duplicate bound section refuses without a partial batch",
	_HSCS_BoundRefusal.Bind([Map("group", "magickey", "section", "replace"),
		Map("group", "magickey", "section", "replace")], "invalid-section"))
Test("hotstring-extension-scope: malformed bound scope refuses without a partial batch",
	_HSCS_BoundRefusal.Bind(false, "invalid-request"))

_HSCS_DenseAndOverlappingBindings() {
	Hole := [], Hole.Length := 1
	AssertFalse(HotstringsCategoryScopePlan(Map("magickey", ["replace"]), Hole, true, &Reason))
	AssertEqual("invalid-request", Reason)
	AssertFalse(HotstringsCategoryScopePlan(Map("magickey", ["replace"]), [], true, &Reason, Hole))
	AssertEqual("invalid-request", Reason)
	AssertFalse(HotstringsCategoryScopePlan(Map("magickey", Hole), [], true, &Reason,
		[Map("group", "magickey", "section", "replace")]))
	AssertEqual("unknown-category", Reason)
	_HSCS_CheckVector(Map("inventory", Map("magickey", ["replace"]),
		"targets", ["magickey"], "enabled", true,
		"bound_sections", [Map("group", "magickey", "section", "replace")],
		"expected", [Map("group", "magickey", "enabled", true),
			Map("group", "magickey", "section", "replace", "enabled", true)]))
}
Test("hotstring-extension-scope: dense arrays and overlapping ownership retain strict validation",
	_HSCS_DenseAndOverlappingBindings)

; Real shipped discovery and native menu dispatch, with only replacement launch
; injected. No installed layout record is needed to select the Ergopti pack.
_HSCS_ExtensionMenuOwner(Enabled, LateRefusal, Paused := false) {
	_HSCS_WithDynamicBootState(Boot)
	Boot() {
		global Features, CategoryEnabled, HotstringCategoriesStd, HotstringCategoriesErgopti, SubMenus
		global _HS_ExtensionsCacheLoaded, _HS_ExtensionsCache, _LegacyTopCategoryMap, HS_LANGUAGE_GATE_KEYS
		global _FLAT_HOTSTRING_V1_CATS
		HadFlatCategories := IsSet(_FLAT_HOTSTRING_V1_CATS)
		SavedFlatCategories := HadFlatCategories ? _FLAT_HOTSTRING_V1_CATS : 0
		global _FmtCountCache, _MenuDispatchCallbacks
		SavedCategories := CategoryEnabled, SavedStd := IsSet(HotstringCategoriesStd) ? HotstringCategoriesStd : unset
		SavedErgopti := IsSet(HotstringCategoriesErgopti) ? HotstringCategoriesErgopti : unset
		SavedMenus := IsSet(SubMenus) ? SubMenus : unset
		SavedCache := [_HS_ExtensionsCacheLoaded, _HS_ExtensionsCache], SavedLanguageKeys := HS_LANGUAGE_GATE_KEYS
		SavedCounts := IsSet(_FmtCountCache) ? _FmtCountCache : unset, SavedSuspend := A_IsSuspended
		State := MasterGateState(), SavedState := State.Clone()
		Fixture := _ScopeOwnerFixture(), Built := 0, Bundle := 0, Refusal := 0, Launches := 0, OwnedMenus := Map()
		InitialChoice := Enabled ? "false" : "true"
		Fixture.source := '[category_enabled]`nhotstrings = false`nmagic_key = ' . InitialChoice . '`n'
			. 'rolls = ' . InitialChoice . '`ndistances_reduction = ' . InitialChoice . '`n'
			. 'sfbs_reduction = ' . InitialChoice . '`nfrench_distancesreduction = ' . InitialChoice . '`n'
			. '[hotstrings.magic_key.replace]`nenabled = ' . InitialChoice . '`n'
			. '[hotstrings.magic_key.repeat_corrections]`nenabled = ' . InitialChoice . '`n'
			. '[hotstrings.magic_key.text_expansion_symbols]`nenabled = true`n'
			. '[hotstrings.magic_key.text_expansion_symbols_typst]`nenabled = true`n'
			. '[private]`ncredential = "retain-extension-fixture"`n'
		Launch(_Success, Borrowed, Refused) {
			Launches += 1, Bundle := Borrowed, Refusal := Refused
			return LateRefusal
		}
		Fixture.options["reload"] := Launch
		Fixture.options["roots"] := (*) => [_LCT_RegistryDir()]
		try {
			Suspend(false)
			Fixture.source := _CMJFixtureCurrentSource(Fixture.source)
			Assert(FSWriteDurable(Fixture.path, Fixture.source))
			ApplyConfigToml(Features, Fixture.path)
			CategoryEnabled := Map("Hotstrings", false, "MagicKey", !Enabled)
			HS_LANGUAGE_GATE_KEYS := Map()
			HotstringsSeedLanguageCategoryGates(CategoryEnabled)
			_FLAT_HOTSTRING_V1_CATS := []
			_HS_RegisterLanguageMenuCategories()
			State["initialized"] := false
			MasterGateInitialize(Features, Map("keys", Map()), (*) => false)
			Groups := MenuManifest_LoadHotstringGroups()
			HotstringCategoriesStd := Groups.standard, HotstringCategoriesErgopti := Groups.ergopti
			SubMenus := OwnedMenus, _FmtCountCache := Map()
			for Category in HotstringCategoriesErgopti
				SubMenus[Category] := Menu()
			_EHX_WithRoutes(_LCT_RegistryDir(), Check)
		} finally {
			_FLAT_HOTSTRING_V1_CATS := HadFlatCategories ? SavedFlatCategories : unset
			Suspend(SavedSuspend)
			if Built is Menu
				_CTC_ReleaseMenu(Built)
			for Owned in OwnedMenus
				_CTC_ReleaseMenu(OwnedMenus[Owned])
			if Bundle is Object
				_ConfigWriteTerminalRelease(Bundle)
			CategoryEnabled := SavedCategories, HotstringCategoriesStd := IsSet(SavedStd) ? SavedStd : unset
			HotstringCategoriesErgopti := IsSet(SavedErgopti) ? SavedErgopti : unset
			SubMenus := IsSet(SavedMenus) ? SavedMenus : unset
			_HS_ExtensionsCacheLoaded := SavedCache[1], _HS_ExtensionsCache := SavedCache[2]
			HS_LANGUAGE_GATE_KEYS := SavedLanguageKeys, _FmtCountCache := IsSet(SavedCounts) ? SavedCounts : unset
			State.Clear()
			for Key, Value in SavedState
				State[Key] := Value
			_ScopeOwnerCleanup(Fixture)
		}
		Check(Packs) {
			global _HS_ExtensionsCache, _HS_ExtensionsCacheLoaded
			_HS_ExtensionsCache := Packs, _HS_ExtensionsCacheLoaded := true
			Rows := _HS_ExtensionRows(Fixture.options), ErgoptiRows := false
			for Row in Rows {
				if InStr(Row["label"], StrReplace(t("menu.extensions.hotstrings_of"), "%s", "Ergopti+")) == 1
					ErgoptiRows := Row["items"]
			}
			Assert(ErgoptiRows is Array, "the shipped pack is present without installing its layout")
			Built := Menu()
			Assert(MenuRenderer_AppendRows(Built, "hotstrings_menu", "hotstring_personal_ext", ErgoptiRows) > 2)
			AssertEqual(0, CountTomlSection("magickey", "replace"), "the real native replacement is a metadata-only section")
			AssertEqual(24, CountTomlSection("french_distancesreduction", "suffixes_a"))
			ReplacementLabel := MenuLabelFromDescriptionKey("menu.hotstrings.magic_key.replace", "hotstrings.magic_key.replace")
			AssertEqual(1, _CTC_CountLabel(Built, ReplacementLabel), "the localized native replacement row belongs to the shipped extension")
			CommandLabel := t(Enabled ? "menu.hotstrings.scope_enable_all" : "menu.hotstrings.scope_disable_all")
			AssertEqual(1, _CTC_CountLabel(Built, CommandLabel), "one actual extension command owns the entire selection")
			Action := _L4M_MenuAction(Built, CommandLabel)
			if Paused
				Suspend(true)
			Receipt := Action.Call()
			if Paused {
				AssertEqual("refused", Receipt["status"])
				AssertEqual(0, Launches, "a retained command cannot launch while paused")
				AssertFalse(FSStrictExists(Receipt["backup"]))
			} else {
				AssertEqual(1, Launches, "one extension click admits one staged cohort")
				if LateRefusal {
					AssertEqual("pending", Receipt["status"])
					Parsed := TOML_ParseFreshFile(Fixture.path)
					for Name in ["replace", "repeat_corrections"]
						_HSCS_AssertSparseSelection(Parsed, "hotstrings.magic_key." . Name, "enabled",
							"hotstrings.magic_key." . Name . ".enabled", Enabled)
					AssertEqual(!Enabled, ReadFeatureStateV2("hotstrings.magic_key.replace")["enabled"],
						"pending publication leaves the real runtime's desired feature map unchanged")
					AssertTrue(Parsed["category_enabled"]["magic_key"], "closing bound leaves retains the category gate")
					for Name in ["text_expansion_symbols", "text_expansion_symbols_typst"]
						AssertTrue(Parsed["hotstrings.magic_key." . Name]["enabled"], "unrelated MagicKey symbols remain selected")
					for Key in ["rolls", "distances_reduction", "sfbs_reduction", "french_distancesreduction"]
						_HSCS_AssertSparseSelection(Parsed, "category_enabled", Key, "category_enabled." . Key, Enabled)
					AssertFalse(Parsed["category_enabled"]["hotstrings"], "the engine master keeps its independent choice")
					AssertEqual("retain-extension-fixture", Parsed["private"]["credential"])
					Refusal.Call("native extension selection refused")
				}
				AssertEqual("refused", Receipt["status"])
				AssertEqual(Fixture.source, FSReadUtf8Exact(Receipt["backup"]))
			}
			AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path), "refusal restores exact bytes for the entire extension")
		}
	}
}
for _HSCS_Enabled in [true, false]
	for _HSCS_Late in [true, false]
		Test("hotstring-extension-menu-owner: real shipped command " . _HSCS_Enabled . " rollback " . _HSCS_Late,
			_HSCS_ExtensionMenuOwner.Bind(_HSCS_Enabled, _HSCS_Late))
Test("hotstring-extension-menu-owner: retained native command refuses after pause",
	_HSCS_ExtensionMenuOwner.Bind(true, true, true))

_HSCS_ExtensionPackOwnedOwner(Enabled, Removed := false) {
	_HSCS_WithDynamicBootState(Boot)
	Boot() {
		_L4R_WithPack(Check)
	}
	Check(Root, SourcePath) {
		Fixture := _ScopeOwnerFixture(), Bundle := 0, Refusal := 0, Launches := 0
		Available := true
		Fixture.source .= '[hotstrings.groups]`n"ext:sample:words" = false`n"ext:foreign:words" = true`n'
			. '[hotstrings.modules."ext:sample:words"]`nwanted = false`nhidden = true`n'
			. '[hotstrings.magic_key.replace]`nenabled = true`n'
		OriginalRules := FSReadUtf8Exact(SourcePath)
		Launch(_Success, Borrowed, Refused) {
			Launches += 1, Bundle := Borrowed, Refusal := Refused
			return true
		}
		Fixture.options["reload"] := Launch
		Fixture.options["roots"] := (*) => Available ? [Root] : []
		try {
			Fixture.source := _CMJFixtureCurrentSource(Fixture.source)
			Assert(FSWriteDurable(Fixture.path, Fixture.source))
			Rows := _HS_ExtensionScopeCommandRows("sample", Fixture.options)
			AssertEqual(2, Rows.Length)
			Action := Rows[Enabled ? 1 : 2]["action"]
			if Removed
				Available := false
			Receipt := Action.Call()
			if Removed {
				AssertEqual("refused", Receipt["status"])
				AssertEqual(0, Launches, "current discovery rejects an uninstalled retained pack before reload")
				AssertFalse(FSStrictExists(Receipt["backup"]))
			} else {
				AssertEqual("pending", Receipt["status"])
				AssertEqual(1, Launches)
				Parsed := TOML_ParseFreshFile(Fixture.path)
				GroupPath := "hotstrings.groups.ext:sample:words"
				GroupRows := Parsed.Get("hotstrings.groups", Map())
				AssertEqual(Enabled != ManifestDefaultFor(GroupPath), GroupRows.Has("ext:sample:words"),
					"the group persists only a difference from its declared neutral choice")
				AssertEqual(Enabled, GroupRows.Get("ext:sample:words", ManifestDefaultFor(GroupPath)))
				ModuleRows := Parsed.Get('hotstrings.modules."ext:sample:words"', Map())
				for Name in ["wanted", "hidden"] {
					ModulePath := "hotstrings.modules.ext:sample:words." . Name
					AssertEqual(Enabled != ManifestDefaultFor(ModulePath), ModuleRows.Has(Name),
						"each module persists only a difference from its declared neutral choice")
					AssertEqual(Enabled, ModuleRows.Get(Name, ManifestDefaultFor(ModulePath)),
						"all pack-owned sections share the group transaction")
				}
				AssertTrue(Parsed["hotstrings.groups"]["ext:foreign:words"])
				AssertTrue(Parsed["hotstrings.magic_key.replace"]["enabled"], "a different extension cannot alter replacement")
				Refusal.Call("native pack-owned selection refused")
				AssertEqual("refused", Receipt["status"])
				AssertEqual(Fixture.source, FSReadUtf8Exact(Receipt["backup"]))
			}
			AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
			AssertEqual(OriginalRules, FSReadUtf8Exact(SourcePath), "selection never edits source rules")
		} finally {
			if Bundle is Object
				_ConfigWriteTerminalRelease(Bundle)
			_ScopeOwnerCleanup(Fixture)
		}
	}
}
for _HSCS_Enabled in [true, false]
	Test("hotstring-extension-scope: pack-owned staged cohort " . _HSCS_Enabled,
		_HSCS_ExtensionPackOwnedOwner.Bind(_HSCS_Enabled))
Test("hotstring-extension-scope: retained command cannot activate an uninstalled pack",
	_HSCS_ExtensionPackOwnedOwner.Bind(true, true))

; The existing journal owns runtime admission and conditional rollback. Only
; replacement launch is injected; the typed source, backup and journal are real.
_HSCS_WithSource(Body) {
	global _LegacyTopCategoryMap
	Saved := IsSet(_LegacyTopCategoryMap) ? _LegacyTopCategoryMap : unset
	Fixture := _ScopeOwnerFixture()
	Fixture.source := '[category_enabled]`nhotstrings = false`nrolls = false`nautocorrection = true`n[hotstrings.rolls.hc]`nenabled = false`ntime_activation_seconds = 0.75`n[hotstrings.rolls.sx]`nenabled = true`n[hotstrings.magic_key.replace]`nenabled = true`n[private]`ncredential = "retain-fixture-value"`n'
	try {
		Fixture.source := _CMJFixtureCurrentSource(Fixture.source)
		Assert(FSWriteDurable(Fixture.path, Fixture.source))
		_LegacyTopCategoryMap := Map("Rolls", "hotstrings.rolls")
		Body.Call(Fixture)
	} finally {
		_LegacyTopCategoryMap := IsSet(Saved) ? Saved : unset
		_ScopeOwnerCleanup(Fixture)
	}
}

_HSCS_PendingAndNativeRefusal(Enabled) {
	_HSCS_WithSource(Check)
	Check(Fixture) {
		Refusal := 0, Bundle := 0
		Launch(_Success, Borrowed, Refused) {
			Bundle := Borrowed
			Refusal := Refused
			return true
		}
		Fixture.options["reload"] := Launch
		try {
			Receipt := HotstringsCategoryScopeApply(["Rolls"], Enabled, Fixture.options)
			AssertEqual("pending", Receipt["status"], "accepted launch is never completed publication")
			AssertEqual(Enabled ? "enable_all" : "disable_all", Receipt["mode"])
			AssertEqual(Fixture.source, FSReadUtf8Exact(Receipt["backup"]))
			AssertEqual(Enabled, TOML_Read(Fixture.path, "category_enabled", "rolls",
				ManifestDefaultFor("category_enabled.rolls")))
			Target := ManifestBuildFeaturesMap()
			ApplyConfigToml(Target, Fixture.path)
			for Entry in ManifestFeaturesForSection("hotstrings.rolls") {
				Loc := FeatureLocateV2(Target, Entry["path"])
				AssertEqual(Enabled, Loc["v2_node"][Loc["key"]], "each selected section reaches the real reader")
			}
			Parsed := TOML_ParseFreshFile(Fixture.path)
			AssertEqual(false, Parsed["category_enabled"]["hotstrings"], "the engine master stays disabled")
			AssertEqual(true, Parsed["category_enabled"]["autocorrection"], "another category keeps its choice")
			AssertEqual(0.75, Parsed["hotstrings.rolls.hc"]["time_activation_seconds"])
			AssertEqual(true, Parsed["hotstrings.magic_key.replace"]["enabled"], "an unrelated replacement choice is retained")
			AssertEqual("retain-fixture-value", Parsed["private"]["credential"])
			Assert(!(_ConfigWriteLeaseTryAcquire(Fixture.path, "concurrent-category")))
			Refusal.Call("native category reload refused")
			AssertEqual("refused", Receipt["status"])
			AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path), "late refusal restores exact original bytes")
			Assert(!(_ConfigWriteLeaseSelectOwner(Bundle, Fixture.path) is Object))
		} finally {
			if Bundle is Object
				_ConfigWriteTerminalRelease(Bundle)
		}
	}
}

_HSCS_ImmediateRefusal(Enabled) {
	_HSCS_WithSource(Check)
	Check(Fixture) {
		Fixture.options["reload"] := (*) => false
		Receipt := HotstringsCategoryScopeApply(["Rolls"], Enabled, Fixture.options)
		AssertEqual("refused", Receipt["status"])
		AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
		AssertEqual(Fixture.source, FSReadUtf8Exact(Receipt["backup"]))
	}
}

_HSCS_UnknownScope() {
	_HSCS_WithSource(Check)
	Check(Fixture) {
		Launches := 0
		Fixture.options["reload"] := (*) => Launches += 1
		Receipt := HotstringsCategoryScopeApply(["Rolls", "missing"], true, Fixture.options)
		AssertEqual("refused", Receipt["status"])
		AssertEqual(0, Launches)
		AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
		AssertFalse(FSStrictExists(Receipt["backup"]), "an invalid scope creates no backup or partial write")
	}
}

for _HSCS_Enabled in [true, false] {
	Test("hotstring-category-owner: pending " . _HSCS_Enabled . " rolls back native refusal",
		_HSCS_PendingAndNativeRefusal.Bind(_HSCS_Enabled))
	Test("hotstring-category-owner: immediate " . _HSCS_Enabled . " refusal preserves exact source",
		_HSCS_ImmediateRefusal.Bind(_HSCS_Enabled))
}
Test("hotstring-category-owner: an unknown sibling never launches or writes", _HSCS_UnknownScope)

_HSCS_InventoryOwnsOnlyHotstrings() {
	Requested := []
	Read(Prefix) {
		Requested.Push(Prefix)
		return ManifestFeaturesForSection(Prefix)
	}
	Inventory := _HotstringsCategoryScopeInventory(Map("Layout", "layout", "Shortcuts", "shortcuts",
		"Gestures", "gestures", "Rolls", "hotstrings.rolls"), Read)
	AssertEqual(1, Inventory.Count, "other tray scopes are not hotstring categories")
	Assert(Inventory.Has("Rolls"))
	Assert(Inventory["Rolls"].Length > 1, "the admitted category must expose its real sections")
	AssertEqual(1, Requested.Length, "foreign namespaces are not even queried")
	AssertEqual("hotstrings.rolls", Requested[1])
	AssertFalse(HotstringsCategoryScopePlan(Inventory, ["Rolls", "Layout"], true, &Reason))
	AssertEqual("unknown-category", Reason)
}
Test("hotstring-category-owner: other tray namespaces never enter the selected inventory",
	_HSCS_InventoryOwnsOnlyHotstrings)

; The real Win32 command dispatch reaches the durable scope owner, including
; pending handoff and restoration after native refusal.
_HSCS_MenuOwner(Enabled) {
	global _MenuDispatchCallbacks
	_HSCS_WithSource(Check)
	Check(Fixture) {
		Receipt := 0, Refusal := 0
		Launch(_Success, _Borrowed, Refused) {
			Refusal := Refused
			return true
		}
		Apply(Targets, Requested) {
			Receipt := HotstringsCategoryScopeApply(Targets, Requested, Fixture.options)
		}
		Fixture.options["reload"] := Launch
		Built := _HS_CategoryMenu("Rolls", "", [], Apply)
		try {
			AssertEqual(2, TrayMenuItemCount(Built), "empty providers leave exactly the two declared commands")
			Position := Enabled ? 0 : 1
			AssertEqual(t(Enabled ? "menu.hotstrings.scope_enable_all" : "menu.hotstrings.scope_disable_all"),
				_CTC_LabelAt(Built, Position))
			Id := DllCall("GetMenuItemID", "ptr", Built.Handle, "int", Position, "uint")
			Assert(_MenuDispatchCallbacks.Has(Id))
			_MenuDispatchCallbacks[Id].Call()
			AssertEqual("pending", Receipt["status"])
			AssertEqual(Enabled, TOML_Read(Fixture.path, "category_enabled", "rolls", false))
			AssertEqual(false, TOML_Read(Fixture.path, "category_enabled", "hotstrings", true))
			Refusal.Call("native category menu reload refused")
			AssertEqual("refused", Receipt["status"])
			AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
		} finally _CTC_ReleaseMenu(Built)
	}
}
for _HSCS_Enabled in [true, false]
	Test("hotstring-category-menu-owner: native command " . _HSCS_Enabled . " commits through the journal",
		_HSCS_MenuOwner.Bind(_HSCS_Enabled))

; Personal inventory is file-owned, not part of the manifest catalogue. A cached
; menu preview must not omit a section added before the configuration lease.
_HSCS_PersonalMenuOwner(Enabled, LateRefusal) {
	global ScriptInformation, Features, CategoryEnabled, _ReadPersonalTomlCache
	global _PersonalExtTree, _FmtCountCache, _MenuDispatchCallbacks, _PrevDefaultLabel
	Fixture := _ScopeOwnerFixture(), Built := 0, Bundle := 0, Refusal := 0, Launches := 0
	PersonalPath := Fixture.path . ".personal.toml"
	Source := '[category_enabled]`nhotstrings = false`nrolls = true`n[hotstrings.personal.first]`nenabled = false`ntime_activation_seconds = 0.75`n[hotstrings.personal.future]`nenabled = false`n[private]`ncredential = "retain-personal-fixture"`n'
	SavedInfo := ScriptInformation, SavedFeatures := Features, SavedCategories := CategoryEnabled
	SavedCache := _ReadPersonalTomlCache
	SavedTree := IsSet(_PersonalExtTree) ? _PersonalExtTree : unset
	SavedCounts := IsSet(_FmtCountCache) ? _FmtCountCache : unset
	SavedDefaultLabel := IsSet(_PrevDefaultLabel) ? _PrevDefaultLabel : unset
	State := MasterGateState(), SavedState := State.Clone()
	Launch(_Success, Borrowed, Refused) {
		Launches += 1
		Bundle := Borrowed, Refusal := Refused
		return LateRefusal
	}
	Fixture.options["reload"] := Launch
	try {
		Source := _CMJFixtureCurrentSource(Source)
		Assert(FSWriteDurable(Fixture.path, Source))
		ScriptInformation := ScriptInformation.Clone()
		ScriptInformation["PersonalTomlPath"] := PersonalPath
		_PersonalExtTree := Map(), _FmtCountCache := Map()
		Features := ManifestBuildFeaturesMap()
		_ConfigSeedPersonalHotstring(Features, "first")
		CategoryEnabled := Map("Hotstrings", false, "Rolls", true)
		State["initialized"] := false
		MasterGateInitialize(Features, Map("keys", Map()), (*) => false)
		Assert(FSWriteDurable(PersonalPath, '[[first]]`n'))
		_ReadPersonalTomlCache := false
		AssertEqual(1, ReadPersonalToml()["sections_order"].Length)
		PersonalSource := '[[first]]`n[[second]]`n'
		Assert(FSWriteDurable(PersonalPath, PersonalSource))
		Rows := _HS_PersonalRows(Fixture.options)
		AssertEqual(1, Rows.Length, "the personal file must be a real rendered submenu")
		Built := Rows[1]["submenu"]
		AssertEqual(t("menu.hotstrings.scope_enable_all"), _CTC_LabelAt(Built, 0))
		AssertEqual(t("menu.hotstrings.scope_disable_all"), _CTC_LabelAt(Built, 1))
		AssertEqual(0, _CTC_CountLabel(Built, t("menu.hotstrings.enable_all_sections")))
		AssertEqual(0, _CTC_CountLabel(Built, t("menu.hotstrings.category_enable")))
		AssertFalse(_CTC_IsChecked(Built, Enabled ? 0 : 1))
		Id := DllCall("GetMenuItemID", "ptr", Built.Handle, "int", Enabled ? 0 : 1, "uint")
		Assert(_MenuDispatchCallbacks.Has(Id))
		Receipt := _MenuDispatchCallbacks[Id].Call()
		AssertEqual(1, Launches, "one native click admits one reload transaction")
		if LateRefusal {
			AssertEqual("pending", Receipt["status"])
			for Name in ["first", "second"]
				AssertEqual(Enabled, TOML_Read(Fixture.path, "hotstrings.personal." . Name, "enabled",
					ManifestDefaultFor("hotstrings.personal." . Name . ".enabled")),
					"fresh discovery selects every actual section, including uncached additions")
			Parsed := TOML_ParseFreshFile(Fixture.path)
			AssertFalse(Parsed["category_enabled"]["hotstrings"])
			AssertTrue(Parsed["category_enabled"]["rolls"])
			AssertFalse(Parsed["hotstrings.personal.future"]["enabled"], "unlisted personal sections retain their settings")
			AssertEqual(0.75, Parsed["hotstrings.personal.first"]["time_activation_seconds"])
			AssertEqual("retain-personal-fixture", Parsed["private"]["credential"])
			AssertFalse(Features["hotstrings"]["personal"].Has("second"), "pending selection cannot seed public runtime")
			Assert(!(_ConfigWriteLeaseTryAcquire(Fixture.path, "concurrent-personal-scope")))
			Refusal.Call("native personal menu reload refused")
		}
		AssertEqual("refused", Receipt["status"])
		AssertEqual(Source, FSReadUtf8Exact(Fixture.path), "both refusal timings restore exact original bytes")
		AssertEqual(Source, FSReadUtf8Exact(Receipt["backup"]))
		AssertEqual(PersonalSource, FSReadUtf8Exact(PersonalPath), "scope selection cannot rewrite the user's rules")
	} finally {
		if Built is Menu
			_CTC_ReleaseMenu(Built)
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		ScriptInformation := SavedInfo, Features := SavedFeatures, CategoryEnabled := SavedCategories
		_ReadPersonalTomlCache := SavedCache
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

for _HSCS_Enabled in [true, false] {
	for _HSCS_Late in [true, false]
		Test("hotstring-personal-menu-owner: command " . _HSCS_Enabled . " preserves state after refusal " . _HSCS_Late,
			_HSCS_PersonalMenuOwner.Bind(_HSCS_Enabled, _HSCS_Late))
}

_HSCS_ExistingMenuTarget() {
	Target := Menu(), Asked := []
	Apply(_Targets, Enabled) => Asked.Push(Enabled)
	Built := _HS_CategoryMenu("Personal", "", [], Apply, Target)
	try {
		AssertEqual(ObjPtr(Target), ObjPtr(Built), "repaint callbacks retain the caller's native menu")
		AssertEqual(2, TrayMenuItemCount(Target))
		Rejected := false
		try _HS_CategoryMenu("Personal", "", [], Apply, Target)
		catch
			Rejected := true
		AssertTrue(Rejected, "an already populated target must refuse before appending duplicate commands")
		AssertEqual(2, TrayMenuItemCount(Target))
	} finally _CTC_ReleaseMenu(Built)
}
Test("hotstring-personal-menu: shared rendering preserves caller-owned repaint references", _HSCS_ExistingMenuTarget)

_HSCS_DefaultMenuTargetsAreIndependent() {
	Apply(_Targets, Enabled) => true
	First := _HS_CategoryMenu("Personal", "", [], Apply)
	Second := _HS_CategoryMenu("Personal", "", [], Apply)
	try {
		AssertTrue(ObjPtr(First) != ObjPtr(Second), "default rendering creates a fresh native menu for each caller")
		AssertEqual(2, TrayMenuItemCount(First))
		AssertEqual(2, TrayMenuItemCount(Second))
		First.Add("fixture", (*) => true)
		AssertEqual(3, TrayMenuItemCount(First))
		AssertEqual(2, TrayMenuItemCount(Second), "mutating one native menu cannot duplicate sibling rows")
	} finally {
		_CTC_ReleaseMenu(First)
		_CTC_ReleaseMenu(Second)
	}
}
Test("hotstring-personal-menu: default rendering creates independent native menus", _HSCS_DefaultMenuTargetsAreIndependent)

; The headless runner deliberately omits tray_menu.ahk's auto-execute block.
; Read the real tray and personal-information declarations and feature manifest:
; no second curated order or hard-coded live feature map belongs in a fixture.
_HSCS_TrayMapLiteral(Source, Name) {
	if !RegExMatch(Source, "ms)^global " . Name . " := Map\((.*?)^\)", &Found)
		throw Error("The tray boot owner has no Map declaration for " . Name . ".")
	Values := JsonParse("[" . RegExReplace(Found[1], ",\s*$") . "]")
	if !(Values is Array) || Mod(Values.Length, 2)
		throw Error("The tray boot Map declaration has incomplete pairs: " . Name . ".")
	Result := Map()
	loop Values.Length // 2
		Result[Values[2 * A_Index - 1]] := Values[2 * A_Index]
	return Result
}

_HSCS_WithDynamicBootState(Body) {
	Assert(IsSet(MenuLabelFromManifestEntry), "the headless menu must load its real manifest label owner")
	global Features, _LegacyTopCategoryMap, _LegacyDynamicHotstringsKeyMap, _DYNAMIC_HOTSTRINGS_ORDER
	global PersonalInformation, _TomlCountCache, _V1CatToV2CatMap
	HadInformation := IsSet(PersonalInformation), OldInformation := HadInformation ? PersonalInformation : 0
	HadCounts := IsSet(_TomlCountCache), OldCounts := HadCounts ? _TomlCountCache : 0
	HadFeatures := IsSet(Features), OldFeatures := HadFeatures ? Features : 0
	HadTop := IsSet(_LegacyTopCategoryMap), OldTop := HadTop ? _LegacyTopCategoryMap : 0
	HadCategoryMap := IsSet(_V1CatToV2CatMap), OldCategoryMap := HadCategoryMap ? _V1CatToV2CatMap : 0
	HadKeys := IsSet(_LegacyDynamicHotstringsKeyMap), OldKeys := HadKeys ? _LegacyDynamicHotstringsKeyMap : 0
	HadOrder := IsSet(_DYNAMIC_HOTSTRINGS_ORDER), OldOrder := HadOrder ? _DYNAMIC_HOTSTRINGS_ORDER : 0
	try {
		Source := _StripFullLineComments(FileRead(_DriverDir . "\ui\tray_menu.ahk", "UTF-8"))
		_LegacyTopCategoryMap := _HSCS_TrayMapLiteral(Source, "_LegacyTopCategoryMap")
		_V1CatToV2CatMap := _HSCS_TrayMapLiteral(Source, "_V1CatToV2CatMap")
		Assert(InStr(Source, "global _LegacyDynamicHotstringsKeyMap := _MR_DynamicHotstringsKeyMap()"),
			"the real tray must consume the shared family alias owner")
		Assert(InStr(Source, "global _DYNAMIC_HOTSTRINGS_ORDER := _MR_DynamicHotstringsOrder()"),
			"the real tray must consume the shared family order owner")
		_LegacyDynamicHotstringsKeyMap := _MR_DynamicHotstringsKeyMap()
		_DYNAMIC_HOTSTRINGS_ORDER := _MR_DynamicHotstringsOrder()
		Assert(_DYNAMIC_HOTSTRINGS_ORDER is Array, "the real tray order must be an array")
		for Id in _DYNAMIC_HOTSTRINGS_ORDER {
			if Id == "-"
				continue
			Assert(_LegacyDynamicHotstringsKeyMap.Has(Id), "the boot order must name an owned dynamic family")
			Assert(ManifestFindEntryByPath("hotstrings.dynamic." . _LegacyDynamicHotstringsKeyMap[Id]) is Map,
				"the boot family must resolve through the real feature manifest")
		}
		BootSource := _StripFullLineComments(FileRead(_DriverDir . "\ErgoptiPlus.ahk", "UTF-8"))
		PersonalInformation := _HSCS_TrayMapLiteral(BootSource, "PersonalInformation")
		_TomlCountCache := Map()
		Features := ManifestBuildFeaturesMap()
		Body.Call()
	} finally {
		PersonalInformation := HadInformation ? OldInformation : unset
		_TomlCountCache := HadCounts ? OldCounts : unset
		Features := HadFeatures ? OldFeatures : unset
		_LegacyTopCategoryMap := HadTop ? OldTop : unset
		_V1CatToV2CatMap := HadCategoryMap ? OldCategoryMap : unset
		_LegacyDynamicHotstringsKeyMap := HadKeys ? OldKeys : unset
		_DYNAMIC_HOTSTRINGS_ORDER := HadOrder ? OldOrder : unset
	}
}

; Dynamic scopes have eight canonical features and no separate category gate.
; The native submenu reaches the same journal while the master or pause is off.
_HSCS_DynamicMenuOwner(Enabled, Outcome, Paused := false) {
	global Features, CategoryEnabled, _LegacyTopCategoryMap, _MenuDispatchCallbacks, _TomlFileCache
	Fixture := _ScopeOwnerFixture(), Built := 0, Bundle := 0, Refusal := 0, Accepted := 0, Launches := 0
	Names := ["date", "date_fr", "date_long_fr", "phone_prefixes", "ssn_prefixes",
		"iban_prefixes", "user_code", "text_expansion_personal_information"]
	Source := '[category_enabled]`nhotstrings = false`nrolls = true`n[hotstrings.dynamic]`nenabled = false`n'
	for Index, Name in Names {
		Source .= '[hotstrings.dynamic.' . Name . ']`nenabled = ' . (Mod(Index, 2) ? "true" : "false") . '`n'
		if Name == "date"
			Source .= 'time_activation_seconds = 0.75`n'
	}
	Source .= '[hotstrings.dynamic.future_family]`nenabled = true`n[private]`ncredential = "retain-dynamic-fixture"`n'
	SavedFeatures := Features, SavedCategories := CategoryEnabled
	SavedLegacy := IsSet(_LegacyTopCategoryMap) ? _LegacyTopCategoryMap : unset
	SavedSuspend := A_IsSuspended
	State := MasterGateState(), SavedState := State.Clone()
	Launch(Success, Borrowed, Refused) {
		Launches += 1
		Bundle := Borrowed, Refusal := Refused, Accepted := Success
		return Outcome != "immediate_refusal"
	}
	Fixture.options["reload"] := Launch
	try {
		Source := _CMJFixtureCurrentSource(Source)
		Assert(FSWriteDurable(Fixture.path, Source))
		Fixture.source := Source
		Features := ManifestBuildFeaturesMap()
		ApplyConfigToml(Features, Fixture.path)
		CategoryEnabled := Map("Hotstrings", false, "Rolls", true)
		State["initialized"] := false
		MasterGateInitialize(Features, Map("keys", Map()), (*) => false)
		Suspend(Paused)
		RuntimeBefore := KL_JsonEncode(Features)
		; Semantic feature loading does not populate the separate live-text cache.
		AssertEqual(Source, ReadTomlFile(Fixture.path), "fixture primes the live text cache before publication")
		Cached := ParseTomlFile(Fixture.path)
		Built := _BuildDynamicHotstringsSubmenu(Fixture.options)
		AssertEqual(12, TrayMenuItemCount(Built), "two shared commands, two separators, seven displayed families and their editor")
		AssertEqual(t("menu.hotstrings.scope_enable_all"), _CTC_LabelAt(Built, 0))
		AssertEqual(t("menu.hotstrings.scope_disable_all"), _CTC_LabelAt(Built, 1))
		AssertEqual(0, _CTC_CountLabel(Built, t("menu.hotstrings.enable_all_sections")), "the old checkbox is retired")
		AssertEqual(0, _CTC_CountLabel(Built, t("menu.hotstrings.category_enable")), "there is no invented dynamic category switch")
		AssertEqual(1, _CTC_CountLabel(Built, t("menu.shortcuts.edit_personal_info")), "the existing editor stays reachable")
		AssertFalse(_CTC_IsChecked(Built, 0))
		AssertFalse(_CTC_IsChecked(Built, 1))
		AssertEqual(Source, FSReadUtf8Exact(Fixture.path), "building the menu cannot persist a preference")
		; A preview's legacy map cannot retarget the scope into another namespace.
		_LegacyTopCategoryMap := Map("DynamicHotstrings", "shortcuts")
		Position := Enabled ? 0 : 1
		Id := DllCall("GetMenuItemID", "ptr", Built.Handle, "int", Position, "uint")
		Assert(_MenuDispatchCallbacks.Has(Id), "both commands retain their native callbacks behind a closed master")
		Receipt := _MenuDispatchCallbacks[Id].Call()
		AssertEqual(1, Launches, "one native click admits one whole-family transaction")
		AssertEqual(Enabled ? "enable_all" : "disable_all", Receipt["mode"])
		AssertEqual(RuntimeBefore, KL_JsonEncode(Features), "pending or refused replacement cannot publish runtime choices")
		AssertEqual(Paused, A_IsSuspended, "the scope never resumes a paused driver")
		AssertFalse(CategoryEnabled["Hotstrings"], "the native engine master stays off")
		AssertTrue(CategoryEnabled["Rolls"], "another category keeps its native gate")
		if Outcome != "immediate_refusal" {
			AssertEqual("pending", Receipt["status"], "accepted launch is not replacement acknowledgement")
			AssertEqual(Source, FSReadUtf8Exact(Receipt["backup"]), "the exact source is backed up before publication")
			; Replacement boot reads pending bytes in a fresh interpreter. Mirror
			; that read boundary with an exact owned copy, retaining this process
			; cache until its transaction receives acknowledgement or refusal.
			CandidatePath := Fixture.directory . "\replacement-reader.toml"
			CandidateBytes := FSReadUtf8Exact(Fixture.path)
			Assert(FSWriteDurable(CandidatePath, CandidateBytes))
			AssertEqual(CandidateBytes, FSReadUtf8Exact(CandidatePath))
			Target := ManifestBuildFeaturesMap()
			_CMJFixtureReadonly(CandidatePath)
			try ApplyConfigToml(Target, CandidatePath)
			finally {
				if _TomlFileCache.Has(CandidatePath)
					_TomlFileCache.Delete(CandidatePath)
			}
			AssertEqual(Source, ReadTomlFile(Fixture.path), "pending publication preserves the live text cache")
			Actual := ManifestFeaturesForSection("hotstrings.dynamic")
			AssertEqual(Names.Length, Actual.Length, "every current dynamic family belongs to the canonical inventory")
			for Name in Names {
				Loc := FeatureLocateV2(Target, "hotstrings.dynamic." . Name)
				Assert(Loc is Map, "the independent family must resolve: " . Name)
				AssertEqual(Enabled, Loc["v2_node"][Loc["key"]], "the real config reader sees the explicit posture of " . Name)
			}
			Parsed := TOML_ParseFreshFile(Fixture.path)
			AssertFalse(Parsed["category_enabled"]["hotstrings"])
			AssertTrue(Parsed["category_enabled"]["rolls"])
			AssertFalse(Parsed["category_enabled"].Has("dynamichotstrings"), "no additional category gate is written")
			AssertFalse(Parsed["hotstrings.dynamic"]["enabled"], "an unrelated scalar keeps its stored value")
			AssertTrue(Parsed["hotstrings.dynamic.future_family"]["enabled"], "unrecognized future families stay untouched")
			AssertEqual(0.75, Parsed["hotstrings.dynamic.date"]["time_activation_seconds"])
			AssertEqual("retain-dynamic-fixture", Parsed["private"]["credential"])
			AssertEqual(ObjPtr(Cached), ObjPtr(ParseTomlFile(Fixture.path)), "pending bytes cannot replace cached desired authority")
			Assert(!(_ConfigWriteLeaseTryAcquire(Fixture.path, "concurrent-dynamic-scope")))
			if Outcome == "committed" {
				Accepted.Call()
				AssertEqual("committed", Receipt["status"], "only native acknowledgement completes publication")
			} else {
				Refusal.Call("native dynamic menu reload refused")
			}
		}
		if Outcome != "committed" {
			AssertEqual("refused", Receipt["status"])
			AssertEqual(Source, FSReadUtf8Exact(Fixture.path), "immediate and late refusal restore exact source bytes")
			AssertEqual(Source, FSReadUtf8Exact(Receipt["backup"]))
			Assert(!(_ConfigWriteLeaseSelectOwner(Bundle, Fixture.path) is Object))
		}
	} finally {
		if Built is Menu
			_CTC_ReleaseMenu(Built)
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		Features := SavedFeatures, CategoryEnabled := SavedCategories
		_LegacyTopCategoryMap := IsSet(SavedLegacy) ? SavedLegacy : unset
		Suspend(SavedSuspend)
		State.Clear()
		for Key, Value in SavedState
			State[Key] := Value
		_ScopeOwnerCleanup(Fixture)
	}
}

for _HSCS_Enabled in [true, false] {
	for _HSCS_Outcome in ["immediate_refusal", "late_refusal", "committed"]
		Test("hotstring-dynamic-menu-owner: command " . _HSCS_Enabled . " keeps the master and handles " . _HSCS_Outcome,
			_HSCS_WithDynamicBootState.Bind(_HSCS_DynamicMenuOwner.Bind(_HSCS_Enabled, _HSCS_Outcome)))
	Test("hotstring-dynamic-menu-owner: command " . _HSCS_Enabled . " preserves pause across a late refusal",
		_HSCS_WithDynamicBootState.Bind(_HSCS_DynamicMenuOwner.Bind(_HSCS_Enabled, "late_refusal", true)))
}

_HSCS_DynamicInvalidPosture() {
	for Value in ["true", 2] {
		Fixture := _ScopeOwnerFixture(), Launches := 0
		try {
			Fixture.options["reload"] := (*) => Launches += 1
			Receipt := HotstringsDynamicScopeApply(Value, Fixture.options)
			AssertEqual("refused", Receipt["status"], "an invalid request cannot publish a partial selection")
			AssertEqual(0, Launches)
			AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
			AssertFalse(FSStrictExists(Receipt["backup"]), "an invalid request creates no backup or write")
		} finally _ScopeOwnerCleanup(Fixture)
	}
}
Test("hotstring-dynamic-menu-owner: invalid postures are refused before backup or reload", _HSCS_DynamicInvalidPosture)

; This layout-only regression runs unchanged against the old zero-argument
; builder: the original checkbox fails before any native action is invoked.
_HSCS_DynamicMenuHead() {
	Built := _BuildDynamicHotstringsSubmenu()
	try {
		AssertEqual(t("menu.hotstrings.scope_enable_all"), _CTC_LabelAt(Built, 0), "the first command has explicit enable intent")
		AssertEqual(t("menu.hotstrings.scope_disable_all"), _CTC_LabelAt(Built, 1), "the second command has explicit disable intent")
		AssertEqual(0, _CTC_CountLabel(Built, t("menu.hotstrings.enable_all_sections")), "the state-dependent checkbox is retired")
	} finally _CTC_ReleaseMenu(Built)
}
Test("hotstring dynamic submenu: explicit shared command head (hotstring-dynamic-menu-head)",
	_HSCS_WithDynamicBootState.Bind(_HSCS_DynamicMenuHead))


; The golden records were captured from the native owners before centralization.
; Injecting another published order must reach the actual native Menu object.
_HSCS_DynamicSharedOrder(Corpus, Vector) {
	Root := _MM_GetManifestRoot()
	Assert(Root is Map, "the real shared menu declaration must be readable")
	Previous := Root["dynamic_hotstring_families"]
	Rows := []
	for Index in Vector["indices"]
		Rows.Push(Corpus["rows"][Index])
	Root["dynamic_hotstring_families"] := Map("rows", Rows)
	try _HSCS_WithDynamicBootState(Check)
	finally Root["dynamic_hotstring_families"] := Previous
	Check() {
		global _DYNAMIC_HOTSTRINGS_ORDER, _LegacyDynamicHotstringsKeyMap
		Expected := Vector["windows"]
		AssertEqual(Expected.Length, _DYNAMIC_HOTSTRINGS_ORDER.Length)
		for Index, Id in Expected
			AssertEqual(Id, _DYNAMIC_HOTSTRINGS_ORDER[Index], "the boot order must follow the independent vector")
		Built := _BuildDynamicHotstringsSubmenu()
		try {
			AssertEqual(12, TrayMenuItemCount(Built), "all shared commands, families, separators and editor survive")
			Position := 3
			for Index, Id in Expected {
				if Id == "-" {
					State := DllCall("GetMenuState", "ptr", Built.Handle, "uint", Position, "uint", 0x400, "uint")
					Assert(State != 0xFFFFFFFF && (State & 0x800), "the independent separator remains in its exact position")
				} else {
					ExpectedId := Corpus["rows"][Vector["indices"][Index]]["id"]
					AssertEqual(ExpectedId, _LegacyDynamicHotstringsKeyMap[Id], "the published alias keeps its canonical feature")
					Entry := ManifestFindEntryByPath("hotstrings.dynamic." . ExpectedId)
					Assert(Entry is Map, "the independently named native row requires a real feature")
					Row := MenuRowFromManifest(Entry, "DynamicHotstrings")
					Assert(Row is Map, "the independent family must produce its native row")
					AssertEqual(Row["label"], _CTC_LabelAt(Built, Position), "the actual native menu must follow the shared order")
					if ExpectedId == "text_expansion_personal_information" {
						Position += 1
						AssertEqual(t("menu.shortcuts.edit_personal_info"), _CTC_LabelAt(Built, Position),
							"the native editor follows the personal-information family")
					}
				}
				Position += 1
			}
			AssertEqual(12, Position, "every native row is accounted for")
		} finally _CTC_ReleaseMenu(Built)
	}
}

_HSCS_DynamicSharedMetadata() {
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\dynamic_hotstrings\menu_vectors.json", "UTF-8"))
	Root := _MM_GetManifestRoot()
	AssertEqual(KL_JsonEncode(Corpus["rows"]), KL_JsonEncode(Root["dynamic_hotstring_families"]["rows"]),
		"the independently captured published metadata stays exact")
	First := _MR_GetDynamicHotstringFamilies(), Second := _MR_GetDynamicHotstringFamilies()
	First[1]["section"] := "changed-in-first-caller"
	First.Push(Map("separator", true))
	AssertEqual("datelongfr", Second[1]["section"])
	AssertEqual(8, Second.Length)
	AssertEqual(KL_JsonEncode(Corpus["rows"]), KL_JsonEncode(Root["dynamic_hotstring_families"]["rows"]),
		"native callers cannot mutate the manifest cache")
}
Test("hotstring dynamic shared metadata: independent and detached", _HSCS_DynamicSharedMetadata)
for _HSCS_MenuVector in JsonParse(FileRead(_SharedDir . "\tests\corpus\dynamic_hotstrings\menu_vectors.json", "UTF-8"))["vectors"]
	Test("hotstring dynamic shared order: " . _HSCS_MenuVector["id"],
		_HSCS_DynamicSharedOrder.Bind(JsonParse(FileRead(_SharedDir . "\tests\corpus\dynamic_hotstrings\menu_vectors.json", "UTF-8")), _HSCS_MenuVector))

#Include %A_LineFile%\..\..\..\..\_shared\modules\hotstrings\personal_scope.ahk

; Every platform replays the same independent admission decisions.
_HSCS_PersonalAdmission(Vector) {
	Before := KL_JsonEncode(Vector)
	Admitted := PersonalScopeAdmit(Vector["inventory"], Vector["selected"], &Reason)
	if Vector.Has("refusal") {
		AssertFalse(Admitted)
		AssertEqual(Vector["refusal"], Reason)
	} else {
		Assert(Admitted is Map)
		AssertEqual("", Reason)
		AssertEqual(KL_JsonEncode(Vector["expected"]), KL_JsonEncode(Admitted))
		Assert(Admitted["source"] != Vector["selected"]["source"])
		Assert(Admitted["source"]["components"] != Vector["selected"]["source"]["components"])
	}
	AssertEqual(Before, KL_JsonEncode(Vector), "admission cannot mutate caller evidence")
}

for _HSCS_AdmissionVector in JsonParse(FileRead(_SharedDir . "\tests\corpus\hotstrings\personal_scope_admission.json", "UTF-8"))["vectors"]
	Test("personal-file-admission: " . _HSCS_AdmissionVector["name"], _HSCS_PersonalAdmission.Bind(_HSCS_AdmissionVector))


; A caller-owned native menu keeps its ordinary editor leaf and current pause
; owner. Callback observations are asserted after the dispatcher returns.
_HSCS_PersonalEditorDelivery(Vector) {
	global _MenuDispatchCallbacks
	if Vector["pause_receipt"] != "boolean" || !Vector["opener"]
		return
	State := Map("paused", Vector["initial_paused"], "calls", 0)
	Open(State, *) {
		State["calls"] += 1
		return true
	}
	Paused(State, *) => State["paused"]
	Built := Menu()
	try {
		Row := _HS_PersonalEditorRow(Open.Bind(State), Paused.Bind(State))
		Assert(Row is Map, "the canonical declaration must produce provider data")
		MenuRenderer_AppendRows(Built, "hotstrings_menu", "hotstring_personal", [Row])
		AssertEqual(1, TrayMenuItemCount(Built))
		AssertEqual(t("menu.hotstrings.open_editor"), _CTC_LabelAt(Built, 0))
		Flags := DllCall("GetMenuState", "Ptr", Built.Handle, "UInt", 0, "UInt", 0x400, "UInt")
		AssertEqual(!Vector["enabled"], (Flags & 0x3) != 0)
		Id := DllCall("GetMenuItemID", "Ptr", Built.Handle, "Int", 0, "UInt")
		Assert(_MenuDispatchCallbacks.Has(Id), "the real renderer must register the actual leaf callback")
		State["paused"] := Vector["delivered_paused"]
		_MenuDispatchCallbacks[Id].Call()
		AssertEqual(Vector["calls"], State["calls"], "the retained native callback obeys the live pause owner")
	} finally _CTC_ReleaseMenu(Built)
}

for _HSCS_EditorVector in JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\personal_editor_command.json", "UTF-8"))["vectors"] {
	if _HSCS_EditorVector["pause_receipt"] == "boolean" && _HSCS_EditorVector["opener"]
		Test("shared-personal-editor: " . _HSCS_EditorVector["name"], _HSCS_PersonalEditorDelivery.Bind(_HSCS_EditorVector))
}

_HSCS_PersonalEditorReadSite() {
	Body := _DriverFuncBody("_HS_PersonalRows")
	Assert(Body != "", "the actual personal provider must exist")
	AssertTrue(_HSCS_PersonalFrameDelegation(Body), "the actual captured editor row reaches the canonical whole-frame renderer")
	AssertContains(Body, "HotstringsPersonalScopeApply(Enabled, Options), PersonalMenu)",
		"the unchanged scope builder owns the still-empty native repaint target")
	Assert(!InStr(Body, 'Map("label", t("menu.hotstrings.open_editor")'), "the shared declaration owns the label")
}
Test("shared-personal-editor: the actual personal provider consumes its declaration", _HSCS_PersonalEditorReadSite)


_HSCS_PersonalEditorSharedLabel() {
	Root := _MR_GetManifestRoot()
	Assert(Root is Map)
	Declaration := Root["personal_hotstring_commands"]
	AssertEqual(1, Declaration.Length)
	Item := Declaration[1], Before := Item["i18n"], Built := Menu()
	try {
		Item["i18n"] := "menu.hotstrings.shortcut_none"
		Row := _HS_PersonalEditorRow((*) => true, (*) => false)
		MenuRenderer_AppendRows(Built, "hotstrings_menu", "hotstring_personal", [Row])
		AssertEqual(t("menu.hotstrings.shortcut_none"), _CTC_LabelAt(Built, 0), "the native row follows its shared label")
	} finally {
		Item["i18n"] := Before
		_CTC_ReleaseMenu(Built)
	}
}
Test("shared-personal-editor: the actual native provider follows a changed shared label", _HSCS_PersonalEditorSharedLabel)

_HSCS_PersonalEditorUnknownPause(Throws) {
	State := Map("calls", 0)
	Open(State, *) {
		State["calls"] += 1
		return true
	}
	Paused(Throws, *) {
		if Throws
			throw Error("injected native pause read failure")
		return Map("unconfirmed", true)
	}
	Built := Menu()
	try {
		Row := _HS_PersonalEditorRow(Open.Bind(State), Paused.Bind(Throws))
		AssertTrue(Row["disabled"], "a refused actual pause receipt cannot enable the editor")
		MenuRenderer_AppendRows(Built, "hotstrings_menu", "hotstring_personal", [Row])
		Id := DllCall("GetMenuItemID", "Ptr", Built.Handle, "Int", 0, "UInt")
		global _MenuDispatchCallbacks
		Assert(_MenuDispatchCallbacks.Has(Id))
		AssertFalse(_MenuDispatchCallbacks[Id].Call())
		AssertEqual(0, State["calls"])
	} finally _CTC_ReleaseMenu(Built)
}
for _HSCS_PauseThrows in [true, false]
	Test("shared-personal-editor: refused native pause owner " . _HSCS_PauseThrows,
		_HSCS_PersonalEditorUnknownPause.Bind(_HSCS_PauseThrows))


_HSCS_PersonalEditorUntypedPause(Value) {
	global _MenuDispatchCallbacks
	State := Map("calls", 0)
	Open(State, *) {
		State["calls"] += 1
		return true
	}
	Paused(Value, *) => Value
	Built := Menu()
	try {
		Row := _HS_PersonalEditorRow(Open.Bind(State), Paused.Bind(Value))
		AssertTrue(Row["disabled"], "only an actual native Integer pause receipt may enable the editor")
		MenuRenderer_AppendRows(Built, "hotstrings_menu", "hotstring_personal", [Row])
		Id := DllCall("GetMenuItemID", "Ptr", Built.Handle, "Int", 0, "UInt")
		Assert(_MenuDispatchCallbacks.Has(Id))
		AssertFalse(_MenuDispatchCallbacks[Id].Call())
		AssertEqual(0, State["calls"], "untyped zero cannot permit a retained callback")
	} finally _CTC_ReleaseMenu(Built)
}
for _HSCS_UntypedPause in ["0", "false", "", 0.0]
	Test("shared-personal-editor: untyped native pause receipt " . Type(_HSCS_UntypedPause) . ":" . _HSCS_UntypedPause,
		_HSCS_PersonalEditorUntypedPause.Bind(_HSCS_UntypedPause))


; Observe the native opening callback outside the renderer's caught delivery.
_HSCS_FileOpened(Observations, Path, Receipt, *) {
	Observations.Push(Path)
	return Receipt
}

_HSCS_FileCommand(Receipt) {
	global _MenuDispatchCallbacks
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\menus\hotstring_file_command.json", "UTF-8"))
	Definition := _MR_GetMenuDef(Corpus["section"])
	AssertEqual(1, Definition.Length)
	Item := Definition[1]
	AssertEqual(Corpus["id"], Item["id"])
	AssertEqual(Corpus["i18n"], Item["i18n"])
	AssertEqual(Corpus["ready"], Item["disabled_when"][1])
	Label := Item["i18n"]
	Path := A_Temp . "\ergopti-category-command-" . A_TickCount . ".toml"
	Observations := [], Native := 0, Released := true
	try {
		Assert(FSWriteDurable(Path, "# owned category opening fixture`n"))
		AssertEqual(false, _HS_CategoryFileRow(Path, Map()), "an unknown supplied opening owner must refuse")
		Item["i18n"] := "menu.hotstrings.open_editor"
		Row := _HS_CategoryFileRow(Path, _HSCS_FileOpened.Bind(Observations, Path, Receipt))
		Assert(Row is Map, "the actual provider must admit the shared command")
		AssertEqual(t("menu.hotstrings.open_editor"), Row["label"],
			"native opening data comes from the declaration, not a private label")
		AssertEqual(Receipt, Row["action"].Call())
		AssertEqual(1, Observations.Length)
		AssertEqual(Path, Observations[1], "the actual opening owner receives its captured category source")
		Assert(Row["label"] != "", "the replacement declaration must name a native item")
		for Key in ["menu.hotstrings.scope_enable_all", "menu.hotstrings.scope_disable_all"]
			Assert(StrCompare(Row["label"], t(Key), false) != 0,
				"the file command must not replace an existing category caption")
		Native := _HS_CategoryMenu("Rolls", Path, [], (*) => false)
		AssertEqual(3, TrayMenuItemCount(Native), "two scope commands and the admitted file command are distinct native rows")
		AssertEqual(t("menu.hotstrings.scope_enable_all"), _SGM_LabelAt(Native, 0))
		AssertEqual(t("menu.hotstrings.scope_disable_all"), _SGM_LabelAt(Native, 1))
		EnableId := DllCall("GetMenuItemID", "Ptr", Native.Handle, "Int", 0, "UInt")
		DisableId := DllCall("GetMenuItemID", "Ptr", Native.Handle, "Int", 1, "UInt")
		FileId := DllCall("GetMenuItemID", "Ptr", Native.Handle, "Int", 2, "UInt")
		Assert(FileId != 0 && FileId != 0xFFFFFFFF && FileId != EnableId && FileId != DisableId,
			"the file command must own a separate native leaf identity")
		Assert(_MenuDispatchCallbacks.Has(FileId), "the real renderer must register that actual native command")
		AssertEqual(Row["label"], _SGM_LabelAt(Native, 2), "the actual category provider renders the same declaration")
		FileDelete(Path)
		AssertFalse(_MenuDispatchCallbacks[FileId].Call(), "the drawn native command rechecks its withdrawn category source")
		AssertEqual(false, Row["action"].Call(), "a held callback rechecks the native source before opening")
		AssertEqual(1, Observations.Length, "withdrawn source cannot launch its opening owner")
	} finally {
		Item["i18n"] := Label
		if Native is Menu {
			Released := false
			try {
				_CTC_ReleaseMenu(Native)
				Released := true
			}
		}
		if FileExist(Path)
			FileDelete(Path)
	}
	AssertTrue(Released, "the owned native category menu must be released without masking a primary failure")
}

for _HSCS_FileReceipt in [true, false]
	Test("shared category file: native opening receipt " . _HSCS_FileReceipt,
		_HSCS_FileCommand.Bind(_HSCS_FileReceipt))

; The actual boot owner must retain extension-bound categories after relocation.
_HSCS_DeclaredInventory() {
	_HSCS_WithDynamicBootState(Check)
	Check() {
		global _FLAT_HOTSTRING_V1_CATS, _V1CatToV2CatMap, _LegacyTopCategoryMap, HS_LANGUAGE_GATE_KEYS
		SavedLanguageKeys := HS_LANGUAGE_GATE_KEYS
		HS_LANGUAGE_GATE_KEYS := Map()
		HadFlat := IsSet(_FLAT_HOTSTRING_V1_CATS)
		SavedFlat := HadFlat ? _FLAT_HOTSTRING_V1_CATS : 0
		try {
			_FLAT_HOTSTRING_V1_CATS := [], _V1CatToV2CatMap := Map(), _LegacyTopCategoryMap := Map()
			_HS_RegisterLanguageMenuCategories()
			AssertEqual("hotstrings.french_distancesreduction", _LegacyTopCategoryMap.Get("FrenchDistancesReduction", ""),
				"the declared bound category must survive moving out of the language index")
			Inventory := _HotstringsCategoryScopeInventory(_LegacyTopCategoryMap)
			Assert(Inventory.Has("FrenchDistancesReduction"))
			AssertEqual(1, Inventory["FrenchDistancesReduction"].Length)
			AssertEqual("suffixes_a", Inventory["FrenchDistancesReduction"][1])
			Gates := Map("FrenchDistancesReduction", true)
			HotstringsSeedLanguageCategoryGates(Gates)
			AssertTrue(Gates["FrenchDistancesReduction"], "seeding preserves an explicit existing gate")
			AssertEqual("french_distancesreduction", _CategoryEnabledKey("FrenchDistancesReduction"))
			NeutralGates := Map()
			HotstringsSeedLanguageCategoryGates(NeutralGates)
			AssertEqual(ManifestDefaultFor("category_enabled.french_distancesreduction"), NeutralGates["FrenchDistancesReduction"])
			Groups := MenuManifest_LoadHotstringGroups(), Declared := _MG_LoadSubCategories()
			for Categories in [Groups.standard, Groups.ergopti]
				for Category in Categories {
					AssertEqual(Declared[Category], _V1CatToV2CatMap[Category])
					AssertEqual("hotstrings." . Declared[Category], _LegacyTopCategoryMap[Category])
				}
			Count := _FLAT_HOTSTRING_V1_CATS.Length, TopCount := _LegacyTopCategoryMap.Count
			_HS_RegisterLanguageMenuCategories()
			AssertEqual(Count, _FLAT_HOTSTRING_V1_CATS.Length, "a rebuild cannot duplicate flat categories")
			AssertEqual(TopCount, _LegacyTopCategoryMap.Count)
		} finally {
			HS_LANGUAGE_GATE_KEYS := SavedLanguageKeys
			_FLAT_HOTSTRING_V1_CATS := HadFlat ? SavedFlat : unset
		}
	}
}
Test("hotstring-extension-menu-owner: declared bound category inventory survives relocation", _HSCS_DeclaredInventory)

; Sparse persistence still proves the exact choice and deletion of neutral overrides.
_HSCS_AssertSparseSelection(Parsed, Section, Key, Path, Enabled) {
	Rows := Parsed.Get(Section, Map()), Neutral := ManifestDefaultFor(Path)
	AssertEqual(Enabled != Neutral, Rows.Has(Key), "only an explicit difference belongs in the cohort")
	AssertEqual(Enabled, Rows.Get(Key, Neutral), "every selected bound choice belongs to the cohort")
}


; Bind literal-bearing source matches to genuine executable owner tokens.
_HSCS_PersonalFrameStatement(Code, Pattern) {
	Masked := _DriverMaskNonCode(&Code)
	if !RegExMatch(Code, Pattern, &Found)
		return 0
	Position := Found.Pos(1), Token := Found[1]
	return SubStr(Masked, Position, StrLen(Token)) == Token ? Position : 0
}

; The same captured native editor row is supplied through both whole frames.
_HSCS_PersonalFrameDelegation(Body) {
	Capture := _HSCS_PersonalFrameStatement(Body,
		'm)^[ \t]*(EditorRow)[ \t]*:=[ \t]*_HS_PersonalEditorRow\(\(\*\)[ \t]*=>[ \t]*OpenPersonalEditor\(\)\)')
	Controls := _HSCS_PersonalFrameStatement(Body,
		'm)^[ \t]*(Controls)[ \t]*:=[ \t]*MenuRenderer_TemplateRows\("hotstring_personal_controls_frame",')
	Editor := _HSCS_PersonalFrameStatement(Body,
		'"personal_editor",[ \t]*\(\*\)[ \t]*=>[ \t]*(EditorRow)[ \t]+is[ \t]+Map[ \t]*\?[ \t]*\[EditorRow\][ \t]*:[ \t]*\[\]')
	Content := _HSCS_PersonalFrameStatement(Body,
		'm)^[ \t]*(PersonalRows)[ \t]*:=[ \t]*MenuRenderer_TemplateRows\("hotstring_personal_content_frame",')
	Binding := _HSCS_PersonalFrameStatement(Body,
		'"personal_controls",[ \t]*\(\*\)[ \t]*=>[ \t]*(Controls)(?:[ \t]*,)')
	Render := _HSCS_PersonalFrameStatement(Body,
		'm)^[ \t]*(_HS_CategoryMenu)\("Personal",[ \t]*"",[ \t]*PersonalRows,')
	return Capture && Controls && Editor && Content && Binding && Render
		&& Capture < Controls && Controls < Editor && Editor < Content && Content < Binding && Binding < Render
}

; Quote each actual source line separately: native PCRE masks short physical
; strings without the recursion depth of one whole-function continuation.
_HSCS_PersonalFrameQuotedData(Body) {
	Quoted := ""
	for Line in StrSplit(Body, "`n", "`r") {
		Escaped := StrReplace(Line, Chr(96), Chr(96) . Chr(96))
		Escaped := StrReplace(Escaped, "'", Chr(96) . "'")
		Quoted .= "QuotedData := '" . Escaped . "'`n"
	}
	return Quoted
}

_HSCS_PersonalFrameGuardRefuses(Kind) {
	Body := _DriverFuncBody("_HS_PersonalRows")
	Assert(Body != "")
	AssertTrue(_HSCS_PersonalFrameDelegation(Body), "the genuine native producer is admitted before mutation")
	if Kind == "capture"
		Mutant := StrReplace(Body, "EditorRow := _HS_PersonalEditorRow", "EditorRow := _HS_MissingEditorRow")
	else if Kind == "provider"
		Mutant := StrReplace(Body, '"personal_editor", (*) => EditorRow is Map ? [EditorRow] : []', '"personal_editor", (*) => []')
	else if Kind == "controls"
		Mutant := StrReplace(Body, 'MenuRenderer_TemplateRows("hotstring_personal_controls_frame",', 'MenuRenderer_TemplateRows("foreign_personal_controls",')
	else if Kind == "content"
		Mutant := StrReplace(Body, 'MenuRenderer_TemplateRows("hotstring_personal_content_frame",', 'MenuRenderer_TemplateRows("foreign_personal_content",')
	else if Kind == "binding"
		Mutant := StrReplace(Body, '"personal_controls", (*) => Controls,', '"personal_controls", (*) => [],')
	else if Kind == "render"
		Mutant := StrReplace(Body, '_HS_CategoryMenu("Personal", "", PersonalRows,', '_HS_CategoryMenu("Personal", "", [],')
	else if Kind == "quoted"
		Mutant := _HSCS_PersonalFrameQuotedData(Body)
	else
		Mutant := "/*`n" . Body . "`n*/"
	if Kind == "quoted" {
		; This non-anchored actual ownership pattern still matches the raw
		; quoted data. Only the canonical native mask removes its authority.
		Pattern := '"personal_controls",[ \t]*\(\*\)[ \t]*=>[ \t]*(Controls)(?:[ \t]*,)'
		Assert(RegExMatch(Mutant, Pattern), "the quoted actual owner still contains the original non-anchored binding")
		AssertEqual(0, _HSCS_PersonalFrameStatement(Mutant, Pattern), "physical quoted data must be masked even when its raw ownership pattern matches")
	}
	Assert(Mutant != Body, "the actual owner is changed by the independent source control")
	AssertFalse(_HSCS_PersonalFrameDelegation(Mutant), "missing or data-only frame delegation has no executable authority")
}
for _HSCS_PersonalFrameKind in ["capture", "provider", "controls", "content", "binding", "render", "quoted", "commented"]
	Test("shared-personal-frame: refuses " . _HSCS_PersonalFrameKind, _HSCS_PersonalFrameGuardRefuses.Bind(_HSCS_PersonalFrameKind))


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
