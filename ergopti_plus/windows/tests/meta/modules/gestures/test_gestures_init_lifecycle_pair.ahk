; tests/meta/modules/gestures/test_gestures_init_lifecycle_pair.ahk

; ==============================================================================
; MODULE: Gestures Init Lifecycle Pair Meta Test
; DESCRIPTION:
; modules/gestures/init.ahk announced "Gestures module initialised — ready" with
; a LoggerSuccess that had no LoggerStart anywhere in the file, and it announced
; it unconditionally — including when the SetWinEventHook immediately above had
; returned 0.
;
; Two defects in one line. The readiness claim asserted more than was achieved:
; a failed hook leaves window-order tracking dead, so window-cycle gestures do
; nothing while the log says ready. And a SUCCESS with no START inverts this
; project's silent-failure signal (conventions 4.2) — the module runs an
; unprotected CallbackCreate and DllCall at load, so an abort there produced no
; log line at all, making "gestures failed" indistinguishable from "gestures was
; never reached". Across ten days of real logs the tag recorded 61 SUCCESS lines
; and zero START lines.
;
; FEATURES & RATIONALE:
; 1. Encodes both halves of the ROOT CAUSE: the pair must be opened, and the
;    readiness claim must be conditioned on the hook result.
; 2. Pins ORDER, not just presence — a START after the SUCCESS would satisfy a
;    naive substring check while bracketing nothing.
;
; SCOPE: source introspection of modules/gestures via the move-resilient helper.
; ==============================================================================

#Requires AutoHotkey v2.0


; ================================================
; ================================================
; ======= 1/ The readiness claim is bracketed ====
; ================================================
; ================================================

_GILP_ReadyIsBracketedByAStart() {
	Src := _DriverDirConcat("modules/gestures")
	Assert(Src != "", "the gestures module source must be readable")

	ReadyPos := InStr(Src, 'LoggerSuccess("gestures", "Gestures module initialised')
	Assert(ReadyPos > 0, "the gestures readiness SUCCESS line must still exist")

	StartPos := InStr(Src, 'LoggerStart("gestures", "Initialising gestures module')
	Assert(StartPos > 0,
		"the gestures module must OPEN a lifecycle pair before claiming readiness — a SUCCESS with no START inverts the project's silent-failure signal, and this module runs an unprotected CallbackCreate and DllCall at load")
	Assert(StartPos < ReadyPos,
		"the LoggerStart must come BEFORE the readiness SUCCESS, otherwise it brackets nothing")
}

; The hook result must be checked, and the readiness line must report it. A
; SetWinEventHook that returns 0 is a silent, total loss of window-order
; tracking — the feature the hook exists for.
_GILP_HookFailureIsReported() {
	Src := _DriverDirConcat("modules/gestures")

	HookPos := InStr(Src, '_GestureWinHook := DllCall("SetWinEventHook"')
	Assert(HookPos > 0, "the SetWinEventHook registration must still exist")

	ReadyPos := InStr(Src, 'LoggerSuccess("gestures", "Gestures module initialised')
	Assert(ReadyPos > HookPos, "the readiness line must follow the hook registration")

	Between := SubStr(Src, HookPos, ReadyPos - HookPos)
	Assert(InStr(Between, "if !_GestureWinHook") > 0,
		"a SetWinEventHook returning 0 must be detected — unchecked, window-order tracking dies silently while the module still reports ready")
	Assert(InStr(Between, "LoggerError") > 0,
		"a failed window hook must be reported at ERROR: it is a total loss of the window-cycle gesture feature, not a degraded mode")

	; The readiness line itself must be conditioned on the hook state rather than
	; asserting a flat "ready" it cannot vouch for.
	ReadyLine := SubStr(Src, ReadyPos, 220)
	Assert(InStr(ReadyLine, "_GestureWinHook") > 0,
		"the readiness message must report the actual hook state, so it can never claim more than was achieved")
}


Test("meta gestures: the readiness SUCCESS is bracketed by a real LoggerStart",
	_GILP_ReadyIsBracketedByAStart)
Test("meta gestures: a failed window hook is detected and reported, not announced as ready",
	_GILP_HookFailureIsReported)

; Regression: CallbackCreate pointer never stored; CallbackFree never called
TestAuditV4_CallbackFree() {
	; Callback creation stays in init while the ownership-aware release helper
	; lives in window_cycle. The behavioral ahk-126 test pins native refusal;
	; this legacy source ratchet only prevents the original thunk leak returning.
	Src := _DriverDirConcat("modules/gestures")
	ReleaseBody := _DriverFuncBody("_GestureReleaseWinHook")
	UnhookBody := _DriverFuncBody("_GestureUnhook")

	; The bug: CallbackCreate returned directly to SetWinEventHook with no store;
	; _GestureUnhook only called UnhookWinEvent, leaking the thunk.
	; The fix: store in _GestureCallbackPtr and retire it through the shared
	; helper only after its native hook has been detached.
	AssertTrue(
		InStr(Src, "_GestureCallbackPtr"),
		"gestures.ahk must store CallbackCreate result in _GestureCallbackPtr"
	)
	AssertTrue(ReleaseBody != "" && InStr(ReleaseBody, "FreeFn.Call(CallbackPtr)"),
		"gesture WinEvent teardown must release the retained callback thunk")
	AssertTrue(UnhookBody != "" && InStr(UnhookBody, "_GestureReleaseWinHook()"),
		"_GestureUnhook must delegate native ownership retirement to the shared helper")
}
Test("gestures: CallbackCreate pointer stored and retired by gesture teardown", TestAuditV4_CallbackFree)
