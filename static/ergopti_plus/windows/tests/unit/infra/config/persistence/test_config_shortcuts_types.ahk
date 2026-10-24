; static/ergopti_plus/windows/tests/unit/infra/config/persistence/test_config_shortcuts_types.ahk

; ==============================================================================
; MODULE: Metrics Config Type Boundary Tests
; DESCRIPTION:
; Ensures the second metrics reader cannot reinterpret values already rejected
; by the manifest-backed TOML loader or publish a prefix before a later error.
; ==============================================================================

_CSTT_WriteConfig(Path, Body, Header := "[metrics]") {
	if FileExist(Path)
		FileDelete(Path)
	FileAppend(Header . "`n" . Body . "`n", Path, "UTF-8")
}

TestConfigShortcutsRejectsEveryInvalidScalarType() {
	global _ConfigDir, _AhkSubDir
	SavedConfigDir := _ConfigDir
	SavedAhkSubDir := _AhkSubDir
	TestDir := A_Temp . "\ergopti_cs_types_" . A_TickCount . "_" . A_ScriptHwnd . "\"
	DirCreate(TestDir)
	try {
		_ConfigDir := TestDir
		_AhkSubDir := ""
		Path := CS_GetTomlPath()
		Cases := [
			["enabled", '"false"'],
			["private_filter_enabled", '""'],
			["secure_filter_enabled", '""'],
			["system_auth_filter_enabled", "-1"],
			["encrypt", '"true"'],
			["disabled_apps", '"chrome.exe"']
		]
		for Fixture in Cases {
			_CSTT_WriteConfig(Path, Fixture[1] . " = " . Fixture[2])
			Thrown := false
			try CS_Load()
			catch
				Thrown := true
			AssertTrue(Thrown, Fixture[1] . " must reject the wrong TOML type")
		}
	} finally {
		_ConfigDir := SavedConfigDir
		_AhkSubDir := SavedAhkSubDir
		if DirExist(TestDir)
			DirDelete(TestDir, true)
	}
}
Test("metrics config: every field preserves its manifest type (AHK-105)",
	TestConfigShortcutsRejectsEveryInvalidScalarType)

TestConfigShortcutsValidatesBeforePublishing() {
	global _ConfigDir, _AhkSubDir
	SavedConfigDir := _ConfigDir
	SavedAhkSubDir := _AhkSubDir
	SavedEnabled := MetricsShortcuts.enabled
	TestDir := A_Temp . "\ergopti_cs_atomic_" . A_TickCount . "_" . A_ScriptHwnd . "\"
	DirCreate(TestDir)
	try {
		_ConfigDir := TestDir
		_AhkSubDir := ""
		MetricsShortcuts.enabled := true
		_CSTT_WriteConfig(CS_GetTomlPath(),
			'enabled = false`nsecure_filter_enabled = ""')
		Thrown := false
		try CS_Load()
		catch
			Thrown := true
		AssertTrue(Thrown, "an invalid late privacy field must fail the load")
		AssertTrue(MetricsShortcuts.enabled,
			"validation must finish before an earlier field is published")
	} finally {
		MetricsShortcuts.enabled := SavedEnabled
		_ConfigDir := SavedConfigDir
		_AhkSubDir := SavedAhkSubDir
		if DirExist(TestDir)
			DirDelete(TestDir, true)
	}
}
Test("metrics config: validation precedes live publication (AHK-105)",
	TestConfigShortcutsValidatesBeforePublishing)

_CSTT_RetiredShortcutValuesAreUnknown() {
	for Value in ["ctrl+alt+m", 9, false, Map("future", "keep")] {
		Section := Map("metrics_shortcut_typing", Value, "metrics_shortcut_apps", Value,
			"enabled", true)
		Validated := _CS_ValidateMetricsSection(Section)
		AssertFalse(Validated.Has("metrics_shortcut_typing"), "the retired typing field has no live owner")
		AssertFalse(Validated.Has("metrics_shortcut_apps"), "the retired apps field has no live owner")
		AssertTrue(Validated["enabled"], "retirement preserves collection consent validation")
		AssertEqual(Value, Section["metrics_shortcut_typing"], "validation must not mutate unknown data")
	}
}
Test("metrics config: retired bindings are unknown regardless of their historical type", _CSTT_RetiredShortcutValuesAreUnknown)

; Real file reads must use the same grammar as the canonical config reader.
; Losing the section header silently re-enables recording; losing continuation
; lines turns a valid application opt-out list into a startup type error.
_CSTT_ValidTomlPrivacySettings() {
	global _ConfigDir, _AhkSubDir
	SavedConfigDir := _ConfigDir
	SavedAhkSubDir := _AhkSubDir
	SavedEnabled := MetricsShortcuts.enabled
	SavedApps := MetricsFilters.disabled_apps
	SavedFilters := Map()
	for Name in ["private_browsing", "secure_field", "system_auth", "encrypt"]
		SavedFilters[Name] := MetricsFilters.%Name%
	TestDir := A_Temp . "\ergopti_cs_grammar_" . A_TickCount . "_" . A_ScriptHwnd . "\"
	DirCreate(TestDir)
	try {
		_ConfigDir := TestDir
		_AhkSubDir := ""
		Path := CS_GetTomlPath()
		Body := "enabled = false`ndisabled_apps = [`n"
			. ' "CHROME.EXE", # excluded browser' . "`n"
			. " 'editor#1.exe',`n] # excluded applications`n"
		_CSTT_WriteConfig(Path, Body, "[metrics] # explicit recording opt-out")
		Data := CS_Read()
		Assert(Data.Has("metrics"), "a commented header must retain the metrics section")
		Section := Data["metrics"]
		AssertEqual(false, Section["enabled"], "the recording opt-out must remain a native false")
		Apps := Section["disabled_apps"]
		Assert(Apps is Array, "a multiline array must remain an array")
		AssertEqual(2, Apps.Length, "comments must not add or discard applications")
		AssertEqual("CHROME.EXE", Apps[1])
		AssertEqual("editor#1.exe", Apps[2], "a hash inside a literal string is data")
		MetricsShortcuts.enabled := true
		CS_Load()
		AssertFalse(MetricsShortcuts.enabled, "a legal TOML header must never re-enable recording")
		AssertEqual(2, MetricsFilters.disabled_apps.Count)
		Assert(MetricsFilters.disabled_apps.Has("chrome.exe"), "the application list must be applied and normalized")
		Assert(MetricsFilters.disabled_apps.Has("editor#1.exe"), "the literal application name must survive load")
	} finally {
		MetricsShortcuts.enabled := SavedEnabled
		MetricsFilters.disabled_apps := SavedApps
		for Name, Value in SavedFilters
			MetricsFilters.%Name% := Value
		_ConfigDir := SavedConfigDir
		_AhkSubDir := SavedAhkSubDir
		if DirExist(TestDir)
			DirDelete(TestDir, true)
	}
}
Test("metrics config: commented headers and multiline opt-outs apply (metrics-toml-grammar)",
	_CSTT_ValidTomlPrivacySettings)

_CSTT_SemanticPrivacySettings(Shape, Enabled) {
	global _ConfigDir, _AhkSubDir
	SavedConfigDir := _ConfigDir, SavedAhkSubDir := _AhkSubDir
	SavedEnabled := MetricsShortcuts.enabled
	SavedApps := MetricsFilters.disabled_apps
	SavedFilters := Map()
	for Name in ["private_browsing", "secure_field", "system_auth", "encrypt"]
		SavedFilters[Name] := MetricsFilters.%Name%
	TestDir := A_Temp . "\ergopti_cs_semantic_" . A_TickCount . "_" . A_ScriptHwnd . "\"
	DirCreate(TestDir)
	try {
		_ConfigDir := TestDir, _AhkSubDir := ""
		Literal := Enabled ? "true" : "false"
		Apps := '["CHROME.EXE", "editor#1.exe"]'
		switch Shape {
			case "dotted": Source := "metrics.enabled = " . Literal
				. "`nmetrics.disabled_apps = " . Apps . "`n"
			case "inline": Source := "metrics = { enabled = " . Literal
				. ", disabled_apps = " . Apps . " }`n"
			case "quoted": Source := '["metrics"]`nenabled = ' . Literal
				. "`ndisabled_apps = " . Apps . "`n"
			default: throw ValueError("Unknown metrics semantic fixture")
		}
		Path := CS_GetTomlPath()
		AssertTrue(FSWrite(Path, Source))
		Data := CS_Read()
		AssertTrue(Data.Has("metrics"), "the real metrics reader must retain the semantic namespace")
		AssertEqual(Enabled, Data["metrics"]["enabled"])
		AssertTrue(Data["metrics"]["disabled_apps"] is Array)
		MetricsShortcuts.enabled := !Enabled
		CS_Load()
		AssertEqual(Enabled, MetricsShortcuts.enabled, "authored consent must reach the live metrics owner")
		AssertEqual(2, MetricsFilters.disabled_apps.Count)
		AssertTrue(MetricsFilters.disabled_apps.Has("chrome.exe"))
		AssertTrue(MetricsFilters.disabled_apps.Has("editor#1.exe"))
		AssertEqual(Source, FSReadUtf8Exact(Path), "reading semantic settings must not rewrite their source")
	} finally {
		MetricsShortcuts.enabled := SavedEnabled
		MetricsFilters.disabled_apps := SavedApps
		for Name, Value in SavedFilters
			MetricsFilters.%Name% := Value
		_ConfigDir := SavedConfigDir, _AhkSubDir := SavedAhkSubDir
		if DirExist(TestDir)
			DirDelete(TestDir, true)
	}
}
for Shape in ["dotted", "inline", "quoted"] {
	Test("metrics config: " . Shape . " opt-in reaches runtime (metrics-semantic-source)",
		_CSTT_SemanticPrivacySettings.Bind(Shape, true))
	Test("metrics config: " . Shape . " opt-out reaches runtime (metrics-semantic-source)",
		_CSTT_SemanticPrivacySettings.Bind(Shape, false))
}
