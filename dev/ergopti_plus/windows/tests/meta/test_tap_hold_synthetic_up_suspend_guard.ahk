; tests/meta/test_tap_hold_synthetic_up_suspend_guard.ahk

; ==============================================================================
; MODULE: TapHoldSyntheticKeyUp never injects while suspended
; DESCRIPTION:
; TapHoldSyntheticKeyDown refuses to arm while suspended, but TapHoldSyntheticKeyUp's
; untracked-key fallback sent TextPressKey(Key, "Up") UNCONDITIONALLY "for
; idempotence". After a suspend cleanup released the tracked keys, a still-running
; tap-hold finally then hit that fallback and injected a synthetic Up into a paused
; session — an unbalanced Up that can clear a modifier the user is physically holding
; (« pause = tout éteint »). The fallback must guard on A_IsSuspended before the Up.
; (F30, audit 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_THSU_UntrackedUpGuardedBySuspend() {
	Body := _DriverFuncBody("TapHoldSyntheticKeyUp")
	Assert(Body != "", "TapHoldSyntheticKeyUp must exist in modules/tap_holds/constants.ahk")

	; The untracked-key branch's first synthetic Up must be preceded by an
	; A_IsSuspended guard that returns without injecting.
	SuspendPos := InStr(Body, "A_IsSuspended")
	UpPos := InStr(Body, 'TextPressKey(Key, "Up")')
	Assert(SuspendPos > 0,
		"TapHoldSyntheticKeyUp must guard on A_IsSuspended before injecting a synthetic Up (a suspended driver injects nothing)")
	Assert(UpPos > 0, "TapHoldSyntheticKeyUp must still send the Up on the live path")
	Assert(SuspendPos < UpPos,
		"the A_IsSuspended guard must precede the first TextPressKey(Key, Up) so an untracked key is never released into a paused session")
}
Test("tap-holds: synthetic key-Up is not injected while the driver is suspended",
	_THSU_UntrackedUpGuardedBySuspend)
