; tests/meta/test_tap_hold_native_dispatch_guard.ahk

; ==============================================================================
; MODULE: Tap-Hold Native Dispatch Guard Meta Tests
; DESCRIPTION:
; Ensures every delayed tap output, including native Space/Enter/Backspace/
; Escape/Delete and special Alt/Tab/one-shot paths, uses the same activity
; cancellation gate as configurable GESTURE_ACTIONS outputs.
; ==============================================================================

#Requires AutoHotkey v2.0





_THNG_Count(Haystack, Needle) {
	Count := 0
	Pos := 1
	while Found := InStr(Haystack, Needle, , Pos) {
		Count++
		Pos := Found + StrLen(Needle)
	}
	return Count
}

_THNG_ReadTapHoldSource(FileName) {
	SplitPath(A_ScriptDir, , &DriverRoot)
	return FileRead(DriverRoot . "\modules\tap_holds\" . FileName)
}

_THNG_CentralGateOwnsCleanup() {
	Body := _DriverFuncBody("TapHoldDispatchTap")
	Assert(Body != "", "TapHoldDispatchTap must exist as the single tap-output gate")
	Assert(InStr(Body, "TapHoldShouldCancelTap") > 0,
		"TapHoldDispatchTap must consult the activity-cancellation state")
	Assert(InStr(Body, "A_IsSuspended") > 0,
		"TapHoldDispatchTap must preserve the global pause invariant")
	CancelPos := InStr(Body, "TapHoldShouldCancelTap")
	CallPos := InStr(Body, "TapFn.Call()")
	Assert(CallPos > CancelPos,
		"TapHoldDispatchTap must decide cancellation before invoking the tap callback")
	Assert(InStr(Body, "finally") > 0 && InStr(Body, "TapHoldForgetTrackedKey") > 0,
		"TapHoldDispatchTap must consume tracked state in finally on allow, cancel, or throw")
}
Test("tap-hold: central dispatch gate checks activity and always cleans state", _THNG_CentralGateOwnsCleanup)

_THNG_NativeTapOutputsUseCentralGate() {
	Files := Map(
		"space", "space.ahk",
		"enter", "enter.ahk",
		"backspace", "backspace.ahk",
		"escape", "escape.ahk",
		"delete", "delete.ahk",
		"caps_lock", "capslock.ahk"
	)
	for KeyId, FileName in Files {
		Src := _THNG_ReadTapHoldSource(FileName)
		Needle := "TapHoldDispatchTap(" . Chr(34) . KeyId . Chr(34)
		Assert(InStr(Src, Needle) > 0,
			FileName . " must route native/special tap output through TapHoldDispatchTap for key=" . KeyId)
	}
}
Test("tap-hold: native Space/Enter/editing taps use the central cancellation gate", _THNG_NativeTapOutputsUseCentralGate)

_THNG_SpecialDelayedTapPathsUseCentralGate() {
	Expected := Map(
		"right_ctrl", Map("file", "rctrl.ahk", "count", 2), ; tab + one-shot-shift
		"left_alt", Map("file", "lalt.ahk", "count", 4),     ; tab, monitor, two backspace paths
		"tab", Map("file", "tab.ahk", "count", 2)            ; Alt+Tab and monitor branches
	)
	for KeyId, Spec in Expected {
		Src := _THNG_ReadTapHoldSource(Spec["file"])
		Needle := "TapHoldDispatchTap(" . Chr(34) . KeyId . Chr(34)
		Assert(_THNG_Count(Src, Needle) >= Spec["count"],
			Spec["file"] . " must gate every delayed special tap path for key=" . KeyId)
	}
}
Test("tap-hold: delayed Tab/Alt/one-shot special paths use the central cancellation gate", _THNG_SpecialDelayedTapPathsUseCentralGate)

