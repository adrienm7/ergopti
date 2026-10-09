; tests/meta/test_deadkey_suspend_guard.ahk

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

_DKSG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ==================================================
; ==================================================
; ======= 2/ Suspend-guard assertion ===============
; ==================================================
; ==================================================

_DKSG_AssertDeadKeyHasSuspendGuard() {
	Src := _DKSG_ReadSource("modules/keymap/layout.ahk")
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
