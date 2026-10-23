; tests/unit/modules/updater/test_updater_install_phase_owner.ahk

; ==============================================================================
; MODULE: Updater Install Phase Ownership Tests
; DESCRIPTION:
; Genuine transaction producers and callback delivery surround a result-log
; timer. No worker process is launched: every READY handoff is cancelled first.
; ==============================================================================

class _UIPO_Fixture {
	__New(Mode, Root) {
		this.Mode := Mode, this.Root := Root
		this.Ready := InStr(Mode, "ready-") == 1
		this.Current := InStr(Mode, "-current") > 0
		this.Shared := InStr(Mode, "-shared") > 0
		this.Events := [], this.SuccessorEvents := []
		this.Error := 0, this.Done := false, this.TimerCalls := 0, this.LogCalls := 0
		this.ObserverCancelled := false, this.NewAdmission := 0
		this.OldAdmission := 0, this.OldEpoch := 0, this.NewEpoch := 0
		this.OwnedEpoch := 0, this.OwnedObserverEpoch := 0
		this.TimerFn := ObjBindMethod(this, "OnTimer")
		this.SinkFn := ObjBindMethod(this, "OnLog")
		this.OldFn := ObjBindMethod(this, "Observe", "old")
		this.NewFn := this.Shared ? this.OldFn : ObjBindMethod(this, "Observe", "new")
		this.NewExe := Root . "\new.exe", this.SwapPath := Root . "\swap.ps1"
	}
	Observe(Which, Phase, Reason := "", *) {
		global _UpdaterInstallObserverEpoch
		Event := {Which: Which, Phase: Phase, ObserverEpoch: _UpdaterInstallObserverEpoch}
		this.Events.Push(Event)
		if this.NewAdmission is Map && (this.Shared || Which == "new")
			this.SuccessorEvents.Push(Event)
		if this.Ready && this.Current && Phase == "installing" && !this.ObserverCancelled {
			this.ObserverCancelled := true
			try this.ObserverCancelResult := _Updater_CancelSelfUpdateTransaction(
				"Install phase owner fixture: the current observer cancelled.", false, false, this.OldEpoch)
			catch Any as Failure {
				this.Error := Failure
				throw Failure
			}
		}
	}
	Admit(Observer, Image) {
		global UPDATER_REQUEST_ORIGIN_MANUAL, _UpdaterDownloadRequest, _UpdaterDownloadInProgress
		global _UpdaterInstallObserver, _UpdaterInstallObserverEpoch
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
		Admission := _Updater_AdmitInstallObserver({RawJson: "{}", Tag: "v1.0.0"}, Observer, Request)
		AssertTrue(Admission is Map)
		this.OwnedObserverEpoch := Admission["epoch"]
		AssertTrue(_UpdaterInstallObserver == Observer)
		AssertEqual(Admission["epoch"], _UpdaterInstallObserverEpoch)
		Outcome := _Updater_BeginDownloadTransaction(Request, false, "v1.0.0", "https://example.invalid/owned.exe")
		AssertTrue(Outcome.Reserved, "the real producer must admit an actual download transaction")
		this.OwnedEpoch := Outcome.Epoch
		AssertTrue(_UpdaterDownloadInProgress && _UpdaterDownloadRequest == Request)
		AssertTrue(_Updater_SelfUpdateEpochIsCurrent(Outcome.Epoch))
		AssertTrue(_Updater_RegisterDownloadArtifacts(Outcome.Epoch, this.NewExe, this.SwapPath))
		AssertEqual(1, FSWriteDurable(this.NewExe, Image))
		AssertEqual(1, FSWriteDurable(this.SwapPath, Image . "-swap"))
		return {Admission: Admission, Request: Request, Epoch: Outcome.Epoch}
	}
	OnLog(Line) {
		Matches := this.Ready
			? InStr(Line, "[Updater] Update downloaded and verified for", true)
			: InStr(Line, "[Updater] Install phase owner fixture: cancelling original.", true)
		if !Matches
			return
		this.LogCalls += 1
		if this.Current || this.LogCalls != 1
			return
		try {
			AssertFalse(A_IsCritical, "the genuine result diagnostic must remain interruptible")
			SetTimer(this.TimerFn, -1)
			Started := A_TickCount
			while !this.Done && TickElapsed(Started) < 2000
				Sleep(10)
			AssertTrue(this.Done, "the real timer must admit its successor before old delivery resumes")
		} catch Any as Failure
			this.Error := Failure
	}
	OnTimer() {
		global _UpdaterDownloadInProgress, _UpdaterSelfUpdateEpoch, _UpdaterDownloadArtifacts
		this.TimerCalls += 1
		try {
			AssertFalse(A_IsCritical)
			if this.Ready
				AssertTrue(_Updater_CancelSelfUpdateTransaction(
					"Install phase owner fixture: READY was cancelled.", false, false, this.OldEpoch))
			AssertFalse(_UpdaterDownloadInProgress, "the old transaction must really be revoked before replacement")
			AssertTrue(_UpdaterSelfUpdateEpoch > this.OldEpoch)
			Successor := this.Admit(this.NewFn, "successor")
			this.NewAdmission := Successor.Admission
			this.NewEpoch := Successor.Epoch, this.NewRequest := Successor.Request
			this.NewArtifacts := _UpdaterDownloadArtifacts
			AssertTrue(this.NewAdmission["epoch"] > this.OldAdmission["epoch"],
				"reusing a callback must still issue a distinct canonical observer admission")
		} catch Any as Failure
			this.Error := Failure
		finally this.Done := true
	}
	Exercise() {
		global _UpdaterInstallObserver, _UpdaterInstallObserverEpoch
		global _UpdaterDownloadInProgress, _UpdaterDownloadRequest, _UpdaterDownloadArtifacts
		global _UpdaterDownloadWorker, _UpdaterSwapOwner, _UpdaterSwapTransactionCounter
		Old := this.Admit(this.OldFn, "original")
		this.OldAdmission := Old.Admission, this.OldEpoch := Old.Epoch
		LoggerSetTestSink(this.SinkFn)
		if this.Ready {
			; A real zero-handle reservation is a safety guard: even an omitted
			; observer callback must never reach native CreateProcess in this test.
			Guard := _Updater_ReserveSwapOwner(++_UpdaterSwapTransactionCounter, this.OldEpoch)
			AssertTrue(Guard is Map && Guard["ProcessHandle"] == 0)
			_Updater_PollDownloadAsync(0, "READY", "", this.SwapPath,
				this.NewExe, this.Root . "\current.exe", "v1.0.0", this.OldEpoch)
		} else {
			this.CancelResult := _Updater_CancelSelfUpdateTransaction(
				"Install phase owner fixture: cancelling original.", false, false, this.OldEpoch)
		}
		LoggerClearTestSink()
		if IsObject(this.Error)
			throw this.Error
		AssertEqual(1, this.LogCalls, "the actual old diagnostic must be observed")
		AssertEqual(this.Current ? 0 : 1, this.TimerCalls)
		AssertFalse(IsObject(_UpdaterDownloadWorker), "the fixture must never dispatch a worker")
		AssertFalse(_UpdaterSwapOwner is Map, "the revoked READY must never publish a native swap owner")
		FileAppend("RECEIPT updater-install-phase-owner mode=" . this.Mode
			. " old_epoch=" . this.OldEpoch . " old_observer_epoch=" . this.OldAdmission["epoch"]
			. " timer_calls=" . this.TimerCalls . " events=" . this.Events.Length
			. " successor_events=" . this.SuccessorEvents.Length
			. " current_observer_epoch=" . _UpdaterInstallObserverEpoch . "`n", "*")
		if this.Current {
			AssertFalse(_UpdaterDownloadInProgress)
			AssertEqual(0, _UpdaterInstallObserver)
			Expected := this.Ready ? ["installing", "failed"] : ["failed"]
			AssertEqual(Expected.Length, this.Events.Length)
			for Index, Phase in Expected {
				AssertEqual("old", this.Events[Index].Which)
				AssertEqual(Phase, this.Events[Index].Phase)
			}
			if this.Ready {
				AssertTrue(this.ObserverCancelled && this.ObserverCancelResult,
					"the positive READY control must reach its real current observer before cancellation")
			} else
				AssertTrue(this.CancelResult)
		} else {
			AssertTrue(this.NewAdmission is Map, "the timer must issue a genuine new observer admission")
			AssertTrue(_Updater_SelfUpdateEpochIsCurrent(this.NewEpoch))
			AssertTrue(_UpdaterDownloadInProgress && _UpdaterDownloadRequest == this.NewRequest)
			AssertTrue(_UpdaterDownloadArtifacts == this.NewArtifacts)
			AssertEqual("successor", FSReadStrict(this.NewExe))
			AssertEqual("successor-swap", FSReadStrict(this.SwapPath))
			AssertEqual(0, this.SuccessorEvents.Length,
				"an old terminal or progress phase must never be delivered as the newly admitted install")
			AssertTrue(_UpdaterInstallObserver == this.NewFn,
				"an old failure must not detach the new exact observer")
			AssertEqual(this.NewAdmission["epoch"], _UpdaterInstallObserverEpoch,
				"an old delivery cannot consume a reused callback's new admission epoch")
		}
	}
	Close() {
		global _UpdaterInstallObserver, _UpdaterInstallObserverEpoch
		SetTimer(this.TimerFn, 0)
		this.TimerFn := 0, this.SinkFn := 0
		try {
			; Teardown owns only admissions issued by this fixture. Suppress its
			; callbacks before retiring the retained exact private transaction.
			if IsObject(_UpdaterInstallObserver) {
				AssertTrue(_UpdaterInstallObserver == this.OldFn || _UpdaterInstallObserver == this.NewFn)
				AssertEqual(this.OwnedObserverEpoch, _UpdaterInstallObserverEpoch)
				_UpdaterInstallObserver := 0
				_UpdaterInstallObserverEpoch += 1
			}
			Epoch := this.OwnedEpoch
			if !Epoch
				return
			_Updater_CancelSelfUpdateTransaction("Install phase owner fixture cleanup.", false, false, Epoch)
		} finally {
			this.OldFn := 0, this.NewFn := 0
		}
	}
}

_UIPO_Case(Mode) {
	global _UpdaterDownloadInProgress, _UpdaterDownloadWorker, _UpdaterDownloadRequest
	global _UpdaterDownloadArtifacts, _UpdaterDownloadStartedTick, _UpdaterSelfUpdateEpoch
	global _UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation
	global _UpdaterInstallObserver, _UpdaterInstallObserverEpoch, _UpdaterManagedFailureOwner
	global _UpdaterRecoveryPublishTarget, _UpdaterCurlCaptureDebt, _UpdaterSwapCleanupDebt
	global _UpdaterSwapTransactionCounter, _UpdaterAsyncActionLeases
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_PATH_DATE, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	global _HealthCheckWarnCount, _HealthCheckLastError, _HealthCheckErrCount, _ED_Policy, _ED_Busy, _ED_PendingRecord
	AssertFalse(A_IsSuspended)
	AssertFalse(_UpdaterDownloadInProgress || IsObject(_UpdaterDownloadWorker) || IsObject(_UpdaterDownloadRequest))
	AssertFalse(_UpdaterSwapOwner is Map)
	AssertFalse(_UpdaterManagedFailureOwner is Map)
	AssertEqual(0, _UpdaterInstallObserver)
	AssertEqual(0, _UpdaterCurlCaptureDebt.Count)
	AssertEqual(0, _UpdaterSwapCleanupDebt.Count)
	AssertEqual(0, _UpdaterAsyncActionLeases.Count)
	AssertEqual("", _UpdaterRecoveryPublishTarget)
	AssertEqual(0, _LOGGER_TEST_SINK)
	AssertFalse(IsSet(_ED_Busy) && _ED_Busy)
	AssertFalse(IsSet(_ED_PendingRecord) && IsObject(_ED_PendingRecord))
	SavedLogger := _TLOG_CaptureLoggerState()
	AssertFalse(SavedLogger.FlushActive)
	SavedRequest := _UpdaterTest_SaveRequestState()
	Saved := {InProgress: _UpdaterDownloadInProgress, Worker: _UpdaterDownloadWorker,
		Request: _UpdaterDownloadRequest, Artifacts: _UpdaterDownloadArtifacts,
		Started: _UpdaterDownloadStartedTick, Epoch: _UpdaterSelfUpdateEpoch,
		Swap: _UpdaterSwapOwner, Intent: _UpdaterExitIntent, Invocation: _UpdaterExitInvocation,
		Observer: _UpdaterInstallObserver, ObserverEpoch: _UpdaterInstallObserverEpoch,
		Failure: _UpdaterManagedFailureOwner, SwapCounter: _UpdaterSwapTransactionCounter,
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
	static Sequence := 0
	Root := A_Temp . "\ergopti_install_phase_" . A_ScriptHwnd . "_" . A_TickCount . "_" . ++Sequence
	FSCreateDirectoryExclusiveStrict(Root)
	F := _UIPO_Fixture(Mode, Root), Primary := 0, CleanupFailure := 0
	PreviousCritical := A_IsCritical
	try {
		_UpdaterTest_ResetRequestState()
		_ED_Policy := 0
		_ResetLogger()
		LOGGER_SUB_FILES := Map(), _LOGGER_SUB_PENDING := Map(), _LOGGER_SUB_PATHS := Map()
		_LOGGER_REPEAT_ENABLED := false, _LOGGER_PATH_DATE := ""
		_LOGGER_CLOCK_FN := 0, _LOGGER_STAMP_FN := 0
		Critical("Off")
		F.Exercise()
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			LoggerClearTestSink()
			F.Close()
			AssertFalse(_UpdaterDownloadInProgress || IsObject(_UpdaterDownloadWorker))
			AssertFalse(_UpdaterSwapOwner is Map)
			DirDelete(Root, true)
		} catch Any as Failure {
			CleanupFailure := Failure
		} finally {
			_UpdaterTest_RestoreRequestState(SavedRequest)
			_UpdaterDownloadInProgress := Saved.InProgress, _UpdaterDownloadWorker := Saved.Worker
			_UpdaterDownloadRequest := Saved.Request, _UpdaterDownloadArtifacts := Saved.Artifacts
			_UpdaterDownloadStartedTick := Saved.Started, _UpdaterSelfUpdateEpoch := Saved.Epoch
			_UpdaterSwapOwner := Saved.Swap, _UpdaterExitIntent := Saved.Intent, _UpdaterExitInvocation := Saved.Invocation
			_UpdaterInstallObserver := Saved.Observer, _UpdaterInstallObserverEpoch := Saved.ObserverEpoch
			_UpdaterManagedFailureOwner := Saved.Failure, _UpdaterSwapTransactionCounter := Saved.SwapCounter
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

for _UIPO_Mode in ["cancel-distinct", "cancel-shared", "ready-distinct", "ready-shared", "cancel-current", "ready-current"]
	Test("Updater install phase: " . _UIPO_Mode . " preserves exact transaction observation (updater-install-phase-owner)",
		_UIPO_Case.Bind(_UIPO_Mode))
