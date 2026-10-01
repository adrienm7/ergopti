; tests/unit/test_reload_deferral.ahk

; ==============================================================================
; MODULE: A reload asked during a configuration write waits for it
; DESCRIPTION:
; The reload needs the configuration lease, and the thread that asks for it
; interrupts the writer that holds it: the request can only ask again later.
; It used to fail at once with « Reload refused because another configuration
; transaction owns config.toml » and an error window, and the reload was lost
; (reload-during-config-write, seen on 2026-10-01 during a 2 360 ms start-up
; write). The queue is driven here with a captured timer instead of the
; message loop, and the meta test below holds the call site: lifecycle.ahk
; registers hotkeys and cannot be included by this suite.
; ==============================================================================

#Requires AutoHotkey v2.0

global _RLD_Armed := []
global _RLD_Retries := 0

_RLD_Reset() {
	global _RLD_Armed := []
	global _RLD_Retries := 0
	State := _ReloadDeferralState()
	State["armed"] := false
	State["attempts"] := 0
}

_RLD_Arm(Callback, DelayMs) {
	global _RLD_Armed
	_RLD_Armed.Push(Map("fn", Callback, "ms", DelayMs))
	return true
}

_RLD_Retry() {
	global _RLD_Retries
	_RLD_Retries += 1
}

; Runs the timers armed so far, as the message loop would.
_RLD_RunArmed() {
	global _RLD_Armed
	Armed := _RLD_Armed
	_RLD_Armed := []
	for Entry in Armed
		Entry["fn"].Call()
}

_RLD_QueuesOneRetry() {
	global _RLD_Armed, _RLD_Retries, RELOAD_DEFERRAL_RETRY_MS
	_RLD_Reset()
	AssertTrue(ReloadDeferralQueue(_RLD_Retry, _RLD_Arm), "a reload asked during a write is queued, not refused")
	AssertEqual(1, _RLD_Armed.Length, "one retry is scheduled")
	AssertEqual(RELOAD_DEFERRAL_RETRY_MS, _RLD_Armed[1]["ms"])
	AssertEqual(0, _RLD_Retries, "nothing asks again before the writer could resume")
	AssertTrue(ReloadDeferralQueue(_RLD_Retry, _RLD_Arm), "a second request joins the queued reload")
	AssertEqual(1, _RLD_Armed.Length, "and schedules no second retry")
	_RLD_RunArmed()
	AssertEqual(1, _RLD_Retries, "the timer asks for the reload again, once")
	AssertTrue(ReloadDeferralQueue(_RLD_Retry, _RLD_Arm), "a lease still busy queues the next attempt")
	AssertEqual(1, _RLD_Armed.Length)
}
Test("reload deferral: a reload asked during a configuration write is queued once (reload-during-config-write)",
	_RLD_QueuesOneRetry)

_RLD_WaitIsBounded() {
	global _RLD_Armed, RELOAD_DEFERRAL_MAX_ATTEMPTS
	_RLD_Reset()
	Loop RELOAD_DEFERRAL_MAX_ATTEMPTS {
		AssertTrue(ReloadDeferralQueue(_RLD_Retry, _RLD_Arm), "attempt " . A_Index . " is queued")
		_RLD_RunArmed()
	}
	AssertFalse(ReloadDeferralQueue(_RLD_Retry, _RLD_Arm),
		"a lease that is never released ends in the refusal, so its report still reaches the user")
	AssertEqual(0, _RLD_Armed.Length, "no retry outlives the refusal")
	AssertTrue(ReloadDeferralQueue(_RLD_Retry, _RLD_Arm), "the next request starts a new wait")
}
Test("reload deferral: the wait is bounded and ends in the refusal (reload-during-config-write)",
	_RLD_WaitIsBounded)

_RLD_SettleStartsANewWait() {
	global RELOAD_DEFERRAL_MAX_ATTEMPTS
	_RLD_Reset()
	Loop RELOAD_DEFERRAL_MAX_ATTEMPTS - 1 {
		ReloadDeferralQueue(_RLD_Retry, _RLD_Arm)
		_RLD_RunArmed()
	}
	ReloadDeferralSettle()
	Loop RELOAD_DEFERRAL_MAX_ATTEMPTS {
		AssertTrue(ReloadDeferralQueue(_RLD_Retry, _RLD_Arm),
			"a reload that got its lease ends the wait: the next busy lease has the whole bound")
		_RLD_RunArmed()
	}
}
Test("reload deferral: a reload that got its lease resets the bound (reload-during-config-write)",
	_RLD_SettleStartsANewWait)

_RLD_ArmThrows(Callback, DelayMs) {
	throw Error("no timer")
}

_RLD_FailedTimerIsNotQueued() {
	_RLD_Reset()
	AssertFalse(ReloadDeferralQueue(_RLD_Retry, _RLD_ArmThrows),
		"a retry that cannot be scheduled must not be reported as queued")
	AssertFalse(_ReloadDeferralState()["armed"], "and must not leave the queue claimed")
	AssertThrows(() => ReloadDeferralQueue(0, _RLD_Arm), "a deferred reload needs a callable retry")
}
Test("reload deferral: a timer that cannot be armed is a refusal (reload-during-config-write)",
	_RLD_FailedTimerIsNotQueued)

; The call site. A request with its own completion or refusal duties, or one
; that borrows a configuration bundle, is never queued: its caller holds
; state the retry could not carry.
_RLD_LifecycleDefersPlainRequests() {
	Body := _DriverFuncBody("_ReloadPreservingSuspendNonCritical")
	Assert(Body != "", "_ReloadPreservingSuspendNonCritical() must exist")
	QueueAt := InStr(Body, "ReloadDeferralQueue(_ReloadAfterConfigWrite)")
	RefusalAt := InStr(Body, "Reload refused because another configuration transaction owns config.toml.")
	Assert(QueueAt > 0, "a reload with no free lease must be queued behind the write")
	Assert(RefusalAt > QueueAt, "the refusal is what remains once the queue declines")
	Assert(InStr(Body, "_ReloadRequestIsPlain(SuccessFn, ExistingBundle, RefusedFn, StageFailureFn)") > 0
		and InStr(Body, "_ReloadRequestIsPlain(SuccessFn, ExistingBundle, RefusedFn, StageFailureFn)") < QueueAt,
		"only a request with no callback and no borrowed bundle is queued")
	Assert(InStr(Body, "ReloadDeferralSettle()") > RefusalAt, "a reload that got its lease ends the wait")
	Plain := _DriverFuncBody("_ReloadRequestIsPlain")
	Assert(Plain != "", "_ReloadRequestIsPlain() must exist")
	for Name in ["SuccessFn", "RefusedFn", "StageFailureFn"]
		Assert(InStr(Plain, 'HasMethod(' . Name . ', "Call")') > 0, Name . " makes a request not plain")
	Assert(InStr(Plain, "ExistingBundle is Object") > 0, "a borrowed bundle makes a request not plain")
	Retry := _DriverFuncBody("_ReloadAfterConfigWrite")
	Assert(InStr(Retry, "_ReloadPreservingSuspendNonCritical(0, 0, 0, 0)") > 0,
		"the retry asks for the same plain reload")
}
Test("reload deferral: the reload queues plain requests before it refuses (reload-during-config-write)",
	_RLD_LifecycleDefersPlainRequests)
