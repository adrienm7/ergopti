; tests/meta/test_keylogger_tick_overflow.ahk

; ==============================================================================
; MODULE: Keylogger A_TickCount Overflow Guard Meta Test
; DESCRIPTION:
; Static source guard for the "keylogger-tickcount-overflow" audit finding in
; modules/keylogger/keylogger_watchers.ahk and keylogger_hook.ahk.
;
; ROOT CAUSE ENCODED:
; A_TickCount is a 32-bit unsigned counter that wraps from 0xFFFFFFFF back to 0
; approximately every 49.7 days. A naive delta (now - last) is evaluated in
; AHK v2 as a 64-bit signed integer. After the wrap, the result is a large
; negative number, making elapsed-time comparisons always false — idle/session
; timers never fire, and the watcher loses track of keystroke timing permanently
; until the script restarts.
;
; The fix masks every subtraction: (now - last) & 0xFFFFFFFF. This keeps the
; delta in [0, 0xFFFFFFFF] regardless of counter direction and produces the
; correct unsigned elapsed time after a wrap event.
;
; The companion test test_tickcount_wrap_safe.ahk covers the same fix in
; prediction_engine.ahk and llm_bridge.ahk. This test covers the two keylogger
; modules that were not included in that earlier guard.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ keylogger_watchers tick overflow ========
; ===================================================
; ===================================================

_KLTO_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	return FileRead(StrReplace(Root, "/", "\") . "\" . StrReplace(RelPath, "/", "\"), "UTF-8")
}

_KLTO_StripComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}

_KLTO_WatchersWrapSafe() {
	Raw := _KLTO_ReadSource("modules/keylogger/keylogger_watchers.ahk")
	Src := _KLTO_StripComments(Raw)
	Assert(Src != "", "modules/keylogger/keylogger_watchers.ahk must be readable")

	Assert(InStr(Src, "& 0xFFFFFFFF") > 0,
		"keylogger_watchers.ahk must apply the & 0xFFFFFFFF mask to every A_TickCount delta (keylogger-tickcount-overflow)")

	; Verify the mask is used on gap computation — both session and idle paths use it
	Assert(InStr(Src, "gap := (now - last) & 0xFFFFFFFF") > 0
		or InStr(Src, "gap := (now - KLHook.last_tick) & 0xFFFFFFFF") > 0,
		"keylogger_watchers.ahk must use (now - last) & 0xFFFFFFFF for gap computation")

	; Verify the mask is also applied to session duration reporting
	Assert(InStr(Src, ") & 0xFFFFFFFF") > 0,
		"keylogger_watchers.ahk must mask session-duration deltas with & 0xFFFFFFFF")
}
Test("keylogger: keylogger_watchers.ahk uses & 0xFFFFFFFF mask on all A_TickCount deltas (keylogger-tickcount-overflow)", _KLTO_WatchersWrapSafe)




; ===============================================
; ===============================================
; ======= 2/ keylogger_hook tick overflow ========
; ===============================================
; ===============================================

_KLTO_HookWrapSafe() {
	Raw := _KLTO_ReadSource("modules/keylogger/keylogger_hook.ahk")
	Src := _KLTO_StripComments(Raw)
	Assert(Src != "", "modules/keylogger/keylogger_hook.ahk must be readable")

	Assert(InStr(Src, "& 0xFFFFFFFF") > 0,
		"keylogger_hook.ahk must apply the & 0xFFFFFFFF mask to the A_TickCount inter-keystroke delay (keylogger-tickcount-overflow)")

	Assert(InStr(Src, "last_tick) & 0xFFFFFFFF") > 0,
		"keylogger_hook.ahk must mask the (now - last_tick) delay with & 0xFFFFFFFF")
}
Test("keylogger: keylogger_hook.ahk uses & 0xFFFFFFFF mask on inter-keystroke delay (keylogger-tickcount-overflow)", _KLTO_HookWrapSafe)
