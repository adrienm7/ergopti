; tests/meta/test_altgr_dispatch_resume_aware.ahk

; ==============================================================================
; MODULE: AltGr Dispatch Resume-Aware Meta Test
; DESCRIPTION:
; Regression guard ensuring the AltGr hotkey registration correctly handles
; BOTH the suspended and active states — the dispatch is resume-aware.
;
; Two related invariants:
;
; A. Per-slot chord debounce (resume-crossing guard)
;    _ScriptAltGrChordDebounce uses a per-slot timestamp to reject callbacks
;    that fire within 80ms of the previous one. This prevents a chord that was
;    physically completed just before a suspend/resume toggle from replaying on
;    the fresh thread spawned after resume — the timestamp comparison catches it.
;
; B. Suspended-state SC138 HotIf block (keyboard control while paused)
;    _RegisterScriptAltGrHotkeys registers a second set of SC138+key hotkeys
;    under HotIf((*) => A_IsSuspended and GetKeyState("SC138", "P")).
;    Without this block, a user pausing from the tray menu or a gesture would
;    have no keyboard way back — the prefix-armed "SC138 & X" combos above can
;    silently stop firing across that kind of pause (hook rebuilt off-thread),
;    and the fallback ^! variant only fires on physical Ctrl+Alt. This block's
;    suffix-only hotkeys need no prefix arming, so they reliably reach
;    _ScriptAltGrDispatch and — same as the active-state path — actually RUN
;    the assigned action (pause toggle / reload / open personal shortcuts /
;    quit), not just pass a native keystroke through.
;
; This test asserts:
;   1. _ScriptAltGrChordDebounce uses a per-slot map keyed on Slot.
;   2. The debounce check appears before the action call in _ScriptAltGrDispatch.
;   3. A HotIf predicate combining A_IsSuspended and SC138 state is registered.
;
; SCOPE: source introspection of infra/script_altgr_hotkeys.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ====================================================
; ====================================================
; ======= 1/ Source scan helpers =====================
; ====================================================
; ====================================================

_ADRA_ReadSource() {
	return _DriverDirConcat("infra")
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_ADRA_ChordDebouncePerSlotMap() {
	Src := _ADRA_ReadSource()
	Assert(Src != "", "infra/ source must be readable")

	Body := _DriverFuncBody("_ScriptAltGrChordDebounce")
	Assert(Body != "", "_ScriptAltGrChordDebounce must be defined in infra/script_altgr_hotkeys.ahk")

	; Must use a static Map to track the last fire time per slot
	Assert(InStr(Body, "static last := Map()") > 0,
		"_ScriptAltGrChordDebounce must use a 'static last := Map()' keyed by Slot — a single shared timestamp would falsely debounce different chords that fire in quick succession on separate keys")
}

Test("script_altgr: _ScriptAltGrChordDebounce uses per-slot static Map (altgr-dispatch-resume-aware)",
	_ADRA_ChordDebouncePerSlotMap)


_ADRA_DebounceBeforeAction() {
	Body := _DriverFuncBody("_ScriptAltGrDispatch")
	Assert(Body != "", "_ScriptAltGrDispatch must be defined — prerequisite for this test")

	DebouncePos := InStr(Body, "_ScriptAltGrChordDebounce(Slot)")
	ActionPos   := InStr(Body, "RunScriptShortcutAction(Slot)")

	Assert(DebouncePos > 0,
		"_ScriptAltGrDispatch must call _ScriptAltGrChordDebounce(Slot) — the debounce guard prevents rapid re-fire across a suspend/resume boundary")
	Assert(ActionPos > 0,
		"_ScriptAltGrDispatch must call RunScriptShortcutAction(Slot)")
	Assert(DebouncePos < ActionPos,
		"_ScriptAltGrChordDebounce must run BEFORE RunScriptShortcutAction in _ScriptAltGrDispatch — the debounce check is what prevents a chord completed just before a suspend/resume toggle from replaying the action on the fresh thread spawned after resume")
}

Test("script_altgr: chord debounce check runs before the action call (altgr-dispatch-resume-aware)",
	_ADRA_DebounceBeforeAction)


_ADRA_SuspendedHotIfBlockRegistered() {
	Body := _DriverFuncBody("_RegisterScriptAltGrHotkeys")
	Assert(Body != "", "_RegisterScriptAltGrHotkeys must be defined in infra/script_altgr_hotkeys.ahk")

	; Must register HotIf context that is active when suspended AND SC138 is held
	Assert(InStr(Body, "A_IsSuspended") > 0 and InStr(Body, "GetKeyState") > 0,
		"_RegisterScriptAltGrHotkeys must register a HotIf predicate that checks both A_IsSuspended and SC138 key state — this pass-through block ensures SC138+key chords still produce output while the driver is suspended")
}

Test("script_altgr: suspended-state HotIf block is registered in _RegisterScriptAltGrHotkeys (altgr-dispatch-resume-aware)",
	_ADRA_SuspendedHotIfBlockRegistered)


_ADRA_ActionUnconditionalOnSuspendState() {
	Body := _DriverFuncBody("_ScriptAltGrDispatch")
	Assert(Body != "", "_ScriptAltGrDispatch must be defined — prerequisite for this test")

	Assert(InStr(Body, "RunScriptShortcutAction(Slot)") > 0,
		"_ScriptAltGrDispatch must call RunScriptShortcutAction(Slot) — the action must fire once a chord is confirmed physically pressed, whether the driver is running or paused")
	Assert(!InStr(Body, "A_IsSuspended"),
		"_ScriptAltGrDispatch must not reference A_IsSuspended at all — the dedicated already-suspended fallback hotkeys (see _RegisterScriptAltGrHotkeys) are what makes paused-state control reachable; a suspend check inside the shared dispatch body would silence RunScriptShortcutAction while paused again")
}

Test("script_altgr: RunScriptShortcutAction fires regardless of suspend state (altgr-dispatch-resume-aware)",
	_ADRA_ActionUnconditionalOnSuspendState)
