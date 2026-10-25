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
	Admit(Observer, Image, Acquire := true, WriteImage := true) {
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
		if Acquire
			AssertTrue(_Updater_AcquireStagingArtifacts(Outcome.Epoch) is _UpdaterStagedArtifactRetirement,
				"the real parent owns exclusive staged files before any worker can exist")
		if !WriteImage
			return {Admission: Admission, Request: Request, Epoch: Outcome.Epoch}
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
	ExerciseStagingCleanup() {
		global _UpdaterDownloadWorker, _UpdaterDownloadArtifacts, _UpdaterCurlCaptureDebt, _UpdaterCurlCaptureRetry
		global _UpdaterSwapTransactionCounter, UPDATER_REQUEST_ORIGIN_MANUAL
		Old := this.Admit(this.OldFn, "original")
		Capture := _UpdaterCurlCaptureLedger()
		Capture.Acquire(this.Root)
		Worker := _UIPO_QuiescentWorker()
		Capture.Attach(Worker)
		_UpdaterDownloadArtifacts.CurlCapture := Capture
		_UpdaterDownloadArtifacts.StagingRetirement.Capture := Capture
		Artifacts := _UpdaterDownloadArtifacts
		Blocker := 0
		Moved := this.NewExe . ".original"
		try {
			if this.Mode != "artifact-failed-swap" {
				BlockedPath := this.Mode == "artifact-stage-reader" ? this.NewExe : Capture.Files["artifact.bin"]["path"]
				Blocker := Capture.Open(BlockedPath, 0x80000000, 3, false, 3)
				AssertTrue(Blocker != 0, "a real foreign reader must deny native file deletion")
				_UpdaterDownloadWorker := Worker
				AssertTrue(_Updater_CancelSelfUpdateTransaction(
					"Install phase fixture: native capture retirement was deferred.", false, false, Old.Epoch))
				if HasMethod(_UpdaterCurlCaptureRetry, "Call")
					SetTimer(_UpdaterCurlCaptureRetry, 0)
				_UpdaterCurlCaptureRetry := 0
				AssertEqual(this.Mode == "artifact-stage-reader", Capture.Retired,
					"only a capture-file reader retains native capture handles")
				Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
				Pending := _Updater_TryReserveDownloadTransaction(Request, false)
				AssertFalse(Pending.Reserved, "real native refusal retains admission debt")
				AssertTrue(Pending.RecoveryBusy, "a successor must observe the outstanding cleanup obligation")
				AssertEqual("original", FileRead(this.NewExe, "UTF-8"), "no staging deletion precedes native quiescence")
				if this.Mode == "artifact-replaced-after-cancel" {
					AssertTrue(DllCall("kernel32\MoveFileW", "Str", this.NewExe, "Str", Moved, "Int"))
					AssertTrue(FSWriteCreateDurable(this.NewExe, "foreign replacement"))
				}
				AssertTrue(DllCall("kernel32\CloseHandle", "Ptr", Blocker, "Int"))
				Blocker := 0
				if this.Mode == "artifact-replaced-after-cancel" {
					AssertFalse(_Updater_RetryCurlCaptureDebt(), "a foreign path replacement cannot borrow retained deletion authority")
					AssertEqual("foreign replacement", FileRead(this.NewExe, "UTF-8"))
					AssertEqual("original", FileRead(Moved, "UTF-8"))
					FileDelete(this.NewExe)
					AssertTrue(DllCall("kernel32\MoveFileW", "Str", Moved, "Str", this.NewExe, "Int"))
				}
				AssertTrue(_Updater_RetryCurlCaptureDebt(), "closing the native reader allows exact retirement retry")
			} else {
				Id := ++_UpdaterSwapTransactionCounter
				Owner := _Updater_ReserveSwapOwner(Id, Old.Epoch)
				AssertTrue(Owner is Map && !Owner["ProcessHandle"], "the fixture must never launch a swap process")
				; The genuine READY callback first admits the worker-created files.
				; This occupied reservation prevents native process creation and
				; exercises the real failed-swap terminal in the same callback.
				_Updater_PollDownloadAsync(0, "READY", "", this.SwapPath,
					this.NewExe, this.Root . "\current.exe", "v1.0.0", Old.Epoch)
			}
			AssertTrue(Capture.Retired, "the old private native capture must be completely retired")
			Created := FSWriteCreateDurable(this.NewExe, "next-release")
			FileAppend("RECEIPT updater-staging-cleanup mode=" . this.Mode
				. " exclusive_create=" . Created . " swap_exists=" . !!FileExist(this.SwapPath) . "`n", "*")
			AssertTrue(Created, "terminal cleanup must leave the next authenticated CreateNew download possible")
			AssertFalse(FileExist(this.SwapPath), "a failed transaction cannot leave a stale swap script collision")
		} finally {
			SetTimer(_Updater_ShowDeferredSwapFailureNotice, 0)
			if Blocker
				AssertTrue(DllCall("kernel32\CloseHandle", "Ptr", Blocker, "Int"))
			if FileExist(Moved) {
				if FileExist(this.NewExe)
					FileDelete(this.NewExe)
				AssertTrue(DllCall("kernel32\MoveFileW", "Str", Moved, "Str", this.NewExe, "Int"))
			}
			Retirement := Artifacts.HasOwnProp("StagingRetirement") ? Artifacts.StagingRetirement : Capture
			AssertTrue(_Updater_RetireCurlCapture(Retirement), "fixture native handles must retire even after an assertion failure")
		}
	}
	OnAllocationCancel(*) {
		try AssertTrue(_Updater_CancelSelfUpdateTransaction(
			"Install phase fixture: cancelled at native allocation admission.", false, false, this.AllocationEpoch))
		catch Any as Failure
			this.Error := Failure
		finally this.Done := true
	}
	ExerciseAllocationAdmission() {
		global _UpdaterDownloadArtifacts, _UpdaterCurlCaptureRetry
		Old := this.Admit(this.OldFn, "", false, false)
		this.AllocationEpoch := Old.Epoch
		this.AllocationTimer := ObjBindMethod(this, "OnAllocationCancel")
		Owner := _UIPO_AllocationAdmissionBoundary(_UpdaterDownloadArtifacts, this)
		_UpdaterDownloadArtifacts.StagingRetirement := Owner
		try {
			Owner.AcquireExclusive()
			Started := A_TickCount
			while !this.Done && TickElapsed(Started) < 2000
				Sleep(10)
			AssertTrue(this.Done, "a genuine cancellation timer must cross allocation admission")
			if IsObject(this.Error)
				throw this.Error
			if HasMethod(_UpdaterCurlCaptureRetry, "Call")
				SetTimer(_UpdaterCurlCaptureRetry, 0)
			_UpdaterCurlCaptureRetry := 0
			AssertTrue(_Updater_RetryCurlCaptureDebt())
			AssertTrue(Owner.Retired)
			AssertFalse(FileExist(this.NewExe) || FileExist(this.SwapPath), "cancelled allocation cannot orphan actual staged files")
			for Name, Entry in Owner.Files
				AssertEqual(0, Entry["handle"], "every native creation remains owned through the real cancellation")
		} finally {
			SetTimer(this.AllocationTimer, 0)
			; The broken admission can retire an empty owner, then allocate new
			; real handles. Reopen only this fixture's exact ledger for cleanup;
			; the physical orphan assertions above remain the verdict.
			for Name, Entry in Owner.Files
				if Entry["handle"]
					Owner.Retired := false
			AssertTrue(_Updater_RetireCurlCapture(Owner), "the fixture closes every actual native handle even on its negative control")
		}
	}
	ExerciseInvalidStagingMetadata() {
		global _UpdaterDownloadArtifacts, _UpdaterDownloadInProgress
		Old := this.Admit(this.OldFn, "foreign initial bytes", false)
		Artifacts := _UpdaterDownloadArtifacts
		_Updater_StartStagingWorker("https://example.invalid/refused.exe", "", this.NewExe, this.SwapPath,
			this.Root . "\current.exe", "v1.0.0", Old.Epoch, 0, Old.Request, , 0)
		AssertFalse(_UpdaterDownloadInProgress, "invalid authenticated metadata must settle the real reservation")
		AssertFalse(Artifacts.HasOwnProp("StagingRetirement"), "invalid metadata refuses before any native file acquisition")
		AssertEqual("foreign initial bytes", FileRead(this.NewExe, "UTF-8"))
		AssertEqual("foreign initial bytes-swap", FileRead(this.SwapPath, "UTF-8"))
	}
	ExerciseExclusiveCollision() {
		global _UpdaterDownloadArtifacts, UPDATER_REQUEST_ORIGIN_MANUAL
		ForeignPath := this.Mode == "artifact-create-new-collision" ? this.NewExe : this.SwapPath
		AssertTrue(FSWriteCreateDurable(ForeignPath, "independent collision bytes"))
		Old := this.Admit(this.OldFn, "", false, false)
		AssertFalse(IsObject(_Updater_AcquireStagingArtifacts(Old.Epoch)), "CREATE_NEW must refuse preexisting native identity")
		Owner := _UpdaterDownloadArtifacts.StagingRetirement
		AssertTrue(Owner.ExclusiveAllocated, "the failed allocation retains its own partial custody")
		AssertEqual(this.Mode == "artifact-create-new-collision" ? 0 : 1, Owner.Files.Count,
			"only successful native creations enter the exact cleanup ledger")
		AssertTrue(_Updater_EndDownloadTransaction(Old.Epoch))
		AssertTrue(Owner.Retired, "failed parent allocation must acknowledge all partial native cleanup")
		AssertEqual("independent collision bytes", FileRead(ForeignPath, "UTF-8"))
		if ForeignPath != this.NewExe
			AssertFalse(FileExist(this.NewExe), "the genuinely created partial executable must retire")
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
		After := _Updater_TryReserveDownloadTransaction(Request, false)
		AssertTrue(After.Reserved, "a closed partial allocation cannot strand successor admission")
		this.OwnedEpoch := After.Epoch
	}
	ExerciseUnacquiredCancellation() {
		AssertTrue(FSWriteCreateDurable(this.NewExe, "preexisting foreign bytes"))
		AssertTrue(FSWriteCreateDurable(this.SwapPath, "preexisting foreign bytes-swap"))
		Old := this.Admit(this.OldFn, "", false, false)
		AssertTrue(_Updater_CancelSelfUpdateTransaction(
			"Install phase fixture: cancelled before worker acquisition.", false, false, Old.Epoch))
		AssertEqual("preexisting foreign bytes", FileRead(this.NewExe, "UTF-8"),
			"registration alone cannot authorize deletion of an existing executable")
		AssertEqual("preexisting foreign bytes-swap", FileRead(this.SwapPath, "UTF-8"))
	}
	ExerciseStagingCloseDebt() {
		global _UpdaterDownloadArtifacts
		this.Admit(this.OldFn, "", false, false)
		Owner := _UIPO_StagingCloseRefusal(_UpdaterDownloadArtifacts)
		try {
			AssertFalse(Owner.AcquireExclusive(), "a retained native lease cannot authorize staged handoff")
			AssertEqual(1, Owner.ProbeCloseDebt.Length)
			AssertTrue(Owner.Snapshot(Owner.ProbeCloseDebt[1]) is Map,
				"the injected refusal must retain an actual open native directory reference")
			AssertFalse(Owner.Validate(), "validation cannot bypass the retained close debt")
		} finally {
			for Handle in Owner.ProbeCloseDebt
				AssertTrue(DllCall("kernel32\CloseHandle", "Ptr", Handle, "Int"))
			Owner.ProbeCloseDebt := []
			AssertTrue(Owner.Retire(), "the fixture must close every exact native reference")
		}
	}
	ExerciseRejectedStaging() {
		global _UpdaterDownloadArtifacts
		Old := this.Admit(this.OldFn, "foreign existing bytes", false)
		Artifacts := _UpdaterDownloadArtifacts
		_Updater_PollDownloadAsync(1, "refused before acquiring files", "", this.SwapPath,
			this.NewExe, this.Root . "\current.exe", "v1.0.0", Old.Epoch)
		AssertFalse(Artifacts.HasOwnProp("StagingComplete"), "a failure receipt conveys no creation authority")
		AssertEqual("foreign existing bytes", FileRead(this.NewExe, "UTF-8"))
		AssertEqual("foreign existing bytes-swap", FileRead(this.SwapPath, "UTF-8"))
	}
	OnRetirementTimer() {
		global UPDATER_REQUEST_ORIGIN_MANUAL
		try {
			AssertFalse(A_IsCritical, "the termination boundary must permit actual callback interruption")
			Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
			this.RetirementOutcome := _Updater_BeginDownloadTransaction(Request, false,
				"v1.0.1", "https://example.invalid/successor.exe")
			if this.RetirementOutcome.Reserved {
				this.OwnedEpoch := this.RetirementOutcome.Epoch
				AssertTrue(_Updater_RegisterDownloadArtifacts(this.OwnedEpoch, this.NewExe, this.SwapPath))
				AssertTrue(FSWriteDurable(this.NewExe, "successor"))
				AssertTrue(FSWriteDurable(this.SwapPath, "successor-swap"))
			}
		} catch Any as Failure
			this.Error := Failure
		finally this.Done := true
	}
	ExerciseRetirementAdmission() {
		global _UpdaterDownloadWorker, _UpdaterDownloadArtifacts, UPDATER_REQUEST_ORIGIN_MANUAL
		Old := this.Admit(this.OldFn, "original")
		Worker := _UIPO_RetirementWorker(this)
		Capture := _UpdaterCurlCaptureLedger()
		_UpdaterDownloadArtifacts.CurlCapture := Capture
		_UpdaterDownloadArtifacts.StagingRetirement.Capture := Capture
		Capture.Acquire(this.Root)
		Capture.Attach(Worker)
		_UpdaterDownloadWorker := Worker
		if this.Mode == "retire-end-admission"
			AssertTrue(_Updater_EndDownloadTransaction(Old.Epoch))
		else
			AssertTrue(_Updater_CancelSelfUpdateTransaction(
				"Install phase owner fixture: retiring original.", false, false, Old.Epoch))
		if IsObject(this.Error)
			throw this.Error
		AssertTrue(this.Done, "a real timer must attempt admission while the retiring worker yields")
		AssertTrue(Worker.Calls >= (this.Mode == "retire-end-admission" ? 1 : 2),
			"the genuine capture owner must acknowledge tree retirement too")
		FileAppend("RECEIPT updater-retirement-admission admitted=" . this.RetirementOutcome.Reserved
			. " new_exists=" . !!FileExist(this.NewExe) . " swap_exists=" . !!FileExist(this.SwapPath)
			. " terminate_calls=" . Worker.Calls . "`n", "*")
		AssertFalse(this.RetirementOutcome.Reserved,
			"a successor must not acquire shared staging paths before the previous worker and files retire")
		AssertTrue(Capture.Retired, "the old private native capture must be fully released")
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
		After := _Updater_BeginDownloadTransaction(Request, false, "v1.0.1", "https://example.invalid/successor.exe")
		AssertTrue(After.Reserved, "successful retirement must reopen install admission")
		this.OwnedEpoch := After.Epoch
		AssertTrue(_Updater_RegisterDownloadArtifacts(After.Epoch, this.NewExe, this.SwapPath))
		AssertTrue(FSWriteDurable(this.NewExe, "successor"))
		AssertTrue(FSWriteDurable(this.SwapPath, "successor-swap"))
		AssertEqual("successor", FileRead(this.NewExe, "UTF-8"))
		AssertEqual("successor-swap", FileRead(this.SwapPath, "UTF-8"))
	}
	Exercise() {
		global _UpdaterInstallObserver, _UpdaterInstallObserverEpoch
		global _UpdaterDownloadInProgress, _UpdaterDownloadRequest, _UpdaterDownloadArtifacts
		global _UpdaterDownloadWorker, _UpdaterSwapOwner, _UpdaterSwapTransactionCounter
		if this.Mode == "artifact-allocation-admission"
			return this.ExerciseAllocationAdmission()
		if this.Mode == "artifact-invalid-metadata"
			return this.ExerciseInvalidStagingMetadata()
		if this.Mode == "artifact-create-new-collision" || this.Mode == "artifact-create-swap-collision"
			return this.ExerciseExclusiveCollision()
		if this.Mode == "artifact-unacquired-cancel"
			return this.ExerciseUnacquiredCancellation()
		if this.Mode == "artifact-close-debt"
			return this.ExerciseStagingCloseDebt()
		if this.Mode == "artifact-rejected-collision"
			return this.ExerciseRejectedStaging()
		if InStr(this.Mode, "artifact-") == 1
			return this.ExerciseStagingCleanup()
		if this.Mode == "retire-admission" || this.Mode == "retire-end-admission"
			return this.ExerciseRetirementAdmission()
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


; Mirrors the tree port's synchronous termination acknowledgement while exposing
; its yielding boundary. Native capture acquisition and retirement remain real.
class _UIPO_RetirementWorker {
	__New(Fixture) {
		this.Fixture := Fixture
		this.Calls := 0
	}
	terminate() {
		this.Calls += 1
		if this.Calls != 1
			return true
		F := this.Fixture
		Timer := ObjBindMethod(F, "OnRetirementTimer")
		try {
			SetTimer(Timer, -1)
			Started := A_TickCount
			while !F.Done && TickElapsed(Started) < 2000
				Sleep(10)
			AssertTrue(F.Done, "the real timer must run before termination acknowledges completion")
		} finally SetTimer(Timer, 0)
		return true
	}
}


; The child has already exited on these terminal paths; the actual file and
; directory handles below still determine whether retirement can complete.
class _UIPO_AllocationAdmissionBoundary extends _UpdaterStagedArtifactRetirement {
	__New(Artifacts, Fixture) {
		super.__New(Artifacts)
		this.Fixture := Fixture
		this.Armed := true
	}
	Retired {
		get {
			Captured := this.StoredRetired
			if this.HasOwnProp("Armed") && this.Armed {
				this.Armed := false
				SetTimer(this.Fixture.AllocationTimer, -1)
				if !A_IsCritical {
					Started := A_TickCount
					while !this.Fixture.Done && TickElapsed(Started) < 2000
						Sleep(10)
					AssertTrue(this.Fixture.Done, "the unprotected guard must yield to an actual cancellation")
				}
			}
			return Captured
		}
		set => this.StoredRetired := value
	}
}

class _UIPO_StagingCloseRefusal extends _UpdaterStagedArtifactRetirement {
	CloseProbe(Handle) {
		if !this.HasOwnProp("Refused") {
			this.Refused := true
			this.ProbeCloseDebt.Push(Handle)
			return false
		}
		return super.CloseProbe(Handle)
	}
}

class _UIPO_QuiescentWorker {
	terminate() {
		return true
	}
}

_UIPO_Case(Mode) {
	global _UpdaterDownloadInProgress, _UpdaterDownloadWorker, _UpdaterDownloadRequest
	global _UpdaterDownloadArtifacts, _UpdaterDownloadStartedTick, _UpdaterSelfUpdateEpoch, _UpdaterDownloadRetirement
	global _UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation
	global _UpdaterInstallObserver, _UpdaterInstallObserverEpoch, _UpdaterManagedFailureOwner
	global _UpdaterRecoveryPublishTarget, _UpdaterCurlCaptureDebt, _UpdaterSwapCleanupDebt
	global _UpdaterSwapTransactionCounter, _UpdaterAsyncActionLeases
	global _LOGGER_TEST_SINK, _LOGGER_REPEAT_ENABLED, _LOGGER_PATH_DATE, _LOGGER_CLOCK_FN, _LOGGER_STAMP_FN
	global LOGGER_SUB_FILES, _LOGGER_SUB_PENDING, _LOGGER_SUB_PATHS
	global _HealthCheckWarnCount, _HealthCheckLastError, _HealthCheckErrCount, _ED_Policy, _ED_Busy, _ED_PendingRecord
	AssertFalse(A_IsSuspended)
	AssertFalse(_UpdaterDownloadInProgress || IsObject(_UpdaterDownloadWorker) || IsObject(_UpdaterDownloadRequest))
	AssertFalse(IsObject(_UpdaterDownloadRetirement))
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
		Started: _UpdaterDownloadStartedTick, Epoch: _UpdaterSelfUpdateEpoch, Retirement: _UpdaterDownloadRetirement,
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
			AssertFalse(IsObject(_UpdaterDownloadRetirement), "no terminal admission fence may leak")
			AssertFalse(_UpdaterSwapOwner is Map)
			DirDelete(Root, true)
		} catch Any as Failure {
			CleanupFailure := Failure
		} finally {
			_UpdaterTest_RestoreRequestState(SavedRequest)
			_UpdaterDownloadInProgress := Saved.InProgress, _UpdaterDownloadWorker := Saved.Worker
			_UpdaterDownloadRequest := Saved.Request, _UpdaterDownloadArtifacts := Saved.Artifacts
			_UpdaterDownloadStartedTick := Saved.Started, _UpdaterSelfUpdateEpoch := Saved.Epoch
			_UpdaterDownloadRetirement := Saved.Retirement
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

Test("Updater install phase: retirement fences successor admission (updater-retirement-admission)",
	_UIPO_Case.Bind("retire-admission"))

Test("Updater install phase: completion fences successor admission (updater-retirement-admission)",
	_UIPO_Case.Bind("retire-end-admission"))

for _UIPO_CleanupMode in ["artifact-deferred-cleanup", "artifact-failed-swap",
		"artifact-stage-reader", "artifact-replaced-after-cancel"]
	Test("Updater staging: " . _UIPO_CleanupMode . " leaves the next download possible (updater-staging-terminal-cleanup)",
		_UIPO_Case.Bind(_UIPO_CleanupMode))

Test("Updater staging: a refused writer cannot delete preexisting paths (updater-staging-terminal-cleanup)",
	_UIPO_Case.Bind("artifact-rejected-collision"))

Test("Updater staging: native close debt cannot authorize handoff (updater-staging-close-debt)",
	_UIPO_Case.Bind("artifact-close-debt"))

Test("Updater staging: cancellation cannot delete unacquired paths (updater-staging-cancel-custody)",
	_UIPO_Case.Bind("artifact-unacquired-cancel"))

for _UIPO_CollisionMode in ["artifact-create-new-collision", "artifact-create-swap-collision"]
	Test("Updater staging: " . _UIPO_CollisionMode . " preserves foreign native custody (updater-staging-cancel-custody)",
		_UIPO_Case.Bind(_UIPO_CollisionMode))

_UIPO_RunNativeStreamControl(Owner, Mode) {
	global _VendorDir
	Args := [_Updater_PowerShellPath(), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-File", A_ScriptDir . "\fixtures\updater_staged_custody.ps1", "-Module", _VendorDir . "\ergopti_updater_download.ps1",
		"-Path", Owner.Files["NewExe"]["path"], "-ExpectedIdentity", Owner.Identity(Owner.Files["NewExe"]),
		"-ExpectedDirectoryIdentity", Owner.Identity(Owner.Directory), "-Mode", Mode]
	Command := ""
	for Arg in Args
		Command .= (Command == "" ? "" : " ") . _Updater_QuoteCreateProcessArg(Arg)
	AssertEqual(0, RunWait(Command, , "Hide"), "the actual Windows PowerShell child must prove " . Mode . " custody")
}

_UIPO_NativeStreamCustody() {
	Root := RTrim(_SR_AcquireCaptureDirectory(), "\")
	Artifacts := {NewExe: Root . "\new.exe", SwapScript: Root . "\swap.ps1"}
	Owner := _UpdaterStagedArtifactRetirement(Artifacts)
	Moved := Artifacts.NewExe . ".original"
	try {
		AssertTrue(Owner.AcquireExclusive())
		_UIPO_RunNativeStreamControl(Owner, "accept")
		_UIPO_RunNativeStreamControl(Owner, "nonempty")
		AssertTrue(DllCall("kernel32\MoveFileW", "Str", Artifacts.NewExe, "Str", Moved, "Int"))
		AssertTrue(FSWriteCreateDurable(Artifacts.NewExe, ""))
		_UIPO_RunNativeStreamControl(Owner, "foreign")
		AssertEqual("abc", FileRead(Moved, "UTF-8"))
		AssertEqual("", FileRead(Artifacts.NewExe, "UTF-8"), "an independently created empty replacement must remain untouched")
	} finally {
		if FileExist(Moved) {
			if FileExist(Artifacts.NewExe)
				FileDelete(Artifacts.NewExe)
			AssertTrue(DllCall("kernel32\MoveFileW", "Str", Moved, "Str", Artifacts.NewExe, "Int"))
		}
		AssertTrue(Owner.Retire(), "actual parent references must close after every child control")
		DirDelete(Root, false)
	}
}

Test("Updater staging: actual child streams enforce parent identities and preserve refused bytes (updater-staging-native-custody)",
	_UIPO_NativeStreamCustody)

Test("Updater staging: invalid authenticated metadata refuses before file allocation (updater-staging-invalid-custody)",
	_UIPO_Case.Bind("artifact-invalid-metadata"))

_UIPO_StagedDirectoryDebtReceipt() {
	Envelope := '{"schema_version":1,"state":"failed","operation":"download","reason":"download","receipt":{},'
		. '"cleanup_debt":[{"resource":"staging_directory","receipt":{"backend":"dotnet","stage":"file_create","failure_provenance":"unknown"}}]}'
	Debt := _Updater_ParseStagingFailure(Envelope)
	AssertTrue(Debt["valid"], "the new physical directory lease must retain its cleanup receipt")
	AssertEqual(1, Debt["cleanup_debt"].Length)
	AssertEqual("staging_directory", Debt["cleanup_debt"][1]["resource"])
	Refused := _Updater_ParseStagingFailure(StrReplace(Envelope, '"staging_directory"', '"STAGING_DIRECTORY"'))
	AssertFalse(Refused["valid"], "the resource admission remains closed and case-sensitive")
}
Test("Updater staging: parent directory cleanup debt retains its bounded receipt (updater-staging-directory-debt)",
	_UIPO_StagedDirectoryDebtReceipt)

Test("Updater staging: native allocation admission retains cancellation debt (updater-staging-allocation-admission)",
	_UIPO_Case.Bind("artifact-allocation-admission"))
