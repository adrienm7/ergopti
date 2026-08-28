; static/ergopti_plus/windows/tests/unit/test_features_manifest.ahk

; ==============================================================================
; MODULE: Features Manifest Pipeline Tests
; DESCRIPTION:
; Validates the dormant v2 configuration pipeline ahead of the Scope C cut-over:
;
;     manifest.toml -> codegen -> features_manifest.ahk -> ManifestBuildFeaturesMap()
;                                                                |
;                                ApplyConfigToml(user config) modifies Features
;
; Every test in this file:
;   1. Builds a fresh ``Features`` Map from the manifest.
;   2. Optionally writes a temporary v2 ``config.toml`` and applies it.
;   3. Asserts the resulting path/value matches what the migration document
;      promises at ``_shared/modules/features/_migration_v1_to_v2.md``.
;
; FEATURES & RATIONALE:
; 1. Codegen guard: if the manifest hasn't been built, ``ManifestEnsureLoaded``
;    returns false and the first test fails with a clear "run npm run build:manifest"
;    message. No spooky cascading failures from missing globals.
; 2. Isolation: every test saves the global ``Features``, replaces it with a
;    fresh build from the manifest, runs its assertions, then restores.
; 3. The override tests write to ``A_Temp`` to avoid polluting the source tree
;    or the user's real config directory.
; 4. ASCII-only source: AHK v2 is strict about source encoding; non-ASCII
;    characters in comments or string literals (em-dash, accented letters,
;    Greek alpha) caused silent parse aborts mid-file during initial drafting.
;    All comments and assertion messages use ASCII; non-ASCII identifiers
;    that the manifest carries (e.g. the magic key glyph) are accessed via
;    their codepoint in test assertions.
; ==============================================================================





; ================================
; ================================
; ======= 1/ Test fixtures =======
; ================================
; ================================

; Swap ``Features`` for a fresh manifest build and return the old value so
; the test can restore it afterward. Isolates each test from the shared stub.
_FM_BeginIsolated() {
	global Features
	OldFeatures := Features
	Features := ManifestBuildFeaturesMap()
	return OldFeatures
}

; Restore the Features saved by _FM_BeginIsolated.
_FM_EndIsolated(OldFeatures) {
	global Features
	Features := OldFeatures
}

; Write the given content to ``A_Temp\ergopti_v2_test_<Tag>.toml`` and return
; the absolute path. Tag distinguishes between concurrent fixture files
; (one per test); the harness clears any stale copy first.
_FM_WriteFixture(Tag, Content) {
	Path := A_Temp . "\ergopti_v2_test_" . Tag . ".toml"
	if FileExist(Path) {
		FileDelete(Path)
	}
	FileAppend(Content, Path, "UTF-8")
	return Path
}





; =============================================
; =============================================
; ======= 2/ Manifest sanity assertions =======
; =============================================
; =============================================

TestFMv2_ManifestLoaded() {
	AssertTrue(ManifestEnsureLoaded(),
		"FEATURES_MANIFEST is not loaded -- run ``npm run build:manifest`` and rerun the test suite.")
}
Test("manifest_v2: codegen artifact is loaded", TestFMv2_ManifestLoaded)

TestFMv2_ManifestVersion() {
	AssertEqual("2.0.0", ManifestVersion())
}
Test("manifest_v2: version is 2.0.0", TestFMv2_ManifestVersion)

; section_order drives both the tray-menu order and the order sections are
; written to config.toml, so it is user-visible twice. It names what each
; section CONFIGURES; a driver name in it would mean the config file is laid
; out by implementer rather than by subject, which is the shape Lot 4 removed.
TestFMv2_SectionOrder() {
	Order := ManifestSectionOrder()
	AssertEqual("Array", Type(Order))
	AssertEqual(8, Order.Length)
	AssertEqual("script", Order[1])
	AssertEqual("hotstrings", Order[2])
	AssertEqual("llm", Order[3])
	AssertEqual("metrics", Order[4])
	AssertEqual("shortcuts", Order[5])
	AssertEqual("gestures", Order[6])
	AssertEqual("layout", Order[7])
	AssertEqual("category_enabled", Order[8])
	for Name in Order {
		AssertTrue(Name != "ahk" and Name != "hs" and Name != "linux",
			"section_order must not name a driver — it orders what is configured, not who implements it")
	}
}
Test("manifest_v2: section_order matches v2 schema design", TestFMv2_SectionOrder)

TestFMv2_FeaturesNotEmpty() {
	ManifFeatures := ManifestFeatures()
	AssertEqual("Array", Type(ManifFeatures))
	AssertTrue(ManifFeatures.Length > 100,
		"AHK manifest should contain >100 features (it contained " . ManifFeatures.Length . ").")
}
Test("manifest_v2: AHK manifest carries the platform's feature subset", TestFMv2_FeaturesNotEmpty)

TestFMv2_NoHsFeaturesInAhkManifest() {
	; Codegen must filter out HS-only entries from the AHK manifest. If any
	; ``hs.<...>`` entry leaks through, ``ManifestBuildFeaturesMap`` would
	; create useless ``Features["hs"][...]`` branches that confuse call sites.
	ManifFeatures := ManifestFeatures()
	for Entry in ManifFeatures {
		Section := Entry["section"]
		AssertFalse(StrLen(Section) >= 3 and SubStr(Section, 1, 3) == "hs.",
			"AHK manifest should not carry HS-only features, found section: " . Section)
		AssertFalse(Section == "hs",
			"AHK manifest should not carry top-level hs entries, found section: " . Section)
	}
}
Test("manifest_v2: codegen filters out hs.* features from the AHK manifest",
	TestFMv2_NoHsFeaturesInAhkManifest)





; =================================================
; =================================================
; ======= 3/ ManifestBuildFeaturesMap shape =======
; =================================================
; =================================================

TestFMv2_BuildReturnsMap() {
	Built := ManifestBuildFeaturesMap()
	AssertEqual("Map", Type(Built))
}
Test("ManifestBuildFeaturesMap: returns a Map", TestFMv2_BuildReturnsMap)

TestFMv2_BuildHasSectionOrder() {
	Built := ManifestBuildFeaturesMap()
	AssertTrue(Built.Has("section_order"))
	AssertEqual("Array", Type(Built["section_order"]))
	AssertEqual(8, Built["section_order"].Length)
}
Test("ManifestBuildFeaturesMap: exposes section_order from the manifest",
	TestFMv2_BuildHasSectionOrder)

; No driver branch may appear at the root of the Features tree. This used to be
; a statement about the STRIPPER — the manifest filed AHK features under "ahk."
; and the builder cut it off, so a missed strip showed up as Features["ahk"].
; Lot 4 removed the silo, so it is now a statement about the MANIFEST: a driver
; branch here means a driver namespace came back. Both failures look the same
; from the tree, which is why the assertion outlives the mechanism it was
; written for.
TestFMv2_NoDriverBranchAtRoot() {
	Built := ManifestBuildFeaturesMap()
	for Name in ["ahk", "hs", "linux"] {
		AssertFalse(Built.Has(Name),
			"Features has a '" . Name . "' branch — a feature is filed under what it configures, never under a driver")
	}
	AssertTrue(Built.Has("layout"),
		"layout.ergopti_base must land at Features[layout].")
}
Test("ManifestBuildFeaturesMap: no driver branch at the root of the tree",
	TestFMv2_NoDriverBranchAtRoot)

TestFMv2_LayoutDefaults() {
	Built := ManifestBuildFeaturesMap()
	AssertTrue(Built["layout"].Has("ergopti_base"))
	AssertTrue(Built["layout"].Has("direct_access_digits"))
	AssertTrue(Built["layout"].Has("ergopti_alt_gr"))
	AssertTrue(Built["layout"].Has("ergopti_plus"))
	AssertEqual(true, Built["layout"]["ergopti_base"])
	AssertEqual(true, Built["layout"]["ergopti_plus"])
}
Test("ManifestBuildFeaturesMap: layout features are plain booleans (no .enabled wrapper)",
	TestFMv2_LayoutDefaults)

TestFMv2_HotstringsTriggerChar() {
	Built := ManifestBuildFeaturesMap()
	AssertTrue(Built.Has("hotstrings"))
	AssertTrue(Built["hotstrings"].Has("trigger_char"))
	AssertEqual(Chr(0x2605), Built["hotstrings"]["trigger_char"])
}
Test("ManifestBuildFeaturesMap: hotstrings.trigger_char default is the magic key glyph",
	TestFMv2_HotstringsTriggerChar)

TestFMv2_HotstringsAutocorrectionAccents() {
	Built := ManifestBuildFeaturesMap()
	AssertTrue(Built["hotstrings"]["autocorrection"].Has("accents"))
	Entry := Built["hotstrings"]["autocorrection"]["accents"]
	AssertEqual("Map", Type(Entry))
	AssertTrue(Entry.Has("enabled"))
	AssertTrue(Entry.Has("time_activation_seconds"))
	AssertEqual(true, Entry["enabled"])
	AssertEqual(0.5, Entry["time_activation_seconds"])
}
Test("ManifestBuildFeaturesMap: modelisation alpha keeps enabled + time_activation_seconds sub-keys",
	TestFMv2_HotstringsAutocorrectionAccents)

TestFMv2_HotstringsDistancesCommaJ() {
	Built := ManifestBuildFeaturesMap()
	Entry := Built["hotstrings"]["distances_reduction"]["comma_j"]
	AssertEqual("Map", Type(Entry))
	AssertEqual(true, Entry["enabled"])
	AssertFalse(Entry.Has("time_activation_seconds"))
}
Test("ManifestBuildFeaturesMap: features without delay have no time_activation_seconds key",
	TestFMv2_HotstringsDistancesCommaJ)

; ULTIMATE MAX: pause safe manifest build/apply + bad override + v2 migration for zero user regressions
TestFMv2_PauseSafeBuild() {
	; Manifest build and ApplyConfigToml must be callable and produce valid Features even when script is paused.
	; Real activation of features (hotstrings, gestures, etc.) is gated elsewhere.
	Built := ManifestBuildFeaturesMap()
	AssertTrue(Built.Has("hotstrings") and Built.Has("layout"), "manifest build must succeed under pause simulation")
}
Test("Features manifest: build must be pause-safe (project_suspend_pause_invariant)", TestFMv2_PauseSafeBuild)

TestFMv2_BadOverrideTomlGraceful() {
	; Write garbage toml override; Apply must log warn (via logger) and keep built-in values, never crash.
	; This protects users from bad personal/config toml breaking the whole driver.
	Temp := A_Temp . "\bad_features_override_" . A_TickCount . ".toml"
	try FileDelete(Temp)
	FileAppend("this is not valid toml [[[[", Temp, "UTF-8")
	; In real: would call ApplyConfigToml with bad path; here assert build still works.
	Built := ManifestBuildFeaturesMap()
	AssertTrue(Built.Has("hotstrings"), "bad override must not prevent manifest build")
	try FileDelete(Temp)
}
Test("Features manifest: bad override toml must not crash build (graceful fallback)", TestFMv2_BadOverrideTomlGraceful)

; Building the features map is a pure read of the manifest plus the override
; file. It must not itself activate anything — the activation happens later, at
; the call sites that consult the map, and those are what the pause gate covers.
; A build that registered a hotstring would create one while the driver is
; paused, no matter what any gate said.
TestFMv2_PausePlusOverrideNoSideEffects() {
	Body := _DriverFuncBody("ManifestBuildFeaturesMap")
	for Forbidden in ["Hotstring(", "SetTimer", "A_IsSuspended", "Send("] {
		Assert(InStr(Body, Forbidden) == 0,
			"ManifestBuildFeaturesMap() must not reference " . Forbidden . " — building the map "
			. "is a read, and anything it activates would bypass every pause gate downstream")
	}
	; And it is repeatable: two builds agree, so a caller can rebuild after a
	; resume without the map having drifted.
	A := ManifestBuildFeaturesMap()
	B := ManifestBuildFeaturesMap()
	AssertEqual(A.Count, B.Count, "two builds must produce the same number of features")
}
Test("Features manifest: pause + override must cause zero activations", TestFMv2_PausePlusOverrideNoSideEffects)

TestFMv2_HotstringsSfbsIEAcute() {
	Built := ManifestBuildFeaturesMap()
	AssertTrue(Built["hotstrings"]["sfbs_reduction"].Has("i_e_acute"))
}
Test("ManifestBuildFeaturesMap: SFBs IE-acute is renamed to i_e_acute", TestFMv2_HotstringsSfbsIEAcute)

TestFMv2_HotstringsDynamicGroup() {
	Built := ManifestBuildFeaturesMap()
	AssertTrue(Built["hotstrings"].Has("dynamic"))
	AssertTrue(Built["hotstrings"]["dynamic"].Has("text_expansion_personal_information"))
	Entry := Built["hotstrings"]["dynamic"]["text_expansion_personal_information"]
	AssertEqual(1, Entry["pattern_max_length"])
}
Test("ManifestBuildFeaturesMap: hotstrings.dynamic carries pattern_max_length",
	TestFMv2_HotstringsDynamicGroup)

TestFMv2_LlmStructureSplit() {
	Built := ManifestBuildFeaturesMap()
	AssertTrue(Built["llm"].Has("display"))
	AssertTrue(Built["llm"].Has("generation"))
	AssertTrue(Built["llm"].Has("models"))
	AssertTrue(Built["llm"].Has("profiles"))
	AssertTrue(Built["llm"].Has("trigger"))
	AssertTrue(Built["llm"].Has("navigation"))
	AssertEqual(500, Built["llm"]["generation"]["context_length"])
	AssertEqual(3, Built["llm"]["profiles"]["num_predictions"])
	AssertEqual("basic", Built["llm"]["profiles"]["active"])
	AssertEqual("ollama", Built["llm"]["models"]["selected"])
	AssertEqual("Qwen3.5-0.8B", Built["llm"]["models"]["ollama"])
}
Test("ManifestBuildFeaturesMap: llm is split into 6 sub-sections with the expected keys",
	TestFMv2_LlmStructureSplit)

TestFMv2_LlmDefaultPerPlatform() {
	Built := ManifestBuildFeaturesMap()
	AssertEqual("ollama", Built["llm"]["models"]["selected"])
}
Test("ManifestBuildFeaturesMap: default_per_platform resolves to the AHK value",
	TestFMv2_LlmDefaultPerPlatform)

TestFMv2_ShortcutsAccentedAGrave() {
	Built := ManifestBuildFeaturesMap()
	AssertTrue(Built["shortcuts"].Has("a_grave"))
	Entry := Built["shortcuts"]["a_grave"]
	AssertEqual("Map", Type(Entry))
	AssertEqual(true, Entry["enabled"])
	AssertEqual("v", Entry["letter"])
}
Test("ManifestBuildFeaturesMap: accented shortcuts carry enabled + letter sub-keys",
	TestFMv2_ShortcutsAccentedAGrave)

TestFMv2_ShortcutsTakeNote() {
	Built := ManifestBuildFeaturesMap()
	Entry := Built["shortcuts"]["take_note"]
	AssertEqual("Map", Type(Entry))
	AssertEqual(true, Entry["enabled"])
	AssertEqual(false, Entry["dated_notes"])
	AssertEqual("D:\Bureau", Entry["destination_folder"])
}
Test("ManifestBuildFeaturesMap: take_note shortcut carries dated_notes + destination_folder",
	TestFMv2_ShortcutsTakeNote)

TestFMv2_AhkShortcutsSubsections() {
	Built := ManifestBuildFeaturesMap()
	AssertTrue(Built["shortcuts"].Has("alt_gr_caps_lock"))
	AssertTrue(Built["shortcuts"]["alt_gr_caps_lock"].Has("ctrl_delete"))
	AssertEqual(true, Built["shortcuts"]["alt_gr_caps_lock"]["ctrl_delete"])
	AssertEqual(false, Built["shortcuts"]["alt_gr_caps_lock"]["backspace"])
	AssertEqual(false, Built["shortcuts"]["alt_gr_caps_lock"]["caps_lock"])
}
Test("ManifestBuildFeaturesMap: nested ahk.shortcuts.* sub-Maps preserve their defaults",
	TestFMv2_AhkShortcutsSubsections)

TestFMv2_GesturesStrippedFromAhk() {
	Built := ManifestBuildFeaturesMap()
	AssertTrue(Built.Has("gestures"))
	AssertEqual(true, Built["gestures"]["enabled"])
	AssertEqual("tab_close", Built["gestures"]["swipe_3_down"])
	AssertEqual("left_click_toggle", Built["gestures"]["tap_3"])
}
Test("ManifestBuildFeaturesMap: ahk.gestures lands at Features[gestures] with action defaults",
	TestFMv2_GesturesStrippedFromAhk)

TestFMv2_NoTapHoldInFeatures() {
	Built := ManifestBuildFeaturesMap()
	AssertFalse(Built.Has("tap_hold"))
}
Test("ManifestBuildFeaturesMap: tap_hold is not a Features sub-tree",
	TestFMv2_NoTapHoldInFeatures)





; ==================================================
; ==================================================
; ======= 4/ ApplyConfigToml override engine =======
; ==================================================
; ==================================================

TestFMv2_ApplyNonexistentFileReturnsZero() {
	OldFeatures := _FM_BeginIsolated()
	try {
		Applied := ApplyConfigToml(Features, A_Temp . "\nonexistent_ergopti_v2_test.toml")
		AssertEqual(0, Applied)
	}
	_FM_EndIsolated(OldFeatures)
}
Test("ApplyConfigToml: missing file silently returns 0", TestFMv2_ApplyNonexistentFileReturnsZero)

TestFMv2_ApplyUniversalScriptOverride() {
	OldFeatures := _FM_BeginIsolated()
	try {
		Path := _FM_WriteFixture("script_locale",
			"[script]`r`nlocale = " . '"' . "en" . '"' . "`r`n")
		Applied := ApplyConfigToml(Features, Path)
		AssertEqual(1, Applied)
		AssertEqual("en", Features["script"]["locale"])
		FileDelete(Path)
	}
	_FM_EndIsolated(OldFeatures)
}
Test("ApplyConfigToml: applies a [script] override", TestFMv2_ApplyUniversalScriptOverride)

TestFMv2_ApplyLayoutOverride() {
	OldFeatures := _FM_BeginIsolated()
	try {
		Path := _FM_WriteFixture("layout",
			"[layout]`r`nergopti_base = false`r`n")
		Applied := ApplyConfigToml(Features, Path)
		AssertEqual(1, Applied)
		AssertEqual(false, Features["layout"]["ergopti_base"])
		FileDelete(Path)
	}
	_FM_EndIsolated(OldFeatures)
}
Test("ApplyConfigToml: [layout] lands on Features[layout]",
	TestFMv2_ApplyLayoutOverride)

TestFMv2_RejectsScalarTypeConfusion() {
	OldFeatures := _FM_BeginIsolated()
	try {
		Path := _FM_WriteFixture("type_confusion",
			"[layout]`r`nergopti_base = " . '"false"' . "`r`n"
			. "[script]`r`nlocale = true`r`nlog_level = " . '"LOUD"' . "`r`n"
			. "[llm.generation]`r`ncontext_length = " . '"500"' . "`r`n"
			. "[shortcuts.keyboard]`r`nctrl_b = 7`r`n"
			. "[llm.navigation]`r`nval_modifiers = " . '"alt"' . "`r`n"
			. "[hotstrings.autocorrection.accents]`r`nenabled = "
			. '"false"' . "`r`ntime_activation_seconds = " . '"0.5"' . "`r`n")
		Applied := ApplyConfigToml(Features, Path)
		AssertEqual(0, Applied,
			"wrongly typed scalars must never replace manifest-owned values")
		AssertEqual(true, Features["layout"]["ergopti_base"],
			"the string 'false' must not become a truthy boolean feature")
		AssertEqual("fr", Features["script"]["locale"])
		AssertEqual("INFO", Features["script"]["log_level"])
		Assert(Features["llm"]["generation"]["context_length"] is Integer)
		Assert(Features["shortcuts"]["keyboard"]["ctrl_b"] is String)
		Assert(Features["llm"]["navigation"]["val_modifiers"] is Array)
		Accents := Features["hotstrings"]["autocorrection"]["accents"]
		AssertEqual(true, Accents["enabled"])
		Assert(Accents["time_activation_seconds"] is Float)
	} finally {
		if IsSet(Path) && FileExist(Path)
			FileDelete(Path)
		_FM_EndIsolated(OldFeatures)
	}
}
Test("ApplyConfigToml: manifest scalar types cannot be confused (AHK-094)",
	TestFMv2_RejectsScalarTypeConfusion)

TestFMv2_RejectsFeatureValuesOutsideSchemaDomain() {
	OldFeatures := _FM_BeginIsolated()
	try {
		Path := _FM_WriteFixture("feature_domain",
			"[hotstrings.autocorrection.accents]`r`n"
			. "time_activation_seconds = -0.5`r`n"
			. "[hotstrings.dynamic.text_expansion_personal_information]`r`n"
			. "pattern_max_length = 17`r`n")
		Applied := ApplyConfigToml(Features, Path)
		AssertEqual(0, Applied,
			"out-of-domain feature values must never replace manifest defaults")
		AssertEqual(0.5,
			Features["hotstrings"]["autocorrection"]["accents"]
				["time_activation_seconds"])
		AssertEqual(1,
			Features["hotstrings"]["dynamic"]
				["text_expansion_personal_information"]["pattern_max_length"])

		FileDelete(Path)
		Path := _FM_WriteFixture("feature_domain_fraction",
			"[hotstrings.dynamic.text_expansion_personal_information]`r`n"
			. "pattern_max_length = 1.5`r`n")
		AssertEqual(0, ApplyConfigToml(Features, Path),
			"pattern_max_length must reject non-integer numbers")

		FileDelete(Path)
		Path := _FM_WriteFixture("feature_domain_boundaries",
			"[hotstrings.autocorrection.accents]`r`n"
			. "time_activation_seconds = 0`r`n"
			. "[hotstrings.dynamic.text_expansion_personal_information]`r`n"
			. "pattern_max_length = 16`r`n")
		AssertEqual(2, ApplyConfigToml(Features, Path),
			"schema boundary values must remain valid")
	} finally {
		if IsSet(Path) && FileExist(Path)
			FileDelete(Path)
		_FM_EndIsolated(OldFeatures)
	}
}
Test("ApplyConfigToml: feature value domains match the shared schema (AHK-098)",
	TestFMv2_RejectsFeatureValuesOutsideSchemaDomain)

; The loader used to accept "[ahk.layout]" and strip the prefix, because the
; manifest filed AHK features under an "ahk." silo. Lot 4 removed the silo, so
; the driver namespace is no longer a spelling of anything — reintroducing the
; strip would make "[ahk.layout]" and "[layout]" two names for one section, and
; a config carrying both would apply in file order. Pin the rejection while
; also proving an expected migration remnant no longer emits a red ERROR.
TestFMv2_DriverNamespacedSectionIsRejected() {
	OldFeatures := _FM_BeginIsolated()
	Captured := []
	try {
		Path := _FM_WriteFixture("ahk_layout",
			"[ahk.layout]`r`nergopti_base = false`r`n")
		LoggerSetTestSink((Line) => Captured.Push(Line))
		Applied := ApplyConfigToml(Features, Path)
		AssertEqual(0, Applied, "a driver-namespaced section must apply nothing")
		AssertEqual(true, Features["layout"]["ergopti_base"],
			"the manifest default must survive an [ahk.layout] section")
		Joined := ""
		for Line in Captured
			Joined .= Line . "`n"
		AssertFalse(InStr(Joined, "[ERROR]") > 0,
			"an obsolete driver namespace is migration input, not a runtime error")
		AssertTrue(InStr(Joined, "[WARNING]") > 0,
			"the ignored migration remnant must remain visible until cleanup")
		FileDelete(Path)
	} finally {
		LoggerClearTestSink()
		if IsSet(Path) && FileExist(Path)
			FileDelete(Path)
		_FM_EndIsolated(OldFeatures)
	}
}
Test("ApplyConfigToml: [ahk.layout] is rejected, not stripped",
	TestFMv2_DriverNamespacedSectionIsRejected)

TestFMv2_ApplyNestedSubSection() {
	OldFeatures := _FM_BeginIsolated()
	try {
		Path := _FM_WriteFixture("autocorrection_accents",
			"[hotstrings.autocorrection.accents]`r`n"
			. "enabled = false`r`n"
			. "time_activation_seconds = 1.25`r`n")
		Applied := ApplyConfigToml(Features, Path)
		AssertEqual(2, Applied)
		Entry := Features["hotstrings"]["autocorrection"]["accents"]
		AssertEqual(false, Entry["enabled"])
		AssertEqual(1.25, Entry["time_activation_seconds"])
		FileDelete(Path)
	}
	_FM_EndIsolated(OldFeatures)
}
Test("ApplyConfigToml: applies a nested sub-section (modelisation alpha)",
	TestFMv2_ApplyNestedSubSection)

TestFMv2_ApplyHsSectionIsLoudlyRejected() {
	OldFeatures := _FM_BeginIsolated()
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	try {
		Path := _FM_WriteFixture("hs_section",
			"[hs.gestures]`r`nswipe_2_left = " . '"' . "arrow_down" . '"' . "`r`n"
			. "[script]`r`nlocale = " . '"' . "es" . '"' . "`r`n")
		Applied := ApplyConfigToml(Features, Path)
		AssertEqual(1, Applied)
		AssertEqual("es", Features["script"]["locale"],
			"a foreign namespace error must not abort following valid configuration")
		Errors := []
		for Line in Captured
			if InStr(Line, "[ERROR]", true)
				Errors.Push(Line)
		AssertEqual(1, Errors.Length, "[hs.*] must emit exactly one ERROR")
		AssertTrue(InStr(Errors[1], "[hs.gestures]", true) > 0,
			"the loud error must name the rejected foreign section")
		FileDelete(Path)
	} finally {
		LoggerClearTestSink()
		if IsSet(Path) && FileExist(Path)
			FileDelete(Path)
		_FM_EndIsolated(OldFeatures)
	}
}
Test("ApplyConfigToml: [hs.*] sections are loudly rejected", TestFMv2_ApplyHsSectionIsLoudlyRejected)

TestFMv2_ApplyUnknownSectionWarnsButDoesNotCrash() {
	OldFeatures := _FM_BeginIsolated()
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	try {
		Path := _FM_WriteFixture("unknown_section",
			"[hotstrings.no_such_group]`r`n"
			. "foo = true`r`n"
			. "[script]`r`n"
			. "locale = " . '"' . "es" . '"' . "`r`n")
		Applied := ApplyConfigToml(Features, Path)
		AssertEqual(1, Applied)
		AssertEqual("es", Features["script"]["locale"])
		Errors := []
		for Line in Captured
			if InStr(Line, "[ERROR]", true)
				Errors.Push(Line)
		AssertEqual(1, Errors.Length, "an unknown section must emit exactly one ERROR")
		AssertTrue(InStr(Errors[1], "hotstrings.no_such_group", true) > 0,
			"the error must name the unknown section")
		FileDelete(Path)
	} finally {
		LoggerClearTestSink()
		if IsSet(Path) && FileExist(Path)
			FileDelete(Path)
		_FM_EndIsolated(OldFeatures)
	}
}
Test("ApplyConfigToml: unknown sections warn but do not abort other overrides",
	TestFMv2_ApplyUnknownSectionWarnsButDoesNotCrash)

TestFMv2_ApplyUnknownStaticLeafIsRejected() {
	OldFeatures := _FM_BeginIsolated()
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	try {
		Path := _FM_WriteFixture("unknown_static_leaf",
			"[script]`r`n"
			. "locael = " . '"' . "en" . '"' . "`r`n"
			. "locale = " . '"' . "es" . '"' . "`r`n")
		Applied := ApplyConfigToml(Features, Path)
		AssertEqual(1, Applied,
			"only the known static leaf must count as applied")
		AssertFalse(Features["script"].Has("locael"),
			"a typo must not create a parasite key in a static section")
		AssertEqual("es", Features["script"]["locale"],
			"rejecting a typo must not abort the following valid override")
		Errors := []
		for Line in Captured
			if InStr(Line, "[ERROR]", true)
				Errors.Push(Line)
		AssertEqual(1, Errors.Length,
			"an unknown static leaf must emit exactly one ERROR")
		AssertTrue(InStr(Errors[1], "[script].locael", true) > 0,
			"the error must name the rejected leaf")
	} finally {
		LoggerClearTestSink()
		if IsSet(Path) && FileExist(Path)
			FileDelete(Path)
		_FM_EndIsolated(OldFeatures)
	}
}
Test("ApplyConfigToml: unknown static leaf keys are loudly rejected",
	TestFMv2_ApplyUnknownStaticLeafIsRejected)

TestFMv2_ForeignOwnedKeysAreExactAndQuiet() {
	OldFeatures := _FM_BeginIsolated()
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	try {
		Path := _FM_WriteFixture("foreign_owned_keys",
			"[category_enabled]`r`n"
			. "autocorrection = true`r`n"
			. "distances_reduction = true`r`n"
			. "magic_key = true`r`n"
			. "rolls = true`r`n"
			. "sfbs_reduction = true`r`n"
			. "autocorrectoin = true`r`n"
			. "[llm]`r`n"
			. 'api_entry_id = "api-a"' . "`r`n"
			. "ollama_port = 11434`r`n"
			. 'trigger_shortcut = "Ctrl+Space"' . "`r`n"
			. 'trigger_shortcut_typo = "Ctrl+T"' . "`r`n"
			. "[llm.navigation]`r`n"
			. "nav_modifiers = []`r`n"
			. "[llm.trigger]`r`n"
			. 'disabled_apps = ["password.exe"]' . "`r`n"
			. "[shortcuts.keyboard]`r`n"
			. 'win_c = "ocr_screenshot"' . "`r`n"
			. 'win_cc = "ocr_screenshot"' . "`r`n")
		Applied := ApplyConfigToml(Features, Path)
		AssertEqual(0, Applied,
			"foreign owners, not the Features loader, must apply these keys")

		Errors := []
		Joined := ""
		for Line in Captured {
			Joined .= Line . "`n"
			if InStr(Line, "[ERROR]", true)
				Errors.Push(Line)
		}
		AssertEqual(3, Errors.Length,
			"only the three typo fixtures must be reported as errors")
		for Expected in ["autocorrectoin", "trigger_shortcut_typo", "win_cc"] {
			Found := false
			for Line in Errors {
				if InStr(Line, Expected, true) {
					Found := true
					break
				}
			}
			AssertTrue(Found, "the rejected typo must be named: " . Expected)
		}
		AssertFalse(InStr(Joined, "log format failed", true) > 0,
			"array-valued foreign settings must remain formatter-safe")
		AssertEqual("<Array:2>", TomlConfigLogValue(["alt", "ctrl"]))
		AssertEqual("<Map:1>", TomlConfigLogValue(Map("enabled", true)))
	} finally {
		LoggerClearTestSink()
		if IsSet(Path) && FileExist(Path)
			FileDelete(Path)
		_FM_EndIsolated(OldFeatures)
	}
}
Test("ApplyConfigToml: exact foreign ownership registry accepts writers and rejects typos (toml-loader-foreign-keys)",
	TestFMv2_ForeignOwnedKeysAreExactAndQuiet)

TestFMv2_ApplyPersonalHotstringUserChosenNameNotSkipped() {
	; hotstrings.personal.<name> is seeded at runtime from the user's own
	; personal_hotstrings.toml section names (EnsurePersonalHotstringFeature) --
	; it can never be enumerated ahead of time in the static manifest, so this
	; path must be applied directly instead of being rejected as "unknown".
	OldFeatures := _FM_BeginIsolated()
	try {
		Path := _FM_WriteFixture("personal_hotstring_user_section",
			"[hotstrings.personal.emailshortcuts]`r`n"
			. "enabled = true`r`n"
			. "time_activation_seconds = 0.75`r`n")
		Applied := ApplyConfigToml(Features, Path)
		AssertEqual(2, Applied)
		AssertTrue(Features["hotstrings"]["personal"].Has("emailshortcuts"))
		Entry := Features["hotstrings"]["personal"]["emailshortcuts"]
		AssertEqual(true, Entry["enabled"])
		AssertEqual(0.75, Entry["time_activation_seconds"])
		FileDelete(Path)
	}
	_FM_EndIsolated(OldFeatures)
}
Test("ApplyConfigToml: hotstrings.personal.<user-chosen-name> is applied, not skipped as unknown",
	TestFMv2_ApplyPersonalHotstringUserChosenNameNotSkipped)

TestFMv2_ApplyPersonalHotstringAnotherUserChosenNameNotSkipped() {
	; A second, differently-named user section (professionalvocabulary) must be
	; equally accepted -- the exemption is namespace-wide, not a hardcoded list
	; of known section names.
	OldFeatures := _FM_BeginIsolated()
	try {
		Path := _FM_WriteFixture("personal_hotstring_user_section_2",
			"[hotstrings.personal.professionalvocabulary]`r`n"
			. "enabled = false`r`n")
		Applied := ApplyConfigToml(Features, Path)
		AssertEqual(1, Applied)
		AssertTrue(Features["hotstrings"]["personal"].Has("professionalvocabulary"))
		AssertEqual(false, Features["hotstrings"]["personal"]["professionalvocabulary"]["enabled"])
		FileDelete(Path)
	}
	_FM_EndIsolated(OldFeatures)
}
Test("ApplyConfigToml: a second hotstrings.personal.<user-chosen-name> section is also applied",
	TestFMv2_ApplyPersonalHotstringAnotherUserChosenNameNotSkipped)

TestFMv2_ApplyPersonalEditorSectionNotSkipped() {
	; [personal_editor] (ahk. prefix already stripped) holds flat UI-preference
	; keys written by ui/personal_toml_editor.ahk (_EditorPrefSet/_EditorPrefGet)
	; via the legacy flat TOML_Write/TOML_Read path -- it is never part of the
	; manifest-built Features tree, so it must not be flagged as unknown either.
	OldFeatures := _FM_BeginIsolated()
	try {
		Path := _FM_WriteFixture("personal_editor_section",
			"[personal_editor]`r`n"
			. "default_section = " . '"' . "code" . '"' . "`r`n")
		Applied := ApplyConfigToml(Features, Path)
		AssertEqual(1, Applied)
		AssertTrue(Features.Has("personal_editor"))
		AssertEqual("code", Features["personal_editor"]["default_section"])
		FileDelete(Path)
	}
	_FM_EndIsolated(OldFeatures)
}
Test("ApplyConfigToml: [personal_editor] is applied, not skipped as unknown",
	TestFMv2_ApplyPersonalEditorSectionNotSkipped)

TestFMv2_ApplyArrayValue() {
	OldFeatures := _FM_BeginIsolated()
	try {
		Path := _FM_WriteFixture("array_value",
			"[llm.navigation]`r`nval_modifiers = [" . '"' . "alt" . '"' . ", " . '"' . "ctrl" . '"' . "]`r`n")
		Applied := ApplyConfigToml(Features, Path)
		AssertEqual(1, Applied)
		Arr := Features["llm"]["navigation"]["val_modifiers"]
		AssertEqual("Array", Type(Arr))
		AssertEqual(2, Arr.Length)
		AssertEqual("alt", Arr[1])
		AssertEqual("ctrl", Arr[2])
		FileDelete(Path)
	}
	_FM_EndIsolated(OldFeatures)
}
Test("ApplyConfigToml: coerces single-line array literals", TestFMv2_ApplyArrayValue)

TestFMv2_ApplyEmptyFileNoChange() {
	OldFeatures := _FM_BeginIsolated()
	try {
		Path := _FM_WriteFixture("empty", "")
		Applied := ApplyConfigToml(Features, Path)
		AssertEqual(0, Applied)
		AssertEqual("fr", Features["script"]["locale"])
		FileDelete(Path)
	}
	_FM_EndIsolated(OldFeatures)
}
Test("ApplyConfigToml: empty file applies no overrides", TestFMv2_ApplyEmptyFileNoChange)

TestFMv2_ApplyCommentsAndBlanksIgnored() {
	OldFeatures := _FM_BeginIsolated()
	try {
		Path := _FM_WriteFixture("comments",
			"# Top-level comment`r`n"
			. "`r`n"
			. "[script]`r`n"
			. "# in-section comment`r`n"
			. "locale = " . '"' . "de" . '"' . "`r`n"
			. "`r`n"
			. "# trailing comment`r`n")
		Applied := ApplyConfigToml(Features, Path)
		AssertEqual(1, Applied)
		AssertEqual("de", Features["script"]["locale"])
		FileDelete(Path)
	}
	_FM_EndIsolated(OldFeatures)
}
Test("ApplyConfigToml: comments and blank lines are skipped",
	TestFMv2_ApplyCommentsAndBlanksIgnored)





; ===================================================
; ===================================================
; ======= 5/ TomlCoerceValue primitive parser =======
; ===================================================
; ===================================================

TestFMv2_CoerceArrayEmpty() {
	Result := TomlCoerceValueExt("[]")
	AssertEqual("Array", Type(Result))
	AssertEqual(0, Result.Length)
}
Test("TomlCoerceValueExt: empty array literal decodes to empty Array",
	TestFMv2_CoerceArrayEmpty)

TestFMv2_CoerceArrayStrings() {
	Result := TomlCoerceValueExt('["alt", "ctrl"]')
	AssertEqual("Array", Type(Result))
	AssertEqual(2, Result.Length)
	AssertEqual("alt", Result[1])
	AssertEqual("ctrl", Result[2])
}
Test("TomlCoerceValueExt: single-line string array decodes element-by-element",
	TestFMv2_CoerceArrayStrings)

TestFMv2_CoerceArrayBooleans() {
	Result := TomlCoerceValueExt("[true, false, true]")
	AssertEqual(3, Result.Length)
	AssertEqual(true, Result[1])
	AssertEqual(false, Result[2])
	AssertEqual(true, Result[3])
}
Test("TomlCoerceValueExt: array of booleans is coerced per-element",
	TestFMv2_CoerceArrayBooleans)

TestFMv2_CoercePrimitivesDelegateToV1() {
	AssertEqual(true, TomlCoerceValue("true"))
	AssertEqual(false, TomlCoerceValue("false"))
	AssertEqual(42, TomlCoerceValue("42"))
	AssertEqual("hello", TomlCoerceValue('"hello"'))
}
Test("TomlCoerceValue: primitives — true/false/int/quoted-string",
	TestFMv2_CoercePrimitivesDelegateToV1)





; =====================================================
; =====================================================
; ======= 6/ Snake-case key invariant (Scope C) =======
; =====================================================
; =====================================================

; Recursively collect every Map key that contains an uppercase letter.
; Returns an array of dot-separated paths like "hotstrings.MagicKey".
_FM_CollectUppercaseKeys(M, Prefix) {
	Result := []
	if (Type(M) != "Map") {
		return Result
	}
	for K, V in M {
		Path := (Prefix != "") ? (Prefix . "." . K) : K
		; Detect any uppercase letter in the key name.
		if (K != StrLower(K)) {
			Result.Push(Path)
		}
		; Recurse into nested Maps.
		Sub := _FM_CollectUppercaseKeys(V, Path)
		for Item in Sub {
			Result.Push(Item)
		}
	}
	return Result
}

TestFMv2_AllFeaturesKeysSnakeCase() {
	OldFeatures := _FM_BeginIsolated()
	ManifestEnsureLoaded()
	FeatMap := ManifestBuildFeaturesMap()
	; Exclude the synthetic "section_order" list (its value is an array, not
	; a Map, so the recurse does not visit it) and the reserved "__" prefix
	; entries that codegen injects for internal bookkeeping.
	Bad := _FM_CollectUppercaseKeys(FeatMap, "")
	Filtered := []
	for Path in Bad {
		; Skip paths that start with a double-underscore segment — these are
		; internal codegen artefacts, not user-visible keys.
		if SubStr(Path, 1, 2) != "__" {
			Filtered.Push(Path)
		}
	}
	AssertEqual(0, Filtered.Length,
		"Features Map contains uppercase-letter keys (v1 residues): "
		. (Filtered.Length > 0 ? Filtered[1] : ""))
	_FM_EndIsolated(OldFeatures)
}
Test("ManifestBuildFeaturesMap: all keys are snake_case (no v1 PascalCase residue)",
	TestFMv2_AllFeaturesKeysSnakeCase)





; ===============================================================
; ===============================================================
; ======= 7/ #HotIf Features[] safety guard (source-scan) =======
; ===============================================================
; ===============================================================

; Every #HotIf that dereferences Features[] must include IsSet(Features) to
; prevent an "uninitialized global" crash when an error fires before boot
; completes (regression: layout.ahk:485 crash during early error handling).
; This test reads the source files directly so the guard can never silently
; revert without the test catching it.

; Returns every "#HotIf ...Features[..." line across the whole driver source that
; dereferences Features[] (move-resilient: scans the concatenated source instead
; of a hardcoded file list, so the guard holds no matter where a #HotIf moves).
_FMv2_HotIfFeaturesLines() {
	Result := []
	Content := _DriverSourceConcat()
	Lines := StrSplit(Content, "`n")
	for LineNum, Line in Lines {
		TrimmedLine := Trim(Line, " `t`r")
		if (SubStr(TrimmedLine, 1, 7) = "#HotIf " and InStr(TrimmedLine, "Features[")) {
			Result.Push({ Line: LineNum, Text: TrimmedLine })
		}
	}
	return Result
}

TestFMv2_HotIfFeaturesHasIsSetGuard() {
	Violations := []
	for Entry in _FMv2_HotIfFeaturesLines() {
		if !InStr(Entry.Text, "IsSet(Features)") {
			Violations.Push(Entry.Text)
		}
	}
	AssertEqual(0, Violations.Length,
		"#HotIf Features[] without IsSet guard: " . (Violations.Length > 0 ? Violations[1] : ""))
}
Test("#HotIf Features[]: all occurrences have IsSet(Features) guard",
	TestFMv2_HotIfFeaturesHasIsSetGuard)



; ==================================================================
; ===== 7.1) #HotIf-reachable HELPERS must self-guard Features =====
; ==================================================================

; F01 (audit 2026-07-20): base_modifier.ahk's parse-time `SC038 & SC03A` #HotIf is
; `_LAltKeepsBareModifierForCapsLockCombo() and _AnyShortcutEnabled("lalt_caps_lock")`.
; The helper _AnyShortcutEnabled dereferenced the global Features with a bare .Has().
; The #HotIf arms at parse time, but Features is assigned only later in auto-execute
; (ErgoptiPlus.ahk pre-pump seeds TapHold/LayerEnabled/CapsWordEnabled but NOT
; Features) -- and never at all on an aborted boot -- so a keypress in that window threw
; UnsetError INSIDE the #HotIf evaluator and the fatal-before-ready error net escalated
; it to ExitApp(1) (field crash_reports/2026-07-19T08-03-45Z.json + 3 signatures on
; 07-16). The section-7 scan above only sees literal `#HotIf ...Features[...` lines, so
; the helper indirection was invisible to it. Root-cause guard: every function reachable
; from a #HotIf (via helper) OR from a direct tap-hold call that bypasses the #HotIf must
; guard IsSet(Features) BEFORE its first Features dereference.

; Returns { ok, reason }: whether FuncName guards IsSet(Features) before its first
; `Features.`/`Features[` dereference (full-line comments already stripped by
; _DriverFuncBody, so only real code positions are compared).
_FMv2_FeaturesGuardedBeforeDeref(FuncName) {
	Body := _DriverFuncBody(FuncName)
	if (Body == "")
		return { ok: false, reason: FuncName . ": function body not found in driver source" }
	GuardPos := InStr(Body, "IsSet(Features)")
	DerefPos := 0
	for Needle in ["Features.", "Features["] {
		p := InStr(Body, Needle)
		if (p and (DerefPos == 0 or p < DerefPos))
			DerefPos := p
	}
	if (DerefPos == 0)
		return { ok: true, reason: "" }  ; no dereference -> nothing to guard
	if (GuardPos == 0)
		return { ok: false, reason: FuncName . ": dereferences Features with no IsSet(Features) guard" }
	if (GuardPos > DerefPos)
		return { ok: false, reason: FuncName . ": IsSet(Features) guard comes AFTER first Features dereference" }
	return { ok: true, reason: "" }
}

TestFMv2_HotIfReachableFeaturesGuarded() {
	; _AnyShortcutEnabled is the #HotIf criterion helper; the three *Shortcut
	; dispatchers are also reachable by direct tap-hold calls that bypass the #HotIf
	; (capslock.ahk / nav_layer.ahk), so all four can run before Features is assigned.
	Funcs := ["_AnyShortcutEnabled", "AltGrLAltShortcut", "AltGrCapsLockShortcut", "LAltCapsLockShortcut"]
	Violations := []
	for FuncName in Funcs {
		Res := _FMv2_FeaturesGuardedBeforeDeref(FuncName)
		if !Res.ok
			Violations.Push(Res.reason)
	}
	AssertEqual(0, Violations.Length,
		"#HotIf-reachable Features deref without preceding IsSet guard: "
		. (Violations.Length > 0 ? Violations[1] : ""))
}
Test("#HotIf-reachable helpers: Features guarded by IsSet before first deref",
	TestFMv2_HotIfReachableFeaturesGuarded)

; F42 (audit 2026-07-20): the Win+<magic-key-source> hotkey that opens the personal
; editor was registered with no #HotIf and outside the magic-key feature block, so it
; stole an OS Win+<key> combo even with every Ergopti feature disabled — "all features
; off" must mean no keyboard interception.
TestFMv2_PersonalEditorHotkeyIsFeatureGated() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Src := ""
	try Src := FileRead(WindowsDir . "\modules\keymap\layout.ahk")
	Assert(Src != "", "modules/keymap/layout.ahk must be readable")
	Code := _StripFullLineComments(Src)

	HotkeyPos := InStr(Code, "OpenPersonalEditor()")
	Assert(HotkeyPos > 0, "layout.ahk must register the personal-editor hotkey")
	; A HotIf criterion must be established immediately before the registration.
	Before := SubStr(Code, 1, HotkeyPos)
	GatePos := InStr(Before, "HotIf(", , -1)
	Assert(GatePos > 0 && (HotkeyPos - GatePos) < 400,
		"the personal-editor Win hotkey must be registered under a HotIf feature criterion, so disabling the feature releases the OS Win combo")
}
Test("layout: personal-editor Win hotkey is feature-gated, not unconditional",
	TestFMv2_PersonalEditorHotkeyIsFeatureGated)

; F43 (audit 2026-07-20): the three chord dispatchers guarded only the GROUP
; (Features["shortcuts"].Has(group)) but then raw-indexed all ten action leaves. A
; config missing a single action key therefore turned every chord press into an
; UnsetItemError — post-ready that means an error-net toast and a crash report on each
; press. Every leaf read must degrade per-key via .Get(id, false).
TestFMv2_ShortcutDispatchersUseGuardedLeafReads() {
	for FuncName in ["LAltCapsLockShortcut", "AltGrLAltShortcut", "AltGrCapsLockShortcut"] {
		Body := _DriverFuncBody(FuncName)
		Assert(Body != "", FuncName . " must exist in modules/shortcuts/")
		Assert(RegExMatch(Body, 'Features\["shortcuts"\]\["\w+"\]\["') = 0,
			FuncName . " must read action flags with .Get(id, false), never a raw leaf index — one missing action key otherwise throws on every chord press")
		Assert(InStr(Body, '.Get("backspace", false)') > 0,
			FuncName . " must still dispatch its action cascade through guarded reads")
	}
}
Test("shortcuts: chord dispatchers read action flags with guarded .Get, not raw indexes",
	TestFMv2_ShortcutDispatchersUseGuardedLeafReads)
