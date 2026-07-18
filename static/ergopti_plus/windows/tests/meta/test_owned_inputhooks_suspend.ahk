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
	_OIH_AssertSuspendOwnedHook("DeadKey", "_DeadKeyInputHook")
}
Test("lifecycle: owned Space, OneShotShift, and DeadKey InputHooks stop on suspend (owned-inputhooks-suspend)", _OIH_SpaceAndOneShotHooksStopOnSuspend)

_OIH_SpaceOwnerReleaseStopsCaptureBeforeNextKey() {
	Body := _DriverFuncBody("SpaceTapHold")
	Assert(InStr(Body, 'ih.KeyOpt("{SC039}", "+N")') > 0,
		"Space capture must receive its physical owner key-up")
	Assert(InStr(Body, "ih.OnKeyUp := _SpaceHoldOnKeyUp") > 0,
		"Space capture must bind an owner-release callback")
	Assert(InStr(Body, "if _SpaceHoldOwnerReleased") > 0,
		"Space capture must exit before dispatch after its owner was released")
	Callback := _DriverFuncBody("_SpaceHoldOnKeyUp")
	Assert(InStr(Callback, "ih.Stop()") > 0 and InStr(Callback, "_SpaceHoldOwnerReleased := true") > 0,
		"Space owner key-up must stop the suppressing hook and mark the transaction closed")
}
Test("lifecycle: Space owner key-up terminates the suppressing capture", _OIH_SpaceOwnerReleaseStopsCaptureBeforeNextKey)
