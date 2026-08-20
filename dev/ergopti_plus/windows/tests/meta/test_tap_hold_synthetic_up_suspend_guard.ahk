; tests/meta/test_tap_hold_synthetic_up_suspend_guard.ahk

; ==============================================================================
; MODULE: Untracked TapHoldSyntheticKeyUp never injects while suspended
; DESCRIPTION:
; TapHoldSyntheticKeyDown refuses to arm while suspended, but TapHoldSyntheticKeyUp's
; untracked-key fallback sent TextPressKey(Key, "Up") UNCONDITIONALLY "for
; idempotence". After a suspend cleanup released the tracked keys, a still-running
; tap-hold finally then hit that fallback and injected a synthetic Up into a paused
; session — an unbalanced Up that can clear a modifier the user is physically holding
; (« pause = tout éteint »). A tracked release-pending key is different: its failed
; Up is lifecycle-owned and must remain retryable even during Suspend. The guard must
; therefore precede only the UNTRACKED fallback, not the pending-release branch.
; (F30, audit 2026-07-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

_THSU_UntrackedUpGuardedBySuspend() {
	Body := _DriverFuncBody("TapHoldSyntheticKeyUp")
	RetryBody := _DriverFuncBody("_TH_RetrySyntheticKeyRelease")
	Assert(Body != "", "TapHoldSyntheticKeyUp must exist in platform/remap/constants.ahk")
	Assert(RetryBody != "", "_TH_RetrySyntheticKeyRelease must own the bounded physical Up")

	; Pending ownership is checked first so Suspend cleanup can finish a failed
	; release. The untracked branch's pending mark/send must follow the guard.
	PendingPos := InStr(Body, "_TH_SyntheticReleasePendingKeys.Has(Name)")
	SuspendPos := InStr(Body, "A_IsSuspended")
	UntrackedReleasePos := InStr(Body, "_TH_MarkSyntheticKeyReleasePending(Name)", , SuspendPos)
	UpPos := InStr(RetryBody, 'TextPressKey(Key, "Up", false)')
	Assert(PendingPos > 0 and PendingPos < SuspendPos,
		"a known failed Up must remain retryable during Suspend before the untracked guard runs")
	Assert(SuspendPos > 0,
		"TapHoldSyntheticKeyUp must guard on A_IsSuspended before injecting a synthetic Up (a suspended driver injects nothing)")
	Assert(UntrackedReleasePos > SuspendPos,
		"the A_IsSuspended guard must precede creation of an untracked release owner")
	Assert(UpPos > 0,
		"the retry helper must still send the physical Up through the boolean TextPressKey contract")
}
Test("tap-holds AHK-03: synthetic key-Up is not injected while the driver is suspended",
	_THSU_UntrackedUpGuardedBySuspend)
