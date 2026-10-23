; tests/unit/modules/updater/test_updater_schedule_publication.ahk

; ==============================================================================
; MODULE: Updater Schedule Publication Tests
; DESCRIPTION:
; A genuine completed fetch reaches the real result logger. A timer retires
; its background generation before the returning callback records its outcome.
; ==============================================================================

class _USP_Fixture {
	__New(Mode) {
		this.Mode := Mode, this.States := [], this.Owners := [0, 0], this.Deliveries := []
		this.Error := 0, this.Done := false, this.LogCalls := 0, this.TimerCalls := 0
		this.TimerFn := ObjBindMethod(this, "OnTimer")
		this.SinkFn := ObjBindMethod(this, "OnLog")
	}
	OnJson(Index, Json, Request, Terminal) {
		this.Deliveries.Push({Index: Index, Json: Json, Request: Request, Terminal: Terminal})
		try _Updater_HandleBackgroundResult(Json, "9.9.9", Request, Terminal)
		catch Any as Failure {
			this.Error := Failure
			throw Failure
		}
	}
	Dispatch(Index) {
		global UPDATER_REQUEST_ORIGIN_BACKGROUND
		State := this.States[Index]
		CurlAsyncRequest.DefineProp("Call", {Call: _UMJ_Construct.Bind(State)})
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_BACKGROUND)
		Owner := _Updater_FetchLatestJsonAsync("main", Request, ObjBindMethod(this, "OnJson", Index))
		this.Owners[Index] := Owner
		if State.Has("error")
			throw State["error"]
		if IsObject(this.Error)
			throw this.Error
		return Request
	}
	OnLog(Line) {
		if !InStr(Line, "[WARNING] [Updater] Background check result: the release response carried no tag", true)
			return
		this.LogCalls += 1
		if this.Mode == "current" || this.LogCalls != 1
			return
		try {
			AssertFalse(A_IsCritical, "the genuine result log must remain interruptible")
			SetTimer(this.TimerFn, -1)
			Started := A_TickCount
			while !this.Done && TickElapsed(Started) < 2000
				Sleep(10)
			AssertTrue(this.Done, "the real cancellation timer must settle before the old result resumes")
		} catch Any as Failure
			this.Error := Failure
	}
	OnTimer() {
		this.TimerCalls += 1
		try {
			AssertFalse(A_IsCritical)
			AssertTrue(Updater_StopBackgroundChecks(), "the public stop must retire the generation")
			if this.Mode == "successor" {
				this.NewRequest := this.Dispatch(2)
				AssertEqual(1, this.Store.Writes, "the current successor must actually persist its success")
				this.SuccessRecord := _UCSch_Record(this.Store).Clone()
				AssertEqual(0, this.SuccessRecord["failures"])
				AssertEqual(this.Clock.Now, this.SuccessRecord["last_success_at"])
			}
		} catch Any as Failure
			this.Error := Failure
		finally this.Done := true
	}
	Run(Store, Clock) {
		try this.Exercise(Store, Clock)
		finally {
			; Discard only this fixture's remaining deliveries while its private
			; schedule port is still installed, before _UCSch_With restores it.
			for Owner in this.Owners {
				if IsObject(Owner) && _Updater_AsyncRequestOwned(Owner)
					Owner.Record["on_json"] := (*) => true
			}
			_Updater_CancelAsyncChecks()
		}
	}
	Exercise(Store, Clock) {
		global UPDATER_REQUEST_POLICY_ALLOW, UPDATER_REQUEST_POLICY_DROP
		this.Store := Store, this.Clock := Clock
		_Updater_CheckState()
		AssertEqual(0, Store.Writes, "the admitted seeded record needs no initial write")
		for Image in ['{}', '{"tag_name":"v1.0.0"}'] {
			State := _ManagedCurlControlState()
			State["constructs"] := 0
			State["pieces"] := [Image]
			State["request"] := CurlAsyncRequest(Map("spawn", _UMJ_Spawn.Bind(State)))
			this.States.Push(State)
		}
		LoggerSetTestSink(this.SinkFn)
		Request := this.Dispatch(1)
		LoggerClearTestSink()
		if IsObject(this.Error)
			throw this.Error
		ExpectedRequests := this.Mode == "successor" ? 2 : 1
		AssertEqual(1, this.LogCalls, "the old malformed release must reach the actual business diagnostic")
		AssertEqual(this.Mode == "current" ? 0 : 1, this.TimerCalls)
		AssertEqual(ExpectedRequests, this.Deliveries.Length, "every real fetch must deliver once")
		loop ExpectedRequests {
			Index := A_Index, State := this.States[Index], Owner := this.Owners[Index]
			AssertEqual(1, State["constructs"])
			AssertEqual(1, State["starts"])
			AssertEqual(1, State["spawns"])
			AssertTrue(State["request"].Completed)
			AssertTrue(State["request"].ResponseEncodingValid)
			AssertEqual(200, State["request"].Status)
			AssertEqual(this.Deliveries[Index].Json, State["request"].ResponseText)
			AssertEqual(0, this.Deliveries[Index].Terminal)
			AssertTrue(Owner.Record["http"] == State["request"], "the real callback must retain its exact facade")
			AssertTrue(Owner.Record["request"] == this.Deliveries[Index].Request)
			AssertFalse(_Updater_AsyncRequestOwned(Owner))
			AssertFalse(IsObject(Owner.Record["poll_fn"]))
			AssertFalse(_Updater_PollAsync(Owner.Id), "a late native poll must be inert")
		}
		ExpectedWrites := this.Mode == "cancel" ? 0 : 1
		Policy := _Updater_RequestPolicy(Request)
		FileAppend("RECEIPT updater-schedule-publication mode=" . this.Mode
			. " deliveries=" . this.Deliveries.Length . " writes=" . Store.Writes
			. " expected_writes=" . ExpectedWrites . " old_policy=" . Policy
			. " log_calls=" . this.LogCalls . " timer_calls=" . this.TimerCalls . "`n", "*")
		AssertEqual(this.Mode == "current" ? UPDATER_REQUEST_POLICY_ALLOW : UPDATER_REQUEST_POLICY_DROP, Policy)
		AssertEqual(ExpectedWrites, Store.Writes,
			"a revoked old callback must not persist its outcome after the winning cancellation")
		Record := _UCSch_Record(Store)
		if this.Mode == "successor" {
			AssertEqual(this.SuccessRecord["last_success_at"], Record["last_success_at"])
			AssertEqual(0, Record["failures"], "the newer success must retain its non-backoff schedule")
			AssertEqual(UPDATER_REQUEST_POLICY_ALLOW, _Updater_RequestPolicy(this.NewRequest))
		} else if this.Mode == "current" {
			AssertEqual(Clock.Now, Record["last_check_at"])
			AssertEqual(1, Record["failures"], "the uninterrupted genuine malformed result remains a failure")
		} else {
			AssertEqual(1699999000, Record["last_check_at"], "cancelled completion must preserve the prior record")
			AssertEqual(0, Record["failures"])
		}
	}
	Close() {
		global _HTTP_CURL_CLEANUP_DEBTS, _HTTP_CURL_ABORT_DEBTS
		SetTimer(this.TimerFn, 0)
		this.TimerFn := 0, this.SinkFn := 0
		CleanupFailure := 0
		try {
			for State in this.States {
				try {
					Request := State["request"]
					_ManagedCurlControlRelease(State)
					AssertFalse(IsObject(Request.Handle))
					AssertFalse(IsObject(Request.ManagedCapture))
					AssertFalse(IsObject(Request.ManagedAdmissionFn))
					AssertFalse(IsObject(Request.DeadlineFn))
					AssertFalse(_HTTP_CURL_CLEANUP_DEBTS.Has(Request.CleanupDebtId))
					AssertFalse(_HTTP_CURL_ABORT_DEBTS.Has(Request.CleanupDebtId))
					for Path in [Request.ConfigPath, Request.BodyPath, Request.HeaderPath]
						AssertFalse(FileExist(Path), "every private managed artifact must retire")
					if State.Has("directory")
						AssertFalse(DirExist(State["directory"]))
				} catch Any as Failure {
					if !IsObject(CleanupFailure)
						CleanupFailure := Failure
				}
			}
		} finally {
			for Owner in this.Owners {
				if !IsObject(Owner)
					continue
				Owner.Record["on_json"] := 0
				Owner.Record["http"] := 0
			}
		}
		if IsObject(CleanupFailure)
			throw CleanupFailure
	}

}

_USP_Case(Mode) {
	global _UpdaterAsyncRequests, _UpdaterActiveSendLeaseCount, _UpdaterActiveAsyncTerminalDeliveryCount
	global _UpdaterAsyncActionLeases, _UpdaterBackgroundOwner, _UpdaterBackgroundFn
	global _UpdaterFetchCache, _UpdaterListDiskLoaded, _UpdaterListDiskEntry
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_PATH_DATE, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	global _HealthCheckWarnCount, _HealthCheckLastError, _HealthCheckErrCount, _ED_Policy, _ED_Busy, _ED_PendingRecord
	AssertFalse(A_IsSuspended)
	AssertEqual(0, _UpdaterAsyncRequests.Count)
	AssertEqual(0, _UpdaterActiveSendLeaseCount)
	AssertEqual(0, _UpdaterActiveAsyncTerminalDeliveryCount)
	AssertEqual(0, _UpdaterAsyncActionLeases.Count)
	AssertFalse(IsObject(_UpdaterBackgroundOwner), "no foreign background timer may be detached")
	AssertFalse(IsSet(_UpdaterBackgroundFn), "no foreign cadence callback may be detached")
	AssertFalse(IsSet(_ED_Busy) && _ED_Busy)
	AssertFalse(IsSet(_ED_PendingRecord) && IsObject(_ED_PendingRecord))
	AssertEqual(0, _LOGGER_TEST_SINK)
	SavedLogger := _TLOG_CaptureLoggerState()
	AssertFalse(SavedLogger.FlushActive)
	SavedRequest := _UpdaterTest_SaveRequestState()
	Saved := {Cache: _UpdaterFetchCache, Loaded: _UpdaterListDiskLoaded, Disk: _UpdaterListDiskEntry,
		Repeat: _LOGGER_REPEAT_ENABLED, PathDate: _LOGGER_PATH_DATE,
		Clock: _LOGGER_CLOCK_FN, Stamp: _LOGGER_STAMP_FN,
		HadWarn: IsSet(_HealthCheckWarnCount), HadError: IsSet(_HealthCheckLastError),
		HadErrorCount: IsSet(_HealthCheckErrCount), HadPolicy: IsSet(_ED_Policy)}
	if Saved.HadWarn
		Saved.Warn := _HealthCheckWarnCount
	if Saved.HadError
		Saved.Error := _HealthCheckLastError
	if Saved.HadErrorCount
		Saved.ErrorCount := _HealthCheckErrCount
	if Saved.HadPolicy
		Saved.Policy := _ED_Policy
	HadCall := CurlAsyncRequest.HasOwnProp("Call")
	SavedCall := HadCall ? CurlAsyncRequest.GetOwnPropDesc("Call") : 0
	F := _USP_Fixture(Mode), Primary := 0, CleanupFailure := 0
	PreviousCritical := A_IsCritical
	try {
		_UpdaterTest_ResetRequestState()
		_UpdaterFetchCache := Map(), _UpdaterListDiskLoaded := true, _UpdaterListDiskEntry := 0
		_ED_Policy := 0
		_ResetLogger()
		LOGGER_SUB_FILES := Map(), _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_REPEAT_ENABLED := false, _LOGGER_PATH_DATE := ""
		_LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0
		Critical("Off")
		_UCSch_With(Map("seed", "7f3a9c21e5b04d68", "last_check_at", 1699999000, "failures", 0),
			1700000000, 1699990000, 86400, ObjBindMethod(F, "Run"))
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			LoggerClearTestSink()
			if HadCall
				CurlAsyncRequest.DefineProp("Call", SavedCall)
			else if CurlAsyncRequest.HasOwnProp("Call")
				CurlAsyncRequest.DeleteProp("Call")
			F.Close()
			AssertEqual(0, _UpdaterAsyncRequests.Count)
			AssertEqual(0, _UpdaterActiveSendLeaseCount)
			AssertEqual(0, _UpdaterActiveAsyncTerminalDeliveryCount)
		} catch Any as Failure {
			CleanupFailure := Failure
		} finally {
			_UpdaterTest_RestoreRequestState(SavedRequest)
			_UpdaterFetchCache := Saved.Cache, _UpdaterListDiskLoaded := Saved.Loaded, _UpdaterListDiskEntry := Saved.Disk
			_LOGGER_TEST_SINK := 0
			_LOGGER_REPEAT_ENABLED := Saved.Repeat, _LOGGER_PATH_DATE := Saved.PathDate
			_LOGGER_CLOCK_FN := Saved.Clock, _LOGGER_STAMP_FN := Saved.Stamp
			_TLOG_RestoreLoggerState(SavedLogger)
			_HealthCheckWarnCount := Saved.HadWarn ? Saved.Warn : unset
			_HealthCheckLastError := Saved.HadError ? Saved.Error : unset
			_HealthCheckErrCount := Saved.HadErrorCount ? Saved.ErrorCount : unset
			_ED_Policy := Saved.HadPolicy ? Saved.Policy : unset
			Critical(PreviousCritical)
		}
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupFailure)
		throw CleanupFailure
}

for _USP_Mode in ["cancel", "successor", "current"]
	Test("Updater schedule publication: " . _USP_Mode . " preserves the winning completion (updater-schedule-publication)",
		_USP_Case.Bind(_USP_Mode))
