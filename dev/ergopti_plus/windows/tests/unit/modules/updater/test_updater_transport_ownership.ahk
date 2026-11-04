; tests/unit/modules/updater/test_updater_transport_ownership.ahk

; ==============================================================================
; MODULE: Updater Transport Ownership
; DESCRIPTION:
; AHK-31 and AHK-33: the updater owns its request before it prepares an
; async transport, and every preparation or send failure retires that exact
; owner.
; ==============================================================================

#Requires AutoHotkey v2.0





class _UpdaterTestOwnedPreparationHttp {
	__New(State, ThrowOnSend := false) {
		this.State := State
		this.ThrowOnSend := ThrowOnSend
	}

	Send() {
		this.State.Sends += 1
		if this.ThrowOnSend
			throw Error("deterministic Send failure")
		return true
	}

	Abort() {
		this.State.Aborts += 1
		return true
	}
}

class _UpdaterTestPhasePreparationHttp {
	__New(State, ThrowPhase) {
		this.State := State
		this.ThrowPhase := ThrowPhase
		State.TimeoutCalls := []
		State.TimeoutsAtSend := 0
	}

	_Visit(Phase) {
		this.State.PhaseVisits.Push(Phase)
		if (this.ThrowPhase == Phase)
			throw Error("deterministic " . Phase . " preparation failure")
	}

	Open(*) {
		this._Visit("open")
	}

	SetRequestHeader(Name, *) {
		if (Name == "Accept")
			Phase := "accept"
		else if (Name == "User-Agent")
			Phase := "user-agent"
		else if (Name == "If-None-Match")
			Phase := "etag"
		else
			Phase := "other-header"
		this._Visit(Phase)
	}

	SetTimeouts(Values*) {
		this._Visit("timeouts")
		this.State.TimeoutCalls.Push(Values)
	}

	Send() {
		this._Visit("send")
		this.State.TimeoutsAtSend := this.State.TimeoutCalls.Length
		this.State.Sends += 1
		return true
	}

	Abort() {
		this.State.Aborts += 1
		return true
	}
}

_UpdaterTest_CaptureOwnedPreparationTerminal(State, Json, Request,
	Terminal := 0) {
	State.Terminals += 1
	State.Json := Json
	State.CompletedRequest := Request
	State.Terminal := Terminal
}

_UpdaterTest_ThrowDuringPreparation(*) {
	throw Error("deterministic preparation failure")
}

_UpdaterTest_CancelUpdaterForSuspend(*) {
	global UPDATER_CANCEL_REASON_SUSPEND
	_Updater_CancelAsyncChecks(UPDATER_CANCEL_REASON_SUSPEND)
}

_UpdaterTest_CreatePhasePreparationHttp(State, ThrowPhase) {
	Http := _UpdaterTestPhasePreparationHttp(State, ThrowPhase)
	State.PhaseVisits.Push("factory")
	if (ThrowPhase == "factory")
		throw Error("deterministic factory preparation failure")
	return Http
}

_UpdaterTest_PrepareLatestWithFactory(PrepareLatest, FactoryFn, Owner) {
	return PrepareLatest.Call(Owner, FactoryFn)
}

_UpdaterTest_CancelDuringOwnedPreparation(State, RequestOwned, Owner) {
	State.OwnedDuringCancel := RequestOwned.Call(Owner)
	_UpdaterTest_CancelUpdaterForSuspend()
	return _UpdaterTestOwnedPreparationHttp(State)
}

_UpdaterTest_OwnerPrecedesTransportPreparation() {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	RegisterOwner := _UpdaterTest_ResolveFunction(
		"_Updater_RegisterAsyncRequestOwner")
	SendOwned := _UpdaterTest_ResolveFunction("_Updater_SendOwnedAsyncRequest")
	RequestOwned := _UpdaterTest_ResolveFunction("_Updater_AsyncRequestOwned")
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		State := { OwnedDuringPrepare: false, Sends: 0, Aborts: 0,
			Polls: 0, Terminals: 0, Json: "not-called",
			CompletedRequest: 0, Terminal: 0 }
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		Owner := RegisterOwner.Call(
			0, "main",
			_UpdaterTest_CaptureOwnedPreparationTerminal.Bind(State),
			"test://owner-before-preparation", Request)
		PrepareFn := (ExactOwner) => (
			State.OwnedDuringPrepare := RequestOwned.Call(ExactOwner),
			_UpdaterTestOwnedPreparationHttp(State))
		PollFn := (Id) => (State.Polls += 1, true)

		Assert(IsObject(Owner),
			"the async request must publish an opaque owner before preparation")
		AssertEqual(true, SendOwned.Call(
			Owner, PollFn, "test owned preparation", PrepareFn),
			"owned preparation must reach Send and its poll handoff")
		AssertEqual(true, State.OwnedDuringPrepare,
			"registry ownership must already exist when the first transport effect runs")
		AssertEqual(1, State.Sends,
			"the prepared exact transport must be sent once")
		AssertEqual(1, State.Polls,
			"a successful owned Send must hand off to one poll owner")
		AssertEqual(0, State.Terminals,
			"a successful dispatch must not manufacture a failure terminal")
		_Updater_CancelAsyncChecks("test cleanup")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: owner precedes async transport preparation (updater-owner-before-preparation)",
	_UpdaterTest_OwnerPrecedesTransportPreparation)

_UpdaterTest_PreparationThrowRetiresExactOwner() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, _UpdaterAsyncRequests
	RegisterOwner := _UpdaterTest_ResolveFunction(
		"_Updater_RegisterAsyncRequestOwner")
	SendOwned := _UpdaterTest_ResolveFunction("_Updater_SendOwnedAsyncRequest")
	RequestOwned := _UpdaterTest_ResolveFunction("_Updater_AsyncRequestOwned")
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		State := { Sends: 0, Aborts: 0, Polls: 0, Terminals: 0,
			Json: "not-called", CompletedRequest: 0, Terminal: 0 }
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		Owner := RegisterOwner.Call(
			0, "main",
			_UpdaterTest_CaptureOwnedPreparationTerminal.Bind(State),
			"test://preparation-throws", Request)
		PrepareFn := _UpdaterTest_ThrowDuringPreparation
		PollFn := (Id) => (State.Polls += 1, true)

		AssertEqual(false, SendOwned.Call(
			Owner, PollFn, "test preparation throw", PrepareFn),
			"a preparation exception must close the owned dispatch")
		AssertEqual(1, State.Terminals,
			"preparation failure must deliver exactly one callback terminal")
		Assert(State.Json is String and State.Json == "",
			"preparation failure must deliver the canonical empty JSON failure")
		Assert(IsObject(State.CompletedRequest)
			and ObjPtr(State.CompletedRequest) == ObjPtr(Request),
			"failure must terminal the immutable request that owned preparation")
		AssertEqual(false, RequestOwned.Call(Owner),
			"preparation failure must retire the exact registry owner")
		AssertEqual(0, _UpdaterAsyncRequests.Count,
			"preparation failure must leave no orphaned registry entry")
		AssertEqual(0, State.Polls,
			"a failed preparation must never arm response polling")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: preparation failure retires exact owner (updater-owner-before-preparation)",
	_UpdaterTest_PreparationThrowRetiresExactOwner)

_UpdaterTest_PreparationThrowAtEveryPhaseRetiresOwner() {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	global _UpdaterAsyncRequests, _UpdaterFetchCache
	RegisterOwner := _UpdaterTest_ResolveFunction(
		"_Updater_RegisterAsyncRequestOwner")
	SendOwned := _UpdaterTest_ResolveFunction("_Updater_SendOwnedAsyncRequest")
	RequestOwned := _UpdaterTest_ResolveFunction("_Updater_AsyncRequestOwned")
	PrepareLatest := _UpdaterTest_ResolveFunction(
		"_Updater_PrepareLatestAsyncTransport")
	Saved := _UpdaterTest_SaveRequestState()
	HadCache := _UpdaterFetchCache.Has("main")
	SavedCache := HadCache ? _UpdaterFetchCache["main"] : 0
	try {
		_UpdaterFetchCache["main"] := { Etag: '"owner-test-etag"' }
		PreparationPhases := [
			"factory", "open", "accept", "user-agent", "timeouts", "etag"]
		for PhaseIndex, ThrowPhase in PreparationPhases {
			_UpdaterTest_ResetRequestState()
			State := { PhaseVisits: [], Sends: 0, Aborts: 0, Polls: 0,
				Terminals: 0, Json: "not-called", CompletedRequest: 0,
				Terminal: 0 }
			Request := _Updater_NewRequestContext(
				UPDATER_REQUEST_ORIGIN_MANUAL, false)
			Owner := RegisterOwner.Call(
				0, "main",
				_UpdaterTest_CaptureOwnedPreparationTerminal.Bind(State),
				"test://throw-during-" . ThrowPhase, Request)
			FactoryFn := _UpdaterTest_CreatePhasePreparationHttp.Bind(
				State, ThrowPhase)
			PrepareFn := _UpdaterTest_PrepareLatestWithFactory.Bind(
				PrepareLatest, FactoryFn)
			PollFn := (Id) => (State.Polls += 1, true)

			AssertEqual(false, SendOwned.Call(
				Owner, PollFn, "test phase preparation throw", PrepareFn),
				"a throw during " . ThrowPhase
				. " must stop the owned dispatch")
			AssertEqual(PhaseIndex, State.PhaseVisits.Length,
				"a throw during " . ThrowPhase
				. " must prevent every later preparation effect")
			AssertEqual(ThrowPhase, State.PhaseVisits[PhaseIndex],
				"the exact throwing preparation phase must be the last effect")
			AssertEqual(0, State.Sends,
				"a preparation owner that throws during " . ThrowPhase
				. " must never reach Send")
			AssertEqual(PhaseIndex == 1 ? 0 : 1, State.Aborts,
				"failure cleanup must abort exactly when a transport was published")
			AssertEqual(0, State.Polls,
				"a failed preparation must never hand off to polling")
			AssertEqual(1, State.Terminals,
				"each preparation failure must deliver exactly one terminal")
			AssertEqual(0, State.Terminal,
				"a preparation exception must not impersonate typed cancellation")
			Assert(IsObject(State.CompletedRequest)
				and ObjPtr(State.CompletedRequest) == ObjPtr(Request),
				"preparation failure must terminal the exact request")
			AssertEqual(false, RequestOwned.Call(Owner),
				"the failed exact owner must be retired")
			AssertEqual(0, _UpdaterAsyncRequests.Count,
				"preparation failure must leave no registry orphan")
		}
	} finally {
		if HadCache
			_UpdaterFetchCache["main"] := SavedCache
		else
			_UpdaterFetchCache.Delete("main")
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: every preparation phase failure retires exact owner (updater-owner-before-preparation)",
	_UpdaterTest_PreparationThrowAtEveryPhaseRetiresOwner)

_UpdaterTest_CancellationDuringOwnedPreparationWins() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, UPDATER_CANCEL_REASON_SUSPEND
	global _UpdaterAsyncRequests
	RegisterOwner := _UpdaterTest_ResolveFunction(
		"_Updater_RegisterAsyncRequestOwner")
	SendOwned := _UpdaterTest_ResolveFunction("_Updater_SendOwnedAsyncRequest")
	RequestOwned := _UpdaterTest_ResolveFunction("_Updater_AsyncRequestOwned")
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		State := { OwnedDuringCancel: false, Sends: 0, Aborts: 0,
			Polls: 0, Terminals: 0, Json: "not-called",
			CompletedRequest: 0, Terminal: 0 }
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		Owner := RegisterOwner.Call(
			0, "main",
			_UpdaterTest_CaptureOwnedPreparationTerminal.Bind(State),
			"test://cancel-during-preparation", Request)
		PrepareFn := _UpdaterTest_CancelDuringOwnedPreparation.Bind(
			State, RequestOwned)
		PollFn := (Id) => (State.Polls += 1, true)

		AssertEqual(false, SendOwned.Call(
			Owner, PollFn, "test cancellation during preparation", PrepareFn),
			"cancellation during preparation must win before Send")
		AssertEqual(true, State.OwnedDuringCancel,
			"cancellation reached from preparation must find the exact owner")
		AssertEqual(0, State.Sends,
			"a request cancelled during preparation must never reach Send")
		AssertEqual(0, State.Polls,
			"a request cancelled during preparation must never start polling")
		AssertEqual(1, State.Terminals,
			"preparation cancellation must deliver exactly one terminal")
		Assert(_Updater_AsyncTerminalIsCancelled(State.Terminal),
			"preparation cancellation must retain its typed terminal")
		AssertEqual(UPDATER_CANCEL_REASON_SUSPEND, State.Terminal.Reason,
			"preparation cancellation must preserve its suspend reason")
		Assert(IsObject(State.CompletedRequest)
			and ObjPtr(State.CompletedRequest) == ObjPtr(Request),
			"preparation cancellation must terminal the exact request")
		AssertEqual(false, RequestOwned.Call(Owner),
			"preparation cancellation must retire the exact owner")
		AssertEqual(0, _UpdaterAsyncRequests.Count,
			"preparation cancellation must leave no registry orphan")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: cancellation during owned preparation wins (updater-owner-before-preparation)",
	_UpdaterTest_CancellationDuringOwnedPreparationWins)

_UpdaterTest_SendThrowRetiresExactOwner() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, _UpdaterAsyncRequests
	RegisterOwner := _UpdaterTest_ResolveFunction(
		"_Updater_RegisterAsyncRequestOwner")
	SendOwned := _UpdaterTest_ResolveFunction("_Updater_SendOwnedAsyncRequest")
	RequestOwned := _UpdaterTest_ResolveFunction("_Updater_AsyncRequestOwned")
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		State := { Sends: 0, Aborts: 0, Polls: 0, Terminals: 0,
			Json: "not-called", CompletedRequest: 0, Terminal: 0 }
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		Owner := RegisterOwner.Call(
			0, "main",
			_UpdaterTest_CaptureOwnedPreparationTerminal.Bind(State),
			"test://send-throws", Request)
		PrepareFn := (*) => _UpdaterTestOwnedPreparationHttp(State, true)
		PollFn := (Id) => (State.Polls += 1, true)

		AssertEqual(false, SendOwned.Call(
			Owner, PollFn, "test Send throw", PrepareFn),
			"a Send exception must close the exact owned dispatch")
		AssertEqual(1, State.Sends,
			"the throwing transport must receive exactly one Send attempt")
		AssertEqual(1, State.Aborts,
			"Send failure cleanup must abort the exact prepared transport")
		AssertEqual(0, State.Polls,
			"a throwing Send must never hand off to polling")
		AssertEqual(1, State.Terminals,
			"Send failure must deliver exactly one failure terminal")
		Assert(State.Json is String and State.Json == "",
			"Send failure must deliver the canonical empty JSON failure")
		AssertEqual(0, State.Terminal,
			"a transport failure must not impersonate typed cancellation")
		AssertEqual(false, RequestOwned.Call(Owner),
			"Send failure must retire the exact registry owner")
		AssertEqual(0, _UpdaterAsyncRequests.Count,
			"Send failure must leave no orphaned registry entry")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: Send failure retires exact owner (updater-owner-before-preparation)",
	_UpdaterTest_SendThrowRetiresExactOwner)

_UpdaterTest_StaleOwnerCannotRetireReplacement() {
	global UPDATER_REQUEST_ORIGIN_MANUAL, _UpdaterAsyncRequests
	RegisterOwner := _UpdaterTest_ResolveFunction(
		"_Updater_RegisterAsyncRequestOwner")
	TakeRequest := _UpdaterTest_ResolveFunction("_Updater_TakeAsyncRequest")
	Saved := _UpdaterTest_SaveRequestState()
	try {
		_UpdaterTest_ResetRequestState()
		State := { Terminals: 0, Json: "not-called",
			CompletedRequest: 0, Terminal: 0 }
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		Owner := RegisterOwner.Call(
			0, "main",
			_UpdaterTest_CaptureOwnedPreparationTerminal.Bind(State),
			"test://stale-owner", Request)
		Replacement := Owner.Record.Clone()
		PreviousCritical := A_IsCritical
		Critical("On")
		try _UpdaterAsyncRequests[Owner.Id] := Replacement
		finally Critical(PreviousCritical ? PreviousCritical : "Off")

		AssertEqual(false, TakeRequest.Call(Owner.Id, Owner.Record),
			"a stale owner must not retire a replacement at the same numeric id")
		Assert(_UpdaterAsyncRequests.Has(Owner.Id),
			"the exact replacement must remain registered after a stale take")
		AssertEqual(ObjPtr(Replacement), ObjPtr(_UpdaterAsyncRequests[Owner.Id]),
			"stale cleanup must preserve the replacement object's identity")
		AssertEqual(0, State.Terminals,
			"a stale owner must not terminal the replacement request")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
	}
}
Test("Updater AHK-31: stale owner cannot retire replacement (updater-owner-before-preparation)",
	_UpdaterTest_StaleOwnerCannotRetireReplacement)


_UpdaterTest_InterruptDownloadStartBeforeReservation(State, Line) {
	global _UpdaterDownloadInProgress
	global UPDATER_CANCEL_REASON_SUSPEND
	State.Lines.Push(Line)
	if (State.Triggered or InStr(Line, "[START]") == 0
		or InStr(Line, "Downloading update") == 0)
		return
	State.Triggered := true
	State.OwnedAtStart := _UpdaterDownloadInProgress
	Pending := _Updater_SwapAsyncRequestsForBoundary(
		UPDATER_CANCEL_REASON_SUSPEND, Map())
	State.RetiredAsyncCount := Pending.Count
	State.CancelledTransaction := _Updater_CancelSelfUpdateForSuspend()
}

_UpdaterTest_DownloadStartPrecedesCancellableOwner() {
	global _UpdaterDownloadInProgress, _UpdaterDownloadWorker
	global _UpdaterDownloadRequest, _UpdaterSelfUpdateEpoch
	global _UpdaterRecoveryPublishTarget
	global _UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation
	global _LOGGER_TEST_SINK
	global UPDATER_REQUEST_ORIGIN_MANUAL
	SavedRequestState := _UpdaterTest_SaveRequestState()
	SavedSelfUpdate := {
		InProgress: _UpdaterDownloadInProgress,
		Worker: _UpdaterDownloadWorker,
		Request: _UpdaterDownloadRequest,
		Epoch: _UpdaterSelfUpdateEpoch,
		RecoveryTargetSet: IsSet(_UpdaterRecoveryPublishTarget),
		RecoveryTarget: IsSet(_UpdaterRecoveryPublishTarget)
			? _UpdaterRecoveryPublishTarget : "",
		SwapOwner: _UpdaterSwapOwner,
		ExitIntent: _UpdaterExitIntent,
		ExitInvocation: _UpdaterExitInvocation
	}
	SavedSink := _LOGGER_TEST_SINK
	State := {
		Lines: [],
		Triggered: false,
		OwnedAtStart: -1,
		RetiredAsyncCount: -1,
		CancelledTransaction: -1
	}
	try {
		_UpdaterTest_ResetRequestState()
		_UpdaterDownloadInProgress := false
		_UpdaterDownloadWorker := 0
		_UpdaterDownloadRequest := 0
		_UpdaterRecoveryPublishTarget := ""
		_UpdaterSwapOwner := 0
		_UpdaterExitIntent := 0
		_UpdaterExitInvocation := 0
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false)
		LoggerSetTestSink(
			_UpdaterTest_InterruptDownloadStartBeforeReservation.Bind(State))
		Outcome := _Updater_BeginDownloadTransaction(Request, false,
			"v-test-" . A_TickCount, "https://example.invalid/update.exe")

		AssertTrue(State.Triggered,
			"the deterministic logger sink must interrupt the exact download START")
		AssertFalse(State.OwnedAtStart,
			"START must become observable before any cancellable download owner is published")
		AssertEqual(0, State.RetiredAsyncCount,
			"the isolated interleave must retire no unrelated async request")
		AssertFalse(State.CancelledTransaction,
			"Pause inside START must find no half-published transaction to terminate")
		Assert(Outcome.ShouldDrop and !Outcome.Reserved,
			"the resumed reservation must reject the request invalidated inside START")
		AssertFalse(_UpdaterDownloadInProgress,
			"the rejected reservation must leave the central transaction unowned")
		AssertFalse(IsObject(_UpdaterDownloadRequest),
			"the rejected reservation must not publish stale manual provenance")

		StartCount := 0
		TerminalCount := 0
		StartPos := 0
		TerminalPos := 0
		for Index, LoggedLine in State.Lines {
			if (InStr(LoggedLine, "[START]") > 0
				and InStr(LoggedLine, "Downloading update") > 0) {
				StartCount += 1
				StartPos := Index
			}
			if ((InStr(LoggedLine, "[WARNING]") > 0
				or InStr(LoggedLine, "[ERROR]") > 0)
				and InStr(LoggedLine, "Download") > 0) {
				TerminalCount += 1
				TerminalPos := Index
			}
		}
		AssertEqual(1, StartCount,
			"the interrupted attempt must emit exactly one lifecycle START")
		AssertEqual(1, TerminalCount,
			"the rejected attempt must close START with exactly one terminal")
		Assert(TerminalPos > StartPos,
			"the terminal must follow START in observable logger order")
	} finally {
		_LOGGER_TEST_SINK := SavedSink
		_UpdaterDownloadInProgress := SavedSelfUpdate.InProgress
		_UpdaterDownloadWorker := SavedSelfUpdate.Worker
		_UpdaterDownloadRequest := SavedSelfUpdate.Request
		_UpdaterSelfUpdateEpoch := SavedSelfUpdate.Epoch
		if SavedSelfUpdate.RecoveryTargetSet
			_UpdaterRecoveryPublishTarget := SavedSelfUpdate.RecoveryTarget
		else
			_UpdaterRecoveryPublishTarget := unset
		_UpdaterSwapOwner := SavedSelfUpdate.SwapOwner
		_UpdaterExitIntent := SavedSelfUpdate.ExitIntent
		_UpdaterExitInvocation := SavedSelfUpdate.ExitInvocation
		_UpdaterTest_RestoreRequestState(SavedRequestState)
	}
}

Test("Updater AHK-33: download START precedes cancellable owner (updater-download-logger-order)",
	_UpdaterTest_DownloadStartPrecedesCancellableOwner)
