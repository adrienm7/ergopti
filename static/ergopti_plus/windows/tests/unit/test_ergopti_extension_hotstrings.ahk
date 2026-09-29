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
	}
}
Test("ergopti extension: the shipped groups load from the extension under their historical ids (ergopti-hotstrings-ext)",
	_EHX_ShippedGroupsLoadFromTheExtension)

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
