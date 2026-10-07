; tests/unit/test_ergopti_extension_hotstrings.ahk

; ==============================================================================
; MODULE: Ergopti Extension Hotstrings (Windows)
; DESCRIPTION:
; SFB reduction, rolls and the magic key's repeat corrections moved from the
; shared hotstrings folder into the Ergopti layout extension. With the Ergopti
; extension the driver ships, they load from its files under their historical
; categories and sections, so every saved preference still addresses them, the
; counters and the prefix index follow the same files, and the typed outputs are
; the shared ones; without it, nothing supplies them.
; ==============================================================================

; Runs Callback with the routes one discovery commits, restoring the boot's.
_EHX_WithRoutes(RegistryDir, Callback) {
	global _HotstringBoundSources, HotstringGroupConfig, _HotstringsOverrides, _HSResolveCache
	global _HotstringExtensionPaths
	Saved := _HotstringBoundSources
	SavedGroups := HotstringGroupConfig, SavedOverrides := _HotstringsOverrides, SavedResolved := _HSResolveCache
	SavedPaths := _HotstringExtensionPaths
	HotstringGroupConfig := Map(), _HotstringsOverrides := Map(), _HSResolveCache := Map()
	_HotstringExtensionPaths := Map()
	Directory := _LCT_TempDir()
	try {
		Roots := HotstringExtensions_Roots(Directory, Directory . "missing-bundled", RegistryDir)
		Packs := HotstringExtensions_Prepare(ManifestBuildFeaturesMap(), Roots)
		Callback.Call(Packs)
	} finally {
		_HotstringBoundSources := Saved
		HotstringGroupConfig := SavedGroups, _HotstringsOverrides := SavedOverrides, _HSResolveCache := SavedResolved
		_HotstringExtensionPaths := SavedPaths
		DirDelete(Directory, true)
	}
}

; The first registered case of a trigger in one TOML section, as LoadHotstringsSection reads it.
_EHX_Entry(Path, Section, Trigger) {
	global _HOTSTRING_ENTRY_PATTERN
	Current := ""
	loop parse, FileRead(Path, "UTF-8"), "`n", "`r" {
		Line := Trim(A_LoopField, " `t")
		if RegExMatch(Line, "^\[+([^\[\]]+)\]+$", &Header) {
			Current := Header[1]
			continue
		}
		if (Current == Section && RegExMatch(Line, _HOTSTRING_ENTRY_PATTERN, &Match)
				&& UnescapeTomlString(Match[1]) == Trigger)
			return Map("output", UnescapeTomlString(Match[2]), "is_word", Match[3], "auto_expand", Match[4])
	}
	return 0
}

_EHX_ShippedGroupsLoadFromTheExtension() {
	_EHX_WithRoutes(_LCT_RegistryDir(), Check)
	Check(Packs) {
		Ergopti := 0
		for Pack in Packs
			if (Pack.id == "ergopti")
				Ergopti := Pack
		Assert(IsObject(Ergopti), "the Ergopti extension the driver ships is installed")
		AssertEqual("Ergopti+", Ergopti.name, "the shared pack keeps its plus in the display name")
		AssertEqual(6, Ergopti.bound_files.Length)
		AssertEqual(0, Ergopti.toml_files.Length, "none of its files becomes an ext: category")
		Registry := _LCT_RegistryDir() . "ergopti\hotstrings\"
		AssertEqual(Registry . "sfbsreduction.toml", HotstringsBoundTomlPath("sfbsreduction", "comma"))
		AssertEqual(Registry . "sfbsreduction.toml", HotstringsBundledTomlPath("SFBsReduction"),
			"the menu's spelling reaches the same file")
		AssertEqual(Registry . "rolls.toml", HotstringsBundledTomlPath("rolls"))
		AssertEqual(Registry . "repeatcorrections.toml", HotstringsBoundTomlPath("magickey", "repeat_corrections"))
		AssertEqual(Registry . "magickeyreplace.toml", HotstringsBoundTomlPath("magickey", "replace"))
		AssertEqual(Registry . "suffixes_a.toml", HotstringsBundledTomlPath("french_distancesreduction"))
		AssertEqual(24, CountTomlSection("french_distancesreduction", "suffixes_a"))
		AssertEqual(0, CountTomlSection("magickey", "replace"), "the native feature owns no fabricated mapping")
		AssertEqual("", HotstringsBoundTomlPath("magickey", "text_expansion_symbols"),
			"the other magic key sections stay bundled")
		Assert(InStr(HotstringsBundledTomlPath("magickey"), "\modules\hotstrings\magickey.toml"))
		AssertEqual(34, CountTomlHotstrings("sfbsreduction"))
		AssertEqual(35, CountTomlHotstrings("rolls"))
		AssertEqual(14, CountTomlSection("magickey", "repeat_corrections"))
		AssertEqual(CountTomlHotstrings("magickey", HotstringsBundledTomlPath("magickey")) + 14,
			CountTomlHotstrings("magickey"), "the magic key total counts its bound section")
		; One historical expansion per moved group, read the way the loader reads it.
		for Row in [["sfbsreduction", "comma", ",t", "pt"], ["rolls", "hc", "hc", "wh"],
				["magickey", "repeat_corrections", "ccê", "ccu"]] {
			Entry := _EHX_Entry(HotstringsBoundTomlPath(Row[1], Row[2]), Row[2], Row[3])
			Assert(IsObject(Entry), Row[1] . " carries " . Row[3])
			AssertEqual(Row[4], Entry["output"])
			AssertEqual("false", Entry["is_word"])
			AssertEqual("true", Entry["auto_expand"])
		}
		AssertEqual(HSE_PRIORITY_COMMON, _HSE_SourcePriority("rolls"), "the groups keep the common tier")
		Route := _HotstringBoundSources["magickey"]
		AssertEqual("ergopti", Route["section_extensions"]["repeat_corrections"],
			"the repeat corrections name the extension whose submenu lists them")
		AssertEqual("ergopti", _HotstringBoundSources["rolls"]["extension"])
		AssertEqual("ergopti", Route["section_extensions"]["replace"])
		AssertEqual("ergopti", _HotstringBoundSources["frenchdistancesreduction"]["extension"])
	}
}
Test("ergopti extension: the shipped groups load from the extension under their historical ids (ergopti-hotstrings-ext)",
	_EHX_ShippedGroupsLoadFromTheExtension)

; A successful boot discovery must not inflate the diagnostic's warning count
; by announcing that the sources it just routed are unsupported.
_EHX_BoundSourcesDoNotWarn() {
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _HealthCheckWarnCount
	SavedSink := _LOGGER_TEST_SINK
	SavedRepeat := _LOGGER_REPEAT_ENABLED
	SavedWarnings := _HealthCheckWarnCount
	try _TLOG_Isolated(Check)
	finally {
		_LOGGER_TEST_SINK := SavedSink
		_LOGGER_REPEAT_ENABLED := SavedRepeat
		_HealthCheckWarnCount := SavedWarnings
	}
	Check() {
		global _LOGGER_REPEAT_ENABLED, _HealthCheckWarnCount
		_ResetLogger()
		_LOGGER_REPEAT_ENABLED := false
		Captured := []
		LoggerSetTestSink((Line) => Captured.Push(Line))
		LoggerWarn("ExtensionReadinessTest", "Warning capture is active.")
		AssertEqual(1, Captured.Length, "the sink must observe enabled warnings")
		AssertContains(Captured[1], "[WARNING] [ExtensionReadinessTest]")
		Captured.Length := 0
		Before := _HealthCheckWarnCount
		_EHX_WithRoutes(_LCT_RegistryDir(), CheckSources)
		for Line in Captured
			Assert(!InStr(Line, "[WARNING]"), "available extension sources must not warn: " . Line)
		AssertEqual(Before, _HealthCheckWarnCount,
			"successful source routing must not raise the diagnostic warning count")
	}
	CheckSources(Packs) {
		Assert(Packs.Length > 0, "the real shipped registry must discover an extension")
		AssertEqual(83, CountTomlHotstrings("sfbsreduction") + CountTomlHotstrings("rolls")
			+ CountTomlSection("magickey", "repeat_corrections"), "all three routed sources remain readable")
	}
}
Test("ergopti extension: available bound sources do not report unsupported loading (bound-source-warning)",
	_EHX_BoundSourcesDoNotWarn)

_EHX_NotInstalledSuppliesNothing() {
	Directory := _LCT_TempDir()
	try _EHX_WithRoutes(Directory . "missing-registry\", Check)
	finally DirDelete(Directory, true)
	Check(Packs) {
		AssertEqual(0, Packs.Length)
		AssertEqual("", HotstringsBoundTomlPath("rolls"))
		AssertEqual("", HotstringsBoundTomlPath("magickey", "repeat_corrections"))
		AssertEqual(0, CountTomlHotstrings("sfbsreduction"), "no file supplies SFB reduction")
		AssertEqual(0, CountTomlHotstrings("distancesreduction"), "no file supplies common distance reduction")
		AssertEqual(0, CountTomlSection("magickey", "repeat_corrections"))
	}
}
Test("ergopti extension: without the Ergopti extension the groups are absent (ergopti-hotstrings-ext)",
	_EHX_NotInstalledSuppliesNothing)

_EHX_CacheCompilesOnlyTheBundledFolder() {
	for Cat in HotstringsBundledCategories() {
		Assert(Cat != "distancesreduction" && Cat != "sfbsreduction" && Cat != "rolls",
			"a category an extension supplies never enters the bundled cache: " . Cat)
	}
}
Test("ergopti extension: the bundled cache no longer compiles the moved groups (ergopti-hotstrings-ext)",
	_EHX_CacheCompilesOnlyTheBundledFolder)

_EHX_MenuListsBoundCategoriesUnderTheExtension() {
	Rows := _DriverFuncBody("_HS_ExtensionRows")
	Assert(Rows != "", "the extension rows provider must resolve")
	Assert(InStr(Rows, "_HS_BoundCategoryRows(Ext.id)") > 0,
		"each extension submenu lists the categories it binds (SFB reduction and rolls for Ergopti)")
	Assert(InStr(Rows, 't("menu.extensions.hotstrings_of")') > 0,
		"each extension submenu is labelled « Hotstrings <extension> »")
	Bound := _DriverFuncBody("_HS_BoundCategoryRows")
	Assert(Bound != "", "the bound category rows builder must resolve")
	Assert(InStr(Bound, '_HotstringBoundSources[Key]["extension"] != ExtensionId') > 0,
		"a category is listed under the extension that binds it, and only there")
	Assert(InStr(_DriverSourceNoComments(), '"hotstring_categories_ergopti"') == 0,
		"the « Disposition Ergopti » section is gone from the hotstrings menu")
	Assert(InStr(Bound, "_HS_BoundSectionRows(ExtensionId, Result)") > 0,
		"the submenu also lists the sections the extension binds (the repeat corrections)")
	Sections := _DriverFuncBody("_HS_BoundSectionRows")
	Assert(Sections != "", "the bound section rows builder must resolve")
	Assert(InStr(Sections, "MenuRowFromManifest(Entry, Category)") > 0,
		"a bound section keeps its manifest row, so its switch is the historical preference")
	SubMenusBody := _DriverFuncBody("InitSubMenus")
	Assert(SubMenusBody != "", "the category submenus builder must resolve")
	Assert(InStr(SubMenusBody, "HotstringsBoundSections(V1Cat).Has(StrLower(SecId))") > 0,
		"a bound section leaves its category's submenu (the magic key's repeat corrections)")
}
Test("ergopti extension: the Hotstrings menu lists the groups under « Hotstrings Ergopti » (ergopti-hotstrings-ext)",
	_EHX_MenuListsBoundCategoriesUnderTheExtension)

_EHX_NoExtensionCategoryRowsWithoutRoutes() {
	_EHX_WithRoutes(A_Temp . "\ergopti-missing-registry-" . A_TickCount . "\", Check)
	Check(Packs) {
		Bound := _HS_BoundCategoryRows("ergopti")
		AssertEqual(0, Bound.rows.Length, "an extension that is not installed lists no category")
		AssertEqual(0, Bound.total)
	}
}
Test("ergopti extension: without the extension its submenu lists no category (ergopti-hotstrings-ext)",
	_EHX_NoExtensionCategoryRowsWithoutRoutes)

; The settings window and its « reset all » scope list a category's sections
; from its files: the repeat corrections now live in the extension's file, and
; a per-section delay, colour or priority saved for them must stay reachable.
_EHX_SettingsWindowKeepsTheBoundSection() {
	_EHX_WithRoutes(_LCT_RegistryDir(), Check)
	Check(Packs) {
		Entry := { Key: "magickey", Path: "", IsPersonal: false, IsExtension: false }
		Names := []
		Titles := Map()
		for _, Section in _HCW_GetSections(Entry) {
			Names.Push(Section.Name)
			Titles[Section.Name] := Section.Title
		}
		Assert(Titles.Has("repeat_corrections"),
			"the settings window lists the repeat corrections the extension binds into the magic key")
		Assert(InStr(Titles["repeat_corrections"], "(" . Chr(0xEA) . Chr(0x2192) . "u)") > 0,
			"with the localized description the extension's file gives it, not its raw id")
		; « replace » is a module placeholder with no [[section]], so the magic
		; key's order puts the repeat corrections first, as before they moved.
		AssertEqual("repeat_corrections", Names[1], "at the place the magic key's own order gives it")
		Assert(Titles.Has("text_expansion_symbols"), "the bundled sections are still listed")
		Scope := Map()
		for _, Section in _HotstringsScopeSections(Entry)
			Scope[Section.Name] := true
		Assert(Scope.Has("repeat_corrections"), "and « reset all » clears the overrides saved for it")
	}
}
Test("ergopti extension: the settings window keeps the repeat corrections row (ergopti-hotstrings-ext)",
	_EHX_SettingsWindowKeepsTheBoundSection)

; The menu consumes the discovered name, without renaming historical ids.
_EHX_ShippedLabelInMenu() {
	global _HS_ExtensionsCacheLoaded, _HS_ExtensionsCache
	global HotstringCategoriesStd, HotstringCategoriesErgopti, SubMenus
	Saved := [_HS_ExtensionsCacheLoaded, _HS_ExtensionsCache]
	SavedStd := IsSet(HotstringCategoriesStd) ? HotstringCategoriesStd : unset
	SavedErgopti := IsSet(HotstringCategoriesErgopti) ? HotstringCategoriesErgopti : unset
	SavedMenus := IsSet(SubMenus) ? SubMenus : unset
	try {
		; The unit runner omits main's category discovery. This name-only case
		; owns a neutral menu context without changing another case's globals.
		HotstringCategoriesStd := [], HotstringCategoriesErgopti := [], SubMenus := Map()
		_EHX_WithRoutes(_LCT_RegistryDir(), Check)
	} finally {
		_HS_ExtensionsCacheLoaded := Saved[1], _HS_ExtensionsCache := Saved[2]
		HotstringCategoriesStd := IsSet(SavedStd) ? SavedStd : unset
		HotstringCategoriesErgopti := IsSet(SavedErgopti) ? SavedErgopti : unset
		SubMenus := IsSet(SavedMenus) ? SavedMenus : unset
	}
	Check(Packs) {
		for Pack in Packs {
			if Pack.id != "ergopti"
				continue
			_HS_ExtensionsCache := [Pack], _HS_ExtensionsCacheLoaded := true
			Rows := _HS_ExtensionRows()
			AssertEqual(1, Rows.Length)
			Prefix := StrReplace(t("menu.extensions.hotstrings_of"), "%s", "Ergopti+")
			Assert(InStr(Rows[1]["label"], Prefix . " (") == 1, "the actual menu provider keeps the plus")
			return
		}
		throw Error("The shipped extension must be discovered before inspecting its menu.")
	}
}
Test("ergopti extension: the actual Hotstrings menu names Ergopti+", _EHX_ShippedLabelInMenu)

; Replay the independent pre-move reference through the native loader, never a
; synthetic registrar that could agree with a changed source by construction.
_EHX_DistanceReferenceLoadsNatively() {
	_EHX_WithRoutes(_LCT_RegistryDir(), Check)
	Check(Packs) {
		global HSE_RegistryByGroup, _SharedDir
		CorpusPath := _SharedDir . "\tests\corpus\hotstrings\distance_reduction_entries.json"
		Reference := JsonParse(FileRead(CorpusPath, "UTF-8"))
		AssertEqual(101, Reference["entries"].Length)
		AssertEqual(101, CountTomlHotstrings("distancesreduction"))
		AssertEqual("ergopti", _HotstringBoundSources["distancesreduction"]["extension"])
		Assert(!FileExist(_SharedDir . "\modules\hotstrings\distancesreduction.toml"),
			"the common folder must not duplicate the extension's file")
		HSE_TestReset()
		try {
			for Section, Count in Reference["section_counts"] {
				AssertEqual(Count, CountTomlSection("distancesreduction", Section))
				LoadHotstringsSection("distancesreduction", Section, { Enabled: true })
			}
			for Row in Reference["entries"] {
				Group := "distancesreduction." . Row["section"]
				Assert(HSE_RegistryByGroup.Has(Group), "the real loader registers " . Group)
				Found := 0
				for Spec in HSE_RegistryByGroup[Group]
					if Spec.Trigger == Row["trigger"] {
						Found := Spec
						break
					}
				Assert(IsObject(Found), "the real loader registers " . Row["trigger"])
				AssertEqual(Row["output"], Found.Replacement)
				AssertEqual(Row["is_word"], Found.IsWord)
				AssertEqual(Row["auto_expand"], Found.Auto)
				AssertEqual(Row["final_result"], Found.FinalResult)
				AssertEqual(!Row["is_case_sensitive"] && !InStr(Row["trigger"], ",") && !InStr(Row["trigger"], Chr(0x27)),
					Found.HasOwnProp("CaseConform") && Found.CaseConform, "comma rules retain explicit shifted-symbol variants")
				AssertEqual(HSE_PRIORITY_COMMON, Found.Priority, "relocation must keep the common tier")
				Delay := Row["section"] == "comma_j" ? Reference["meta"]["section_delays"]["comma_j"] : Reference["meta"]["delay"]
				AssertEqual(Delay, Found.TimeActivationSeconds, "historical delays survive relocation")
			}
		} finally HSE_TestReset()
	}
}
Test("ergopti extension: all 101 distance rules load natively from the historical reference (ergopti-distance-ext)",
	_EHX_DistanceReferenceLoadsNatively)

; Exercise the real sparse writer and configuration reader before and after
; extension rediscovery. Moving a source never changes a desired posture.
_EHX_DistanceChoicesSurviveReload(GroupEnabled) {
	_EHX_WithRoutes(_LCT_RegistryDir(), Check)
	Check(Packs) {
		Directory := _LCT_TempDir()
		try {
			ConfigPath := Directory . "config.toml"
			Assert(TOML_BatchWrite(ConfigPath, _ConfigPrepareTypedUpdates([
				ManifestSparseOperation("category_enabled.distances_reduction", GroupEnabled),
				ManifestSparseOperation("hotstrings.distances_reduction.qu.enabled", true),
				ManifestSparseOperation("hotstrings.distances_reduction.comma_j.enabled", false)])))
			Before := FSReadUtf8Exact(ConfigPath)
			Roots := HotstringExtensions_Roots(Directory, Directory . "missing-bundled", _LCT_RegistryDir())
			loop 2 {
				Target := ManifestBuildFeaturesMap()
				HotstringExtensions_Prepare(Target, Roots)
				ApplyConfigToml(Target, ConfigPath)
				HotstringExtensions_Prepare(Target, Roots)
				_EHX_DistanceGateReadByNativeOwner(ConfigPath, GroupEnabled)
				for Path, Expected in Map("hotstrings.distances_reduction.qu.enabled", true,
					"hotstrings.distances_reduction.comma_j.enabled", false) {
					Location := FeatureLocateV2(Target, Path)
					AssertEqual(Expected, Location["v2_node"][Location["key"]])
				}
				AssertEqual(Before, FSReadUtf8Exact(ConfigPath), "rediscovery must never rewrite the user's choices")
				AssertEqual(101, CountTomlHotstrings("distancesreduction"))
			}
		} finally DirDelete(Directory, true)
	}
}
Test("ergopti extension: disabled distance group survives native owner reload (ergopti-distance-ext)",
	_EHX_DistanceChoicesSurviveReload.Bind(false))
Test("ergopti extension: disabled distance section survives native owner reload (ergopti-distance-ext)",
	_EHX_DistanceChoicesSurviveReload.Bind(true))

_EHX_UserDistanceCopyWins() {
	_EHX_WithRoutes(_LCT_RegistryDir(), Check)
	Check(Packs) {
		Directory := _LCT_TempDir()
		try {
			DirCreate(Directory . "extensions")
			UserPack := Directory . "extensions\ergopti"
			DirCopy(_LCT_RegistryDir() . "ergopti", UserPack)
			UserPath := UserPack . "\hotstrings\distancesreduction.toml"
			Source := '[_meta]`nsections_order = ["qu"]`n[[qu]]`n'
				. '"qa" = { output = "user distance", is_word = false, auto_expand = true, is_case_sensitive = false, final_result = false }`n'
			Assert(FSWriteDurable(UserPath, Source))
			Roots := HotstringExtensions_Roots(Directory, Directory . "missing-bundled", _LCT_RegistryDir())
			HotstringExtensions_Prepare(ManifestBuildFeaturesMap(), Roots)
			AssertEqual(UserPath, HotstringsBoundTomlPath("distancesreduction", "qu"))
			AssertEqual(1, CountTomlHotstrings("distancesreduction"), "the shipped file must not add duplicates to an explicit user copy")
			Entry := _EHX_Entry(UserPath, "qu", "qa")
			Assert(IsObject(Entry), "the real source still contains the user rule")
			AssertEqual("user distance", Entry["output"])
			AssertEqual(Source, FSReadUtf8Exact(UserPath), "discovery must retain exact user-source bytes")
			AssertEqual(HSE_PRIORITY_COMMON, _HSE_SourcePriority("distancesreduction"))
		} finally DirDelete(Directory, true)
	}
}
Test("ergopti extension: the user's distance source keeps precedence and exact bytes (ergopti-distance-ext)",
	_EHX_UserDistanceCopyWins)

; CategoryEnabled is a separate production owner, intentionally absent from
; the unit runner's stub. Read the same source through its boot smoke process.
_EHX_DistanceGateReadByNativeOwner(Path, Expected) {
	Harness := A_ScriptDir . "\support\feature_state_boot_smoke.ahk"
	Quote := Chr(34)
	Command := Quote . A_AhkPath . Quote . " " . Quote . Harness . Quote
		. " distance_gate " . Quote . Path . Quote . " " . (Expected ? "true" : "false")
	AssertEqual(0, RunWait(Command, A_ScriptDir, "Hide"), "the actual gate owner preserves the distance choice")
}


; Independently authored original suffix vectors, exercised through the real loader.
_EHX_SuffixesLoadNatively() {
	_EHX_WithRoutes(_LCT_RegistryDir(), Check)
	Check(Packs) {
		global HSE_RegistryByGroup
		Expected := [
			["à'", "ance"], ["àa", "aire"], ["àc", "ction"], ["àd", "would"],
			["àê", "able"], ["àf", "iste"], ["àg", "ought"], ["àh", "ight"],
			["ài", "ying"], ["àk", "ique"], ["àl", "elle"], ["àm", "isme"],
			["àn", "ation"], ["àp", "ence"], ["àq", "ique"], ["àr", "erre"],
			["às", "ement"], ["àt", "ettre"], ["àv", "ment"], ["àx", "ieux"],
			["àz", "ez-vous"], ["à’", "ance"], ["càd", "could"], ["shàd", "should"]]
		AssertEqual(24, CountTomlSection("french_distancesreduction", "suffixes_a"))
		HSE_TestReset()
		try {
			LoadHotstringsSection("french_distancesreduction", "suffixes_a", { Enabled: true })
			Group := "french_distancesreduction.suffixes_a"
			Assert(HSE_RegistryByGroup.Has(Group), "the native registry admits the bound suffix category")
			Previous := 0
			for Row in Expected {
				Found := 0
				for Spec in HSE_RegistryByGroup[Group]
					if Spec.Trigger == Row[1] {
						Found := Spec
						break
					}
				Assert(IsObject(Found), "the native loader registers " . Row[1])
				AssertEqual(Row[2], Found.Replacement)
				AssertEqual(false, Found.IsWord)
				AssertEqual(true, Found.Auto)
				AssertEqual(false, Found.FinalResult)
				AssertEqual(HSE_PRIORITY_COMMON, Found.Priority)
				AssertEqual(0.5, Found.TimeActivationSeconds)
				Assert(Found.Seq > Previous, "canonical suffixes retain historical registration order")
				Previous := Found.Seq
			}
		} finally HSE_TestReset()
	}
}
Test("ergopti extension: every relocated suffix loads through the native registry (ergopti-suffixes-ext)",
	_EHX_SuffixesLoadNatively)


; The exact native empty-file presentation consumes its current declaration.
_EHX_EmptyExtensionDeclaration() {
	global _HS_ExtensionsCacheLoaded, _HS_ExtensionsCache
	Root := _MR_GetManifestRoot()
	Original := Root["hotstring_extension_empty_file"]
	Saved := [_HS_ExtensionsCacheLoaded, _HS_ExtensionsCache]
	try {
		_HS_ExtensionsCacheLoaded := true, _HS_ExtensionsCache := []
		Rows := _HS_ExtensionRows()
		Assert(Rows is Array && Rows.Length == 1)
		AssertEqual(t("menu.extensions.empty"), Rows[1]["label"])
		AssertEqual(true, Rows[1]["disabled"])
		Assert(!Rows[1].Has("action"), "the old empty-file status remains inert")
		Marker := Original[1].Clone()
		Marker["i18n"] := "button.ok"
		Root["hotstring_extension_empty_file"] := [Marker]
		AssertEqual(t("button.ok"), _HS_ExtensionRows()[1]["label"], "the native provider reads the published caption")
		Root.Delete("hotstring_extension_empty_file")
		AssertEqual(0, _HS_ExtensionRows().Length, "missing empty-file presentation refuses")
		Marker["foreign_field"] := true
		Root["hotstring_extension_empty_file"] := [Marker]
		AssertEqual(0, _HS_ExtensionRows().Length, "malformed inert presentation refuses")
		Root["hotstring_extension_empty_file"] := Original
		AssertEqual(1, _HS_ExtensionRows().Length, "repair restores the genuine provider")
	} finally {
		Root["hotstring_extension_empty_file"] := Original
		_HS_ExtensionsCacheLoaded := Saved[1], _HS_ExtensionsCache := Saved[2]
	}
}
Test("hotstring extension frame: the actual empty native provider consumes current inert declaration",
	_EHX_EmptyExtensionDeclaration)

; Discovery is genuine; this fixture owns a neutral category context, as the
; existing shipped-label case does, while retaining the actual scope commands.
_EHX_InstalledExtensionFrame() {
	global _HS_ExtensionsCacheLoaded, _HS_ExtensionsCache
	global HotstringCategoriesStd, HotstringCategoriesErgopti, SubMenus
	Root := _MR_GetManifestRoot()
	Original := Root["hotstring_extension_content_frame"]
	SavedCache := [_HS_ExtensionsCacheLoaded, _HS_ExtensionsCache]
	SavedStd := IsSet(HotstringCategoriesStd) ? HotstringCategoriesStd : unset
	SavedErgopti := IsSet(HotstringCategoriesErgopti) ? HotstringCategoriesErgopti : unset
	SavedMenus := IsSet(SubMenus) ? SubMenus : unset
	try {
		HotstringCategoriesStd := [], HotstringCategoriesErgopti := [], SubMenus := Map()
		_EHX_WithRoutes(_LCT_RegistryDir(), Check)
	} finally {
		Root["hotstring_extension_content_frame"] := Original
		_HS_ExtensionsCacheLoaded := SavedCache[1], _HS_ExtensionsCache := SavedCache[2]
		HotstringCategoriesStd := IsSet(SavedStd) ? SavedStd : unset
		HotstringCategoriesErgopti := IsSet(SavedErgopti) ? SavedErgopti : unset
		SubMenus := IsSet(SavedMenus) ? SavedMenus : unset
	}
	Check(Packs) {
		global _HS_ExtensionsCacheLoaded, _HS_ExtensionsCache, _MenuDispatchCallbacks
		for Pack in Packs {
			if Pack.id != "ergopti"
				continue
			_HS_ExtensionsCacheLoaded := true, _HS_ExtensionsCache := [Pack]
			Rows := _HS_ExtensionRows()
			Assert(Rows is Array && Rows.Length == 1, "genuine discovery reaches the complete installed frame")
			Items := Rows[1]["items"]
			AssertEqual(3, Items.Length, "empty native catalogue precedes the two existing scope commands")
			AssertEqual(t("menu.extensions.empty"), Items[1]["label"])
			AssertEqual(t("menu.hotstrings.scope_enable_all"), Items[2]["label"])
			AssertEqual(t("menu.hotstrings.scope_disable_all"), Items[3]["label"])
			AssertEqual(true, Items[1]["disabled"])
			Assert(!Items[1].Has("action"))
			Native := Menu()
			try {
				MenuRenderer_AppendRows(Native, "hotstrings_menu", "hotstring_extensions", Items)
				AssertEqual(3, DllCall("GetMenuItemCount", "Ptr", Native.Handle, "Int"))
				for Index in [1, 2] {
					Id := DllCall("GetMenuItemID", "Ptr", Native.Handle, "Int", Index, "UInt")
					Assert(_MenuDispatchCallbacks.Has(Id), "each actual scope item retains its genuine dispatch binding")
				}
				Root.Delete("hotstring_extension_content_frame")
				AssertEqual(0, _HS_ExtensionRows().Length, "withdrawal refuses the installed provider")
				Root["hotstring_extension_content_frame"] := Original
				Foreign := []
				for Row in Original
					Foreign.Push(Row.Clone())
				Foreign[3]["id"] := "foreign_extension_bound_head"
				Root["hotstring_extension_content_frame"] := Foreign
				AssertEqual(0, _HS_ExtensionRows().Length, "an unbound declared child refuses the whole frame")
				Root["hotstring_extension_content_frame"] := Original
				AssertEqual(1, _HS_ExtensionRows().Length, "repair preserves the real extension submenu")
			} finally {
				try Native.Delete()
				finally MenuDispatcher_PruneMenu(Native)
			}
			return
		}
		throw Error("The genuine shipped extension is required for the native frame test.")
	}
}
Test("hotstring extension frame: genuine installed catalogue retains order, native scope callbacks and withdrawal",
	_EHX_InstalledExtensionFrame)


; Actual discovered TOML files allocate their native children before final frame
; admission. Refusal must dispose only those children and preserve existing owners.
_EHX_FilePackRefusalOwnsNativeChildren() {
	global _HotstringExtensionPaths, HotstringGroupConfig, _HotstringBoundSources
	SavedPaths := _HotstringExtensionPaths, SavedGroups := HotstringGroupConfig
	SavedBoundSources := _HotstringBoundSources
	try {
		; Prepare mutates its routing maps. Keep the real caller-owned maps private
		; while the inherited file-pack helper performs its genuine source work.
		_HotstringExtensionPaths := Map(), HotstringGroupConfig := Map()
		_L4R_WithPack(Check)
	} finally {
		_HotstringExtensionPaths := SavedPaths, HotstringGroupConfig := SavedGroups
		_HotstringBoundSources := SavedBoundSources
		; Keep resolver generations monotonic after restoring the actual owners.
		HotstringsResolveBumpGen()
	}
	Check(PackRoot, SourcePath) {
		global Features, CategoryEnabled, _HS_ExtensionsCacheLoaded, _HS_ExtensionsCache, _HotstringExtensionPacks
		global HotstringCategoriesStd, HotstringCategoriesErgopti, SubMenus
		global _MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatchTokens
		global _MenuDispatchClickSequences, _MenuDispatchOwnerHandles
		Root := _MR_GetManifestRoot()
		Original := Root["hotstring_extension_content_frame"]
		SavedFeatures := Features, SavedCategories := CategoryEnabled, SavedPacks := _HotstringExtensionPacks
		SavedCache := [_HS_ExtensionsCacheLoaded, _HS_ExtensionsCache]
		SavedStd := IsSet(HotstringCategoriesStd) ? HotstringCategoriesStd : unset
		SavedErgopti := IsSet(HotstringCategoriesErgopti) ? HotstringCategoriesErgopti : unset
		SavedMenus := IsSet(SubMenus) ? SubMenus : unset
		State := MasterGateState(), SavedState := State.Clone()
		Owned := []
		ReadRows() {
			Rows := _HS_ExtensionRows()
			if Rows is Array {
				for ExtensionRow in Rows {
					if !ExtensionRow.Has("items")
						continue
					for Item in ExtensionRow["items"]
						if Item.Has("submenu") && Item["submenu"] is Menu
							Owned.Push(Item["submenu"])
				}
			}
			return Rows
		}
		try {
			Features := ManifestBuildFeaturesMap()
			_HotstringExtensionPacks := HotstringExtensions_Prepare(Features, [PackRoot])
			AssertEqual(1, _HotstringExtensionPacks.Length)
			AssertEqual(1, _HotstringExtensionPacks[1].toml_files.Length)
			AssertEqual(SourcePath, _HotstringExtensionPacks[1].toml_files[1].path)
			Features["hotstrings"]["groups"]["ext:sample:words"] := true
			State["initialized"] := false
			CategoryEnabled := Map("Hotstrings", false)
			MasterGateInitialize(Features, Map("keys", Map()), (*) => false)
			HotstringCategoriesStd := [], HotstringCategoriesErgopti := [], SubMenus := Map()
			_HS_ExtensionsCacheLoaded := true, _HS_ExtensionsCache := _HotstringExtensionPacks
			Source := FSReadUtf8Exact(SourcePath)
			File := _HotstringExtensionPacks[1].toml_files[1]
			AssertEqual(SourcePath, File.path)
			AssertEqual(2, File.sections.Length, "the complete genuine file catalogue contains both sections")
			Wanted := false, Hidden := false
			for Section in File.sections {
				if Section["name"] == "wanted"
					Wanted := Section
				else if Section["name"] == "hidden"
					Hidden := Section
			}
			Assert(Wanted is Map && Hidden is Map, "both ordered inputs are authentic scanned section records")
			AssertEqual("wanted", Wanted["name"])
			AssertEqual("hidden", Hidden["name"])
			AssertEqual(2, Wanted["count"])
			AssertEqual(1, Hidden["count"])
			; Scan's Counts Map has no physical-source ordering contract. This
			; private complete Array owns wanted/hidden order without replacing records.
			File.sections := [Wanted, Hidden]
			Assert(File.sections[1] == Wanted && File.sections[2] == Hidden, "the exact original record identities supply the controlled order")
			AssertEqual(Source, FSReadUtf8Exact(SourcePath), "ordering the owned catalogue preserves the whole physical source")
			Cleaner := Menu()
			try Cleaner.Delete()
			finally MenuDispatcher_PruneMenu(Cleaner)
			Maps := [_MenuDispatchCallbacks, _MenuDispatchLastFire, _MenuDispatchTokens,
				_MenuDispatchClickSequences, _MenuDispatchOwnerHandles]
			Before := []
			for Table in Maps
				Before.Push(Table.Clone())
			Rows := ReadRows()
			Assert(Rows is Array && Rows.Length == 1, "the actual file catalogue reaches the native frame")
			AssertEqual(1, Owned.Length, "one actual native file child transfers to the successful caller")
			Assert(_MenuDispatchCallbacks.Count > Before[1].Count, "the real child registered genuine callbacks")
			AssertEqual("Wanted (2)", _CTC_LabelAt(Owned[1], 4), "native source section order and count stay intact")
			for Child in Owned
				_HS_PersonalReleaseMenus([Child])
			Owned := []
			Root.Delete("hotstring_extension_content_frame")
			loop 3 {
				Refused := ReadRows()
				Assert(Refused is Array && Refused.Length == 0,
					"the actual late declaration refusal never hands off a partial native child")
				for Index, Table in Maps {
					AssertEqual(Before[Index].Count, Table.Count, "refused file menus leave no dispatcher resources")
					for Key, Value in Before[Index]
						Assert(Table.Has(Key) && Table[Key] == Value, "existing dispatcher owner identities remain exact")
				}
				AssertEqual(Source, FSReadUtf8Exact(SourcePath), "presentation refusal preserves every real source byte")
			}
			Root["hotstring_extension_content_frame"] := Original
			AssertEqual(1, ReadRows().Length, "exact declaration repair restores the native file pack")
		} finally {
			try {
				CleanupFailure := 0
				for Child in Owned {
					try _HS_PersonalReleaseMenus([Child])
					catch as ErrorInfo {
						if !CleanupFailure
							CleanupFailure := ErrorInfo
					}
				}
				if CleanupFailure
					throw CleanupFailure
			} finally {
				Root["hotstring_extension_content_frame"] := Original
				Features := SavedFeatures, CategoryEnabled := SavedCategories, _HotstringExtensionPacks := SavedPacks
				_HS_ExtensionsCacheLoaded := SavedCache[1], _HS_ExtensionsCache := SavedCache[2]
				HotstringCategoriesStd := IsSet(SavedStd) ? SavedStd : unset
				HotstringCategoriesErgopti := IsSet(SavedErgopti) ? SavedErgopti : unset
				SubMenus := IsSet(SavedMenus) ? SavedMenus : unset
				State.Clear()
				for Key, Value in SavedState
					State[Key] := Value
			}
		}
	}
}
Test("hotstring extension frame: real file-pack refusal releases every owned native child and exact dispatch bindings",
	_EHX_FilePackRefusalOwnsNativeChildren)
