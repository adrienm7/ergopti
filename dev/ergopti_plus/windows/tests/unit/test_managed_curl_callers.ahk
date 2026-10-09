; tests/unit/test_managed_curl_callers.ahk
; Tests call production consumers through explicit process/clock publication ports.
; Native wire behavior stays with real Windows fixtures and is not credited here.

_ManagedCallerFactory(State) {
	State["factory_entered"] := A_TickCount
	Sleep(20)
	State["factory_returned"] := A_TickCount
	return State["request"]
}

_ManagedCallerChangelog(Mode := "live", YieldAfterAck := false) {
	global _CLW_RequestEpoch, _CLW_Queue, CHANGELOG_SOURCE_TIMEOUT_MS
	Previous := _CNR_InstallChangelog()
	State := _ManagedCurlControlState()
	Request := _ManagedCurlControlNew(State)
	Request.ManagedRouting := false
	try {
		_CLW_BeginWindowSession()
		Context := _CLW_BeginFetchRequest("main")
		Port := Map("create_http", _ManagedCallerFactory.Bind(State), "poll", (*) => 0)
		_CLW_DoFetch(Context, Port)
		AssertEqual(1, State["spawns"], "the real Versions caller owns one Job for discovery and transfer")
		AssertTrue(State["input"]["started_tick"] <= State["factory_entered"], "the source clock begins before request acquisition can yield")
		AssertTrue(State["factory_returned"] - State["input"]["started_tick"] >= 15, "request acquisition cannot reset the original source clock")
		AssertEqual(CHANGELOG_SOURCE_TIMEOUT_MS, State["input"]["deadline_ms"], "discovery and transfer share the source's original duration")
		AssertFalse(FileExist(State["directory"] . "transport.json"), "actual caller headers stay unpublished before route/capability admission")
		; This control delivers the poll only after exact source revocation. Hold
		; its real callback before the complete ACK can make admission due.
		AssertTrue(IsObject(Request.ManagedAdmissionFn), "manual Versions revocation must own the actual admission callback")
		if YieldAfterAck {
			AssertEqual(0, A_IsCritical, "the Versions interleave must allow actual timer dispatch")
			SetTimer(Request.ManagedAdmissionFn, -1)
		}
		SetTimer(Request.ManagedAdmissionFn, 0)
		_ManagedCurlControlAck(State)
		if YieldAfterAck {
			Sleep(30)
			AssertTrue(IsObject(Request.ManagedAdmissionFn), "holding admission retains the exact callback until source replacement")
			AssertFalse(Request.ManagedPayloadPublished, "a yielded complete ACK cannot preempt controlled Versions replacement")
			AssertFalse(Request.Aborted, "holding admission preserves the original live Versions request until replacement")
			AssertEqual(State["input"]["started_tick"], Request.DeadlineStart, "the Versions interleave cannot restart the source clock")
			AssertEqual(CHANGELOG_SOURCE_TIMEOUT_MS, Request.DeadlineTimeout, "the Versions interleave cannot extend its original duration")
		}
		if Mode == "replaced"
			_CLW_RequestEpoch += 1
		else if Mode == "expired" {
			Request.DeadlineStart := 0
			Request.DeadlineTimeout := 1
		}
		Request._PollManagedAdmission()
		if Mode != "live" {
			AssertTrue(Request.Aborted, "a revoked exact caller rejects its queued acknowledgement")
			AssertFalse(FileExist(State["directory"] . "transport.json"), "stale source admission cannot publish caller headers")
			AssertEqual(0, _CLW_Queue.Length, "a rejected source cannot inject a page response")
		} else {
			Published := JsonParse(FileRead(State["directory"] . "transport.json", "UTF-8"))
			AssertTrue(Published["headers"].Length >= 2, "only admitted transport receives the original caller headers")
			AssertTrue(FSWrite(Request.BodyPath, "[]"))
			AssertTrue(FSWrite(Request.HeaderPath, "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`n`r`n"))
			State["callback"].Call(0, '{"schema_version":1,"ok":true,"status":200,"child_quiesced":true,"receipt":{}}', "")
			_CLW_PollFetch(Request, Context, 0)
			AssertEqual(1, _CLW_Queue.Length, "the real current Versions poll publishes the accepted response once")
		}
	} finally {
		_ManagedCurlControlRelease(State)
		_CNR_RestoreChangelog(Previous)
	}
}
Test("managed caller: Versions owns proxy admission before transport under its original source clock", _ManagedCallerChangelog)
Test("managed caller: Versions replacement revokes a queued native admission", _ManagedCallerChangelog.Bind("replaced"))
Test("managed caller: Versions source expiry revokes a queued native admission", _ManagedCallerChangelog.Bind("expired"))
Test("managed caller: queued Versions admission cannot preempt replacement after a yielded ACK (versions-queued-admission-owner)", _ManagedCallerChangelog.Bind("replaced", true))

_ManagedCallerHealthcheck(YieldAfterAck := false) {
	global _HC_ProbeRun
	Saved := _HC_ProbeRun
	State := _ManagedCurlControlState()
	Request := _ManagedCurlControlNew(State)
	Request.ManagedRouting := false
	Run := { Epoch: 9042, Cancelled: false, Requests: [], Publish: (*) => 0 }
	_HC_ProbeRun := Run
	Started := A_TickCount
	try {
		Port := Map("create_http", _ManagedCallerFactory.Bind(State), "arm_poll", (*) => 0)
		_HC_ProbeSend(Run, "github_api", "https://safe.invalid/api", Map("User-Agent", "owned-probe"),
			20000, _HC_GithubAnswer, Started, Port)
		AssertEqual(1, State["spawns"], "the real diagnostics caller routes and transfers in one owned Job")
		AssertEqual(Started, State["input"]["started_tick"], "probe dispatch cannot reset its pre-discovery clock")
		AssertEqual(20000, State["input"]["deadline_ms"], "the exact original probe budget reaches native discovery")
		AssertEqual(ObjPtr(Request), ObjPtr(Run.Requests[1]), "the exact run publishes its request before native effects")
		; This control delivers the poll only after exact run replacement. Hold
		; its real callback before the complete ACK can make admission due.
		AssertTrue(IsObject(Request.ManagedAdmissionFn), "manual diagnostics replacement must own the actual admission callback")
		if YieldAfterAck {
			AssertEqual(0, A_IsCritical, "the diagnostics interleave must allow actual timer dispatch")
			SetTimer(Request.ManagedAdmissionFn, -1)
		}
		SetTimer(Request.ManagedAdmissionFn, 0)
		_ManagedCurlControlAck(State)
		if YieldAfterAck {
			Sleep(30)
			AssertTrue(IsObject(Request.ManagedAdmissionFn), "holding admission retains the exact callback until run replacement")
			AssertFalse(Request.ManagedPayloadPublished, "a yielded complete ACK cannot preempt controlled diagnostics replacement")
			AssertFalse(Request.Aborted, "holding admission preserves the original live diagnostics request until replacement")
			AssertEqual(Started, Request.DeadlineStart, "the diagnostics interleave cannot restart the source clock")
			AssertEqual(20000, Request.DeadlineTimeout, "the diagnostics interleave cannot extend its original duration")
		}
		_HC_ProbeRun := { Epoch: 9043, Cancelled: false, Requests: [], Publish: (*) => 0 }
		Request._PollManagedAdmission()
		AssertTrue(Request.Aborted, "replacement of a diagnostics run revokes the old facade")
		AssertFalse(FileExist(State["directory"] . "transport.json"), "old diagnostics admission cannot publish headers")
	} finally {
		_ManagedCurlControlRelease(State)
		Run.Requests := []
		_HC_ProbeRun := Saved
	}
}
Test("managed caller: diagnostics binds the original clock and exact run before native admission", _ManagedCallerHealthcheck)
Test("managed caller: queued diagnostics admission cannot preempt replacement after a yielded ACK", _ManagedCallerHealthcheck.Bind(true))

_ManagedCallerAiFailure(State) {
	global _LLM_Remote_Async
	Saved := _LLM_Remote_Async
	_LLM_Remote_Async := Map()
	Control := _ManagedCurlControlState()
	Request := _ManagedCurlControlNew(Control)
	Calls := []
	try {
		Resolved := Map("Format", "openai", "Token", "private-provider-token", "Model", "fixture")
		Entry := _LLMRemote_ReserveRequest(902145, (*) => 0, (Info) => Calls.Push(Info), 20000, A_TickCount, Resolved)
		Entry["http"] := Request
		Entry["transport"] := "managed_curl"
		Request.ManagedTransport := true
		Request.Completed := true
		Request.NativeReceipt := Map("backend", "curl", "stage", "tls", "failure_provenance", "verified",
			"tls_verification", "enforced", "curl_exit", 60, "private_url", "https://private.invalid/token")
		_LLMRemote_PollRequest(902145)
		AssertEqual(1, Calls.Length, "the actual AI completion returns one existing failure callback")
		AssertEqual("certificate", Calls[1]["network_report"]["cause"], "actual typed certificate failure reaches the AI consumer")
		Safe := ManagedNetworkFailureWindows_ReportJson(Calls[1]["network_report"])
		AssertFalse(InStr(Safe, "private.invalid"), "the callback report contains no native endpoint")
		AssertFalse(InStr(Safe, "curl_exit"), "the callback report contains no private native receipt")
		AssertFalse(_LLM_Remote_Async.Has(902145), "the exact terminal registry owner retires once")
	} finally {
		_ManagedCurlControlRelease(Control)
		_LLM_Remote_Async := Saved
	}
}
Test("managed caller: actual AI failure callback carries only its canonical safe cause", (*) => _MNW_Scope(_ManagedCallerAiFailure))

_ManagedCallerUpdaterFailure(State) {
	global _UpdaterAsyncRequests, UPDATER_REQUEST_ORIGIN_MANUAL
	Saved := _UpdaterAsyncRequests
	_UpdaterAsyncRequests := Map()
	Control := _ManagedCurlControlState()
	Request := _ManagedCurlControlNew(Control)
	try {
		Context := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
		Owner := _Updater_RegisterAsyncRequestOwner(Request, Context.Channel, (*) => 0, "https://safe.invalid/api", Context)
		Request.ManagedTransport := true
		Request.Completed := true
		Request.NativeReceipt := Map("backend", "curl", "stage", "proxy_connect", "failure_provenance", "verified",
			"proxy_connect_status", 407, "private_path", "C:\secret\owned")
		AssertTrue(_Updater_AttachManagedNetworkFailure(Owner), "the exact live updater record owns typed failure materialization")
		AssertEqual("proxy", Context.NetworkFailureReport["cause"], "the existing manual request retains the safe proxy cause")
		AssertFalse(InStr(ManagedNetworkFailureWindows_ReportJson(Context.NetworkFailureReport), "secret"), "manual result contains no native path")
		Context.DeleteProp("NetworkFailureReport")
		_UpdaterAsyncRequests[Owner.Id] := Map("http", 0)
		AssertFalse(_Updater_AttachManagedNetworkFailure(Owner), "a replacement registry record cannot borrow the retired receipt")
		AssertFalse(Context.HasOwnProp("NetworkFailureReport"), "stale native failure cannot annotate a successor result")
	} finally {
		_ManagedCurlControlRelease(Control)
		_UpdaterAsyncRequests := Saved
	}
}
Test("managed caller: updater typed cause is bound to its exact live record", (*) => _MNW_Scope(_ManagedCallerUpdaterFailure))

_ManagedCallerInvalidNativeCause(State) {
	Control := _ManagedCurlControlState()
	Request := _ManagedCurlControlNew(Control)
	try {
		Request.ManagedTransport := true
		Request.Completed := true
		Request.NativeReceipt := Map("backend", "curl", "stage", "tls", "failure_provenance", "verified",
			"tls_verification", "enforced", "curl_exit", "60", "stderr", "certificate disk full proxy forbidden")
		Report := ManagedNetworkFailureWindows_FromTransport(Request, (*) => true)
		AssertEqual("unknown", Report["cause"], "a string-valued native exit cannot manufacture certificate provenance")
		AssertEqual("invalid_receipt", Report["evidence"], "typed refusal remains distinct from an observed cause")
		AssertEqual("", ManagedNetworkFailureWindows_MessageKey(Map("cause", "certificate", "message_key", "private.arbitrary")),
			"rendering cannot borrow an arbitrary caller-supplied translation key")
	} finally _ManagedCurlControlRelease(Control)
}
Test("managed caller: typed failure rejects string coercion and arbitrary renderer keys", (*) => _MNW_Scope(_ManagedCallerInvalidNativeCause))
