; tests/unit/test_updater_managed_failure.ahk
#Requires AutoHotkey v2.0

_UMF_WithContract(Callback) {
	global _UpdaterManagedFailureContract, _SharedDir
	Saved := _UpdaterManagedFailureContract
	try {
		_UpdaterManagedFailureContract := ManagedNetworkFailureContract(
			JsonParse(FileRead(_SharedDir . "\modules\network\managed_network.json", "UTF-8")))
		Callback.Call(_UpdaterManagedFailureContract)
	} finally {
		_UpdaterManagedFailureContract := Saved
	}
}

_UMF_IndependentEnvelopes(Contract) {
	Cases := [
		['{"schema_version":1,"state":"failed","operation":"download","reason":"download","receipt":{"backend":"dotnet","stage":"tls","failure_provenance":"verified","tls_verification":"enforced","tls_status":"untrusted_certificate"}}', "certificate"],
		['{"schema_version":1,"state":"failed","operation":"download","reason":"download","receipt":{"backend":"dotnet","stage":"tls","failure_provenance":"unknown","tls_verification":"enforced"}}', "unknown"],
		['{"schema_version":1,"state":"failed","operation":"download","reason":"download","receipt":{"backend":"dotnet","stage":"http","failure_provenance":"verified","http_status":407,"http_response_source":"unavailable"}}', "unknown"],
		['{"schema_version":1,"state":"failed","operation":"download","reason":"download","receipt":{"backend":"dotnet","stage":"file_write","failure_provenance":"verified","native_errno_domain":"win32","native_errno":"112"}}', "disk"],
		['{"schema_version":1,"state":"failed","operation":"download","reason":"download","receipt":{"backend":"dotnet","stage":"connect","failure_provenance":"verified","native_errno_domain":"win32","native_errno":"112"}}', "unknown"],
		['{"schema_version":1,"state":"failed","operation":"download","reason":"download","receipt":{"backend":"dotnet","stage":"file_create","failure_provenance":"verified","native_errno_domain":"win32","native_errno":"5"}}', "permission"]
	]
	for ProbeCase in Cases {
		Failure := _Updater_ParseStagingFailure(ProbeCase[1])
		Assert(Failure["valid"], "independent native envelope must be admitted")
		Report := Contract.Classify(Failure["receipt"], Map())
		AssertEqual(ProbeCase[2], Report["cause"], "native operation and provenance must remain distinct")
	}
	Refused := [
		'ERR:certificate disk full permission denied SHA-256 mismatch',
		'{"schema_version":1,"state":"FAILED","operation":"download","reason":"download","receipt":{}}',
		'{"schema_version":1,"state":{},"operation":"download","reason":"download","receipt":{}}',
		'{"schema_version":1,"state":"failed","operation":"download","reason":"verify","receipt":{"private_url":"https://secret.invalid/token"}}',
		'{"schema_version":1,"state":"failed","operation":"download","reason":"download","receipt":{"backend":"dotnet","stage":"tls","failure_provenance":"verified","tls_status":[]}}',
		'{"schema_version":1,"state":"failed","operation":"download","reason":"download","receipt":{},"message":"private"}',
		'{"schema_version":1,"state":"failed","operation":"download","reason":"download","receipt":{},"native_cleanup_debt":1}',
		'{"schema_version":1,"state":"failed","operation":"download","reason":"download","receipt":{},"native_cleanup_debt":"true"}',
		'{"schema_version":1,"state":"failed","operation":"download","reason":"download","receipt":{},"native_cleanup_debt":null}',
		'{"schema_version":1,"state":"failed","operation":"download","reason":"download","receipt":{},"native_cleanup_debt":[],"cleanup_debt":[]}',
		'{"schema_version":1,"state":"failed","operation":"download","reason":"download","receipt":{},"native_cleanup_debt":false,"native_cleanup_debt":true}'
	]
	for Raw in Refused {
		Failure := _Updater_ParseStagingFailure(Raw)
		Assert(!Failure["valid"], "malformed or text-only output must be refused")
		AssertEqual("unknown", Contract.Classify(Failure["receipt"], Map())["cause"],
			"refusal must not manufacture a network cause")
	}
	Verified := _Updater_ParseStagingFailure(
		'{"schema_version":1,"state":"failed","operation":"download","reason":"verify","receipt":{}}')
	AssertEqual("verify", Verified["reason"], "logical verification stays separate from native receipt stage")
	NativeDebt := _Updater_ParseStagingFailure(
		'{"schema_version":1,"state":"failed","operation":"download","reason":"download","receipt":{"backend":"dotnet","stage":"http","failure_provenance":"verified","http_status":407,"http_response_source":"unavailable"},"native_cleanup_debt":true}')
	Assert(NativeDebt["valid"] && NativeDebt["native_cleanup_debt"], "private resolver debt survives completion")
	AssertEqual(407, NativeDebt["receipt"]["http_status"], "private resolver debt cannot replace the primary receipt")
	AssertEqual("unknown", Contract.Classify(NativeDebt["receipt"], Map())["cause"], "native cleanup cannot invent proxy or CONNECT provenance")
	NoDebt := _Updater_ParseStagingFailure(
		'{"schema_version":1,"state":"failed","operation":"download","reason":"download","receipt":{},"native_cleanup_debt":false,"cleanup_debt":[]}')
	Assert(NoDebt["valid"] && !NoDebt["native_cleanup_debt"], "explicit closed flag remains false")
	Debt := _Updater_ParseStagingFailure(
		'{"schema_version":1,"state":"failed","operation":"download","reason":"download","receipt":{"backend":"dotnet","stage":"http","failure_provenance":"verified","http_status":407,"http_response_source":"unavailable"},"cleanup_debt":[{"resource":"output","receipt":{"backend":"dotnet","stage":"file_write","failure_provenance":"unknown"}}]}')
	Assert(Debt["valid"] && Debt["cleanup_debt"].Length == 1, "bounded cleanup debt must survive process completion")
	AssertEqual(407, Debt["receipt"]["http_status"], "cleanup debt cannot replace primary failure")
	AssertEqual("unknown", Contract.Classify(Debt["receipt"], Map())["cause"],
		"deferred cleanup cannot manufacture proxy provenance")
}

Test("Updater managed failure: independent bounded native receipts (updater-managed-failure)",
	(*) => _UMF_WithContract(_UMF_IndependentEnvelopes))

_UMF_ReceiptObserver() {
	global _UpdaterInstallObserver
	Saved := _UpdaterInstallObserver
	Calls := []
	Receipt := Map("backend", "dotnet", "stage", "file_write", "native_errno", "112")
	try {
		_UpdaterInstallObserver := (Phase, Reason, NativeReceipt) => Calls.Push(NativeReceipt)
		Assert(_Updater_NotifyInstallPhase("failed", "changelog_window.install_error_download", Receipt))
		AssertEqual(1, Calls.Length, "one terminal observer owns one native receipt")
		Assert(Calls[1] == Receipt, "the actual typed receipt must reach Versions unchanged")
		AssertEqual(0, _UpdaterInstallObserver, "terminal observation retires the old phase observer")
	} finally {
		_UpdaterInstallObserver := Saved
	}
}
Test("Updater managed failure: actual receipt survives native observer (updater-managed-failure)",
	_UMF_ReceiptObserver)

_UMF_ObserverIdentitySurvivesNewRequest() {
	global _UpdaterInstallObserver
	Saved := _UpdaterInstallObserver
	Calls := []
	OldObserver := (Phase, Reason, Receipt) => Calls.Push("old")
	NewObserver := (Phase, Reason, Receipt) => Calls.Push("new")
	try {
		_UpdaterInstallObserver := NewObserver
		Assert(_Updater_NotifyInstallPhase("failed", "changelog_window.install_error_download",
			Map("backend", "dotnet", "stage", "connect"), OldObserver))
		AssertEqual(1, Calls.Length, "only the captured failed request observer is notified")
		AssertEqual("old", Calls[1], "old completion cannot borrow a newer observer")
		Assert(_UpdaterInstallObserver == NewObserver, "old terminal cannot clear newer Versions operation")
	} finally {
		_UpdaterInstallObserver := Saved
	}
}
Test("Updater managed failure: exact observer identity survives retirement (updater-managed-failure)",
	_UMF_ObserverIdentitySurvivesNewRequest)

_UMF_StaleCompletionCannotPublish() {
	global _UpdaterManagedFailurePresenter, _UpdaterManagedFailureOwner
	global _UpdaterDownloadInProgress, _UpdaterSelfUpdateEpoch, _UpdaterDownloadWorker
	Saved := [_UpdaterManagedFailurePresenter, _UpdaterManagedFailureOwner,
		_UpdaterDownloadInProgress, _UpdaterSelfUpdateEpoch, _UpdaterDownloadWorker]
	Calls := []
	Worker := { Token: "new-owned-worker" }
	try {
		_UpdaterManagedFailurePresenter := (Failure, Owner) => Calls.Push(Failure)
		_UpdaterManagedFailureOwner := 0
		_UpdaterDownloadInProgress := true
		_UpdaterSelfUpdateEpoch := 8124
		_UpdaterDownloadWorker := Worker
		_Updater_PollDownloadAsync(1,
			'{"schema_version":1,"state":"failed","operation":"download","reason":"download","receipt":{"backend":"dotnet","stage":"tls","failure_provenance":"verified","tls_verification":"enforced","tls_status":"untrusted_certificate"}}',
			"", "old-swap", "old-new", "old-current", "v1.0.0", 8123)
		AssertEqual(0, Calls.Length, "old typed receipt cannot cross the existing staging epoch fence")
		Assert(_UpdaterDownloadWorker == Worker, "stale completion cannot retire a newer exact worker")
		AssertEqual(0, _UpdaterManagedFailureOwner, "stale receipt cannot publish a terminal retry owner")
	} finally {
		_UpdaterManagedFailurePresenter := Saved[1]
		_UpdaterManagedFailureOwner := Saved[2]
		_UpdaterDownloadInProgress := Saved[3]
		_UpdaterSelfUpdateEpoch := Saved[4]
		_UpdaterDownloadWorker := Saved[5]
	}
}
Test("Updater managed failure: typed stale completion stays inert (updater-managed-failure)",
	_UMF_StaleCompletionCannotPublish)

_UMF_TerminalOwnerFences() {
	global _UpdaterManagedFailureOwner, _UpdaterSelfUpdateEpoch
	global _UpdaterDownloadInProgress, _UpdaterDownloadWorker, _UpdaterSwapOwner
	global _UpdaterRecoveryPublishTarget, _UpdaterPauseGeneration, _UpdaterChannelEpoch
	global UPDATER_REQUEST_ORIGIN_MANUAL
	Saved := [_UpdaterManagedFailureOwner, _UpdaterSelfUpdateEpoch,
		_UpdaterDownloadInProgress, _UpdaterDownloadWorker, _UpdaterSwapOwner,
		_UpdaterRecoveryPublishTarget, _UpdaterPauseGeneration, _UpdaterChannelEpoch]
	try {
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
		_UpdaterSelfUpdateEpoch := 8123
		_UpdaterDownloadInProgress := false
		_UpdaterDownloadWorker := 0
		_UpdaterSwapOwner := 0
		_UpdaterRecoveryPublishTarget := ""
		Owner := _Updater_NewManagedFailureOwner({RawJson: "{}", Tag: "v1.0.0"},
			Request, "https://github.com/adrienm7/ergopti/releases/download/v1.0.0/ErgoptiPlus.exe",
			"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", 8123)
		Owner["terminal"] := true
		_UpdaterManagedFailureOwner := Owner
		Assert(_Updater_ManagedFailureOwnerIsCurrent(Owner), "positive control: exact current terminal owner")
		Release := {RawJson: "{}", Tag: "v1.0.0"}
		Assert(_Updater_GetManagedFailureOwnerFor(Request, Release) == Owner,
			"Versions can bind its exact private request and original release")
		DifferentRequest := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
		AssertEqual(0, _Updater_GetManagedFailureOwnerFor(DifferentRequest, Release),
			"matching release and generation cannot borrow a different request object")
		AssertEqual(0, _Updater_GetManagedFailureOwnerFor(Request, {RawJson: "{ }", Tag: "v1.0.0"}),
			"matching tag cannot borrow different original release bytes")
		Assert(!_Updater_RetryManagedFailure(Owner), "missing authenticated asset must refuse retry before download")
		Assert(_Updater_ManagedFailureOwnerIsCurrent(Owner), "asset refusal cannot borrow or retire a different owner")
		_UpdaterSelfUpdateEpoch += 1
		Assert(!_Updater_ManagedFailureOwnerIsCurrent(Owner), "new same-tag staging epoch must refuse old dialog")
		_UpdaterSelfUpdateEpoch := 8123
		_UpdaterDownloadInProgress := true
		Assert(!_Updater_ManagedFailureOwnerIsCurrent(Owner), "active download must refuse retry")
		_UpdaterDownloadInProgress := false
		_UpdaterSwapOwner := Map("Id", 1)
		Assert(!_Updater_ManagedFailureOwnerIsCurrent(Owner), "active swap must refuse retry")
		_UpdaterSwapOwner := 0
		_UpdaterRecoveryPublishTarget := "owned-recovery"
		Assert(!_Updater_ManagedFailureOwnerIsCurrent(Owner), "active recovery must refuse retry")
		_UpdaterRecoveryPublishTarget := ""
		_UpdaterPauseGeneration += 1
		Assert(!_Updater_ManagedFailureOwnerIsCurrent(Owner), "pause and resume cannot revive old retry consent")
		_UpdaterPauseGeneration := Saved[7]
		_UpdaterChannelEpoch += 1
		Assert(!_Updater_ManagedFailureOwnerIsCurrent(Owner), "channel round trip must refuse old terminal owner")
		_UpdaterChannelEpoch := Saved[8]
		Owner["retired"] := true
		Assert(!_Updater_ManagedFailureOwnerIsCurrent(Owner), "retired native owner must stay inert")
	} finally {
		_UpdaterManagedFailureOwner := Saved[1]
		_UpdaterSelfUpdateEpoch := Saved[2]
		_UpdaterDownloadInProgress := Saved[3]
		_UpdaterDownloadWorker := Saved[4]
		_UpdaterSwapOwner := Saved[5]
		_UpdaterRecoveryPublishTarget := Saved[6]
		_UpdaterPauseGeneration := Saved[7]
		_UpdaterChannelEpoch := Saved[8]
	}
}
Test("Updater managed failure: exact owner and lifecycle retry fences (updater-managed-failure)",
	_UMF_TerminalOwnerFences)

_UMF_ActualOwnedFileReceipt() {
	global _VendorDir, _DriverDir
	Observed := []
	Handle := 0
	try {
		Handle := ShellRunner_SpawnTreeOwned(_Updater_PowerShellPath(),
			["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
				_DriverDir . "\tests\fixtures\updater_download_receipts.ps1", "-HelperPath",
				_VendorDir . "\ergopti_updater_download.ps1"],
			(Code, Out, Err) => Observed.Push(Map("exit", Code, "stdout", Out, "stderr", Err)))
		Assert(Handle.start(), "native filesystem receipt fixture must actually start")
		Started := A_TickCount
		while Observed.Length == 0 && !TickExpired64(Started, 10000) {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Observed.Length, "exact native fixture must settle within deadline")
		AssertEqual(0, Observed[1]["exit"], "actual file denial and independent receipt controls must pass")
		AssertEqual("", Observed[1]["stderr"], "native errors cannot escape through stderr")
		AssertEqual("UPDATER_RECEIPT_CONTROLS:20", Observed[1]["stdout"],
			"all declared native/type controls must execute")
	} finally {
		if IsObject(Handle)
			Assert(Handle.terminate(), "private fixture tree must physically retire")
	}
}
Test("Updater managed failure: actual owned filesystem refusal (updater-managed-failure)",
	_UMF_ActualOwnedFileReceipt)

_UMF_LateReadyCannotBeatMonitor() {
	global _UpdaterDownloadInProgress, _UpdaterDownloadStartedTick, _UpdaterSelfUpdateEpoch
	global _UpdaterDownloadWorker, _UpdaterDownloadRequest, _UpdaterDownloadArtifacts
	global _UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation
	global _UpdaterInstallObserver, _UpdaterManagedFailureOwner, UPDATER_HTTP_DOWNLOAD_DEADLINE_MS
	Saved := [_UpdaterDownloadInProgress, _UpdaterDownloadStartedTick, _UpdaterSelfUpdateEpoch,
		_UpdaterDownloadWorker, _UpdaterDownloadRequest, _UpdaterDownloadArtifacts,
		_UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation,
		_UpdaterInstallObserver, _UpdaterManagedFailureOwner]
	State := { Terminations: 0, Notices: 0, Message: "" }
	Phases := []
	try {
		_UpdaterDownloadInProgress := true
		_UpdaterDownloadStartedTick := 100
		_UpdaterSelfUpdateEpoch := 8123
		; This unit worker represents the already completed private Job callback;
		; real tree quiescence remains the independent ShellRunner native gate.
		_UpdaterDownloadWorker := _UpdaterTestDeadlineWorker(State)
		_UpdaterDownloadRequest := 0
		_UpdaterDownloadArtifacts := 0
		_UpdaterSwapOwner := 0
		_UpdaterExitIntent := 0
		_UpdaterExitInvocation := 0
		_UpdaterManagedFailureOwner := 0
		_UpdaterInstallObserver := (Phase, Reason) => Phases.Push(Phase)
		_Updater_PollDownloadAsync(0, "READY", "", "", "", "", "v1.0.0", 8123,
			0, 100 + UPDATER_HTTP_DOWNLOAD_DEADLINE_MS + 1,
			_UpdaterTest_RecordDeadlineFailure.Bind(State))
		AssertEqual(1, State.Terminations, "late READY must retain exact worker until deadline cancellation")
		AssertEqual(false, _UpdaterDownloadInProgress, "original expired transaction must retire")
		AssertEqual(1, Phases.Length, "late READY has one failed phase, no installing/restarting")
		AssertEqual("failed", Phases[1])
		AssertEqual(0, _UpdaterSwapOwner, "late READY cannot dispatch a swap before the next monitor tick")
		AssertEqual(1, State.Notices, "original deadline remains the visible primary terminal")
		AssertEqual(0, _UpdaterManagedFailureOwner, "expired READY cannot create retry consent")
	} finally {
		_UpdaterDownloadInProgress := Saved[1]
		_UpdaterDownloadStartedTick := Saved[2]
		_UpdaterSelfUpdateEpoch := Saved[3]
		_UpdaterDownloadWorker := Saved[4]
		_UpdaterDownloadRequest := Saved[5]
		_UpdaterDownloadArtifacts := Saved[6]
		_UpdaterSwapOwner := Saved[7]
		_UpdaterExitIntent := Saved[8]
		_UpdaterExitInvocation := Saved[9]
		_UpdaterInstallObserver := Saved[10]
		_UpdaterManagedFailureOwner := Saved[11]
	}
}
Test("Updater managed failure: late READY cannot beat monitor deadline (updater-managed-failure)",
	_UMF_LateReadyCannotBeatMonitor)

_UMF_RetryReservationCannotRetireSuccessor() {
	global _UpdaterManagedFailureOwner, _UpdaterSelfUpdateEpoch, _UpdaterDownloadInProgress
	global _UpdaterDownloadWorker, _UpdaterSwapOwner, _UpdaterRecoveryPublishTarget
	global UPDATER_REQUEST_ORIGIN_MANUAL
	Saved := [_UpdaterManagedFailureOwner, _UpdaterSelfUpdateEpoch, _UpdaterDownloadInProgress,
		_UpdaterDownloadWorker, _UpdaterSwapOwner, _UpdaterRecoveryPublishTarget]
	try {
		_UpdaterSelfUpdateEpoch := 8123
		_UpdaterDownloadInProgress := false
		_UpdaterDownloadWorker := 0
		_UpdaterSwapOwner := 0
		_UpdaterRecoveryPublishTarget := ""
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
		Old := _Updater_NewManagedFailureOwner({RawJson: "{}", Tag: "v1.0.0"},
			Request, "owned-url", "owned-digest", 8123)
		Old["terminal"] := true
		_UpdaterManagedFailureOwner := Old
		Assert(_Updater_ManagedFailureOwnerIsCurrent(Old), "positive preliminary retry validation")
		; Independent race: another request settles after preliminary validation.
		_UpdaterSelfUpdateEpoch := 8124
		Successor := _Updater_NewManagedFailureOwner({RawJson: "{}", Tag: "v1.0.0"},
			_Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false), "other-url", "other-digest", 8124)
		Successor["terminal"] := true
		_UpdaterManagedFailureOwner := Successor
		Outcome := _Updater_TryReserveDownloadTransaction(Request, false, Old)
		Assert(Outcome.RetryStale && !Outcome.Reserved, "Critical reservation must refuse replaced owner")
		Assert(_UpdaterManagedFailureOwner == Successor && !Successor["retired"],
			"old retry cannot retire the newer terminal owner")
		AssertEqual(8124, _UpdaterSelfUpdateEpoch, "old retry cannot reserve another old-release epoch")
		Assert(!_UpdaterDownloadInProgress, "old retry cannot dispatch a download")
		Assert(!_Updater_RetireManagedFailure(Old), "exact retirement must reject foreign current owner")
		Assert(_UpdaterManagedFailureOwner == Successor)
	} finally {
		_UpdaterManagedFailureOwner := Saved[1]
		_UpdaterSelfUpdateEpoch := Saved[2]
		_UpdaterDownloadInProgress := Saved[3]
		_UpdaterDownloadWorker := Saved[4]
		_UpdaterSwapOwner := Saved[5]
		_UpdaterRecoveryPublishTarget := Saved[6]
	}
}
Test("Updater managed failure: retry reservation rejects successor ownership (updater-managed-failure)",
	_UMF_RetryReservationCannotRetireSuccessor)

_UMF_ObservedRetryRefusesBeforeObserverMutation() {
	global _UpdaterManagedFailureOwner, _UpdaterSelfUpdateEpoch, _UpdaterDownloadInProgress
	global _UpdaterDownloadWorker, _UpdaterSwapOwner, _UpdaterRecoveryPublishTarget
	global _UpdaterInstallObserver, UPDATER_REQUEST_ORIGIN_MANUAL
	Saved := [_UpdaterManagedFailureOwner, _UpdaterSelfUpdateEpoch, _UpdaterDownloadInProgress,
		_UpdaterDownloadWorker, _UpdaterSwapOwner, _UpdaterRecoveryPublishTarget, _UpdaterInstallObserver]
	try {
		_UpdaterSelfUpdateEpoch := 8123
		_UpdaterDownloadInProgress := false
		_UpdaterDownloadWorker := 0
		_UpdaterSwapOwner := 0
		_UpdaterRecoveryPublishTarget := ""
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
		Release := {RawJson: "{}", Tag: "v1.0.0"}
		Owner := _Updater_NewManagedFailureOwner(Release, Request, "owned-url", "owned-digest", 8123)
		Owner["terminal"] := true
		_UpdaterManagedFailureOwner := Owner
		OldObserver := (*) => 0
		NewObserver := (*) => 0
		_UpdaterInstallObserver := OldObserver
		Assert(_Updater_ManagedFailureOwnerIsCurrent(Owner), "positive original terminal owner")
		OtherRequest := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
		Assert(!_Updater_StartObservedInstall(Release, NewObserver, OtherRequest, Owner),
			"another request cannot borrow the failed staging intent")
		AssertEqual(ObjPtr(OldObserver), ObjPtr(_UpdaterInstallObserver), "foreign request must not replace the observer")
		Assert(!_Updater_StartObservedInstall({RawJson: "{ }", Tag: Release.Tag}, NewObserver, Request, Owner),
			"same-tag different release bytes cannot borrow retry consent")
		AssertEqual(ObjPtr(OldObserver), ObjPtr(_UpdaterInstallObserver), "foreign release must not replace the observer")
		Successor := _Updater_NewManagedFailureOwner(Release, Request, "owned-url", "owned-digest", 8123)
		Successor["terminal"] := true
		_UpdaterManagedFailureOwner := Successor
		Assert(!_Updater_StartObservedInstall(Release, NewObserver, Request, Owner),
			"an old exact intent cannot enter through a current same-tag successor")
		AssertEqual(ObjPtr(OldObserver), ObjPtr(_UpdaterInstallObserver), "old intent must preserve the current observer")
		Assert(_UpdaterManagedFailureOwner == Successor && !Successor["retired"], "refusal must not retire its successor")
		Assert(!_UpdaterDownloadInProgress && !IsObject(_UpdaterDownloadWorker), "refused observed retry cannot acquire native work")
		AssertEqual(8123, _UpdaterSelfUpdateEpoch, "refused observed retry cannot reserve a newer transaction")
	} finally {
		_UpdaterManagedFailureOwner := Saved[1]
		_UpdaterSelfUpdateEpoch := Saved[2]
		_UpdaterDownloadInProgress := Saved[3]
		_UpdaterDownloadWorker := Saved[4]
		_UpdaterSwapOwner := Saved[5]
		_UpdaterRecoveryPublishTarget := Saved[6]
		_UpdaterInstallObserver := Saved[7]
	}
}
Test("Updater managed failure: observed retry refuses foreign request release and terminal before effects",
	_UMF_ObservedRetryRefusesBeforeObserverMutation)

; This getter is test-only. Production retry retains an ordinary plain release snapshot.
_UMF_ObserverRaceReadRelease(State, This) {
	if !State["queued"] {
		State["queued"] := true
		State["getter_critical"] := A_IsCritical
		SetTimer(State["timer"], -1)
		Sleep(25)
		State["fired_in_getter"] := State["fired"]
	}
	return "{}"
}
_UMF_ObserverRaceSuccessor(State) {
	global _UpdaterManagedFailureOwner, _UpdaterSelfUpdateEpoch, _UpdaterInstallObserver
	State["timer_critical"] := A_IsCritical
	State["before_successor"] := _UpdaterInstallObserver
	_UpdaterSelfUpdateEpoch := 8124
	_UpdaterManagedFailureOwner := State["successor"]
	State["successor_admission"] := _Updater_AdmitInstallObserver(State["plain_release"],
		State["new_observer"], State["request"], State["successor"])
	State["fired"] := true
}
_UMF_ObserverAdmissionDefersActualTimer() {
	global _UpdaterManagedFailureOwner, _UpdaterSelfUpdateEpoch, _UpdaterDownloadInProgress
	global _UpdaterDownloadWorker, _UpdaterSwapOwner, _UpdaterRecoveryPublishTarget
	global _UpdaterInstallObserver, _UpdaterInstallObserverEpoch, UPDATER_REQUEST_ORIGIN_MANUAL
	SavedCritical := A_IsCritical
	Saved := [_UpdaterManagedFailureOwner, _UpdaterSelfUpdateEpoch, _UpdaterDownloadInProgress,
		_UpdaterDownloadWorker, _UpdaterSwapOwner, _UpdaterRecoveryPublishTarget,
		_UpdaterInstallObserver, _UpdaterInstallObserverEpoch]
	State := Map("queued", false, "fired", false, "fired_in_getter", false)
	TimerFn := _UMF_ObserverRaceSuccessor.Bind(State)
	State["timer"] := TimerFn
	try {
		Critical("Off")
		_UpdaterSelfUpdateEpoch := 8123
		_UpdaterDownloadInProgress := false
		_UpdaterDownloadWorker := 0
		_UpdaterSwapOwner := 0
		_UpdaterRecoveryPublishTarget := ""
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, false)
		Release := {RawJson: "{}", Tag: "v1.0.0"}
		Owner := _Updater_NewManagedFailureOwner(Release, Request, "owned-url", "owned-digest", 8123)
		Owner["terminal"] := true
		_UpdaterManagedFailureOwner := Owner
		Plain := {RawJson: "{}", Tag: "v1.0.0"}
		Successor := _Updater_NewManagedFailureOwner(Plain, Request, "owned-url", "owned-digest", 8124)
		Successor["terminal"] := true
		OldObserver := (*) => 0
		NewObserver := (*) => 0
		_UpdaterInstallObserver := (*) => 0
		State["request"] := Request, State["plain_release"] := Plain
		State["successor"] := Successor, State["new_observer"] := NewObserver
		Release.DefineProp("RawJson", {get: _UMF_ObserverRaceReadRelease.Bind(State)})
		Admission := _Updater_AdmitInstallObserver(Release, OldObserver, Request, Owner)
		RestoredCritical := A_IsCritical
		Limit := A_TickCount + 2000
		while !State["fired"] && A_TickCount < Limit
			Sleep(10)
		Assert(Admission is Map, "the original exact intent must be admitted before the queued successor")
		Assert(State["queued"] && State["fired"], "the actual one-shot AHK timer must run")
		Assert(State["getter_critical"] > 0 && !State["fired_in_getter"], "a timer cannot replace owner between validation and observer publication")
		AssertEqual(0, RestoredCritical, "admission must restore the caller before public install or network work")
		AssertEqual(0, State["timer_critical"], "the successor runs after the short Critical section")
		Assert(State["before_successor"] == OldObserver, "original admission must publish before the deferred successor")
		Assert(State["successor_admission"] is Map && _UpdaterInstallObserver == NewObserver,
			"the actual successor admission must retain the final observer")
		Assert(!_Updater_RestoreInstallObserver(Admission), "an older refusal cannot erase a queued successor")
		Assert(_UpdaterManagedFailureOwner == Successor && _UpdaterInstallObserver == NewObserver,
			"old cleanup must leave exact successor owner and observer intact")
		Assert(!_UpdaterDownloadInProgress && !IsObject(_UpdaterDownloadWorker), "this admission control starts no native work")
	} finally {
		Critical("On")
		SetTimer(TimerFn, 0)
		_UpdaterManagedFailureOwner := Saved[1], _UpdaterSelfUpdateEpoch := Saved[2]
		_UpdaterDownloadInProgress := Saved[3], _UpdaterDownloadWorker := Saved[4]
		_UpdaterSwapOwner := Saved[5], _UpdaterRecoveryPublishTarget := Saved[6]
		_UpdaterInstallObserver := Saved[7], _UpdaterInstallObserverEpoch := Saved[8]
		Critical(SavedCritical)
	}
}
Test("Updater observer: actual timer cannot enter between current intent validation and publication",
	_UMF_ObserverAdmissionDefersActualTimer)

_UMF_ObserverRollbackPreservesPriorAndSameCallbackSuccessor() {
	global _UpdaterInstallObserver, _UpdaterInstallObserverEpoch
	Saved := [_UpdaterInstallObserver, _UpdaterInstallObserverEpoch]
	SavedCritical := A_IsCritical
	try {
		Prior := (*) => 0
		Shared := (*) => 0
		_UpdaterInstallObserver := Prior
		Critical(17)
		First := _Updater_AdmitInstallObserver({}, Shared, 0)
		AssertEqual(17, A_IsCritical, "admission must restore an already Critical caller")
		Assert(_Updater_RestoreInstallObserver(First), "own failed admission must restore its predecessor")
		AssertEqual(17, A_IsCritical, "rollback must restore the exact caller Critical interval")
		Assert(_UpdaterInstallObserver == Prior, "a refused install must preserve its prior observer")
		Assert(!_Updater_RestoreInstallObserver(First), "the same rollback token cannot publish twice")
		Old := _Updater_AdmitInstallObserver({}, Shared, 0)
		Successor := _Updater_AdmitInstallObserver({}, Shared, 0)
		Assert(Old["epoch"] != Successor["epoch"], "same callback admissions must have different ownership epochs")
		Assert(!_Updater_RestoreInstallObserver(Old), "callback identity alone cannot clear a newer admission")
		Assert(_UpdaterInstallObserver == Shared && _UpdaterInstallObserverEpoch == Successor["epoch"],
			"same-callback successor must remain the exact current publication")
	} finally {
		_UpdaterInstallObserver := Saved[1], _UpdaterInstallObserverEpoch := Saved[2]
		Critical(SavedCritical)
	}
}
Test("Updater observer: own rollback preserves prior observer and same-callback successor epochs",
	_UMF_ObserverRollbackPreservesPriorAndSameCallbackSuccessor)
