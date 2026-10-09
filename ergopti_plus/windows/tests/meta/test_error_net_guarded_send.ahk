; tests/meta/test_error_net_guarded_send.ahk

; ==============================================================================
; MODULE: Error-Net Guarded SendEvent
; DESCRIPTION:
; Regression guard for AHK-35: ErgoptiGlobalErrorHandler iterated 8 modifier
; keys and called SendEvent("{ModKey Up}") with no try guard. If SendEvent
; throws on a hook conflict or foreground-window race while the error handler
; is already running, AHK aborts the rest of the OnError body, skipping the
; deferred crash report (SetTimer) and tray toast — exactly the modal/lock-up
; the handler exists to prevent.
;
; The bug is acknowledged by the codebase itself: test_uia_wrap_suppress_latch
; notes "a Send can fail on a hook conflict / foreground-window race" and
; space.ahk guards every SendInput with try for this reason. The SendEvent in
; the error handler was the one bare OS call on the unlock path.
;
; Fix (AHK-35): wrap SendEvent in the modifier-release loop with try so a
; failure on one modifier does not abort releasing the others or the net.
;
; This test asserts (source introspection on ErgoptiGlobalErrorHandler):
;   Every SendEvent call in the body is preceded by `try`, so no OS call
;   on the unlock path can abort the deferred crash report + tray toast.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================================================
; ============================================================
; ======= 1/ SendEvent in error handler is try-guarded =======
; ============================================================
; ============================================================

_TENGS_CheckGuardedSend() {
	Body := _DriverFuncBody("ErgoptiGlobalErrorHandler")
	Assert(Body != "", "ErgoptiGlobalErrorHandler() must exist in infra/error_net.ahk")

	; Must have at least one guarded SendEvent
	Assert(InStr(Body, "try SendEvent(") > 0,
		"AHK-35: ErgoptiGlobalErrorHandler must use `try SendEvent(...)` so a throw on the unlock path cannot abort the deferred crash report and tray toast")

	; Must NOT have any bare (unguarded) SendEvent
	; Strip try SendEvent occurrences then assert SendEvent( is absent
	Stripped := StrReplace(Body, "try SendEvent(", "try ___SEND___(")
	Assert(InStr(Stripped, "SendEvent(") = 0,
		"AHK-35: ErgoptiGlobalErrorHandler must not contain any bare SendEvent() outside try — every OS call on the unlock path must be guarded so the net cannot be aborted mid-cleanup")
}


Test("meta ahk-35: every SendEvent in ErgoptiGlobalErrorHandler is guarded with try so the unlock path cannot abort the deferred crash report",
	_TENGS_CheckGuardedSend)
