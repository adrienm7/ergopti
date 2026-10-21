; tests/unit/infra/config/persistence/test_apply_config_toml.ahk

; ==============================================================================
; MODULE: ApplyConfigToml Override Engine
; DESCRIPTION:
; ApplyConfigToml applies config.toml overrides onto the manifest-built
; Features map: typed scalars that cannot alias, legacy boolean migration,
; shared value domains, unused sections offered for cleanup and the dynamic
; personal sections.
; ==============================================================================

#Requires AutoHotkey v2.0





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

TestFMv2_LiteralStringsKeepManifestTypes() {
	OldFeatures := _FM_BeginIsolated()
	try {
		Path := _FM_WriteFixture("literal_string_types",
			"[script]`nlocale = 'en'`nlog_level = 'ERROR' # explicit threshold`n"
			. "[shortcuts.keyboard]`nctrl_b = 'microsoft_bold'`n")
		AssertEqual(3, ApplyConfigToml(Features, Path, &Rejected, , &Outdated),
			"literal strings must apply to string, enum and action manifest leaves")
		AssertEqual("en", Features["script"]["locale"])
		AssertEqual("ERROR", Features["script"]["log_level"])
		AssertEqual("microsoft_bold", Features["shortcuts"]["keyboard"]["ctrl_b"])
		AssertEqual(0, Rejected)
		AssertEqual(0, Outdated.Count,
			"valid literal strings must never be proposed for configuration cleanup")
	} finally {
		if IsSet(Path) && FileExist(Path)
			FileDelete(Path)
		_FM_EndIsolated(OldFeatures)
	}
}
Test("ApplyConfigToml: literal strings retain manifest types (toml-literal-string-kind)",
	TestFMv2_LiteralStringsKeepManifestTypes)
