; tests/meta/test_timer_scheduler_registration_transaction.ahk
#Requires AutoHotkey v2.0

_TSRT_RegistrationFollowsSuccessfulSchedule() {
	for FnName in ["TimerAfter", "TimerEvery"] {
		Body := _DriverFuncBody(FnName)
		SchedulePos := InStr(Body, "try SetTimer(BoundFn, Ms)")
		RegisterPos := InStr(Body, "_TIMER_ADAPTER_REGISTRY[Handle[")
		Assert(SchedulePos > 0 and RegisterPos > SchedulePos,
			FnName . " must publish a timer handle only after SetTimer succeeds (timer-scheduler-registration-transaction)")
		Assert(InStr(Body, "catch as Err") > SchedulePos and InStr(Body, "throw Err") > SchedulePos,
			FnName . " must surface scheduling failure instead of leaking a live registry handle (timer-scheduler-registration-transaction)")
	}
}
Test("TimerScheduler: failed schedule cannot publish a live handle (timer-scheduler-registration-transaction)", _TSRT_RegistrationFollowsSuccessfulSchedule)

_TSRT_CancelAndRequeueFailuresAreContained() {
        CancelBody := _DriverFuncBody("TimerCancel")
        OneShotBody := _DriverFuncBody("_TimerAdapterMakeOneShot")
        Assert(CancelBody != "" && OneShotBody != "", "TimerCancel and one-shot wrapper must exist")
        Assert(InStr(CancelBody, "try SetTimer(BoundFn, 0)") > 0
                && InStr(CancelBody, "try SetTimer(RequeuedFn, 0)") > 0,
                "TimerCancel must contain OS cancellation failures instead of throwing from a user cancellation path")
        RequeuePos := InStr(OneShotBody, "SetTimer(requeued, -500)")
        FiredPos := InStr(OneShotBody, 'BoundHandle["Fired"] := true', false, RequeuePos)
        RegistryPos := InStr(OneShotBody, "_TIMER_ADAPTER_REGISTRY.Delete(Id)", false, RequeuePos)
        Assert(RequeuePos > 0 and FiredPos > RequeuePos and RegistryPos > RequeuePos,
                "a failed suspended re-queue must terminate and unpublish its handle, not leak a timer that can never fire")
}
Test("TimerScheduler: cancellation and suspended re-queue failures are transactional", _TSRT_CancelAndRequeueFailuresAreContained)
