; tests/unit/test_hotstring_category_scope.ahk

; ==============================================================================
; MODULE: Hotstring Category Selection Parity (Windows)
; DESCRIPTION:
; Replays the independent shared corpus through the native policy port. A
; refused scope cannot emit a partial batch, and every valid category/section
; choice matches both Lua drivers, including the excluded layout remapping.
; ==============================================================================

_HSCS_CheckVector(Vector) {
	Inventory := Vector["inventory"]
	Targets := Vector["targets"].Clone()
	Before := Map()
	for Id, Sections in Inventory
		Before[Id] := Sections.Clone()
	Choices := HotstringsCategoryScopePlan(Inventory, Vector["targets"], Vector["enabled"], &Reason)
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

; The existing journal owns runtime admission and conditional rollback. Only
; replacement launch is injected; the typed source, backup and journal are real.
_HSCS_WithSource(Body) {
	global _LegacyTopCategoryMap
	Saved := IsSet(_LegacyTopCategoryMap) ? _LegacyTopCategoryMap : unset
	Fixture := _ScopeOwnerFixture()
	Fixture.source := '[category_enabled]`nhotstrings = false`nrolls = false`nautocorrection = true`n[hotstrings.rolls.hc]`nenabled = false`ntime_activation_seconds = 0.75`n[hotstrings.rolls.sx]`nenabled = true`n[hotstrings.magic_key.replace]`nenabled = true`n[private]`ncredential = "retain-fixture-value"`n'
	try {
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
			AssertEqual(true, Parsed["hotstrings.magic_key.replace"]["enabled"], "layout remapping is retained")
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
; Read its real literal declarations and use the actual feature-manifest owner:
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
	HadFeatures := IsSet(Features), OldFeatures := HadFeatures ? Features : 0
	HadTop := IsSet(_LegacyTopCategoryMap), OldTop := HadTop ? _LegacyTopCategoryMap : 0
	HadKeys := IsSet(_LegacyDynamicHotstringsKeyMap), OldKeys := HadKeys ? _LegacyDynamicHotstringsKeyMap : 0
	HadOrder := IsSet(_DYNAMIC_HOTSTRINGS_ORDER), OldOrder := HadOrder ? _DYNAMIC_HOTSTRINGS_ORDER : 0
	try {
		Source := _StripFullLineComments(FileRead(_DriverDir . "\ui\tray_menu.ahk", "UTF-8"))
		_LegacyTopCategoryMap := _HSCS_TrayMapLiteral(Source, "_LegacyTopCategoryMap")
		_LegacyDynamicHotstringsKeyMap := _HSCS_TrayMapLiteral(Source, "_LegacyDynamicHotstringsKeyMap")
		if !RegExMatch(Source, "ms)^global _DYNAMIC_HOTSTRINGS_ORDER := (\[.*?\])", &Found)
			throw Error("The tray boot owner has no dynamic hotstring order declaration.")
		_DYNAMIC_HOTSTRINGS_ORDER := JsonParse(Found[1])
		Assert(_DYNAMIC_HOTSTRINGS_ORDER is Array, "the real tray order must be an array")
		for Id in _DYNAMIC_HOTSTRINGS_ORDER {
			if Id == "-"
				continue
			Assert(_LegacyDynamicHotstringsKeyMap.Has(Id), "the boot order must name an owned dynamic family")
			Assert(ManifestFindEntryByPath("hotstrings.dynamic." . _LegacyDynamicHotstringsKeyMap[Id]) is Map,
				"the boot family must resolve through the real feature manifest")
		}
		Features := ManifestBuildFeaturesMap()
		Body.Call()
	} finally {
		Features := HadFeatures ? OldFeatures : unset
		_LegacyTopCategoryMap := HadTop ? OldTop : unset
		_LegacyDynamicHotstringsKeyMap := HadKeys ? OldKeys : unset
		_DYNAMIC_HOTSTRINGS_ORDER := HadOrder ? OldOrder : unset
	}
}

; Dynamic scopes have seven canonical families and no separate category gate.
; The native submenu reaches the same journal while the master or pause is off.
_HSCS_DynamicMenuOwner(Enabled, Outcome, Paused := false) {
	global Features, CategoryEnabled, _LegacyTopCategoryMap, _MenuDispatchCallbacks
	Fixture := _ScopeOwnerFixture(), Built := 0, Bundle := 0, Refusal := 0, Accepted := 0, Launches := 0
	Names := ["date", "date_fr", "date_long_fr", "phone_prefixes", "ssn_prefixes",
		"iban_prefixes", "text_expansion_personal_information"]
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
		Assert(FSWriteDurable(Fixture.path, Source))
		Fixture.source := Source
		Features := ManifestBuildFeaturesMap()
		ApplyConfigToml(Features, Fixture.path)
		CategoryEnabled := Map("Hotstrings", false, "Rolls", true)
		State["initialized"] := false
		MasterGateInitialize(Features, Map("keys", Map()), (*) => false)
		Suspend(Paused)
		RuntimeBefore := KL_JsonEncode(Features)
		Cached := ParseTomlFile(Fixture.path)
		Built := _BuildDynamicHotstringsSubmenu(Fixture.options)
		AssertEqual(12, TrayMenuItemCount(Built), "two shared commands, two separators, seven families and their editor")
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
			Target := ManifestBuildFeaturesMap()
			ApplyConfigToml(Target, Fixture.path)
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
