; tests/meta/test_keylogger_hook_global_try.ahk

; ==============================================================================
; MODULE: Keylogger Hook Global Try/Catch Meta Test
; DESCRIPTION:
; Static source guard for the "keylogger-hook-global-try" audit finding in
; modules/keylogger/keylogger_hook.ahk.
;
; ROOT CAUSE ENCODED:
; KL_Hook_OnChar and KL_Hook_OnKeyDown had only localised try blocks around
; individual Win32 calls. An uncaught exception thrown from any of the many
; unprotected code paths (buffer mutations, privacy filtering, ergo walker,
; WPM push) would propagate up to the InputHook dispatcher. AHK v2 silently
; disables an InputHook that throws from its callback, meaning the keylogger
; would stop recording all subsequent keystrokes with no error message.
;
; The fix wraps the entire body of each callback in a single outer try/catch
; that logs the exception and returns, keeping the InputHook alive.
; ==============================================================================

#Requires AutoHotkey v2.0





; =============================================================
; =============================================================
; ======= 1/ KL_Hook_OnChar wrapped in global try/catch =======
; =============================================================
; =============================================================

_KHT_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	return FileRead(StrReplace(Root, "/", "\") . "\" . StrReplace(RelPath, "/", "\"), "UTF-8")
}

_KHT_StripComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}

_KHT_OnCharWrapped() {
	Src := _KHT_StripComments(_KHT_ReadSource("modules/keylogger/keylogger_hook.ahk"))
	Body := _DriverFuncBody("KL_Hook_OnChar")

	Assert(Body != "", "KL_Hook_OnChar must exist in keylogger_hook.ahk")

	; The outer try block must enclose the main logic
	Assert(InStr(Body, "try {") > 0,
		"KL_Hook_OnChar must have an outer try { } block to prevent InputHook deactivation on exception (keylogger-hook-global-try)")

	; The catch must log and not re-throw so the hook stays alive
	Assert(RegExMatch(Body, "catch\s+as\s+\w+") > 0,
		"KL_Hook_OnChar must have a named catch clause to log the error (keylogger-hook-global-try)")
	Assert(InStr(Body, "LoggerError") > 0,
		"KL_Hook_OnChar catch must call LoggerError to surface the problem (keylogger-hook-global-try)")
}
Test("keylogger_hook: KL_Hook_OnChar body wrapped in global try/catch (keylogger-hook-global-try)", _KHT_OnCharWrapped)





; =================================================================
; =================================================================
; ======= 2/ KL_Hook_OnKeyDown wrapped in global try/catch ========
; =================================================================
; =================================================================

_KHT_OnKeyDownWrapped() {
	Src := _KHT_StripComments(_KHT_ReadSource("modules/keylogger/keylogger_hook.ahk"))
	Body := _DriverFuncBody("KL_Hook_OnKeyDown")

	Assert(Body != "", "KL_Hook_OnKeyDown must exist in keylogger_hook.ahk")

	Assert(InStr(Body, "try {") > 0,
		"KL_Hook_OnKeyDown must have an outer try { } block to prevent InputHook deactivation on exception (keylogger-hook-global-try)")

	Assert(RegExMatch(Body, "catch\s+as\s+\w+") > 0,
		"KL_Hook_OnKeyDown must have a named catch clause to log the error (keylogger-hook-global-try)")
	Assert(InStr(Body, "LoggerError") > 0,
		"KL_Hook_OnKeyDown catch must call LoggerError to surface the problem (keylogger-hook-global-try)")
}
Test("keylogger_hook: KL_Hook_OnKeyDown body wrapped in global try/catch (keylogger-hook-global-try)", _KHT_OnKeyDownWrapped)
