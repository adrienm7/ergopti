; tests/meta/test_tap_hold_fire_action_suspend_guard.ahk

; ==============================================================================
; MODULE: Tap-Hold Suspend Guard Meta Test (Pattern 1)
; DESCRIPTION:
; Static source guard for the systemic "native Suspend() never disarms a
; tap-hold's own dispatch call" gap-class (docs/PROJECT_MEMORY.md's
; project-suspend-pause-invariant). Covers TapHoldDispatchTap, the shared gate
; used by both configured actions and native/special delayed tap outputs.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Source scan helpers =======
; ======================================
; ======================================

_THFASG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return _THFASG_StripLineComments(FileRead(Path))
}

; Strips full-line comments so a module docstring merely MENTIONING a call
; (e.g. "released immediately on tap to let AltTabMonitor() fire clean.")
; cannot be mistaken by InStr() for the real call site.
_THFASG_StripLineComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}





; =============================================
; =============================================
; ======= 2/ _TapHoldFireAction (1a/1b) =======
; =============================================
; =============================================

_THFASG_FireActionHasSuspendGuard() {
	GateBody := _DriverFuncBody("TapHoldDispatchTap")
	Assert(GateBody != "", "TapHoldDispatchTap must exist in modules/tap_holds/constants.ahk")

	GuardPos := InStr(GateBody, "A_IsSuspended")
	Assert(GuardPos > 0,
		"TapHoldDispatchTap must check A_IsSuspended before any delayed tap callback")

	DispatchPos := InStr(GateBody, "TapFn.Call()")
	Assert(DispatchPos > 0, "TapHoldDispatchTap must invoke the accepted tap callback")
	Assert(GuardPos < DispatchPos,
		"TapHoldDispatchTap: the A_IsSuspended guard must appear before callback dispatch")

	FireBody := _DriverFuncBody("_TapHoldFireAction")
	Assert(InStr(FireBody, "TapHoldDispatchTap") > 0,
		"_TapHoldFireAction must delegate configured actions to the shared gate")
}
Test("tap_holds: _TapHoldFireAction has A_IsSuspended guard before dispatch (suspend-guard-pattern-1)",
	_THFASG_FireActionHasSuspendGuard)





; ==============================================
; ==============================================
; ======= 3/ lalt.ahk AltTabMonitor (1c) =======
; ==============================================
; ==============================================

_THFASG_LaltAltTabMonitorHasSuspendGuard() {
	Src := _THFASG_ReadSource("modules/tap_holds/lalt.ahk")
	Assert(InStr(Src, 'TapHoldDispatchTap("left_alt", AltTabMonitor)') > 0,
		"lalt.ahk: delayed AltTabMonitor tap must use the central suspend/activity gate")
}
Test("tap_holds: lalt.ahk AltTabMonitor tap has A_IsSuspended guard (suspend-guard-pattern-1)",
	_THFASG_LaltAltTabMonitorHasSuspendGuard)





; =======================================================
; =======================================================
; ======= 4/ tab.ahk AltTabMonitor + Tab+Alt (1c) =======
; =======================================================
; =======================================================

_THFASG_TabAltTabMonitorHasSuspendGuard() {
	Src := _THFASG_ReadSource("modules/tap_holds/tab.ahk")
	Assert(InStr(Src, 'TapHoldDispatchTap("tab", AltTabMonitor)') > 0,
		"tab.ahk: delayed AltTabMonitor tap must use the central suspend/activity gate")
}
Test("tap_holds: tab.ahk AltTabMonitor tap has A_IsSuspended guard (suspend-guard-pattern-1)",
	_THFASG_TabAltTabMonitorHasSuspendGuard)

_THFASG_TabAltAltShortcutHasSuspendGuard() {
	Src := _THFASG_ReadSource("modules/tap_holds/tab.ahk")
	Assert(InStr(Src, 'TapHoldDispatchTap("tab", TextPressKey.Bind("Tab", "Alt"))') > 0,
		"tab.ahk: delayed Tab+Alt output must use the central suspend/activity gate")
}
Test("tap_holds: tab.ahk Tab+Alt (LAlt physically held) branch has A_IsSuspended guard (suspend-guard-pattern-1)",
	_THFASG_TabAltAltShortcutHasSuspendGuard)
