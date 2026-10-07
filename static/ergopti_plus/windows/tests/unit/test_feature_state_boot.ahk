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
    Harness := A_ScriptDir . "\support\feature_state_boot_smoke.ahk"
    AssertTrue(FileExist(Harness) != "", "feature-state startup harness must exist")
    Command := Chr(34) . A_AhkPath . Chr(34) . " " . Chr(34) . Harness . Chr(34) . " " . Fixture
	; CI-only observation: keep the actual RunWait transport and native verdict.
	Receipt := Fixture == "script_late_parameter" ? _FeatureStateBootCiReceipt() : ""
	if Receipt != ""
		Command .= " --ci-error-receipt " . Chr(34) . Receipt . Chr(34)
	try {
		ExitCode := RunWait(Command, A_ScriptDir, "Hide")
		Diagnostic := ""
		if Fixture == "script_late_parameter" && ExitCode != 0 {
			Diagnostic := "; child diagnostic unavailable"
			if Receipt != "" {
				try {
					Content := FileRead(Receipt, "UTF-8")
					if Content != "" {
						Content := StrReplace(StrReplace(Content, "`r`n", "`n"), "`r", "`n")
						Diagnostic := "; child diagnostic: " . StrReplace(SubStr(Content, 1, 3000), "`n", " | ")
						if StrLen(Content) > 3000
							Diagnostic .= " [truncated at 3000 characters]"
					}
				}
			}
		}
		AssertEqual(0, ExitCode, "feature-state startup fixture must exit cleanly: " . Fixture . Diagnostic)
		return ExitCode
	} finally {
		; Only an atomically created, task-owned receipt is eligible for disposal.
		if Receipt != ""
			try FileDelete(Receipt)
	}
}

_FeatureStateBootRunFails(Fixture) {
	Harness := A_ScriptDir . "\support\feature_state_boot_smoke.ahk"
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

TestFeatureStateBootUsesManifestMagicSourceDefaults() {
	_FeatureStateBootRun("manifest_defaults")
}
Test("feature-state startup: magic source options are manifest-owned (AHK-097)",
	TestFeatureStateBootUsesManifestMagicSourceDefaults)

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

TestFeatureStateBootRejectsInvalidMagicSourceKeys() {
	_FeatureStateBootRunFails("invalid_source_char")
}
Test("feature-state startup: the magic source character fails closed (AHK-096)",
	TestFeatureStateBootRejectsInvalidMagicSourceKeys)

; The shared [hotstrings] magic_key_source replaced the Windows-only scan code
; (config schema v5). A value naming no candidate key is outdated configuration:
; one warning from the loader and an offer from the cleanup, read as the
; automatic key here and never a boot failure.
TestFeatureStateBootOutdatedMagicSourceKeyReadsAutomatic() {
	_FeatureStateBootRun("outdated_source_key")
	_FeatureStateBootRun("retired_source_scan")
}
Test("feature-state startup: an outdated magic source key reads as the automatic key (magic-key-source)",
	TestFeatureStateBootOutdatedMagicSourceKeyReadsAutomatic)

TestFeatureStateBootRejectsInvalidCategoryGates() {
	_FeatureStateBootRunFails("invalid_category_string")
	_FeatureStateBootRunFails("invalid_category_number")
}
Test("feature-state startup: category gates preserve schema booleans (AHK-099)",
	TestFeatureStateBootRejectsInvalidCategoryGates)

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

TestFeatureStateBootSemanticSources() {
	_FeatureStateBootRun("semantic_root")
	_FeatureStateBootRun("semantic_section")
	_FeatureStateBootRun("semantic_inline")
}
Test("feature-state startup: semantic root and section sources reach actual readers (config-semantic-snapshot)",
	TestFeatureStateBootSemanticSources)


TestFeatureStateBootScriptBindingPublication() {
	_FeatureStateBootRun("script_binding_publication")
}
Test("feature-state startup: actual compiled script declaration publishes a complete binding receipt (script-binding-identity)",
	TestFeatureStateBootScriptBindingPublication)

TestFeatureStateBootTapBindingPublication() {
	_FeatureStateBootRun("tap_binding_publication")
}
Test("feature-state startup: actual compiled tap declarations publish before config consumers (tap-binding-identity)",
	TestFeatureStateBootTapBindingPublication)

TestFeatureStateBootTapBindingSourceWiring() {
	Source := FileRead(A_ScriptDir . "\..\ErgoptiPlus.ahk", "UTF-8")
	State := FileRead(A_ScriptDir . "\..\infra\feature_state.ahk", "UTF-8")
	KeyStatePos := InStr(Source, "#Include adapters/key_state.ahk")
	StatePos := InStr(Source, "#Include infra/feature_state.ahk")
	ApplyPos := InStr(Source, "_BootConfigApplied := ApplyBootConfigToml(")
	GesturePos := InStr(Source, "#Include modules/gestures/init.ahk")
	LaterTapPos := InStr(Source, "#Include infra/tap_keys.ahk")
	TapReadPos := InStr(Source, "TapKeysReadConfig(_IniCache)")
	AssertTrue(KeyStatePos > 0 && StatePos > 0 && ApplyPos > 0 && GesturePos > 0 && LaterTapPos > 0 && TapReadPos > 0,
		"all actual declaration, reader and native prerequisite source bindings must exist")
	AssertTrue(KeyStatePos < StatePos && StatePos < ApplyPos && ApplyPos < GesturePos && GesturePos < LaterTapPos && LaterTapPos < TapReadPos,
		"native declarations precede both config readers while actual tap configuration stays in its original stage")
	IncludePos := InStr(State, "#Include %A_LineFile%\..\tap_keys.ahk")
	PublishPos := InStr(State, "global _TapKeyBindingPublication := ConfigBindingIdentityTapPublication(TAP_KEY_ORDER, TAP_KEY_SCANCODES)")
	AssertTrue(IncludePos > 0 && PublishPos > IncludePos,
		"the exact existing native source publishes only after its ordinary early include")
}
Test("feature-state startup: tap publication source ordering retains the later native read stage (tap-binding-identity)",
	TestFeatureStateBootTapBindingSourceWiring)

; Atomically reserve a fresh private file; a collision never grants ownership.
_FeatureStateBootCiReceipt() {
	static Counter := 0
	Loop 8 {
		Counter += 1
		Path := A_Temp . "\ergopti_feature_state_ci_error_" . DllCall("GetCurrentProcessId")
			. "_" . A_TickCount . "_" . Counter . ".txt"
		Handle := -1
		try {
			Handle := DllCall("kernel32\CreateFileW", "Str", Path, "UInt", 0x40000000,
				"UInt", 0, "Ptr", 0, "UInt", 1, "UInt", 0x80, "Ptr", 0, "Ptr")
			if Handle != -1
				return Path
			if A_LastError != 80 && A_LastError != 183
				return ""
		} catch {
			return ""
		} finally {
			if Handle != -1
				try DllCall("kernel32\CloseHandle", "Ptr", Handle)
		}
	}
	return ""
}
