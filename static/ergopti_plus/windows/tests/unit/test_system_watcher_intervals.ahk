; tests/unit/test_system_watcher_intervals.ahk

; ==============================================================================
; MODULE: System Watcher Interval Integration Tests
; DESCRIPTION: Replay actual Windows callbacks through publication, SQL and manifest boundaries.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLSW_CallbacksReachMetrics() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	SavedOwner := KLWatch.system_events
	SavedFailure := KLWatch.system_failure_reported
	SavedBatch := KLW.batch
	SavedDevice := Keylogger._device_id_lit
	SavedApp := KLHook.prev_app
	F := _KLSO_Fixture()
	KLWatch.system_events := F.Owner
	KLWatch.system_failure_reported := false
	Keylogger._device_id_lit := SQLite_Q("dev-one")
	KLHook.prev_app := ""
	KLW_ResetBatch()
	try {
		F.Tick := 10
		KL_Watchers_OnSessionChange(KLWatchConst.WTS_SESSION_LOCK, 0, 0, 0)
		F.Tick := 20
		KL_Watchers_OnPowerBroadcast(KLWatchConst.PBT_APMSUSPEND, 0, 0, 0)
		F.Tick := 60
		KL_Watchers_OnPowerBroadcast(KLWatchConst.PBT_APMRESUMEAUTOMATIC, 0, 0, 0)
		F.Tick := 65
		KL_Watchers_OnPowerBroadcast(KLWatchConst.PBT_APMRESUMESUSPEND, 0, 0, 0)
		F.Tick := 90
		KL_Watchers_OnSessionChange(KLWatchConst.WTS_SESSION_UNLOCK, 0, 0, 0)
		F.Tick := 100
		KL_Watchers_OnSessionChange(KLWatchConst.WTS_SESSION_LOCK, 0, 0, 0)
		F.Tick := 150
		AssertTrue(_KL_Watchers_SystemDrain(true))
		AssertTrue(_KL_Watchers_SystemDrain(true), "a repeated shutdown drain must not emit twice")
		AssertEqual(4, F.Measures().Length, "actual callbacks must generate measured intervals")
		Sql := _KLRDC_Header()
		for Id, Entry in F.Events
			Sql .= KL_BuildInsertSystem(Entry, Id)
		_KLRDC_WriteLedger(Sql)
		Db := _KLRDC_BuildAsWorker()
		Row := SQLite_Query(Db, "SELECT * FROM agg_system_day;")[1]
		_KLRSDA_Assert(Row, 90, 40, 0)
		AssertEqual(4, Row["passive_count"])
		System := KLR_ReadManifest(Db)["2026-01-01"]["_system"]
		AssertEqual(90, System["locked_ms"])
		AssertEqual(40, System["sleep_ms"])
		AssertEqual(4, System["passive_count"])
	} finally {
		_KLRDC_Cleanup()
		KLWatch.system_events := SavedOwner
		KLWatch.system_failure_reported := SavedFailure
		KLW.batch := SavedBatch
		Keylogger._device_id_lit := SavedDevice
		KLHook.prev_app := SavedApp
	}
}

_KLSW_IdleRetry() {
	SavedOwner := KLWatch.system_events
	SavedFailure := KLWatch.system_failure_reported
	SavedInitialized := Keylogger.initialized
	SavedTick := KLHook.last_tick
	F := _KLSO_Fixture()
	try {
		KLWatch.system_events := F.Owner
		KLWatch.system_failure_reported := false
		Keylogger.initialized := true
		KLHook.last_tick := 0
		F.Tick := 10
		KL_Watchers_OnPowerBroadcast(KLWatchConst.PBT_APMSUSPEND, 0, 0, 0)
		F.Mode := "throw-before"
		F.Tick := 40
		KL_Watchers_OnPowerBroadcast(KLWatchConst.PBT_APMRESUMEAUTOMATIC, 0, 0, 0)
		AssertTrue(KLWatch.system_failure_reported)
		AssertEqual(2, F.Owner.Pending.Length)
		F.Mode := "ok"
		F.Tick := 900
		KL_Watchers_IdleTick()
		AssertFalse(KLWatch.system_failure_reported)
		AssertEqual(0, F.Owner.Pending.Length)
		AssertEqual(30, F.Measures()[1]["duration_ms"])
	} finally {
		KLWatch.system_events := SavedOwner
		KLWatch.system_failure_reported := SavedFailure
		Keylogger.initialized := SavedInitialized
		KLHook.last_tick := SavedTick
	}
}

_KLSW_AppendBridge() {
	global _Stub_AppendLogRows, _Stub_AppendLogAccept, _Stub_AppendLogRejectSuspend, _Stub_AppendLogHook
	SavedRows := _Stub_AppendLogRows
	SavedAccept := _Stub_AppendLogAccept
	SavedReject := _Stub_AppendLogRejectSuspend
	SavedHook := _Stub_AppendLogHook
	SavedOwner := KLWatch.system_events
	SavedFailure := KLWatch.system_failure_reported
	F := _KLSO_Fixture()
	try {
		_Stub_AppendLogRows := []
		_Stub_AppendLogAccept := true
		_Stub_AppendLogRejectSuspend := false
		_Stub_AppendLogHook := 0
		KLWatch.system_events := KLSystemEventOwner(F.Frame.Bind(F), _KL_SystemEventAppend, () => F.Allowed)
		F.Tick := 10
		KL_Watchers_OnSessionChange(KLWatchConst.WTS_SESSION_LOCK, 0, 0, 0)
		AssertTrue(KL_Watchers_ResetSystemIntervals())
		F.Tick := 40
		KL_Watchers_OnSessionChange(KLWatchConst.WTS_SESSION_UNLOCK, 0, 0, 0)
		AssertEqual(2, _Stub_AppendLogRows.Length, "reset must not emit a cross-pause duration")
		_Stub_AppendLogAccept := false
		F.Tick := 50
		KL_Watchers_OnPowerBroadcast(KLWatchConst.PBT_APMSUSPEND, 0, 0, 0)
		F.Tick := 80
		KL_Watchers_OnPowerBroadcast(KLWatchConst.PBT_APMRESUMEAUTOMATIC, 0, 0, 0)
		AssertEqual(0, KLWatch.system_events.Pending.Length)
		_Stub_AppendLogAccept := true
		F.Tick := 90
		KL_Watchers_OnPowerBroadcast(KLWatchConst.PBT_APMSUSPEND, 0, 0, 0)
		F.Tick := 120
		KL_Watchers_OnPowerBroadcast(KLWatchConst.PBT_APMRESUMEAUTOMATIC, 0, 0, 0)
		AssertEqual(5, _Stub_AppendLogRows.Length)
		AssertEqual("passive_period", _Stub_AppendLogRows[5]["action"])
		AssertEqual(30, _Stub_AppendLogRows[5]["duration_ms"])
		AssertEqual(0, KLWatch.system_events.Pending.Length, "the production adapter must forward the commit callback")
	} finally {
		_Stub_AppendLogRows := SavedRows
		_Stub_AppendLogAccept := SavedAccept
		_Stub_AppendLogRejectSuspend := SavedReject
		_Stub_AppendLogHook := SavedHook
		KLWatch.system_events := SavedOwner
		KLWatch.system_failure_reported := SavedFailure
	}
}

_KLSW_LifecycleBoundaries() {
	Enter := _DriverFuncBody("Ergopti_OnSuspendEnter")
	Stop := _DriverFuncBody("KL_Watchers_Stop")
	Shutdown := _DriverFuncBody("KL_Stop")
	AssertTrue(Enter != "" && Stop != "" && Shutdown != "", "all lifecycle owners must resolve")
	ResetAt := InStr(Enter, "KL_Watchers_ResetSystemIntervals")
	AssertTrue(ResetAt > 0 && ResetAt < InStr(Enter, "LoggerStart"),
		"pause must invalidate intervals before yielding teardown logs")
	AssertTrue(InStr(Stop, "_KL_Watchers_SystemDrain(true)") > 0)
	AssertTrue(InStr(Shutdown, "KL_Watchers_Stop()") > 0
		&& InStr(Shutdown, "KL_Watchers_Stop()") < InStr(Shutdown, "_KL_JournalPendingEntries("),
		"terminal intervals must enter the existing final durable drain")
}

Test("system watchers: actual callbacks reach SQL and manifest totals (system-watcher-intervals)",
	_KLRDC_CheckTeardown.Bind(_KLSW_CallbacksReachMetrics))
Test("system watchers: the idle timer retries technical delivery debt (system-watcher-intervals)", _KLSW_IdleRetry)
Test("system watchers: append guards preserve reset and privacy boundaries (system-watcher-intervals)", _KLSW_AppendBridge)
Test("system watchers: pause and final drain own interval boundaries (system-watcher-intervals)", _KLSW_LifecycleBoundaries)

_KLSW_PausedDeliveryDebt(Stopping) {
	SavedOwner := KLWatch.system_events
	SavedFailure := KLWatch.system_failure_reported
	F := _KLSO_Fixture()
	try {
		KLWatch.system_events := F.Owner
		KLWatch.system_failure_reported := false
		F.Step("sleep", 10)
		F.Mode := "throw-before"
		F.Tick := 40
		if Stopping
			AssertFalse(_KL_Watchers_SystemDrain(true))
		else
			AssertFalse(F.Step("wake", 40))
		ExpectedPending := Stopping ? 1 : 2
		AssertEqual(ExpectedPending, F.Owner.Pending.Length)
		F.Allowed := false
		KL_Watchers_ResetSystemIntervals()
		AssertEqual(ExpectedPending, F.Owner.Pending.Length,
			"pause must preserve completed measurements awaiting technical retry")
		F.Mode := "ok"
		AssertFalse(_KL_Watchers_SystemDrain(Stopping), "paused delivery must retain its debt")
		AssertEqual(0, F.Measures().Length, "no record may publish while collection is paused")
		F.Allowed := true
		F.Tick := 900
		AssertTrue(_KL_Watchers_SystemDrain(Stopping))
		AssertEqual(0, F.Owner.Pending.Length)
		Rows := F.Measures()
		AssertEqual(1, Rows.Length)
		AssertEqual(30, Rows[1]["duration_ms"], "resume must not extend the original completed interval")
		AssertEqual("2026-01-01 10:00:00.040", Rows[1]["timestamp"])
	} finally {
		KLWatch.system_events := SavedOwner
		KLWatch.system_failure_reported := SavedFailure
	}
}

for Stopping in [false, true]
	Test("system watchers: pause preserves delivery debt stopping=" . Stopping . " (system-paused-delivery-debt)",
		_KLSW_PausedDeliveryDebt.Bind(Stopping))

_KLSW_PausedShutdownDrain() {
	SavedOwner := KLWatch.system_events
	SavedFailure := KLWatch.system_failure_reported
	SavedShutdown := Keylogger._shutting_down
	SavedSuspend := A_IsSuspended
	F := _KLSO_Fixture()
	InnerResult := true
	try {
		KLWatch.system_events := false
		Keylogger._shutting_down := false
		AssertTrue(_KL_Watchers_SystemStart())
		; Retain the production admission port while replacing clock and storage.
		KLWatch.system_events.ClockFn := F.Frame.Bind(F)
		KLWatch.system_events.AppendFn := F.Append.Bind(F)
		F.Owner := KLWatch.system_events
		F.Step("lock", 10)
		F.Mode := "throw-before"
		AssertFalse(F.Step("unlock", 40))
		AssertFalse(F.Step("sleep", 50))
		AssertEqual(3, F.Owner.Pending.Length)
		Suspend(1)
		KL_Watchers_ResetSystemIntervals()
		AssertFalse(F.Owner.AllowedFn.Call(), "normal collection must stay paused")
		Keylogger._shutting_down := true
		F.Mode := "ok"
		F.Tick := 900
		F.Reenter := NestedStop
		AssertTrue(_KL_Watchers_SystemDrain(true), "shutdown must drain existing pre-pause records")
		AssertFalse(InnerResult, "a reentrant shutdown cannot claim the outer drain completed")
		AssertEqual(4, F.Events.Length, "reentrant shutdown must not invalidate a pending raw transition")
		Rows := F.Measures()
		AssertEqual(1, Rows.Length, "the unobserved sleeping interval must not enter shutdown totals")
		AssertEqual("lock", Rows[1]["kind"])
		AssertEqual(30, Rows[1]["duration_ms"])
		AssertEqual(0, F.Owner.Pending.Length)
	} finally {
		Suspend(SavedSuspend)
		Keylogger._shutting_down := SavedShutdown
		KLWatch.system_events := SavedOwner
		KLWatch.system_failure_reported := SavedFailure
	}
	NestedStop() {
		InnerResult := _KL_Watchers_SystemDrain(true)
	}
}
Test("system watchers: paused shutdown drains only completed records (system-paused-delivery-debt)",
	_KLSW_PausedShutdownDrain)
