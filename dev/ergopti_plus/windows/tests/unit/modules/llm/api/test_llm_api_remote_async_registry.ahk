; tests/unit/modules/llm/api/test_llm_api_remote_async_registry.ahk

; ==============================================================================
; MODULE: Remote API Async Registry
; DESCRIPTION:
; LLM_RemoteCancelAsync and LLM_RemoteCancelAllAsync flag and retire the
; in-flight entries, and the curl owner detaches before a reentrant
; callback.
; ==============================================================================

#Requires AutoHotkey v2.0





_RemoteCancelAsync_FlagsEntry() {
	global _LLM_Remote_Async
	fake_id := 88801
	_LLM_Remote_Async[fake_id] := Map("http", "", "format", "openai", "on_success", (*) => 0, "on_fail", (*) => 0, "cancelled", false)
	LLM_RemoteCancelAsync(fake_id)
	AssertTrue(_LLM_Remote_Async[fake_id]["cancelled"])
	_LLM_Remote_Async.Delete(fake_id)
}
Test("LLM_RemoteCancelAsync: sets cancelled flag on in-flight entry", _RemoteCancelAsync_FlagsEntry)


_RemoteCancelAsync_NoOpOnMissingId() {
	global _LLM_Remote_Async
	before_count := _LLM_Remote_Async.Count
	LLM_RemoteCancelAsync(999888)
	AssertEqual(before_count, _LLM_Remote_Async.Count)
}
Test("LLM_RemoteCancelAsync: no-op when request id not found", _RemoteCancelAsync_NoOpOnMissingId)


_RemoteCancelAllAsync_FlagsAll() {
	global _LLM_Remote_Async
	_LLM_Remote_Async[88802] := Map("http", "", "on_success", (*) => 0, "on_fail", (*) => 0, "cancelled", false)
	_LLM_Remote_Async[88803] := Map("http", "", "on_success", (*) => 0, "on_fail", (*) => 0, "cancelled", false)
	LLM_RemoteCancelAllAsync()
	AssertTrue(_LLM_Remote_Async[88802]["cancelled"])
	AssertTrue(_LLM_Remote_Async[88803]["cancelled"])
	_LLM_Remote_Async.Delete(88802)
	_LLM_Remote_Async.Delete(88803)
}
Test("LLM_RemoteCancelAllAsync: cancels every in-flight entry", _RemoteCancelAllAsync_FlagsAll)


; The per-keystroke cancel must spare the explicit user probe: typing while a
; Test-selected-API probe is in flight kills it silently (no on_fail, no log,
; no popup) because the poll tick just sees a missing reservation. Ordinary
; prediction work still cancels, and a bare call keeps blanket semantics.
_RemoteCancelAllAsync_SparesOwnedProbe() {
	global _LLM_Remote_Async, LLM_REMOTE_KIND_API_TEST
	_LLM_Remote_Async[88804] := Map("kind", LLM_REMOTE_KIND_API_TEST, "cancelled", false)
	_LLM_Remote_Async[88805] := Map("kind", "", "cancelled", false)
	try {
		LLM_RemoteCancelAllAsync(LLM_REMOTE_KIND_API_TEST)
		AssertFalse(_LLM_Remote_Async[88804]["cancelled"],
			"an explicit user probe must survive the keystroke cancel")
		AssertTrue(_LLM_Remote_Async[88805]["cancelled"],
			"ordinary prediction work must still cancel")
		LLM_RemoteCancelAllAsync()
		AssertTrue(_LLM_Remote_Async[88804]["cancelled"],
			"a bare cancel-all keeps its blanket semantics")
	} finally {
		_LLM_Remote_Async.Delete(88804)
		_LLM_Remote_Async.Delete(88805)
	}
}
Test("LLM_RemoteCancelAllAsync: spares the owned user probe (api-test-entry-survives-typing)",
	_RemoteCancelAllAsync_SparesOwnedProbe)


_RemoteCancelPublication_Run(State, Command, WorkingDir, Options, &Pid, &ProcessOwner) {
	State["runs"] += 1
	LLM_RemoteCancelAllAsync()
	Pid := 7313
	ProcessOwner := Map("pid", Pid, "handle", 9313, "released", false)
}

_RemoteCancelPublication_Open(State, Pid) {
	State["opens"] += 1
	if State.Get("cancel_during_open", false)
		LLM_RemoteCancelAllAsync()
	if State.Get("fail_open", false)
		return 0
	return 9313
}

_RemoteCancelPublication_Terminate(State, Handle) {
	State["terminates"] += 1
	return true
}

_RemoteCancelPublication_Close(State, Handle) {
	State["closes"] += 1
	return true
}

_RemoteCancelPublication_Delete(State, Path) {
	State["deletes"] += 1
	return true
}

_RemoteCancelPublication_Poll(State, ReqId) {
	State["polls"] += 1
}

_RemoteCancelPublication_CurlPort(State, RunFn) {
	return Map(
		"resolve_proxy", _Stub_CurlResolveProxyDirect.Bind(State),
		"file_exists", (*) => true,
		"temp_dir", (*) => A_Temp,
		"write", (*) => true,
		"delete", _RemoteCancelPublication_Delete.Bind(State),
		"run", RunFn,
		"poll", _RemoteCancelPublication_Poll.Bind(State),
		"tick", (*) => 1313,
		"schedule_orphan_sweep", (*) => true,
		"open_process", _RemoteCancelPublication_Open.Bind(State),
		"terminate_process", _RemoteCancelPublication_Terminate.Bind(State),
		"wait_process", (*) => 0,
		"close_process", _RemoteCancelPublication_Close.Bind(State))
}

_RemoteCancelPublication_NewState() {
	return Map("runs", 0, "opens", 0, "terminates", 0, "closes", 0,
		"deletes", 0, "polls", 0, "aborts", 0, "sends", 0)
}

_RemoteCancelPublication_Resolved() {
	return Map("Format", "openai", "Token", "secret", "Model", "model")
}

_RemoteCancelPublication_CurlRunBoundary() {
	global _LLM_Remote_Async
	_LLM_Remote_Async := Map()
	State := _RemoteCancelPublication_NewState()
	Port := _RemoteCancelPublication_CurlPort(State,
		_RemoteCancelPublication_Run.Bind(State))
	ReqId := 891301
	try {
		AssertTrue(_LLMRemote_DispatchCurl(ReqId,
			_RemoteCancelPublication_Resolved(), "https://safe.invalid/v1", "{}",
			(*) => 0, (*) => 0, 1000, Port))
		Sleep(30)
		AssertEqual(1, State["proxy_resolutions"], "the real continuation admits the recorded direct route once")
		AssertFalse(_LLM_Remote_Async.Has(ReqId),
			"cancellation inside Run must not be overwritten by a live publication")
		AssertEqual(0, State["polls"],
			"a request cancelled during Run must never arm its poll")
		AssertEqual(1, State["terminates"],
			"the process returned by a reentrant Run boundary must be terminated exactly once")
		AssertEqual(1, State["closes"],
			"the exact adopted process handle must be closed exactly once")
	} finally {
		_LLM_Remote_Async := Map()
	}
}
Test("api_remote: cancellation during curl Run cannot miss unpublished owner (remote-cancel-publication-race)",
	_RemoteCancelPublication_CurlRunBoundary)


_RemoteCancelPublication_RunWithoutCancel(State, Command, WorkingDir, Options, &Pid, &ProcessOwner) {
	State["runs"] += 1
	Pid := 7314
	ProcessOwner := Map("pid", Pid, "handle", 9314, "released", false)
	if State.Get("fail_after_owner", false)
		throw Error("injected failure after exact owner creation")
}

_RemoteCancelPublication_CurlOwnedLaunchFailure() {
	global _LLM_Remote_Async
	_LLM_Remote_Async := Map()
	State := _RemoteCancelPublication_NewState()
	State["fail_after_owner"] := true
	State["fail_calls"] := 0
	Port := _RemoteCancelPublication_CurlPort(State,
		_RemoteCancelPublication_RunWithoutCancel.Bind(State))
	ReqId := 891302
	try {
		AssertTrue(_LLMRemote_DispatchCurl(ReqId,
			_RemoteCancelPublication_Resolved(), "https://safe.invalid/v1", "{}",
			(*) => 0, _RemoteAdoptionFailure_Record.Bind(State), 1000, Port))
		AssertEqual(1, State["proxy_resolutions"], "owned launch crosses the direct proxy continuation once")
		AssertFalse(_LLM_Remote_Async.Has(ReqId),
			"a launch failure after process creation must retire the reservation")
		AssertEqual(0, State["polls"],
			"a partially returned owned launch must never arm its poll")
		AssertEqual(1, State["terminates"],
			"the exact process owner returned before the throw must be terminated once")
		AssertEqual(1, State["closes"],
			"the exact process owner returned before the throw must be closed once")
		AssertEqual(1, State["fail_calls"],
			"owned launch containment must report request failure exactly once")
	} finally {
		_LLM_Remote_Async := Map()
	}
}
Test("api_remote: a throwing owned launcher cannot leak its child (AHK-079)",
	_RemoteCancelPublication_CurlOwnedLaunchFailure)


_RemoteAdoptionFailure_Record(State, *) {
	State["fail_calls"] += 1
}

_RemoteAdoptionFailure_AbortsDispatch() {
	global _LLM_Remote_Async
	_LLM_Remote_Async := Map()
	State := _RemoteCancelPublication_NewState()
	State["fail_after_owner"] := true
	State["fail_calls"] := 0
	Port := _RemoteCancelPublication_CurlPort(State,
		_RemoteCancelPublication_RunWithoutCancel.Bind(State))
	ReqId := 891303
	try {
		AssertTrue(_LLMRemote_DispatchCurl(ReqId,
			_RemoteCancelPublication_Resolved(), "https://safe.invalid/v1", "{}",
			(*) => 0, _RemoteAdoptionFailure_Record.Bind(State), 1000, Port))
		AssertEqual(1, State["proxy_resolutions"], "failed adoption still crosses the real proxy continuation once")
		AssertEqual(0, State["opens"],
			"owned curl launch must not use a second fallible OpenProcess step")
		AssertEqual(1, State["fail_calls"],
			"failed owned launch must fail the request exactly once")
		AssertEqual(1, State["terminates"],
			"failed owned launch must synchronously contain its exact child")
		AssertEqual(1, State["closes"],
			"failed owned launch must close its exact process handle")
		AssertEqual(0, State["polls"],
			"a process that was not adopted must never enter the async poll registry")
		AssertFalse(_LLM_Remote_Async.Has(ReqId),
			"failed adoption must retire the reservation synchronously")
		Assert(State["deletes"] > 0,
			"failed adoption must attempt to remove every pre-poll artifact")
	} finally {
		_LLM_Remote_Async := Map()
	}
}
Test("api_remote: owned launch failure aborts dispatch without adoption (AHK-079)",
	_RemoteAdoptionFailure_AbortsDispatch)


_RemoteOwnedLaunch_RetainsCreatedProcessHandle() {
	Pid := 0
	ProcessOwner := 0
	try {
		_LLM_CurlArtifactRun(A_ComSpec . ' /D /C "exit /b 0"', "", "Hide",
			&Pid, &ProcessOwner)
		Assert(IsInteger(Pid) and Pid > 0,
			"the native launch receipt must expose its positive process id")
		Assert(ProcessOwner is Map and ProcessOwner["pid"] == Pid
			and ProcessOwner["handle"] != 0 and !ProcessOwner["released"],
			"the successful CreateProcess call must retain its exact process handle")
		Deadline := A_TickCount + 3000
		while !_LLM_CurlProcessExited(ProcessOwner) and A_TickCount < Deadline
			Sleep(10)
		AssertTrue(_LLM_CurlProcessExited(ProcessOwner),
			"the retained process handle must observe the benign child terminal")
	} finally {
		if ProcessOwner is Map
			AssertTrue(_LLM_CurlReleaseProcess(ProcessOwner),
				"the exact native process handle must close successfully")
	}
}
Test("curl owner: native launch returns the exact child handle atomically (AHK-079)",
	_RemoteOwnedLaunch_RetainsCreatedProcessHandle)


; This deliberately unowned synthetic process can never settle. Keep its debt
; local to the fixture: later strict enable receipts require the real global
; ledger to settle. Critical preserves any already-armed predecessor timer while
; the fixture temporarily owns the ledger; finally restores it even on assertion.
_RemoteAdoptionFailure_WithSyntheticDebt(Body) {
	global _LLM_CurlCleanupDebt, _LLM_CurlCleanupDebtCounter
	global _LLM_CurlCleanupRetryTimer, LLM_CURL_CLEANUP_RETRY_MS
	PreviousCritical := Critical("On")
	OldDebt := _LLM_CurlCleanupDebt
	OldCounter := _LLM_CurlCleanupDebtCounter
	OldTimer := _LLM_CurlCleanupRetryTimer
	OldDelay := LLM_CURL_CLEANUP_RETRY_MS
	try {
		_LLM_CurlCleanupDebt := Map()
		_LLM_CurlCleanupDebtCounter := 0
		_LLM_CurlCleanupRetryTimer := 0
		LLM_CURL_CLEANUP_RETRY_MS := 60000
		Body.Call()
	} finally {
		if HasMethod(_LLM_CurlCleanupRetryTimer, "Call")
			SetTimer(_LLM_CurlCleanupRetryTimer, 0)
		_LLM_CurlCleanupDebt := OldDebt
		_LLM_CurlCleanupDebtCounter := OldCounter
		_LLM_CurlCleanupRetryTimer := OldTimer
		LLM_CURL_CLEANUP_RETRY_MS := OldDelay
		Critical(PreviousCritical)
	}
}

_RemoteAdoptionFailure_ReleaseCannotClaimSuccess() {
	global _LLM_CurlCleanupDebt, _LLM_CurlCleanupRetryTimer
	State := _RemoteCancelPublication_NewState()
	Port := _RemoteCancelPublication_CurlPort(State,
		_RemoteCancelPublication_RunWithoutCancel.Bind(State))
	Owner := Map("pid", 7315, "handle", 0, "released", false)
	AssertFalse(_LLM_CurlReleaseProcess(Owner, true, Port),
		"release without an exact retained process handle must report failure")
	AssertEqual(0, State["terminates"],
		"release must not fall back to terminating a recyclable numeric PID")
	AssertEqual(1, _LLM_CurlCleanupDebt.Count,
		"refused release must retain exactly its synthetic cleanup record")
	DebtId := Owner["cleanup_debt_id"]
	Record := _LLM_CurlCleanupDebt[DebtId]
	AssertEqual(ObjPtr(Owner), ObjPtr(Record["owner"]),
		"debt must retain the exact refusing owner rather than its numeric PID")
	AssertTrue(HasMethod(_LLM_CurlCleanupRetryTimer, "Call"),
		"refusal must arm its owned cleanup retry")
	; Consume the armed one-shot before manually replaying its callback. Otherwise
	; retry replaces the timer field and would strand the original native timer.
	SetTimer(_LLM_CurlCleanupRetryTimer, 0)
	AssertFalse(LLM_CurlRetryCleanupDebt(),
		"retry cannot invent a native handle for this deliberately invalid owner")
	AssertEqual(1, _LLM_CurlCleanupDebt.Count,
		"refusal must remain owned until the synthetic fixture is withdrawn")
	AssertEqual(ObjPtr(Record), ObjPtr(_LLM_CurlCleanupDebt[DebtId]),
		"retry must keep the same cleanup record")
	AssertFalse(Owner["released"], "fixture isolation is not native settlement")
	AssertEqual(0, State["opens"], "retry must never reopen a recyclable PID")
	AssertEqual(0, State["terminates"], "retry must never terminate by PID")
	AssertEqual(0, State["closes"], "retry must not close a fabricated handle")
}
Test("curl owner: release without exact handle cannot report success (curl-adoption-failure)",
	_RemoteAdoptionFailure_WithSyntheticDebt.Bind(
		_RemoteAdoptionFailure_ReleaseCannotClaimSuccess))


_RemoteAdoptionFailure_ThrowAfterRefusal() {
	_RemoteAdoptionFailure_ReleaseCannotClaimSuccess()
	throw Error("synthetic debt fixture interruption")
}

_RemoteAdoptionFailure_IsolationRestoresAfterThrow() {
	global _LLM_CurlCleanupDebt, _LLM_CurlCleanupDebtCounter
	global _LLM_CurlCleanupRetryTimer, LLM_CURL_CLEANUP_RETRY_MS
	OldDebt := _LLM_CurlCleanupDebt
	OldCount := OldDebt.Count
	OldCounter := _LLM_CurlCleanupDebtCounter
	OldTimer := _LLM_CurlCleanupRetryTimer
	OldDelay := LLM_CURL_CLEANUP_RETRY_MS
	OldCritical := A_IsCritical
	Failure := ""
	try _RemoteAdoptionFailure_WithSyntheticDebt(_RemoteAdoptionFailure_ThrowAfterRefusal)
	catch as Err
		Failure := Err.Message
	AssertEqual("synthetic debt fixture interruption", Failure,
		"the isolation fixture must propagate the original failure")
	AssertEqual(ObjPtr(OldDebt), ObjPtr(_LLM_CurlCleanupDebt),
		"interrupted fixture must restore the exact predecessor cleanup ledger")
	AssertEqual(OldCount, _LLM_CurlCleanupDebt.Count,
		"synthetic refusal must not leak into genuine predecessor debt")
	AssertEqual(OldCounter, _LLM_CurlCleanupDebtCounter,
		"interrupted fixture must restore predecessor debt identity allocation")
	AssertEqual(OldTimer, _LLM_CurlCleanupRetryTimer,
		"interrupted fixture must preserve the exact already-armed retry owner")
	AssertEqual(OldDelay, LLM_CURL_CLEANUP_RETRY_MS,
		"interrupted fixture must restore the predecessor retry policy")
	AssertEqual(OldCritical, A_IsCritical,
		"interrupted fixture must restore native thread admission")
}
Test("curl owner: synthetic debt fixture restores predecessor ownership after interruption (curl-adoption-failure)",
	_RemoteAdoptionFailure_IsolationRestoresAfterThrow)


class _RemoteCancelPublicationHttp {
	__New(State) {
		this.State := State
	}

	Open(*) {
	}

	SetTimeouts(*) {
	}

	SetRequestHeader(*) {
	}

	Send(*) {
		this.State["sends"] += 1
		LLM_RemoteCancelAllAsync()
	}

	Abort() {
		this.State["aborts"] += 1
	}
}

_RemoteCancelPublication_CreateHttp(State) {
	return _RemoteCancelPublicationHttp(State)
}

_RemoteCancelPublication_WinHttpBoundary() {
	global _LLM_Remote_Async
	_LLM_Remote_Async := Map()
	State := _RemoteCancelPublication_NewState()
	Port := Map(
		"create_http", _RemoteCancelPublication_CreateHttp.Bind(State),
		"poll", _RemoteCancelPublication_Poll.Bind(State),
		"tick", (*) => 1314)
	ReqId := 891303
	; A refused override fails the route before Send; that is another test's state.
	Choice := ProxyOverride_Current()
	AssertTrue(Choice is Map && Choice["mode"] == "automatic",
		"precondition: the proxy override must be automatic so the route reaches Send")
	try {
		AssertTrue(_LLMRemote_DispatchWinHttp(ReqId,
			_RemoteCancelPublication_Resolved(), "https://safe.invalid/v1", "{}",
			(*) => 0, (*) => 0, 1000, Port))
		Sleep(30)
		AssertEqual(1, State["sends"],
			"the WinHTTP seam must inject cancellation from inside Send")
		AssertEqual(1, State["aborts"],
			"the request cancelled during Send must be aborted exactly once")
		AssertEqual(0, State["polls"],
			"a request cancelled during Send must never arm its poll")
		AssertFalse(_LLM_Remote_Async.Has(ReqId),
			"WinHTTP cancellation must retire the exact reserved owner")
	} finally {
		_LLM_Remote_Async := Map()
	}
}
Test("api_remote: cancellation during WinHTTP Send cannot miss unpublished owner (remote-cancel-publication-race)",
	_RemoteCancelPublication_WinHttpBoundary)

; The COM request takes the override's route; a refused value sends nothing.
class _RemoteOverrideHttp extends _RemoteCancelPublicationHttp {
	SetProxy(Setting, Server := "") {
		this.State["proxy"] := Setting . "|" . Server
	}
}

; The publication lives in process globals, never in the environment, so the
; fixture restores those globals: a refused value left published made every later
; WinHTTP dispatch fail its route before Send, which --reverse exposed.
_RemoteOverride_Dispatch(Stored) {
	global _LLM_Remote_Async
	global _ProxyOverrideStored, _ProxyOverridePublished, _ProxyOverrideSealed, _ProxyOverrideBootSealSource
	_LLM_Remote_Async := Map()
	State := _RemoteCancelPublication_NewState()
	State["proxy"] := "unset"
	Failed := 0
	Port := Map("create_http", (*) => _RemoteOverrideHttp(State),
		"poll", _RemoteCancelPublication_Poll.Bind(State), "tick", (*) => 1314)
	Saved := [_ProxyOverrideStored, _ProxyOverridePublished, _ProxyOverrideSealed, _ProxyOverrideBootSealSource]
	try {
		ProxyOverride_Publish(Stored)
		_LLMRemote_DispatchWinHttp(891304, _RemoteCancelPublication_Resolved(),
			"https://safe.invalid/v1", "{}", (*) => 0, (*) => (Failed += 1), 1000, Port)
		State["failed"] := Failed
		return State
	} finally {
		_ProxyOverrideStored := Saved[1], _ProxyOverridePublished := Saved[2]
		_ProxyOverrideSealed := Saved[3], _ProxyOverrideBootSealSource := Saved[4]
		_LLM_Remote_Async := Map()
	}
}

_RemoteOverride_WinHttpRoute() {
	global _ProxyOverridePublished
	Predecessor := _ProxyOverridePublished
	AssertEqual("unset", _RemoteOverride_Dispatch("")["proxy"], "automatic leaves the object's route alone")
	AssertEqual("1|", _RemoteOverride_Dispatch("direct")["proxy"], "direct is explicit")
	AssertEqual("2|proxy.corp.invalid:3128", _RemoteOverride_Dispatch("http://proxy.corp.invalid:3128")["proxy"])
	Refused := _RemoteOverride_Dispatch("not a proxy")
	AssertEqual(0, Refused["sends"], "a refused override sends nothing")
	AssertEqual(1, Refused["failed"], "and says so")
	AssertEqual(Predecessor, _ProxyOverridePublished,
		"the override fixture must restore the predecessor publication, not leave the refused token")
}
Test("api_remote: the WinHTTP request takes the proxy override's route (remote-winhttp-override)",
	_RemoteOverride_WinHttpRoute)


_RemoteTrimRegistry_DropsOldestWhenAtCap() {
	global _LLM_Remote_Async, LLM_REMOTE_MAX_INFLIGHT
	_LLM_Remote_Async := Map()
	base_id := 77000
	loop LLM_REMOTE_MAX_INFLIGHT
		_LLM_Remote_Async[base_id + A_Index] := Map("cancelled", false)
	_LLMRemote_TrimAsyncRegistry()
	AssertEqual(LLM_REMOTE_MAX_INFLIGHT - 1, _LLM_Remote_Async.Count)
	AssertFalse(_LLM_Remote_Async.Has(base_id + 1), "oldest entry must have been removed")
	_LLM_Remote_Async := Map()
}
Test("_LLMRemote_TrimAsyncRegistry: removes oldest entry when at cap", _RemoteTrimRegistry_DropsOldestWhenAtCap)


_RemoteTrimRegistry_ReentrantSuccessor(State, *) {
	State["callbacks"] += 1
	if State["callbacks"] != 1
		return
	_LLMRemote_ReserveRequest(77013, (*) => 0, (*) => 0, 1000, 13,
		_RemoteCancelPublication_Resolved())
}

_RemoteTrimRegistry_DetachesBeforeReentrantCallback() {
	global _LLM_Remote_Async, LLM_REMOTE_MAX_INFLIGHT
	OldMax := LLM_REMOTE_MAX_INFLIGHT
	State := Map("callbacks", 0)
	LLM_REMOTE_MAX_INFLIGHT := 2
	_LLM_Remote_Async := Map(
		77011, Map("cancelled", false,
			"on_fail", _RemoteTrimRegistry_ReentrantSuccessor.Bind(State)),
		77012, Map("cancelled", false, "on_fail", (*) => 0))
	Err := "", ContractThrew := false
	try _LLMRemote_TrimAsyncRegistry()
	catch as Caught {
		ContractThrew := true
		Err := Caught.Message
	}
	finally LLM_REMOTE_MAX_INFLIGHT := OldMax
	try {
		AssertFalse(ContractThrew,
			"remote trim must not delete an owner already detached by reentrant work: " . Err)
		AssertEqual(1, State["callbacks"],
			"the displaced remote owner must emit exactly one terminal callback")
		AssertFalse(_LLM_Remote_Async.Has(77011),
			"the displaced owner must be absent before its callback starts")
		AssertTrue(_LLM_Remote_Async.Has(77012),
			"the surviving request must remain registered")
		AssertTrue(_LLM_Remote_Async.Has(77013),
			"the callback's successor must not be trimmed or removed by its predecessor")
		AssertEqual(2, _LLM_Remote_Async.Count,
			"remote trim plus one reentrant successor must finish exactly at the cap")
	} finally {
		_LLM_Remote_Async := Map()
	}
}
Test("api_remote: trim detaches owner before reentrant callback (async-trim-detach-before-callback)",
	_RemoteTrimRegistry_DetachesBeforeReentrantCallback)

#Include test_llm_backboard_exchange_after.ahk


_LTRC_Create(Control) {
    Http := CurlAsyncRequest(Map("spawn", _ManagedCurlControlSpawn.Bind(Control)))
    Control["request"] := Http
    return Http
}
_LTRC_Port(Control) {
    return Map("managed_settings", (*) => Map("auto_detect", false, "pac_url", "", "proxy", "", "bypass", ""),
        "create_http", _LTRC_Create.Bind(Control))
}
_LTRC_Admit(Control) {
    Http := Control["request"]
    AssertEqual(1, Control["spawns"])
    _ManagedCurlControlAck(Control)
    Http._PollManagedAdmission()
    AssertTrue(Http.ManagedPayloadPublished)
    AssertTrue(IsObject(Http.Handle))
}

_LTRC_Body(Cancelled) {
    global _LLM_Remote_Async, LLM_REMOTE_MAX_INFLIGHT
    AssertFalse(A_IsSuspended)
    AssertEqual(0, _LLM_Remote_Async.Count, "do not borrow any foreign reservation")
    SavedCap := LLM_REMOTE_MAX_INFLIGHT
    Controls := [_ManagedCurlControlState(), _ManagedCurlControlState()]
    Ids := [], Entries := [], First := [], Second := [], Primary := 0, CleanupIssues := []
    Resolved := _LLMRemoteResolveEntry(Map("Provider", "openai_compat", "Model", "fixture-model",
        "Token", "owned-fixture-secret", "BaseUrl", "https://trim-fixture.invalid/v1"))
    Url := "https://trim-fixture.invalid/v1/chat/completions"
    PreviousCritical := Critical("Off")
    try {
        LLM_REMOTE_MAX_INFLIGHT := 1
        Id1 := LLM_RemotePostBody_Async(Resolved, Url, '{"messages":[]}',
            (*) => First.Push(Map("ok", true)), (Info := "") => First.Push(Map("ok", false, "info", Info)),
            20000, "trim_cancel_control", 0, 0, _LTRC_Port(Controls[1]))
        Ids.Push(Id1)
        AssertTrue(_LLM_Remote_Async.Has(Id1))
        Entry1 := _LLM_Remote_Async[Id1]
        Entries.Push(Entry1)
        _LTRC_Admit(Controls[1])
        ; Cancel queues native cleanup by design. Hold that exact requesting
        ; thread through successor admission so a poll cannot retire it first.
        HandoffCritical := Critical("On")
        try {
            if Cancelled {
                LLM_RemoteCancelAsync(Id1)
                AssertTrue(Entry1["cancelled"])
                AssertTrue(_LLM_Remote_Async.Has(Id1), "cancellation is logically marked before deferred retirement")
            }
            Id2 := LLM_RemotePostBody_Async(Resolved, Url, '{"messages":[]}',
                (Text, Usage := "") => Second.Push(Map("ok", true, "text", Text)),
                (Info := "") => Second.Push(Map("ok", false, "info", Info)),
                20000, "trim_cancel_successor", 0, 0, _LTRC_Port(Controls[2]))
            Ids.Push(Id2)
            AssertTrue(_LLM_Remote_Async.Has(Id2))
            Entry2 := _LLM_Remote_Async[Id2]
            Entries.Push(Entry2)
        } finally Critical(HandoffCritical)
        AssertFalse(_LLM_Remote_Async.Has(Id1), "actual capacity trim must detach the predecessor")
        AssertTrue(_LLM_Remote_Async.Has(Id2) && _LLM_Remote_Async[Id2] == Entry2)
        Http1 := Controls[1]["request"], Http2 := Controls[2]["request"]
        AssertTrue(Http1.Completed && Http1.Aborted)
        AssertFalse(IsObject(Http1.Handle), "the actual trim must retire its predecessor's controlled Job")
        _LTRC_Admit(Controls[2])
        AssertTrue(FSWrite(Http2.BodyPath, '{"choices":[{"message":{"content":"owned-successor-ok"}}]}'))
        AssertTrue(FSWrite(Http2.HeaderPath, "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`n`r`n"))
        TerminalCritical := Critical("On")
        try {
            Controls[2]["callback"].Call(0, '{"schema_version":1,"ok":true,"status":200,"child_quiesced":true,"receipt":{}}', "")
            _LLMRemote_PollRequest(Id2)
        } finally Critical(TerminalCritical)
        _TestPrint("# REMOTE_TRIM_CANCEL " . KL_JsonEncode(Map("cancelled_case", Cancelled,
            "predecessor_cancelled", Entry1["cancelled"], "predecessor_callbacks", First.Length,
            "predecessor_reason", First.Length && !First[1]["ok"] ? First[1]["info"]["reason"] : "",
            "predecessor_registry_present", _LLM_Remote_Async.Has(Id1),
            "predecessor_handle_retired", !IsObject(Http1.Handle),
            "successor_callbacks", Second.Length, "successor_registry_present", _LLM_Remote_Async.Has(Id2),
            "successor_handle_retired", !IsObject(Http2.Handle), "native_spawns", Controls[1]["spawns"] + Controls[2]["spawns"])))
        AssertEqual(Cancelled ? 0 : 1, First.Length,
            "cancelled predecessor must stay silent; a live capacity eviction must fail exactly once")
        if !Cancelled {
            AssertFalse(First[1]["ok"])
            AssertEqual("trimmed", First[1]["info"]["reason"])
        }
        AssertEqual(1, Second.Length)
        AssertTrue(Second[1]["ok"] && Second[1]["text"] == "owned-successor-ok")
        AssertFalse(_LLM_Remote_Async.Has(Id2))
        AssertFalse(IsObject(Http2.Handle))
    } catch Any as Failure {
        Primary := Failure
    } finally {
        for Index, Id in Ids {
            try {
                if Index <= Entries.Length && _LLM_Remote_Async.Has(Id) && _LLM_Remote_Async[Id] == Entries[Index] {
                    LLM_RemoteCancelAsync(Id)
                    _LLMRemote_PollRequest(Id)
                }
            } catch Any as Failure {
                CleanupIssues.Push(Map("phase", "reservation", "error", Type(Failure), "message", SubStr(Failure.Message, 1, 200)))
                if !IsObject(Primary)
                    Primary := Failure
            }
        }
        for Control in Controls {
            try {
                if Control.Has("request") {
                    AssertTrue(Control["request"].Abort())
                    AssertFalse(IsObject(Control["request"].Handle))
                    _ManagedCurlControlRelease(Control)
                }
            } catch Any as Failure {
                CleanupIssues.Push(Map("phase", "facade", "error", Type(Failure), "message", SubStr(Failure.Message, 1, 200)))
                if !IsObject(Primary)
                    Primary := Failure
            }
        }
        LLM_REMOTE_MAX_INFLIGHT := SavedCap
        Critical(PreviousCritical)
        if CleanupIssues.Length > 0
            _TestPrint("# REMOTE_TRIM_CANCEL_CLEANUP " . KL_JsonEncode(CleanupIssues))
    }
    if IsObject(Primary)
        throw Primary
}
_LTRC_Run(Cancelled) {
    _ManagedRemoteFixtureWithLlmTimings(_LTRC_Body.Bind(Cancelled))
}
Test("Remote capacity trim: a live predecessor fails once (remote-trim-cancel)", _LTRC_Run.Bind(false))
Test("Remote capacity trim: a cancelled predecessor stays silent (remote-trim-cancel)", _LTRC_Run.Bind(true))

_LTRS_Body(Revoked) {
    global _LLM_Remote_Async, LLM_REMOTE_MAX_INFLIGHT
    AssertFalse(A_IsSuspended)
    AssertEqual(0, _LLM_Remote_Async.Count, "do not borrow any foreign reservation")
    SavedCap := LLM_REMOTE_MAX_INFLIGHT
    Controls := [_ManagedCurlControlState(), _ManagedCurlControlState()]
    Ids := [], Entries := [], First := [], Second := [], Primary := 0, CleanupIssues := []
    Scope := Map("current", true)
    Resolved := _LLMRemoteResolveEntry(Map("Provider", "openai_compat", "Model", "fixture-model",
        "Token", "owned-fixture-secret", "BaseUrl", "https://trim-fixture.invalid/v1"))
    Url := "https://trim-fixture.invalid/v1/chat/completions"
    PreviousCritical := Critical("Off")
    try {
        LLM_REMOTE_MAX_INFLIGHT := 1
        Id1 := LLM_RemotePostBody_Async(Resolved, Url, '{"messages":[]}',
            (*) => First.Push(Map("ok", true)), (Info := "") => First.Push(Map("ok", false, "info", Info)),
            20000, "trim_scope_control", 0, () => Scope["current"], _LTRC_Port(Controls[1]))
        Ids.Push(Id1)
        AssertTrue(_LLM_Remote_Async.Has(Id1))
        Entry1 := _LLM_Remote_Async[Id1]
        Entries.Push(Entry1)
        _LTRC_Admit(Controls[1])
        ; The requester disappears without calling CancelAsync. Hold only the
        ; native admission handoff so polling cannot retire the first request.
        HandoffCritical := Critical("On")
        try {
            if Revoked {
                Scope["current"] := false
                AssertFalse(Entry1["cancelled"], "scope withdrawal is independent of explicit cancellation")
                AssertTrue(_LLM_Remote_Async.Has(Id1), "the actual scope-revoked predecessor remains owned before trim")
            }
            Id2 := LLM_RemotePostBody_Async(Resolved, Url, '{"messages":[]}',
                (Text, Usage := "") => Second.Push(Map("ok", true, "text", Text)),
                (Info := "") => Second.Push(Map("ok", false, "info", Info)),
                20000, "trim_scope_successor", 0, 0, _LTRC_Port(Controls[2]))
            Ids.Push(Id2)
            AssertTrue(_LLM_Remote_Async.Has(Id2))
            Entry2 := _LLM_Remote_Async[Id2]
            Entries.Push(Entry2)
        } finally Critical(HandoffCritical)
        AssertFalse(_LLM_Remote_Async.Has(Id1), "actual capacity trim must detach the predecessor")
        AssertTrue(_LLM_Remote_Async.Has(Id2) && _LLM_Remote_Async[Id2] == Entry2)
        Http1 := Controls[1]["request"], Http2 := Controls[2]["request"]
        AssertTrue(Http1.Completed && Http1.Aborted)
        AssertFalse(IsObject(Http1.Handle), "the actual trim must retire its predecessor's controlled Job")
        _LTRC_Admit(Controls[2])
        AssertTrue(FSWrite(Http2.BodyPath, '{"choices":[{"message":{"content":"owned-successor-ok"}}]}'))
        AssertTrue(FSWrite(Http2.HeaderPath, "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`n`r`n"))
        TerminalCritical := Critical("On")
        try {
            Controls[2]["callback"].Call(0, '{"schema_version":1,"ok":true,"status":200,"child_quiesced":true,"receipt":{}}', "")
            _LLMRemote_PollRequest(Id2)
        } finally Critical(TerminalCritical)
        _TestPrint("# REMOTE_TRIM_SCOPE " . KL_JsonEncode(Map("revoked_case", Revoked, "requester_current", Scope["current"],
            "predecessor_cancelled", Entry1["cancelled"], "predecessor_callbacks", First.Length,
            "predecessor_reason", First.Length && !First[1]["ok"] ? First[1]["info"]["reason"] : "",
            "predecessor_registry_present", _LLM_Remote_Async.Has(Id1),
            "predecessor_handle_retired", !IsObject(Http1.Handle),
            "successor_callbacks", Second.Length, "successor_registry_present", _LLM_Remote_Async.Has(Id2),
            "successor_handle_retired", !IsObject(Http2.Handle), "native_spawns", Controls[1]["spawns"] + Controls[2]["spawns"])))
        AssertEqual(Revoked ? 0 : 1, First.Length,
            "a revoked requester must stay silent; a live capacity eviction must fail exactly once")
        if !Revoked {
            AssertFalse(First[1]["ok"])
            AssertEqual("trimmed", First[1]["info"]["reason"])
        }
        AssertEqual(1, Second.Length)
        AssertTrue(Second[1]["ok"] && Second[1]["text"] == "owned-successor-ok")
        AssertFalse(_LLM_Remote_Async.Has(Id2))
        AssertFalse(IsObject(Http2.Handle))
    } catch Any as Failure {
        Primary := Failure
    } finally {
        for Index, Id in Ids {
            try {
                if Index <= Entries.Length && _LLM_Remote_Async.Has(Id) && _LLM_Remote_Async[Id] == Entries[Index] {
                    LLM_RemoteCancelAsync(Id)
                    _LLMRemote_PollRequest(Id)
                }
            } catch Any as Failure {
                CleanupIssues.Push(Map("phase", "reservation", "error", Type(Failure), "message", SubStr(Failure.Message, 1, 200)))
                if !IsObject(Primary)
                    Primary := Failure
            }
        }
        for Control in Controls {
            try {
                if Control.Has("request") {
                    AssertTrue(Control["request"].Abort())
                    AssertFalse(IsObject(Control["request"].Handle))
                    _ManagedCurlControlRelease(Control)
                }
            } catch Any as Failure {
                CleanupIssues.Push(Map("phase", "facade", "error", Type(Failure), "message", SubStr(Failure.Message, 1, 200)))
                if !IsObject(Primary)
                    Primary := Failure
            }
        }
        LLM_REMOTE_MAX_INFLIGHT := SavedCap
        Critical(PreviousCritical)
        if CleanupIssues.Length > 0
            _TestPrint("# REMOTE_TRIM_SCOPE_CLEANUP " . KL_JsonEncode(CleanupIssues))
    }
    if IsObject(Primary)
        throw Primary
}
_LTRS_Run(Revoked) {
    _ManagedRemoteFixtureWithLlmTimings(_LTRS_Body.Bind(Revoked))
}
Test("Remote capacity trim: a current requester fails once (remote-trim-scope)", _LTRS_Run.Bind(false))
Test("Remote capacity trim: a scope-revoked requester stays silent (remote-trim-scope)", _LTRS_Run.Bind(true))
