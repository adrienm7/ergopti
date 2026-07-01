; tests/meta/test_gesture_cycling_flag_critical.ahk

; ==============================================================================
; MODULE: Gesture Cycling Flag Critical-Section Meta Test
; DESCRIPTION:
; Regression guard: _GestureCycling is a single plain global boolean shared
; across the four independently-dispatchable window-cycle gesture hotkeys
; (win_next/win_prev/app_win_next/app_win_prev all funnel through
; GestureCycleWindows/GestureCycleAppWindows). Unlike hook_dispatcher.ahk's
; established pattern for the same class of shared-state mutation, the
; set-activate-clear bracket had no Critical section, leaving a narrow,
; load-dependent race window where a second window-cycle gesture firing on
; its own pseudo-thread mid-activation could clear the flag early.
;
; This is a DIFFERENT concern from test_gesture_cycle_winevent_fence.ahk (the
; async-WinEvent-arrives-after-clear race, already fenced via
; _GestureSelfActivated) -- this guards the flag/activation bracket itself
; against a second gesture hotkey's pseudo-thread interleaving.
;
; SCOPE: source introspection of modules/gestures/window_cycle.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================================
; =====================================================
; ======= 1/ Critical brackets the flag+activation ====
; =====================================================
; =====================================================

_GCFC_CheckCriticalBracket(FuncName) {
	Body := _DriverFuncBody(FuncName)
	Assert(Body != "", FuncName . " must exist in modules/gestures/window_cycle.ahk")

	CriticalOnPos := InStr(Body, 'Critical("On")')
	Assert(CriticalOnPos > 0,
		FuncName . " must engage Critical(" . Chr(34) . "On" . Chr(34) . ") around the _GestureCycling set/activate/clear bracket -- a plain global boolean shared across 4 independently-dispatchable gesture hotkeys needs the same serialization hook_dispatcher.ahk already uses for its shared-state mutations")

	SetPos := InStr(Body, "_GestureCycling := True")
	ClearPos := InStr(Body, "_GestureCycling := False")
	Assert(SetPos > CriticalOnPos, FuncName . ': _GestureCycling := True must be set AFTER Critical("On") engages')
	Assert(ClearPos > SetPos, FuncName . ": _GestureCycling := False must clear after it was set")

	; The clear must be in a finally so a thrown GestureActivateWindow cannot
	; leave the flag stuck true forever.
	FinallyPos := InStr(Body, "} finally {")
	Assert(FinallyPos > 0 and FinallyPos < ClearPos,
		FuncName . ": _GestureCycling := False must run inside a finally block so a thrown GestureActivateWindow cannot leave the flag stuck true")
}

Test("gestures: GestureCycleWindows brackets _GestureCycling with Critical + finally (gesture-cycling-flag-race)",
	() => _GCFC_CheckCriticalBracket("GestureCycleWindows"))

Test("gestures: GestureCycleAppWindows brackets _GestureCycling with Critical + finally (gesture-cycling-flag-race)",
	() => _GCFC_CheckCriticalBracket("GestureCycleAppWindows"))
