; tests/meta/test_space_hold_exception_guard.ahk

#Requires AutoHotkey v2.0

_SHEG_AssertSpaceHoldTryGuard() {
	HoldBody := _DriverFuncBody("TapHoldOwnImmediateModifier")
	Assert(HoldBody != "", "the shared immediate modifier owner must exist")
	Assert(RegExMatch(HoldBody, "finally\s*\{[\s\S]*KeyUpFn\.Call\(ModKey\)") > 0,
		"every Space/modifier wait failure must release through the shared finally")
}

Test("tap_holds: Space shares exception-safe immediate modifier ownership (space-hold-exception-guard)", _SHEG_AssertSpaceHoldTryGuard)
