; tests/meta/test_timer_scheduler_registration_transaction.ahk
#Requires AutoHotkey v2.0

_TSRT_RegistrationFollowsSuccessfulSchedule() {
	for FnName in ["TimerAfter", "TimerRestartAfter", "TimerEvery"] {
		Body := _DriverFuncBody(FnName)
		CommitPos := InStr(Body, "try _TimerAdapterCommitNative(Handle, BoundFn, Ms)")
		Assert(CommitPos > 0,
			FnName . " must delegate native admission and publication to one transaction (timer-scheduler-registration-transaction)")
		Assert(InStr(Body, "catch as Err", false, CommitPos) > CommitPos
				&& InStr(Body, "throw Err", false, CommitPos) > CommitPos,
			FnName . " must surface scheduling failure instead of leaking a live registry handle (timer-scheduler-registration-transaction)")
	}
}
Test("TimerScheduler: failed schedule cannot publish a live handle (timer-scheduler-registration-transaction)", _TSRT_RegistrationFollowsSuccessfulSchedule)

global _TSRT_ExpectedHandleId := 0

_TSRT_ObserveNativeAdmission(BoundFn, IntervalMs) {
	global _TIMER_ADAPTER_REGISTRY, _TSRT_ExpectedHandleId
	Assert(A_IsCritical,
		"native admission and registry publication must be non-interruptible")
	AssertFalse(_TIMER_ADAPTER_REGISTRY.Has(_TSRT_ExpectedHandleId),
		"the logical owner must not publish before native admission succeeds")
}

_TSRT_NativeAdmissionAndPublicationAreAtomic() {
	global _TIMER_ADAPTER_REGISTRY, _TSRT_ExpectedHandleId
	_TIMER_ADAPTER_REGISTRY := Map()
	_TSRT_ExpectedHandleId := 91001
	Handle := Map("Id", _TSRT_ExpectedHandleId, "Fired", false)
	_TimerAdapterCommitNative(Handle, (*) => 0, -1,
		_TSRT_ObserveNativeAdmission)
	AssertTrue(_TIMER_ADAPTER_REGISTRY.Has(_TSRT_ExpectedHandleId),
		"successful native admission must publish the exact handle before leaving the transaction")
	_TIMER_ADAPTER_REGISTRY.Delete(_TSRT_ExpectedHandleId)

	for FnName in ["TimerAfter", "TimerRestartAfter", "TimerEvery"] {
		Body := _DriverFuncBody(FnName)
		Assert(InStr(Body, "_TimerAdapterCommitNative(") > 0,
			FnName . " must use the atomic native-admission helper (timer-scheduler-publication-race)")
	}
}
Test("TimerScheduler: native admission and publication are atomic (timer-scheduler-publication-race)",
	_TSRT_NativeAdmissionAndPublicationAreAtomic)

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
