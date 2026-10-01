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
	global _HotstringBoundSources
	Saved := _HotstringBoundSources
	Directory := _LCT_TempDir()
	try {
		Roots := HotstringExtensions_Roots(Directory, Directory . "missing-bundled", RegistryDir)
		Packs := HotstringExtensions_Prepare(ManifestBuildFeaturesMap(), Roots)
		Callback.Call(Packs)
	} finally {
		_HotstringBoundSources := Saved
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
		AssertEqual(3, Ergopti.bound_files.Length)
		AssertEqual(0, Ergopti.toml_files.Length, "none of its files becomes an ext: category")
		Registry := _LCT_RegistryDir() . "ergopti\hotstrings\"
		AssertEqual(Registry . "sfbsreduction.toml", HotstringsBoundTomlPath("sfbsreduction", "comma"))
		AssertEqual(Registry . "sfbsreduction.toml", HotstringsBundledTomlPath("SFBsReduction"),
			"the menu's spelling reaches the same file")
		AssertEqual(Registry . "rolls.toml", HotstringsBundledTomlPath("rolls"))
		AssertEqual(Registry . "repeatcorrections.toml", HotstringsBoundTomlPath("magickey", "repeat_corrections"))
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
		AssertEqual(0, CountTomlSection("magickey", "repeat_corrections"))
	}
}
Test("ergopti extension: without the Ergopti extension the groups are absent (ergopti-hotstrings-ext)",
	_EHX_NotInstalledSuppliesNothing)

_EHX_CacheCompilesOnlyTheBundledFolder() {
	for Cat in HotstringsBundledCategories() {
		Assert(Cat != "sfbsreduction" && Cat != "rolls",
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
