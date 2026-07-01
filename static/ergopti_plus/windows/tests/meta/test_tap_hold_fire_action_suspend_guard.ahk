; tests/meta/test_tap_hold_fire_action_suspend_guard.ahk

; ==============================================================================
; MODULE: Tap-Hold Suspend Guard Meta Test (Pattern 1)
; DESCRIPTION:
; Static source guard for the systemic "native Suspend() never disarms a
; tap-hold's own dispatch call" gap-class (docs/PROJECT_MEMORY.md's
; project-suspend-pause-invariant). Covers the shared _TapHoldFireAction
; dispatcher (used by capslock/enter/backspace/delete/escape/win/tab/rctrl/
; lshift_lctrl/rshift/altgr) and the two AltTabMonitor() call sites in
; lalt.ahk/tab.ahk, which dispatch directly instead of going through
; _TapHoldFireAction and therefore need their own guard.
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

; Extract the smallest hotkey block that contains the given needle, delimited
; by the nearest preceding "#HotIf " opener and following bare "#HotIf" closer.
_THFASG_HotIfBlock(Src, Needle) {
	CallPos := InStr(Src, Needle)
	if !CallPos
		return ""

	BlockStart := 0
	SearchFrom := 1
	loop {
		Pos := InStr(Src, "#HotIf ", , SearchFrom)
		if (!Pos or Pos >= CallPos)
			break
		BlockStart := Pos
		SearchFrom := Pos + 1
	}
	if !BlockStart
		return SubStr(Src, 1, CallPos + StrLen(Needle))

	ClosePos := InStr(Src, "`n#HotIf`n", , CallPos)
	if !ClosePos
		ClosePos := InStr(Src, "`n#HotIf`r`n", , CallPos)
	if ClosePos
		return SubStr(Src, BlockStart, ClosePos - BlockStart + 8)
	return SubStr(Src, BlockStart)
}

; Narrow "immediately preceded by" check for call sites that share a HotIf
; block with a SIBLING branch that has its OWN, DIFFERENT guard — a whole-block
; scan would be fooled by the sibling's guard also being "somewhere before"
; this call. Only look at the LookBackChars immediately preceding the call,
; a window wide enough for this call's own guard but too narrow to reach a
; different branch's guard several lines away.
_THFASG_ImmediatelyPrecededBySuspendGuard(Src, CallTarget, LookBackChars := 150) {
	CallPos := InStr(Src, CallTarget)
	if !CallPos
		return false
	WindowStart := Max(1, CallPos - LookBackChars)
	Window := SubStr(Src, WindowStart, CallPos - WindowStart)
	return InStr(Window, "A_IsSuspended") > 0
}





; =============================================
; =============================================
; ======= 2/ _TapHoldFireAction (1a/1b) =======
; =============================================
; =============================================

_THFASG_FireActionHasSuspendGuard() {
	Body := _DriverFuncBody("_TapHoldFireAction")
	Assert(Body != "", "_TapHoldFireAction must exist in modules/tap_holds/constants.ahk")

	GuardPos := InStr(Body, "A_IsSuspended")
	Assert(GuardPos > 0,
		"_TapHoldFireAction must check A_IsSuspended — this is the shared dispatch point for every simple tap-hold key (capslock/enter/backspace/delete/escape/win/tab/rctrl/lshift_lctrl/rshift/altgr); without the guard a tap landing shortly after a Suspend toggle still fires the configured GESTURE_ACTIONS entry (script_reload/script_quit/open_url/take_note, …)")

	DispatchPos := InStr(Body, "GESTURE_ACTIONS[ActionId]")
	Assert(DispatchPos > 0, "_TapHoldFireAction must still dispatch via GESTURE_ACTIONS[ActionId]")
	Assert(GuardPos < DispatchPos,
		"_TapHoldFireAction: the A_IsSuspended guard must appear BEFORE the GESTURE_ACTIONS dispatch call")
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

	CallTarget := "AltTabMonitor()"
	CallPos := InStr(Src, CallTarget)
	Assert(CallPos > 0, "AltTabMonitor() must be called in lalt.ahk")

	Seg := _THFASG_HotIfBlock(Src, CallTarget)
	Assert(Seg != "", "Could not extract the hotkey block containing AltTabMonitor() in lalt.ahk")

	GuardPos := InStr(Seg, "A_IsSuspended")
	Assert(GuardPos > 0,
		"lalt.ahk: the alt_tab_monitor tap block must check A_IsSuspended before AltTabMonitor() — a Suspend toggle mid-KeyWait would still switch the foreground window without this guard")

	LocalCallPos := InStr(Seg, CallTarget)
	Assert(GuardPos < LocalCallPos,
		"lalt.ahk: A_IsSuspended guard must appear BEFORE AltTabMonitor() — a guard placed after the call provides no protection")
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
	Assert(InStr(Src, "AltTabMonitor()") > 0, "AltTabMonitor() must be called in tab.ahk")

	; tab.ahk's alt_tab_monitor block has TWO sibling branches, each with its
	; OWN guard (Tab+Alt when LAlt is physically held; AltTabMonitor()
	; otherwise) — a whole-block scan would be fooled by the sibling branch's
	; guard also being "somewhere earlier" in the block, so this checks only
	; the text immediately preceding THIS call.
	Assert(_THFASG_ImmediatelyPrecededBySuspendGuard(Src, "AltTabMonitor()"),
		"tab.ahk: the AltTabMonitor() branch must check A_IsSuspended immediately before the call — a Suspend toggle mid-KeyWait would still switch the foreground window without this guard")
}
Test("tap_holds: tab.ahk AltTabMonitor tap has A_IsSuspended guard (suspend-guard-pattern-1)",
	_THFASG_TabAltTabMonitorHasSuspendGuard)

_THFASG_TabAltAltShortcutHasSuspendGuard() {
	Src := _THFASG_ReadSource("modules/tap_holds/tab.ahk")
	CallTarget := 'TextPressKey("Tab", "Alt")'
	Assert(InStr(Src, CallTarget) > 0, "tab.ahk must still send Tab+Alt when LAlt is physically held")

	Assert(_THFASG_ImmediatelyPrecededBySuspendGuard(Src, CallTarget),
		"tab.ahk: the LAlt-physically-held Tab+Alt branch must check A_IsSuspended immediately before the send — it emits a real synthetic Alt+Tab keystroke and must not fire while paused")
}
Test("tap_holds: tab.ahk Tab+Alt (LAlt physically held) branch has A_IsSuspended guard (suspend-guard-pattern-1)",
	_THFASG_TabAltAltShortcutHasSuspendGuard)
