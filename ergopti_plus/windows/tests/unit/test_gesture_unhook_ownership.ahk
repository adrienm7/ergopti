; tests/unit/test_gesture_unhook_ownership.ahk

; ==============================================================================
; MODULE: Gesture WinEvent Teardown Ownership Tests
; DESCRIPTION:
; Proves a refused native WinEvent unhook retains both the hook handle and its
; callback thunk until a later successful retry can retire them safely.
; ==============================================================================

#Requires AutoHotkey v2.0

global _GUO_UnhookAllowed := false
global _GUO_UnhookCalls := []
global _GUO_FreeCalls := []

_GUO_Unhook(Hook) {
	global _GUO_UnhookAllowed, _GUO_UnhookCalls
	_GUO_UnhookCalls.Push(Hook)
	return _GUO_UnhookAllowed
}

_GUO_Free(CallbackPtr) {
	global _GUO_FreeCalls
	_GUO_FreeCalls.Push(CallbackPtr)
}

_GUO_RefusalRetainsNativeOwnership() {
	global _GestureWinHook, _GestureCallbackPtr
	global _GUO_UnhookAllowed, _GUO_UnhookCalls, _GUO_FreeCalls
	_GestureWinHook := 12001
	_GestureCallbackPtr := 13001
	_GUO_UnhookAllowed := false
	_GUO_UnhookCalls := []
	_GUO_FreeCalls := []

	AssertFalse(_GestureReleaseWinHook(_GUO_Unhook, _GUO_Free),
		"a refused native unhook must remain observable")
	AssertEqual(12001, _GestureWinHook,
		"a refused native unhook must retain the exact hook handle")
	AssertEqual(13001, _GestureCallbackPtr,
		"a refused native unhook must retain its callback thunk")
	AssertEqual(1, _GUO_UnhookCalls.Length)
	AssertEqual(0, _GUO_FreeCalls.Length,
		"the callback must remain executable while User32 owns the hook")

	_GUO_UnhookAllowed := true
	AssertTrue(_GestureReleaseWinHook(_GUO_Unhook, _GUO_Free),
		"a later teardown must retry retained native ownership")
	AssertEqual(0, _GestureWinHook)
	AssertEqual(0, _GestureCallbackPtr)
	AssertEqual(2, _GUO_UnhookCalls.Length)
	AssertEqual(1, _GUO_FreeCalls.Length)
	AssertEqual(13001, _GUO_FreeCalls[1])
}
Test("gestures: failed WinEvent unhook retains callback ownership (ahk-126)",
	_GUO_RefusalRetainsNativeOwnership)
