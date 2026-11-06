; static/ergopti_plus/windows/tests/unit/modules/hotstrings/catalogue/test_hotstrings_config.ahk

; ==============================================================================
; MODULE: Hotstrings Config Tests
; RUN:    AutoHotkey64.exe run_all.ahk --only "HotstringsConfig:" (not this
;         file directly — it has no test framework of its own).
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
global _HCfgTestFixtureRoot := ""

; Registration owns no disk state. Acquire this process/window namespace only
; when a callback needs it, and never adopt a pre-existing directory.
_HCfgTestOverridePath() {
	global _HCfgTestFixtureRoot
	if _HCfgTestFixtureRoot == "" {
		Candidate := A_Temp . "\ergopti_hotstrings_config_unit_"
			. DllCall("GetCurrentProcessId", "UInt") . "_" . A_ScriptHwnd
		FSCreateDirectoryExclusiveStrict(Candidate)
		_HCfgTestFixtureRoot := Candidate
	}
	return _HCfgTestFixtureRoot . "\overrides.toml"
}

; Exit without an acquired fixture is inert. A failed deletion retains the
; exact owner for retry instead of converting cleanup refusal to success.
_HCfgTestCleanup(*) {
	global _HCfgTestFixtureRoot
	if _HCfgTestFixtureRoot == ""
		return
	DirDelete(_HCfgTestFixtureRoot, true)
	_HCfgTestFixtureRoot := ""
}
OnExit(_HCfgTestCleanup)

_HCfgTestReset() {
    global _HotstringsOverrides, _HotstringsOverridesPath, HotstringGroupConfig
	; Mutators publish memory only after a successful write, so unit tests use a
	; private writable target instead of treating "no path" as a fake success.
	_HotstringsOverridesPath := _HCfgTestOverridePath()
	try FileDelete(_HotstringsOverridesPath)
	_HotstringsOverrides := _ParseOverrides(_HotstringsOverridesPath)
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

; The file stores a delay as an offset of the base expansion delay. The parser
; keeps it pending (the base is unknown at boot); applying the base derives the
; effective delay.
TestHotstringsConfig_ParseOverridesFileLevel() {
    Path := A_Temp . "\hotstrings_config_test_filelvl.toml"
    try FileDelete(Path)
    FileAppend("[rolls]`ndelay_offset = -0.35`ncolor = " . '"' . "#abcdef" . '"' . "`n", Path, "UTF-8")
    Result := _ParseOverrides(Path)
    AssertTrue(Result.Has("rolls"), "rolls override should be parsed")
    AssertEqual("", Result["rolls"].Delay, "no effective delay before the base is applied")
    AssertEqual(-0.35, Result["rolls"].PendingOffset, "rolls delay offset parsed")
    AssertEqual("#abcdef", Result["rolls"].Color, "rolls color parsed")
    HotstringsOverridesApplyBase(Result)
    AssertEqual(0.4, Result["rolls"].Delay, "the offset is added to the base expansion delay")
    AssertEqual("", Result["rolls"].PendingOffset, "an applied offset is no longer pending")
    try FileDelete(Path)
}
Test("HotstringsConfig: _ParseOverrides reads a file-level delay offset and color",
    TestHotstringsConfig_ParseOverridesFileLevel)

TestHotstringsConfig_ParseOverridesSection() {
    Path := A_Temp . "\hotstrings_config_test_sec.toml"
    try FileDelete(Path)
    FileAppend("[rolls.ct]`ndelay_offset = -0.55`ncolor = " . '"' . "#00838f" . '"' . "`n", Path, "UTF-8")
    Result := _ParseOverrides(Path)
    AssertTrue(Result.Has("rolls"), "rolls bucket created")
    AssertTrue(Result["rolls"].Sections.Has("ct"), "rolls.ct subsection parsed")
    AssertEqual(-0.55, Result["rolls"].Sections["ct"].PendingOffset, "rolls.ct delay offset parsed")
    AssertEqual("#00838f", Result["rolls"].Sections["ct"].Color, "rolls.ct color parsed")
    HotstringsOverridesApplyBase(Result)
    AssertEqual(0.2, Result["rolls"].Sections["ct"].Delay, "the section offset is added to the base")
    try FileDelete(Path)
}
Test("HotstringsConfig: _ParseOverrides reads [category.section] tables",
    TestHotstringsConfig_ParseOverridesSection)

; An unlimited delay (0) is not an offset of anything, so it keeps its own flag
; and survives any base. The absolute spelling of earlier builds is only kept
; for the boot migration.
TestHotstringsConfig_ParseOverridesUnlimitedAndLegacy() {
    Path := A_Temp . "\hotstrings_config_test_unlimited.toml"
    try FileDelete(Path)
    FileAppend("[rolls]`ndelay_unlimited = true`n[magickey]`ndelay = 0.6`n", Path, "UTF-8")
    Result := _ParseOverrides(Path)
    AssertEqual(0, Result["rolls"].Delay, "delay_unlimited is the effective delay 0")
    AssertEqual("", Result["rolls"].PendingOffset, "an unlimited delay has no offset")
    AssertEqual("", Result["magickey"].Delay, "a legacy absolute delay is not applied as such")
    AssertEqual(0.6, Result["magickey"].LegacyDelay, "a legacy absolute delay waits for the boot migration")
    HotstringsOverridesApplyBase(Result)
    AssertEqual(0, Result["rolls"].Delay, "the base never changes an unlimited delay")
    try FileDelete(Path)
}
Test("HotstringsConfig: _ParseOverrides keeps unlimited and legacy delays apart",
    TestHotstringsConfig_ParseOverridesUnlimitedAndLegacy)

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

; Runs Body with hotstrings.expansion_delay set to Seconds in the headless Features
; map, then restores it.
_HCfgWithBase(Seconds, Body) {
    global Features
    Hotstrings := Features["hotstrings"]
    Had := Hotstrings.Has("expansion_delay")
    Saved := Had ? Hotstrings["expansion_delay"] : unset
    Hotstrings["expansion_delay"] := Seconds
    ; HotstringsResolve memoises per generation: the resolution made before the
    ; base moved would otherwise be served again.
    HotstringsResolveBumpGen()
    try Body.Call()
    finally {
        if Had
            Hotstrings["expansion_delay"] := Saved
        else
            Hotstrings.Delete("expansion_delay")
        HotstringsResolveBumpGen()
    }
}

TestHotstringsConfig_BaseDelayTier() {
    _HCfgTestReset()
    ; Nothing set anywhere -> the shared default.
    R := HotstringsResolve("rolls", "")
    AssertEqual(GLOBAL_DEFAULT_DELAY, R.Delay,
        "no toml + no override + no user base -> the shared default delay")
    ; The user's base (hotstrings.expansion_delay) applies to any category that has
    ; no delay of its own: below a per-category value, above the shared default.
    _HCfgWithBase(2.5, () => _HCfgBaseDelayTierBody())
}
_HCfgBaseDelayTierBody() {
    R := HotstringsResolve("rolls", "")
    AssertEqual(2.5, R.Delay, "the base delay applies when the category has no delay")
    AssertFalse(R.HasOverride,
        "the base is not a per-category override - HasOverride stays false")
    HotstringsSetOverride("rolls", "", "delay", 1.2)
    AssertEqual(1.2, HotstringsResolve("rolls", "").Delay, "a per-category override sets its effective delay")
}
Test("HotstringsConfig: base expansion delay tier (below category, above the shared default)",
    TestHotstringsConfig_BaseDelayTier)

; A user delay is stored as an offset, so it follows the base: setting 1.2 s on
; top of the 0.75 s default is +0.45 s, and a 1.0 s base makes it 1.45 s.
TestHotstringsConfig_OverrideFollowsTheBase() {
    global Features, _HotstringsOverridesPath
    _HCfgTestReset()
    AssertTrue(HotstringsSetOverride("rolls", "", "delay", 1.2), "the override is stored")
    AssertTrue(InStr(FileRead(_HotstringsOverridesPath, "UTF-8"), "delay_offset = 0.450") > 0,
        "the file holds the offset of the base, not the absolute delay")
    AssertFalse(InStr(FileRead(_HotstringsOverridesPath, "UTF-8"), "delay = 1.2") > 0,
        "the absolute spelling is gone")
    Previous := HotstringsBaseDelay()
    HotstringsOverridesRebase(Previous, 1.0)
    AssertEqual(1.45, HotstringsResolve("rolls", "").Delay,
        "after the base moves to 1.0 s the override keeps its +0.45 s")
    HotstringsOverridesRebase(1.0, Previous)
    AssertEqual(1.2, HotstringsResolve("rolls", "").Delay, "and returns with the base")
}
Test("HotstringsConfig: a delay override keeps its offset when the base moves",
    TestHotstringsConfig_OverrideFollowsTheBase)

; Unlimited is not an offset: it must stay unlimited whatever the base.
TestHotstringsConfig_UnlimitedSurvivesTheBase() {
    global _HotstringsOverridesPath
    _HCfgTestReset()
    AssertTrue(HotstringsSetOverride("rolls", "", "delay", 0), "unlimited is stored")
    AssertTrue(InStr(FileRead(_HotstringsOverridesPath, "UTF-8"), "delay_unlimited = true") > 0,
        "an unlimited delay has its own flag")
    HotstringsOverridesRebase(0.75, 3)
    AssertEqual(0, HotstringsResolve("rolls", "").Delay, "the base never changes an unlimited delay")
    HotstringsOverridesRebase(3, 0.75)
}
Test("HotstringsConfig: an unlimited delay override survives a base change",
    TestHotstringsConfig_UnlimitedSurvivesTheBase)

; The override file of earlier builds held absolute delays and a menu-set default
; delay under [_global]. The boot migration keeps every effective delay.
TestHotstringsConfig_LegacyDelaysAreMigrated() {
    global _HotstringsOverrides, _HotstringsOverridesPath, Features
    _HCfgTestReset()
    Path := _HotstringsOverridesPath
    FileAppend("[_global]`ndelay = 1.5`n[rolls]`ndelay = 2.0`ncolor = " . '"' . "#112233" . '"' . "`n"
        . "[rolls.ct]`ndelay = 0.4`n[magickey]`ndelay_offset = 0.25`n", Path, "UTF-8")
    _HotstringsOverrides := _ParseOverrides(Path)
    Hotstrings := Features["hotstrings"]
    Had := Hotstrings.Has("expansion_delay")
    Saved := Had ? Hotstrings["expansion_delay"] : 0
    ; The harness has no config.toml to write: the seam stands for the live writer
    ; and publishes the value the way a successful write does.
    Writes := []
    WriteBase(Seconds) {
        Writes.Push(Seconds)
        Hotstrings["expansion_delay"] := Seconds
        return true
    }
    try {
        AssertTrue(HotstringsOverridesBoot(WriteBase), "the migration reports success once the file is rewritten")
        AssertEqual(1, Writes.Length, "the base is written once")
        AssertEqual(1.5, Writes[1], "the default delay of the old file becomes the base")
        AssertEqual(1.5, HotstringsBaseDelay(), "the new base is live")
        AssertEqual(2.0, HotstringsResolve("rolls", "").Delay, "an absolute delay keeps its value")
        AssertEqual(0.4, HotstringsResolve("rolls", "ct").Delay, "a section delay keeps its value")
        AssertEqual(1.75, HotstringsResolve("magickey", "").Delay, "an offset already stored follows the migrated base")
        AssertFalse(_HotstringsOverrides.Has("_global"), "the old default delay record is gone")
        Text := FileRead(Path, "UTF-8")
        AssertTrue(InStr(Text, "delay_offset = 0.500") > 0, "the file holds the offset of the migrated base")
        AssertTrue(InStr(Text, "delay_offset = -1.100") > 0, "a section below the base gets a negative offset")
        AssertFalse(RegExMatch(Text, "m)^delay = ") > 0, "no absolute delay remains in the file")
        AssertFalse(InStr(Text, "[_global]") > 0, "the old default delay section is gone")
        AssertTrue(InStr(Text, "#112233") > 0, "the colour is kept")
        ; Idempotent: a second boot over the rewritten file changes nothing.
        _HotstringsOverrides := _ParseOverrides(Path)
        AssertTrue(HotstringsOverridesBoot(WriteBase), "the rewritten file needs no migration")
        AssertEqual(1, Writes.Length, "and writes no second base")
        AssertEqual(2.0, HotstringsResolve("rolls", "").Delay, "the migrated file resolves to the same delays")
    } finally {
        if Had
            Hotstrings["expansion_delay"] := Saved
        else if Hotstrings.Has("expansion_delay")
            Hotstrings.Delete("expansion_delay")
        HotstringsResolveBumpGen()
    }
}
Test("HotstringsConfig: the boot migration keeps every effective delay (hotstrings-delay-offsets)",
    TestHotstringsConfig_LegacyDelaysAreMigrated)

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
    AssertEqual(Float(ManifestDefaultFor("hotstrings.expansion_delay")), GLOBAL_DEFAULT_DELAY,
        "GLOBAL_DEFAULT_DELAY is the manifest default of hotstrings.expansion_delay")
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
    Sections["assign"] := { Delay: 0.3, Color: "#2e7d32", Description: "" }
    _HCfgTestSeedToml("rolls", 0.5, "#fb8c00", Sections)
    R := HotstringsResolve("rolls", "assign")
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
    HotstringsSetOverride("rolls", "assign", "delay", 0.2)
    HotstringsSetOverride("rolls", "assign", "color", "#abcdef")
    ; Empty Field clears both delay and color.
    HotstringsClearOverride("rolls", "assign", "")
    R := HotstringsResolve("rolls", "assign")
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

TestHotstringsConfig_ClearOverrideRejectsUnknownField() {
	global _HotstringsOverridesPath
	_HCfgTestReset()
	AssertTrue(HotstringsSetOverride("rolls", "", "delay", 0.25),
		"the fixture must publish one real override before testing clear")
	Before := FileRead(_HotstringsOverridesPath, "UTF-8")
	for InvalidField in ["badfield", 42] {
		AssertFalse(HotstringsClearOverride(
			"rolls", "", InvalidField),
			"clearOverride must reject an unknown or non-string field")
		AssertEqual(Before, FileRead(_HotstringsOverridesPath, "UTF-8"),
			"a rejected clear must not rewrite the durable override file")
		AssertEqual(0.25, HotstringsResolve("rolls", "").Delay,
			"a rejected clear must preserve the live override")
	}
	AssertFalse(HotstringsClearOverride("missing", "", "badfield"),
		"an absent category must not turn an invalid field into idempotent success")
}
Test("HotstringsConfig: clearOverride rejects unknown fields",
	TestHotstringsConfig_ClearOverrideRejectsUnknownField)

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
	OriginalText := "[rolls]`ndelay_offset = -0.350`n"
	Lock := 0
	try {
		try FileDelete(Path)
		FileAppend(OriginalText, Path, "UTF-8")
		_HotstringsOverridesPath := Path
		_HotstringsOverrides := _ParseOverrides(Path)
		HotstringsOverridesApplyBase()
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
	Assert(InStr(Body, "FSConfigAtomicMoveCreate(StagePath, Path, FinalAdmission)") > 0
		&& InStr(Body, "FSConfigAtomicMoveReplace(StagePath, Path, &MoveError, FinalAdmission)") > 0,
		"both absent and existing sources must publish through their atomic filesystem adapter with final source admission")
	Assert(InStr(Body, 'FileOpen(_HotstringsOverridesPath, "w"') == 0,
		"_SaveOverrides must never truncate the live override file before publication succeeds")
}
Test("HotstringsConfig: override file publication is atomic (hotstrings-override-rollback-on-write-failure)",
	TestHotstringsConfig_SaveOverridesPublishesAtomically)


TestHotstringsConfig_SaveOverridesRequiresDurableExactStage() {
	Body := _DriverFuncBody("_SaveOverrides")
	DurablePos := InStr(Body, "FSWriteDurable(StagePath, Out)")
	ExactPos := InStr(Body, "FSUtf8ExactMatches(StagePath, Out)")
	CreatePos := InStr(Body, "FSConfigAtomicMoveCreate(StagePath, Path, FinalAdmission)")
	ReplacePos := InStr(Body, "FSConfigAtomicMoveReplace(StagePath, Path, &MoveError, FinalAdmission)")
	PublishedReadbackPos := InStr(Body, "FSUtf8ExactMatches(Path, Out)")
	LivePos := InStr(Body, "LivePublished := PublishFn.Call()")
	Assert(DurablePos > 0,
		"the default override writer must count bytes and flush its stage to stable storage")
	Assert(ExactPos > DurablePos,
		"the durable stage must be read back byte-exactly before publication")
	Assert(CreatePos > ExactPos && ReplacePos > ExactPos,
		"both atomic publication modes must remain downstream of durable exact stage validation")
	Assert(PublishedReadbackPos > CreatePos && PublishedReadbackPos > ReplacePos
		&& LivePos > PublishedReadbackPos,
		"RAM publication must remain downstream of byte-exact native target readback")
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
		FileAppend('[rolls]`ndelay_offset = -0.350`ncolor = "#111111"`n', Path, "UTF-8")
		_HotstringsOverridesPath := Path
		_HotstringsOverrides := _ParseOverrides(Path)
		HotstringsOverridesApplyBase()
		HotstringsResolveBumpGen()
		_HCfgLeaseOuterWriterCalls := 0
		_HCfgLeaseInnerWriterCalls := 0
		_HCfgLeaseInnerResult := unset
		_HCfgLeaseReloadResult := unset
		_HCfgLeaseReloadPreservedIdentity := false

		OuterResult := HotstringsSetOverride("rolls", "", "delay", 0.9,
			_HCfgLeaseOuterWriter)
		DiskAfter := _ParseOverrides(Path)
		HotstringsOverridesApplyBase(DiskAfter)

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
	_HCfgTestSeedToml("rolls", 0.5, "#fb8c00", Map("assign", { Delay: 0.3, Color: "#2e7d32", ShowTooltip: "" }))

	; Resolution reads no suspend flag anywhere in its cascade.
	Body := _DriverFuncBody("_HotstringsResolveUncached")
	Assert(InStr(Body, "A_IsSuspended") == 0,
		"the resolution cascade must not branch on A_IsSuspended — a paused driver would "
		. "resolve a different delay than a running one for the same hotstring")

	; And it is deterministic: the same query twice yields the same values, so a
	; caller that resolves before a pause and acts after it sees one answer.
	A := HotstringsResolve("rolls", "assign")
	B := HotstringsResolve("rolls", "assign")
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
	; rolls.assign declares no delay in the manifest, so its file decides.
	_HCfgTestReset()
	_HCfgTestSeedToml("rolls", 0.5, "", Map("assign", { Delay: 0.3, Color: "", ShowTooltip: "" }))
	AssertEqual(0.3, HotstringsResolve("rolls", "assign").Delay,
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
	AssertEqual(30, _HSE_SourcePriority("ext:ergopti:rolls"), "canonical extension category source default")
	AssertEqual(30, _HSE_SourcePriority("EXT:ERGOPTI:ROLLS"), "canonical extension source is case-insensitive")
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
	_HotstringsOverrides     := _ParseOverrides(Path)
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
	_HotstringsOverrides     := _ParseOverrides(Path)
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
	global _HotstringsOverrides, _HotstringsOverridesPath
	Saved := _HotstringsOverrides
	SavedPath := _HotstringsOverridesPath
	; The setter publishes only after a successful write, so this case owns its
	; writable override file instead of inheriting a path an earlier test set.
	Path := A_Temp . "\hotstrings_ext_prio_overrides.toml"
	ExtPath := A_Temp . "\hotstrings_ext_prio.toml"
	try FileDelete(Path)
	try FileDelete(ExtPath)
	_HotstringsOverrides := _ParseOverrides(Path)
	_HotstringsOverridesPath := Path
	HotstringsResolveBumpGen()
	try {
		FileAppend("[_meta]`ndelay = 0.5`n", ExtPath, "UTF-8")   ; ships no priority

		R := HotstringsResolveExt("demo", ExtPath, "")
		AssertEqual(30, R.Priority,
			"extension with no override resolves to the package source default (30)")

		AssertTrue(HotstringsSetOverride("ext.demo", "", "priority", 88),
			"the extension priority override must be persisted and published")
		R2 := HotstringsResolveExt("demo", ExtPath, "")
		AssertEqual(88, R2.Priority,
			"a user override beats the extension package source default")
	} finally {
		try FileDelete(ExtPath)
		try FileDelete(Path)
		_HotstringsOverrides := Saved
		_HotstringsOverridesPath := SavedPath
		HotstringsResolveBumpGen()
	}
}
Test("HotstringsResolveExt: exposes priority with the package source default + override",
	TestHotstringsConfig_ResolveExtPriority)

; Real offset source, production projection/rebase and actual public colour/delay
; writes. Expectations compare an independent semantic source decode or a fresh
; production reload, never the proposed StoredOffset implementation property.
_HCO_OffsetRetainsIntent(Mode) {
	global Features, _HotstringsOverrides, _HotstringsOverridesPath, HotstringGroupConfig
	Saved := {features: Features, overrides: _HotstringsOverrides,
		path: _HotstringsOverridesPath, groups: HotstringGroupConfig}
	Root := A_Temp . "\ergopti_offset_intent_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	FSCreateDirectoryExclusiveStrict(Root)
	Path := Root . "\overrides.toml"
	try {
		AssertFalse(A_IsSuspended)
		Features := Features.Clone()
		Features["hotstrings"] := Features["hotstrings"].Clone()
		Features["hotstrings"][ConfigLeaf.EXPANSION_DELAY] := 0.75
		_HotstringsOverridesPath := Path
		HotstringGroupConfig := HotstringGroupConfig.Clone()
		Offset := (Mode == "unclipped-control" || Mode == "base-roundtrip") ? -0.25 : -1.0
		Leaf := Mode == "unlimited-control" ? "delay_unlimited = true" : "delay_offset = " . Offset
		Source := '[magickey]`n' . Leaf . '`ncolor = "#123456"`n'
			. '[magickey.text_expansion_symbols]`n' . Leaf . '`ncolor = "#234567"`n'
		AssertTrue(FSWriteCreateDurable(Path, Source))
		SourceModel := TOML_ParseDocument(FSReadStrict(Path))
		_HotstringsOverrides := _ParseOverrides(Path)
		HotstringsOverridesApplyBase()
		HotstringsResolveBumpGen()
		Initial := HotstringsResolve("magickey", "").Delay
		if Mode == "unlimited-control"
			AssertEqual(0, Initial)
		else if Mode == "unclipped-control" || Mode == "base-roundtrip"
			AssertEqual(0.5, Initial)
		else
			AssertEqual(0.001, Initial, "a finite cancelling offset clamps; it must not become unlimited")

		if Mode == "replace-clipped-delay" {
			AssertTrue(HotstringsSetOverride("magickey", "", "delay", 0.5))
			AssertTrue(HotstringsSetOverride("magickey", "text_expansion_symbols", "delay", 0.5))
			AssertEqual(0.5, HotstringsResolve("magickey", "").Delay)
			AssertEqual(0.5, HotstringsResolve("magickey", "text_expansion_symbols").Delay)
		}
		if Mode == "base-roundtrip" {
			Features["hotstrings"][ConfigLeaf.EXPANSION_DELAY] := 0.1
			HotstringsOverridesRebase(0.75, 0.1)
			AssertEqual(0.001, HotstringsResolve("magickey", "").Delay)
			Features["hotstrings"][ConfigLeaf.EXPANSION_DELAY] := 0.75
			HotstringsOverridesRebase(0.1, 0.75)
		} else if Mode != "colour" {
			Features["hotstrings"][ConfigLeaf.EXPANSION_DELAY] := 2.0
			HotstringsOverridesRebase(0.75, 2.0)
		}

		if Mode == "colour" || Mode == "unclipped-control" || Mode == "unlimited-control" {
			AssertTrue(HotstringsSetOverride("magickey", "", "color", "#abcdef"),
				"the actual public writer must acknowledge the unrelated colour change")
			AssertTrue(HotstringsSetOverride("magickey", "text_expansion_symbols", "color", "#fedcba"))
			Disk := TOML_ParseDocument(FSReadStrict(Path))
			AssertEqual("#abcdef", Disk["magickey"]["color"])
			AssertEqual("#fedcba", Disk["magickey"]["text_expansion_symbols"]["color"])
			if Mode != "unlimited-control" {
				AssertEqual(SourceModel["magickey"]["delay_offset"], Disk["magickey"]["delay_offset"],
					"a colour write cannot replace the finite relative intention with its clipped projection")
				AssertEqual(SourceModel["magickey"]["text_expansion_symbols"]["delay_offset"],
					Disk["magickey"]["text_expansion_symbols"]["delay_offset"])
			} else {
				AssertTrue(Disk["magickey"]["delay_unlimited"] is TOML_Bool)
				AssertTrue(Disk["magickey"]["delay_unlimited"].Value)
				AssertFalse(Disk["magickey"].Has("delay_offset"))
			}
		}

		Fresh := _ParseOverrides(Path)
		HotstringsOverridesApplyBase(Fresh)
		FileLive := HotstringsResolve("magickey", "").Delay
		SectionLive := HotstringsResolve("magickey", "text_expansion_symbols").Delay
		AssertEqual(Fresh["magickey"].Delay, FileLive,
			"live rebasing must equal a genuine reload of the same persistent offset at the same base")
		AssertEqual(Fresh["magickey"].Sections["text_expansion_symbols"].Delay, SectionLive)
		if Mode == "rebase"
			AssertEqual(1.0, FileLive, "source -1.000 plus base 2.000 is finite one second")
		else if Mode == "base-roundtrip"
			AssertEqual(0.5, FileLive, "returning the base must restore the pre-clamp finite delay")
		else if Mode == "replace-clipped-delay" || Mode == "unclipped-control"
			AssertEqual(1.75, FileLive)
		else if Mode == "unlimited-control"
			AssertEqual(0, FileLive)
		if Mode == "rebase" || Mode == "base-roundtrip"
			AssertEqual(Source, FSReadStrict(Path), "memory-only rebase must not rewrite the original offset")
		Stages := 0
		loop files, Root . "\*.tmp"
			Stages += 1
		AssertEqual(0, Stages)
		Probe := _ConfigWriteLeaseTryAcquire(Path, "offset-fixture-terminal-probe")
		AssertTrue(Probe is Object)
		try AssertTrue(_ConfigWriteLeaseOwns(Probe, Path))
		finally _ConfigWriteLeaseRelease(Probe)
	} finally {
		Features := Saved.features
		_HotstringsOverrides := Saved.overrides
		_HotstringsOverridesPath := Saved.path
		HotstringGroupConfig := Saved.groups
		HotstringsResolveBumpGen()
		DirDelete(Root, true)
	}
}
for _HCO_Mode in ["rebase", "colour", "base-roundtrip", "unclipped-control", "unlimited-control", "replace-clipped-delay"]
	Test("HotstringsConfig persistent offset: " . _HCO_Mode, _HCO_OffsetRetainsIntent.Bind(_HCO_Mode))

; A valid source may carry both recognised delay leaves. The shared resolver
; explicitly gives true unlimited priority over an offset, independently of
; source line order. The offset here stays above the clamp: this is not the
; separate clipped-offset information-loss regression.
_HCU_UnlimitedPrecedence(Mode) {
	global Features, _HotstringsOverrides, _HotstringsOverridesPath, HotstringGroupConfig
	Saved := {features: Features, overrides: _HotstringsOverrides,
		path: _HotstringsOverridesPath, groups: HotstringGroupConfig}
	Root := A_Temp . "\ergopti_unlimited_precedence_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	FSCreateDirectoryExclusiveStrict(Root)
	Path := Root . "\overrides.toml"
	try {
		Features := Features.Clone()
		Features["hotstrings"] := Features["hotstrings"].Clone()
		Features["hotstrings"][ConfigLeaf.EXPANSION_DELAY] := 0.75
		_HotstringsOverridesPath := Path
		HotstringGroupConfig := HotstringGroupConfig.Clone()
		switch Mode {
			case "unlimited-only": Leaves := "delay_unlimited = true`n"
			case "offset-only": Leaves := "delay_offset = -0.25`n"
			case "unlimited-first": Leaves := "delay_unlimited = true`ndelay_offset = -0.25`n"
			case "offset-first": Leaves := "delay_offset = -0.25`ndelay_unlimited = true`n"
			default: throw ValueError("unknown unlimited precedence control")
		}
		Source := "[magickey]`n" . Leaves . "[magickey.text_expansion_symbols]`n" . Leaves
		AssertTrue(FSWriteCreateDurable(Path, Source))
		Document := TOML_ParseDocument(FSReadStrict(Path))
		if Mode != "offset-only" {
			AssertTrue(Document["magickey"]["delay_unlimited"] is TOML_Bool)
			AssertTrue(Document["magickey"]["delay_unlimited"].Value)
		}
		if Mode != "unlimited-only"
			AssertEqual(-0.25, Document["magickey"]["delay_offset"])
		_HotstringsOverrides := _ParseOverrides(Path)
		HotstringsOverridesApplyBase()
		HotstringsResolveBumpGen()
		Expected := Mode == "offset-only" ? 0.5 : 0
		AssertEqual(Expected, HotstringsResolve("magickey", "").Delay,
			"the actual category resolver must give true unlimited precedence over a finite source offset")
		AssertEqual(Expected, HotstringsResolve("magickey", "text_expansion_symbols").Delay,
			"the actual section resolver must use the same unlimited precedence")
		AssertEqual(Source, FSReadStrict(Path), "reading/applying overrides must not normalize or rewrite source bytes")
	} finally {
		Features := Saved.features
		_HotstringsOverrides := Saved.overrides
		_HotstringsOverridesPath := Saved.path
		HotstringGroupConfig := Saved.groups
		HotstringsResolveBumpGen()
		DirDelete(Root, true)
	}
}
for _HCU_Mode in ["unlimited-only", "offset-only", "unlimited-first", "offset-first"]
	Test("HotstringsConfig unlimited precedence: " . _HCU_Mode, _HCU_UnlimitedPrecedence.Bind(_HCU_Mode))

; Canonical TOML spellings must survive an unrelated public setting change.
_HOS_ValidSyntaxRoundTrip(Mode) {
	global Features, _HotstringsOverrides, _HotstringsOverridesPath, HotstringGroupConfig
	Saved := {features: Features, overrides: _HotstringsOverrides,
		path: _HotstringsOverridesPath, groups: HotstringGroupConfig}
	Root := A_Temp . "\ergopti_override_syntax_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	FSCreateDirectoryExclusiveStrict(Root)
	Path := Root . "\overrides.toml"
	try {
		AssertFalse(A_IsSuspended)
		Features := Features.Clone()
		Features["hotstrings"] := Features["hotstrings"].Clone()
		Features["hotstrings"][ConfigLeaf.EXPANSION_DELAY] := 0.75
		HotstringGroupConfig := HotstringGroupConfig.Clone()
		_HotstringsOverridesPath := Path
		_HotstringsOverrides := Map()
		Field := InStr(Mode, "color") ? "color" : InStr(Mode, "priority") ? "priority" : "delay_offset"
		if Mode == "literal-color"
			Leaf := "color = '#123456'"
		else if Mode == "quoted-key-color"
			Leaf := '"color" = "#123456"'
		else if Mode == "color-control"
			Leaf := 'color = "#123456"'
		else if Mode == "signed-offset"
			Leaf := "delay_offset = +0.250"
		else if Mode == "exponent-offset"
			Leaf := "delay_offset = 2.5e-1"
		else if Mode == "offset-control"
			Leaf := "delay_offset = 0.250"
		else if Mode == "separated-priority"
			Leaf := "priority = 2_5"
		else
			Leaf := "priority = 25"
		Source := "[magickey]`n" . Leaf . "`n[magickey.text_expansion_symbols]`n" . Leaf . "`n"
		AssertTrue(FSWriteCreateDurable(Path, Source))
		Before := TOML_ParseDocument(FSReadStrict(Path))
		AssertTrue(Before["magickey"].Has(Field), "the canonical source decoder must recognize the real owned leaf")
		AssertTrue(HotstringsConfigReload(), "the real loader must admit the source before the public edit")
		AssertTrue(HotstringsSetOverride("magickey", "", "show_tooltip", false))
		AssertTrue(HotstringsSetOverride("magickey", "text_expansion_symbols", "show_tooltip", false))
		After := TOML_ParseDocument(FSReadStrict(Path))
		AssertTrue(After["magickey"].Has(Field), "an unrelated acknowledged save must preserve the category's existing valid leaf")
		AssertTrue(After["magickey"]["text_expansion_symbols"].Has(Field), "an unrelated acknowledged save must preserve the section's existing valid leaf")
		AssertEqual(Before["magickey"][Field], After["magickey"][Field])
		AssertEqual(Before["magickey"]["text_expansion_symbols"][Field], After["magickey"]["text_expansion_symbols"][Field])
		AssertTrue(After["magickey"]["show_tooltip"] is TOML_Bool)
		AssertFalse(After["magickey"]["show_tooltip"].Value)
		AssertTrue(HotstringsConfigReload(), "the written file must remain reloadable by the production owner")
		Expected := Before["magickey"][Field]
		Live := HotstringsResolve("magickey", "")
		AssertEqual(Field == "color" ? Expected : Field == "priority" ? Expected : 0.75 + Expected,
			Field == "color" ? Live.Color : Field == "priority" ? Live.Priority : Live.Delay)
		Stages := 0
		loop files, Root . "\*.tmp"
			Stages += 1
		AssertEqual(0, Stages)
	} finally {
		Features := Saved.features
		_HotstringsOverrides := Saved.overrides
		_HotstringsOverridesPath := Saved.path
		HotstringGroupConfig := Saved.groups
		HotstringsResolveBumpGen()
		DirDelete(Root, true)
	}
}
for _HOS_Mode in ["literal-color", "quoted-key-color", "signed-offset", "exponent-offset", "separated-priority", "color-control", "offset-control", "priority-control"]
	Test("HotstringsConfig valid syntax persistence: " . _HOS_Mode, _HOS_ValidSyntaxRoundTrip.Bind(_HOS_Mode))

; A projection can ignore future data for reading, but may not erase it on save.
_HOSP_RefusesUnrepresentableSource(Mode) {
	global _HotstringsOverrides, _HotstringsOverridesPath, HotstringGroupConfig
	Saved := {overrides: _HotstringsOverrides, path: _HotstringsOverridesPath, groups: HotstringGroupConfig}
	Root := A_Temp . "\ergopti_override_preservation_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	FSCreateDirectoryExclusiveStrict(Root)
	Path := Root . "\overrides.toml"
	try {
		AssertFalse(A_IsSuspended)
		Source := '[magickey]`ncolor = "#123456"`n'
		switch Mode {
			case "unknown-leaf": Source .= 'future_enabled = true`n'
			case "nested-section": Source .= '[magickey.text_expansion_symbols.future]`nflag = true`n'
			case "array-category": Source .= '[[future_records]]`nvalue = "keep"`n'
			case "invalid-owned-type": Source .= 'delay_offset = "future-mode"`n'
			case "extension-control": Source .= '[ext.demo.main]`npriority = 25`n'
		}
		AssertTrue(FSWriteCreateDurable(Path, Source))
		TOML_ParseDocument(FSReadStrict(Path))
		_HotstringsOverridesPath := Path
		_HotstringsOverrides := Map()
		HotstringGroupConfig := HotstringGroupConfig.Clone()
		AssertTrue(HotstringsConfigReload(), "the shared read projection may ignore foreign data")
		Owner := _HotstringsOverrides
		if Mode == "extension-control" {
			AssertTrue(HotstringsSetOverride("magickey", "", "show_tooltip", false))
			Disk := TOML_ParseDocument(FSReadStrict(Path))
			AssertEqual(25, Disk["ext"]["demo"]["main"]["priority"], "the supported extension route stays writable")
		} else {
			AssertFalse(HotstringsSetOverride("magickey", "", "show_tooltip", false),
				"a serializer cannot acknowledge an edit that loses unrepresented source data")
			AssertEqual(Source, FSReadStrict(Path), "refusal must preserve the exact foreign source bytes")
			AssertTrue(_HotstringsOverrides == Owner, "refusal cannot publish a detached candidate")
		}
		Stages := 0
		loop files, Root . "\*.tmp"
			Stages += 1
		AssertEqual(0, Stages)
	} finally {
		_HotstringsOverrides := Saved.overrides
		_HotstringsOverridesPath := Saved.path
		HotstringGroupConfig := Saved.groups
		HotstringsResolveBumpGen()
		DirDelete(Root, true)
	}
}
for _HOSP_Mode in ["unknown-leaf", "nested-section", "array-category", "invalid-owned-type", "extension-control"]
	Test("HotstringsConfig source preservation: " . _HOSP_Mode, _HOSP_RefusesUnrepresentableSource.Bind(_HOSP_Mode))

_HOL_LegacyDelayRoundTrip(Mode) {
	global Features, _HotstringsOverrides, _HotstringsOverridesPath, HotstringGroupConfig
	global _HotstringsLegacyDelimiters, _HotstringsCommonOverrideAdmitted
	Saved := {features: Features, overrides: _HotstringsOverrides, path: _HotstringsOverridesPath,
		groups: HotstringGroupConfig, legacy: _HotstringsLegacyDelimiters, common: HotstringsCommonOverrideAdmitted()}
	Root := A_Temp . "\ergopti_legacy_reload_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	FSCreateDirectoryExclusiveStrict(Root)
	Path := Root . "\overrides.toml"
	try {
		AssertFalse(A_IsSuspended)
		Features := Features.Clone(), Features["hotstrings"] := Features["hotstrings"].Clone()
		Features["hotstrings"][ConfigLeaf.EXPANSION_DELAY] := 0.75
		HotstringGroupConfig := HotstringGroupConfig.Clone()
		_HotstringsOverridesPath := Path, _HotstringsOverrides := Map()
		Leaf := Mode == "offset-control" ? "delay_offset = -0.250" : "delay = 0.500"
		Source := "[magickey]`n" . Leaf . "`n[magickey.text_expansion_symbols]`n" . Leaf . "`n"
		if Mode == "global-default-refused" || Mode == "init-global-save"
			Source := "[_global]`ndelay = 1.500`n" . Source
		AssertTrue(FSWriteCreateDurable(Path, Source))
		if Mode == "global-default-refused" {
			Owner := _HotstringsOverrides
			AssertFalse(HotstringsConfigReload(), "a runtime read cannot acknowledge the cross-file default migration")
			AssertTrue(_HotstringsOverrides == Owner)
			AssertEqual(0.75, HotstringsBaseDelay())
			AssertEqual(Source, FSReadStrict(Path))
			return
		}
		if InStr(Mode, "init-") == 1
			HotstringsConfigInit(Path)
		else
			AssertTrue(HotstringsConfigReload())
		if Mode == "reload-effective" || Mode == "offset-control" {
			AssertEqual(0.5, HotstringsResolve("magickey", "").Delay, "runtime reload must apply a recognized absolute delay")
			AssertEqual(0.5, HotstringsResolve("magickey", "text_expansion_symbols").Delay)
			AssertEqual(Source, FSReadStrict(Path), "the memory-only reload may not rewrite the source")
		}
		if Mode == "init-clear" {
			AssertTrue(HotstringsClearOverride("magickey", "", "delay"))
			AssertTrue(HotstringsClearOverride("magickey", "text_expansion_symbols", "delay"))
		} else if Mode == "init-replace" {
			AssertTrue(HotstringsSetOverride("magickey", "", "delay", 0.25))
			AssertTrue(HotstringsSetOverride("magickey", "text_expansion_symbols", "delay", 0.25))
		} else {
			AssertTrue(HotstringsSetOverride("magickey", "", "color", "#123456"))
			AssertTrue(HotstringsSetOverride("magickey", "text_expansion_symbols", "color", "#234567"))
		}
		Disk := TOML_ParseDocument(FSReadStrict(Path))
		for Values in [Disk.Get("magickey", Map()), Disk.Has("magickey") ? Disk["magickey"].Get("text_expansion_symbols", Map()) : Map()] {
			if Mode == "init-clear" {
				AssertFalse(Values.Has("delay"), "explicit clear retires legacy intention too")
				AssertFalse(Values.Has("delay_offset"))
			} else {
				AssertTrue(Values.Has("delay") || Values.Has("delay_offset"), "an unrelated acknowledged save cannot lose the existing absolute delay")
				Effective := Values.Has("delay") ? Values["delay"] : 0.75 + Values["delay_offset"]
				AssertEqual(Mode == "init-replace" ? 0.25 : 0.5, Effective)
			}
		}
		if Mode == "init-global-save" {
			AssertEqual(1.5, Disk["_global"]["delay"], "a pre-boot unrelated write must preserve the absolute default intent")
			AssertFalse(Disk["_global"].Has("delay_offset"), "the legacy default is not an ordinary category offset")
			AfterSave := FSReadStrict(Path), Owner := _HotstringsOverrides
			AssertFalse(HotstringsConfigReload(), "the preserved pending default still requires the startup migration")
			AssertTrue(_HotstringsOverrides == Owner)
			AssertEqual(AfterSave, FSReadStrict(Path))
			AssertEqual(0.75, HotstringsBaseDelay())
			return
		}
		AssertTrue(HotstringsConfigReload())
		if Mode != "init-clear" {
			AssertEqual(Mode == "init-replace" ? 0.25 : 0.5, HotstringsResolve("magickey", "").Delay)
			AssertEqual(Mode == "init-replace" ? 0.25 : 0.5, HotstringsResolve("magickey", "text_expansion_symbols").Delay)
		}
	} finally {
		Features := Saved.features, _HotstringsOverrides := Saved.overrides
		_HotstringsOverridesPath := Saved.path, HotstringGroupConfig := Saved.groups
		_HotstringsLegacyDelimiters := Saved.legacy, _HotstringsCommonOverrideAdmitted := Saved.common
		HotstringsResolveBumpGen()
		DirDelete(Root, true)
	}
}
for _HOL_Mode in ["reload-effective", "reload-save", "init-save", "init-clear", "init-replace", "offset-control", "global-default-refused", "init-global-save"]
	Test("HotstringsConfig legacy runtime delay: " . _HOL_Mode, _HOL_LegacyDelayRoundTrip.Bind(_HOL_Mode))

_HOUTF8_ExactSource(Mode) {
	global _HotstringsOverrides, _HotstringsOverridesPath, HotstringGroupConfig
	Saved := {overrides: _HotstringsOverrides, path: _HotstringsOverridesPath, groups: HotstringGroupConfig}
	Root := A_Temp . "\ergopti_override_utf8_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	FSCreateDirectoryExclusiveStrict(Root)
	Path := Root . "\overrides.toml"
	EmptyOwner := _ParseOverrides(Path)
	try {
		AssertFalse(A_IsSuspended)
		Invalid := Mode == "invalid-byte" || Mode == "invalid-save"
		Value := Invalid ? "X" : "é" . Chr(0x1F600)
		Source := Mode == "empty-control" ? "" : "[magickey]`ncolor = " . TOML_RenderString(Value) . "`n"
		if Mode == "bom-unicode"
			Source := Chr(0xFEFF) . Source
		Bytes := FSUtf8Bytes(Source)
		if Invalid {
			Offset := InStr(Source, "X", true) - 1
			AssertTrue(Offset >= 0)
			NumPut("UChar", 0xFF, Bytes, Offset)
		}
		Stream := FileOpen(Path, "w", "UTF-8-RAW")
		AssertTrue(IsObject(Stream))
		try {
			if Bytes.Size
				AssertEqual(Bytes.Size, Stream.RawWrite(Bytes, Bytes.Size))
			else
				AssertEqual(0, Stream.Length, "opening an empty owned fixture must create a genuinely zero-byte file")
		} finally Stream.Close()
		Initial := FSReadBytesStrict(Path)
		AssertEqual(Bytes.Size, Initial.Size)
		if Bytes.Size
			AssertEqual(Bytes.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", Bytes, "Ptr", Initial, "UPtr", Bytes.Size, "UPtr"))
		if Mode == "bom-unicode"
			AssertEqual(0xEF, NumGet(Initial, 0, "UChar"), "the fixture physically contains its input UTF-8 BOM")
		_HotstringsOverridesPath := Path
		_HotstringsOverrides := EmptyOwner
		HotstringGroupConfig := HotstringGroupConfig.Clone()
		Owner := _HotstringsOverrides
		if Invalid {
			AssertFalse(FSReadUtf8Exact(Path) is String, "the native exact reader must observe malformed UTF-8")
			Status := FSReadWithStatus(Path)
			AssertEqual(FS_STATUS_ERROR, Status["status"], "the actual existing source must classify as an encoding/read error, never absence")
			AssertEqual("", Status["content"])
			if Mode == "invalid-save"
				AssertFalse(HotstringsSetOverride("magickey", "", "show_tooltip", false), "a genuine native save must refuse before normalizing malformed source bytes")
			AssertFalse(HotstringsConfigReload(), "invalid source bytes cannot publish normalized replacement data")
			AssertTrue(_HotstringsOverrides == Owner)
			RefusedGlobal := false
			try _ParseGlobalKey(Path, "word_delimiters")
			catch ValueError
				RefusedGlobal := true
			AssertTrue(RefusedGlobal, "the sibling legacy reader must refuse the same malformed bytes")
			AssertFalse(HotstringsSetOverride("magickey", "", "show_tooltip", false), "even a valid unrelated edit cannot overwrite undecodable source data")
			AssertTrue(_HotstringsOverrides == Owner)
			After := FSReadBytesStrict(Path)
			AssertEqual(Initial.Size, After.Size)
			AssertEqual(Initial.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", Initial, "Ptr", After, "UPtr", Initial.Size, "UPtr"))
		} else {
			AssertTrue(FSReadUtf8Exact(Path) is String, "an empty or BOM-bearing valid UTF-8 source remains readable")
			AssertTrue(HotstringsConfigReload())
			AssertEqual("", _ParseGlobalKey(Path, "word_delimiters"))
			if Mode != "empty-control"
				AssertEqual(Value, _HotstringsOverrides["magickey"].Color)
			else
				AssertEqual(0, _HotstringsOverrides.Count)
			AssertTrue(HotstringsSetOverride("magickey", "", "show_tooltip", false))
			Disk := TOML_ParseDocument(FSReadUtf8Exact(Path))
			if Mode != "empty-control"
				AssertEqual(Value, Disk["magickey"]["color"], "valid Unicode must survive a genuine unrelated native save")
			AssertTrue(HotstringsConfigReload())
			if Mode != "empty-control"
				AssertEqual(Value, _HotstringsOverrides["magickey"].Color)
		}
		Stages := 0
		loop files, Root . "\*.tmp"
			Stages += 1
		AssertEqual(0, Stages)
	} finally {
		_HotstringsOverrides := Saved.overrides, _HotstringsOverridesPath := Saved.path
		HotstringGroupConfig := Saved.groups
		HotstringsResolveBumpGen()
		DirDelete(Root, true)
	}
}
for _HOUTF8_Mode in ["invalid-byte", "invalid-save", "unicode-control", "bom-unicode", "empty-control"]
	Test("HotstringsConfig exact source UTF-8: " . _HOUTF8_Mode, _HOUTF8_ExactSource.Bind(_HOUTF8_Mode))

; Shape validation of today's file cannot grant yesterday's Map write authority.
_HOSS_ExternalSourceSurvivesSave(Mode) {
	global _HotstringsOverrides, _HotstringsOverridesPath, HotstringGroupConfig
	Saved := {overrides: _HotstringsOverrides, path: _HotstringsOverridesPath, groups: HotstringGroupConfig}
	Root := A_Temp . "\ergopti_override_external_source_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	FSCreateDirectoryExclusiveStrict(Root)
	Path := Root . "\overrides.toml"
	try {
		AssertFalse(A_IsSuspended)
		A := '[magickey]`ncolor = "#111111"`npriority = 10`nshow_tooltip = true`n'
			. '[magickey.text_expansion_symbols]`ncolor = "#111111"`npriority = 10`nshow_tooltip = true`n'
		B := StrReplace(StrReplace(A, "#111111", "#222222", true), "priority = 10", "priority = 25", true)
		if Mode == "external-new-category"
			B := A . '[rolls]`npriority = 77`ncolor = "#777777"`n'
		if Mode == "unchanged-control"
			B := A
		AssertTrue(FSWriteCreateDurable(Path, A))
		_HotstringsOverridesPath := Path, _HotstringsOverrides := Map()
		HotstringGroupConfig := HotstringGroupConfig.Clone()
		AssertTrue(HotstringsConfigReload(), "the real loader first admits source A")
		AssertEqual(10, _HotstringsOverrides["magickey"].Priority)
		AssertEqual("#111111", _HotstringsOverrides["magickey"].Color)
		AssertTrue(FSWriteDurable(Path, B), "an external editor finishes writing valid source B before the user's next click")
		External := TOML_ParseDocument(FSReadUtf8Exact(Path))
		if Mode == "reloaded-control"
			AssertTrue(HotstringsConfigReload(), "an explicit genuine reload admits source B")
		Owner := _HotstringsOverrides
		Section := Mode == "external-section-set" ? "text_expansion_symbols" : ""
		Result := Mode == "external-clear"
			? HotstringsClearOverride("magickey", "", "show_tooltip")
			: HotstringsSetOverride("magickey", Section, "show_tooltip", false)
		Disk := TOML_ParseDocument(FSReadUtf8Exact(Path))
		if Mode == "external-new-category" {
			AssertTrue(Disk.Has("rolls"), "a full-state edit cannot delete a category the external editor already committed")
			AssertEqual(77, Disk["rolls"]["priority"])
			AssertEqual("#777777", Disk["rolls"]["color"])
		}
		for Key in ["color", "priority"] {
			AssertEqual(External["magickey"][Key], Disk["magickey"][Key], "the real native save must preserve the newer external category " . Key)
			AssertEqual(External["magickey"]["text_expansion_symbols"][Key], Disk["magickey"]["text_expansion_symbols"][Key], "the real native save must preserve the newer external section " . Key)
		}
		if Mode == "unchanged-control" || Mode == "reloaded-control"
			AssertTrue(Result, "an unchanged or explicitly reloaded source stays writable")
		if Result {
			Target := Section == "" ? Disk["magickey"] : Disk["magickey"][Section]
			if Mode == "external-clear"
				AssertFalse(Target.Has("show_tooltip"))
			else {
				AssertTrue(Target["show_tooltip"] is TOML_Bool)
				AssertFalse(Target["show_tooltip"].Value)
			}
			AssertEqual(External["magickey"]["color"], HotstringsResolve("magickey", "").Color)
		} else {
			AssertEqual(B, FSReadUtf8Exact(Path), "source-conflict refusal must retain every exact byte from the external editor")
			AssertTrue(_HotstringsOverrides == Owner, "refusal must preserve the old live owner until an explicit reload")
		}
		Stages := 0
		loop files, Root . "\*.tmp"
			Stages += 1
		AssertEqual(0, Stages)
		Probe := _ConfigWriteLeaseTryAcquire(Path, "external-source-fixture-terminal-probe")
		AssertTrue(Probe is Object)
		try AssertTrue(_ConfigWriteLeaseOwns(Probe, Path))
		finally _ConfigWriteLeaseRelease(Probe)
	} finally {
		_HotstringsOverrides := Saved.overrides, _HotstringsOverridesPath := Saved.path
		HotstringGroupConfig := Saved.groups
		HotstringsResolveBumpGen()
		DirDelete(Root, true)
	}
}
for _HOSS_Mode in ["external-category-set", "external-section-set", "external-clear", "external-new-category", "unchanged-control", "reloaded-control"]
	Test("HotstringsConfig external source ownership: " . _HOSS_Mode, _HOSS_ExternalSourceSurvivesSave.Bind(_HOSS_Mode))

_HOSST_ExternalSourceChangesWhileStaging(ChangeSource) {
	global _HotstringsOverrides, _HotstringsOverridesPath, HotstringGroupConfig
	Saved := {overrides: _HotstringsOverrides, path: _HotstringsOverridesPath, groups: HotstringGroupConfig}
	Root := A_Temp . "\ergopti_override_stage_source_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	FSCreateDirectoryExclusiveStrict(Root)
	Path := Root . "\overrides.toml"
	try {
		A := '[magickey]`ncolor = "#111111"`npriority = 10`n'
		C := ChangeSource ? '[magickey]`ncolor = "#333333"`npriority = 35`n' : A
		AssertTrue(FSWriteCreateDurable(Path, A))
		_HotstringsOverridesPath := Path, _HotstringsOverrides := Map()
		HotstringGroupConfig := HotstringGroupConfig.Clone()
		AssertTrue(HotstringsConfigReload())
		Owner := _HotstringsOverrides, State := {Calls: 0}
		WriteStage(StagePath, Content) {
			State.Calls += 1
			; The seam observes the existing cutpoint but delegates staging to
			; the genuine durable writer; no fake result or filesystem is used.
			AssertTrue(FSWriteDurable(StagePath, Content))
			AssertTrue(FSWriteDurable(Path, C), "the external source changes only after the real candidate is staged")
			return 1
		}
		Result := HotstringsSetOverride("magickey", "", "show_tooltip", false, WriteStage)
		AssertEqual(1, State.Calls)
		Disk := TOML_ParseDocument(FSReadUtf8Exact(Path))
		AssertEqual(ChangeSource ? 35 : 10, Disk["magickey"]["priority"], "the final native commit cannot bless newly read C for a candidate constructed from A")
		AssertEqual(ChangeSource ? "#333333" : "#111111", Disk["magickey"]["color"])
		if ChangeSource {
			AssertFalse(Result, "the stale staged candidate has no authority over source C")
			AssertEqual(C, FSReadUtf8Exact(Path))
			AssertTrue(_HotstringsOverrides == Owner)
		} else {
			AssertTrue(Result, "the genuine stage writer remains supported when source is unchanged")
			AssertFalse(Disk["magickey"]["show_tooltip"].Value)
		}
		Stages := 0
		loop files, Root . "\*.tmp"
			Stages += 1
		AssertEqual(0, Stages)
	} finally {
		_HotstringsOverrides := Saved.overrides, _HotstringsOverridesPath := Saved.path
		HotstringGroupConfig := Saved.groups
		HotstringsResolveBumpGen()
		DirDelete(Root, true)
	}
}
Test("HotstringsConfig staged source ownership: external change survives the final native commit", _HOSST_ExternalSourceChangesWhileStaging.Bind(true))
Test("HotstringsConfig staged source ownership: unchanged real stage remains writable", _HOSST_ExternalSourceChangesWhileStaging.Bind(false))

_HOSGATE_FinalSourceAdmission(ChangeSource) {
	Root := A_Temp . "\ergopti_override_gate_source_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	FSCreateDirectoryExclusiveStrict(Root)
	Path := Root . "\overrides.toml"
	try {
		A := '[magickey]`ncolor = "#111111"`npriority = 10`n'
		C := ChangeSource ? '[magickey]`ncolor = "#444444"`npriority = 45`n' : A
		AssertTrue(FSWriteCreateDurable(Path, A))
		Candidate := _ParseOverrides(Path)
		Candidate["magickey"].ShowTooltip := false
		State := {Staged: false, Admissions: 0, Edits: 0}
		WriteStage(StagePath, Content) {
			Written := FSWriteDurable(StagePath, Content)
			State.Staged := Written == 1
			return Written
		}
		Admit() {
			State.Admissions += 1
			if State.Staged {
				AssertTrue(FSWriteDurable(Path, C), "a reentrant admission finishes writing C before native replacement")
				State.Edits += 1
			}
			return 1
		}
		Result := _SaveOverrides(Candidate, WriteStage, 0, Path, Admit)
		AssertTrue(State.Staged && State.Edits > 0, "the genuine candidate stage and final logical admission must both be reached")
		Disk := TOML_ParseDocument(FSReadUtf8Exact(Path))
		AssertEqual(ChangeSource ? 45 : 10, Disk["magickey"]["priority"], "the final source comparison must follow reentrant logical admission")
		AssertEqual(ChangeSource ? "#444444" : "#111111", Disk["magickey"]["color"])
		if ChangeSource {
			AssertFalse(Result)
			AssertEqual(C, FSReadUtf8Exact(Path))
		} else {
			AssertTrue(Result)
			AssertFalse(Disk["magickey"]["show_tooltip"].Value)
		}
		Stages := 0
		loop files, Root . "\*.tmp"
			Stages += 1
		AssertEqual(0, Stages)
	} finally DirDelete(Root, true)
}
Test("HotstringsConfig native source gate: admission source edit survives the true native boundary", _HOSGATE_FinalSourceAdmission.Bind(true))
Test("HotstringsConfig native source gate: unchanged admission still commits", _HOSGATE_FinalSourceAdmission.Bind(false))


_HOSDIRECT_ReadReceiptIsNotBorrowed(CloneOwner) {
	Root := A_Temp . "\ergopti_override_direct_origin_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	FSCreateDirectoryExclusiveStrict(Root)
	Path := Root . "\overrides.toml"
	try {
		A := '[magickey]`ncolor = "#111111"`npriority = 10`n'
		AssertTrue(FSWriteCreateDurable(Path, A))
		Read := _ParseOverrides(Path)
		if CloneOwner {
			Candidate := Read.Clone()
			Candidate["magickey"] := _HotstringsCloneOverrideCategory(Read["magickey"])
		} else
			Candidate := Read
		Candidate["magickey"].Color := "#222222"
		Result := _SaveOverrides(Candidate, 0, 0, Path)
		if CloneOwner {
			AssertEqual(A, FSReadUtf8Exact(Path), "a copied Map cannot borrow the original Map's read authority")
			AssertFalse(Result, "an explicit clone needs its separately captured origin")
			AssertEqual("#111111", Read["magickey"].Color, "the detached clone cannot mutate the actual read owner")
		} else {
			AssertTrue(Result, "the actual read Map retains its direct atomic write-only contract")
			Disk := TOML_ParseDocument(FSReadUtf8Exact(Path))
			AssertEqual("#222222", Disk["magickey"]["color"])
			AssertEqual(10, Disk["magickey"]["priority"])
		}
		Stages := 0
		loop files, Root . "\*.tmp"
			Stages += 1
		AssertEqual(0, Stages)
	} finally DirDelete(Root, true)
}
Test("HotstringsConfig direct source authority: a cloned Map cannot borrow read ownership", _HOSDIRECT_ReadReceiptIsNotBorrowed.Bind(true))
Test("HotstringsConfig direct source authority: the actual read Map remains writable", _HOSDIRECT_ReadReceiptIsNotBorrowed.Bind(false))


_HOLACK_DefaultNeedsDurableAck(Mode) {
	global Features, ConfigurationFile, _HotstringsOverrides, _HotstringsOverridesPath
	global _HotstringsLegacyDelimiters, _HotstringsCommonOverrideAdmitted, HotstringGroupConfig
	Gates := MasterGateState()
	Saved := {features: Features, overrides: _HotstringsOverrides, path: _HotstringsOverridesPath,
		legacy: _HotstringsLegacyDelimiters, common: HotstringsCommonOverrideAdmitted(),
		groups: HotstringGroupConfig, initialized: Gates["initialized"]}
	Root := A_Temp . "\ergopti_legacy_default_ack_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	FSCreateDirectoryExclusiveStrict(Root)
	Path := Root . "\overrides.toml"
	Blocker := 0
	try {
		Features := Features.Clone(), Features["hotstrings"] := Features["hotstrings"].Clone()
		Features["hotstrings"][ConfigLeaf.EXPANSION_DELAY] := 0.75
		Gates["initialized"] := false
		HotstringGroupConfig := HotstringGroupConfig.Clone()
		HasDefault := Mode != "no-default-lease-control"
		Source := (HasDefault ? "[_global]`ndelay = 1.500`n" : "")
			. '[magickey]`ndelay = 2.000`ncolor = "#123456"`n'
		AssertTrue(FSWriteCreateDurable(Path, Source))
		HotstringsConfigInit(Path)
		ConfigBefore := FSReadUtf8Exact(ConfigurationFile)
		AssertEqual(0.75, TOML_ParseDocument(ConfigBefore)["hotstrings"]["expansion_delay"])
		Held := Mode == "base-lease-refusal" || Mode == "base-refusal-color" || Mode == "no-default-lease-control" || Mode == "explicit-after-base-refusal"
		if Held {
			Blocker := _ConfigWriteLeaseTryAcquire(ConfigurationFile, "independent-config-owner-during-legacy-default")
			AssertTrue(Blocker is Object, "a real separate config writer must own the exact destination")
		} else if Mode == "explicit-after-override-refusal" {
			Blocker := _ConfigWriteLeaseTryAcquire(Path, "independent-override-owner-after-base-ack")
			AssertTrue(Blocker is Object)
		}
		State := {Calls: 0}
		RefuseBase(Seconds) {
			State.Calls += 1
			AssertEqual(1.5, Seconds)
			if Mode == "sibling-base-commit"
				AssertTrue(WriteFeatureV2(Features, ConfigKey.HOTSTRINGS_EXPANSION_DELAY, 2.25), "the sibling really commits a different base through the native writer")
			return false
		}
		Result := Mode == "seam-base-refusal" || Mode == "sibling-base-commit" ? HotstringsOverridesBoot(RefuseBase) : HotstringsOverridesBoot()
		if Mode == "explicit-after-base-refusal" || Mode == "explicit-after-override-refusal" {
			AssertFalse(Result, "the first migration must observe the genuine held destination")
			AssertEqual(Source, FSReadUtf8Exact(Path))
			if Mode == "explicit-after-override-refusal"
				AssertEqual(1.5, TOML_ParseDocument(FSReadUtf8Exact(ConfigurationFile))["hotstrings"]["expansion_delay"], "the base really acknowledged before override retirement was refused")
			else
				AssertEqual(ConfigBefore, FSReadUtf8Exact(ConfigurationFile))
			AssertTrue(_ConfigWriteLeaseRelease(Blocker))
			Blocker := 0
			AssertTrue(HotstringsSetBaseDelay(2.25), "an explicit newer choice must finish pending legacy work before committing")
			AssertEqual(2.25, TOML_ParseDocument(FSReadUtf8Exact(ConfigurationFile))["hotstrings"]["expansion_delay"])
			; Reconstruct the effective base from its actual durable image and run
			; the real startup readers again, rather than trusting the RAM mirror.
			Features["hotstrings"][ConfigLeaf.EXPANSION_DELAY] := TOML_ParseDocument(FSReadUtf8Exact(ConfigurationFile))["hotstrings"]["expansion_delay"]
			HotstringsConfigInit(Path)
			AssertTrue(HotstringsOverridesBoot())
			AssertEqual(2.25, TOML_ParseDocument(FSReadUtf8Exact(ConfigurationFile))["hotstrings"]["expansion_delay"], "fresh boot cannot resurrect the older default after the explicit choice acknowledged")
			AssertEqual(2.25, HotstringsBaseDelay())
			AssertFalse(TOML_ParseDocument(FSReadUtf8Exact(Path)).Has("_global"))
			AssertEqual(2.75, HotstringsResolve("magickey", "").Delay, "the category retains its relative distance through pending work and the later base change")
		} else if Mode == "sibling-base-commit" {
			AssertFalse(Result)
			AssertEqual(1, State.Calls)
			AssertEqual(2.25, TOML_ParseDocument(FSReadUtf8Exact(ConfigurationFile))["hotstrings"]["expansion_delay"])
			AssertEqual(2.25, HotstringsBaseDelay(), "the failed old migration cannot overwrite the sibling's freshly committed base in the same Feature node")
			AssertEqual(Source, FSReadUtf8Exact(Path))
		} else if Mode == "base-success-control" {
			AssertTrue(Result, "the genuine unblocked cross-file migration must complete")
			AssertEqual(1.5, TOML_ParseDocument(FSReadUtf8Exact(ConfigurationFile))["hotstrings"]["expansion_delay"])
			AssertEqual(1.5, HotstringsBaseDelay())
			Disk := TOML_ParseDocument(FSReadUtf8Exact(Path))
			AssertFalse(Disk.Has("_global"))
			AssertEqual(0.5, Disk["magickey"]["delay_offset"])
		} else if Mode == "no-default-lease-control" {
			AssertTrue(Result, "a category-only migration requires no config.toml write")
			AssertEqual(ConfigBefore, FSReadUtf8Exact(ConfigurationFile))
			Disk := TOML_ParseDocument(FSReadUtf8Exact(Path))
			AssertFalse(Disk.Has("_global"))
			AssertEqual(1.25, Disk["magickey"]["delay_offset"])
		} else {
			AssertEqual(ConfigBefore, FSReadUtf8Exact(ConfigurationFile), "the real refused destination write cannot have committed a new base")
			if Held
				AssertTrue(_ConfigWriteLeaseOwns(Blocker, ConfigurationFile), "the genuine competing config owner stays held")
			if Mode == "base-refusal-color" {
				SavedColor := HotstringsSetOverride("magickey", "", "color", "#abcdef")
				Disk := TOML_ParseDocument(FSReadUtf8Exact(Path))
				AssertTrue(Disk.Has("_global"), "a later unrelated save cannot erase a default whose destination never acknowledged it")
				AssertEqual(1.5, Disk["_global"]["delay"])
				if SavedColor
					AssertEqual("#abcdef", Disk["magickey"]["color"])
				else
					AssertEqual(Source, FSReadUtf8Exact(Path))
			} else
				AssertEqual(Source, FSReadUtf8Exact(Path), "failed cross-file default migration must retain its exact legacy source for next boot")
			AssertFalse(Result, "the migration cannot acknowledge retirement after its default destination refused")
			if Mode == "seam-base-refusal"
				AssertEqual(1, State.Calls)
		}
		if Mode == "base-success-control" || Mode == "no-default-lease-control" {
			Fresh := _ParseOverrides(Path)
			HotstringsOverridesApplyBase(Fresh)
			AssertEqual(2.0, Fresh["magickey"].Delay, "the category intent survives a genuine next load against the persisted base")
		}
	} finally {
		if Blocker is Object
			_ConfigWriteLeaseRelease(Blocker)
		Features := Saved.features, _HotstringsOverrides := Saved.overrides, _HotstringsOverridesPath := Saved.path
		_HotstringsLegacyDelimiters := Saved.legacy, _HotstringsCommonOverrideAdmitted := Saved.common
		HotstringGroupConfig := Saved.groups, Gates["initialized"] := Saved.initialized
		HotstringsResolveBumpGen()
		DirDelete(Root, true)
	}
}
for _HOLACK_Mode in ["base-lease-refusal", "base-refusal-color", "seam-base-refusal", "base-success-control", "no-default-lease-control"]
	Test("HotstringsConfig legacy default durable ACK: " . _HOLACK_Mode,
		_HTBS_Run.Bind("legacy-default-ack-" . _HOLACK_Mode,
			"[hotstrings]`nexpansion_delay = 0.750`n", _HOLACK_DefaultNeedsDurableAck.Bind(_HOLACK_Mode)))

_HOUP_PublicBaseKeepsEffectiveDuration(Mode) {
	global Features, ConfigurationFile, TICK_MAX_DURATION_MS, LastSentCharacterKeyTime
	global _HotstringsOverrides, _HotstringsOverridesPath, _HotstringsLegacyDelimiters
	global _HotstringsCommonOverrideAdmitted, HotstringGroupConfig
	Gates := MasterGateState()
	Saved := {features: Features, overrides: _HotstringsOverrides, path: _HotstringsOverridesPath,
		legacy: _HotstringsLegacyDelimiters, common: HotstringsCommonOverrideAdmitted(),
		groups: HotstringGroupConfig, initialized: Gates["initialized"], times: LastSentCharacterKeyTime}
	Root := A_Temp . "\ergopti_delay_upper_domain_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Path := Root . "\overrides.toml"
	Created := false
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := (Creation is Integer) && Creation == 1
		AssertTrue(Created, "the fixture must affirmatively acquire its exclusive root before any write")
		Features := Features.Clone(), Features["hotstrings"] := Features["hotstrings"].Clone()
		Features["hotstrings"][ConfigLeaf.EXPANSION_DELAY] := 0.75
		Gates["initialized"] := false
		HotstringGroupConfig := HotstringGroupConfig.Clone()
		LastSentCharacterKeyTime := LastSentCharacterKeyTime.Clone()
		HotstringsConfigInit(Path)
		AssertTrue(HotstringsOverridesBoot())
		InitialDelay := Mode == "unlimited-control" ? 0 : Mode == "zero-offset-control" ? 0.75 : 1.0
		AssertTrue(HotstringsSetOverride("magickey", "", "delay", InitialDelay), "the real public category writer must produce the initial offset")
		AssertTrue(HotstringsSetOverride("magickey", "text_expansion_symbols", "delay", InitialDelay), "the real public section writer must produce the initial offset")
		Source := FSReadUtf8Exact(Path)
		Before := FSReadUtf8Exact(ConfigurationFile)
		Maximum := TICK_MAX_DURATION_MS / 1000
		Base := Mode == "below-cap-control" ? Maximum - 1.0 : Maximum
		AssertTrue(TickTryDurationMsFromSeconds(Base, &BaseMs), "the exact UI-bound public setter input must be valid")
		Committed := HotstringsSetBaseDelay(Base)
		if !Committed {
			AssertEqual("overflow", Mode, "valid controls must not be rejected conservatively")
			AssertEqual(Before, FSReadUtf8Exact(ConfigurationFile), "a safe refusal cannot persist only the invalid base transition")
			AssertEqual(0.75, HotstringsBaseDelay())
			AssertEqual(Source, FSReadUtf8Exact(Path))
			return
		}
		AssertEqual(Base, TOML_ParseDocument(FSReadUtf8Exact(ConfigurationFile))["hotstrings"]["expansion_delay"], "the real config writer acknowledged the base")
		for Section in ["", "text_expansion_symbols"] {
			Resolved := HotstringsResolve("magickey", Section)
			AssertTrue(TickTryDurationMsFromSeconds(Resolved.Delay, &EffectiveMs), "an acknowledged valid base cannot make an existing override permanently expire outside the engine duration domain")
			Now := A_TickCount
			LastSentCharacterKeyTime["x"] := Now
			AssertFalse(IsTimeActivationExpired("x", Resolved.Delay, Now), "the actual engine time gate must accept a previous scalar sent now")
		}
		AssertEqual(Source, FSReadUtf8Exact(Path), "a base rebase must not destroy the stored relative intention")
		AssertTrue(HotstringsSetBaseDelay(0.75))
		Expected := Mode == "unlimited-control" ? 0 : Mode == "zero-offset-control" ? 0.75 : 1.0
		AssertEqual(Expected, HotstringsResolve("magickey", "").Delay, "returning the base restores the original offset rather than persisting an upper clamp")
		AssertEqual(Expected, HotstringsResolve("magickey", "text_expansion_symbols").Delay)
		AssertEqual(Source, FSReadUtf8Exact(Path))
	} finally {
		Features := Saved.features, _HotstringsOverrides := Saved.overrides, _HotstringsOverridesPath := Saved.path
		_HotstringsLegacyDelimiters := Saved.legacy, _HotstringsCommonOverrideAdmitted := Saved.common
		HotstringGroupConfig := Saved.groups, Gates["initialized"] := Saved.initialized
		LastSentCharacterKeyTime := Saved.times
		HotstringsResolveBumpGen()
		if Created
			DirDelete(Root, true)
	}
}
for _HOUP_Mode in ["overflow", "below-cap-control", "zero-offset-control", "unlimited-control"]
	Test("HotstringsConfig public base upper duration: " . _HOUP_Mode,
		_HTBS_Run.Bind("upper-duration-" . _HOUP_Mode, "[hotstrings]`nexpansion_delay = 0.750`n",
			_HOUP_PublicBaseKeepsEffectiveDuration.Bind(_HOUP_Mode)))

Test("HotstringsConfig legacy default durable ACK: sibling-base-commit",
	_HTBS_Run.Bind("legacy-default-ack-sibling-base-commit", "[hotstrings]`nexpansion_delay = 0.750`n",
		_HOLACK_DefaultNeedsDurableAck.Bind("sibling-base-commit")))

for _HOLACK_PendingMode in ["explicit-after-base-refusal", "explicit-after-override-refusal"]
	Test("HotstringsConfig legacy default durable ACK: " . _HOLACK_PendingMode,
		_HTBS_Run.Bind("legacy-default-ack-" . _HOLACK_PendingMode, "[hotstrings]`nexpansion_delay = 0.750`n",
			_HOLACK_DefaultNeedsDurableAck.Bind(_HOLACK_PendingMode)))

_HSAC_LastAuthorizer(ChangeSource) {
	Root := A_Temp . "\ergopti_override_authorizer_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Path := Root . "\overrides.toml", Created := false
	A := '[magickey]`ncolor = "#111111"`npriority = 10`n'
	B := ChangeSource ? '[magickey]`ncolor = "#444444"`npriority = 45`n' : A
	State := {calls: 0, criticalEdits: 0, observedStage: 0, nativeWriteAck: 0}
	Admit() {
		State.calls += 1
		if A_IsCritical {
			Count := 0
			loop files Path . "." . A_ScriptHwnd . "-*.tmp", "F"
				Count += 1
			if Count {
				State.observedStage += Count
				State.nativeWriteAck := FSWriteDurable(Path, B)
				if State.nativeWriteAck == 1
					State.criticalEdits += 1
			}
		}
		return 1
	}
	try {
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := (Creation is Integer) && Creation == 1
		AssertTrue(Created)
		AssertEqual(1, FSWriteCreateDurable(Path, A))
		Candidate := _ParseOverrides(Path)
		Candidate["magickey"].ShowTooltip := false
		Result := _SaveOverrides(Candidate, 0, 0, Path, Admit)
		Actual := FSReadUtf8Exact(Path), Disk := TOML_ParseDocument(Actual)
		_TestPrint("# override-last-authorizer change_source=" . ChangeSource . " result=" . Result
			. " calls=" . State.calls . " critical_edits=" . State.criticalEdits
			. " observed_stage=" . State.observedStage . " native_write_ack=" . State.nativeWriteAck
			. " disk_color=" . Disk["magickey"]["color"] . " disk_priority=" . Disk["magickey"]["priority"])
		AssertTrue(State.observedStage > 0, "the real default writer must already own its native candidate stage")
		AssertTrue(State.criticalEdits > 0, "the arbitrary authorizer must reach its actual final Critical callback")
		AssertEqual(1, State.nativeWriteAck, "the competing source image must actually be durably written")
		AssertEqual(ChangeSource ? 45 : 10, Disk["magickey"]["priority"])
		AssertEqual(ChangeSource ? "#444444" : "#111111", Disk["magickey"]["color"])
		if ChangeSource {
			AssertFalse(Result, "an arbitrary final authorizer cannot lend its ACK to an older source image")
			AssertEqual(B, Actual, "the complete image written by the real callback remains authoritative")
		} else {
			AssertTrue(Result, "legacy custom authorization still permits unchanged-source default publication")
			AssertFalse(Disk["magickey"]["show_tooltip"].Value)
		}
	} finally {
		if Created {
			_TOML_InvalidateParseCache(Path)
			Refusals := _TOML_WriteRefusals(), Key := _TOML_WriteRefusalKey(Path)
			if Refusals.Has(Key)
				Refusals.Delete(Key)
			DirDelete(Root, true)
		}
	}
}
for _HSAC_Change in [true, false]
	Test("hotstring override authorization: last arbitrary callback source edit=" . _HSAC_Change
		. " (override-last-authorizer-source)", _HSAC_LastAuthorizer.Bind(_HSAC_Change))

_HSBR_PublicNamespace(ExtensionControl) {
	global _HotstringsOverridesPath, _HotstringsOverrides, _HSResolveGen
	SavedPath := _HotstringsOverridesPath, SavedMap := _HotstringsOverrides, SavedGen := _HSResolveGen
	Root := A_Temp . "\ergopti_override_namespace_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
	Path := Root . "\overrides.toml", Created := false
	Category := ExtensionControl ? "ext.demo" : "ext"
	try {
		AssertFalse(_ConfigFullSaveHasPending())
		Creation := FSCreateDirectoryExclusiveStrict(Root)
		Created := (Creation is Integer) && Creation == 1
		AssertTrue(Created)
		AssertEqual(1, FSWriteCreateDurable(Path, '[rolls]`ncolor = "#111111"`n'))
		_HotstringsOverridesPath := Path
		_HotstringsOverrides := _ParseOverrides(Path)
		AssertEqual("#111111", _HotstringsOverrides["rolls"].Color)
		Before := FSReadBytesStrict(Path)
		Result := HotstringsSetOverride(Category, "", "color", "#222222")
		AfterSetter := FSReadBytesStrict(Path)
		Reloaded := HotstringsConfigReload()
		Retained := _HotstringsOverrides.Has(Category)
		ReloadedColor := Retained ? _HotstringsOverrides[Category].Color : "<absent>"
		NextWrite := HotstringsSetOverride("rolls", "", "priority", 23)
		_TestPrint("# override-reserved-root category=" . Category . " result=" . Result
			. " reload=" . Reloaded . " retained=" . Retained . " reloaded_color=" . ReloadedColor
			. " next_write=" . NextWrite . " before_bytes=" . Before.Size . " setter_bytes=" . AfterSetter.Size)
		AssertTrue(Reloaded, "the actual reload must complete before a persistence roundtrip verdict")
		if Result {
			AssertTrue(Retained, "a durable setter ACK must survive the actual override loader")
			AssertEqual("#222222", ReloadedColor)
		} else {
			AssertFalse(ExtensionControl, "a real extension category remains a supported positive control")
			AssertEqual(Before.Size, AfterSetter.Size)
			AssertEqual(Before.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", Before,
				"Ptr", AfterSetter, "UPtr", Before.Size, "UPtr"), "a reserved unsupported category must refuse before replacing the original source")
		}
		AssertTrue(NextWrite, "a category setter cannot turn its source into an unrepresentable document that blocks unrelated valid changes")
		AssertEqual(23, TOML_ParseDocument(FSReadUtf8Exact(Path))["rolls"]["priority"])
	} finally {
		_HotstringsOverridesPath := SavedPath, _HotstringsOverrides := SavedMap, _HSResolveGen := SavedGen
		if Created {
			_TOML_InvalidateParseCache(Path)
			Refusals := _TOML_WriteRefusals(), Key := _TOML_WriteRefusalKey(Path)
			if Refusals.Has(Key)
				Refusals.Delete(Key)
			DirDelete(Root, true)
		}
	}
}
for _HSBR_Control in [false, true]
	Test("hotstring override reserved namespace: extension_control=" . _HSBR_Control
		. " (override-reserved-root-roundtrip)", _HSBR_PublicNamespace.Bind(_HSBR_Control))


_HSQS_LegacyFiniteIntention(Kind) {
 global Features, _HotstringsOverrides, _HotstringsOverridesPath, HotstringGroupConfig
 global _HotstringsLegacyDelimiters, _HotstringsCommonOverrideAdmitted, LastSentCharacterKeyTime
 Saved := {features: Features, overrides: _HotstringsOverrides, path: _HotstringsOverridesPath,
  groups: HotstringGroupConfig, legacy: _HotstringsLegacyDelimiters, common: HotstringsCommonOverrideAdmitted(),
  times: LastSentCharacterKeyTime}
 Root := A_Temp . "\ergopti_delay_zero_sentinel_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1, 999999)
 Created := FSCreateDirectoryExclusiveStrict(Root)
 AssertEqual(1, Created)
 Path := Root . "\overrides.toml"
 Raw := Kind == "positive-sub-ms" ? "0.0004" : (Kind == "one-ms" ? "0.001" : "0")
 Original := Kind == "positive-sub-ms" ? 0.0004 : (Kind == "one-ms" ? 0.001 : 0)
 try {
  AssertFalse(A_IsSuspended)
  Features := Features.Clone(), Features["hotstrings"] := Features["hotstrings"].Clone()
  Features["hotstrings"][ConfigLeaf.EXPANSION_DELAY] := 0.75
  HotstringGroupConfig := HotstringGroupConfig.Clone()
  _HotstringsOverridesPath := Path, _HotstringsOverrides := Map()
  Source := "[magickey]`ndelay = " . Raw . "`n[magickey.text_expansion_symbols]`ndelay = " . Raw . "`n"
  AssertEqual(1, FSWriteCreateDurable(Path, Source))
  HotstringsConfigInit(Path)
  AssertEqual(Original, _HotstringsOverrides["magickey"].LegacyDelay, "The actual typed TOML reader must admit the complete original finite intention")
  AssertEqual(Original, _HotstringsOverrides["magickey"].Sections["text_expansion_symbols"].LegacyDelay)
  AssertTrue(TickTryDurationMsFromSeconds(Original, &QuantizedMs), "The existing native duration policy admits this source")
  LastSentCharacterKeyTime := Map("a", 1000)
  ExpectedExpired := IsTimeActivationExpired("a", Original, 1002)
  AssertEqual(Original > 0, ExpectedExpired, "The original positive delay is a finite same-tick gate; explicit zero is unlimited")
  AssertTrue(HotstringsSetOverride("magickey", "", "color", "#123456"), "An unrelated real public metadata save must be acknowledged")
  Disk := TOML_ParseDocument(FSReadUtf8Exact(Path))
  AssertEqual("#123456", Disk["magickey"]["color"])
  AssertTrue(HotstringsConfigReload(), "The actual acknowledged image must reload through the genuine override owner")
  for Section in ["", "text_expansion_symbols"] {
   Resolved := HotstringsResolve("magickey", Section)
   ActualExpired := IsTimeActivationExpired("a", Resolved.Delay, 1002)
   _TestPrint("# delay-zero-sentinel kind=" . Kind . " original=" . Raw . " quantized_ms=" . QuantizedMs
    . " section=" . Section . " resolved=" . Resolved.Delay . " expected_expired=" . ExpectedExpired . " actual_expired=" . ActualExpired)
   AssertEqual(Original == 0, Resolved.Delay == 0, "Millisecond quantization cannot turn an acknowledged finite source into the unlimited sentinel")
   AssertEqual(ExpectedExpired, ActualExpired, "An unrelated save cannot remove the original finite activation gate")
  }
 } finally {
  Features := Saved.features, _HotstringsOverrides := Saved.overrides
  _HotstringsOverridesPath := Saved.path, HotstringGroupConfig := Saved.groups
  _HotstringsLegacyDelimiters := Saved.legacy, _HotstringsCommonOverrideAdmitted := Saved.common
  LastSentCharacterKeyTime := Saved.times
  HotstringsResolveBumpGen()
  _TOML_InvalidateParseCache(Path)
  if Created
   DirDelete(Root, true)
 }
}
for _HSQS_Kind in ["positive-sub-ms", "one-ms", "explicit-zero"]
 Test("Hotstring delay quantization preserves its zero sentinel: " . _HSQS_Kind . " (hotstring-delay-zero-sentinel-domain)", _HSQS_LegacyFiniteIntention.Bind(_HSQS_Kind))
