; tests/meta/test_webview_temp_dir_and_com_leak_on_reload.ahk

; ==============================================================================
; MODULE: WebView2 Reload-Leak Guard Meta Test
; DESCRIPTION:
; Static source guard for the "webview-temp-dir-and-com-leak-on-reload" finding.
;
; AHK Reload()/ExitApp() tear the process down WITHOUT running per-class
; destructors: static class state (KLWV.windows := Map()) is re-initialised,
; but the WebView2 COM controller and its CoreWebView2 host process keep the
; per-launch udir locked. Unless KLWV_CloseAll() runs on shutdown, every
; metrics-dashboard open across a Reload (config change / update) orphans an
; msedgewebview2.exe host and a multi-MB ergopti_webview2_* profile dir in
; %TEMP%.
;
; The fix wires KLWV_CloseAll() into the single global OnExit shutdown handler
; (Ergopti_OnShutdown), so Reload/ExitApp closes controllers and destroys Guis.
; KLWV_Close releases the controller, destroys the Gui AND deletes the udir,
; and KLWV_CloseAll iterates a Clone() so deleting entries mid-loop is safe.
;
; This is a meta-static test (scans source text) because keylogger_webview.ahk
; and ErgoptiPlus.ahk register top-level hooks/Guis and cannot be #Included by
; the headless runner. If the OnExit wiring of KLWV_CloseAll is removed, or
; KLWV_Close stops releasing the controller / deleting the udir, this fails.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_WVRL_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

; Returns the full function body - from its declaration to the first closing
; brace at column 0 (AHK functions close with `}` flush-left, while inner blocks
; close indented). Returns "" when the declaration is absent.
_WVRL_FuncBody(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		return SubStr(Rest, 1, End + 1)
	return Rest
}




; ==================================================
; ==================================================
; ======= 2/ OnExit wiring assertion ===============
; ==================================================
; ==================================================

_WVRL_CloseAllWiredToOnExit() {
	Src := _WVRL_ReadSource("ErgoptiPlus.ahk")
	; The single global shutdown handler must call KLWV_CloseAll, and it must be
	; registered via OnExit - Reload/ExitApp run ONLY OnExit callbacks, so this
	; is the seam that releases the WebView2 controllers and unlocks the udirs.
	Seg := _WVRL_FuncBody(Src, "Ergopti_OnShutdown(reason, code) {")
	Assert(Seg != "", "Ergopti_OnShutdown(reason, code) must exist in ErgoptiPlus.ahk")
	Assert(InStr(Seg, "KLWV_CloseAll()") > 0,
		"Ergopti_OnShutdown must call KLWV_CloseAll() - without it a Reload orphans the WebView2 host process and leaks its locked ergopti_webview2_* temp profile dir")
	Assert(InStr(Src, "OnExit(Ergopti_OnShutdown)") > 0,
		"ErgoptiPlus.ahk must register OnExit(Ergopti_OnShutdown) - the handler only runs on shutdown if it is wired to OnExit")
}
Test("keylogger: KLWV_CloseAll runs on shutdown via OnExit (webview-temp-dir-and-com-leak-on-reload)", _WVRL_CloseAllWiredToOnExit)




; ==================================================
; ==================================================
; ======= 3/ Close-path release assertions =========
; ==================================================
; ==================================================

_WVRL_CloseReleasesEverything() {
	Src := _WVRL_ReadSource("modules/keylogger/keylogger_webview.ahk")
	Seg := _WVRL_FuncBody(Src, "KLWV_Close(which) {")
	Assert(Seg != "", "KLWV_Close(which) must exist in keylogger_webview.ahk")
	; Releasing the COM controller is what stops the msedgewebview2.exe host and
	; releases the lock on the per-launch profile dir.
	Assert(InStr(Seg, '["controller"].Close()') > 0,
		"KLWV_Close must Close() the WebView2 controller so the host process exits and unlocks the udir")
	; Destroying the Gui frees the HWND the controller was parented to.
	Assert(InStr(Seg, '["gui"].Destroy()') > 0,
		"KLWV_Close must Destroy() the host Gui")
	; Deleting the udir reclaims the multi-MB temp profile dir for this launch.
	Assert(InStr(Seg, 'DirDelete(entry["udir"], true)') > 0,
		"KLWV_Close must DirDelete the per-launch udir - otherwise reopening leaks a new ergopti_webview2_* dir each time")
}
Test("keylogger: KLWV_Close releases controller, gui and udir (webview-temp-dir-and-com-leak-on-reload)", _WVRL_CloseReleasesEverything)

_WVRL_CloseAllIteratesClone() {
	Src := _WVRL_ReadSource("modules/keylogger/keylogger_webview.ahk")
	Seg := _WVRL_FuncBody(Src, "KLWV_CloseAll() {")
	Assert(Seg != "", "KLWV_CloseAll() must exist in keylogger_webview.ahk")
	; KLWV_Close mutates KLWV.windows (Delete) mid-iteration; iterating a Clone()
	; avoids skipping entries / corrupting the enumerator.
	Assert(InStr(Seg, "KLWV.windows.Clone()") > 0,
		"KLWV_CloseAll must iterate KLWV.windows.Clone() - KLWV_Close deletes from KLWV.windows during the loop")
}
Test("keylogger: KLWV_CloseAll iterates a Clone (webview-temp-dir-and-com-leak-on-reload)", _WVRL_CloseAllIteratesClone)
