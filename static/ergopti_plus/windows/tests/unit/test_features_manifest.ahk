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
	static Sequence := 0
	Path := A_Temp . "\ergopti_v2_test_" . Tag . "_" . A_ScriptHwnd . "_" . ++Sequence . ".toml"
	if FileExist(Path) {
		FileDelete(Path)
	}
	FileAppend(Content, Path, "UTF-8")
	_CMJFixtureReadonly(Path)
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
	AssertEqual(9, Order.Length)
	AssertEqual("script", Order[1])
	AssertEqual("hotstrings", Order[2])
	AssertEqual("llm", Order[3])
	AssertEqual("metrics", Order[4])
	AssertEqual("shortcuts", Order[5])
	AssertEqual("gestures", Order[6])
	AssertEqual("layout", Order[7])
	AssertEqual("category_enabled", Order[8])
	AssertEqual("ui", Order[9])
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
	AssertEqual(9, Built["section_order"].Length)
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
	AssertTrue(Built["layout"].Has("ergopti_variant"))
	AssertEqual(false, Built["layout"]["ergopti_base"])
	AssertEqual("none", Built["layout"]["ergopti_variant"])
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
	AssertTrue(Built["hotstrings"]["french_autocorrection"].Has("accents"))
	AssertFalse(Built["hotstrings"]["autocorrection"].Has("accents"),
		"accents moved to the French pack; the neutral category must not keep a copy")
	Entry := Built["hotstrings"]["french_autocorrection"]["accents"]
	AssertEqual("Map", Type(Entry))
	AssertTrue(Entry.Has("enabled"))
	AssertTrue(Entry.Has("time_activation_seconds"))
	; Every bundled section ships disabled; the user opts in.
	AssertEqual(false, Entry["enabled"])
	AssertEqual(0.5, Entry["time_activation_seconds"])
}
Test("ManifestBuildFeaturesMap: modelisation alpha keeps enabled + time_activation_seconds sub-keys",
	TestFMv2_HotstringsAutocorrectionAccents)

TestFMv2_HotstringsDistancesCommaJ() {
	Built := ManifestBuildFeaturesMap()
	Entry := Built["hotstrings"]["distances_reduction"]["comma_j"]
	AssertEqual("Map", Type(Entry))
	AssertEqual(false, Entry["enabled"])
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
	AssertEqual(false, Entry["enabled"])
	AssertEqual("v", Entry["letter"])
}
Test("ManifestBuildFeaturesMap: accented shortcuts carry enabled + letter sub-keys",
	TestFMv2_ShortcutsAccentedAGrave)

TestFMv2_ShortcutsTakeNote() {
	Built := ManifestBuildFeaturesMap()
	Entry := Built["shortcuts"]["take_note"]
	AssertEqual("Map", Type(Entry))
	AssertEqual(false, Entry["enabled"])
	AssertEqual(false, Entry["dated_notes"])
	AssertEqual("D:\Bureau", Entry["destination_folder"])
}
Test("ManifestBuildFeaturesMap: take_note shortcut carries dated_notes + destination_folder",
	TestFMv2_ShortcutsTakeNote)

TestFMv2_AhkShortcutsSubsections() {
	Built := ManifestBuildFeaturesMap()
	AssertTrue(Built["shortcuts"].Has("key_combination_taps"))
	Taps := Built["shortcuts"]["key_combination_taps"]
	AssertEqual(3, Taps.Count, "the three declared pairs")
	for PairId in ["alt_gr_then_left_alt", "alt_gr_then_caps_lock", "left_alt_then_caps_lock"]
		AssertEqual("none", Taps[PairId], PairId . " binds nothing in an empty configuration")
}
Test("ManifestBuildFeaturesMap: nested ahk.shortcuts.* sub-Maps preserve their defaults",
	TestFMv2_AhkShortcutsSubsections)

TestFMv2_GesturesStrippedFromAhk() {
	Built := ManifestBuildFeaturesMap()
	AssertTrue(Built.Has("gestures"))
	AssertEqual(false, Built["gestures"]["enabled"])
	AssertEqual("none", Built["gestures"]["swipe_3_down"])
	AssertEqual("none", Built["gestures"]["tap_3"])
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
		MissingPath := A_Temp . "\nonexistent_ergopti_v2_test.toml"
		_CMJFixtureReadonly(MissingPath)
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
			. "[hotstrings.french_autocorrection.accents]`r`nenabled = "
			. '"false"' . "`r`ntime_activation_seconds = " . '"0.5"' . "`r`n")
		Applied := ApplyConfigToml(Features, Path)
		AssertEqual(0, Applied,
			"wrongly typed scalars must never replace manifest-owned values")
		AssertEqual(false, Features["layout"]["ergopti_base"],
			"the string 'false' must not become a truthy boolean feature")
		AssertEqual("fr", Features["script"]["locale"])
		AssertEqual("INFO", Features["script"]["log_level"])
		Assert(Features["llm"]["generation"]["context_length"] is Integer)
		Assert(Features["shortcuts"]["keyboard"]["ctrl_b"] is String)
		Assert(Features["llm"]["navigation"]["val_modifiers"] is Array)
		Accents := Features["hotstrings"]["french_autocorrection"]["accents"]
		AssertEqual(false, Accents["enabled"],
			"the string 'false' must leave the shipped (disabled) default in place")
		Assert(Accents["time_activation_seconds"] is Float)
	} finally {
		if IsSet(Path) && FileExist(Path)
			FileDelete(Path)
		_FM_EndIsolated(OldFeatures)
	}
}
Test("ApplyConfigToml: manifest scalar types cannot be confused (AHK-094)",
	TestFMv2_RejectsScalarTypeConfusion)

; Out-of-domain integers stay rejected for booleans even though legacy 0/1
; migrates (see the llm-toggle-deadlock test above): 2 is not a spelling the
; old writer produced, so it carries no user intent to preserve.
TestFMv2_RejectsBooleanIntegerTypeAliasing() {
	OldFeatures := _FM_BeginIsolated()
	try {
		LayoutDefault := Features["layout"]["ergopti_base"]
		ContextDefault := Features["llm"]["generation"]["context_length"]
		KanaDefault := Features["script"]["alt_gr_is_kana_remap"]
		DelayDefault := (Features["hotstrings"]["french_autocorrection"]["accents"]
			["time_activation_seconds"])
		Path := _FM_WriteFixture("boolean_integer_aliasing",
			"[layout]`r`nergopti_base = 2`r`n"
			. "[script]`r`nalt_gr_is_kana_remap = 1`r`n"
			. "[llm.generation]`r`ncontext_length = true`r`n"
			. "[hotstrings.french_autocorrection.accents]`r`n"
			. "time_activation_seconds = true`r`n"
			. "[hotstrings.personal.audit_alias]`r`n"
			. "enabled = 2`r`ntime_activation_seconds = true`r`n")
		Applied := ApplyConfigToml(Features, Path)
		AssertEqual(0, Applied,
			"TOML booleans and integers must retain their source types")
		AssertEqual(LayoutDefault, Features["layout"]["ergopti_base"])
		AssertEqual(KanaDefault, Features["script"]["alt_gr_is_kana_remap"])
		AssertEqual(ContextDefault,
			Features["llm"]["generation"]["context_length"])
		AssertEqual(DelayDefault,
			Features["hotstrings"]["french_autocorrection"]["accents"]
				["time_activation_seconds"])
		AssertFalse(Features["hotstrings"]["personal"].Has("audit_alias"),
			"rejected dynamic values must not create an empty feature section")

		FileDelete(Path)
		Path := _FM_WriteFixture("boolean_enum_literal",
			"[script]`r`nalt_gr_is_kana_remap = false`r`n")
		AssertEqual(1, ApplyConfigToml(Features, Path),
			"a real boolean literal must remain valid in a mixed enum")
		AssertEqual(false, Features["script"]["alt_gr_is_kana_remap"])
	} finally {
		if IsSet(Path) && FileExist(Path)
			FileDelete(Path)
		_FM_EndIsolated(OldFeatures)
	}
}
Test("ApplyConfigToml: TOML booleans and integers cannot alias (AHK-131)",
	TestFMv2_RejectsBooleanIntegerTypeAliasing)

; The driver's own writer emitted 0/1 for booleans for years, so the installed
; base carries them on every manifest-boolean key. Strict literal-kind
; rejection skipped each one AND latched the boot authority, which refused
; every later save - including the toggle that would have canonicalized the
; file. The menu toggle could never stick (llm-toggle-deadlock). Legacy 0/1
; for a boolean key must therefore apply with user intent and count as
; migrated, while every other confusion direction stays unapplied as outdated
; configuration: one warning naming it, never an ERROR or a latched refusal.
TestFMv2_LegacyZeroOneBooleansMigrate() {
	OldFeatures := _FM_BeginIsolated()
	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	try {
		Path := _FM_WriteFixture("legacy_boolean_migration",
			"[llm]`r`n"
			. "enabled = 1`r`n"
			. "onboarding_seen = 1`r`n"
			. "[hotstrings.french_autocorrection.accents]`r`n"
			. "enabled = 1`r`n"
			. "[hotstrings.personal.legacy_alias]`r`n"
			. "enabled = 0`r`n"
			. "[llm.generation]`r`n"
			. "context_length = 0`r`n"
			. "[script]`r`n"
			. "locale = " . '"' . "es" . '"' . "`r`n"
			. "[hotstrings.autocorrection.names]`r`n"
			. "time_activation_seconds = true`r`n")
		Applied := ApplyConfigToml(Features, Path, &Rejected, , &Outdated)
		AssertEqual(6, Applied,
			"four legacy 0/1 booleans plus two valid controls must apply")
		AssertEqual(0, Rejected,
			"an outdated value is never a rejected override (config-outdated-windows)")
		AssertEqual(1, Outdated.Count,
			"only the boolean-for-number confusion is left unapplied as outdated")
		AssertEqual(true, Features["llm"]["enabled"],
			"legacy enabled = 1 must switch the feature on, not fall back to default")
		AssertEqual(true, Features["llm"]["onboarding_seen"])
		AssertEqual(true,
			Features["hotstrings"]["french_autocorrection"]["accents"]["enabled"],
			"legacy enabled = 1 must switch the feature on (default is off)")
		AssertTrue(Features["hotstrings"]["personal"].Has("legacy_alias"),
			"a migrated dynamic value must create its section like any valid one")
		AssertEqual(false,
			Features["hotstrings"]["personal"]["legacy_alias"]["enabled"])
		AssertEqual(0, Features["llm"]["generation"]["context_length"],
			"a numeric zero for a number key applies as a number, not as migrated")
		Assert(Features["llm"]["generation"]["context_length"] is Integer,
			"a numeric zero must keep its source type through migration")
		AssertEqual("es", Features["script"]["locale"])
		Errors := []
		Migrated := []
		LeafNamed := false
		for Line in Captured {
			if InStr(Line, "[ERROR]", true)
				Errors.Push(Line)
			if InStr(Line, "legacy", true)
				Migrated.Push(Line)
			LeafNamed := LeafNamed || (InStr(Line, "[WARNING]", true)
				&& InStr(Line, "outdated configuration value(s)", true)
				&& InStr(Line, "time_activation_seconds", true))
		}
		AssertEqual(0, Errors.Length,
			"the confused leaf is outdated configuration, never an ERROR or a partial apply")
		AssertTrue(LeafNamed, "the outdated-value warning must name the confused leaf")
		AssertTrue(Migrated.Length >= 1,
			"legacy migration must say so in the log, or the next save looks unexplained")
	} finally {
		LoggerClearTestSink()
		if IsSet(Path) && FileExist(Path)
			FileDelete(Path)
		_FM_EndIsolated(OldFeatures)
	}
}
Test("ApplyConfigToml: legacy 0/1 booleans migrate with user intent (llm-toggle-deadlock)",
	TestFMv2_LegacyZeroOneBooleansMigrate)

TestFMv2_RejectsFeatureValuesOutsideSchemaDomain() {
	OldFeatures := _FM_BeginIsolated()
	try {
		Path := _FM_WriteFixture("feature_domain",
			"[hotstrings.french_autocorrection.accents]`r`n"
			. "time_activation_seconds = -0.5`r`n"
			. "[hotstrings.dynamic.text_expansion_personal_information]`r`n"
			. "pattern_max_length = 17`r`n")
		Applied := ApplyConfigToml(Features, Path)
		AssertEqual(0, Applied,
			"out-of-domain feature values must never replace manifest defaults")
		AssertEqual(0.5,
			Features["hotstrings"]["french_autocorrection"]["accents"]
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
			"[hotstrings.french_autocorrection.accents]`r`n"
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
			"[ahk.layout]`r`nergopti_base = true`r`n")
		LoggerSetTestSink((Line) => Captured.Push(Line))
		Applied := ApplyConfigToml(Features, Path)
		AssertEqual(0, Applied, "a driver-namespaced section must apply nothing")
		AssertEqual(false, Features["layout"]["ergopti_base"],
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
			"[hotstrings.french_autocorrection.accents]`r`n"
			. "enabled = true`r`n"
			. "time_activation_seconds = 1.25`r`n")
		Applied := ApplyConfigToml(Features, Path)
		AssertEqual(2, Applied)
		Entry := Features["hotstrings"]["french_autocorrection"]["accents"]
		AssertEqual(true, Entry["enabled"])
		AssertEqual(1.25, Entry["time_activation_seconds"])
		FileDelete(Path)
	}
	_FM_EndIsolated(OldFeatures)
}
Test("ApplyConfigToml: applies a nested sub-section (modelisation alpha)",
	TestFMv2_ApplyNestedSubSection)

; Unused entries are maintenance: one summary warning, with exact identities
; available to the cleanup workflow rather than one runtime error per key.
_FM_AssertUnusedWarning(Captured, Path, ExpectedKeys) {
	Warnings := []
	Errors := 0
	for Line in Captured {
		if InStr(Line, "[ERROR]", true)
			Errors += 1
		if InStr(Line, "[WARNING]", true) && InStr(Line, "[TomlConfigLoader]", true)
			Warnings.Push(Line)
	}
	AssertEqual(0, Errors, "unused entries must not trigger runtime errors")
	AssertEqual(1, Warnings.Length, "one warning must summarize every unused entry")
	AssertContains(Warnings[1], "Ignored " . ExpectedKeys.Length . " unused configuration key(s) in '" . Path . "'")
	Scan := ConfigUnusedKeysFind(Path)
	AssertEqual("ok", Scan["status"], "the cleanup must be able to inspect the fixture")
	AssertEqual(ExpectedKeys.Length, Scan["keys"].Length, "only the unused entries may be proposed for cleanup")
	Actual := Map()
	for Entry in Scan["keys"]
		Actual[Entry["section"] . "." . Entry["key"]] := true
	for Key in ExpectedKeys
		AssertTrue(Actual.Has(Key), "the cleanup must name the exact unused entry: " . Key)
}

TestFMv2_ApplyHsSectionOffersCleanup() {
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
			"a foreign namespace must not abort following valid configuration")
		_FM_AssertUnusedWarning(Captured, Path, ["hs.gestures.swipe_2_left"])
		FileDelete(Path)
	} finally {
		LoggerClearTestSink()
		if IsSet(Path) && FileExist(Path)
			FileDelete(Path)
		_FM_EndIsolated(OldFeatures)
	}
}
Test("ApplyConfigToml: unused [hs.*] sections are offered for cleanup", TestFMv2_ApplyHsSectionOffersCleanup)

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
		_FM_AssertUnusedWarning(Captured, Path, ["hotstrings.no_such_group.foo"])
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
		_FM_AssertUnusedWarning(Captured, Path, ["script.locael"])
	} finally {
		LoggerClearTestSink()
		if IsSet(Path) && FileExist(Path)
			FileDelete(Path)
		_FM_EndIsolated(OldFeatures)
	}
}
Test("ApplyConfigToml: unused static leaf keys are offered for cleanup",
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
			. "ollama_port_typo = 11435`r`n"
			. "[llm.navigation]`r`n"
			. "nav_modifiers = []`r`n"
			. "[llm.trigger]`r`n"
			. 'disabled_apps = ["password.exe"]' . "`r`n"
			. "[gestures]`r`n"
			. "auto_configure_on_next_start = true`r`n"
			. "[shortcuts.keyboard]`r`n"
			. 'win_c = "ocr_screenshot"' . "`r`n"
			. 'win_b = "microsoft_bold"' . "`r`n"
			. 'win_cc = "ocr_screenshot"' . "`r`n")
		Applied := ApplyConfigToml(Features, Path)
		AssertEqual(0, Applied,
			"foreign owners, not the Features loader, must apply these keys")

		Joined := ""
		for Line in Captured
			Joined .= Line . "`n"
		_FM_AssertUnusedWarning(Captured, Path,
			["category_enabled.autocorrectoin", "llm.ollama_port_typo", "shortcuts.keyboard.win_cc"])
		AssertEqual("ConfigIO",
			TomlConfigForeignOwner("shortcuts.keyboard", "win_b"),
			"a picker-created keyboard slot must name its real config owner")
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
Test("ApplyConfigToml: dynamic keyboard slots have exact foreign ownership (AHK-100)",
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

TestFMv2_PersonalEditorPreferencesKeepTheirOwner() {
	global _LLM_Menu
	; [personal_editor] (ahk. prefix already stripped) holds flat UI-preference
	; keys written by ui/personal_toml_editor.ahk (_EditorPrefSet/_EditorPrefGet)
	; via the legacy flat TOML_Write/TOML_Read path -- it is never part of the
	; manifest-built Features tree, so it must not be flagged as unknown either.
	OldFeatures := _FM_BeginIsolated()
	try {
		Path := _FM_WriteFixture("personal_editor_section",
			"[personal_editor]`r`n"
			. 'default_section = "code"' . "`r`n"
			. 'compact_view = "1"' . "`r`n"
			. 'close_on_add = "0"' . "`r`n")
		Applied := ApplyConfigToml(Features, Path)
		AssertEqual(0, Applied, "editor-owned preferences never enter the Features tree")
		AssertTrue(!Features.Has("personal_editor"))
		for Key in ["compact_view", "close_on_add", "default_section"] {
			AssertEqual("PersonalEditor", TomlConfigForeignOwner("personal_editor", Key))
			AssertEqual("", TomlConfigUnknownKind(Features, "personal_editor", Key))
		}
		AssertTrue(TomlConfigUnknownKind(Features, "personal_editor", "compact_veiw") != "",
			"a typo does not inherit a broad namespace exemption")
		Menu := _HSDeepCloneMap(_LLM_Menu)
		Menu["onboarding_seen"] := false
		Menu["app_profile_overrides"] := Map()
		Menu["user_profiles"] := []
		Updates := _ConfigCollectFullSaveUpdates(Features, Menu)
		AssertTrue(Updates.Length > 0, "the full-save collector must complete")
		AssertTrue(TOML_BatchWrite(Path, Updates), "the collected full save must publish")
		Prefs := TOML_ParseFreshFile(Path)["personal_editor"]
		AssertEqual("code", Prefs["default_section"])
		AssertEqual("1", Prefs["compact_view"])
		AssertEqual("0", Prefs["close_on_add"])
	} finally {
		if IsSet(Path) && FileExist(Path)
			FileDelete(Path)
		_FM_EndIsolated(OldFeatures)
	}
}
Test("ApplyConfigToml: editor preferences stay owned and survive full saves (personal-editor-config-owner)",
	TestFMv2_PersonalEditorPreferencesKeepTheirOwner)

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

TestFMv2_ApplyInlineCommentsBeforeCoercion() {
	OldFeatures := _FM_BeginIsolated()
	try {
		Path := _FM_WriteFixture("inline_comments",
			"[layout]`r`nergopti_base = false # disable base`r`n"
			. "[llm.generation]`r`ncontext_length = 1024 # tokens`r`n"
			. "[shortcuts.keyboard]`r`n"
			. 'ctrl_b = "open#docs" # hash inside string' . "`r`n"
			. "[llm.navigation]`r`n"
			. 'val_modifiers = ["alt", "ctrl#keep"] # navigation' . "`r`n")
		Applied := ApplyConfigToml(Features, Path)
		AssertEqual(4, Applied,
			"TOML comments must be removed before value coercion")
		AssertEqual(false, Features["layout"]["ergopti_base"])
		AssertEqual(1024, Features["llm"]["generation"]["context_length"])
		AssertEqual("open#docs", Features["shortcuts"]["keyboard"]["ctrl_b"])
		Modifiers := Features["llm"]["navigation"]["val_modifiers"]
		AssertEqual(2, Modifiers.Length)
		AssertEqual("ctrl#keep", Modifiers[2],
			"a hash inside quotes must remain part of the value")
	} finally {
		if IsSet(Path) && FileExist(Path)
			FileDelete(Path)
		_FM_EndIsolated(OldFeatures)
	}
}
Test("ApplyConfigToml: inline comments precede coercion (AHK-133)",
	TestFMv2_ApplyInlineCommentsBeforeCoercion)





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



; The personal editor is an ordinary, neutral keyboard slot. Its former fixed
; Win+magic-key owner intercepted input outside that assignment model and could
; not be removed or rebound from the Shortcuts menu.
TestFMv2_PersonalEditorHasNoDedicatedMagicBinding() {
	Code := _StripFullLineComments(_DriverDirConcat("modules/keymap"))
	Assert(Trim(Code) != "", "the complete actual keymap module must be readable and nonempty")
	Assert(!InStr(Code, "OpenPersonalEditor()"),
		"layout.ahk must never register an editor binding outside ordinary keyboard slots")
	for Chosen in [false, true] {
		for CtrlSave in [false, true] {
			for Entry in LayoutRegistry_MagicKeyHotkeys("SC02E", Chosen, CtrlSave)
				Assert(Entry["kind"] != "editor",
					"neither chosen nor layout-owned physical magic sources may reserve an editor chord")
		}
	}
	Personal := _StripFullLineComments(_DriverFuncBody("_HS_PersonalRows"))
	Assert(Personal != "", "the actual personal-hotstring provider must be readable")
	Assert(!InStr(Personal, '"menu.hotstrings.shortcut_prefix"'),
		"the Personal menu must not advertise a dedicated fixed editor chord")
	Assert(InStr(Personal, "OpenPersonalEditor()") > 0,
		"the ordinary editor opening command remains in the Personal menu")
	AssertEqual("none", ManifestDefaultFor("shortcuts.keyboard.win_d"),
		"an empty configuration must never install the editor recommendation")
	AssertEqual("none", ManifestRecommendedFor("shortcuts.keyboard.win_d"),
		"Win+D remains available for personal assignments instead of a fixed recommendation")
	AssertEqual("open_hotstrings_editor", ManifestDefaultFor("shortcuts.keyboard.magic_editor"),
		"the physical conditional slot owns the editor recommendation")
	AssertEqual("open_hotstrings_editor", ManifestRecommendedFor("shortcuts.keyboard.magic_editor"))
	AssertEqual("none", ManifestValueFor("shortcuts.keyboard.magic_editor", "cleared"),
		"clearing the ordinary contextual owner persists explicit none")
}
Test("layout: editor shortcuts belong only to ordinary user-owned assignments (hotstrings-editor-ordinary-slot)",
	TestFMv2_PersonalEditorHasNoDedicatedMagicBinding)


; =======================================================
; =======================================================
; ======= 8/ Semantic configuration snapshot ============
; =======================================================
; =======================================================

; Each native case owns real source bytes and an isolated cache identity.
_FMS_WithSource(Tag, Source, Body) {
	global _ParseTomlCache, _TomlFileCache, _ConfigTomlSnapshots
	global _ConfigBootReadFailed, _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries
	Path := _FM_WriteFixture("semantic_" . Tag . "_" . ProcessExist(), Source)
	OldRead := _ConfigBootReadFailed, OldRejected := _ConfigBootRejectedOverrides
	OldOutdated := _ConfigBootOutdatedEntries
	PriorRefusal := TOML_WriteRefusal(Path)
	try return Body.Call(Path)
	finally {
		_ConfigBootReadFailed := OldRead
		_ConfigBootRejectedOverrides := OldRejected
		_ConfigBootOutdatedEntries := OldOutdated
		if PriorRefusal == "" && _TOML_WriteRefusals().Has(_TOML_WriteRefusalKey(Path))
			_TOML_WriteRefusals().Delete(_TOML_WriteRefusalKey(Path))
		for Store in [_ParseTomlCache, _TomlFileCache, _ConfigTomlSnapshots] {
			if Store.Has(Path)
				Store.Delete(Path)
		}
		try FileDelete(Path)
	}
}

_FMS_RootAndSectionRows(Path) {
	Cache := ParseConfigTomlFile(Path)
	AssertEqual("@", IniCacheGet(Cache, "hotstrings", "trigger_char"))
	AssertEqual(true, IniCacheGet(Cache, "category_enabled", "hotstrings"))
	AssertEqual("none", IniCacheGet(Cache, "shortcuts.keyboard", "win_space"))
	Target := ManifestBuildFeaturesMap()
	Target["hotstrings"]["autocorrection"]["names"]["enabled"] := false
	Assert(ApplyConfigToml(Target, Path) >= 1, "at least the actual known dotted feature must apply")
	AssertTrue(Target["hotstrings"]["autocorrection"]["names"]["enabled"])
	AssertEqual(false, TOML_UnreadableFile(Path))
}
_FMS_RootSettingsAndDottedFeatureApply() {
	Source := 'hotstrings.trigger_char = "@"`ncategory_enabled.hotstrings = true`nshortcuts.keyboard.win_space = "none"`nhotstrings.autocorrection.names.enabled = true`n'
	_FMS_WithSource("root", Source, _FMS_RootAndSectionRows)
	Source := '[hotstrings]`ntrigger_char = "@"`nautocorrection.names.enabled = true`n[category_enabled]`nhotstrings = true`n[shortcuts]`nkeyboard.win_space = "none"`n'
	_FMS_WithSource("section", Source, _FMS_RootAndSectionRows)
}
Test("configuration snapshot: root and dotted settings reach cache and features (config-semantic-snapshot)",
	_FMS_RootSettingsAndDottedFeatureApply)

_FMS_LiteralAndNested(Path) {
	Cache := ParseConfigTomlFile(Path)
	AssertEqual(false, IniCacheGet(Cache, "hotstrings", "autocorrection.names.enabled"))
	AssertEqual(true, IniCacheGet(Cache, "hotstrings.autocorrection.names", "enabled"))
	AssertEqual("literal", IniCacheGet(Cache, '"hotstrings.autocorrection.names"', "note"))
	AssertEqual("_", IniCacheGet(Cache, "hotstrings.autocorrection.names", "note"))
	Target := ManifestBuildFeaturesMap()
	Target["hotstrings"]["autocorrection"]["names"]["enabled"] := false
	ApplyConfigToml(Target, Path)
	AssertTrue(Target["hotstrings"]["autocorrection"]["names"]["enabled"],
		"the quoted literal false leaf must never alias the actual nested true preference")
	AssertEqual(false, IniCacheGet(Cache, "hotstrings", "autocorrection.names.enabled"))
}
_FMS_LiteralDotsStayDistinct() {
	Source := '[hotstrings]`n"autocorrection.names.enabled" = false`nautocorrection.names.enabled = true`n["hotstrings.autocorrection.names"]`nnote = "literal"`n'
	_FMS_WithSource("literal", Source, _FMS_LiteralAndNested)
}
Test("configuration snapshot: literal dots never alias nested settings (config-semantic-snapshot)",
	_FMS_LiteralDotsStayDistinct)

_FMS_TypedModelsAndIsolation() {
	Snapshot := ConfigTomlDecodeSnapshot('[future]`ntruth = true`nzero = 0`ntext = "0"`nitems = [false, 1, "true"]`nvalue = { nested = { enabled = true } }`n')
	Cache := Snapshot.Cache["future"]
	AssertEqual("Integer", Type(Cache["truth"]))
	AssertTrue(Cache["truth"])
	AssertEqual("Integer", Type(Cache["zero"]))
	AssertEqual(0, Cache["zero"])
	AssertEqual("String", Type(Cache["text"]))
	AssertEqual("0", Cache["text"])
	AssertEqual(3, Cache["items"].Length)
	AssertEqual(false, Cache["items"][1])
	AssertEqual(1, Cache["items"][2])
	AssertEqual("true", Cache["items"][3])
	Cache["value"]["nested"]["enabled"] := false
	AssertTrue(Snapshot.Rows[5].Value["nested"]["enabled"], "feature values do not alias the cache")
	Assert(Snapshot.Document["future"]["value"]["nested"]["enabled"] is TOML_Bool,
		"the original typed source proof retains Boolean intent")
	AssertTrue(Snapshot.Document["future"]["value"]["nested"]["enabled"].Value)
	Assert(Snapshot.Rows[5].Typed["nested"]["enabled"] is TOML_Bool)
	Snapshot.Document["future"]["value"]["nested"]["enabled"].Value := false
	AssertTrue(Snapshot.Rows[5].Typed["nested"]["enabled"].Value, "typed row evidence is detached from the document")
	AssertEqual("true", Snapshot.Rows[5].ChildRaw["nested"]["enabled"], "the exact child raw token remains retained")
}
Test("configuration snapshot: nested native values are typed and detached (config-semantic-snapshot)",
	_FMS_TypedModelsAndIsolation)

_FMS_LegacyBooleans(Path) {
	Target := ManifestBuildFeaturesMap()
	AssertEqual(2, ApplyConfigToml(Target, Path, &Rejected, &Migrated, &Outdated))
	AssertEqual(0, Rejected)
	AssertEqual(2, Migrated, "bare zero/one preserve the installed legacy Boolean contract")
	AssertEqual(2, Outdated.Count, "quoted and out-of-range values remain obsolete")
	AssertTrue(Target["shortcuts"]["screen"])
	AssertFalse(Target["layout"]["ergopti_base"])
}
_FMS_LegacyBooleanCompatibility() {
	_FMS_WithSource("legacy", 'shortcuts.screen = 1`nlayout.ergopti_base = 0`nshortcuts.microsoft_bold = "true"`nshortcuts.title_case = 2`n',
		_FMS_LegacyBooleans)
}
Test("configuration snapshot: legacy Boolean intent and outdated values stay governed (config-semantic-snapshot)",
	_FMS_LegacyBooleanCompatibility)

_FMS_RefusesWholeNamespace(Path) {
	global _ConfigBootReadFailed, _ConfigBootRejectedOverrides
	Target := ManifestBuildFeaturesMap()
	Target["layout"]["ergopti_base"] := true
	_ConfigBootReadFailed := false
	_ConfigBootRejectedOverrides := 0
	Cache := ParseConfigTomlFile(Path)
	AssertEqual(0, Cache.Count, "no incomplete cache may be published")
	AssertTrue(_ConfigBootReadFailed, "semantic boot refusal must remain session-blocking")
	AssertEqual(-1, ApplyBootConfigToml(Target, Path))
	AssertTrue(_ConfigBootRejectedOverrides > 0)
	AssertTrue(Target["layout"]["ergopti_base"], "the early valid leaf must not publish before duplicate admission")
	AssertFalse(ConfigFullStateCanPersist())
	Original := FSRead(Path)
	AssertFalse(TOML_BatchWrite(Path, [{ Section: "layout", Key: "ergopti_base", Value: TOML_Bool(false) }]))
	AssertEqual(Original, FSRead(Path))
	Repaired := '[layout]`nergopti_base = false`n'
	AssertTrue(FSWriteDurable(Path, Repaired))
	AssertFalse(IniCacheGet(ParseConfigTomlFile(Path), "layout", "ergopti_base"))
	AssertTrue(_ConfigBootReadFailed, "manual repair does not complete the prior boot generation")
	AssertFalse(TOML_BatchWrite(Path, [{ Section: "layout", Key: "ergopti_base", Value: TOML_Bool(true) }]))
	AssertEqual(Repaired, FSRead(Path), "only a restart can reconsider the semantic boot write refusal")
}
_FMS_DuplicatesPublishNothing() {
	_FMS_WithSource("duplicate", 'layout.ergopti_base = false`n[layout]`nergopti_base = true`n',
		_FMS_RefusesWholeNamespace)
}
Test("configuration snapshot: duplicate namespaces refuse before cache or feature publication (config-semantic-snapshot)",
	_FMS_DuplicatesPublishNothing)

_FMS_TableArrayGenerationIsolation() {
	Snapshot := ConfigTomlDecodeSnapshot('[[future]]`nname = "one"`nvalue.enabled = true`n[[future]]`nname = "two"`nvalue.enabled = false`n[layout]`nergopti_base = false`n')
	AssertEqual(4, Snapshot.SkippedRecords)
	AssertFalse(Snapshot.Cache.Has("future"))
	AssertFalse(Snapshot.Cache.Has("future.value"))
	AssertEqual(1, Snapshot.Rows.Length)
	AssertEqual("one", Snapshot.Document["future"][1]["name"])
	AssertEqual("two", Snapshot.Document["future"][2]["name"])
	AssertTrue(Snapshot.Document["future"][1]["value"]["enabled"].Value)
	AssertFalse(Snapshot.Document["future"][2]["value"]["enabled"].Value)
}
Test("configuration snapshot: table-array generations cannot become last-wins settings (config-semantic-snapshot)",
	_FMS_TableArrayGenerationIsolation)

_FMS_SnapshotOwnsOneGeneration(Path) {
	global _ParseTomlCache
	Cache := ParseConfigTomlFile(Path)
	Source := FSReadUtf8Exact(Path)
	AssertTrue(Cache["layout"]["ergopti_base"])
	External := '[layout]`nergopti_base = false`n'
	FileDelete(Path)
	FileAppend(External, Path, "UTF-8")
	Target := ManifestBuildFeaturesMap()
	ApplyConfigToml(Target, Path)
	AssertTrue(Target["layout"]["ergopti_base"], "feature application consumes the same admitted boot generation")
	_ParseTomlCache.Delete(Path)
	NewCache := ParseConfigTomlFile(Path)
	AssertFalse(NewCache["layout"]["ergopti_base"])
	AssertTrue(Cache["layout"]["ergopti_base"], "retirement must not mutate a prior cache object")
	Assert(NewCache != Cache, "new source generation owns a new cache")
	ApplyConfigToml(Target, Path)
	AssertFalse(Target["layout"]["ergopti_base"])
	AssertFalse(_TOML_BatchWriteImpl(Path,
		[{ Section: "layout", Key: "ergopti_base", Value: TOML_Bool(true) }],
		[], "write", Source, 1),
		"an old source image cannot acknowledge publication over the new generation")
	AssertEqual(External, FSRead(Path))
}
_FMS_OneAdmittedSourceGeneration() {
	_FMS_WithSource("generation", '[layout]`nergopti_base = true`n', _FMS_SnapshotOwnsOneGeneration)
}
Test("configuration snapshot: boot readers share one generation and invalidation retires identity (config-semantic-snapshot)",
	_FMS_OneAdmittedSourceGeneration)

_FMS_UnknownScalarsAndWriterPolicy(Path) {
	Original := FSRead(Path)
	Cache := ParseConfigTomlFile(Path)
	AssertEqual("retain", Cache["future"]["old"])
	ApplyConfigToml(ManifestBuildFeaturesMap(), Path)
	AssertTrue(TOML_BatchWrite(Path, [{ Section: "hotstrings", Key: "trigger_char", Value: "@" }]))
	AssertEqual(Original, FSRead(Path), "loading/no-op publication does not clean unowned scalar records")
	AssertFalse(TOML_BatchWrite(Path, [{ Section: "hotstrings", Key: "trigger_char", Value: "!" }]))
	AssertEqual(Original, FSRead(Path), "semantic loading does not relax changed dotted-source writer refusal")
}
_FMS_UnknownScalarsStayUntilCleanup() {
	_FMS_WithSource("unknown", 'hotstrings.trigger_char = "@"`n[future]`nold = "retain" # user data`n',
		_FMS_UnknownScalarsAndWriterPolicy)
}
Test("configuration snapshot: unknown scalars survive and writer admission stays strict (config-semantic-snapshot)",
	_FMS_UnknownScalarsStayUntilCleanup)

_FMS_RepeatedFeatureValuesAreDetached(Path) {
	ParseConfigTomlFile(Path)
	Target := ManifestBuildFeaturesMap()
	AssertEqual(1, ApplyConfigToml(Target, Path))
	Target["shortcuts"]["take_note"]["enabled"] := false
	Target["shortcuts"]["take_note"]["destination_folder"] := "changed by the first consumer"
	Second := ManifestBuildFeaturesMap()
	AssertEqual(1, ApplyConfigToml(Second, Path))
	AssertTrue(Second["shortcuts"]["take_note"]["enabled"])
	AssertEqual("owned", Second["shortcuts"]["take_note"]["destination_folder"],
		"a feature consumer cannot rewrite the retained admitted source row")
}
_FMS_RepeatedFeatureReadUsesOriginalSource() {
	_FMS_WithSource("detached", '[shortcuts]`ntake_note = { enabled = true, dated_notes = false, destination_folder = "owned" }`n',
		_FMS_RepeatedFeatureValuesAreDetached)
}
Test("configuration snapshot: repeated feature reads detach their retained source values (config-semantic-snapshot)",
	_FMS_RepeatedFeatureReadUsesOriginalSource)

_FMS_NativeReadRefusalAndRecovery(Path) {
	global _ConfigBootReadFailed
	_ConfigBootReadFailed := false
	Before := FSReadUtf8Exact(Path)
	AssertTrue(Before is String, "the independent original source is physically readable before locking")
	Admission := ConfigMigrateBoot(Path, "capture_read")
	AssertTrue(HasMethod(Admission, "Call"), "the actual readonly source constructor admits the original native read")
	CanonicalSource := SubStr(Before, 1, 1) == Chr(0xFEFF) ? SubStr(Before, 2) : Before
	AssertTrue(Admission.Call(CanonicalSource, 1), "the genuine source receipt matches the exact original legacy bytes")
	AssertFalse(ConfigSchemaCanPrepareWrite(Path), "readonly corpus custody creates no write READY")
	Lock := FileOpen(Path, "r-rwd")
	Assert(IsObject(Lock), "the native read-refusal fixture must acquire its actual exclusive lock")
	try Cache := ParseConfigTomlFile(Path)
	finally Lock.Close()
	AssertEqual(0, Cache.Count)
	AssertTrue(TOML_UnreadableFile(Path))
	AssertTrue(_ConfigBootReadFailed)
	Recovered := ParseConfigTomlFile(Path)
	AssertEqual("@", IniCacheGet(Recovered, "hotstrings", "trigger_char"))
	AssertFalse(TOML_UnreadableFile(Path), "a successful native read clears only the per-path read diagnostic")
	AssertTrue(_ConfigBootReadFailed, "a later successful read cannot rewrite the incomplete boot generation")
	AssertFalse(ConfigFullStateCanPersist())
}
_FMS_ReadFailureRemainsSessionDebt() {
	_FMS_WithSource("locked", 'hotstrings.trigger_char = "@"`n', _FMS_NativeReadRefusalAndRecovery)
}
Test("configuration snapshot: real native read refusal retains boot write protection after recovery (config-semantic-snapshot)",
	_FMS_ReadFailureRemainsSessionDebt)

_FMS_CaseAndEscapedNames() {
	Snapshot := ConfigTomlDecodeSnapshot('[hotstrings]`n"trigger\u005fchar" = "@"`n[Hotstrings]`ntrigger_char = "!"`n')
	AssertEqual("@", IniCacheGet(Snapshot.Cache, "hotstrings", "trigger_char"))
	AssertEqual("!", IniCacheGet(Snapshot.Cache, "Hotstrings", "trigger_char"))
	AssertThrows(_FMS_EscapedAlias,
		"semantic quoted/bare aliases must refuse before either projection is returned")
}
_FMS_EscapedAlias() {
	return ConfigTomlDecodeSnapshot('[hotstrings]`ntrigger_char = "@"`n"trigger\u005fchar" = "!"`n')
}
Test("configuration snapshot: escaped aliases refuse and case-distinct namespaces stay distinct (config-semantic-snapshot)",
	_FMS_CaseAndEscapedNames)

_FMS_GenericParserRemainsFlat(Path) {
	Cache := ParseTomlFile(Path)
	AssertFalse(Cache.Has("root"), "generic data-file parsing retains its historical root contract")
	AssertEqual(7, IniCacheGet(Cache, "settings", "nested.value"))
	AssertEqual("_", IniCacheGet(Cache, "settings.nested", "value"))
	Semantic := ConfigTomlDecodeSnapshot(FSRead(Path))
	AssertEqual(1, IniCacheGet(Semantic.Cache, "root", "value"))
	AssertEqual(7, IniCacheGet(Semantic.Cache, "settings.nested", "value"))
}
_FMS_GenericDataParserCompatibility() {
	_FMS_WithSource("generic", 'root.value = 1`n[settings]`nnested.value = 7`n', _FMS_GenericParserRemainsFlat)
}
Test("configuration snapshot: generic data-file parsing keeps its legacy contract (config-semantic-snapshot)",
	_FMS_GenericDataParserCompatibility)

; These complete native-cache goldens are handwritten from the independent
; semantic corpus, never emitted by the new projection implementation.
_FMS_IndependentDottedCorpus() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\toml\dotted_keys.json", "UTF-8"))
	AssertEqual(23, Corpus["documents"].Length, "every independent semantic vector remains registered")
	Caches := Map(
		"root bare dotted assignment", Map("a", Map("b", 1)),
		"siblings share one semantic owner", Map("a", Map("b", 1, "c", false)),
		"root literal and nested dots coexist", Map("", Map("a.b", 1), "a", Map("b", 2)),
		"section relative dotted assignment", Map("settings.ai", Map("enabled", true, "model", "001")),
		"array of table owner generations", Map(),
		"multiline dotted array", Map("a", Map("b", [1, 2])),
		"multiline dotted string", Map("a", Map("b", "first`nsecond")),
		"quoted Unicode assignment", Map('"é"', Map("ключ", true)),
		"root quoted escaped path", Map('a."b.c"', Map("d", 2)),
		"inline dotted values inside array", Map("", Map("items", [Map("a", Map("b", 1, "c", false))])),
		"dotted namespace child header", Map("a", Map("b", 1), "a.c", Map("v", 2)),
		"implicit header parent admits new dotted child", Map("a.b.c", Map("x", 1), "a.b", Map("d", 2)))
	Valid := 0
	for Row in Corpus["documents"] {
		if !Row["valid"] {
			AssertThrows(ConfigTomlDecodeSnapshot.Bind(Row["source"]), Row["name"])
			continue
		}
		Valid += 1
		AssertTrue(Caches.Has(Row["name"]), "each valid source owns an independent native-cache golden")
		Snapshot := ConfigTomlDecodeSnapshot(Row["source"])
		_TIT_DottedAssert(Row["expected"], Snapshot.Document)
		_TIT_DottedAssert(Caches[Row["name"]], Snapshot.Cache)
	}
	AssertEqual(12, Valid)
}
Test("configuration snapshot: independent dotted corpus pins complete native projection (config-semantic-snapshot)",
	_FMS_IndependentDottedCorpus)

_FMS_MissingSourceIsNotFailure(Path) {
	global _ConfigBootReadFailed
	FileDelete(Path)
	_ConfigBootReadFailed := false
	AssertEqual(0, ParseConfigTomlFile(Path).Count)
	AssertFalse(_ConfigBootReadFailed, "first use has a genuinely absent source, not incomplete boot data")
	AssertFalse(TOML_UnreadableFile(Path))
	AssertEqual("", TOML_WriteRefusal(Path))
	AssertTrue(TOML_BatchWrite(Path, [{ Section: "script", Key: "locale", Value: "en" }]))
	AssertEqual("en", IniCacheGet(ParseConfigTomlFile(Path), "script", "locale"))
}
_FMS_MissingSourceAllowsFirstUse() {
	_FMS_WithSource("missing", "", _FMS_MissingSourceIsNotFailure)
}
Test("configuration snapshot: an absent source still permits first-use settings (config-semantic-snapshot)",
	_FMS_MissingSourceAllowsFirstUse)

_FMS_FullSavePreservesOutdatedAndUnknown(Path) {
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries, _LOGGER_TEST_SINK
	Runtime := _CFGFS_CaptureRuntime(), Coordinator := _ConfigFullSaveCoordinator()
	Original := FSRead(Path)
	Target := ManifestBuildFeaturesMap()
	PriorSink := _LOGGER_TEST_SINK
	Observed := { collector_entered: 0, collector_completed: 0, phase: "unobserved" }
	try {
		_CFGFS_Prepare(Path)
		_ConfigBootRejectedOverrides := 0
		_ConfigBootOutdatedEntries := Map()
		Cache := ParseConfigTomlFile(Path)
		ApplyBootConfigToml(Target, Path)
		AssertEqual("@", IniCacheGet(Cache, "hotstrings", "trigger_char"))
		AssertTrue(_ConfigBootOutdatedEntries.Has("shortcuts`nscreen"))
		AssertEqual(0, _ConfigBootRejectedOverrides)
		Collect() {
			Observed.collector_entered := 1
			Updates := [
				{ Section: "hotstrings", Key: "trigger_char", Value: IniCacheGet(Cache, "hotstrings", "trigger_char") },
				{ Section: "shortcuts", Key: "screen", Value: Target["shortcuts"]["screen"] }]
			Observed.collector_completed := 1
			return Updates
		}
		ObservePhase(Line) {
			; Classify fixed existing messages only; never emit paths, source,
			; credentials or the original formatted logger line.
			if !(Line is String)
				return
			for Phase in ["source", "collector", "writer"]
				if InStr(Line, "The full configuration " . Phase . " raised an error:")
					Observed.phase := Phase
			if InStr(Line, "Refusing semantic configuration write for")
				Observed.phase := "candidate"
			if InStr(Line, "Write-through atomic replace of")
				Observed.phase := "native_replace"
			if InStr(Line, "Refusing configuration writer: genuine source schema admission was not captured.")
				Observed.phase := "schema_capture"
			if InStr(Line, "Refusing unchanged-source acknowledgment: genuine native admission was withdrawn.")
				Observed.phase := "native_ack_noop"
			if InStr(Line, "Refusing unchanged-image acknowledgment: genuine native admission was withdrawn.")
				Observed.phase := "native_ack_image"
		}
		LoggerSetTestSink(ObservePhase)
		SaveResult := SaveFullConfig(0, (*) => true, true, 0, Collect)
		LoggerSetTestSink(PriorSink)
		if SaveResult != CONFIG_SAVE_OK
			_FMS_TraceClosedFullSaveRefusal(Path, SaveResult, Observed, Original)
		AssertEqual(CONFIG_SAVE_OK, SaveResult,
			"the actual full-save owner and writer must acknowledge the semantic no-op")
		AssertEqual(Original, FSRead(Path), "full save must preserve obsolete scalar and unowned source bytes")
		AssertEqual(_ConfigFullSaveCoordinator().requested_generation,
			_ConfigFullSaveCoordinator().committed_generation,
			"successful publication, not a deferred timer, owns this generation")
	} finally {
		LoggerSetTestSink(PriorSink)
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
	}
}
_FMS_FullSaveUsesSemanticReadWithoutCleanup() {
	_FMS_WithSource("fullsave", '_meta.schema_version = 11`nhotstrings.trigger_char = "@"`n[shortcuts]`nscreen = 2 # outdated, retained`n[future]`nold = "retain" # user data`n',
		_FMS_FullSavePreservesOutdatedAndUnknown)
}
Test("configuration snapshot: actual full save retains outdated and unknown scalar records (config-semantic-snapshot)",
	_FMS_FullSaveUsesSemanticReadWithoutCleanup)

; Complete hand-authored models distinguish native values from typed sentinels.
_FMS_AssertExactTree(Expected, Actual) {
	if Expected is TOML_Bool {
		Assert(Actual is TOML_Bool, "typed Boolean source intent remains distinct")
		AssertEqual(Expected.Value, Actual.Value)
	} else if Expected is Map {
		Assert(Actual is Map)
		AssertEqual(Expected.Count, Actual.Count, "the complete independent model retains every member")
		for Key, Child in Expected {
			Assert(Actual.Has(Key), "the exact independent semantic identity exists: " . Key)
			_FMS_AssertExactTree(Child, Actual[Key])
		}
	} else if Expected is Array {
		Assert(Actual is Array)
		AssertEqual(Expected.Length, Actual.Length)
		for Index, Child in Expected
			_FMS_AssertExactTree(Child, Actual[Index])
	} else {
		AssertEqual(Type(Expected), Type(Actual), "native scalar kinds cannot alias one another")
		AssertEqual(Expected, Actual)
	}
}

_FMS_InlineOwnedNamespaces(Path) {
	Snapshot := ConfigTomlReadSnapshot(Path)
	Cache := ParseConfigTomlFile(Path)
	_FMS_AssertExactTree(Map("hotstrings", Map("trigger_char", "@", "autocorrection", Map("names", Map("enabled", TOML_Bool(true)))),
		"category_enabled", Map("hotstrings", TOML_Bool(true))), Snapshot.Document)
	_FMS_AssertExactTree(Map("hotstrings", Map("trigger_char", "@"), "hotstrings.autocorrection", Map("names", Map("enabled", true)),
		"category_enabled", Map("hotstrings", true)), Cache)
	AssertEqual("@", IniCacheGet(Cache, "hotstrings", "trigger_char"))
	AssertTrue(IniCacheGet(Cache, "category_enabled", "hotstrings"))
	Assert(Cache["hotstrings.autocorrection"]["names"] is Map,
		"inline feature records retain a native owned-record identity")
	Target := ManifestBuildFeaturesMap()
	AssertEqual(3, ApplyConfigToml(Target, Path, &Rejected, , &Outdated),
		"two owned primitive leaves and one successfully merged feature record apply")
	AssertEqual(0, Rejected)
	AssertEqual(0, Outdated.Count)
	AssertTrue(Target["hotstrings"]["autocorrection"]["names"]["enabled"])
	AssertEqual(0.5, Target["hotstrings"]["autocorrection"]["names"]["time_activation_seconds"],
		"an omitted feature child retains its independent shipped default")
	Assert(Target["hotstrings"].Has("french_autocorrection"),
		"an inline namespace cannot replace unrelated seeded siblings")
	AssertFalse(Target["hotstrings"]["autocorrection"].Has("accents"),
		"the actual current manifest has no accents owner in this namespace")
	AssertTrue(Snapshot.Document["hotstrings"]["autocorrection"]["names"]["enabled"].Value)
}
_FMS_InlineNamespaceSpellingsKeepDefaults() {
	_FMS_WithSource("inline_root", 'hotstrings = { trigger_char = "@", autocorrection = { names = { enabled = true } } }`ncategory_enabled = { hotstrings = true }`n',
		_FMS_InlineOwnedNamespaces)
	_FMS_WithSource("inline_section", '[hotstrings]`ntrigger_char = "@"`nautocorrection = { names = { enabled = true } }`n[category_enabled]`nhotstrings = true`n',
		_FMS_InlineOwnedNamespaces)
}
Test("configuration snapshot: inline owned namespaces retain record identity and defaults (config-semantic-snapshot)",
	_FMS_InlineNamespaceSpellingsKeepDefaults)

_FMS_InlineRecordAndPhysicalChildren() {
	Inline := ConfigTomlDecodeSnapshot('shortcuts = { take_note = { enabled = true } }`n')
	Assert(Inline.Cache["shortcuts"]["take_note"] is Map)
	AssertEqual(1, Inline.Rows.Length, "the record must not be flattened into an alternative cache layout")
	AssertEqual("shortcuts", Inline.Rows[1].Section)
	AssertEqual("take_note", Inline.Rows[1].Key)
	AssertTrue(Inline.Cache["shortcuts"]["take_note"]["enabled"])
	Source := '[shortcuts]`ntake_note = { enabled = true }`n'
	_FMS_WithSource("inline_record", Source, _FMS_AssertRecordDefaults)
	Source := '[shortcuts.take_note]`nenabled = true`n'
	_FMS_WithSource("physical_record", Source, _FMS_AssertRecordDefaults)
}
_FMS_AssertRecordDefaults(Path) {
	Target := ManifestBuildFeaturesMap()
	AssertEqual(1, ApplyConfigToml(Target, Path))
	AssertTrue(Target["shortcuts"]["take_note"]["enabled"])
	AssertFalse(Target["shortcuts"]["take_note"]["dated_notes"])
	AssertEqual("D:\Bureau", Target["shortcuts"]["take_note"]["destination_folder"])
}
Test("configuration snapshot: owned inline records match physical child settings without dropping defaults (config-semantic-snapshot)",
	_FMS_InlineRecordAndPhysicalChildren)

_FMS_ChildPoliciesAndFullSave(Path, ExpectedSave) {
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries
	Runtime := _CFGFS_CaptureRuntime(), Coordinator := _ConfigFullSaveCoordinator()
	Original := FSRead(Path)
	Target := ManifestBuildFeaturesMap()
	try {
		_CFGFS_Prepare(Path, true, false, false)
		ConfigMigrateBoot(Path)
		_ConfigBootRejectedOverrides := 0
		_ConfigBootOutdatedEntries := Map()
		ParseConfigTomlFile(Path)
		AssertEqual(1, ApplyBootConfigToml(Target, Path), "only the valid timing child applies")
		Names := Target["hotstrings"]["autocorrection"]["names"]
		AssertFalse(Names["enabled"], "an invalid known Boolean child cannot become truthy")
		AssertEqual(0.25, Names["time_activation_seconds"])
		AssertFalse(Names.Has("future"), "unowned fields are ignored in runtime, retained on disk")
		AssertTrue(_ConfigBootOutdatedEntries.Has("hotstrings.autocorrection.names`nenabled"),
			"the exact child identity, not the parent record, owns neutral-save preservation")
		Collect() {
			Updates := []
			_CollectFeatureUpdates(Updates, "hotstrings.autocorrection.names", Names)
			return Updates
		}
		BeforeRequested := _ConfigFullSaveCoordinator().requested_generation
		BeforeCommitted := _ConfigFullSaveCoordinator().committed_generation
		AssertEqual(BeforeRequested, BeforeCommitted, "the fixture starts with no uncommitted generation")
		Requested := 0
		Result := SaveFullConfig(0, (*) => true, true, 0, Collect, &Requested)
		AssertTrue(Result is Integer, "the full-save capability preserves its strict native status type")
		AssertEqual(ExpectedSave, Result,
			"the actual full-save owner acknowledges preserved inline and physical semantic no-ops")
		AssertEqual(BeforeRequested + 1, Requested, "one real request owns one new generation")
		AssertEqual(Requested, _ConfigFullSaveCoordinator().requested_generation)
		AssertEqual(Original, FSRead(Path), "neither outcome may erase the invalid or unowned source child")
		if ExpectedSave == CONFIG_SAVE_OK {
			AssertEqual(Requested, _ConfigFullSaveCoordinator().committed_generation)
			AssertEqual(Requested, _ConfigFullSaveCoordinator().settled_generation)
			AssertFalse(_ConfigFullSaveHasPending(), "the successful no-op settles exactly its request")
		}
		else
			Assert(_ConfigFullSaveCoordinator().committed_generation < _ConfigFullSaveCoordinator().requested_generation,
				"an inline writer refusal must not acknowledge the requested generation")
	} finally {
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
	}
}
_FMS_InlineChildRefusalAndPhysicalPreservation() {
	_FMS_WithSource("inline_child", _CMJFixtureCurrentSource('[hotstrings]`nautocorrection = { names = { enabled = "true", time_activation_seconds = 0.25, future = "retain" } } # preserve`n'),
		_FMS_ChildPoliciesAndFullSave.Bind(, CONFIG_SAVE_OK))
	_FMS_WithSource("physical_child", _CMJFixtureCurrentSource('[hotstrings.autocorrection.names]`nenabled = "true" # outdated`ntime_activation_seconds = 0.25`nfuture = "retain" # unknown`n'),
		_FMS_ChildPoliciesAndFullSave.Bind(, CONFIG_SAVE_OK))
}
Test("configuration snapshot: inline child policy and actual full-save fences retain obsolete data (config-semantic-snapshot)",
	_FMS_InlineChildRefusalAndPhysicalPreservation)

_FMS_EmptyNamespaceCannotBorrowRoot(Path) {
	Cache := ParseConfigTomlFile(Path)
	_FMS_AssertExactTree(Map('"".layout', Map("ergopti_base", false), 'layout.""', Map("ergopti_base", false),
		'"layout.extra"', Map("ergopti_base", false)), Cache)
	_FMS_AssertExactTree(Map("", Map("layout", Map("ergopti_base", TOML_Bool(false))),
		"layout", Map("", Map("ergopti_base", TOML_Bool(false))), "layout.extra", Map("ergopti_base", TOML_Bool(false))),
		ConfigTomlReadSnapshot(Path).Document)
	AssertFalse(IniCacheGet(Cache, '"".layout', "ergopti_base"))
	AssertFalse(IniCacheGet(Cache, 'layout.""', "ergopti_base"))
	AssertFalse(IniCacheGet(Cache, '"layout.extra"', "ergopti_base"))
	AssertEqual("_", IniCacheGet(Cache, "layout", "ergopti_base"))
	Target := ManifestBuildFeaturesMap()
	Target["layout"]["ergopti_base"] := true
	AssertEqual(0, ApplyConfigToml(Target, Path))
	AssertTrue(Target["layout"]["ergopti_base"], "empty and literal dotted names must never borrow a root owner")
	AssertEqual("section", TomlConfigUnknownKind(Target, '"".layout', "ergopti_base"))
	AssertEqual("", TomlConfigManifestPath('"".layout'))
	AssertEqual("", TomlConfigManifestPath('"layout.extra"'))
	AssertEqual(0, Target["layout"].Has(""))
}
_FMS_EmptyAndLiteralNamespacesStayForeign() {
	_FMS_WithSource("empty_namespace", '["".layout]`nergopti_base = false`n[layout.""]`nergopti_base = false`n["layout.extra"]`nergopti_base = false`n',
		_FMS_EmptyNamespaceCannotBorrowRoot)
}
Test("configuration snapshot: quoted empty and literal namespaces cannot alias root settings (config-semantic-snapshot)",
	_FMS_EmptyAndLiteralNamespacesStayForeign)

_FMS_DeletedSourceKeepsAdmittedBootGeneration(Path) {
	global _ParseTomlCache
	Cache := ParseConfigTomlFile(Path)
	AssertTrue(IniCacheGet(Cache, "layout", "ergopti_base"))
	Snapshot := ConfigTomlReadSnapshot(Path)
	AssertTrue(Snapshot.Present, "presence belongs to the successful admitted read")
	FileDelete(Path)
	Target := ManifestBuildFeaturesMap()
	AssertEqual(1, ApplyConfigToml(Target, Path), "external deletion cannot bypass the retained boot generation")
	AssertTrue(Target["layout"]["ergopti_base"])
	Assert(ParseConfigTomlFile(Path) == Cache, "publication must use admitted presence, not a later FileExist shortcut")
	_ParseTomlCache.Delete(Path)
	Fresh := ConfigTomlReadSnapshot(Path)
	AssertFalse(Fresh.Present, "retirement permits a new genuinely absent generation")
	AssertEqual(0, Fresh.Rows.Length)
	AssertEqual(0, ApplyConfigToml(ManifestBuildFeaturesMap(), Path))
}
_FMS_DeletionBetweenConsumersKeepsOneGeneration() {
	_FMS_WithSource("deleted_generation", '[layout]`nergopti_base = true`n', _FMS_DeletedSourceKeepsAdmittedBootGeneration)
}
Test("configuration snapshot: external deletion cannot split bootstrap consumer generations (config-semantic-snapshot)",
	_FMS_DeletionBetweenConsumersKeepsOneGeneration)

_FMS_ForeignInlineNamespacesRemainOwned(Path) {
	Cache := ParseConfigTomlFile(Path)
	_FMS_AssertExactTree(Map("personal_editor", Map("close_on_add", false, "future", "retained"),
		"llm", Map("api_entry_id", "42")), Cache)
	_FMS_AssertExactTree(Map("personal_editor", Map("close_on_add", TOML_Bool(false), "future", "retained"),
		"llm", Map("api_entry_id", "42")), ConfigTomlReadSnapshot(Path).Document)
	AssertFalse(IniCacheGet(Cache, "personal_editor", "close_on_add"))
	AssertEqual("retained", IniCacheGet(Cache, "personal_editor", "future"))
	AssertEqual("42", IniCacheGet(Cache, "llm", "api_entry_id"))
	Target := ManifestBuildFeaturesMap()
	AssertEqual(0, ApplyConfigToml(Target, Path), "foreign and unknown children cannot enter the feature tree")
	AssertFalse(Target.Has("personal_editor"))
}
_FMS_RegisteredForeignNamespaceProjection() {
	_FMS_WithSource("foreign_inline", 'personal_editor = { close_on_add = false, future = "retained" }`nllm = { api_entry_id = "42" }`n',
		_FMS_ForeignInlineNamespacesRemainOwned)
}
Test("configuration snapshot: inline foreign bootstrap namespaces reuse their exact registry owner (config-semantic-snapshot)",
	_FMS_RegisteredForeignNamespaceProjection)

_FMS_DynamicLiteralNamesKeepChildDomains(Path) {
	Cache := ParseConfigTomlFile(Path)
	_FMS_AssertExactTree(Map("hotstrings", Map("personal", Map("work.notes", Map("enabled", "false", "time_activation_seconds", -1),
		"", Map("enabled", 2, "time_activation_seconds", TOML_Bool(true)),
		"literal.ok", Map("enabled", TOML_Bool(true), "time_activation_seconds", 0.125)))), ConfigTomlReadSnapshot(Path).Document)
	_FMS_AssertExactTree(Map('hotstrings.personal."work.notes"', Map("enabled", "false", "time_activation_seconds", -1),
		'hotstrings.personal.""', Map("enabled", 2, "time_activation_seconds", true),
		'hotstrings.personal."literal.ok"', Map("enabled", true, "time_activation_seconds", 0.125)), Cache)
	AssertEqual("false", IniCacheGet(Cache, 'hotstrings.personal."work.notes"', "enabled"))
	AssertEqual(-1, IniCacheGet(Cache, 'hotstrings.personal."work.notes"', "time_activation_seconds"))
	AssertEqual(2, IniCacheGet(Cache, 'hotstrings.personal.""', "enabled"))
	Target := ManifestBuildFeaturesMap()
	AssertEqual(2, ApplyConfigToml(Target, Path, &Rejected, , &Outdated))
	AssertEqual(0, Rejected)
	AssertEqual(4, Outdated.Count, "quoted dots and empty names retain Boolean and timing domains")
	AssertTrue(Outdated.Has('hotstrings.personal."work.notes"' . "`nenabled"))
	AssertTrue(Outdated.Has('hotstrings.personal.""' . "`ntime_activation_seconds"))
	AssertFalse(Target["hotstrings"]["personal"].Has("work.notes"))
	AssertFalse(Target["hotstrings"]["personal"].Has(""))
	AssertTrue(Target["hotstrings"]["personal"]["literal.ok"]["enabled"])
	AssertEqual(0.125, Target["hotstrings"]["personal"]["literal.ok"]["time_activation_seconds"])
	AssertFalse(Target["hotstrings"]["personal"].Has("literal"), "a literal user name never creates nested category ownership")
}
_FMS_DynamicEmptyNameIsDistinct(Path) {
	Target := ManifestBuildFeaturesMap()
	AssertEqual(2, ApplyConfigToml(Target, Path))
	AssertFalse(Target["hotstrings"]["personal"][""]["enabled"])
	AssertEqual(0, Target["hotstrings"]["personal"][""]["time_activation_seconds"])
	AssertFalse(Target["layout"]["ergopti_base"], "the empty personal name remains inside its declared dynamic owner")
}
_FMS_DynamicQuotedNamesDoNotBorrowStaticPaths() {
	_FMS_WithSource("dynamic_literals", '[hotstrings.personal."work.notes"]`nenabled = "false"`ntime_activation_seconds = -1`n[hotstrings.personal.""]`nenabled = 2`ntime_activation_seconds = true`n[hotstrings.personal."literal.ok"]`nenabled = true`ntime_activation_seconds = 0.125`n',
		_FMS_DynamicLiteralNamesKeepChildDomains)
	_FMS_WithSource("dynamic_empty_valid", '[hotstrings.personal.""]`nenabled = false`ntime_activation_seconds = 0`n',
		_FMS_DynamicEmptyNameIsDistinct)
}
Test("configuration snapshot: dynamic quoted names retain typed domains and exact identities (config-semantic-snapshot)",
	_FMS_DynamicQuotedNamesDoNotBorrowStaticPaths)

_FMS_DynamicInlineMapsUseChildDomains(Path) {
	Cache := ParseConfigTomlFile(Path)
	_FMS_AssertExactTree(Map("hotstrings", Map("personal", Map("work.notes", Map("enabled", "false", "time_activation_seconds", -1),
		"literal.ok", Map("enabled", TOML_Bool(true), "time_activation_seconds", 0.125)))), ConfigTomlReadSnapshot(Path).Document)
	_FMS_AssertExactTree(Map('hotstrings.personal."work.notes"', Map("enabled", "false", "time_activation_seconds", -1),
		'hotstrings.personal."literal.ok"', Map("enabled", true, "time_activation_seconds", 0.125)), Cache)
	AssertEqual("false", IniCacheGet(Cache, 'hotstrings.personal."work.notes"', "enabled"))
	AssertEqual(-1, IniCacheGet(Cache, 'hotstrings.personal."work.notes"', "time_activation_seconds"))
	Target := ManifestBuildFeaturesMap()
	AssertEqual(2, ApplyConfigToml(Target, Path, &Rejected, , &Outdated))
	AssertEqual(0, Rejected)
	AssertEqual(2, Outdated.Count)
	AssertFalse(Target["hotstrings"]["personal"].Has("work.notes"))
	AssertTrue(Target["hotstrings"]["personal"]["literal.ok"]["enabled"])
	AssertEqual(0.125, Target["hotstrings"]["personal"]["literal.ok"]["time_activation_seconds"])
}
_FMS_InlineDynamicNamespacesMatchPhysicalPolicy() {
	_FMS_WithSource("inline_dynamic_root", 'hotstrings = { personal = { "work.notes" = { enabled = "false", time_activation_seconds = -1 }, "literal.ok" = { enabled = true, time_activation_seconds = 0.125 } } }`n',
		_FMS_DynamicInlineMapsUseChildDomains)
	_FMS_WithSource("inline_dynamic_section", '[hotstrings.personal]`n"work.notes" = { enabled = "false", time_activation_seconds = -1 }`n"literal.ok" = { enabled = true, time_activation_seconds = 0.125 }`n',
		_FMS_DynamicInlineMapsUseChildDomains)
}
Test("configuration snapshot: inline dynamic namespaces retain physical child typing (config-semantic-snapshot)",
	_FMS_InlineDynamicNamespacesMatchPhysicalPolicy)

_FMS_AbsentGenerationCannotConsumeExternalCreation(Path) {
	global _ParseTomlCache
	FileDelete(Path)
	Cache := ParseConfigTomlFile(Path)
	AssertEqual(0, Cache.Count)
	AssertFalse(ConfigTomlReadSnapshot(Path).Present)
	FileAppend('[layout]`nergopti_base = true`n', Path, "UTF-8")
	Target := ManifestBuildFeaturesMap()
	AssertEqual(0, ApplyConfigToml(Target, Path), "external creation cannot replace admitted absence between boot consumers")
	AssertFalse(Target["layout"]["ergopti_base"])
	Assert(ParseConfigTomlFile(Path) == Cache)
	_ParseTomlCache.Delete(Path)
	Fresh := ParseConfigTomlFile(Path)
	AssertTrue(IniCacheGet(Fresh, "layout", "ergopti_base"))
	AssertTrue(ConfigTomlReadSnapshot(Path).Present)
	AssertEqual(1, ApplyConfigToml(Target, Path))
	AssertTrue(Target["layout"]["ergopti_base"])
}
_FMS_ExternalCreationCannotSplitAbsentBoot() {
	_FMS_WithSource("absent_created", "", _FMS_AbsentGenerationCannotConsumeExternalCreation)
}
Test("configuration snapshot: admitted absence survives external creation until owner retirement (config-semantic-snapshot)",
	_FMS_ExternalCreationCannotSplitAbsentBoot)

_FMS_BootPublicationUsesAdmittedPresence() {
	Body := _DriverFuncBody("ParseConfigTomlFile")
	Assert(Body != "", "the actual configuration cache owner must be readable")
	Assert(!InStr(Body, "FileExist("), "a post-read existence check cannot decide which admitted generation to publish")
	Assert(InStr(Body, "_ParseTomlCache[Path] := Snapshot.Cache") > 0,
		"both admitted presence and admitted absence must retain the actual cache identity")
	Assert(InStr(Body, "_ConfigTomlSnapshots[Path] := Snapshot") > 0,
		"both states must retain the exact source rows for the next boot consumer")
}
Test("configuration snapshot: source guard retains observed generation without post-read shortcuts (config-semantic-snapshot)",
	_FMS_BootPublicationUsesAdmittedPresence)

_FMS_InlineLiteralSpellingsKeepBooleanIntent(Path) {
	Snapshot := ConfigTomlReadSnapshot(Path)
	_FMS_AssertExactTree(Map("shortcuts", Map("screen", 0, "microsoft_bold", 0, "title_case", 1),
		"hotstrings", Map("autocorrection", Map("names", Map("enabled", 0, "time_activation_seconds", 0.125)),
		"french_autocorrection", Map("accents", Map("enabled", 1)))), Snapshot.Document)
	_FMS_AssertExactTree(Map("shortcuts", Map("screen", 0, "microsoft_bold", 0, "title_case", 1),
		"hotstrings.autocorrection", Map("names", Map("enabled", 0, "time_activation_seconds", 0.125)),
		"hotstrings.french_autocorrection", Map("accents", Map("enabled", 1))), Snapshot.Cache)
	Rows := Map()
	for Row in Snapshot.Rows
		Rows[Row.Section . "`n" . Row.Key] := Row
	AssertEqual(5, Rows.Count)
	AssertEqual("-0", Rows["shortcuts`nscreen"].Raw)
	AssertEqual("-0", Rows["shortcuts`nmicrosoft_bold"].Raw)
	AssertEqual("1", Rows["shortcuts`ntitle_case"].Raw)
	AssertEqual("-0", Rows["hotstrings.autocorrection`nnames"].ChildRaw["enabled"])
	AssertEqual("1", Rows["hotstrings.french_autocorrection`naccents"].ChildRaw["enabled"])
	Target := ManifestBuildFeaturesMap()
	AssertEqual(3, ApplyConfigToml(Target, Path, &Rejected, &Migrated, &Outdated))
	AssertEqual(0, Rejected)
	AssertEqual(2, Migrated, "only actual bare one leaves carry legacy Boolean intent")
	AssertEqual(3, Outdated.Count, "signed-zero integers cannot invent legacy Boolean intent")
	AssertFalse(Target["shortcuts"]["screen"])
	AssertFalse(Target["shortcuts"]["microsoft_bold"])
	AssertTrue(Target["shortcuts"]["title_case"])
	AssertFalse(Target["hotstrings"]["autocorrection"]["names"]["enabled"])
	AssertEqual(0.125, Target["hotstrings"]["autocorrection"]["names"]["time_activation_seconds"])
	AssertTrue(Target["hotstrings"]["french_autocorrection"]["accents"]["enabled"])
}
_FMS_InlineRawTokensNeverInventMigrationIntent() {
	_FMS_WithSource("inline_spelling", 'shortcuts = { screen = -0, microsoft_bold = -0, title_case = 1 }`nhotstrings = { autocorrection = { names = { enabled = -0, time_activation_seconds = 0.125 } }, french_autocorrection = { accents = { enabled = 1 } } }`n',
		_FMS_InlineLiteralSpellingsKeepBooleanIntent)
}
Test("configuration snapshot: exact inline child spellings retain legacy Boolean admission (config-semantic-snapshot)",
	_FMS_InlineRawTokensNeverInventMigrationIntent)

_FMS_RepeatedArrayOwnerCannotRewriteRows(Path) {
	ParseConfigTomlFile(Path)
	First := ManifestBuildFeaturesMap()
	AssertEqual(1, ApplyConfigToml(First, Path))
	First["llm"]["navigation"]["val_modifiers"].Push("ctrl")
	Second := ManifestBuildFeaturesMap()
	AssertEqual(1, ApplyConfigToml(Second, Path))
	AssertEqual(1, Second["llm"]["navigation"]["val_modifiers"].Length)
	AssertEqual("alt", Second["llm"]["navigation"]["val_modifiers"][1])
}
_FMS_RepeatedArrayReadUsesRetainedSource() {
	_FMS_WithSource("detached_array", '[llm.navigation]`nval_modifiers = ["alt"]`n', _FMS_RepeatedArrayOwnerCannotRewriteRows)
}
Test("configuration snapshot: repeated array consumers cannot mutate retained source rows (config-semantic-snapshot)",
	_FMS_RepeatedArrayReadUsesRetainedSource)

; Actual publication is followed by a fresh native bootstrap reader process.
; The complete expected image is authored here, independently of the renderer.
_FMS_FullSaveChangedInlineSource(Path) {
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries
	Runtime := _CFGFS_CaptureRuntime(), Coordinator := _ConfigFullSaveCoordinator()
	Target := ManifestBuildFeaturesMap()
	; A nondefault target exercises a durable leaf; the default 0.5 is sparse.
	Expected := Chr(0xFEFF) . '_meta.schema_version = 11`nhotstrings.trigger_char = "@"`nhotstrings.autocorrection = {names = {enabled = "true", time_activation_seconds = 0.75, future = "retain"}}`n[future]`nold = "retain" # user data`n'
	try {
		_CFGFS_Prepare(Path)
		_ConfigBootRejectedOverrides := 0
		_ConfigBootOutdatedEntries := Map()
		ParseConfigTomlFile(Path)
		AssertEqual(2, ApplyBootConfigToml(Target, Path), "the supported trigger scalar and valid timing record both apply")
		AssertEqual("@", Target["hotstrings"]["trigger_char"], "the independently supplied trigger leaf also reaches Features")
		AssertEqual(0, _ConfigBootRejectedOverrides)
		AssertTrue(_ConfigBootOutdatedEntries.Has("hotstrings.autocorrection.names`nenabled"))
		Names := Target["hotstrings"]["autocorrection"]["names"]
		AssertFalse(Names["enabled"])
		AssertEqual(0.25, Names["time_activation_seconds"], "the real boot loader supplies the original valid timing")
		Names["time_activation_seconds"] := 0.75
		Collect() {
			Updates := []
			_CollectFeatureUpdates(Updates, "hotstrings.autocorrection.names", Names)
			return Updates
		}
		Before := FSReadUtf8Exact(Path)
		Requested := 0
		AssertEqual(0, _ConfigFullSaveCoordinator().requested_generation)
		AssertEqual(0, _ConfigFullSaveCoordinator().committed_generation)
		Result := SaveFullConfig(0, (*) => true, true, 0, Collect, &Requested)
		AssertTrue((Result is Integer) && Result == CONFIG_SAVE_OK, "only the strict durable status acknowledges the real feature")
		AssertEqual(1, Requested)
		AssertEqual(Requested, _ConfigFullSaveCoordinator().requested_generation)
		AssertEqual(Requested, _ConfigFullSaveCoordinator().committed_generation)
		AssertEqual(Requested, _ConfigFullSaveCoordinator().settled_generation)
		AssertFalse(_ConfigFullSaveHasPending())
		Assert(Before != Expected, "the actual feature changes a valid owned timing leaf")
		AssertEqual(Expected, FSReadUtf8Exact(Path), "the complete image retains obsolete and foreign values")
		Harness := A_ScriptDir . "\support\feature_state_boot_smoke.ahk"
		Command := '"' . A_AhkPath . '" /ErrorStdOut "' . Harness . '" persisted_semantic "' . Path . '"'
		AssertEqual(0, RunWait(Command, A_ScriptDir, "Hide"), "a new native process reads the durable semantic source")
		AssertEqual(Expected, FSReadUtf8Exact(Path), "the fresh bootstrap reader cannot normalize or clean the source")
	} finally {
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
	}
}
_FMS_FullSaveChangedInlineAndRestart() {
	_FMS_WithSource("fullsave_inline_changed", '_meta.schema_version = 11`nhotstrings.trigger_char = "@"`nhotstrings.autocorrection = {names = {enabled = "true", time_activation_seconds = 0.25, future = "retain"}}`n[future]`nold = "retain" # user data`n',
		_FMS_FullSaveChangedInlineSource)
}
Test("configuration snapshot: actual full save changes an inline leaf and survives fresh native bootstrap (config-full-semantic-successor)",
	_FMS_FullSaveChangedInlineAndRestart)

; A removed feature stays source data until the existing explicit cleanup owner
; removes its exact offered keys. Ordinary publication owns only current names.
_FMS_RemovedCapsPreservedUntilCleanup(Path) {
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries
	Runtime := _CFGFS_CaptureRuntime(), Coordinator := _ConfigFullSaveCoordinator()
	BackupPath := ""
	Target := ManifestBuildFeaturesMap()
	try {
		_CFGFS_Prepare(Path)
		_ConfigBootRejectedOverrides := 0
		_ConfigBootOutdatedEntries := Map()
		Original := FSReadUtf8Exact(Path)
		AssertTrue(Target["hotstrings"]["autocorrection"].Has("names"), "the positive control has a published feature owner")
		AssertFalse(Target["hotstrings"]["autocorrection"].Has("caps"), "the removed feature cannot be restored as a fixture shortcut")
		AssertFalse(Target["hotstrings"]["autocorrection"]["names"]["enabled"])
		AssertEqual(0.5, Target["hotstrings"]["autocorrection"]["names"]["time_activation_seconds"])
		ParseConfigTomlFile(Path)
		AssertEqual(2, ApplyBootConfigToml(Target, Path), "only the two actual known names children apply")
		AssertEqual(0, _ConfigBootRejectedOverrides)
		AssertEqual(0, _ConfigBootOutdatedEntries.Count, "removed paths are unused, not invalid known values")
		AssertFalse(Target["hotstrings"]["autocorrection"].Has("caps"), "source parsing cannot manufacture removed runtime ownership")
		Names := Target["hotstrings"]["autocorrection"]["names"]
		AssertTrue(Names["enabled"])
		AssertEqual(0.25, Names["time_activation_seconds"])
		Names["time_activation_seconds"] := 0.75
		Collect() {
			Updates := []
			_CollectFeatureUpdates(Updates, "hotstrings.autocorrection.names", Names)
			return Updates
		}
		Requested := 0
		Result := SaveFullConfig(0, (*) => true, true, 0, Collect, &Requested)
		AssertTrue((Result is Integer) && Result == CONFIG_SAVE_OK)
		AssertEqual(1, Requested)
		AssertEqual(Requested, _ConfigFullSaveCoordinator().committed_generation)
		Expected := StrReplace(Original, "time_activation_seconds = 0.25", "time_activation_seconds = 0.75")
		AssertEqual(Expected, FSReadUtf8Exact(Path), "an unrelated admitted save retains the entire removed source namespace")
		Document := TOML_ParseDocument(FSReadUtf8Exact(Path))
		AssertTrue(Document["hotstrings"]["autocorrection"]["caps"]["enabled"].Value)
		AssertEqual(0.125, Document["hotstrings"]["autocorrection"]["caps"]["time_activation_seconds"])
		Scan := ConfigUnusedKeysFind(Path)
		AssertEqual("ok", Scan["status"])
		AssertEqual(2, Scan["keys"].Length, "only the two removed source children are offered")
		Identities := Map()
		for Entry in Scan["keys"] {
			AssertEqual("hotstrings.autocorrection.caps", Entry["section"])
			Identities[Entry["key"]] := true
		}
		AssertTrue(Identities.Has("enabled"))
		AssertTrue(Identities.Has("time_activation_seconds"))
		Stamp := "20990101-000312-" . ProcessExist() . "-" . A_TickCount
		CandidateBackup := ConfigUnusedKeysBackupPath(Path, Stamp)
		AssertFalse(FileExist(CandidateBackup), "the explicit cleanup fixture owns a fresh backup path")
		Removal := ConfigUnusedKeysRemove(Path, Scan["keys"], Stamp, 0, 0, Expected)
		AssertEqual("removed", Removal["status"])
		BackupPath := Removal["backup"]
		AssertEqual(CandidateBackup, BackupPath)
		AssertEqual(2, Removal["removed"])
		AssertEqual(Expected, FSReadUtf8Exact(Removal["backup"]), "cleanup backs up the exact admitted source first")
		Document := TOML_ParseDocument(FSReadUtf8Exact(Path))
		AssertFalse(Document["hotstrings"]["autocorrection"].Has("caps"))
		AssertTrue(Document["hotstrings"]["autocorrection"]["names"]["enabled"].Value)
		AssertEqual(0.75, Document["hotstrings"]["autocorrection"]["names"]["time_activation_seconds"])
		AssertEqual(0, ConfigUnusedKeysFind(Path)["keys"].Length)
	} finally {
		if BackupPath != ""
			try FileDelete(BackupPath)
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
	}
}
_FMS_RemovedCapsDoNotAcquireKnownOwnership() {
	_FMS_WithSource("removed_caps", '_meta.schema_version = 11`n[hotstrings.autocorrection.names]`nenabled = true`ntime_activation_seconds = 0.25`n[hotstrings.autocorrection.caps]`nenabled = true`ntime_activation_seconds = 0.125`n',
		_FMS_RemovedCapsPreservedUntilCleanup)
}
Test("configuration snapshot: removed caps stays runtime unread and is preserved until explicit cleanup (config-current-feature-owner)",
	_FMS_RemovedCapsDoNotAcquireKnownOwnership)

; Retired family source remains readable without becoming a current feature.
_FMS_RetiredCorrectionFamily(Path) {
	Original := FSRead(Path)
	Target := ManifestBuildFeaturesMap()
	Assert(ManifestFindEntryByPath("hotstrings.autocorrection.names") is Map,
		"the replacement fixture must exercise a current canonical feature")
	AssertFalse(ManifestFindEntryByPath("hotstrings.autocorrection.caps"))
	AssertEqual(true, IniCacheGet(ParseConfigTomlFile(Path), "hotstrings.autocorrection.caps", "enabled"))
	AssertEqual(0, ApplyConfigToml(Target, Path), "a retired family cannot apply as a current feature")
	AssertFalse(Target["hotstrings"]["autocorrection"].Has("caps"))
	AssertEqual(Original, FSRead(Path), "loading must preserve the retired user source bytes")
}
_FMS_RetiredCorrectionFamilyRemainsSourceOnly() {
	_FMS_WithSource("retired_correction", "[hotstrings.autocorrection.caps]`nenabled = true`n",
		_FMS_RetiredCorrectionFamily)
}
Test("configuration snapshot: retired correction family stays source-only (config-semantic-snapshot)",
	_FMS_RetiredCorrectionFamilyRemainsSourceOnly)

; A genuine loader owns exact user names; full-state traversal must not flatten them.
_FMS_ConfigExactNameFixtures() {
	return [
		{ name: "literal.ok", header: '[hotstrings.personal."literal.ok"]' },
		{ name: "", header: '[hotstrings.personal.""]' },
		{ name: Chr(0x1F680), header: '[hotstrings.personal."' . Chr(0x1F680) . '"]' },
		{ name: "Twin", header: '[hotstrings.personal."Twin"]' },
		{ name: "twin", header: '[hotstrings.personal."twin"]' }]
}

_FMS_ConfigExactNameSource(Fixture) {
	return "# private exact-name source`n" . Fixture.header . "`n"
		. "enabled = true # current choice`ntime_activation_seconds = 0.125`n"
		. '# keep source trivia`n[future]`n"literal.dot" = { rows = [[1, "x"]], count = 9223372036854775807 }`n'
}

_FMS_ConfigExactWholeCollector(Path, Fixture) {
	global _LLM_Menu
	Target := ManifestBuildFeaturesMap()
	AssertEqual(2, ApplyConfigToml(Target, Path), "the real reader admits both dynamic typed fields")
	AssertTrue(Target["hotstrings"]["personal"].Has(Fixture.name))
	Menu := _HSDeepCloneMap(_LLM_Menu)
	Menu["onboarding_seen"] := false
	Menu["app_profile_overrides"] := Map()
	Menu["user_profiles"] := []
	State := MasterGateState(), PriorState := State.Clone()
	try {
		State["initialized"] := false
		Updates := _ConfigCollectFullSaveUpdates(Target, Menu)
		Found := 0
		for Update in Updates {
			Parts := TOML_ParseKeyPath(Update.Section, true)
			if !_FMS_ConfigExactPersonalRow(Parts, Fixture.name)
				continue
			AssertEqual(Fixture.name, Parts[3], "the real full-state collector retains the exact admitted name")
			AssertTrue(Update.Key == "enabled" || Update.Key == "time_activation_seconds")
			AssertFalse(Update.HasOwnProp("Delete"), "both explicit choices differ from their published defaults")
			AssertEqual(Update.Key == "enabled" ? true : 0.125, Update.Value)
			Found += 1
		}
		AssertEqual(2, Found, "the genuine whole collector must include both exact dynamic rows")
	} finally {
		State.Clear()
		for Key, Value in PriorState
			State[Key] := Value
	}
}
_FMS_ConfigWholeCollectorsKeepExactNames() {
	for Index, Fixture in _FMS_ConfigExactNameFixtures()
		_FMS_WithSource("fullcollector_name_" . Index, _FMS_ConfigExactNameSource(Fixture),
			_FMS_ConfigExactWholeCollector.Bind(, Fixture))
}
Test("configuration snapshot: actual whole full-state collector retains exact semantic names (config-full-state-exact-path)",
	_FMS_ConfigWholeCollectorsKeepExactNames)

; The same recursive collector and sparse adapter feed the real durable full-save owner.
_FMS_ConfigExactCollectedSubtree(Target) {
	Updates := []
	_CollectFeatureUpdates(Updates, "hotstrings.personal", Target["hotstrings"]["personal"])
	return _ConfigSparseUpdates(Updates)
}

_FMS_ConfigExactNameFullSave(Path, Fixture) {
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries
	Runtime := _CFGFS_CaptureRuntime(), Coordinator := _ConfigFullSaveCoordinator()
	Original := '_meta.schema_version = 11`n' . _FMS_ConfigExactNameSource(Fixture)
	Target := ManifestBuildFeaturesMap()
	try {
		_CFGFS_Prepare(Path)
		_ConfigBootRejectedOverrides := 0
		_ConfigBootOutdatedEntries := Map()
		AssertEqual(2, ApplyBootConfigToml(Target, Path))
		AssertEqual(Original, FSRead(Path))
		Collector := _FMS_ConfigExactCollectedSubtree.Bind(Target)
		AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(0, (*) => true, true, 0, Collector))
		AssertEqual(Original, FSRead(Path), "a collected semantic no-op retains the complete handwritten source")
		Target["hotstrings"]["personal"][Fixture.name]["enabled"] := false
		AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(0, (*) => true, true, 0, Collector))
		ExpectedSource := "_meta.schema_version = 11`n# private exact-name source`n" . Fixture.header . "`n"
			. "time_activation_seconds = 0.125`n"
			. '# keep source trivia`n[future]`n"literal.dot" = { rows = [[1, "x"]], count = 9223372036854775807 }`n'
		AssertEqual(ExpectedSource, FSRead(Path), "only the explicitly cleared leaf is removed")
		Personal := Map()
		Personal.CaseSense := "On"
		Personal[Fixture.name] := Map("time_activation_seconds", 0.125)
		_FMS_AssertExactTree(Map("hotstrings", Map("personal", Personal),
			"future", Map("literal.dot", Map("rows", [[1, "x"]], "count", 9223372036854775807)),
			"_meta", Map("schema_version", 11)),
			TOML_ParseDocument(FSRead(Path)))
		Reloaded := ManifestBuildFeaturesMap()
		AssertEqual(1, ApplyConfigToml(Reloaded, Path), "the genuine reload reader keeps the exact remaining owner")
		AssertTrue(Reloaded["hotstrings"]["personal"].Has(Fixture.name))
		AssertEqual(0.125, Reloaded["hotstrings"]["personal"][Fixture.name]["time_activation_seconds"])
		AssertEqual(_ConfigFullSaveCoordinator().requested_generation,
			_ConfigFullSaveCoordinator().committed_generation)
		AssertFalse(_ConfigFullSaveHasPending())
	} finally {
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
	}
}
_FMS_ConfigFullSaveKeepsExactNames() {
	for Index, Fixture in _FMS_ConfigExactNameFixtures()
		_FMS_WithSource("fullsave_name_" . Index, '_meta.schema_version = 11`n' . _FMS_ConfigExactNameSource(Fixture),
			_FMS_ConfigExactNameFullSave.Bind(, Fixture))
}
Test("configuration snapshot: real full-save publication and reload preserve exact semantic names (config-full-state-exact-path)",
	_FMS_ConfigFullSaveKeepsExactNames)

_FMS_ConfigExactCaseTwins() {
	Personal := Map()
	Personal.CaseSense := "On"
	Personal["Twin"] := Map("enabled", true)
	Personal["twin"] := Map("enabled", true)
	Rows := _FMS_ConfigExactCollectedSubtree(Map("hotstrings", Map("personal", Personal)))
	AssertEqual(2, Rows.Length)
	Seen := Map()
	Seen.CaseSense := "On"
	for Row in Rows {
		Parts := TOML_ParseKeyPath(Row.Section, true)
		AssertEqual(3, Parts.Length)
		Seen[Parts[3]] := Row.Value
	}
	AssertEqual(2, Seen.Count, "a supplied exact native Map must not collapse case twins during collection")
	AssertTrue(Seen.Has("Twin"))
	AssertTrue(Seen.Has("twin"))
	Exact := ManifestConfigSparseOperation('hotstrings.personal."literal.ok"', "enabled", true)
	AssertEqual('hotstrings.personal."literal.ok"', Exact.Section)
	AssertEqual("enabled", Exact.Key)
	AssertEqual(true, Exact.Value)
	AssertFalse(Exact.HasOwnProp("Delete"))
	AssertTrue(ManifestDynamicEntry("hotstrings.personal.user.enabled") is Map)
	AssertFalse(ManifestDynamicEntry('hotstrings.personal."literal.ok".enabled'),
		"the generic path API retains its original lexical segment contract")
	AssertThrows(ManifestConfigSparseOperation.Bind('hotstrings.personal."literal.ok"', "typo", true),
		"an exact user name cannot invent a dynamic field")
	AssertThrows(ManifestConfigSparseOperation.Bind('hotstrings.personall."literal.ok"', "enabled", true),
		"an adjacent prefix cannot acquire dynamic ownership")
}
Test("configuration snapshot: config-row adapter preserves twins and unchanged generic domains (config-full-state-exact-path)",
	_FMS_ConfigExactCaseTwins)


; Full-save traverses initialized personal defaults too. Select the exact fixture
; identity without relying on Map iteration order or flattening semantic segments.
_FMS_ConfigExactPersonalRow(Parts, Name) {
	return Parts is Array && Parts.Length == 3
		&& StrCompare(Parts[1], "hotstrings", true) == 0
		&& StrCompare(Parts[2], "personal", true) == 0
		&& StrCompare(Parts[3], Name, true) == 0
}
_FMS_ConfigExactPersonalRowSelection() {
	for Fixture in _FMS_ConfigExactNameFixtures() {
		Parts := TOML_ParseKeyPath(SubStr(Fixture.header, 2, StrLen(Fixture.header) - 2), true)
		AssertTrue(_FMS_ConfigExactPersonalRow(Parts, Fixture.name),
			"the handwritten physical header resolves to the exact fixture identity")
		AssertFalse(_FMS_ConfigExactPersonalRow(["hotstrings", "personal", "autocorrection"], Fixture.name),
			"an initialized default sibling is not the fixture under test")
		AssertFalse(_FMS_ConfigExactPersonalRow(["hotstrings", "personal", Fixture.name, "child"], Fixture.name),
			"a descendant must not be mistaken for its literal parent name")
		AssertFalse(_FMS_ConfigExactPersonalRow(["hotstrings", "Personal", Fixture.name], Fixture.name),
			"a case-distinct category cannot acquire the fixture identity")
	}
	AssertFalse(_FMS_ConfigExactPersonalRow(["hotstrings", "personal", "Twin"], "twin"),
		"two actual admitted case twins remain distinct")
	AssertFalse(_FMS_ConfigExactPersonalRow(TOML_ParseKeyPath("hotstrings.personal.literal.ok", true), "literal.ok"),
		"nested syntax is not the admitted literal-dot name")
	Defaults := ManifestBuildFeaturesMap()
	AssertTrue(Defaults["hotstrings"]["personal"].Has("autocorrection"),
		"the real collector input contains the default sibling that exposed the old premise")
}
Test("configuration snapshot: exact fixture row selection rejects initialized siblings and semantic-name decoys",
	_FMS_ConfigExactPersonalRowSelection)

; The whole native collector remains real: isolate its unrelated runtime owners
; at their published neutral values, then preserve one actual accepted change.
_FMS_FullSnapshotParentSource(Literal) {
	return '[_meta]`nschema_version = ' . ConfigMigrateCurrentVersion()
		. '`n[hotstrings]`nautocorrection = ' . Literal . ' # retained until explicit cleanup`n'
		. '[layout]`nergopti_variant = "ergopti"`n'
		. '[private]`n"literal.dot" = { keep = [1, "x"], date = 1979-05-27, count = 9223372036854775807 } # future source`n'
		. '[[private."future.rows"]]`nvalue = "first"`n[[private."future.rows"]]`nvalue = "second"`n'
}

_FMS_FullSnapshotParent(Path, Literal, Scenario := "complete") {
	global _I18nLocale, LOGGER_MIN_LEVEL, ScriptInformation
	global ConfigurationFile
	global ScriptShortcutAssignments, KeyboardShortcutAssignments, GestureAssignments
	global CategoryEnabled, UPDATER_CHECK_INTERVAL, UPDATER_CHANNEL, _IniCache
	global KEYBOARD_SHORTCUT_DEFAULTS
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries, Features
	global _ParseTomlCache, _TomlFileCache, _ConfigTomlSnapshots, _LOGGER_TEST_SINK
	Runtime := _CFGFS_CaptureRuntime(), Coordinator := _ConfigFullSaveCoordinator()
	State := MasterGateState(), PriorState := State.Clone()
	SavedI18nLocale := IsSet(_I18nLocale) ? _I18nLocale : unset
	SavedLOGGERMINLEVEL := IsSet(LOGGER_MIN_LEVEL) ? LOGGER_MIN_LEVEL : unset
	SavedScriptInformation := IsSet(ScriptInformation) ? ScriptInformation : unset
	SavedScriptShortcutAssignments := IsSet(ScriptShortcutAssignments) ? ScriptShortcutAssignments : unset
	SavedKeyboardShortcutAssignments := IsSet(KeyboardShortcutAssignments) ? KeyboardShortcutAssignments : unset
	SavedKeyboardDefaults := IsSet(KEYBOARD_SHORTCUT_DEFAULTS) ? KEYBOARD_SHORTCUT_DEFAULTS : unset
	SavedGestureAssignments := IsSet(GestureAssignments) ? GestureAssignments : unset
	SavedCategoryEnabled := IsSet(CategoryEnabled) ? CategoryEnabled : unset
	SavedUPDATERCHECKINTERVAL := IsSet(UPDATER_CHECK_INTERVAL) ? UPDATER_CHECK_INTERVAL : unset
	SavedUPDATERCHANNEL := IsSet(UPDATER_CHANNEL) ? UPDATER_CHANNEL : unset
	SavedIniCache := IsSet(_IniCache) ? _IniCache : unset
	Fields := [
		{ target: MetricsShortcuts, key: "enabled", path: "metrics.metrics_enabled" },
		{ target: MetricsShortcuts, key: "wpm_menubar_colors", path: "metrics.metrics_wpm_menubar_colors" },
		{ target: MetricsFilters, key: "private_browsing", path: "metrics.private_filter_enabled" },
		{ target: MetricsFilters, key: "secure_field", path: "metrics.secure_filter_enabled" },
		{ target: MetricsFilters, key: "system_auth", path: "metrics.system_auth_filter_enabled" },
		{ target: MetricsFilters, key: "encrypt", path: "metrics.encrypt" },
		{ target: WPMWidget, key: "visible", path: "metrics.wpm_widget_visible" },
		{ target: WPMWidget, key: "pos_x", path: "metrics.wpm_widget_x" },
		{ target: WPMWidget, key: "pos_y", path: "metrics.wpm_widget_y" },
		{ target: WPMWidget, key: "use_colors", path: "metrics.wpm_widget_colors" },
		{ target: WPMWidget, key: "show_graph", path: "metrics.wpm_widget_graph" }]
	PriorFields := [], PriorApps := MetricsFilters.disabled_apps
	Original := FSReadUtf8Exact(Path), Target := ManifestBuildFeaturesMap()
	BeforeFeatures := _HSDeepCloneMap(Features), Borrowed := 0, Collected := 0
	Foreign := Original . "# external generation during actual collection`n"
	Expected := StrReplace(Original, 'ergopti_variant = "ergopti"`n', 'ergopti_variant = "ergopti_plus"`n')
	FreshAbsentPath := ""
	Collect() {
		Collected += 1
		Rows := _ConfigCollectFullSaveUpdates(Target, false)
		Repeated := 0
		for Row in Rows {
			if Row.Section == "script" && Row.Key == "locale"
				Repeated += 1
		}
		Assert(Repeated >= 2, "the actual whole-state producer has intentional repeated runtime-owner rows")
		if Scenario == "late-neutral"
			Rows.Push({ Section: "hotstrings.autocorrection.names", Key: "enabled", Delete: 1 })
		if Scenario == "source" || Scenario == "absent"
			Assert(FSWriteDurable(Path, Foreign), "the external successor must reach the real filesystem")
		return Rows
	}
	try {
		_CFGFS_Prepare(Path)
		_ConfigBootRejectedOverrides := 0, _ConfigBootOutdatedEntries := Map()
		ApplyBootConfigToml(Target, Path)
		AssertEqual(0, _ConfigBootRejectedOverrides)
		Assert(_ConfigBootOutdatedEntries.Has("hotstrings`nautocorrection"), "the actual loader owns the obsolete parent classification")
		AssertFalse(Target["hotstrings"]["autocorrection"]["names"]["enabled"])
		Target["layout"]["ergopti_variant"] := "ergopti_plus"
		if Scenario == "nonneutral" || Scenario == "late-neutral"
			Target["hotstrings"]["autocorrection"]["names"]["enabled"] := true
		_I18nLocale := "fr", LOGGER_MIN_LEVEL := "INFO"
		ScriptInformation := Map("MagicKey", "★")
		ScriptShortcutAssignments := Map(), KeyboardShortcutAssignments := Map()
		; The headless runner omits feature_state; use its exact manifest default projection.
		KEYBOARD_SHORTCUT_DEFAULTS := Map()
		for Entry in ManifestFeaturesForSection("shortcuts.keyboard")
			KEYBOARD_SHORTCUT_DEFAULTS[Entry["id"]] := ManifestDefaultFor(Entry["path"])
		Assert(KEYBOARD_SHORTCUT_DEFAULTS.Count > 0, "the real collector receives the native manifest-derived keyboard defaults")
		GestureAssignments := Map(), CategoryEnabled := Map(), _IniCache := Map()
		UPDATER_CHECK_INTERVAL := unset, UPDATER_CHANNEL := unset
		MetricsFilters.disabled_apps := Map()
		for Field in Fields {
			PriorFields.Push({ target: Field.target, key: Field.key, value: Field.target.%Field.key% })
			Field.target.%Field.key% := ManifestDefaultFor(Field.path)
		}
		State["initialized"] := false
		if Scenario == "repair" {
			Repair := StrReplace(Original, 'autocorrection = ' . Literal . ' # retained until explicit cleanup`n',
				'[hotstrings.autocorrection.names]`nenabled = true`n')
			Assert(FSWriteDurable(Path, Repair))
			Expected := StrReplace(Repair, 'ergopti_variant = "ergopti"`n', 'ergopti_variant = "ergopti_plus"`n')
			Expected := StrReplace(Expected, "enabled = true`n", "")
			Assert(_ConfigBootOutdatedEntries.Has("hotstrings`nautocorrection"), "the stale warning is deliberately retained")
		}
		if Scenario == "absent" {
			Assert(FSDelete(Path))
			AssertFalse(FileExist(Path), "source admission must observe genuine absence")
			AssertFalse(ConfigSchemaCanPrepareWrite(Path),
				"deleting a booted current source never grants fresh-missing write authority")
			; A distinct exact destination owns the genuine absent-source startup.
			; The original loaded obsolete-parent assertions remain above this transition.
			FreshAbsentPath := Path . ".fresh-absent.toml"
			AssertFalse(FSStrictExists(FreshAbsentPath), "the fresh absent destination is exclusively owned")
			AssertFalse(ConfigMigrateBoot(FreshAbsentPath, "known"), "no old journal identity is reused")
			PreparedAbsent := ConfigSchemaPrepareSource(FreshAbsentPath)
			Assert(PreparedAbsent is Map, "the actual readonly absent constructor must return its result")
			AssertEqual("fresh-missing", PreparedAbsent["status"])
			AssertEqual(1, PreparedAbsent["read_only"])
			AssertFalse(ConfigSchemaCanPrepareWrite(FreshAbsentPath), "readonly absence does not manufacture READY")
			BootAbsent := ConfigMigrateBoot(FreshAbsentPath)
			Assert(BootAbsent is Map, "the same genuine absent source completes actual default Boot")
			AssertEqual("absent", BootAbsent["status"])
			AssertEqual(0, BootAbsent["read_only"])
			AssertTrue(ConfigSchemaCanPrepareWrite(FreshAbsentPath))
			AssertFalse(FSStrictExists(FreshAbsentPath), "absent Boot creates no physical source")
			AssertEqual(0, _ConfigFullSaveCoordinator().requested_generation,
				"source construction and native Boot never invent requested intent")
			ConfigurationFile := FreshAbsentPath
			Path := FreshAbsentPath
			AssertEqual(Path, ConfigurationFile, "collection and the current destination share the exact fresh identity")
		}
		StampRefused := SubStr(Scenario, 1, 6) == "stamp-"
		if StampRefused {
			Registry := ConfigMigrateShippedRegistry()
			Stamp := Scenario == "stamp-invalid" ? '"invalid"'
				: Scenario == "stamp-newer" ? String(Registry["current"] + 1)
				: Scenario == "stamp-older" ? String(Registry["unstamped"])
				: Scenario == "stamp-boolean" ? "true"
				: Scenario == "stamp-fractional" ? String(Registry["current"] + 0.5) : ""
			ChangedSource := Scenario == "stamp-parent"
				? StrReplace(Original, '[_meta]`nschema_version = ' . Registry["current"] . '`n', '_meta = false`n')
				: StrReplace(Original, "schema_version = " . Registry["current"], "schema_version = " . Stamp)
			AssertFalse(ChangedSource == Original, "the actual post-boot schema edit must change physical source")
			Assert(FSWriteDurable(Path, ChangedSource))
			Original := ChangedSource
			AssertEqual("", TOML_WriteRefusal(Path), "fresh admission must not borrow a pre-existing session refusal")
		}
		if Scenario == "schema"
			TOML_RefuseWrites(Path, "invalid schema stamp")
		if Scenario == "borrowed" {
			Borrowed := _ConfigWriteLeaseTryAcquire(Path, "full-parent-test")
			Assert(Borrowed is Object)
		}
		Requested := 0
		NativeLog := [], PriorLogSink := _LOGGER_TEST_SINK
		try {
			LoggerSetTestSink((Line) => NativeLog.Push(Line))
			Result := SaveFullConfig(0, (*) => true, true, Borrowed, Collect, &Requested)
		} finally {
			_LOGGER_TEST_SINK := PriorLogSink
		}
		Trace := ""
		for Line in NativeLog
			Trace .= (Trace != "" ? "`n" : "") . Line
		Diagnostic := " | scenario=" . Scenario . " collected=" . Collected
			. " native_log=" . JsonStringLiteral(Trace)
		if Scenario == "absent" {
			Assert(Requested > 0, "the genuine fresh destination accepted its own exact request")
			AssertEqual(FreshAbsentPath, _ConfigFullSaveBoundPath())
			AssertEqual(FreshAbsentPath, ConfigurationFile)
		}
		if StampRefused || Scenario == "nonneutral" || Scenario == "late-neutral" || Scenario == "source" || Scenario == "absent" || Scenario == "schema" {
			AssertEqual(CONFIG_SAVE_FAILED, Result, "a nonneutral collision or withdrawn source never receives a successful full-save ACK" . Diagnostic)
			ActualSource := FSReadUtf8Exact(Path)
			ExpectedSource := Scenario == "source" || Scenario == "absent" ? Foreign : Original
			AssertEqual(ExpectedSource, ActualSource,
				"the complete retained or external source survives refusal" . Diagnostic
					. " expected=" . JsonStringLiteral(String(ExpectedSource))
					. " actual=" . JsonStringLiteral(String(ActualSource)))
			AssertEqual(0, _ConfigFullSaveCoordinator().committed_generation)
			if Scenario == "schema" {
				AssertEqual(0, Collected, "the strict session fence precedes the real collector")
				AssertEqual("invalid schema stamp", TOML_WriteRefusal(Path))
			} else if StampRefused {
				AssertEqual(0, Collected, "the current physical schema stamp is admitted before invoking any collector")
				Assert(Requested > 0 && _ConfigFullSaveHasPending(), "fresh schema refusal retains the exact outstanding request")
				AssertEqual(0, _ConfigFullSaveCoordinator().settled_generation)
				AssertEqual("", TOML_WriteRefusal(Path), "fresh snapshot refusal does not invent a session migration result")
				AssertFalse(FileExist(Path . ".bak"), "refused source admission does not create a backup")
			} else {
				AssertEqual(1, Collected)
				Assert(_ConfigFullSaveHasPending(), "failure retains the exact outstanding request")
			}
		} else {
			AssertEqual(CONFIG_SAVE_OK, Result, "unrelated real snapshot changes can commit while obsolete parents remain" . Diagnostic)
			AssertEqual(1, Collected)
			AssertEqual(Expected, FSReadUtf8Exact(Path), "the complete handwritten physical image changes only admitted owned fields")
			AssertEqual(Requested, _ConfigFullSaveCoordinator().committed_generation)
			AssertEqual(Requested, _ConfigFullSaveCoordinator().settled_generation)
			AssertFalse(_ConfigFullSaveHasPending())
			Doc := TOML_ParseDocument(FSReadUtf8Exact(Path))
			AssertEqual("ergopti_plus", Doc["layout"]["ergopti_variant"])
			if Scenario == "repair"
				Assert(Doc["hotstrings"]["autocorrection"]["names"] is Map && Doc["hotstrings"]["autocorrection"]["names"].Count == 0)
			else
				Assert(TOML_SameValue(TOML_ParseDocument(Original)["hotstrings"], Doc["hotstrings"]), "the obsolete raw model is retained without normalization")
			Assert(TOML_SameValue(TOML_ParseDocument(Original)["private"], Doc["private"]), "quoted future fields, dates, maximum integers and table-array generations remain unchanged")
			Restart := Path . ".restart.toml"
			try {
				Assert(FSWriteCreateDurable(Restart, Expected))
				; A fresh process first gives this exact source to the genuine
				; readonly journal. Reading alone never creates writer readiness.
				PreparedRestart := ConfigSchemaPrepareSource(Restart)
				AssertEqual("current", PreparedRestart["status"])
				AssertEqual(1, PreparedRestart["read_only"])
				AssertTrue(FSUtf8ExactMatches(Restart, Expected), "readonly restart construction preserves the complete independent source image")
				AssertFalse(ConfigSchemaCanPrepareWrite(Restart), "the native restart reader does not manufacture completed Boot")
				Reloaded := ManifestBuildFeaturesMap()
				ApplyConfigToml(Reloaded, Restart, &Rejected, , &Outdated)
				AssertEqual(0, Rejected)
				AssertEqual("ergopti_plus", Reloaded["layout"]["ergopti_variant"])
				AssertFalse(Reloaded["hotstrings"]["autocorrection"]["names"]["enabled"])
				if Scenario != "repair"
					Assert(Outdated.Has("hotstrings`nautocorrection"))
				AssertEqual(Expected, FSReadUtf8Exact(Restart))
			} finally {
				for Store in [_ParseTomlCache, _TomlFileCache, _ConfigTomlSnapshots] {
					if Store.Has(Restart)
						Store.Delete(Restart)
				}
				if FileExist(Restart)
					FSDelete(Restart)
			}
		}
		_FMS_AssertExactTree(BeforeFeatures, Features)
		if Borrowed is Object {
			Assert(_ConfigWriteLeaseOwns(Borrowed, Path), "a full save never releases its borrowed owner")
			AssertFalse(_ConfigWriteLeaseTryAcquire(Path, "intruder"))
		}
	} finally {
		if Borrowed is Object
			_ConfigWriteLeaseRelease(Borrowed)
		for Field in PriorFields
			Field.target.%Field.key% := Field.value
		MetricsFilters.disabled_apps := PriorApps
		_I18nLocale := IsSet(SavedI18nLocale) ? SavedI18nLocale : unset
		LOGGER_MIN_LEVEL := IsSet(SavedLOGGERMINLEVEL) ? SavedLOGGERMINLEVEL : unset
		ScriptInformation := IsSet(SavedScriptInformation) ? SavedScriptInformation : unset
		ScriptShortcutAssignments := IsSet(SavedScriptShortcutAssignments) ? SavedScriptShortcutAssignments : unset
		KeyboardShortcutAssignments := IsSet(SavedKeyboardShortcutAssignments) ? SavedKeyboardShortcutAssignments : unset
		KEYBOARD_SHORTCUT_DEFAULTS := IsSet(SavedKeyboardDefaults) ? SavedKeyboardDefaults : unset
		GestureAssignments := IsSet(SavedGestureAssignments) ? SavedGestureAssignments : unset
		CategoryEnabled := IsSet(SavedCategoryEnabled) ? SavedCategoryEnabled : unset
		UPDATER_CHECK_INTERVAL := IsSet(SavedUPDATERCHECKINTERVAL) ? SavedUPDATERCHECKINTERVAL : unset
		UPDATER_CHANNEL := IsSet(SavedUPDATERCHANNEL) ? SavedUPDATERCHANNEL : unset
		_IniCache := IsSet(SavedIniCache) ? SavedIniCache : unset
		State.Clear()
		for Key, Value in PriorState
			State[Key] := Value
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
		if FreshAbsentPath != "" {
			; Retire only this fixture's extra physical file and ordinary parse caches.
			; The native journal row and accepted-intent stores are never cleared.
			for Store in [_ParseTomlCache, _TomlFileCache, _ConfigTomlSnapshots] {
				if Store.Has(FreshAbsentPath)
					Store.Delete(FreshAbsentPath)
			}
			if FileExist(FreshAbsentPath)
				FSDelete(FreshAbsentPath)
		}
	}
}

_FMS_FullSnapshotParentCase(Literal, Scenario := "complete") {
	_FMS_WithSource("full_parent_" . Scenario . "_" . A_TickCount, _FMS_FullSnapshotParentSource(Literal),
		_FMS_FullSnapshotParent.Bind(, Literal, Scenario))
}
Test("full-snapshot-obsolete-parent: actual scalar namespace retains source and unrelated state", _FMS_FullSnapshotParentCase.Bind('false'))
Test("full-snapshot-obsolete-parent: actual string namespace retains source", _FMS_FullSnapshotParentCase.Bind('"old-shape"'))
Test("full-snapshot-obsolete-parent: actual integer namespace retains source", _FMS_FullSnapshotParentCase.Bind('2'))
Test("full-snapshot-obsolete-parent: actual float namespace retains source", _FMS_FullSnapshotParentCase.Bind('2.0'))
Test("full-snapshot-obsolete-parent: actual array namespace retains source", _FMS_FullSnapshotParentCase.Bind('[1, "x"]'))
Test("full-snapshot-obsolete-parent: actual borrowed lease remains owned", _FMS_FullSnapshotParentCase.Bind('false', "borrowed"))
Test("full-snapshot-obsolete-parent: actual nonneutral child refuses complete source", _FMS_FullSnapshotParentCase.Bind('false', "nonneutral"))
Test("full-snapshot-obsolete-parent: later neutral repetition cannot hide a nonneutral child", _FMS_FullSnapshotParentCase.Bind('false', "late-neutral"))
Test("full-snapshot-obsolete-parent: actual collection cannot adopt an external generation", _FMS_FullSnapshotParentCase.Bind('false', "source"))
Test("full-snapshot-obsolete-parent: admitted absence cannot adopt an external creation", _FMS_FullSnapshotParentCase.Bind('false', "absent"))
Test("full-snapshot-obsolete-parent: actual schema fence precedes collection", _FMS_FullSnapshotParentCase.Bind('false', "schema"))
Test("full-snapshot-obsolete-parent: actual repair supersedes stale boot warning", _FMS_FullSnapshotParentCase.Bind('false', "repair"))
Test("full-snapshot-obsolete-parent: fresh invalid string stamp refuses before collection", _FMS_FullSnapshotParentCase.Bind('false', "stamp-invalid"))
Test("full-snapshot-obsolete-parent: fresh newer stamp refuses before collection", _FMS_FullSnapshotParentCase.Bind('false', "stamp-newer"))
Test("full-snapshot-obsolete-parent: fresh older migration-eligible stamp refuses before collection", _FMS_FullSnapshotParentCase.Bind('false', "stamp-older"))
Test("full-snapshot-obsolete-parent: fresh Boolean stamp refuses before collection", _FMS_FullSnapshotParentCase.Bind('false', "stamp-boolean"))
Test("full-snapshot-obsolete-parent: fresh fractional stamp refuses before collection", _FMS_FullSnapshotParentCase.Bind('false', "stamp-fractional"))
Test("full-snapshot-obsolete-parent: fresh scalar metadata-parent stamp refuses before collection", _FMS_FullSnapshotParentCase.Bind('false', "stamp-parent"))

_FMS_FullSnapshotScopeAndIndividualStayStrict() {
	Source := '[hotstrings]`nautocorrection = false # retained`n'
	AssertEqual(0, ConfigFullSnapshotCaptureObsoleteSource("").Length, "genuine absence retains the existing unstamped admission contract")
	AssertEqual(1, ConfigFullSnapshotCaptureObsoleteSource(Source).Length, "unstamped source is classified without inventing a migration")
	Delete := { Section: "hotstrings.autocorrection.names", Key: "enabled", Delete: 1 }
	Repeated := [Delete, Delete.Clone()]
	AssertThrows(ConfigScopePreserveObsoleteSource.Bind(Source, Repeated), "ordinary scope batches still refuse duplicate effects")
	AssertEqual(0, ConfigFullSnapshotPreserveObsoleteSource(ConfigFullSnapshotCaptureObsoleteSource(Source), Repeated).Length, "every repeated neutral descendant retains the same obsolete parent")
	Changed := [{ Section: Delete.Section, Key: Delete.Key, Value: true }, Delete]
	AssertThrows(ConfigFullSnapshotPreserveObsoleteSource.Bind(ConfigFullSnapshotCaptureObsoleteSource(Source), Changed), "a later neutral effect cannot hide earlier nonneutral replacement")
	Path := _FM_WriteFixture("full_snapshot_individual_strict", Source)
	Original := FSReadUtf8Exact(Path)
	try {
		AssertFalse(TOML_ConfigBatchWrite(Path, [Delete]), "individual typed writes do not gain full-snapshot preservation semantics")
		AssertEqual(Original, FSReadUtf8Exact(Path))
	} finally {
		if FileExist(Path)
			FSDelete(Path)
	}
}
Test("full-snapshot-obsolete-parent: scope duplicates and individual writer refusal stay strict", _FMS_FullSnapshotScopeAndIndividualStayStrict)

; A file-backed personal category owns its canonical lowercase identity before
; configuration boot. Exact TOML names do not grant a different alias its intent.
_FMS_PersonalFileCaseAliasSource(Name) {
	return '[_meta]`nschema_version = ' . ConfigMigrateCurrentVersion()
		. '`n[hotstrings.personal.' . Name . ']`nenabled = true # exact source owner`n'
		. '[future]`n"literal.dot" = { count = 9223372036854775807, date = 1979-05-27 } # retained`n'
}

_FMS_PersonalFileCaseAlias(Path, Name) {
	global _I18nLocale, LOGGER_MIN_LEVEL, ScriptInformation
	global ScriptShortcutAssignments, KeyboardShortcutAssignments, GestureAssignments
	global KEYBOARD_SHORTCUT_DEFAULTS
	global CategoryEnabled, UPDATER_CHECK_INTERVAL, UPDATER_CHANNEL, _IniCache
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries, Features
	global _ParseTomlCache, _TomlFileCache, _ConfigTomlSnapshots, _ReadPersonalTomlCache
	global _TomlUnreadableFiles, _TomlReadFailures
	Runtime := _CFGFS_CaptureRuntime(), Coordinator := _ConfigFullSaveCoordinator()
	State := MasterGateState(), PriorState := State.Clone()
	SavedI18nLocale := IsSet(_I18nLocale) ? _I18nLocale : unset
	SavedLOGGERMINLEVEL := IsSet(LOGGER_MIN_LEVEL) ? LOGGER_MIN_LEVEL : unset
	SavedScriptInformation := IsSet(ScriptInformation) ? ScriptInformation : unset
	SavedScriptShortcutAssignments := IsSet(ScriptShortcutAssignments) ? ScriptShortcutAssignments : unset
	SavedKeyboardShortcutAssignments := IsSet(KeyboardShortcutAssignments) ? KeyboardShortcutAssignments : unset
	SavedKeyboardDefaults := IsSet(KEYBOARD_SHORTCUT_DEFAULTS) ? KEYBOARD_SHORTCUT_DEFAULTS : unset
	SavedGestureAssignments := IsSet(GestureAssignments) ? GestureAssignments : unset
	SavedCategoryEnabled := IsSet(CategoryEnabled) ? CategoryEnabled : unset
	SavedUPDATERCHECKINTERVAL := IsSet(UPDATER_CHECK_INTERVAL) ? UPDATER_CHECK_INTERVAL : unset
	SavedUPDATERCHANNEL := IsSet(UPDATER_CHANNEL) ? UPDATER_CHANNEL : unset
	SavedIniCache := IsSet(_IniCache) ? _IniCache : unset
	Fields := [
		{ target: MetricsShortcuts, key: "enabled", path: "metrics.metrics_enabled" },
		{ target: MetricsShortcuts, key: "wpm_menubar_colors", path: "metrics.metrics_wpm_menubar_colors" },
		{ target: MetricsFilters, key: "private_browsing", path: "metrics.private_filter_enabled" },
		{ target: MetricsFilters, key: "secure_field", path: "metrics.secure_filter_enabled" },
		{ target: MetricsFilters, key: "system_auth", path: "metrics.system_auth_filter_enabled" },
		{ target: MetricsFilters, key: "encrypt", path: "metrics.encrypt" },
		{ target: WPMWidget, key: "visible", path: "metrics.wpm_widget_visible" },
		{ target: WPMWidget, key: "pos_x", path: "metrics.wpm_widget_x" },
		{ target: WPMWidget, key: "pos_y", path: "metrics.wpm_widget_y" },
		{ target: WPMWidget, key: "use_colors", path: "metrics.wpm_widget_colors" },
		{ target: WPMWidget, key: "show_graph", path: "metrics.wpm_widget_graph" }]
	PriorFields := [], PriorApps := MetricsFilters.disabled_apps
	SavedFeatures := Features
	SavedPersonalCache := _ReadPersonalTomlCache
	PersonalPath := Path . ".personal_hotstrings.toml", Restart := Path . ".restart.toml"
	; Retain only diagnostics belonging to these two newly owned paths. Store
	; the actual prior value reference, including false or object sentinels.
	OwnedDiagnostics := []
	for Extra in [Restart, PersonalPath] {
		for Store in [_TomlUnreadableFiles, _TomlReadFailures] {
			Present := Store.Has(Extra)
			OwnedDiagnostics.Push({ store: Store, key: Extra, present: Present,
				value: Present ? Store[Extra] : false })
		}
		Store := _TOML_WriteRefusals(), Key := _TOML_WriteRefusalKey(Extra)
		Present := Store.Has(Key)
		OwnedDiagnostics.Push({ store: Store, key: Key, present: Present,
			value: Present ? Store[Key] : false })
	}
	PersonalSource := Chr(0xFEFF) . '[_meta]`nsections_order = ["owned"]`n'
		. '[[owned]]`n"zz_owned_probe" = { output = "PRIVATE", is_word = false, auto_expand = true, is_case_sensitive = false, final_result = false }`n'
	Original := FSReadUtf8Exact(Path)
	Canonical := StrCompare(Name, "owned", true) == 0
	try {
		_CFGFS_Prepare(Path)
		_ConfigBootRejectedOverrides := 0, _ConfigBootOutdatedEntries := Map()
		_I18nLocale := "fr", LOGGER_MIN_LEVEL := "INFO"
		ScriptInformation := Map("MagicKey", "★")
		ScriptShortcutAssignments := Map(), KeyboardShortcutAssignments := Map()
		; The headless runner omits feature_state; use its exact manifest default projection.
		KEYBOARD_SHORTCUT_DEFAULTS := Map()
		for Entry in ManifestFeaturesForSection("shortcuts.keyboard")
			KEYBOARD_SHORTCUT_DEFAULTS[Entry["id"]] := ManifestDefaultFor(Entry["path"])
		Assert(KEYBOARD_SHORTCUT_DEFAULTS.Count > 0, "the real alias collector receives the native manifest-derived keyboard defaults")
		GestureAssignments := Map(), CategoryEnabled := Map(), _IniCache := Map()
		UPDATER_CHECK_INTERVAL := unset, UPDATER_CHANNEL := unset
		MetricsFilters.disabled_apps := Map()
		for Field in Fields {
			PriorFields.Push({ target: Field.target, key: Field.key, value: Field.target.%Field.key% })
			Field.target.%Field.key% := ManifestDefaultFor(Field.path)
		}
		State["initialized"] := false
		ScriptInformation["PersonalTomlPath"] := PersonalPath
		Assert(FSWriteCreateDurable(PersonalPath, PersonalSource), "the actual personal owner must exist on disk")
		_ReadPersonalTomlCache := false
		Features := ManifestBuildFeaturesMap()
		AssertFalse(Features["hotstrings"]["personal"].Has("owned"), "the category must be discovered from the real personal file")
		Model := ReadPersonalToml(true)
		AssertEqual(1, Model["sections_order"].Length)
		AssertEqual("owned", Model["sections_order"][1])
		AssertEqual(1, Model["sections"]["owned"]["entries"].Length)
		AssertEqual("zz_owned_probe", Model["sections"]["owned"]["entries"][1]["trigger"])
		AssertEqual("PRIVATE", Model["sections"]["owned"]["entries"][1]["output"])
		Assert(_PersonalTomlCanonicalSectionOrder(Model, &Detail) is Array,
			"the genuine personal file passes the actual canonical owner contract")
		UpperModel := _HSDeepCloneMap(Model)
		UpperModel["sections"] := Map("Owned", UpperModel["sections"]["owned"])
		UpperModel["sections_order"] := ["Owned"]
		AssertFalse(_PersonalTomlCanonicalSectionOrder(UpperModel, &UpperDetail),
			"a distinct uppercase personal owner is outside the actual canonical file contract")
		Assert(InStr(UpperDetail, "lowercase", true) > 0)
		for Section in Model["sections_order"] {
			if Section != "-"
				EnsurePersonalHotstringFeature(Section)
		}
		ActualNames := []
		for Key in Features["hotstrings"]["personal"] {
			if StrCompare(Key, "owned", true) == 0
				ActualNames.Push(Key)
		}
		AssertEqual(1, ActualNames.Length, "the real boot owner seeds exactly the stored lowercase category")
		AssertFalse(Features["hotstrings"]["personal"]["owned"]["enabled"])
		Snapshot := ConfigTomlReadSnapshot(Path)
		Exact := Snapshot.Document["hotstrings"]["personal"]
		AssertEqual("On", Exact.CaseSense)
		AssertTrue(Exact.Has(Name))
		AssertFalse(Exact.Has(Canonical ? "Owned" : "owned"), "the typed source must not collapse aliases")
		AssertEqual("On", Snapshot.Cache.CaseSense)
		AssertTrue(Snapshot.Cache.Has("hotstrings.personal." . Name))
		AssertFalse(Snapshot.Cache.Has("hotstrings.personal." . (Canonical ? "Owned" : "owned")))
		Assert(ApplyBootConfigToml(Features, Path) >= 0, "the real configured boot reader must admit the complete source")
		AssertEqual(0, _ConfigBootRejectedOverrides)
		AssertEqual(Original, FSReadUtf8Exact(Path), "boot must preserve the exact case-distinct physical source")
		AssertEqual(Canonical, Features["hotstrings"]["personal"]["owned"]["enabled"],
			"only the canonical file-backed owner may receive the persisted enabled intent")
		Collect() => _ConfigCollectFullSaveUpdates(Features, false)
		Requested := 0
		AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(0, (*) => true, true, 0, Collect, &Requested),
			"the actual whole-state collector and native writer must acknowledge an ordinary save")
		AssertEqual(Original, FSReadUtf8Exact(Path), "ordinary save retains the exact original source without normalizing the alias")
		AssertEqual(PersonalSource, FSReadUtf8Exact(PersonalPath), "configuration save must not rewrite the actual personal owner")
		AssertEqual(Requested, _ConfigFullSaveCoordinator().committed_generation)
		AssertEqual(Requested, _ConfigFullSaveCoordinator().settled_generation)
		AssertFalse(_ConfigFullSaveHasPending())
		Assert(FSWriteCreateDurable(Restart, Original))
		; Restart reads this new exact destination through its genuine readonly owner.
		AssertFalse(ConfigMigrateBoot(Restart, "known"), "restart owns a fresh journal identity")
		PreparedRestart := ConfigSchemaPrepareSource(Restart)
		Assert(PreparedRestart is Map, "the real readonly restart constructor returns its result")
		AssertEqual("current", PreparedRestart["status"])
		AssertEqual(1, PreparedRestart["read_only"])
		AssertTrue(FSUtf8ExactMatches(Restart, Original), "readonly restart construction preserves all independent bytes")
		AssertFalse(ConfigSchemaCanPrepareWrite(Restart), "the restart reader never manufactures completed writer Boot")
		Features := ManifestBuildFeaturesMap()
		_ReadPersonalTomlCache := false
		ReloadedModel := ReadPersonalToml(true)
		for Section in ReloadedModel["sections_order"] {
			if Section != "-"
				EnsurePersonalHotstringFeature(Section)
		}
		AssertFalse(Features["hotstrings"]["personal"]["owned"]["enabled"])
		_ConfigBootRejectedOverrides := 0, _ConfigBootOutdatedEntries := Map()
		Assert(ApplyBootConfigToml(Features, Restart) >= 0, "restart uses a fresh native configuration source identity")
		AssertEqual(0, _ConfigBootRejectedOverrides)
		AssertEqual(Canonical, Features["hotstrings"]["personal"]["owned"]["enabled"],
			"the same actual file-backed owner retains the case-sensitive intent boundary after restart")
		AssertEqual(Original, FSReadUtf8Exact(Restart))
		AssertEqual(PersonalSource, FSReadUtf8Exact(PersonalPath))
	} finally {
		; Native read refusal and migration debt must not outlive this fixture.
		; Restore presence as well as exact prior values; unrelated entries stay.
		for Diagnostic in OwnedDiagnostics {
			if Diagnostic.present
				Diagnostic.store[Diagnostic.key] := Diagnostic.value
			else if Diagnostic.store.Has(Diagnostic.key)
				Diagnostic.store.Delete(Diagnostic.key)
		}
		Features := SavedFeatures
		_ReadPersonalTomlCache := SavedPersonalCache
		for Extra in [Restart, PersonalPath] {
			for Store in [_ParseTomlCache, _TomlFileCache, _ConfigTomlSnapshots] {
				if Store.Has(Extra)
					Store.Delete(Extra)
			}
			if FileExist(Extra)
				FSDelete(Extra)
		}
		for Field in PriorFields
			Field.target.%Field.key% := Field.value
		MetricsFilters.disabled_apps := PriorApps
		_I18nLocale := IsSet(SavedI18nLocale) ? SavedI18nLocale : unset
		LOGGER_MIN_LEVEL := IsSet(SavedLOGGERMINLEVEL) ? SavedLOGGERMINLEVEL : unset
		ScriptInformation := IsSet(SavedScriptInformation) ? SavedScriptInformation : unset
		ScriptShortcutAssignments := IsSet(SavedScriptShortcutAssignments) ? SavedScriptShortcutAssignments : unset
		KeyboardShortcutAssignments := IsSet(SavedKeyboardShortcutAssignments) ? SavedKeyboardShortcutAssignments : unset
		KEYBOARD_SHORTCUT_DEFAULTS := IsSet(SavedKeyboardDefaults) ? SavedKeyboardDefaults : unset
		GestureAssignments := IsSet(SavedGestureAssignments) ? SavedGestureAssignments : unset
		CategoryEnabled := IsSet(SavedCategoryEnabled) ? SavedCategoryEnabled : unset
		UPDATER_CHECK_INTERVAL := IsSet(SavedUPDATERCHECKINTERVAL) ? SavedUPDATERCHECKINTERVAL : unset
		UPDATER_CHANNEL := IsSet(SavedUPDATERCHANNEL) ? SavedUPDATERCHANNEL : unset
		_IniCache := IsSet(SavedIniCache) ? SavedIniCache : unset
		State.Clear()
		for Key, Value in PriorState
			State[Key] := Value
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
	}
}

_FMS_PersonalFileCaseAliases() {
	for Name in ["owned", "Owned"]
		_FMS_WithSource("personal_case_alias_" . Name, _FMS_PersonalFileCaseAliasSource(Name),
			_FMS_PersonalFileCaseAlias.Bind(, Name))
}
Test("configuration snapshot: genuine personal file owner does not transfer case-distinct config intent (config-personal-file-case-alias)",
	_FMS_PersonalFileCaseAliases)

; A real private constructor refusal must not masquerade as physical unreadability.
_FMS_LogicalRegistryRefusalHasNoPhysicalDiagnostic(Path) {
	global _ConfigBootReadFailed
	Before := FSReadUtf8Exact(Path)
	Admission := ConfigMigrateBoot(Path, "capture_read")
	AssertTrue(HasMethod(Admission, "Call"), "the actual original readonly constructor is available before withdrawal")
	CanonicalSource := SubStr(Before, 1, 1) == Chr(0xFEFF) ? SubStr(Before, 2) : Before
	AssertTrue(Admission.Call(CanonicalSource, 1))
	Registry := ConfigMigrateShippedRegistry(), Calls := { foreign: 0 }
	AssertFalse(Object.Prototype.HasOwnProp.Call(Registry, "__Enum"))
	try {
		Registry.DefineProp("__Enum", { Call: (This, Arity) =>
			(Calls.foreign += 1, Map.Prototype.__Enum.Call(This, Arity)) })
		Cache := ParseConfigTomlFile(Path)
		AssertEqual(0, Cache.Count, "the genuine schema owner withdrawal still refuses the real reader")
		AssertEqual(0, Calls.foreign, "no revoked registry observer executes before diagnostic refusal")
		AssertFalse(TOML_UnreadableFile(Path), "logical native-owner refusal issues no physical read diagnostic")
		AssertEqual(0, ConfigMigrateBoot(Path, "consume_read_failure"), "public queries cannot mint an observed native failure")
		AssertTrue(_ConfigBootReadFailed)
		AssertFalse(ConfigFullStateCanPersist())
		AssertTrue(FSUtf8ExactMatches(Path, Before))
	} finally {
		if Object.Prototype.HasOwnProp.Call(Registry, "__Enum")
			Registry.DeleteProp("__Enum")
	}
	Repaired := ParseConfigTomlFile(Path)
	AssertEqual("@", IniCacheGet(Repaired, "hotstrings", "trigger_char"))
	AssertFalse(TOML_UnreadableFile(Path))
	AssertEqual(0, Calls.foreign, "exact original registry repair executes no rejected observer")
	AssertTrue(FSUtf8ExactMatches(Path, Before), "legacy source bytes remain independent and unchanged")
}
_FMS_LogicalRegistryRefusalDiagnostic() {
	_FMS_WithSource("logical_refusal_diagnostic", 'hotstrings.trigger_char = "@"`n',
		_FMS_LogicalRegistryRefusalHasNoPhysicalDiagnostic)
}
Test("configuration snapshot: genuine logical owner refusal never issues physical unreadability", _FMS_LogicalRegistryRefusalDiagnostic)


; Observes only the completed actual result. No extra save, native ACK,
; schema constructor, lease acquisition or owner repair runs for diagnosis.
_FMS_TraceClosedFullSaveRefusal(Path, SaveResult, Observed, Original) {
	global TEST_RESULTS_FILE
	Status := (SaveResult is Integer) ? SaveResult : "noninteger"
	Phase := Observed.phase
	if !(Phase is String) || !InStr("|unobserved|source|collector|writer|candidate|native_replace|schema_capture|native_ack_noop|native_ack_image|", "|" . Phase . "|")
		Phase := "noncanonical"
	CollectorEntered := Observed.collector_entered == 1 ? 1 : 0
	CollectorCompleted := Observed.collector_completed == 1 ? 1 : 0
	SchemaAdmitted := ConfigSchemaCanPrepareWrite(Path) ? 1 : 0
	ReadBusy := FileReadActivityBusy(Path) ? 1 : 0
	TerminalActive := _ConfigWriteTerminalIsActive() ? 1 : 0
	Unchanged := FSRead(Path) == Original ? 1 : 0
	; Only a closed message emitted after the actual native ACK refused can
	; establish refusal. Top-level result and source equality remain insufficient.
	NativeAck := (Phase == "native_ack_noop" || Phase == "native_ack_image") ? "0" : "unobserved"
	Line := "# group1-actual-fullsave-refusal: result=" . Status
		. ";phase=" . Phase . ";collector_entered=" . CollectorEntered
		. ";collector_completed=" . CollectorCompleted . ";schema_admitted=" . SchemaAdmitted
		. ";read_busy=" . ReadBusy . ";terminal_active=" . TerminalActive
		. ";source_text_unchanged=" . Unchanged . ";native_ack=" . NativeAck . "`r`n"
	try _TestResultsWrite(TEST_RESULTS_FILE, Line)
}
