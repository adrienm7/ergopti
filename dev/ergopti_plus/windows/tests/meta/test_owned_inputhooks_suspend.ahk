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
	_OIH_AssertSuspendOwnedHook("OneShotShift", "_OneShotShiftInputHook")
	_OIH_AssertSuspendOwnedHook("DeadKey", "_DeadKeyInputHook")
	Space := _DriverFuncBody("SpaceTapHold")
	Assert(InStr(Space, 'TapHoldOwnImmediateModifier("space",') > 0
		and !InStr(Space, "InputHook("),
		"Space no longer owns an InputHook: its configured modifier must be active before the first chord")
}
Test("lifecycle: owned InputHooks stop on suspend and Space uses no capture hook (owned-inputhooks-suspend)", _OIH_SpaceAndOneShotHooksStopOnSuspend)

_OIH_SpaceOwnerReleaseStopsCaptureBeforeNextKey() {
	Body := _DriverFuncBody("SpaceTapHold")
	Assert(!InStr(Body, "InputHook(") and !InStr(Body, "ih.Wait()"),
		"Space must not swallow a chord into a delayed capture window")
}
Test("lifecycle: Space has no suppressing capture after immediate ownership", _OIH_SpaceOwnerReleaseStopsCaptureBeforeNextKey)
