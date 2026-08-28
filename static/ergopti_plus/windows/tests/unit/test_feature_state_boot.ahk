; static/ergopti_plus/windows/tests/unit/test_feature_state_boot.ahk

; ============================================================================
; MODULE: Feature-State Boot Regression Tests
; DESCRIPTION:
; Each case launches the isolated production smoke harness.  This keeps
; boot-only globals out of the shared test runner while proving that the exact
; ReadScriptConfig / ReadCategoryEnabled path compiles and executes in a fresh
; AutoHotkey process.
; ============================================================================

_FeatureStateBootRun(Fixture) {
    Harness := A_ScriptDir . "\startup\feature_state_boot_smoke.ahk"
    AssertTrue(FileExist(Harness) != "", "feature-state startup harness must exist")
    Command := Chr(34) . A_AhkPath . Chr(34) . " " . Chr(34) . Harness . Chr(34) . " " . Fixture
    ExitCode := RunWait(Command, A_ScriptDir, "Hide")
    AssertEqual(0, ExitCode, "feature-state startup fixture must exit cleanly: " . Fixture)
}

_FeatureStateBootRunFails(Fixture) {
	Harness := A_ScriptDir . "\startup\feature_state_boot_smoke.ahk"
	AssertTrue(FileExist(Harness) != "", "feature-state startup harness must exist")
	Command := Chr(34) . A_AhkPath . Chr(34) . " " . Chr(34) . Harness . Chr(34) . " " . Fixture
	ExitCode := RunWait(Command, A_ScriptDir, "Hide")
	AssertEqual(1, ExitCode,
		"invalid feature-state startup fixture must fail before registration: " . Fixture)
}

TestFeatureStateBootParsedConfig() {
    _FeatureStateBootRun("parsed")
}
Test("Feature-state startup: parses and applies a valid user configuration (feature-state-boot-parsed)", TestFeatureStateBootParsedConfig)

TestFeatureStateBootMissingSections() {
    _FeatureStateBootRun("missing")
}
Test("Feature-state startup: absent optional sections keep defaults (feature-state-boot-missing)", TestFeatureStateBootMissingSections)

TestFeatureStateBootMalformedCache() {
    _FeatureStateBootRun("malformed")
}
Test("Feature-state startup: malformed scalar sections cannot abort boot (feature-state-boot-malformed)", TestFeatureStateBootMalformedCache)

TestFeatureStateBootNonMapCache() {
    _FeatureStateBootRun("non_map")
}
Test("Feature-state startup: non-Map cache cannot abort boot (feature-state-boot-non-map)", TestFeatureStateBootNonMapCache)

TestFeatureStateBootRejectsInvalidTrigger() {
	_FeatureStateBootRunFails("empty_trigger")
	_FeatureStateBootRunFails("long_trigger")
	_FeatureStateBootRun("unicode_trigger")
}
Test("feature-state startup: invalid trigger_char fails closed (AHK-060)",
	TestFeatureStateBootRejectsInvalidTrigger)

TestFeatureStateBootRejectsMultiTrigger() {
	_FeatureStateBootRunFails("multi_trigger")
}
Test("feature-state startup: trigger_char is exactly one code point (AHK-070)",
	TestFeatureStateBootRejectsMultiTrigger)

TestFeatureStateBootRejectsInvalidScalarOverrides() {
	_FeatureStateBootRunFails("invalid_repeat_number")
	_FeatureStateBootRunFails("invalid_repeat_string")
	_FeatureStateBootRunFails("invalid_kana")
}
Test("feature-state startup: scalar overrides preserve schema types (AHK-095)",
	TestFeatureStateBootRejectsInvalidScalarOverrides)

TestFeatureStateBootSourceWiring() {
    SourcePath := A_ScriptDir . "\..\ErgoptiPlus.ahk"
    Source := FileRead(SourcePath, "UTF-8")
    HelpersPos := InStr(Source, "#Include infra/toml/toml_helpers.ahk")
    StatePos := InStr(Source, "#Include infra/feature_state.ahk")
    ConfigIoPos := InStr(Source, "#Include infra/config_io.ahk")
    AssertTrue(HelpersPos > 0 && StatePos > 0 && ConfigIoPos > 0,
        "driver must include the configuration helpers, feature state, and config I/O")
    AssertTrue(HelpersPos < StatePos && StatePos < ConfigIoPos,
        "driver include order must make configuration helpers available to feature state and category normalization available before auto-execute calls")
    FeatureStateSource := FileRead(A_ScriptDir . "\..\infra\feature_state.ahk", "UTF-8")
    AssertTrue(InStr(FeatureStateSource, "return IniCacheGet(Cache, Section, Key)") > 0,
        "feature-state must call the configuration accessor directly")
    AssertTrue(InStr(FeatureStateSource, 'Func("IniCacheGet").Call') = 0,
        "feature-state must not use the boot-fragile Func(...).Call accessor")
}
Test("Feature-state startup: production include order and direct loader dependency stay wired (feature-state-boot-wiring)", TestFeatureStateBootSourceWiring)
