; tests/meta/test_toggle_capslock_calls_disable_capsword.ahk

; ==============================================================================
; MODULE: ToggleCapsLock DisableCapsWord Delegation Meta Test
; DESCRIPTION:
; Regression guard ensuring ToggleCapsLock routes through DisableCapsWord
; instead of directly setting CapsWordEnabled := False.
;
; The bug: ToggleCapsLock set CapsWordEnabled := False directly, bypassing
; DisableCapsWord.  DisableCapsWord performs subscriber cleanup —
; HookDispatcher.Unregister for the mouse-down listeners that CapsWord arms
; to detect deactivation clicks.  Skipping it left those listeners permanently
; registered after a CapsLock toggle, causing a subscriber leak: subsequent
; mouse clicks would fire the mouse-down handler even when CapsWord was off,
; and HookDispatcher's listener list would grow unboundedly across toggle cycles.
;
; The fix: call DisableCapsWord() (guarded with IsSet) in ToggleCapsLock so
; every deactivation path — including the hardware toggle — runs the full
; teardown.
;
; SCOPE: source introspection of platform/remap/one_shot_shift.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =================================================
; =================================================
; ======= 1/ Source scan helpers ==================
; =================================================
; =================================================

_TCDCW_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Path := WindowsDir . "\" . StrReplace(RelPath, "/", "\")
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_TCDCW_CheckCallsDisableCapsWord() {
	Src := _TCDCW_ReadSource("platform/remap/one_shot_shift.ahk")
	Assert(Src != "", "platform/remap/one_shot_shift.ahk must be readable")

	Body := _DriverFuncBody("ToggleCapsLock")
	Assert(Body != "", "ToggleCapsLock must be present in one_shot_shift.ahk")

	Assert(InStr(Body, "DisableCapsWord()"),
		"ToggleCapsLock must call DisableCapsWord() so mouse-down subscriber cleanup runs")
}

_TCDCW_CheckNoDirectFalseAssign() {
	Src := _TCDCW_ReadSource("platform/remap/one_shot_shift.ahk")
	Assert(Src != "", "platform/remap/one_shot_shift.ahk must be readable")

	Body := _DriverFuncBody("ToggleCapsLock")
	Assert(Body != "", "ToggleCapsLock must be present in one_shot_shift.ahk")

	; The bare assignment (without the else/fallback path) must not appear as
	; the sole cleanup mechanism — DisableCapsWord must be preferred
	DisablePos    := InStr(Body, "DisableCapsWord()")
	DirectPos     := InStr(Body, "CapsWordEnabled := False")

	; Either DisableCapsWord is the primary path (no direct assign at all),
	; or the direct assign is a guarded fallback after DisableCapsWord
	if (DirectPos > 0)
		Assert(DisablePos < DirectPos,
			"When both DisableCapsWord and a direct CapsWordEnabled assign exist in ToggleCapsLock, DisableCapsWord must come first (fallback pattern)")
	else
		Assert(DisablePos > 0,
			"ToggleCapsLock must call DisableCapsWord() for subscriber cleanup")
}


Test("meta toggle-capslock: ToggleCapsLock calls DisableCapsWord for full subscriber teardown",
	_TCDCW_CheckCallsDisableCapsWord)

Test("meta toggle-capslock: DisableCapsWord precedes any direct CapsWordEnabled assignment in ToggleCapsLock",
	_TCDCW_CheckNoDirectFalseAssign)
