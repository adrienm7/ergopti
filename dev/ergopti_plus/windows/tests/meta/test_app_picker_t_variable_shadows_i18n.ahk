; tests/meta/test_app_picker_t_variable_shadows_i18n.ahk

; ==============================================================================
; MODULE: App Picker i18n Shadow Guard Meta Test
; DESCRIPTION:
; Static source guard for the app-picker-t-variable-shadows-i18n finding.
;
; AppPicker_BuildRows() previously stored the window title in a local named
; `t`, shadowing the project-wide t() i18n function identifier. There is no
; runtime defect today (AHK v2 resolves `t(...)` calls separately from `t`
; variable reads), but it is a footgun: a future maintainer who writes
; `cb := t` expecting the i18n function would silently get the window-title
; string instead. The fix renames the local to `winTitle`.
;
; This is a meta-static test (scans source text) because app_picker.ahk is
; not part of the headless run_all.ahk include graph — calling its functions
; would be a load-time error. We assert the i18n identifier `t` is never used
; as an lvalue anywhere in the file so the shadow cannot be reintroduced.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helper ====================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir
; (tests/); its parent is the windows/ driver root.
_APTV_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Shadow assertion ======================
; ==================================================
; ==================================================

_APTV_NoSingleLetterTAssignment() {
	Src := _APTV_ReadSource("infra/app_picker.ahk")
	Assert(Src != "", "infra/app_picker.ahk must be readable")
	; The single-letter i18n identifier must never appear as an lvalue.
	; A match means the window-title shadow (or a new one) was reintroduced.
	Found := RegExMatch(Src, "m)^\s*t\s*:=")
	Assert(Found = 0,
		"app_picker.ahk must not assign to a local named t (single letter) " . Chr(0x2014) . " it shadows the global i18n function; use winTitle (or another descriptive name) instead")
}
Test("app_picker: i18n identifier t is never an lvalue (app-picker-t-variable-shadows-i18n)", _APTV_NoSingleLetterTAssignment)
