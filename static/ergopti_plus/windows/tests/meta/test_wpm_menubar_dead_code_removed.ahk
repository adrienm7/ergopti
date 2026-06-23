; tests/meta/test_wpm_menubar_dead_code_removed.ahk

; ==============================================================================
; MODULE: WPM Menubar Dead Code Removal Test
; DESCRIPTION:
; Regression guard for F13 — WpmMenubar_Tick was never implemented on Windows;
; only the macOS Lua equivalent exists. When show_wpm_menubar was true the
; SetTimer call crashed with "This global variable has not been assigned a value"
; and aborted the metrics/keylogger init entirely.
;
; This test verifies that all dead wiring for metrics_show_wpm_menubar has been
; removed from the Windows sources so the bug cannot silently re-enter the tree.
;
; COVERAGE:
; 1. ErgoptiPlus.ahk must not reference WpmMenubar_Tick.
; 2. ErgoptiPlus.ahk must not reference metrics_show_wpm_menubar in any Update push.
; 3. metrics_shortcuts.ahk must not declare the show_wpm_menubar field.
; 4. config_shortcuts.ahk must not read or write metrics_show_wpm_menubar.
; 5. features_manifest.ahk must not list the metrics_show_wpm_menubar entry.
; 6. config_template.toml must not contain the metrics_show_wpm_menubar key.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===========================================
; ===========================================
; ======= 1/ Source-reading helper ==========
; ===========================================
; ===========================================

; Reads a source file relative to the windows/ driver root. A_ScriptDir is the
; RUNNER's directory (windows/tests) for every #Include'd test — NOT this file's
; own tests/meta/ dir — so the driver root is ONE level up. The original "\..\..\"
; assumed A_ScriptDir = tests/meta/ and overshot to static/ergopti_plus/, making
; every FileRead fail and silently orphaning this test (it never ran in run_all).
; Returns the file contents as a string, or an empty string on failure.
_WMDR_ReadSource(RelPath) {
	Root := A_ScriptDir . "\..\"
	try {
		return FileRead(Root . RelPath)
	} catch {
		return ""
	}
}




; ===========================================
; ===========================================
; ======= 2/ Test registrations =============
; ===========================================
; ===========================================

_WMDR_NoWpmMenubarTickInMain() {
	Src := _DriverSourceConcat()
	Assert(Src != "", "ErgoptiPlus.ahk must be readable")
	Assert(not InStr(Src, "WpmMenubar_Tick"),
		"ErgoptiPlus.ahk must not reference WpmMenubar_Tick (dead macOS-only callback)")
}
Test("F13 regression: ErgoptiPlus.ahk must not contain WpmMenubar_Tick", _WMDR_NoWpmMenubarTickInMain)

_WMDR_NoShowWpmMenubarPushInMain() {
	Src := _DriverSourceConcat()
	Assert(Src != "", "ErgoptiPlus.ahk must be readable")
	Assert(not InStr(Src, "metrics_show_wpm_menubar"),
		"ErgoptiPlus.ahk must not push metrics_show_wpm_menubar in SaveFullConfig")
}
Test("F13 regression: ErgoptiPlus.ahk must not contain metrics_show_wpm_menubar", _WMDR_NoShowWpmMenubarPushInMain)

_WMDR_NoShowWpmMenubarFieldInClass() {
	Src := _WMDR_ReadSource("lib\metrics\metrics_shortcuts.ahk")
	Assert(Src != "", "lib/metrics/metrics_shortcuts.ahk must be readable")
	Assert(not InStr(Src, "show_wpm_menubar"),
		"MetricsShortcuts class must not declare the show_wpm_menubar field")
}
Test("F13 regression: metrics_shortcuts.ahk must not contain show_wpm_menubar", _WMDR_NoShowWpmMenubarFieldInClass)

_WMDR_NoShowWpmMenubarInConfigShortcuts() {
	Src := _WMDR_ReadSource("lib\config_shortcuts.ahk")
	Assert(Src != "", "lib/config_shortcuts.ahk must be readable")
	Assert(not InStr(Src, "metrics_show_wpm_menubar"),
		"config_shortcuts.ahk must not read or write metrics_show_wpm_menubar")
}
Test("F13 regression: config_shortcuts.ahk must not contain metrics_show_wpm_menubar", _WMDR_NoShowWpmMenubarInConfigShortcuts)

_WMDR_NoShowWpmMenubarInFeaturesManifest() {
	Src := _WMDR_ReadSource("_generated\features_manifest.ahk")
	Assert(Src != "", "_generated/features_manifest.ahk must be readable")
	Assert(not InStr(Src, "metrics_show_wpm_menubar"),
		"features_manifest.ahk must not list the metrics_show_wpm_menubar entry")
}
Test("F13 regression: features_manifest.ahk must not contain metrics_show_wpm_menubar", _WMDR_NoShowWpmMenubarInFeaturesManifest)

_WMDR_NoShowWpmMenubarInConfigTemplate() {
	Src := _WMDR_ReadSource("_generated\config_template.toml")
	Assert(Src != "", "_generated/config_template.toml must be readable")
	Assert(not InStr(Src, "metrics_show_wpm_menubar"),
		"config_template.toml must not declare the metrics_show_wpm_menubar key")
}
Test("F13 regression: config_template.toml must not contain metrics_show_wpm_menubar", _WMDR_NoShowWpmMenubarInConfigTemplate)
