; tests/meta/test_altgr_dispatch_suspend_guard.ahk

; ==============================================================================
; MODULE: AltGr Dispatch Suspend Guard Meta Test
; DESCRIPTION:
; Regression guard ensuring _ScriptAltGrDispatch always runs the assigned
; script-control action once a chord is confirmed physically pressed —
; including while the driver is suspended.
;
; _RegisterScriptAltGrHotkeys() registers a dedicated set of suffix-only
; hotkeys (gated on "A_IsSuspended and GetKeyState(SC138, 'P')") specifically
; so the four script-management chords (pause toggle, reload, open personal
; shortcuts, quit) keep working from the keyboard while paused — otherwise a
; user who pauses via the tray menu or a gesture has no keyboard way back. A
; blanket "if A_IsSuspended: passthrough" bail (added later to guard against a
; stale in-flight chord) silently defeated that mechanism:
; RunScriptShortcutAction(Slot) was never reached while suspended, so
; AltGr+Enter could no longer resume and AltGr+BackSpace could no longer
; reload — the script became unrecoverable from the keyboard once paused.
;
; SCOPE: source introspection of infra/script_altgr_hotkeys.ahk.
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


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_ADSG_CheckActionAlwaysRuns() {
	Src := _ADSG_ReadSource("infra/script_altgr_hotkeys.ahk")
	Assert(Src != "", "infra/script_altgr_hotkeys.ahk must be readable")

	Body := _DriverFuncBody("_ScriptAltGrDispatch")
	Assert(Body != "", "_ScriptAltGrDispatch must be present in infra/script_altgr_hotkeys.ahk")

	ActionPos := InStr(Body, "RunScriptShortcutAction(Slot)")
	Assert(ActionPos > 0, "_ScriptAltGrDispatch must call RunScriptShortcutAction(Slot)")

	; The only early-return before the action call must be the "not physically
	; pressed" guard (_ScriptAltGrIsPhysical) — a bare "if A_IsSuspended" bail
	; between that guard and the action call would once again make the paused-
	; state script-control shortcuts unreachable.
	PhysicalGuardPos := InStr(Body, "_ScriptAltGrIsPhysical")
	Assert(PhysicalGuardPos > 0 and PhysicalGuardPos < ActionPos,
		"_ScriptAltGrDispatch must still guard on _ScriptAltGrIsPhysical before running the action")

	Between := SubStr(Body, PhysicalGuardPos, ActionPos - PhysicalGuardPos)
	Assert(!InStr(Between, "A_IsSuspended"),
		"_ScriptAltGrDispatch must not bail out on A_IsSuspended before RunScriptShortcutAction(Slot) -- the dedicated suspended-state hotkeys exist precisely so pause/reload/quit/open-personal-shortcuts keep working from the keyboard while paused")
}

_ADSG_CheckSuspendedFallbackHotkeysStillRegistered() {
	Body := _DriverFuncBody("_RegisterScriptAltGrHotkeys")
	Assert(Body != "", "_RegisterScriptAltGrHotkeys must be present in infra/script_altgr_hotkeys.ahk")
	Assert(InStr(Body, "A_IsSuspended and GetKeyState(") > 0,
		"_RegisterScriptAltGrHotkeys must still register the dedicated already-suspended fallback hotkeys (SC01C/SC00E/SC153/SC001 gated on A_IsSuspended) so paused-state control stays reachable")
}


Test("meta altgr-dispatch-suspend-guard: _ScriptAltGrDispatch runs the action even while suspended (once physically pressed)",
	_ADSG_CheckActionAlwaysRuns)
Test("meta altgr-dispatch-suspend-guard: suspended-state fallback hotkeys remain registered",
	_ADSG_CheckSuspendedFallbackHotkeysStillRegistered)

; F39 (audit 2026-07-20): the suspend exemption on these chords exists ONLY so script
; management stays keyboard-reachable while paused. RunScriptShortcutAction forwarded
; to GestureInvokeAction with no allowlist, so the exemption silently widened to
; whatever the user assigned — a paused driver still fired arbitrary gesture actions,
; breaking "pause = tout éteint".
_ADSG_SuspendExemptionIsScopedToManagement() {
	Body := _DriverFuncBody("RunScriptShortcutAction")
	Assert(Body != "", "RunScriptShortcutAction must exist in infra/config_io.ahk")
	GatePos := InStr(Body, "A_IsSuspended")
	InvokePos := InStr(Body, "GestureInvokeAction(")
	Assert(GatePos > 0 && InvokePos > GatePos,
		"RunScriptShortcutAction must check A_IsSuspended BEFORE invoking the action, so a paused driver cannot run an arbitrary assignment")
	Assert(InStr(Body, "SCRIPT_SHORTCUT_SUSPEND_ALLOWED") > 0,
		"the suspended path must consult the script-management allowlist")

	Allow := _DriverSourceConcat()
	for Action in ["script_pause_toggle", "script_reload", "script_quit", "open_personal_shortcuts"] {
		Assert(InStr(Allow, Chr(0x22) . Action . Chr(0x22) . ", true") > 0,
			"the suspend allowlist must keep " . Action . " reachable from the keyboard while paused")
	}
}
Test("meta altgr-dispatch-suspend-guard: the suspend exemption is scoped to script management",
	_ADSG_SuspendExemptionIsScopedToManagement)
