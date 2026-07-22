; tests/meta/test_keylogger_ui_dead_code.ahk

; ==============================================================================
; MODULE: Keylogger UI Dead Code Meta Test (Pattern 6)
; DESCRIPTION:
; Static source guard confirming KLUI_OpenTyping/KLUI_OpenApps stay removed.
; Both were dead code (no live caller anywhere in the driver) that duplicated
; the same hardcoded French strings as the real dashboard entry point in
; keylogger_webview.ahk's KLWV_Open -- a maintenance trap: a future refactor
; that re-wired a hotkey directly to one of these would have silently
; reintroduced the hardcoded-locale bug and bypassed the real WebView2
; dashboard entirely.
;
; SCOPE: source introspection of modules/keylogger/keylogger_ui.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Dead functions stay removed ============
; ===================================================
; ===================================================

_KLUIDC_NoDeadOpenFunctions() {
	Src := _DriverDirConcat("modules/keylogger")
	Assert(Src != "", "the modules/keylogger module must exist")

	Assert(InStr(Src, "KLUI_OpenTyping") = 0,
		"KLUI_OpenTyping was dead code (no live caller) duplicating hardcoded French strings already fixed in keylogger_webview.ahk -- do not reintroduce it without wiring it to a real caller and routing its title through t()")
	Assert(InStr(Src, "KLUI_OpenApps") = 0,
		"KLUI_OpenApps was dead code (no live caller) duplicating hardcoded French strings already fixed in keylogger_webview.ahk -- do not reintroduce it without wiring it to a real caller and routing its title through t()")
}
Test("keylogger_ui: dead KLUI_OpenTyping/KLUI_OpenApps stay removed (hardcoded-french-strings)", _KLUIDC_NoDeadOpenFunctions)
