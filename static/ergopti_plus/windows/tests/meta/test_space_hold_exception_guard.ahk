; tests/meta/test_space_hold_exception_guard.ahk

#Requires AutoHotkey v2.0

_SHEG_AssertSpaceHoldTryGuard() {
	; All Space hold modifiers now share one implementation. Keep the guard on the
	; common arm/release path so every configured modifier has the same safety.
	HoldBody := _DriverFuncBody("_SpaceHoldWithModifier")
	SendBody := _DriverFuncBody("_SpaceSendWithModifiers")
	Q := Chr(34)
	Assert(HoldBody != "", "_SpaceHoldWithModifier must exist in space.ahk")
	Assert(SendBody != "", "_SpaceSendWithModifiers must exist in space.ahk")
	Assert(RegExMatch(HoldBody, "try\s*\{[\s\S]*_SpaceSendWithModifiers\(captured, ModKey\)") > 0,
		"_SpaceHoldWithModifier must protect the dynamic send in a try block (space-hold-exception-guard)")
	Assert(RegExMatch(HoldBody, "finally\s*\{[\s\S]*TapHoldSyntheticKeyUp\(ModKey\)") > 0,
		"_SpaceHoldWithModifier must always release its modifier in finally (space-hold-exception-guard)")
	Assert(InStr(SendBody, 'RegExReplace(captured, "([!#^+{}])", "{$1}")') > 0,
		"_SpaceSendWithModifiers must escape characters before SendInput (space-hold-exception-guard)")
	Assert(InStr(SendBody, "_AHK_SendInput.Call") > 0,
		"_SpaceSendWithModifiers must dispatch the captured character through the guarded common sender (space-hold-exception-guard)")
}

Test("tap_holds: generic space hold path guards dynamic SendInput against unhandled exceptions (space-hold-exception-guard)", _SHEG_AssertSpaceHoldTryGuard)
