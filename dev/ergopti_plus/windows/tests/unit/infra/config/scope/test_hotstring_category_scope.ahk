; tests/unit/infra/config/scope/test_hotstring_category_scope.ahk

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
			Assert(FSWriteDurable(Fixture.path, Fixture.source))
			AssertTrue(ConfigSchemaCanPrepareWrite(Fixture.path), "the actual appended pack configuration keeps exactly one schema stamp and the genuine native boot owner")
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

; hotstrings-submenu-live-2026-10-17: every « check all » / « uncheck all »
; wrote config.toml through the reload journal and restarted the whole driver,
; which takes minutes on a real setup; each click queued behind it was refused
; (« another configuration transaction is already in progress »). A selection the
; in-process rebuild covers now applies live, like one section's checkbox, on a
; real boot-admitted config.toml. Only the live and reload effects are ports.
_HSCS_WithLiveConfig(Source, Gates, Body) {
	global ConfigurationFile, Features, CategoryEnabled, _LegacyTopCategoryMap, _ParseTomlCache
	Fixture := _ScopeOwnerFixture(Source)
	SavedPath := ConfigurationFile, SavedFeatures := Features, SavedCategories := CategoryEnabled
	SavedLegacy := IsSet(_LegacyTopCategoryMap) ? _LegacyTopCategoryMap : unset
	State := MasterGateState(), SavedState := State.Clone()
	Calls := { live: 0, reload: 0 }
	Live(*) {
		Calls.live += 1
		return true
	}
	Reload(*) {
		Calls.reload += 1
		return true
	}
	try {
		ConfigurationFile := Fixture.path
		_LegacyTopCategoryMap := Map("Rolls", "hotstrings.rolls", "MagicKey", "hotstrings.magic_key")
		Features := ManifestBuildFeaturesMap()
		ApplyConfigToml(Features, Fixture.path)
		CategoryEnabled := Gates
		State["initialized"] := false
		MasterGateInitialize(Features, Map("keys", Map()), IsCategoryGated)
		Body.Call(Fixture, Map("live", Live, "reload", Reload), Calls)
	} finally {
		ConfigurationFile := SavedPath, Features := SavedFeatures, CategoryEnabled := SavedCategories
		_LegacyTopCategoryMap := IsSet(SavedLegacy) ? SavedLegacy : unset
		State.Clear()
		for Key, Value in SavedState
			State[Key] := Value
		if _ParseTomlCache.Has(Fixture.path)
			_ParseTomlCache.Delete(Fixture.path)
		_ScopeOwnerCleanup(Fixture)
	}
}

; A sparse writer omits a value equal to its manifest default; read it back
; the way the real loader resolves it.
_HSCS_Stored(Parsed, Section, Key := "enabled") {
	if Parsed.Has(Section) && Parsed[Section].Has(Key)
		return Parsed[Section][Key]
	return ManifestDefaultFor(Section . "." . Key)
}

; Clicks the native « check all » (0) or « uncheck all » (1) command of Built.
_HSCS_ClickBulk(Built, Enabled) {
	global _MenuDispatchCallbacks
	Position := Enabled ? 0 : 1
	AssertEqual(t(Enabled ? "menu.hotstrings.scope_enable_all" : "menu.hotstrings.scope_disable_all"),
		_CTC_LabelAt(Built, Position))
	Id := DllCall("GetMenuItemID", "ptr", Built.Handle, "int", Position, "uint")
	Assert(_MenuDispatchCallbacks.Has(Id), "the native command must be registered")
	return _MenuDispatchCallbacks[Id].Call()
}

; Rolls: the gate follows the posture and the whole selection applies in-process.
_HSCS_CategoryMenuLive(Enabled) {
	Source := '[category_enabled]`nhotstrings = true`nrolls = ' . (Enabled ? "false" : "true")
		. '`nautocorrection = true`n[hotstrings.rolls.hc]`nenabled = ' . (Enabled ? "false" : "true")
		. '`ntime_activation_seconds = 0.75`n[hotstrings.magic_key.replace]`nenabled = true`n'
		. '[private]`ncredential = "retain-fixture-value"`n'
	_HSCS_WithLiveConfig(Source, Map("Hotstrings", true, "Rolls", !Enabled, "MagicKey", true), Check)
	Check(Fixture, Options, Calls) {
		global CategoryEnabled, Features
		Built := _HS_CategoryMenu("Rolls", "", [], (Targets, Requested) => ToggleCategoryAllSections(Targets[1], Requested, Options))
		try {
			AssertEqual(2, TrayMenuItemCount(Built), "empty providers leave exactly the two declared commands")
			AssertTrue(_HSCS_ClickBulk(Built, Enabled), "the selection commits")
		} finally _CTC_ReleaseMenu(Built)
		AssertEqual(1, Calls.live, "a Rolls selection applies in-process")
		AssertEqual(0, Calls.reload, "and never restarts the driver")
		Parsed := TOML_ParseFreshFile(Fixture.path)
		AssertEqual(Enabled, _HSCS_Stored(Parsed, "category_enabled", "rolls"), "the category gate follows the posture")
		AssertTrue(Parsed["category_enabled"]["hotstrings"], "the Hotstrings master is never written")
		AssertTrue(Parsed["category_enabled"]["autocorrection"], "another category keeps its gate")
		for Entry in ManifestFeaturesForSection("hotstrings.rolls")
			AssertEqual(Enabled, _HSCS_Stored(Parsed, Entry["path"]), "every own section is selected: " . Entry["path"])
		AssertEqual(0.75, Parsed["hotstrings.rolls.hc"]["time_activation_seconds"])
		AssertTrue(Parsed["hotstrings.magic_key.replace"]["enabled"], "an unrelated choice is retained")
		AssertEqual("retain-fixture-value", Parsed["private"]["credential"])
		AssertEqual(Enabled, CategoryEnabled["Rolls"], "the live gate is published with the write")
		Desired := MasterGateDesiredFeatures(Features)
		for Entry in ManifestFeaturesForSection("hotstrings.rolls") {
			Loc := FeatureLocateV2(Desired, Entry["path"])
			AssertEqual(Enabled, Loc["v2_node"][Loc["key"]], "the live desired state follows: " . Entry["path"])
		}
	}
}

; A section an extension binds is drawn in that extension's submenu, so the
; category's own « check all » never switches it (maintainer report 2026-10-17).
; Magic key also holds a reload-only section, so this selection reloads.
_HSCS_CategoryMenuKeepsBoundSections() {
	global _HotstringBoundSources
	Sections := ManifestFeaturesForSection("hotstrings.magic_key")
	Assert(Sections.Length > 2, "magic key declares several sections")
	BoundPath := ""
	for Entry in Sections
		if Entry["path"] != "hotstrings.magic_key.replace" {
			BoundPath := Entry["path"]
			break
		}
	Parts := StrSplit(BoundPath, ".")
	Source := '[category_enabled]`nhotstrings = true`nmagic_key = true`n[' . BoundPath . ']`nenabled = false`n'
	SavedBound := _HotstringBoundSources
	_HotstringBoundSources := Map("magickey", Map("path", "fixture.toml",
		"sections", Map(StrLower(Parts[3]), "fixture.toml")))
	try _HSCS_WithLiveConfig(Source, Map("Hotstrings", true, "Rolls", true, "MagicKey", true), Check)
	finally _HotstringBoundSources := SavedBound
	Check(Fixture, Options, Calls) {
		AssertTrue(ToggleCategoryAllSections("MagicKey", true, Options))
		AssertEqual(0, Calls.live, "the J-to-star replacement is reload-only")
		AssertEqual(1, Calls.reload)
		Parsed := TOML_ParseFreshFile(Fixture.path)
		AssertFalse(_HSCS_Stored(Parsed, BoundPath), "the extension's bound section is not this submenu's")
		for Entry in Sections
			if Entry["path"] != BoundPath
				AssertTrue(_HSCS_Stored(Parsed, Entry["path"]), "every own section is selected: " . Entry["path"])
	}
}

for _HSCS_Enabled in [true, false]
	Test("hotstring-category-menu: native command " . _HSCS_Enabled . " applies live (hotstrings-submenu-live)",
		_HSCS_CategoryMenuLive.Bind(_HSCS_Enabled))
Test("hotstring-category-menu: check all leaves extension-bound sections alone (hotstrings-submenu-live)",
	_HSCS_CategoryMenuKeepsBoundSections)

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

; Personal inventory is file-owned, not part of the manifest catalogue. A cached
; menu preview must not omit a section added before the configuration lease.
_HSCS_PersonalMenuLive(Enabled) {
	Source := '[category_enabled]`nhotstrings = false`nrolls = true`n[hotstrings.personal.first]`nenabled = '
		. (Enabled ? "false" : "true") . '`ntime_activation_seconds = 0.75`n[hotstrings.personal.future]`nenabled = false`n'
		. '[private]`ncredential = "retain-personal-fixture"`n'
	_HSCS_WithLiveConfig(Source, Map("Hotstrings", false, "Rolls", true), Check)
	Check(Fixture, Options, Calls) {
		global ScriptInformation, Features, CategoryEnabled, _ReadPersonalTomlCache
		global _PersonalExtTree, _FmtCountCache, _PrevDefaultLabel
		PersonalPath := Fixture.directory . "\personal.toml", Built := 0
		SavedInfo := ScriptInformation, SavedCache := _ReadPersonalTomlCache
		SavedTree := IsSet(_PersonalExtTree) ? _PersonalExtTree : unset
		SavedCounts := IsSet(_FmtCountCache) ? _FmtCountCache : unset
		SavedDefaultLabel := IsSet(_PrevDefaultLabel) ? _PrevDefaultLabel : unset
		try {
			ScriptInformation := ScriptInformation.Clone()
			ScriptInformation["PersonalTomlPath"] := PersonalPath
			_PersonalExtTree := Map(), _FmtCountCache := Map()
			_ConfigSeedPersonalHotstring(Features, "first")
			Assert(FSWriteDurable(PersonalPath, '[[first]]`n'))
			_ReadPersonalTomlCache := false
			AssertEqual(1, ReadPersonalToml()["sections_order"].Length)
			PersonalSource := '[[first]]`n[[second]]`n'
			Assert(FSWriteDurable(PersonalPath, PersonalSource))
			Rows := _HS_PersonalRows(Options)
			AssertEqual(1, Rows.Length, "the personal file must be a real rendered submenu")
			Built := Rows[1]["submenu"]
			AssertEqual(0, _CTC_CountLabel(Built, t("menu.hotstrings.enable_all_sections")))
			AssertEqual(0, _CTC_CountLabel(Built, t("menu.hotstrings.category_enable")))
			AssertTrue(_HSCS_ClickBulk(Built, Enabled), "one native click commits one selection")
			AssertEqual(1, Calls.live, "personal sections apply in-process")
			AssertEqual(0, Calls.reload)
			Parsed := TOML_ParseFreshFile(Fixture.path)
			for Name in ["first", "second"]
				AssertEqual(Enabled, _HSCS_Stored(Parsed, "hotstrings.personal." . Name),
					"fresh discovery selects every actual section, including uncached additions")
			AssertFalse(Parsed["category_enabled"]["hotstrings"])
			AssertTrue(Parsed["category_enabled"]["rolls"])
			AssertFalse(Parsed["hotstrings.personal.future"]["enabled"], "unlisted personal sections retain their settings")
			AssertEqual(0.75, Parsed["hotstrings.personal.first"]["time_activation_seconds"])
			AssertEqual("retain-personal-fixture", Parsed["private"]["credential"])
			AssertFalse(CategoryEnabled["Hotstrings"], "the engine master stays off")
			AssertEqual(PersonalSource, FSReadUtf8Exact(PersonalPath), "scope selection cannot rewrite the user's rules")
		} finally {
			if Built is Menu
				_CTC_ReleaseMenu(Built)
			ScriptInformation := SavedInfo, _ReadPersonalTomlCache := SavedCache
			_PersonalExtTree := IsSet(SavedTree) ? SavedTree : unset
			_FmtCountCache := IsSet(SavedCounts) ? SavedCounts : unset
			_PrevDefaultLabel := IsSet(SavedDefaultLabel) ? SavedDefaultLabel : unset
			try FileDelete(PersonalPath)
		}
	}
}

for _HSCS_Enabled in [true, false]
	Test("hotstring-personal-menu-owner: command " . _HSCS_Enabled . " applies live (hotstrings-submenu-live)",
		_HSCS_PersonalMenuLive.Bind(_HSCS_Enabled))

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


#Include %A_LineFile%\..\..\..\..\..\..\..\_shared\modules\hotstrings\personal_scope.ahk
