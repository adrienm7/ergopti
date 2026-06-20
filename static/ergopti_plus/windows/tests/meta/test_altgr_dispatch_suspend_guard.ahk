; tests/meta/test_altgr_dispatch_suspend_guard.ahk

; ==============================================================================
; MODULE: AltGr Dispatch Suspend Guard Meta Test
; DESCRIPTION:
; Regression guard for the A_IsSuspended check in _ScriptAltGrDispatch.
;
; AHK suspend disables Hotkey directives but pseudo-threads launched by timer
; callbacks and certain HotIf contexts can still call through into
; _ScriptAltGrDispatch. Without a guard, a chord partially completed before
; suspend was toggled lands and fires RunScriptShortcutAction — executing user
; scripts while the driver is intentionally paused. The correct behaviour is
; to pass the keystroke natively (SendInput NativeSend) when suspended.
;
; This test asserts that _ScriptAltGrDispatch checks A_IsSuspended before
; calling RunScriptShortcutAction, and that the check precedes the action call.
;
; SCOPE: source introspection of lib/script_altgr_hotkeys.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =================================================
; =================================================
; ======= 1/ Source scan helpers ==================
; =================================================
; =================================================

_ADSG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Path := WindowsDir . "\" . StrReplace(RelPath, "/", "\")
	return FileRead(Path)
}

_ADSG_FuncBody(Src, FnDecl) {
	FnPos := InStr(Src, FnDecl)
	if (!FnPos)
		return ""
	depth := 0
	i := FnPos
	Len := StrLen(Src)
	while (i <= Len) {
		ch := SubStr(Src, i, 1)
		if (ch == "{")
			depth++
		else if (ch == "}") {
			depth--
			if (depth <= 0)
				return SubStr(Src, FnPos, i - FnPos + 1)
		}
		i++
	}
	return SubStr(Src, FnPos)
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_ADSG_CheckSuspendGuard() {
	Src := _ADSG_ReadSource("lib/script_altgr_hotkeys.ahk")
	Assert(Src != "", "lib/script_altgr_hotkeys.ahk must be readable")

	Body := _ADSG_FuncBody(Src, "_ScriptAltGrDispatch(SuffixSC, Slot, NativeSend, CtrlAltSuffixKey) {")
	Assert(Body != "", "_ScriptAltGrDispatch must be present in lib/script_altgr_hotkeys.ahk")

	GuardPos  := InStr(Body, "A_IsSuspended")
	ActionPos := InStr(Body, "RunScriptShortcutAction(Slot)")

	Assert(GuardPos > 0,
		"_ScriptAltGrDispatch must check A_IsSuspended before running the action")
	Assert(ActionPos > 0,
		"_ScriptAltGrDispatch must call RunScriptShortcutAction(Slot)")
	Assert(GuardPos < ActionPos,
		"A_IsSuspended guard must appear before RunScriptShortcutAction call in _ScriptAltGrDispatch")
}


Test("meta altgr-dispatch-suspend-guard: _ScriptAltGrDispatch checks A_IsSuspended before RunScriptShortcutAction",
	_ADSG_CheckSuspendGuard)
