; tests/meta/test_owned_inputhooks_suspend.ahk
#Requires AutoHotkey v2.0

_OIH_AssertSuspendOwnedHook(FunctionName, HookName) {
	Body := _DriverFuncBody(FunctionName)
	Lifecycle := _DriverFuncBody("Ergopti_OnSuspendEnter")
	Q := Chr(34)
	Assert(InStr(Body, "global " . HookName . " :=") > 0,
		FunctionName . " must publish its live InputHook for lifecycle ownership")
	Assert(InStr(Body, "finally") > 0 and InStr(Body, HookName . " := " . Q . Q) > 0,
		FunctionName . " must clear its InputHook owner in finally")
	Assert(InStr(Lifecycle, HookName . ".Stop()") > 0,
		"Suspend enter must synchronously stop " . HookName . " before input can be swallowed")
}

_OIH_SpaceAndOneShotHooksStopOnSuspend() {
	_OIH_AssertSuspendOwnedHook("SpaceTapHold", "_SpaceHoldInputHook")
	_OIH_AssertSuspendOwnedHook("OneShotShift", "_OneShotShiftInputHook")
}
Test("lifecycle: owned Space and OneShotShift InputHooks stop on suspend (owned-inputhooks-suspend)", _OIH_SpaceAndOneShotHooksStopOnSuspend)
