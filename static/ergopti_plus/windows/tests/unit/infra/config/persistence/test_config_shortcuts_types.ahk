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
	FileAppend("[_meta]`nschema_version = " . ConfigMigrateCurrentVersion()
		. "`n" . Header . "`n" . Body . "`n", Path, "UTF-8")
	Journal := ConfigMigrateBoot(Path)
	AssertTrue(Journal is Map, "the private source requires the real native boot constructor")
	AssertEqual("current", Journal.Get("status", "missing"))
}

_CSTT_SaveRuntime() {
	Filters := Map()
	for Name in ["private_browsing", "secure_field", "system_auth", "encrypt"]
		Filters[Name] := MetricsFilters.%Name%
	return { Enabled: MetricsShortcuts.enabled, Filters: Filters,
		Apps: MetricsFilters.disabled_apps, Cipher: KL_Enc_IsEnabled(),
		Visible: WPMWidget.visible, Colors: WPMWidget.use_colors, Graph: WPMWidget.show_graph }
}

_CSTT_RestoreRuntime(Saved) {
	MetricsShortcuts.enabled := Saved.Enabled
	MetricsFilters.disabled_apps := Saved.Apps
	for Name, Value in Saved.Filters
		MetricsFilters.%Name% := Value
	KL_Enc_SetEnabled(Saved.Cipher)
	WPMWidget.visible := Saved.Visible
	WPMWidget.use_colors := Saved.Colors
	WPMWidget.show_graph := Saved.Graph
}

_CSTT_ExpectedValue(Key) {
	TomlConfigExpectedType(ConfigKey.METRICS, Key, &Entry)
	AssertTrue(Entry is Map, "the fixture must name an actual manifest setting")
	return ManifestDefaultFor(Entry["path"])
}

_CSTT_ActualValue(Key) {
	if Key == ConfigLeaf.ENABLED
		return MetricsShortcuts.enabled
	if Key == ConfigLeaf.DISABLED_APPS
		return MetricsFilters.disabled_apps
	Props := Map(ConfigLeaf.PRIVATE_FILTER_ENABLED, "private_browsing",
		ConfigLeaf.SECURE_FILTER_ENABLED, "secure_field",
		ConfigLeaf.SYSTEM_AUTH_FILTER_ENABLED, "system_auth", ConfigLeaf.ENCRYPT, "encrypt")
	Prop := Props[Key]
	return MetricsFilters.%Prop%
}

TestConfigShortcutsRejectsEveryInvalidScalarType() {
	global _ConfigDir, _AhkSubDir
	SavedConfigDir := _ConfigDir, SavedAhkSubDir := _AhkSubDir
	SavedRuntime := _CSTT_SaveRuntime()
	TestDir := A_Temp . "\ergopti_cs_types_" . A_TickCount . "_" . A_ScriptHwnd . "\"
	DirCreate(TestDir)
	try {
		_ConfigDir := TestDir, _AhkSubDir := ""
		Cases := [
			["enabled", '"false"'],
			["private_filter_enabled", '""'],
			["secure_filter_enabled", '""'],
			["system_auth_filter_enabled", "-1"],
			["encrypt", '"true"'],
			["disabled_apps", '"chrome.exe"']
		]
		for Index, Fixture in Cases {
			_ConfigDir := TestDir . Index . "\"
			Path := CS_GetTomlPath()
			_CSTT_WriteConfig(Path, Fixture[1] . " = " . Fixture[2])
			Before := FSReadUtf8Exact(Path)
			MetricsShortcuts.enabled := true
			MetricsFilters.disabled_apps := Map("previous.exe", true)
			CS_Load()
			Expected := _CSTT_ExpectedValue(Fixture[1])
			Actual := _CSTT_ActualValue(Fixture[1])
			if Expected is Array
				AssertEqual(Expected.Length, Actual.Count, "an outdated application list keeps its manifest value")
			else
				AssertEqual(Expected, Actual, Fixture[1] . " must ignore the outdated value without aborting startup")
			AssertEqual(Before, FSReadUtf8Exact(Path), "an outdated read must preserve the exact authored file")
		}
	} finally {
		_CSTT_RestoreRuntime(SavedRuntime)
		_ConfigDir := SavedConfigDir, _AhkSubDir := SavedAhkSubDir
		if DirExist(TestDir)
			DirDelete(TestDir, true)
	}
}
Test("metrics config: every field preserves its manifest type (AHK-105)",
	TestConfigShortcutsRejectsEveryInvalidScalarType)

TestConfigShortcutsValidatesBeforePublishing() {
	SavedEnabled := MetricsShortcuts.enabled
	try {
		MetricsShortcuts.enabled := true
		Thrown := false
		try _CS_ValidateMetricsSection(Map(ConfigLeaf.ENABLED, false,
			ConfigLeaf.SECURE_FILTER_ENABLED, ""))
		catch TypeError
			Thrown := true
		AssertTrue(Thrown, "a malformed in-memory candidate must still fail strict validation")
		AssertTrue(MetricsShortcuts.enabled,
			"candidate validation must never publish a prefix of the proposed values")
	} finally {
		MetricsShortcuts.enabled := SavedEnabled
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
	static FixtureSequence := 0
	FixtureSequence += 1
	global _ConfigDir, _AhkSubDir
	SavedConfigDir := _ConfigDir, SavedAhkSubDir := _AhkSubDir
	SavedEnabled := MetricsShortcuts.enabled
	SavedApps := MetricsFilters.disabled_apps
	SavedFilters := Map()
	for Name in ["private_browsing", "secure_field", "system_auth", "encrypt"]
		SavedFilters[Name] := MetricsFilters.%Name%
	TestDir := A_Temp . "\ergopti_cs_semantic_" . A_TickCount . "_" . A_ScriptHwnd
		. "_" . FixtureSequence . "\"
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
		Source := "_meta = { schema_version = " . ConfigMigrateCurrentVersion() . " }`n" . Source
		Path := CS_GetTomlPath()
		AssertTrue(FSWrite(Path, Source))
		Journal := ConfigMigrateBoot(Path)
		AssertTrue(Journal is Map, "the real native constructor must admit the semantic fixture")
		AssertEqual("current", Journal.Get("status", "missing"))
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


; Keep the exact primary boot admission and the later metrics consumer in the
; same private source. The old reader threw on quoted booleans and reinterpreted
; signed numeric zero/one after the primary owner had rejected their lexemes.
global _CSTT_MetricsWarnings := 0

_CSTT_ObserveWarning(Self, Tag, Message, Args*) {
	global _CSTT_MetricsWarnings
	if Tag == "ConfigShortcuts"
		_CSTT_MetricsWarnings += 1
	Self.DeleteProp("Call")
	try return Self.Call(Tag, Message, Args*)
	finally Self.DefineProp("Call", {Call: _CSTT_ObserveWarning})
}

_CSTT_NoStoredPosition(Key) => "_"

_CSTT_BootAdmission(Key, Raw, Outdated := true, ExpectedValue := unset) {
	static FixtureSequence := 0
	FixtureSequence += 1
	global _ConfigDir, _AhkSubDir, ConfigurationFile, _BootConfigSnapshot
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries, _ConfigBootReadFailed
	global _CSTT_MetricsWarnings
	SavedConfigDir := _ConfigDir, SavedAhkSubDir := _AhkSubDir
	SavedFileSet := IsSet(ConfigurationFile)
	SavedFile := SavedFileSet ? ConfigurationFile : ""
	SavedSnapshotSet := IsSet(_BootConfigSnapshot)
	SavedSnapshot := SavedSnapshotSet ? _BootConfigSnapshot : 0
	SavedRejected := _ConfigBootRejectedOverrides
	SavedOutdated := _ConfigBootOutdatedEntries
	SavedReadFailure := _ConfigBootReadFailed
	SavedRuntime := _CSTT_SaveRuntime()
	TestDir := A_Temp . "\ergopti_cs_admission_" . A_TickCount . "_" . A_ScriptHwnd
		. "_" . FixtureSequence . "\"
	DirCreate(TestDir)
	Observing := false
	try {
		_ConfigDir := TestDir, _AhkSubDir := ""
		ConfigurationFile := CS_GetTomlPath()
		Source := "[_meta]`nschema_version = " . ConfigMigrateCurrentVersion()
			. "`n[metrics]`n"
		if Key != ConfigLeaf.ENABLED
			Source .= "enabled = true`n"
		Source .= Key . " = " . Raw . "`n"
		AssertTrue(FSWrite(ConfigurationFile, Source))
		Before := FSReadUtf8Exact(ConfigurationFile)
		_ConfigBootRejectedOverrides := 0
		_ConfigBootOutdatedEntries := Map()
		_ConfigBootReadFailed := false
		; Match the real entry's journal constructor before asking its snapshot
		; owner to capture a read. A schema stamp alone does not grant admission.
		Journal := ConfigMigrateBoot(ConfigurationFile)
		AssertTrue(Journal is Map, "the real boot journal must return its native result")
		AssertEqual("current", Journal.Get("status", "missing"),
			"the private current-schema source must complete the genuine boot constructor")
		Tree := ManifestBuildFeaturesMap()
		Applied := ApplyBootConfigToml(Tree, ConfigurationFile, &_BootConfigSnapshot)
		AssertTrue(Applied >= 0,
			"the actual primary boot owner must admit the complete private source; applied=" . Applied)
		AssertEqual(0, _ConfigBootRejectedOverrides, "outdated values cannot refuse the whole configuration")
		AssertFalse(_ConfigBootReadFailed)
		AssertEqual(Outdated ? 1 : 0, _ConfigBootOutdatedEntries.Count)
		Physical := _BootConfigSnapshot.Cache[ConfigKey.METRICS][Key]
		MetricsShortcuts.enabled := Key == ConfigLeaf.ENABLED
			? (Outdated ? !ManifestDefaultFor(ConfigKey.METRICS_ENABLED) : !ExpectedValue) : false
		MetricsFilters.disabled_apps := Map("previous.exe", true)
		AssertFalse(LoggerWarn.HasOwnProp("Call"), "the fixture must own its warning observer")
		_CSTT_MetricsWarnings := 0
		LoggerWarn.DefineProp("Call", {Call: _CSTT_ObserveWarning})
		Observing := true
		Cache := CS_Load()
		Expected := Outdated ? _CSTT_ExpectedValue(Key) : ExpectedValue
		WidgetProps := Map(ConfigLeaf.WPM_WIDGET_VISIBLE, "visible",
			ConfigLeaf.WPM_WIDGET_COLORS, "use_colors", ConfigLeaf.WPM_WIDGET_GRAPH, "show_graph")
		if WidgetProps.Has(Key) {
			AssertTrue(Cache is Map, "the widget must receive the same admitted metrics cache")
			Prop := WidgetProps[Key]
			WPMWidget.%Prop% := !Expected
			WPMWidget_LoadConfig(Cache, [], _CSTT_NoStoredPosition)
			Actual := WPMWidget.%Prop%
		} else
			Actual := _CSTT_ActualValue(Key)
		if Expected is Array
			AssertEqual(Expected.Length, Actual.Count)
		else
			AssertEqual(Expected, Actual,
				"secondary reading must preserve the primary manifest admission for " . Key)
		if Key != ConfigLeaf.ENABLED
			AssertTrue(MetricsShortcuts.enabled, "the valid sibling consent remains applied")
		AssertEqual(Physical, _BootConfigSnapshot.Cache[ConfigKey.METRICS][Key],
			"effective values must never mutate the physical admitted snapshot")
		AssertEqual(0, _CSTT_MetricsWarnings,
			"an exact primary boot warning must not be duplicated by its secondary reader")
		AssertEqual(Before, FSReadUtf8Exact(ConfigurationFile),
			"ignored values and all authored bytes remain available to cleanup")
	} finally {
		if Observing
			LoggerWarn.DeleteProp("Call")
		_CSTT_RestoreRuntime(SavedRuntime)
		_ConfigDir := SavedConfigDir, _AhkSubDir := SavedAhkSubDir
		ConfigurationFile := SavedFileSet ? SavedFile : unset
		_BootConfigSnapshot := SavedSnapshotSet ? SavedSnapshot : unset
		_ConfigBootRejectedOverrides := SavedRejected
		_ConfigBootOutdatedEntries := SavedOutdated
		_ConfigBootReadFailed := SavedReadFailure
		if DirExist(TestDir)
			DirDelete(TestDir, true)
	}
}

for Fixture in [
	[ConfigLeaf.ENABLED, '"false"'],
	[ConfigLeaf.ENABLED, "+1"],
	[ConfigLeaf.PRIVATE_FILTER_ENABLED, "+0"],
	[ConfigLeaf.PRIVATE_FILTER_ENABLED, "-0"],
	[ConfigLeaf.PRIVATE_FILTER_ENABLED, '"false"'],
	[ConfigLeaf.SECURE_FILTER_ENABLED, '""'],
	[ConfigLeaf.SYSTEM_AUTH_FILTER_ENABLED, "-1"],
	[ConfigLeaf.ENCRYPT, '"true"'],
	[ConfigLeaf.DISABLED_APPS, '"chrome.exe"'],
	[ConfigLeaf.WPM_WIDGET_VISIBLE, '"true"'],
	[ConfigLeaf.WPM_WIDGET_COLORS, '"true"'],
	[ConfigLeaf.WPM_WIDGET_GRAPH, '"true"']
]
	Test("metrics boot: outdated " . Fixture[1] . " = " . Fixture[2]
		. " keeps primary admission " . (InStr(Fixture[1], "wpm_widget_") == 1
			? "(metrics-secondary-widget-admission)" : "(metrics-secondary-admission)"),
		_CSTT_BootAdmission.Bind(Fixture[1], Fixture[2]))

Test("metrics boot: legacy unsigned zero retains recording opt-out (metrics-secondary-admission)",
	_CSTT_BootAdmission.Bind(ConfigLeaf.ENABLED, "0", false, false))
Test("metrics boot: legacy unsigned one retains recording opt-in (metrics-secondary-admission)",
	_CSTT_BootAdmission.Bind(ConfigLeaf.ENABLED, "1", false, true))
Test("metrics boot: legacy unsigned zero retains privacy opt-out (metrics-secondary-admission)",
	_CSTT_BootAdmission.Bind(ConfigLeaf.PRIVATE_FILTER_ENABLED, "0", false, false))

Test("metrics boot: legacy comment preserves recording opt-in (metrics-secondary-admission)",
	_CSTT_BootAdmission.Bind(ConfigLeaf.ENABLED, "1 # explicit recording consent", false, true))
Test("metrics boot: legacy comment preserves privacy opt-out (metrics-secondary-admission)",
	_CSTT_BootAdmission.Bind(ConfigLeaf.PRIVATE_FILTER_ENABLED, "0 # explicit privacy choice", false, false))


; A physical edit does not retire the primary native boot generation. The
; metrics owner must consume that same admission until the canonical writer or
; explicit cache retirement opens a later generation.
_CSTT_RetainedBootGeneration(Key, ReplacePhysicalSource) {
	static FixtureSequence := 0
	FixtureSequence += 1
	global _ConfigDir, _AhkSubDir, ConfigurationFile, _BootConfigSnapshot
	global _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries, _ConfigBootReadFailed
	SavedConfigDir := _ConfigDir, SavedAhkSubDir := _AhkSubDir
	SavedFileSet := IsSet(ConfigurationFile)
	SavedFile := SavedFileSet ? ConfigurationFile : ""
	SavedSnapshotSet := IsSet(_BootConfigSnapshot)
	SavedSnapshot := SavedSnapshotSet ? _BootConfigSnapshot : 0
	SavedRejected := _ConfigBootRejectedOverrides
	SavedOutdated := _ConfigBootOutdatedEntries
	SavedReadFailure := _ConfigBootReadFailed
	SavedRuntime := _CSTT_SaveRuntime()
	TestDir := A_Temp . "\ergopti_cs_generation_" . A_TickCount . "_" . A_ScriptHwnd
		. "_" . FixtureSequence . "\"
	DirCreate(TestDir)
	Path := ""
	try {
		_ConfigDir := TestDir, _AhkSubDir := ""
		ConfigurationFile := CS_GetTomlPath(), Path := ConfigurationFile
		Header := "[_meta]`nschema_version = " . ConfigMigrateCurrentVersion() . "`n[metrics]`n"
		Initial := Header . "enabled = false`nprivate_filter_enabled = true`n"
		Replacement := Header . "enabled = true`nprivate_filter_enabled = false`n"
		AssertTrue(FSWrite(Path, Initial))
		_ConfigBootRejectedOverrides := 0
		_ConfigBootOutdatedEntries := Map()
		_ConfigBootReadFailed := false
		Journal := ConfigMigrateBoot(Path)
		AssertTrue(Journal is Map, "the real native journal must initialize the private boot path")
		AssertEqual("current", Journal.Get("status", "missing"))
		Bootstrap := ParseConfigTomlFile(Path)
		AssertTrue(Bootstrap.Has(ConfigKey.METRICS), "the actual bootstrap must publish its native generation")
		Tree := ManifestBuildFeaturesMap()
		AssertTrue(ApplyBootConfigToml(Tree, Path, &_BootConfigSnapshot) >= 0)
		AssertEqual(0, _ConfigBootRejectedOverrides)
		AssertEqual(0, _ConfigBootOutdatedEntries.Count)
		AssertFalse(_ConfigBootReadFailed)
		Primary := _BootConfigSnapshot
		AssertEqual(Initial, Primary.Source)
		AssertTrue(Bootstrap == Primary.Cache, "bootstrap and primary application must share the same admitted cache")
		if ReplacePhysicalSource
			AssertTrue(FSWrite(Path, Replacement), "the race must actually replace the private native source")
		Physical := ReplacePhysicalSource ? Replacement : Initial
		AssertEqual(Physical, FSReadUtf8Exact(Path))
		Retained := ConfigTomlReadSnapshot(Path)
		AssertTrue(Retained == Primary, "the genuine canonical reader must retain the already admitted generation")
		AssertEqual(Initial, Retained.Source, "an external edit cannot silently replace the primary source authority")
		MetricsShortcuts.enabled := true
		MetricsFilters.private_browsing := false
		CS_Load()
		Expected := Primary.Cache[ConfigKey.METRICS][Key]
		AssertEqual(Expected, _CSTT_ActualValue(Key),
			"secondary metrics publication must use the retained primary generation for " . Key)
		AssertEqual(Physical, FSReadUtf8Exact(Path), "a secondary read cannot rewrite the external source")
		AssertEqual(Initial, Primary.Source, "secondary reading cannot replace the admitted snapshot")
	} finally {
		_CSTT_RestoreRuntime(SavedRuntime)
		_ConfigDir := SavedConfigDir, _AhkSubDir := SavedAhkSubDir
		ConfigurationFile := SavedFileSet ? SavedFile : unset
		_BootConfigSnapshot := SavedSnapshotSet ? SavedSnapshot : unset
		_ConfigBootRejectedOverrides := SavedRejected
		_ConfigBootOutdatedEntries := SavedOutdated
		_ConfigBootReadFailed := SavedReadFailure
		if Path != ""
			_TOML_InvalidateParseCache(Path)
		if DirExist(TestDir)
			DirDelete(TestDir, true)
	}
}

for Key in [ConfigLeaf.ENABLED, ConfigLeaf.PRIVATE_FILTER_ENABLED] {
	Test("metrics boot: external replacement retains " . Key . " generation (metrics-retained-generation)",
		_CSTT_RetainedBootGeneration.Bind(Key, true))
	Test("metrics boot: unchanged source retains " . Key . " generation (metrics-retained-generation)",
		_CSTT_RetainedBootGeneration.Bind(Key, false))
}
