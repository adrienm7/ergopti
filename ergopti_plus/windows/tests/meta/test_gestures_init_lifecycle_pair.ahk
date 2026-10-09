; tests/meta/test_gestures_init_lifecycle_pair.ahk

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
