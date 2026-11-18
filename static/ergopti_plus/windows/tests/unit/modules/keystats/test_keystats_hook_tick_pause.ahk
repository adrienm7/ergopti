; tests/unit/modules/keystats/test_keystats_hook_tick_pause.ahk

; ==============================================================================
; MODULE: Keystats Flush Tick Under Pause
; DESCRIPTION:
; KL_Hook_Tick is the recurring buffer flush of the keystats hook, and SetTimer
; callbacks keep firing under native Suspend. A paused tick must neither flush
; the typing buffer nor arm the live-push debounce
; (metrics-timers-bypass-pause). The runner's KL_FlushBuffer records each call
; (test_stubs.ahk), so the flush count shows whether the paused tick ran; the
; resumed tick is the positive control.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLHTP_CancelLivePush() {
	if KLHook.HasOwnProp("live_push_timer") && IsObject(KLHook.live_push_timer)
		SetTimer(KLHook.live_push_timer, 0)
}

_KLHTP_PausedTickFlushesNothing() {
	global _Stub_FlushBufferCalls, _Stub_FlushBufferMutates, _Stub_FlushBufferDeferred
	SavedCalls := _Stub_FlushBufferCalls
	SavedMutates := _Stub_FlushBufferMutates
	SavedDeferred := _Stub_FlushBufferDeferred
	SavedEvents := Keystats.buffer_events
	HadTimer := KLHook.HasOwnProp("live_push_timer")
	SavedTimer := HadTimer ? KLHook.live_push_timer : 0
	WasSuspended := A_IsSuspended
	try {
		_Stub_FlushBufferMutates := false
		_Stub_FlushBufferDeferred := false
		Keystats.buffer_events := [Map("type", "keypress")]
		; A fresh debounce slot shows whether the paused tick armed one.
		KLHook.live_push_timer := 0
		_Stub_FlushBufferCalls := 0
		Suspend(true)
		KL_Hook_Tick()
		AssertEqual(0, _Stub_FlushBufferCalls, "a paused flush tick must not flush the typing buffer")
		AssertFalse(IsObject(KLHook.live_push_timer), "a paused flush tick must not arm the live push")
		Suspend(false)
		KL_Hook_Tick()
		AssertEqual(1, _Stub_FlushBufferCalls, "positive control: a running tick flushes the buffer once")
		AssertTrue(IsObject(KLHook.live_push_timer), "positive control: a running tick arms the live push")
	} finally {
		if A_IsSuspended != WasSuspended
			Suspend(WasSuspended)
		_KLHTP_CancelLivePush()
		_Stub_FlushBufferCalls := SavedCalls
		_Stub_FlushBufferMutates := SavedMutates
		_Stub_FlushBufferDeferred := SavedDeferred
		Keystats.buffer_events := SavedEvents
		if HadTimer
			KLHook.live_push_timer := SavedTimer
		else
			KLHook.DeleteProp("live_push_timer")
	}
}
Test("keystats hook: a paused flush tick flushes nothing (metrics-timers-bypass-pause)",
	_KLHTP_PausedTickFlushesNothing)
