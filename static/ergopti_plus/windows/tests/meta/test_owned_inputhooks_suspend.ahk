; tests/meta/test_owned_inputhooks_suspend.ahk
#Requires AutoHotkey v2.0

_OIH_AssertSuspendOwnedHook(FunctionName, OwnerName) {
	Body := _DriverFuncBody(FunctionName)
	Lifecycle := _DriverFuncBody("Ergopti_OnSuspendEnter")
	Assert(InStr(Body, "SIHO_StartOwned(") > 0 and InStr(Body, '"' . OwnerName . '"') > 0,
		FunctionName . " must publish every live hook through the shared owner registry")
	Assert(InStr(Body, "finally") > 0 and InStr(Body, "SIHO_Unregister(") > 0,
		FunctionName . " must unregister its exact owner token in finally")
	Assert(InStr(Lifecycle, "SIHO_StopAll()") > 0,
		"Suspend enter must synchronously stop all registered suppressive hooks")
}

_OIH_SpaceAndOneShotHooksStopOnSuspend() {
	_OIH_AssertSuspendOwnedHook("OneShotShift", "one-shot-shift")
	_OIH_AssertSuspendOwnedHook("DeadKey", "dead-key")
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
