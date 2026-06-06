; static/ergopti_plus/windows/tests/test_hotstrings_config.ahk

; ==============================================================================
; MODULE: Hotstrings Config Tests
; RUN:    AutoHotkey64.exe run_hotstrings_config.ahk  (not this file directly —
;         it has no test framework; run_all.ahk also includes this suite).
; DESCRIPTION:
; Covers the override-file parser, the resolution cascade
; (user.section → user.file → toml.section → toml.file → GLOBAL_DEFAULT_DELAY)
; and the set / clear override mutators implemented in
; ``lib/hotstrings_config.ahk``. The TOML metadata layer is mocked through
; the global ``HotstringGroupConfig`` map populated by
; ``ParseTomlGroupConfig`` so the tests do not depend on the bundled
; hotstring files being present at a specific location during CI.
; ==============================================================================

; Helper — wipe / seed the in-memory state for a single test case.
;
; Pre-seeds ``HotstringGroupConfig`` with empty entries for every category
; the test suite resolves. Without this, ParseTomlGroupConfig would fall
; through to a real file lookup under ``_StaticDir`` and the bundled
; ``static/hotstrings/<category>.toml`` files would smuggle their real
; delay/color into the resolution cascade, breaking the "falls back to
; defaults" assertions. Tests that DO want to exercise toml metadata seed
; their own values via _HCfgTestSeedToml, which overwrites these entries.
_HCfgTestReset() {
    global _HotstringsOverrides, _HotstringsOverridesPath, HotstringGroupConfig
    _HotstringsOverrides := Map()
    _HotstringsOverridesPath := ""   ; disable persistence during tests
    HotstringGroupConfig := Map()
    ; Build a fresh empty config per category so mutations in one test do not
    ; leak into the next (each Sections map must be a distinct instance).
    for Cat in ["rolls", "sfbsreduction", "autocorrection", "distancesreduction", "magickey"] {
        HotstringGroupConfig[Cat] := { Delay: "", Color: "", ShowTooltip: "", Sections: Map() }
    }
}

_HCfgTestSeedToml(Cat, Delay, Color, Sections := unset) {
    global HotstringGroupConfig
    ; ShowTooltip is part of the public Toml config schema (see toml_loader.ahk
    ; ParseTomlGroupConfig — it always materialises a ShowTooltip field, empty
    ; when the toml file does not set the value). The resolution cascade in
    ; hotstrings_config.ahk reads ``TomlCfg.ShowTooltip`` directly, so seeded
    ; test configs MUST expose that property too, otherwise AHK raises a
    ; "no property named ShowTooltip" error during HotstringsResolve.
    Cfg := { Delay: Delay, Color: Color, ShowTooltip: "", Sections: Map() }
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
}





; ============================================================
; ============================================================
; ======= 1/ Override file parser ===========================
; ============================================================
; ============================================================

TestHotstringsConfig_ParseOverridesFileLevel() {
    Path := A_Temp . "\hotstrings_config_test_filelvl.toml"
    try FileDelete(Path)
    FileAppend("[rolls]`ndelay = 0.4`ncolor = `"#abcdef`"`n", Path, "UTF-8")
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
    FileAppend("[rolls.ct]`ndelay = 0.2`ncolor = `"#00838f`"`n", Path, "UTF-8")
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
Test("HotstringsConfig: setOverride rejects fields other than delay/color",
    TestHotstringsConfig_SetOverrideRejectsUnknownField)

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
