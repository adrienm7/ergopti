; tests/unit/infra/config/scope/test_hotstring_dynamic_menu_scope.ahk

; ==============================================================================
; MODULE: Dynamic Hotstrings Menu Scope
; DESCRIPTION:
; The dynamic hotstrings submenu runs its shipped command through the live
; configuration owner, refuses invalid postures before any write, and
; follows the shared command head, order and metadata.
; ==============================================================================

#Requires AutoHotkey v2.0





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
; The native submenu applies in-process while the master or pause is off. The
; programmable hotstrings keep their own row: a bulk click once switched them on
; (2026-10-17, « [hotstrings.dynamic.user_code] enabled = true »).
_HSCS_DynamicMenuLive(Enabled, Paused := false) {
	Names := ["date", "date_fr", "date_long_fr", "phone_prefixes", "ssn_prefixes",
		"iban_prefixes", "user_code", "text_expansion_personal_information"]
	Source := '[category_enabled]`nhotstrings = false`nrolls = true`n[hotstrings.dynamic]`nenabled = false`n'
	for Index, Name in Names {
		Value := Name == "user_code" ? !Enabled : Mod(Index, 2)
		Source .= '[hotstrings.dynamic.' . Name . ']`nenabled = ' . (Value ? "true" : "false") . '`n'
		if Name == "date"
			Source .= 'time_activation_seconds = 0.75`n'
	}
	Source .= '[hotstrings.dynamic.future_family]`nenabled = true`n[private]`ncredential = "retain-dynamic-fixture"`n'
	_HSCS_WithLiveConfig(Source, Map("Hotstrings", false, "Rolls", true), Check)
	Check(Fixture, Options, Calls) {
		global CategoryEnabled
		SavedSuspend := A_IsSuspended, Built := 0
		try {
			Suspend(Paused)
			Built := _BuildDynamicHotstringsSubmenu(Options)
			AssertEqual(12, TrayMenuItemCount(Built), "two shared commands, two separators, seven displayed families and their editor")
			AssertEqual(0, _CTC_CountLabel(Built, t("menu.hotstrings.enable_all_sections")), "the old checkbox is retired")
			AssertEqual(0, _CTC_CountLabel(Built, t("menu.hotstrings.category_enable")), "there is no invented dynamic category switch")
			AssertEqual(1, _CTC_CountLabel(Built, t("menu.shortcuts.edit_personal_info")), "the existing editor stays reachable")
			AssertTrue(_HSCS_ClickBulk(Built, Enabled), "one native click commits one whole-family selection")
			AssertEqual(Paused, A_IsSuspended, "the selection never resumes a paused driver")
		} finally {
			if Built is Menu
				_CTC_ReleaseMenu(Built)
			Suspend(SavedSuspend)
		}
		AssertEqual(1, Calls.live, "the dynamic families apply in-process")
		AssertEqual(0, Calls.reload)
		AssertFalse(CategoryEnabled["Hotstrings"], "the native engine master stays off")
		AssertTrue(CategoryEnabled["Rolls"], "another category keeps its native gate")
		AssertEqual(Names.Length, ManifestFeaturesForSection("hotstrings.dynamic").Length,
			"every current dynamic family belongs to the canonical inventory")
		Parsed := TOML_ParseFreshFile(Fixture.path)
		for Name in Names {
			if Name == "user_code"
				AssertEqual(!Enabled, _HSCS_Stored(Parsed, "hotstrings.dynamic.user_code"),
					"the programmable hotstrings are not part of the families' bulk selection")
			else
				AssertEqual(Enabled, _HSCS_Stored(Parsed, "hotstrings.dynamic." . Name), "the explicit posture of " . Name)
		}
		AssertFalse(Parsed["category_enabled"]["hotstrings"])
		AssertTrue(Parsed["category_enabled"]["rolls"])
		AssertFalse(Parsed["category_enabled"].Has("dynamichotstrings"), "no additional category gate is written")
		AssertFalse(Parsed["hotstrings.dynamic"]["enabled"], "an unrelated scalar keeps its stored value")
		AssertTrue(Parsed["hotstrings.dynamic.future_family"]["enabled"], "unrecognized future families stay untouched")
		AssertEqual(0.75, Parsed["hotstrings.dynamic.date"]["time_activation_seconds"])
		AssertEqual("retain-dynamic-fixture", Parsed["private"]["credential"])
	}
}

for _HSCS_Enabled in [true, false] {
	Test("hotstring-dynamic-menu-owner: command " . _HSCS_Enabled . " keeps the master and applies live (hotstrings-submenu-live)",
		_HSCS_WithDynamicBootState.Bind(_HSCS_DynamicMenuLive.Bind(_HSCS_Enabled)))
	Test("hotstring-dynamic-menu-owner: command " . _HSCS_Enabled . " preserves pause (hotstrings-submenu-live)",
		_HSCS_WithDynamicBootState.Bind(_HSCS_DynamicMenuLive.Bind(_HSCS_Enabled, true)))
}

_HSCS_DynamicInvalidPosture() {
	for Value in ["true", 2]
		_HSCS_DynamicInvalidPostureFor(Value)
}

; One invalid posture per call, so the refused closure reads its parameter and
; not the loop variable (test-ahk-loop-capture).
_HSCS_DynamicInvalidPostureFor(Value) {
	Launches := 0
	Count(*) {
		Launches += 1
		return true
	}
	Fixture := _ScopeOwnerFixture()
	try {
		AssertThrows(() => ToggleDynamicAllSections(Value, Map("live", Count, "reload", Count)),
			"an invalid request cannot publish a partial selection")
		AssertEqual(0, Launches)
		AssertEqual(Fixture.source, FSReadUtf8Exact(Fixture.path))
	} finally _ScopeOwnerCleanup(Fixture)
}
Test("hotstring-dynamic-menu-owner: invalid postures are refused before any write", _HSCS_DynamicInvalidPosture)

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
