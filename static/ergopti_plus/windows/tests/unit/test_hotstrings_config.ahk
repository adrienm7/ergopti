; static/ergopti_plus/windows/tests/unit/test_hotstrings_config.ahk

; ==============================================================================
; MODULE: Hotstrings Config Tests
; RUN:    AutoHotkey64.exe run_hotstrings_config.ahk  (not this file directly —
;         it has no test framework; run_all.ahk also includes this suite).
; DESCRIPTION:
; Covers the override-file parser, the resolution cascade
; (user.section → user.file → toml.section → toml.file → GLOBAL_DEFAULT_DELAY)
; and the set / clear override mutators implemented in
; ``infra/hotstrings_config.ahk``. The TOML metadata layer is mocked through
; the global ``HotstringGroupConfig`` map populated by
; ``ParseTomlGroupConfig`` so the tests do not depend on the bundled
; hotstring files being present at a specific location during CI.
; ==============================================================================

; The resolution fallbacks (GLOBAL_DEFAULT_DELAY / GLOBAL_DEFAULT_COLOR /
; HOTSTRINGS_CATEGORY_DEFAULT_COLORS["personal"]) are no longer hardcoded — they
; load from _shared/modules/hotstrings/defaults.toml. Populate them once here (using the
; real _shared/ dir that test_stubs.ahk points _SharedDir at) so the fallback
; assertions below see the canonical values, exactly as production does at boot.
HotstringsConfigLoadSharedDefaults()
; Likewise seed the llm_prediction tint: production sources it from
; UI_AI_LOADING_HEX (set by UiStyle_LoadSharedConst), which this headless harness
; does not run — so load that hex from the same shared file and run the loader,
; exactly as production does, so the resolve-cascade tests below see the AI tint.
UI_AI_LOADING_HEX := IniCacheGet(ParseTomlFile(_SharedDir . "\modules\tooltip\constants.toml"), "accent_colors", "ai_loading_hex")
HotstringsConfigLoadLlmPredictionColor()

; Helper — wipe / seed the in-memory state for a single test case.
;
; Pre-seeds ``HotstringGroupConfig`` with empty entries for every category
; the test suite resolves. Without this, ParseTomlGroupConfig would fall
; through to a real file lookup under ``_StaticDir`` and the bundled
; ``static/hotstrings/<category>.toml`` files would smuggle their real
; delay/color into the resolution cascade, breaking the "falls back to
; defaults" assertions. Tests that DO want to exercise toml metadata seed
; their own values via _HCfgTestSeedToml, which overwrites these entries.
_HCfgTestOverridePath() {
	return A_Temp . "\ergopti_hotstrings_config_unit_overrides.toml"
}

_HCfgTestCleanup(*) {
	try FileDelete(_HCfgTestOverridePath())
}
OnExit(_HCfgTestCleanup)

_HCfgTestReset() {
    global _HotstringsOverrides, _HotstringsOverridesPath, HotstringGroupConfig
    _HotstringsOverrides := Map()
	; Mutators publish memory only after a successful write, so unit tests use a
	; private writable target instead of treating "no path" as a fake success.
	_HotstringsOverridesPath := _HCfgTestOverridePath()
	try FileDelete(_HotstringsOverridesPath)
    HotstringGroupConfig := Map()
    ; Build a fresh empty config per category so mutations in one test do not
    ; leak into the next (each Sections map must be a distinct instance).
    for Cat in ["rolls", "sfbsreduction", "autocorrection", "distancesreduction", "magickey"] {
        HotstringGroupConfig[Cat] := { Delay: "", Color: "", ShowTooltip: "", Priority: "", Sections: Map() }
    }
    ; Resetting state directly bypasses the production setters that bump the
    ; HotstringsResolve generation, so invalidate the memo here to keep each
    ; test case isolated from the previous one's cached resolutions.
    HotstringsResolveBumpGen()
}

_HCfgTestSeedToml(Cat, Delay, Color, Sections := unset) {
    global HotstringGroupConfig
    ; ShowTooltip is part of the public Toml config schema (see toml_loader.ahk
    ; ParseTomlGroupConfig — it always materialises a ShowTooltip field, empty
    ; when the toml file does not set the value). The resolution cascade in
    ; hotstrings_config.ahk reads ``TomlCfg.ShowTooltip`` directly, so seeded
    ; test configs MUST expose that property too, otherwise AHK raises a
    ; "no property named ShowTooltip" error during HotstringsResolve.
    Cfg := { Delay: Delay, Color: Color, ShowTooltip: "", Priority: "", Sections: Map() }
    if IsSet(Sections) {
        for SecName, SecData in Sections {
            ; Same shape contract for sections — if a caller passes a section
            ; object without ShowTooltip, normalise it here so downstream
            ; resolution can rely on the property being present.
            if !SecData.HasOwnProp("ShowTooltip") {
                SecData.ShowTooltip := ""
            }
            Cfg.Sections[SecName] := SecData
        }
    }
    HotstringGroupConfig[Cat] := Cfg
    ; Seeding TOML config directly bypasses the bumped invalidation path.
    HotstringsResolveBumpGen()
}





; ============================================================
; ============================================================
; ======= 1/ Override file parser ===========================
; ============================================================
; ============================================================

TestHotstringsConfig_ParseOverridesFileLevel() {
    Path := A_Temp . "\hotstrings_config_test_filelvl.toml"
    try FileDelete(Path)
    FileAppend("[rolls]`ndelay = 0.4`ncolor = " . '"' . "#abcdef" . '"' . "`n", Path, "UTF-8")
    Result := _ParseOverrides(Path)
    AssertTrue(Result.Has("rolls"), "rolls override should be parsed")
    AssertEqual(0.4, Result["rolls"].Delay, "rolls delay parsed")
    AssertEqual("#abcdef", Result["rolls"].Color, "rolls color parsed")
    try FileDelete(Path)
}
Test("HotstringsConfig: _ParseOverrides reads file-level delay and color",
    TestHotstringsConfig_ParseOverridesFileLevel)

TestHotstringsConfig_ParseOverridesSection() {
    Path := A_Temp . "\hotstrings_config_test_sec.toml"
    try FileDelete(Path)
    FileAppend("[rolls.ct]`ndelay = 0.2`ncolor = " . '"' . "#00838f" . '"' . "`n", Path, "UTF-8")
    Result := _ParseOverrides(Path)
    AssertTrue(Result.Has("rolls"), "rolls bucket created")
    AssertTrue(Result["rolls"].Sections.Has("ct"), "rolls.ct subsection parsed")
    AssertEqual(0.2, Result["rolls"].Sections["ct"].Delay, "rolls.ct delay parsed")
    AssertEqual("#00838f", Result["rolls"].Sections["ct"].Color, "rolls.ct color parsed")
    try FileDelete(Path)
}
Test("HotstringsConfig: _ParseOverrides reads [category.section] tables",
    TestHotstringsConfig_ParseOverridesSection)

TestHotstringsConfig_ParseOverridesMissingFile() {
    Result := _ParseOverrides("Z:\\nonexistent\\path\\does_not_exist.toml")
    AssertEqual(0, Result.Count, "missing file produces empty map")
}

; Pause invariant regression for hotstrings config (project_suspend_pause_invariant)
TestHotstringsConfig_PauseGuard() {
    _HCfgTestReset()
    ; Config resolution must be safe even when script is paused; actual guard is in dispatch
    ; but config must not assume active state.
    AssertTrue(IsSet(HotstringGroupConfig), "config tables must exist under pause")
}
Test("HotstringsConfig: pause invariant skeleton (dispatch must gate on A_IsSuspended)", TestHotstringsConfig_PauseGuard)

; Delay resolution per section/group (project-hotstring-delay-architecture)
TestHotstringsConfig_SectionDelayOverridesGroup() {
    _HCfgTestReset()
    _HCfgTestSeedToml("rolls", 1.0, "", Map("ct", { Delay: 0.5, Color: "", ShowTooltip: "" }))
    ; When resolving, section delay should take precedence (simulated via seed)
    AssertEqual(0.5, HotstringGroupConfig["rolls"].Sections["ct"].Delay)
}
Test("HotstringsConfig: section delay overrides group delay", TestHotstringsConfig_SectionDelayOverridesGroup)

Test("HotstringsConfig: _ParseOverrides on missing file returns an empty map",
    TestHotstringsConfig_ParseOverridesMissingFile)





; ============================================================
; ============================================================
; ======= 2/ Resolution cascade =============================
; ============================================================
; ============================================================

TestHotstringsConfig_ResolveFallsBackToGlobal() {
    _HCfgTestReset()
    R := HotstringsResolve("rolls", "")
    AssertEqual(GLOBAL_DEFAULT_DELAY, R.Delay,
        "no toml + no override → global default delay")
    AssertEqual(GLOBAL_DEFAULT_COLOR, R.Color,
        "no toml + no override → global default color (single source of truth)")
    AssertFalse(R.HasOverride, "no override flag")
}
Test("HotstringsConfig: resolve falls back to GLOBAL_DEFAULT_DELAY",
    TestHotstringsConfig_ResolveFallsBackToGlobal)

TestHotstringsConfig_GlobalDefaultDelayTier() {
    _HCfgTestReset()
    ; Nothing set anywhere → hardcoded fallback.
    R := HotstringsResolve("rolls", "")
    AssertEqual(GLOBAL_DEFAULT_DELAY, R.Delay,
        "no toml + no override + no global → hardcoded GLOBAL_DEFAULT_DELAY")
    ; The menu-set global default (key "_global") applies for any category that
    ; has no delay of its own — below a per-category value, above the fallback.
    HotstringsSetOverride("_global", "", "delay", 2.5)
    R := HotstringsResolve("rolls", "")
    AssertEqual(2.5, R.Delay,
        "global default delay applies when the category has no delay")
    AssertFalse(R.HasOverride,
        "the global default is not a per-category override — HasOverride stays false")
    ; A per-category user override still wins over the global default.
    HotstringsSetOverride("rolls", "", "delay", 1.2)
    R := HotstringsResolve("rolls", "")
    AssertEqual(1.2, R.Delay, "per-category override wins over the global default")
}
Test("HotstringsConfig: menu-set global default delay tier (below category, above fallback)",
    TestHotstringsConfig_GlobalDefaultDelayTier)

TestHotstringsConfig_PersonalCategoryFallsBackToBaseline() {
    _HCfgTestReset()
    R := HotstringsResolve("personal", "")
    AssertEqual(HOTSTRINGS_CATEGORY_DEFAULT_COLORS["personal"], R.Color,
        "personal category falls back to its per-category default, not global blue")
}
Test("HotstringsConfig: personal category falls back to its per-category baseline",
    TestHotstringsConfig_PersonalCategoryFallsBackToBaseline)

TestHotstringsConfig_LlmPredictionVioletDefault() {
    _HCfgTestReset()
    R := HotstringsResolve("llm_prediction", "")
    AssertEqual(HOTSTRINGS_CATEGORY_DEFAULT_COLORS["llm_prediction"], R.Color,
        "llm_prediction category defaults to violet AI loading tint")
}
Test("HotstringsConfig: llm_prediction category defaults to violet AI tint",
    TestHotstringsConfig_LlmPredictionVioletDefault)

; Single-source tripwire (A4 — mutualised AHK <-> macOS resolution defaults).
; The three fallbacks now load from _shared/modules/hotstrings/defaults.toml instead of a
; per-driver literal. This pins two things at once:
;   1. The loader actually read the shared file — the live globals equal the
;      values parsed straight out of defaults.toml (not a stale hardcoded value).
;   2. The canonical values are exactly what both drivers expect. The macOS suite
;      asserts the SAME literals against the SAME file (test_hotstrings_defaults
;      .lua), so a drift on either driver — or an accidental edit to the shared
;      file — turns one of these red.
TestHotstringsConfig_SharedDefaultsAreSingleSource() {
    global _SharedDir, GLOBAL_DEFAULT_DELAY, GLOBAL_DEFAULT_COLOR, DYN_HOTSTRINGS_DEFAULT_DELAY
    global HOTSTRINGS_CATEGORY_DEFAULT_COLORS
    Path := _SharedDir . "\modules\hotstrings\defaults.toml"
    c    := ParseTomlFile(Path)
    AssertTrue(c.Count > 0, "defaults.toml is present and parses (" . Path . ")")

    ; (1) The live globals equal the file — proves HotstringsConfigLoadSharedDefaults
    ;     populated them from disk, not from a literal left behind in the module.
    ;     Colors are normalised to the with-"#" form (exactly as the loader does)
    ;     so the check is independent of whether the canon stores the leading "#".
    NormHash(v) => (SubStr(v, 1, 1) == "#") ? v : "#" . v
    AssertEqual(NormHash(IniCacheGet(c, "colors", "global_default")), GLOBAL_DEFAULT_COLOR,
        "GLOBAL_DEFAULT_COLOR is loaded from defaults.toml [colors] global_default")
    AssertEqual(NormHash(IniCacheGet(c, "colors", "personal")), HOTSTRINGS_CATEGORY_DEFAULT_COLORS["personal"],
        "personal baseline is loaded from defaults.toml [colors] personal")
    AssertEqual(Float(IniCacheGet(c, "delays", "default_sec")), GLOBAL_DEFAULT_DELAY,
        "GLOBAL_DEFAULT_DELAY is loaded from defaults.toml [delays] default_sec")
    AssertEqual(Float(IniCacheGet(c, "delays", "dynamichotstrings_sec")), DYN_HOTSTRINGS_DEFAULT_DELAY,
        "DYN_HOTSTRINGS_DEFAULT_DELAY is loaded from defaults.toml [delays] dynamichotstrings_sec")

    ; (2) Pin the canonical cross-driver values so an accidental edit is caught.
    AssertEqual("#1e88e5", GLOBAL_DEFAULT_COLOR, "canonical global default color")
    AssertEqual("#6e6e73", HOTSTRINGS_CATEGORY_DEFAULT_COLORS["personal"], "canonical personal baseline color")
    AssertEqual(0.75, GLOBAL_DEFAULT_DELAY, "canonical global default delay (seconds)")
    AssertEqual(2.0, DYN_HOTSTRINGS_DEFAULT_DELAY, "canonical dynamic-hotstrings default delay (seconds)")
}
Test("HotstringsConfig: resolution defaults come from the shared defaults.toml (single source)",
    TestHotstringsConfig_SharedDefaultsAreSingleSource)

; The llm_prediction baseline tint is the canonical AI loading hex from
; _shared/modules/tooltip/constants.toml [accent_colors] ai_loading_hex (exposed as
; UI_AI_LOADING_HEX), NOT a re-typed literal. Proves the loader copies it and
; fails fast when the shared hex is unloaded.
TestHotstringsConfig_LlmPredictionColorFromSharedAiHex() {
    global _SharedDir, UI_AI_LOADING_HEX, HOTSTRINGS_CATEGORY_DEFAULT_COLORS
    ; Pin the canonical value at its single source.
    c := ParseTomlFile(_SharedDir . "\modules\tooltip\constants.toml")
    AssertEqual("#AD61FF", IniCacheGet(c, "accent_colors", "ai_loading_hex"),
        "canonical AI loading hex in _shared/modules/tooltip/constants.toml")

    savedHex   := IsSet(UI_AI_LOADING_HEX) ? UI_AI_LOADING_HEX : ""
    savedColor := HOTSTRINGS_CATEGORY_DEFAULT_COLORS.Has("llm_prediction") ? HOTSTRINGS_CATEGORY_DEFAULT_COLORS["llm_prediction"] : ""
    try {
        ; (1) The loader copies UI_AI_LOADING_HEX into the llm_prediction baseline.
        UI_AI_LOADING_HEX := "#AD61FF"
        HotstringsConfigLoadLlmPredictionColor()
        AssertEqual(UI_AI_LOADING_HEX, HOTSTRINGS_CATEGORY_DEFAULT_COLORS["llm_prediction"],
            "llm_prediction baseline equals UI_AI_LOADING_HEX (single source)")
        AssertEqual("#AD61FF", HOTSTRINGS_CATEGORY_DEFAULT_COLORS["llm_prediction"],
            "llm_prediction resolves to the canonical AI hex")

        ; (2) Fail fast: an unloaded UI_AI_LOADING_HEX must throw, not mask.
        UI_AI_LOADING_HEX := ""
        AssertThrows(HotstringsConfigLoadLlmPredictionColor,
            "loader throws when UI_AI_LOADING_HEX is not loaded")
    } finally {
        UI_AI_LOADING_HEX := savedHex
        HOTSTRINGS_CATEGORY_DEFAULT_COLORS["llm_prediction"] := savedColor
    }
}
Test("HotstringsConfig: llm_prediction tint is sourced from the shared AI loading hex",
    TestHotstringsConfig_LlmPredictionColorFromSharedAiHex)

TestHotstringsConfig_ResolveTomlFile() {
    _HCfgTestReset()
    _HCfgTestSeedToml("rolls", 0.5, "#fb8c00")
    R := HotstringsResolve("rolls", "")
    AssertEqual(0.5, R.Delay, "toml file-level delay wins over global default")
    AssertEqual("#fb8c00", R.Color, "toml file-level color wins over global default")
    AssertFalse(R.HasOverride, "no override flag for toml-only data")
}
Test("HotstringsConfig: resolve sources file-level toml metadata",
    TestHotstringsConfig_ResolveTomlFile)

TestHotstringsConfig_ResolveTomlSectionWinsOverFile() {
    _HCfgTestReset()
    Sections := Map()
    Sections["ct"] := { Delay: 0.3, Color: "#2e7d32", Description: "" }
    _HCfgTestSeedToml("rolls", 0.5, "#fb8c00", Sections)
    R := HotstringsResolve("rolls", "ct")
    AssertEqual(0.3, R.Delay, "toml section delay wins over file delay")
    AssertEqual("#2e7d32", R.Color, "toml section color wins over file color")
}
Test("HotstringsConfig: toml section delay/color wins over toml file",
    TestHotstringsConfig_ResolveTomlSectionWinsOverFile)

TestHotstringsConfig_ResolveUserOverrideWinsOverToml() {
    _HCfgTestReset()
    _HCfgTestSeedToml("rolls", 0.5, "#fb8c00")
    HotstringsSetOverride("rolls", "", "delay", 1.2)
    HotstringsSetOverride("rolls", "", "color", "#000000")
    R := HotstringsResolve("rolls", "")
    AssertEqual(1.2, R.Delay, "user file-level delay wins over toml")
    AssertEqual("#000000", R.Color, "user file-level color wins over toml")
    AssertTrue(R.HasOverride, "override flag is true after setOverride")
}
Test("HotstringsConfig: user override wins over toml metadata",
    TestHotstringsConfig_ResolveUserOverrideWinsOverToml)

TestHotstringsConfig_ResolveSectionFolding() {
    _HCfgTestReset()
    Sections := Map()
    Sections["ie"] := { Delay: 0.7, Color: "", Description: "" }
    _HCfgTestSeedToml("sfbsreduction", 0.5, "", Sections)
    ; Caller passes the PascalCase / accented form used in features_config;
    ; HotstringsResolve must FoldAsciiLower it down to the toml key "ie".
    R := HotstringsResolve("SFBsReduction", "IÉ")
    AssertEqual(0.7, R.Delay,
        "section name is folded for matching (IÉ → ie)")
}
Test("HotstringsConfig: resolve folds accented section names to ASCII",
    TestHotstringsConfig_ResolveSectionFolding)





; ============================================================
; ============================================================
; ======= 3/ Mutators =======================================
; ============================================================
; ============================================================

TestHotstringsConfig_ClearOverrideRevertsToToml() {
    _HCfgTestReset()
    _HCfgTestSeedToml("rolls", 0.5, "#fb8c00")
    HotstringsSetOverride("rolls", "", "delay", 0.2)
    AssertEqual(0.2, HotstringsResolve("rolls", "").Delay, "override applied")
    HotstringsClearOverride("rolls", "", "delay")
    AssertEqual(0.5, HotstringsResolve("rolls", "").Delay,
        "after clear, resolution falls back to toml metadata")
}
Test("HotstringsConfig: clearOverride reverts to toml metadata",
    TestHotstringsConfig_ClearOverrideRevertsToToml)

TestHotstringsConfig_ClearOverrideAllFields() {
    _HCfgTestReset()
    HotstringsSetOverride("rolls", "ct", "delay", 0.2)
    HotstringsSetOverride("rolls", "ct", "color", "#abcdef")
    ; Empty Field clears both delay and color.
    HotstringsClearOverride("rolls", "ct", "")
    R := HotstringsResolve("rolls", "ct")
    AssertEqual(GLOBAL_DEFAULT_DELAY, R.Delay,
        "clearing all fields drops the override to the global fallback")
    AssertEqual(GLOBAL_DEFAULT_COLOR, R.Color,
        "color is cleared back to the global default (rolls has no per-category baseline)")
}
Test("HotstringsConfig: clearOverride with empty field clears delay + color",
    TestHotstringsConfig_ClearOverrideAllFields)

TestHotstringsConfig_SetOverrideRejectsUnknownField() {
    _HCfgTestReset()
    Result := HotstringsSetOverride("rolls", "", "badfield", 1.0)
    AssertFalse(Result, "setOverride returns false for unknown field")
}
Test("HotstringsConfig: setOverride rejects fields other than delay/color/show_tooltip/priority",
    TestHotstringsConfig_SetOverrideRejectsUnknownField)

; A failed disk publication must reject the candidate state in memory too. The
; config window refreshes from HotstringsResolve after a failed save; publishing
; the candidate Map before _SaveOverrides made that refresh repeat a value which
; was never durable. A real deny-sharing lock reproduces the same Windows failure
; caused by sync, backup, and antivirus processes without mocking the writer.
TestHotstringsConfig_OverrideMutationRollsBackOnWriteFailure() {
	global _HotstringsOverrides, _HotstringsOverridesPath
	SavedPath := _HotstringsOverridesPath
	SavedOverrides := _HotstringsOverrides
	Path := A_Temp . "\hotstrings_config_override_rollback.toml"
	OriginalText := "[rolls]`ndelay = 0.400`n"
	Lock := 0
	try {
		try FileDelete(Path)
		FileAppend(OriginalText, Path, "UTF-8")
		_HotstringsOverridesPath := Path
		_HotstringsOverrides := _ParseOverrides(Path)
		HotstringsResolveBumpGen()

		Lock := FileOpen(Path, "r-rwd")
		Assert(Lock != "" and IsObject(Lock),
			"the rollback test must hold a real deny-sharing lock or it proves no failure path")

		SetResult := HotstringsSetOverride("rolls", "", "delay", 0.9)
		SetMemoryAfter := _HotstringsOverrides["rolls"].Delay
		SetResolvedAfter := HotstringsResolve("rolls", "").Delay

		ClearResult := HotstringsClearOverride("rolls", "", "delay")
		ClearMemoryAfter := _HotstringsOverrides["rolls"].Delay
		ClearResolvedAfter := HotstringsResolve("rolls", "").Delay

		Lock.Close()
		Lock := 0
		DiskAfter := FileRead(Path, "UTF-8")

		AssertFalse(SetResult,
			"setOverride must report that the locked override file rejected publication")
		AssertEqual(0.4, SetMemoryAfter,
			"a rejected set must leave the live override Map at the last durable value")
		AssertEqual(0.4, SetResolvedAfter,
			"resolution after a rejected set must describe durable state, not the candidate")
		AssertFalse(ClearResult,
			"clearOverride must report that the locked override file rejected publication")
		AssertEqual(0.4, ClearMemoryAfter,
			"a rejected clear must restore the live override Map instead of erasing the field")
		AssertEqual(0.4, ClearResolvedAfter,
			"resolution after a rejected clear must still describe the durable override")
		AssertEqual(OriginalText, DiskAfter,
			"a failed override transaction must leave the previous file byte-for-byte intact")
	} finally {
		if IsObject(Lock)
			try Lock.Close()
		_HotstringsOverridesPath := SavedPath
		_HotstringsOverrides := SavedOverrides
		HotstringsResolveBumpGen()
		try FileDelete(Path)
	}
}
Test("HotstringsConfig: set/clear rollback when publication fails (hotstrings-override-rollback-on-write-failure)",
	TestHotstringsConfig_OverrideMutationRollsBackOnWriteFailure)

; The rollback guarantee also depends on never truncating the durable target
; before its complete replacement is ready. This source guard is move-resilient:
; _DriverFuncBody locates the function across the production tree.
TestHotstringsConfig_SaveOverridesPublishesAtomically() {
	Body := _DriverFuncBody("_SaveOverrides")
	Assert(Body != "", "_SaveOverrides must exist for the atomic-publication guard")
	Assert(InStr(Body, "FSAtomicMoveReplace(") > 0,
		"_SaveOverrides must publish a same-directory stage through the atomic filesystem adapter")
	Assert(InStr(Body, 'FileOpen(_HotstringsOverridesPath, "w"') == 0,
		"_SaveOverrides must never truncate the live override file before publication succeeds")
}
Test("HotstringsConfig: override file publication is atomic (hotstrings-override-rollback-on-write-failure)",
	TestHotstringsConfig_SaveOverridesPublishesAtomically)


TestHotstringsConfig_SaveOverridesRequiresDurableExactStage() {
	Body := _DriverFuncBody("_SaveOverrides")
	DurablePos := InStr(Body, "FSWriteDurable(StagePath, Out)")
	ExactPos := InStr(Body, "FSUtf8ExactMatches(StagePath, Out)")
	ReplacePos := InStr(Body, "FSAtomicMoveReplace(StagePath, Path)")
	Assert(DurablePos > 0,
		"the default override writer must count bytes and flush its stage to stable storage")
	Assert(ExactPos > DurablePos,
		"the durable stage must be read back byte-exactly before publication")
	Assert(ReplacePos > ExactPos,
		"atomic replacement and live publication must remain downstream of exact stage validation")
}
Test("HotstringsConfig: durable exact stage validation gates override publish (AHK-078)",
	TestHotstringsConfig_SaveOverridesRequiresDurableExactStage)

global _HCfgLeaseOuterWriterCalls := 0
global _HCfgLeaseInnerWriterCalls := 0
global _HCfgLeaseInnerResult := unset
global _HCfgLeaseReloadResult := unset
global _HCfgLeaseReloadPreservedIdentity := false

_HCfgLeaseInnerWriter(StagePath, Content) {
	global _HCfgLeaseInnerWriterCalls
	_HCfgLeaseInnerWriterCalls += 1
	return FSWrite(StagePath, Content)
}

_HCfgLeaseOuterWriter(StagePath, Content) {
	global _HotstringsOverrides
	global _HCfgLeaseOuterWriterCalls, _HCfgLeaseInnerResult
	global _HCfgLeaseReloadResult, _HCfgLeaseReloadPreservedIdentity
	_HCfgLeaseOuterWriterCalls += 1
	; Re-enter while the outer transaction is between its snapshot and publish.
	_HCfgLeaseInnerResult := HotstringsSetOverride("rolls", "", "color", "#222222",
		_HCfgLeaseInnerWriter)
	BeforeReload := _HotstringsOverrides
	_HCfgLeaseReloadResult := HotstringsConfigReload()
	_HCfgLeaseReloadPreservedIdentity := BeforeReload == _HotstringsOverrides
	return FSWrite(StagePath, Content)
}

; AHK can interrupt a transaction inside its writer. Without path ownership,
; the nested setter publishes successfully from the old live Map, then the outer
; setter resumes and overwrites both disk and memory with its stale candidate.
TestHotstringsConfig_ReentrantWriterCannotLoseAcceptedUpdate() {
	global _HotstringsOverrides, _HotstringsOverridesPath
	global _HCfgLeaseOuterWriterCalls, _HCfgLeaseInnerWriterCalls
	global _HCfgLeaseInnerResult, _HCfgLeaseReloadResult
	global _HCfgLeaseReloadPreservedIdentity
	SavedPath := _HotstringsOverridesPath
	SavedOverrides := _HotstringsOverrides
	Path := A_Temp . "\hotstrings_config_reentrant_lease.toml"
	try {
		try FileDelete(Path)
		FileAppend('[rolls]`ndelay = 0.400`ncolor = "#111111"`n', Path, "UTF-8")
		_HotstringsOverridesPath := Path
		_HotstringsOverrides := _ParseOverrides(Path)
		HotstringsResolveBumpGen()
		_HCfgLeaseOuterWriterCalls := 0
		_HCfgLeaseInnerWriterCalls := 0
		_HCfgLeaseInnerResult := unset
		_HCfgLeaseReloadResult := unset
		_HCfgLeaseReloadPreservedIdentity := false

		OuterResult := HotstringsSetOverride("rolls", "", "delay", 0.9,
			_HCfgLeaseOuterWriter)
		DiskAfter := _ParseOverrides(Path)

		AssertTrue(OuterResult, "the owning outer transaction must still publish")
		AssertFalse(_HCfgLeaseInnerResult,
			"a re-entrant setter on the owned path must be refused instead of reporting a lost success")
		AssertEqual(1, _HCfgLeaseOuterWriterCalls,
			"the owning writer must execute exactly once")
		AssertEqual(0, _HCfgLeaseInnerWriterCalls,
			"the refused nested transaction must stop before its writer or any disk publication")
		AssertFalse(_HCfgLeaseReloadResult,
			"a re-entrant reload on the owned path must be refused before parsing or swapping live state")
		AssertTrue(_HCfgLeaseReloadPreservedIdentity,
			"the refused reload must not replace the live override Map")
		AssertEqual(0.9, _HotstringsOverrides["rolls"].Delay,
			"the live Map must publish the outer candidate after its durable commit")
		AssertEqual("#111111", _HotstringsOverrides["rolls"].Color,
			"the refused nested candidate must never enter the live Map")
		AssertEqual(0.9, DiskAfter["rolls"].Delay,
			"the durable file must match the accepted outer transaction")
		AssertEqual("#111111", DiskAfter["rolls"].Color,
			"the refused nested candidate must never reach disk")

		Probe := _ConfigWriteLeaseTryAcquire(Path, "hotstrings-test-probe")
		Assert(Probe is Object,
			"the outer transaction must release path ownership after its live swap")
		if (Probe is Object)
			AssertTrue(_ConfigWriteLeaseRelease(Probe),
				"the test probe must release the shared path lease")
	} finally {
		_HotstringsOverridesPath := SavedPath
		_HotstringsOverrides := SavedOverrides
		HotstringsResolveBumpGen()
		try FileDelete(Path)
	}
}
Test("HotstringsConfig: re-entrant writer cannot lose an accepted update (hotstrings-override-lease-reentrant-writer)",
	TestHotstringsConfig_ReentrantWriterCannotLoseAcceptedUpdate)

; Regression (fixed 2026-06-04): the dynamic-hotstrings default activation delay
; must be defined in this EARLY-loaded config layer, not in modules/hotstrings.ahk.
; The tray "Delays" submenu reads DYN_HOTSTRINGS_DEFAULT_DELAY while building the
; menu at startup (initMenu) — before the feature module's top-level code runs —
; so a definition in the late module left it unassigned and crashed menu
; construction ("This global variable has not been assigned a value").
; This suite loads hotstrings_config.ahk but NOT modules/hotstrings.ahk, so if the
; constant ever drifts back into the module it is undefined here and this fails.
TestHotstringsConfig_DynDefaultDelayDefinedEarly() {
    global DYN_HOTSTRINGS_DEFAULT_DELAY
    AssertTrue(IsSet(DYN_HOTSTRINGS_DEFAULT_DELAY),
        "DYN_HOTSTRINGS_DEFAULT_DELAY must be defined in the early-loaded config layer (the tray menu reads it at initMenu, before modules/hotstrings.ahk runs)")
    if IsSet(DYN_HOTSTRINGS_DEFAULT_DELAY) {
        AssertEqual(2.0, DYN_HOTSTRINGS_DEFAULT_DELAY,
            "dynamic hotstrings default activation delay is 2.0s (mirrors macOS DELAYS_DEFAULT.dynamichotstrings)")
    }
}
Test("HotstringsConfig: DYN_HOTSTRINGS_DEFAULT_DELAY is defined in the early config layer (initMenu-safe)",
    TestHotstringsConfig_DynDefaultDelayDefinedEarly)

; ULTIMATE encore plus: deepen pause + section delay precedence regression + volume/bad config.
; These would have caught the early-load crash for DYN_* and silent activation of hotstrings under pause.
; project_suspend_pause_invariant + project-hotstring-delay-architecture (section > group > default).

; The claim is that resolution is PURE: it reads config tables and returns a
; result, without consulting suspend state. That has to be asserted, not stated
; — if the cascade ever grew an `if A_IsSuspended` branch it would return a
; different delay after a pause than before one, and the tooltip and the engine
; would disagree about the same hotstring.
TestHotstringsConfig_PauseMustGateAllResolution() {
	_HCfgTestReset()
	_HCfgTestSeedToml("rolls", 0.5, "#fb8c00", Map("ct", { Delay: 0.3, Color: "#2e7d32", ShowTooltip: "" }))

	; Resolution reads no suspend flag anywhere in its cascade.
	Body := _DriverFuncBody("_HotstringsResolveUncached")
	Assert(InStr(Body, "A_IsSuspended") == 0,
		"the resolution cascade must not branch on A_IsSuspended — a paused driver would "
		. "resolve a different delay than a running one for the same hotstring")

	; And it is deterministic: the same query twice yields the same values, so a
	; caller that resolves before a pause and acts after it sees one answer.
	A := HotstringsResolve("rolls", "ct")
	B := HotstringsResolve("rolls", "ct")
	AssertEqual(A.Delay, B.Delay, "resolution must be deterministic across calls")
	AssertEqual(A.Color, B.Color, "resolution must be deterministic across calls")
	AssertEqual(0.3, A.Delay, "and it must still return the seeded section delay")
}
Test("HotstringsConfig: pause must not break config resolution (dispatchers gate expansions)", TestHotstringsConfig_PauseMustGateAllResolution)

; Section > file > global default. Each rung is asserted by resolving a query
; that can only produce that rung's value, so a re-ordered cascade fails on the
; specific level that broke rather than on a message that says it should not.
TestHotstringsConfig_SectionDelayPrecedenceRegression() {
	global DYN_HOTSTRINGS_DEFAULT_DELAY, GLOBAL_DEFAULT_DELAY
	AssertTrue(IsSet(DYN_HOTSTRINGS_DEFAULT_DELAY), "default must exist")

	; Rung 1 — a section delay beats the file delay of the same category.
	_HCfgTestReset()
	_HCfgTestSeedToml("rolls", 0.5, "", Map("ct", { Delay: 0.3, Color: "", ShowTooltip: "" }))
	AssertEqual(0.3, HotstringsResolve("rolls", "ct").Delay,
		"section delay must win over the file delay")

	; Rung 2 — with no section match, the file delay wins.
	AssertEqual(0.5, HotstringsResolve("rolls", "no_such_section").Delay,
		"with no matching section the file delay must win")

	; Rung 3 — with neither, the global default is the floor.
	_HCfgTestReset()
	AssertEqual(GLOBAL_DEFAULT_DELAY, HotstringsResolve("rolls", "").Delay,
		"with no section and no file delay the global default must be the floor")
}
Test("HotstringsConfig: section>group>default delay precedence regression (project-hotstring-delay-architecture)", TestHotstringsConfig_SectionDelayPrecedenceRegression)

; Malformed section data must degrade to the file/global value, not throw and
; not invent one. Volume matters because the cascade is memoised per
; (category, section): a throw on entry 137 would poison the cache for every
; later query, so the assertion is that all 200 resolve AND that they resolve to
; the right fallback.
TestHotstringsConfig_HighVolumeBadTomlUnderPause() {
	_HCfgTestReset()
	Bad := Map()
	Loop 200 {
		; Delay left empty (the malformed shape the TOML parser emits for an
		; unparseable value) — resolution must fall through to the file delay.
		Bad["sec" . A_Index] := { Delay: "", Color: "", ShowTooltip: "" }
	}
	_HCfgTestSeedToml("rolls", 0.5, "#fb8c00", Bad)

	Loop 200 {
		R := HotstringsResolve("rolls", "sec" . A_Index)
		AssertEqual(0.5, R.Delay,
			"malformed section " . A_Index . " must fall through to the file delay, not throw or invent one")
	}
	AssertEqual("#fb8c00", HotstringsResolve("rolls", "sec1").Color,
		"and the colour must fall through the same way")
}
Test("HotstringsConfig: high volume bad TOML/overrides under pause must not crash or activate (resilience)", TestHotstringsConfig_HighVolumeBadTomlUnderPause)


; HotstringsResolve memoisation: the result is cached per (category, section)
; and only recomputed when HotstringsResolveBumpGen is called. This pins both
; halves of the contract — the cache is genuinely active (a stale in-place
; mutation is NOT seen until invalidation) and a generation bump invalidates it.
TestHSResolve_MemoAndInvalidation() {
	global _HotstringsOverrides
	SavedOverrides := _HotstringsOverrides
	_HotstringsOverrides := Map()
	_HotstringsOverrides["memotestcat"] := { Delay: 7, Color: "", ShowTooltip: "", Sections: Map() }
	HotstringsResolveBumpGen()
	First := HotstringsResolve("memotestcat")
	AssertEqual(7, First.Delay, "baseline resolve must read the seeded delay")
	; Mutate the override in place WITHOUT bumping — a live memo must still
	; return the cached 7, proving the cache is actually in effect.
	_HotstringsOverrides["memotestcat"].Delay := 99
	Stale := HotstringsResolve("memotestcat")
	AssertEqual(7, Stale.Delay, "memoised resolve must return the cached value until invalidated")
	; Bump the generation — the next resolve must recompute and see 99.
	HotstringsResolveBumpGen()
	Fresh := HotstringsResolve("memotestcat")
	AssertEqual(99, Fresh.Delay, "a generation bump must invalidate the memo")
	_HotstringsOverrides := SavedOverrides
	HotstringsResolveBumpGen()
}
Test("HotstringsResolve: result is memoised and invalidated by generation bump", TestHSResolve_MemoAndInvalidation)

; Priority resolution mirrors delay/color: the override cascade (section >
; category) sits above the source-default fallback (personal 50 > package 30 >
; common 10). _HSE_SourcePriority is the pure source-default mapping.
TestHSE_SourcePriorityHelper() {
	AssertEqual(50, _HSE_SourcePriority("personal"), "personal source default")
	AssertEqual(50, _HSE_SourcePriority("PERSONAL"), "source default is case-insensitive")
	AssertEqual(30, _HSE_SourcePriority("ext.demo"), "extension package source default")
	AssertEqual(10, _HSE_SourcePriority("autocorrection"), "bundled common source default")
}
Test("_HSE_SourcePriority maps personal=50, package=30, common=10",
	TestHSE_SourcePriorityHelper)

TestHSResolve_PriorityCascade() {
	global _HotstringsOverrides
	SavedOverrides := _HotstringsOverrides
	_HotstringsOverrides := Map()

	; No override at all → the source default (this is a common category).
	HotstringsResolveBumpGen()
	AssertEqual(10, HotstringsResolve("priotestcat", "sec").Priority,
		"no override resolves to the common source default")

	; Category-level override beats the source default.
	_HotstringsOverrides["priotestcat"] := { Delay: "", Color: "", ShowTooltip: "", Priority: 70, Sections: Map() }
	HotstringsResolveBumpGen()
	AssertEqual(70, HotstringsResolve("priotestcat", "sec").Priority,
		"category override beats the source default")

	; Section-level override beats the category override.
	_HotstringsOverrides["priotestcat"].Sections["sec"] := { Delay: "", Color: "", ShowTooltip: "", Priority: 90 }
	HotstringsResolveBumpGen()
	AssertEqual(90, HotstringsResolve("priotestcat", "sec").Priority,
		"section override beats the category override")

	_HotstringsOverrides := SavedOverrides
	HotstringsResolveBumpGen()
}
Test("HotstringsResolve: priority cascades section > category > source default",
	TestHSResolve_PriorityCascade)

; The delays/colors window edits priority through HotstringsSetOverride, so the
; field must be accepted (it used to be rejected), persist as a BARE INTEGER, and
; round-trip through _SaveOverrides -> _ParseOverrides at both file and section level.
TestHotstringsConfig_PrioritySetClearRoundTrip() {
	global _HotstringsOverrides, _HotstringsOverridesPath
	SavedPath := _HotstringsOverridesPath
	SavedOv   := _HotstringsOverrides
	Path := A_Temp . "\hotstrings_config_prio_rt.toml"
	try FileDelete(Path)
	_HotstringsOverrides     := Map()
	_HotstringsOverridesPath := Path   ; enable persistence so the save path is exercised

	AssertTrue(HotstringsSetOverride("rolls", "", "priority", 25) != false,
		"setOverride must accept the priority field at file level")
	AssertTrue(HotstringsSetOverride("rolls", "ct", "priority", 80) != false,
		"setOverride must accept the priority field at section level")

	Reparsed := _ParseOverrides(Path)
	AssertEqual(25, Reparsed["rolls"].Priority, "file-level priority round-trips through save/parse")
	AssertEqual(80, Reparsed["rolls"].Sections["ct"].Priority, "section priority round-trips through save/parse")

	; Clearing the field drops it from the persisted file.
	HotstringsClearOverride("rolls", "", "priority")
	After := _ParseOverrides(Path)
	AssertEqual("", After.Has("rolls") ? After["rolls"].Priority : "",
		"clearOverride removes the file-level priority key")

	try FileDelete(Path)
	_HotstringsOverridesPath := SavedPath
	_HotstringsOverrides     := SavedOv
	HotstringsResolveBumpGen()
}
Test("HotstringsConfig: priority set/clear round-trips through the override file",
	TestHotstringsConfig_PrioritySetClearRoundTrip)

; clearOverride with an empty field must wipe EVERY override field, priority
; included — otherwise a stale priority survives a "reset all" from the window.
TestHotstringsConfig_ClearAllFieldsClearsPriority() {
	global _HotstringsOverrides, _HotstringsOverridesPath
	SavedOv := _HotstringsOverrides
	SavedPath := _HotstringsOverridesPath
	Path := A_Temp . "\hotstrings_config_clear_all_priority.toml"
	try FileDelete(Path)
	_HotstringsOverrides     := Map()
	_HotstringsOverridesPath := Path
	try {
		HotstringsSetOverride("rolls", "ct", "delay", 0.2)
		HotstringsSetOverride("rolls", "ct", "priority", 77)
		HotstringsClearOverride("rolls", "ct", "")
		AssertEqual("", _HotstringsOverrides["rolls"].Sections["ct"].Priority,
			"empty-field clearOverride must also clear priority")
	} finally {
		_HotstringsOverrides := SavedOv
		_HotstringsOverridesPath := SavedPath
		HotstringsResolveBumpGen()
		try FileDelete(Path)
	}
}
Test("HotstringsConfig: clearOverride empty field also clears priority",
	TestHotstringsConfig_ClearAllFieldsClearsPriority)

; HotstringsResolveExt must expose Priority too — extensions edited from the
; window default to the package tier (30), and a user override beats it.
TestHotstringsConfig_ResolveExtPriority() {
	global _HotstringsOverrides
	Saved := _HotstringsOverrides
	_HotstringsOverrides := Map()
	HotstringsResolveBumpGen()
	ExtPath := A_Temp . "\hotstrings_ext_prio.toml"
	try FileDelete(ExtPath)
	FileAppend("[_meta]`ndelay = 0.5`n", ExtPath, "UTF-8")   ; ships no priority

	R := HotstringsResolveExt("demo", ExtPath, "")
	AssertEqual(30, R.Priority,
		"extension with no override resolves to the package source default (30)")

	HotstringsSetOverride("ext.demo", "", "priority", 88)
	R2 := HotstringsResolveExt("demo", ExtPath, "")
	AssertEqual(88, R2.Priority,
		"a user override beats the extension package source default")

	try FileDelete(ExtPath)
	_HotstringsOverrides := Saved
	HotstringsResolveBumpGen()
}
Test("HotstringsResolveExt: exposes priority with the package source default + override",
	TestHotstringsConfig_ResolveExtPriority)


; ==============================================================================
; ======= Word-delimiter live-propagation regression ===========================
; ==============================================================================

; Regression guard for word-delimiters-not-applied-live: HotstringsSetWordDelimiters
; was updating the config cache and the disk file but NOT the live engine variable
; HSE_WORD_TERMINATORS — so the engine kept firing on the old set until a full Reload.
; The fix publishes HSE_WORD_TERMINATORS in place after durable replacement.
TestHotstringsConfig_SetWordDelimitersUpdatesEngineVarLive() {
	global _HotstringsOverridesPath, _HotstringsOverrides
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	SavedPath := _HotstringsOverridesPath
	SavedOverrides := _HotstringsOverrides
	SavedCache  := _HotstringsWordDelimiters
	SavedEngine := HSE_WORD_TERMINATORS
	SavedConsumedCache := _HotstringsConsumedDelimiters
	SavedConsumedEngine := HSE_CONSUMED_DELIMITERS
	Path := A_Temp . "\ergopti_set_word_live_" . A_ScriptHwnd
		. "_" . A_TickCount . ".toml"
	try {
		try FileDelete(Path)
		_HotstringsOverridesPath := Path
		_HotstringsOverrides := Map()
		_HotstringsWordDelimiters := ""
		_HotstringsConsumedDelimiters := ""
		Committed := HotstringsSetWordDelimiters("AB")
		EngineAfter := HSE_WORD_TERMINATORS
		AssertTrue(Committed,
			"the fixture must complete the durable transaction before asserting its live projection")
	} finally {
		try FileDelete(Path)
		_HotstringsOverridesPath := SavedPath
		_HotstringsOverrides := SavedOverrides
		_HotstringsWordDelimiters := SavedCache
		HSE_WORD_TERMINATORS := SavedEngine
		_HotstringsConsumedDelimiters := SavedConsumedCache
		HSE_CONSUMED_DELIMITERS := SavedConsumedEngine
	}
	AssertEqual("AB", EngineAfter,
		"HotstringsSetWordDelimiters must propagate to HSE_WORD_TERMINATORS immediately (no Reload needed)")
}
Test("HotstringsConfig: SetWordDelimiters propagates to HSE_WORD_TERMINATORS live",
	TestHotstringsConfig_SetWordDelimitersUpdatesEngineVarLive)

TestHotstringsConfig_SetWordDelimitersGetRoundTrip() {
	global _HotstringsOverridesPath, _HotstringsOverrides
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters
	global HSE_WORD_TERMINATORS, HSE_CONSUMED_DELIMITERS
	SavedPath := _HotstringsOverridesPath
	SavedOverrides := _HotstringsOverrides
	SavedCache  := _HotstringsWordDelimiters
	SavedEngine := HSE_WORD_TERMINATORS
	SavedConsumedCache := _HotstringsConsumedDelimiters
	SavedConsumedEngine := HSE_CONSUMED_DELIMITERS
	Path := A_Temp . "\ergopti_set_word_roundtrip_" . A_ScriptHwnd
		. "_" . A_TickCount . ".toml"
	try {
		try FileDelete(Path)
		_HotstringsOverridesPath := Path
		_HotstringsOverrides := Map()
		_HotstringsWordDelimiters := ""
		_HotstringsConsumedDelimiters := ""
		Committed := HotstringsSetWordDelimiters("XY")
		Got := HotstringsGetWordDelimiters()
		AssertTrue(Committed,
			"the fixture must complete the durable transaction before asserting its getter")
	} finally {
		try FileDelete(Path)
		_HotstringsOverridesPath := SavedPath
		_HotstringsOverrides := SavedOverrides
		_HotstringsWordDelimiters := SavedCache
		HSE_WORD_TERMINATORS := SavedEngine
		_HotstringsConsumedDelimiters := SavedConsumedCache
		HSE_CONSUMED_DELIMITERS := SavedConsumedEngine
	}
	AssertEqual("XY", Got,
		"HotstringsGetWordDelimiters must return the value just set by HotstringsSetWordDelimiters")
}
Test("HotstringsConfig: SetWordDelimiters / GetWordDelimiters round-trip",
	TestHotstringsConfig_SetWordDelimitersGetRoundTrip)


; ==============================================================================
; ======= F06 — _SaveOverrides must preserve [__global__] delimiters ===========
; ==============================================================================

; Regression guard (F06 — 2026-06-18): _SaveOverrides rebuilt the file from the
; _HotstringsOverrides Map only, never touching _HotstringsWordDelimiters /
; _HotstringsConsumedDelimiters. Any category or section edit therefore silently
; erased the [__global__] block — user-configured terminators vanished on disk.
; The fix re-emits [__global__] at the top of every full-file rebuild.
TestHotstringsConfig_SaveOverridesPreservesGlobalDelimiters() {
	global _HotstringsOverrides, _HotstringsOverridesPath
	global _HotstringsWordDelimiters, _HotstringsConsumedDelimiters

	SavedPath     := _HotstringsOverridesPath
	SavedOv       := _HotstringsOverrides
	SavedWordDel  := _HotstringsWordDelimiters
	SavedConsumed := _HotstringsConsumedDelimiters

	Path := A_Temp . "\hotstrings_config_f06_global.toml"
	try FileDelete(Path)

	; Wire up a real file so _SaveOverrides actually writes to disk
	_HotstringsOverrides     := Map()
	_HotstringsOverridesPath := Path

	; 1. Seed custom delimiter candidates in the live fixture.
	_HotstringsWordDelimiters   := "AB"
	_HotstringsConsumedDelimiters := "A"

	; 2. Trigger _SaveOverrides via a category edit (full-file rebuild)
	HotstringsSetOverride("rolls", "", "delay", 1.2)

	; 3. Read the delimiter back from disk directly — _SaveOverrides must have
	;    re-emitted [__global__] during the rebuild, not clobbered it
	WordDelOnDisk     := _ParseGlobalKey(Path, "word_delimiters")
	ConsumedDelOnDisk := _ParseGlobalKey(Path, "consumed_delimiters")

	try FileDelete(Path)
	_HotstringsOverridesPath      := SavedPath
	_HotstringsOverrides          := SavedOv
	_HotstringsWordDelimiters     := SavedWordDel
	_HotstringsConsumedDelimiters := SavedConsumed
	HotstringsResolveBumpGen()

	; 4. Assert the custom delimiters survived the rebuild
	AssertEqual("AB", WordDelOnDisk,
		"[__global__] word_delimiters must survive a subsequent _SaveOverrides")
	AssertEqual("A", ConsumedDelOnDisk,
		"[__global__] consumed_delimiters must survive a subsequent _SaveOverrides")
}
Test("hotstrings_config: _SaveOverrides preserves [__global__] delimiters", TestHotstringsConfig_SaveOverridesPreservesGlobalDelimiters)

; F37 (audit 2026-07-20): a delimiter containing a quote or backslash once
; produced malformed TOML and silently reverted at the next read. Both global
; keys now share one whole-file serializer, including detached candidates.
TestHotstringsConfig_SaveOverridesEscapesGlobalDelimiters() {
	Body := _DriverFuncBody("_SaveOverrides")
	Assert(Body != "", "_SaveOverrides must exist in infra/hotstrings/hotstrings_io.ahk")
	Assert(InStr(Body, "_EscapeTomlString(WordSource)") > 0,
		"_SaveOverrides must escape the detached word-delimiter candidate")
	Assert(InStr(Body, "_EscapeTomlString(ConsumedSource)") > 0,
		"_SaveOverrides must escape the detached consumed-delimiter candidate")
}
Test("hotstrings_config: _SaveOverrides escapes detached [__global__] delimiter candidates",
	TestHotstringsConfig_SaveOverridesEscapesGlobalDelimiters)
