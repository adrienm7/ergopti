; tests/meta/platform/remap/layers/test_deadkey_suspend_guard.ahk

; ==============================================================================
; MODULE: DeadKey Suspend Guard Meta Test
; DESCRIPTION:
; Static source guard for finding
; "deadkey-inputhook-no-timeout-no-suspend-guard".
;
; AHK Suspend disarms hotkeys/hotstrings but does NOT stop a live InputHook, so
; the dead-key state machine bypasses native pause. Without an A_IsSuspended
; guard at the top of DeadKey(), a dead-key keypress slipping through while the
; driver is paused would still arm the InputHook and capture/remap the user's
; next physical key - violating the "pause = tout eteint" invariant.
;
; The fix adds `if A_IsSuspended return` before InDeadKeySequence is set. This
; is a meta-static test because layout.ahk registers top-level hotkeys and
; cannot be #Included by the headless runner; it scans source text so a
; regression that removes the guard fails the suite.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

_DKSG_ReadSource(FileName) {
	return _DriverFileSource(FileName)
}


; ==================================================
; ==================================================
; ======= 2/ Suspend-guard assertion ===============
; ==================================================
; ==================================================

_DKSG_AssertDeadKeyHasSuspendGuard() {
	Src := _DKSG_ReadSource("layout.ahk")
	Body := _DriverFuncBody("DeadKey")
	Assert(Body != "", "DeadKey(Mapping) declaration must exist in layout.ahk")
	Assert(InStr(Body, "A_IsSuspended") > 0,
		"DeadKey must check A_IsSuspended and no-op while paused - a live InputHook bypasses native Suspend (deadkey-inputhook-no-timeout-no-suspend-guard)")
}
Test("layout: DeadKey has an A_IsSuspended pause guard (deadkey-inputhook-no-timeout-no-suspend-guard)", _DKSG_AssertDeadKeyHasSuspendGuard)

; The ENTRY guard alone is insufficient: ih.Wait() pumps the message loop, so a
; pause can land DURING the wait. The post-Wait emit path must re-check
; A_IsSuspended before SendNewResult or a dead-key sequence armed just before pause
; emits a remapped character while the driver is paused.
_DKSG_AssertDeadKeyRechecksSuspendAfterWait() {
	Body := _DriverFuncBody("DeadKey")
	Assert(Body != "", "DeadKey(Mapping) declaration must exist in layout.ahk")
	WaitIdx := InStr(Body, "ih.Wait()")
	Assert(WaitIdx > 0, "DeadKey must call ih.Wait()")
	PostGuardIdx := InStr(Body, "A_IsSuspended", , WaitIdx + 1)
	Assert(PostGuardIdx > WaitIdx,
		"DeadKey must re-check A_IsSuspended AFTER ih.Wait() — a pause can land during the wait and a live InputHook bypasses native Suspend (deadkey-inputhook-post-wait-suspend-leak)")
	FirstEmitIdx := InStr(Body, "SendNewResult", , WaitIdx + 1)
	Assert(FirstEmitIdx == 0 or PostGuardIdx < FirstEmitIdx,
		"DeadKey post-Wait A_IsSuspended re-check must precede the first post-Wait SendNewResult emit (deadkey-inputhook-post-wait-suspend-leak)")
}
Test("layout: DeadKey re-checks A_IsSuspended after ih.Wait() (deadkey-inputhook-post-wait-suspend-leak)", _DKSG_AssertDeadKeyRechecksSuspendAfterWait)

; A registry layout's pending dead key is a plain KLE_State string, which no
; InputHook teardown reaches: it survived pause and resume, so the first key
; typed after resuming composed with a dead key pressed before the pause.
; Pausing cancels it like the legacy transaction (maintainer decision,
; dead-key lifecycle), from the suspend entry, after the hooks stop.
_DKSG_AssertSuspendCancelsRegistryDeadKey() {
	Body := _DriverFuncBody("Ergopti_OnSuspendEnter")
	Assert(Body != "", "Ergopti_OnSuspendEnter() must exist")
	Hooks := InStr(Body, '"suppressive-input-hooks"', true)
	Reset := InStr(Body, "KeylayoutEmulation_ResetDeadKey()", true)
	Assert(Hooks > 0 && Reset > Hooks,
		"pausing must cancel the registry layout's pending dead key after stopping the capture hooks (dead-key lifecycle)")
	Assert(InStr(Body, '"keylayout-dead-key"', true) > 0,
		"the registry dead-key reset must be a named lifecycle step so a failure is logged (dead-key lifecycle)")
	Assert(_DriverFuncBody("KeylayoutEmulation_ResetDeadKey") != "",
		"KeylayoutEmulation_ResetDeadKey() must exist, or the IsSet guard skips the reset silently")
}
Test("lifecycle: pausing cancels the registry layout's pending dead key (dead-key lifecycle)", _DKSG_AssertSuspendCancelsRegistryDeadKey)
