; tests/unit/modules/updater/test_updater_install_deadlines.ahk

; ==============================================================================
; MODULE: Updater Install Policy and Deadlines
; DESCRIPTION:
; Cross-channel install policy (AHK-047), the absolute download deadline
; (AHK-049), the release-notes script boundary, the consent prompt, and the
; native swap and reload deadline precedence.
; ==============================================================================

#Requires AutoHotkey v2.0





_UpdaterTest_RecordCrossChannelInstall(State, Release) {
	State.Installs += 1
	State.Tag := Release.Tag
	return true
}

_UpdaterTest_RecordConsentOffer(State, Release, Request) {
	State.Offers += 1
	State.Tag := Release.Tag
	return true
}

_UpdaterTest_RecordCrossChannelRebuild(State) {
	State.Rebuilds += 1
	return true
}

_UpdaterTest_ExplicitChannelTransitionUsesReleasePolicy() {
	global UPDATER_LATEST_RELEASE, UPDATER_REQUEST_ORIGIN_MANUAL
	ShouldOffer := _UpdaterTest_ResolveFunction("UpdateChannels_ShouldOffer")
	Publish := _UpdaterTest_ResolveFunction("_Updater_PublishOneClickRelease")
	Workflow := FileRead(A_ScriptDir . "\..\..\..\..\.github\workflows\ci.yml", "UTF-8")
	TagTemplate := 'tag="v0.0.0-dev.${next_n}"'
	Assert(InStr(Workflow, TagTemplate) > 0,
		"the regression must consume the exact dev tag family owned by CI")
	DevCandidate := StrReplace(
		SubStr(TagTemplate, 6, StrLen(TagTemplate) - 6), "${next_n}", "117")
	AssertEqual(true, ShouldOffer.Call(
		DevCandidate, "1.0.0", "dev", "main"),
		"an explicit stable-to-dev transition must offer the CI dev candidate")
	AssertEqual(false, ShouldOffer.Call(
		DevCandidate, "1.0.0", "main", "main"),
		"ordinary same-channel checks must retain strict semver ordering")
	AssertEqual(false, ShouldOffer.Call(
		"v1.1.0", "1.0.0", "dev", "main"),
		"a stable candidate must never satisfy a selected dev channel")
	AssertEqual(true, ShouldOffer.Call(
		"v1.1.0", "0.0.0-dev.117", "main", "dev"),
		"an explicit dev-to-stable transition must offer a stable candidate")
	AssertEqual(false, ShouldOffer.Call(
		"not-semver", "1.0.0", "dev", "main"),
		"channel migration must fail closed on malformed release metadata")

	Saved := _UpdaterTest_SaveRequestState()
	HadLatest := IsSet(UPDATER_LATEST_RELEASE)
	if HadLatest
		SavedLatest := UPDATER_LATEST_RELEASE
	try {
		_UpdaterTest_ResetRequestState()
		Request := _Updater_NewRequestContext(
			UPDATER_REQUEST_ORIGIN_MANUAL, false, "dev")
		Release := { Tag: DevCandidate, RawJson: "{}" }
		State := { Rebuilds: 0, Offers: 0, Tag: "" }
		AssertEqual(true, Publish.Call(
			Release, Request, false,
			_UpdaterTest_RecordCrossChannelRebuild.Bind(State),
			0, _UpdaterTest_RecordConsentOffer.Bind(State)),
			"the selected dev candidate must cross publication into the consent prompt")
		AssertEqual(1, State.Rebuilds,
			"candidate publication must refresh the visible updater state once")
		AssertEqual(1, State.Offers,
			"the explicit channel migration must offer the candidate exactly once")
		AssertEqual(DevCandidate, State.Tag,
			"the prompt must offer the exact CI-generated candidate")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
		if HadLatest
			UPDATER_LATEST_RELEASE := SavedLatest
		else
			UPDATER_LATEST_RELEASE := unset
	}
}
Test("Updater AHK-047: explicit channel changes override cross-channel semver ordering (updater-cross-channel-install-2026-08-28)",
	_UpdaterTest_ExplicitChannelTransitionUsesReleasePolicy)

class _UpdaterTestDeadlineWorker {
	__New(State) {
		this.State := State
	}

	terminate() {
		this.State.Terminations += 1
		return true
	}
}

_UpdaterTest_RecordDeadlineFailure(State, Message, Options) {
	State.Notices += 1
	State.Message := Message
	return true
}

_UpdaterTest_AbsoluteDownloadDeadlineOwnsCleanup() {
	global _UpdaterDownloadInProgress, _UpdaterDownloadWorker
	global _UpdaterDownloadRequest, _UpdaterDownloadArtifacts
	global _UpdaterDownloadStartedTick, _UpdaterSelfUpdateEpoch
	global _UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation
	global UPDATER_HTTP_DOWNLOAD_DEADLINE_MS
	Enforce := _UpdaterTest_ResolveFunction("_Updater_EnforceDownloadDeadline")
	Saved := {
		InProgress: _UpdaterDownloadInProgress,
		Worker: _UpdaterDownloadWorker,
		Request: _UpdaterDownloadRequest,
		Artifacts: _UpdaterDownloadArtifacts,
		StartedTick: _UpdaterDownloadStartedTick,
		Epoch: _UpdaterSelfUpdateEpoch,
		SwapOwner: _UpdaterSwapOwner,
		ExitIntent: _UpdaterExitIntent,
		ExitInvocation: _UpdaterExitInvocation
	}
	TempDir := A_Temp . "\ergopti-updater-deadline-" . A_TickCount
	DirCreate(TempDir)
	NewExe := TempDir . "\ErgoptiPlus_new.exe"
	SwapScript := TempDir . "\swap_update.ps1"
	FileAppend("partial", NewExe, "UTF-8-RAW")
	FileAppend("partial", SwapScript, "UTF-8-RAW")
	State := { Terminations: 0, Notices: 0, Message: "" }
	try {
		_UpdaterDownloadInProgress := true
		_UpdaterDownloadWorker := _UpdaterTestDeadlineWorker(State)
		_UpdaterDownloadRequest := 0
		_UpdaterDownloadArtifacts := { NewExe: NewExe, SwapScript: SwapScript }
		_UpdaterDownloadStartedTick := 100
		_UpdaterSelfUpdateEpoch := 51
		_UpdaterSwapOwner := 0
		_UpdaterExitIntent := 0
		_UpdaterExitInvocation := 0
		AssertEqual(true, Enforce.Call(
			100 + UPDATER_HTTP_DOWNLOAD_DEADLINE_MS, false,
			_UpdaterTest_RecordDeadlineFailure.Bind(State)),
			"the wall-clock boundary must terminate the exact transaction")
		AssertEqual(1, State.Terminations,
			"deadline expiry must terminate the owned process tree exactly once")
		AssertEqual(false, _UpdaterDownloadInProgress,
			"deadline expiry must release the global download owner")
		Assert(!FileExist(NewExe),
			"deadline expiry must delete the partial executable")
		Assert(!FileExist(SwapScript),
			"deadline expiry must delete the partial swap worker")
		AssertEqual(1, State.Notices,
			"deadline expiry must publish one visible failure terminal")
	} finally {
		_UpdaterDownloadInProgress := Saved.InProgress
		_UpdaterDownloadWorker := Saved.Worker
		_UpdaterDownloadRequest := Saved.Request
		_UpdaterDownloadArtifacts := Saved.Artifacts
		_UpdaterDownloadStartedTick := Saved.StartedTick
		_UpdaterSelfUpdateEpoch := Saved.Epoch
		_UpdaterSwapOwner := Saved.SwapOwner
		_UpdaterExitIntent := Saved.ExitIntent
		_UpdaterExitInvocation := Saved.ExitInvocation
		try FileDelete(NewExe)
		try FileDelete(SwapScript)
		try DirDelete(TempDir)
	}
}
Test("Updater AHK-049: absolute download deadline terminates and cleans staging (updater-absolute-download-deadline-2026-08-28)",
	_UpdaterTest_AbsoluteDownloadDeadlineOwnsCleanup)

_UpdaterTest_MarkdownPayloadCannotCloseScript() {
	Canary := "</script><script>window.auditCanary=1</script>"
	Seed := _Updater_ReleaseNotesSeed(Canary, "boundary-test")
	Assert(InStr(Seed, "<") = 0 && InStr(Seed, ">") = 0,
		"remote Markdown must not create an executable script boundary")
	Assert(RegExMatch(Seed, 'body:("(?:[^"\\]|\\.)*")', &Literal) > 0,
		"the shared notes page must receive one JSON string literal")
	AssertEqual(Canary, JsonParse(Literal[1]),
		"escaping must preserve the complete remote release body as data")
	ControlText := "before" . Chr(8) . Chr(12) . Chr(0x1F) . "after"
	AssertEqual(ControlText, JsonParse(JsonStringLiteral(ControlText, true)),
		"the shared script-string encoder must round-trip every C0 control character")
}
Test("Updater: release Markdown cannot escape its script (updater-markdown-script-boundary)",
	_UpdaterTest_MarkdownPayloadCannotCloseScript)

; A "Check for updates" click that finds a newer release used to download,
; swap and restart on it at once: the user had asked to check, never to
; install. It must stop at the consent prompt, whose Install button is the only
; place a download starts; nothing is staged before that click
; (updater-consent-2026-09-25).
_UpdaterTest_CheckStopsAtTheConsentPrompt() {
	global UPDATER_LATEST_RELEASE, UPDATER_REQUEST_ORIGIN_MANUAL
	Saved := _UpdaterTest_SaveRequestState()
	HadLatest := IsSet(UPDATER_LATEST_RELEASE)
	if HadLatest
		SavedLatest := UPDATER_LATEST_RELEASE
	try {
		_UpdaterTest_ResetRequestState()
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
		Release := { Tag: "v9.9.9", RawJson: "{}" }
		State := { Offers: 0, Tag: "", Request: 0 }
		Offer(Candidate, OfferRequest) {
			State.Offers += 1
			State.Tag := Candidate.Tag
			State.Request := OfferRequest
			return true
		}
		AssertEqual(true, _Updater_PublishOneClickRelease(
			Release, Request, false, (*) => true, 0, Offer),
			"a newer release found by a check must be offered")
		AssertEqual(1, State.Offers, "the check must open the consent prompt exactly once")
		AssertEqual("v9.9.9", State.Tag, "the prompt must offer the release the check found")
		Assert(State.Request == Request,
			"the prompt must stay owned by the check's request generation")
	} finally {
		_UpdaterTest_RestoreRequestState(Saved)
		if HadLatest
			UPDATER_LATEST_RELEASE := SavedLatest
		else
			UPDATER_LATEST_RELEASE := unset
	}
}
Test("Updater: a check stops at the consent prompt instead of downloading (updater-consent-2026-09-25)",
	_UpdaterTest_CheckStopsAtTheConsentPrompt)


; Native A_TickCount origins retain their full duration after a long suspension.
; Recording ports observe the actual deadline owners without launching transport,
; querying handles, arming timers, or transferring executable ownership.
_UNT64_NewObservation() {
	return { Failures: 0, Arms: 0, Cancels: 0, Notices: 0, Reloads: 0,
		Message: "", Waits: [], Process: 0, Signal: 0, CancelResult: true }
}

_UNT64_RecordReloadFailure(Seen, State, Message, Err := 0) {
	Seen.Failures += 1
	Seen.Message := Message
	return true
}

_UNT64_RecordReloadArm(Seen, State) {
	Seen.Arms += 1
	return true
}

_UNT64_RecordReload(Seen, Args*) {
	Seen.Reloads += 1
	return false
}

_UNT64_RecordCancel(Seen, Message, RebuildMenu, SurfacePausedRequest) {
	global _UpdaterDownloadInProgress, _UpdaterDownloadStartedTick
	Seen.Cancels += 1
	Seen.Message := Message
	AssertEqual(false, RebuildMenu)
	AssertEqual(false, SurfacePausedRequest)
	if Seen.CancelResult {
		_UpdaterDownloadInProgress := false
		_UpdaterDownloadStartedTick := 0
	}
	return Seen.CancelResult
}

_UNT64_RecordNotice(Seen, Message, Options) {
	Seen.Notices += 1
	return true
}

_UNT64_RecordSwapWait(Seen, Owner, Name) {
	Seen.Waits.Push(Name)
	if Seen.Process == -2 and Name == "ProcessHandle"
		return Seen.Waits.Length == 1 ? 0 : 1
	return Name == "ProcessHandle" ? Seen.Process : Seen.Signal
}

_UNT64_RecordSwapFailure(Seen, TransactionId, Message) {
	Seen.Failures += 1
	Seen.Message := Message
	return true
}

_UNT64_RecordSwapArm(Seen, TransactionId) {
	Seen.Arms += 1
	return true
}

_UNT64_RefuseCommit(Seen, Owner, Name) {
	AssertEqual("CommitHandle", Name)
	return false
}

_UNT64_DeadlineObservation(Kind, Elapsed, ExpectedExpired, NativeNow := false) {
	global _UpdaterChannelReloadTransition, _UpdaterAsyncRequests
	global _UpdaterActiveSendLeaseCount, _UpdaterActiveAsyncTerminalDeliveryCount
	global _UpdaterDownloadInProgress, _UpdaterDownloadStartedTick, _UpdaterBalloon
	global _UpdaterSwapOwner, UPDATER_HTTP_DOWNLOAD_DEADLINE_MS
	global UPDATER_SWAP_READY_TIMEOUT_MS, UPDATER_SWAP_ACK_TIMEOUT_MS
	Saved := { Transition: _UpdaterChannelReloadTransition,
		Requests: _UpdaterAsyncRequests, Leases: _UpdaterActiveSendLeaseCount,
		Terminals: _UpdaterActiveAsyncTerminalDeliveryCount,
		Download: _UpdaterDownloadInProgress, Started: _UpdaterDownloadStartedTick,
		Balloon: _UpdaterBalloon, Swap: _UpdaterSwapOwner }
	Seen := _UNT64_NewObservation()
	Origin := A_TickCount
	NowTick := NativeNow ? unset : Origin + Elapsed
	try {
		switch Kind {
			case "reload":
				_UpdaterAsyncRequests := Map()
				_UpdaterActiveSendLeaseCount := 0
				_UpdaterActiveAsyncTerminalDeliveryCount := 1
				State := { Active: true, Scheduled: true, ArmEpoch: 1,
					StartTick: Origin, TimeoutMs: 10000, Continuation: 0,
					ReloadFn: _UNT64_RecordReload.Bind(Seen) }
				_UpdaterChannelReloadTransition := State
				AssertEqual(false, _Updater_RunDeferredChannelReload(State, 1,
					NowTick?, _UNT64_RecordReloadFailure.Bind(Seen),
					_UNT64_RecordReloadArm.Bind(Seen)))
				AssertEqual(ExpectedExpired, Seen.Failures)
				AssertEqual(!ExpectedExpired, Seen.Arms)
				AssertEqual(0, Seen.Reloads)
				AssertEqual(!ExpectedExpired, State.Active)
				if ExpectedExpired {
					AssertEqual("channel reload quiescence timed out", Seen.Message)
					AssertEqual(false, _Updater_RunDeferredChannelReload(State, 1,
						Origin + Elapsed, _UNT64_RecordReloadFailure.Bind(Seen),
						_UNT64_RecordReloadArm.Bind(Seen)))
					AssertEqual(1, Seen.Failures, "retired owner must not fail twice")
				}
			case "download":
				_UpdaterDownloadInProgress := true
				_UpdaterDownloadStartedTick := Origin
				_UpdaterBalloon := { Owned: false, ShowPending: false }
				AssertEqual(ExpectedExpired, _Updater_EnforceDownloadDeadline(
					NowTick?, false, _UNT64_RecordNotice.Bind(Seen),
					_UNT64_RecordCancel.Bind(Seen)))
				AssertEqual(ExpectedExpired, Seen.Cancels)
				AssertEqual(ExpectedExpired, Seen.Notices)
				AssertEqual(!ExpectedExpired, _UpdaterDownloadInProgress)
				if ExpectedExpired {
					AssertEqual(true, InStr(Seen.Message, "wall-clock deadline") > 0)
					AssertEqual(false, _Updater_EnforceDownloadDeadline(
						Origin + Elapsed, false, _UNT64_RecordNotice.Bind(Seen),
						_UNT64_RecordCancel.Bind(Seen)))
					AssertEqual(1, Seen.Notices, "retired download must not notify twice")
				}
			default:
				Owner := _Updater_NewSwapOwner(910064)
				Assert(Owner["PhaseStartedTick"] >= Origin,
					"the real zero-handle producer must sample the native clock")
				Origin := Owner["PhaseStartedTick"]
				NowTick := NativeNow ? unset : Origin + Elapsed
				Owner["Phase"] := Kind == "ready" ? "AwaitReady" : "AwaitAck"
				_UpdaterSwapOwner := Owner
				_Updater_PollSwapHandshake(910064, NowTick?,
					_UNT64_RecordSwapWait.Bind(Seen), _UNT64_RecordSwapFailure.Bind(Seen),
					_UNT64_RecordSwapArm.Bind(Seen), _UNT64_RefuseCommit.Bind(Seen))
				AssertEqual(ExpectedExpired, Seen.Failures)
				AssertEqual(!ExpectedExpired, Seen.Arms)
				AssertEqual(2, Seen.Waits.Length)
				AssertEqual("ProcessHandle", Seen.Waits[1])
				AssertEqual(Kind == "ready" ? "ReadyHandle" : "AckHandle", Seen.Waits[2])
				if ExpectedExpired
					AssertEqual(Kind == "ready" ? "the Ready event timed out"
						: "the Ack event timed out", Seen.Message)
		}
	} finally {
		_UpdaterChannelReloadTransition := Saved.Transition
		_UpdaterAsyncRequests := Saved.Requests
		_UpdaterActiveSendLeaseCount := Saved.Leases
		_UpdaterActiveAsyncTerminalDeliveryCount := Saved.Terminals
		_UpdaterDownloadInProgress := Saved.Download
		_UpdaterDownloadStartedTick := Saved.Started
		_UpdaterBalloon := Saved.Balloon
		_UpdaterSwapOwner := Saved.Swap
	}
}

for Kind in ["reload", "download", "ready", "ack"] {
	Test("updater-native64: " . Kind . " default native clock keeps fresh work pending",
		_UNT64_DeadlineObservation.Bind(Kind, 0, false, true))
	Budget := Kind == "download" ? 1200000 : 10000
	for Vector in [[0, false], [Budget - 1, false], [Budget, true],
		[Budget + 1, true], [0x100000000, true],
		[0x100000000 + Budget - 1, true], [0x200000000, true]]
		Test("updater-native64: " . Kind . " elapsed=" . Vector[1],
			_UNT64_DeadlineObservation.Bind(Kind, Vector[1], Vector[2]))
}

_UNT64_SwapSignalPrecedence(Kind, ProcessState, SignalState, ExpectedMessage) {
	global _UpdaterSwapOwner
	Saved := _UpdaterSwapOwner
	Seen := _UNT64_NewObservation()
	try {
		Owner := _Updater_NewSwapOwner(910065)
		Owner["Phase"] := Kind == "ready" ? "AwaitReady" : "AwaitAck"
		_UpdaterSwapOwner := Owner
		Seen.Process := ProcessState
		Seen.Signal := SignalState
		_Updater_PollSwapHandshake(910065, Owner["PhaseStartedTick"] + 0x200000000,
			_UNT64_RecordSwapWait.Bind(Seen), _UNT64_RecordSwapFailure.Bind(Seen),
			_UNT64_RecordSwapArm.Bind(Seen), _UNT64_RefuseCommit.Bind(Seen))
		AssertEqual(1, Seen.Failures)
		AssertEqual(0, Seen.Arms)
		AssertEqual(ExpectedMessage, Seen.Message)
	} finally {
		_UpdaterSwapOwner := Saved
	}
}

for Kind in ["ready", "ack"] {
	Test("updater-native64: " . Kind . " process refusal precedes elapsed budget",
		_UNT64_SwapSignalPrecedence.Bind(Kind, -1, 0,
			"the exact swap-worker process handle could not be queried"))
	Test("updater-native64: " . Kind . " signal refusal precedes elapsed budget",
		_UNT64_SwapSignalPrecedence.Bind(Kind, 0, -1,
			Kind == "ready" ? "the Ready event could not be queried"
				: "the Ack event could not be queried"))
}
Test("updater-native64: READY signal takes precedence over an elapsed budget",
	_UNT64_SwapSignalPrecedence.Bind("ready", 0, 1,
		"the Commit event could not be signaled"))
Test("updater-native64: ACK signal reaches the post-ack process check before timeout",
	_UNT64_SwapSignalPrecedence.Bind("ack", -2, 1,
		"the swap worker died after Ack"))

_UNT64_DownloadCancellationRefusal() {
	global _UpdaterDownloadInProgress, _UpdaterDownloadStartedTick, _UpdaterBalloon
	Saved := { Active: _UpdaterDownloadInProgress, Tick: _UpdaterDownloadStartedTick,
		Balloon: _UpdaterBalloon }
	Seen := _UNT64_NewObservation()
	try {
		_UpdaterDownloadInProgress := true
		_UpdaterDownloadStartedTick := A_TickCount
		_UpdaterBalloon := { Owned: false, ShowPending: false }
		Seen.CancelResult := false
		AssertEqual(false, _Updater_EnforceDownloadDeadline(
			_UpdaterDownloadStartedTick + 0x200000000, false,
			_UNT64_RecordNotice.Bind(Seen), _UNT64_RecordCancel.Bind(Seen)))
		AssertEqual(1, Seen.Cancels)
		AssertEqual(0, Seen.Notices, "a refused cancellation cannot publish success")
		AssertEqual(true, _UpdaterDownloadInProgress)
	} finally {
		_UpdaterDownloadInProgress := Saved.Active
		_UpdaterDownloadStartedTick := Saved.Tick
		_UpdaterBalloon := Saved.Balloon
	}
}
Test("updater-native64: cancellation refusal preserves the active download",
	_UNT64_DownloadCancellationRefusal)

_UNT64_QuiescentReloadPrecedesTimeout() {
	global _UpdaterChannelReloadTransition, _UpdaterAsyncRequests
	global _UpdaterActiveSendLeaseCount, _UpdaterActiveAsyncTerminalDeliveryCount
	Saved := { Transition: _UpdaterChannelReloadTransition, Requests: _UpdaterAsyncRequests,
		Leases: _UpdaterActiveSendLeaseCount, Terminals: _UpdaterActiveAsyncTerminalDeliveryCount }
	Seen := _UNT64_NewObservation()
	try {
		_UpdaterAsyncRequests := Map()
		_UpdaterActiveSendLeaseCount := 0
		_UpdaterActiveAsyncTerminalDeliveryCount := 0
		State := { Active: true, Scheduled: true, ArmEpoch: 1, StartTick: A_TickCount,
			TimeoutMs: 10000, Continuation: 0, ConfigBundle: 0,
			ReloadFn: _UNT64_RecordReload.Bind(Seen) }
		_UpdaterChannelReloadTransition := State
		AssertEqual(false, _Updater_RunDeferredChannelReload(State, 1,
			State.StartTick + 0x200000000, _UNT64_RecordReloadFailure.Bind(Seen),
			_UNT64_RecordReloadArm.Bind(Seen)))
		AssertEqual(1, Seen.Reloads, "quiescence authorizes the real reload branch")
		AssertEqual("Reload returned false", Seen.Message)
		AssertEqual(0, Seen.Arms)
		AssertEqual(false, State.Active)
	} finally {
		_UpdaterChannelReloadTransition := Saved.Transition
		_UpdaterAsyncRequests := Saved.Requests
		_UpdaterActiveSendLeaseCount := Saved.Leases
		_UpdaterActiveAsyncTerminalDeliveryCount := Saved.Terminals
	}
}
Test("updater-native64: quiescence precedes timeout and respects reload refusal",
	_UNT64_QuiescentReloadPrecedesTimeout)
