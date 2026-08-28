; static/ergopti_plus/windows/tests/unit/test_config_shortcuts_types.ahk

; ==============================================================================
; MODULE: Metrics Config Type Boundary Tests
; DESCRIPTION:
; Ensures the second metrics reader cannot reinterpret values already rejected
; by the manifest-backed TOML loader or publish a prefix before a later error.
; ==============================================================================

_CSTT_WriteConfig(Path, Body) {
	if FileExist(Path)
		FileDelete(Path)
	FileAppend("[metrics]`n" . Body . "`n", Path, "UTF-8")
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
			["metrics_enabled", '"false"'],
			["metrics_wpm_menubar_colors", "2"],
			["private_filter_enabled", '""'],
			["secure_filter_enabled", '""'],
			["system_auth_filter_enabled", "-1"],
			["encrypt", '"true"'],
			["metrics_shortcut_typing", "2"],
			["metrics_shortcut_apps", "false"],
			["metrics_disabled_apps", '"chrome.exe"']
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
			'metrics_enabled = false`nsecure_filter_enabled = ""')
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
