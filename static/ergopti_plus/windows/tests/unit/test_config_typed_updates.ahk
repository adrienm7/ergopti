; tests/unit/test_config_typed_updates.ahk

; ==============================================================================
; MODULE: Configuration Typed Update Tests
; DESCRIPTION:
; Exercises schema-owned Boolean intent through persistence and strict reload.
; Native AHK integers alone cannot distinguish TOML booleans from numbers.
;
; FEATURES & RATIONALE:
; 1. Opposite reload baselines expose rejected writer output.
; 2. Numeric controls and mixed enums prevent blanket zero/one conversion.
; 3. Temporary files keep personal configuration outside the test boundary.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================
; ==================================
; ======= 1/ Typed Roundtrip =======
; ==================================
; ==================================

_CTU_NewPath() {
	static Sequence := 0
	Sequence += 1
	return A_Temp . "\ergopti-config-typed-" . A_ScriptHwnd . "-"
		. A_TickCount . "-" . Sequence . ".toml"
}

_CTU_Roundtrip(BooleanValue, EnumValue, Duration) {
	global ConfigurationFile
	OldPath := ConfigurationFile
	Path := _CTU_NewPath()
	try {
		ConfigurationFile := Path
		Source := Map("layout", Map("ergopti_base", BooleanValue),
			"script", Map("alt_gr_is_kana_remap", EnumValue),
			"hotstrings", Map("autocorrection", Map("accents",
				Map("enabled", BooleanValue, "time_activation_seconds", Duration))))
		Updates := []
		_CollectFeatureUpdates(Updates, "", Source)
		AssertTrue(ConfigCommitUpdates(Path, Updates, "typed config regression",
			0, (*) => 0), "the actual configuration writer must acknowledge publication")
		Target := ManifestBuildFeaturesMap()
		Target["layout"]["ergopti_base"] := !BooleanValue
		Target["script"]["alt_gr_is_kana_remap"] := EnumValue is String ? false : "auto"
		Accents := Target["hotstrings"]["autocorrection"]["accents"]
		Accents["enabled"] := !BooleanValue
		Accents["time_activation_seconds"] := 2
		AssertEqual(4, ApplyConfigToml(Target, Path),
			"strict reload must accept every value emitted by the config writer")
		AssertEqual(BooleanValue, Target["layout"]["ergopti_base"])
		AssertEqual(BooleanValue, Accents["enabled"])
		AssertEqual(EnumValue, Target["script"]["alt_gr_is_kana_remap"])
		AssertEqual(Type(EnumValue), Type(Target["script"]["alt_gr_is_kana_remap"]))
		AssertEqual(Duration, Accents["time_activation_seconds"])
		AssertTrue(Accents["time_activation_seconds"] is Integer)
		AssertTrue(Source["layout"]["ergopti_base"] is Integer,
			"persistence must not replace runtime values with serialization wrappers")
	} finally {
		ConfigurationFile := OldPath
		FSDelete(Path)
	}
}
Test("config: false Boolean and numeric zero survive strict reload "
	. "(config-typed-update-false)", _CTU_Roundtrip.Bind(false, false, 0))
Test("config: true Boolean and numeric one survive strict reload "
	. "(config-typed-update-true)", _CTU_Roundtrip.Bind(true, true, 1))
Test("config: mixed enum string retains its type "
	. "(config-typed-update-enum)", _CTU_Roundtrip.Bind(false, "auto", 1))

_CTU_PreparationIsolation() {
	Updates := [
		{ Section: "layout", Key: "ergopti_base", Value: false, marker: "retained" },
		{ Section: "hotstrings.personal.fixture", Key: "enabled", Value: true },
		{ Section: "script", Key: "alt_gr_is_kana_remap", Value: TOML_Bool(false) },
		{ Section: "hotstrings.personal.fixture", Key: "time_activation_seconds", Value: 1 },
		{ Section: "layout", Key: "ergopti_base", Delete: 1 }
	]
	Typed := _ConfigPrepareTypedUpdates(Updates)
	Again := _ConfigPrepareTypedUpdates(Typed)
	for Index in [1, 2, 3] {
		AssertTrue(Typed[Index].Value is TOML_Bool)
		AssertEqual(TOML_RenderValue(Typed[Index].Value), TOML_RenderValue(Again[Index].Value))
	}
	AssertEqual("retained", Typed[1].marker)
	AssertTrue(Typed[4].Value is Integer)
	AssertEqual(1, Typed[4].Value)
	AssertEqual(1, Typed[5].Delete)
	AssertFalse(Typed[5].HasOwnProp("Value"))
	Typed[1].marker := "changed"
	AssertEqual("retained", Updates[1].marker)
	AssertTrue(Updates[1].Value is Integer)
	AssertTrue(Updates[2].Value is Integer)
}
Test("config: typed updates are detached and idempotent "
	. "(config-typed-update-isolation)", _CTU_PreparationIsolation)

_CTU_GatewayScopesSchemaAndRejectsInvalidValues() {
	global ConfigurationFile
	OldPath := ConfigurationFile
	Path := _CTU_NewPath()
	GenericPath := _CTU_NewPath()
	Seen := []
	Writer := (Target, Updates) => (Seen.Push(Updates), TOML_BatchWrite(Target, Updates))
	try {
		ConfigurationFile := Path
		Update := [{ Section: "layout", Key: "ergopti_base", Value: 1 }]
		AssertTrue(ConfigCommitUpdates(GenericPath, Update, "generic TOML", Writer, (*) => 0))
		AssertTrue(Seen[1][1].Value is Integer,
			"a generic TOML file must not inherit the configuration schema")
		AssertTrue(RegExMatch(FSRead(GenericPath), "m)^ergopti_base = 1$"))
		AssertTrue(ConfigCommitUpdates(StrUpper(Path), Update, "configuration alias", Writer, (*) => 0))
		AssertTrue(Seen[2][1].Value is TOML_Bool,
			"canonical path identity must type the injected writer's input too")
		AssertTrue(RegExMatch(FSRead(Path), "m)^ergopti_base = true$"))
		Before := FSRead(Path)
		Malformed := TOML_Bool(false)
		Malformed.Value := "auto"
		for Invalid in ["false", "0", 2, 0.0, Malformed] {
			AssertFalse(ConfigCommitUpdates(Path,
				[{ Section: "layout", Key: "ergopti_base", Value: Invalid }],
				"invalid Boolean", Writer, (*) => 0))
			AssertEqual(2, Seen.Length, "invalid Boolean intent must fail before writer invocation")
			AssertEqual(Before, FSRead(Path), "refusal must retain the original file")
		}
		Probe := _ConfigWriteLeaseTryAcquire(Path, "typed regression")
		try AssertTrue(Probe is Object, "refusal must release the write owner")
		finally {
			if Probe is Object
				_ConfigWriteLeaseRelease(Probe)
		}
	} finally {
		ConfigurationFile := OldPath
		FSDelete(Path)
		FSDelete(GenericPath)
	}
}
Test("config: schema typing is path-owned and invalid booleans fail before writing "
	. "(config-typed-update-gateway)", _CTU_GatewayScopesSchemaAndRejectsInvalidValues)
