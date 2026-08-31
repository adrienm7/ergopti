; tests/unit/test_keylogger_shutdown_timers.ahk

; ==============================================================================
; MODULE: Keylogger Shutdown Timer Teardown Tests
; DESCRIPTION:
; AHK-120 regression coverage for terminal timer cancellation. One rejected
; native cancellation must not prevent sibling timers from being attempted or
; escape the helper that protects the final durability drain.
; ==============================================================================

#Requires AutoHotkey v2.0


_KLST_NoopTimer() {
}

class _KLSTStaticOwner {
	static first_fn := unset
	static second_fn := unset
}

_KLST_TimerPort(State, Callback, Period) {
	State["calls"].Push(Map("callback", Callback, "period", Period))
	if (Period != 0) {
		State["arm_calls"] += 1
		if (State["fail_arm_at"] = State["arm_calls"])
			throw Error("injected timer admission failure")
		return
	}
	if (State["fail_cancel_owner"] != 0
			&& ObjPtr(State["fail_cancel_owner"]) = ObjPtr(Callback))
		throw Error("injected timer cancellation failure")
}

_KLST_TimerState(FailArmAt := 0, FailCancelOwner := 0) {
	return Map(
		"calls", [],
		"arm_calls", 0,
		"fail_arm_at", FailArmAt,
		"fail_cancel_owner", FailCancelOwner)
}

_KLST_StartRollbackRetainsOnlyCleanupDebt() {
	Owner := _KLSTStaticOwner
	First := _KLST_NoopTimer.Bind()
	Second := _KLST_NoopTimer.Bind()
	Specs := [
		Map("property", "first_fn", "callback", First, "period", 1000),
		Map("property", "second_fn", "callback", Second, "period", 2000)]
	State := _KLST_TimerState(2, First)
	Thrown := false
	try KL_TimerGroupStart(Owner, Specs, _KLST_TimerPort.Bind(State), "probe")
	catch
		Thrown := true

	AssertTrue(Thrown,
		"a partial native admission failure must remain observable")
	AssertTrue(Owner.HasOwnProp("first_fn")
		&& ObjPtr(Owner.first_fn) = ObjPtr(First),
		"failed rollback must retain the exact timer identity for cleanup retry")
	AssertFalse(Owner.HasOwnProp("second_fn"),
		"successful rollback must retire the released timer identity")
	AssertFalse(KL_TimerGroupStart(Owner, Specs,
		_KLST_TimerPort.Bind(_KLST_TimerState()), "probe"),
		"restart must not overwrite unresolved cleanup debt")

	AssertTrue(KL_TimerGroupStop(Owner, ["first_fn", "second_fn"],
		_KLST_TimerPort.Bind(_KLST_TimerState()), "probe"),
		"a later cleanup retry must release the retained timer")
	AssertFalse(Owner.HasOwnProp("first_fn"),
		"successful cleanup retry must retire the retained identity")
}
Test("keylogger timer groups: partial admission retains exact cleanup debt",
	_KLST_StartRollbackRetainsOnlyCleanupDebt)

_KLST_StopFailureRetainsTimerOwnership() {
	Owner := {}
	TimerOwner := _KLST_NoopTimer.Bind()
	SiblingOwner := _KLST_NoopTimer.Bind()
	Owner.timer_fn := TimerOwner
	Owner.sibling_fn := SiblingOwner
	FailState := _KLST_TimerState(0, TimerOwner)

	AssertFalse(KL_TimerGroupStop(Owner, ["timer_fn", "sibling_fn"],
		_KLST_TimerPort.Bind(FailState), "probe"),
		"a rejected native cancellation must reject the stop transition")
	AssertTrue(Owner.HasOwnProp("timer_fn")
		&& ObjPtr(Owner.timer_fn) = ObjPtr(TimerOwner),
		"a rejected cancellation must retain the exact owner")
	AssertFalse(Owner.HasOwnProp("sibling_fn"),
		"one rejected cancellation must not skip successful sibling cleanup")
	AssertTrue(KL_TimerGroupStop(Owner, ["timer_fn", "sibling_fn"],
		_KLST_TimerPort.Bind(_KLST_TimerState()), "probe"),
		"a later stop call must retry the retained owner")
	AssertFalse(Owner.HasOwnProp("timer_fn"),
		"successful cancellation must clear the owner")
}
Test("keylogger timer groups: failed stop retains exact retry ownership",
	_KLST_StopFailureRetainsTimerOwnership)

_KLST_ProductionTimerModulesUseOwnedGroups() {
	for _, StartName in ["KL_Sensors_Start", "KL_Topo_Start", "KL_AV_Start",
			"KL_Net_Start", "KL_Roi_Start"] {
		Body := _DriverFuncBody(StartName)
		AssertTrue(Body != "" && InStr(Body, "KL_TimerGroupStart(") > 0,
			StartName . " must delegate native admission to the owned timer transaction")
	}
	for _, StopName in ["KL_Sensors_Stop", "KL_Topo_Stop", "KL_AV_Stop",
			"KL_Net_Stop", "KL_Roi_Stop"] {
		Body := _DriverFuncBody(StopName)
		AssertTrue(Body != "" && InStr(Body, "KL_TimerGroupStop(") > 0,
			StopName . " must retain failed native cancellation ownership")
	}
	InitBody := _DriverFuncBody("KL_Init")
	StopBody := _DriverFuncBody("KL_Stop")
	AssertTrue(InitBody != "" && InStr(InitBody, "KL_TimerGroupStart(") > 0,
		"KL_Init must admit every core timer through the owned transaction")
	AssertTrue(StopBody != "" && InStr(StopBody, "KL_TimerGroupStop(") > 0,
		"KL_Stop must retain failed core timer cancellation ownership")
}
Test("keylogger timer groups: every auxiliary module uses owned transactions",
	_KLST_ProductionTimerModulesUseOwnedGroups)
