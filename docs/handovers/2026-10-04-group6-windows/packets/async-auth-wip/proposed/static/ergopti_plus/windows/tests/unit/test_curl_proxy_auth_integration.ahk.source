; tests/unit/test_curl_proxy_auth_integration.ahk
; Deterministic owner-boundary controls. Native challenge qualification is separate.
_CurlAuthIntegration_Receipt() {
	return Map("schema_version", 1, "state", "ready", "backend", "curl",
		"child_quiesced", true, "capability", Map("tls_backend", "schannel",
			"sspi", true, "spnego", true, "ntlm", true, "version", "8.13.0"))
}

class _CurlAuthIntegration_Owner {
	__New(Callback, State := 0) {
		this.Callback := Callback
		this.State := State is Map ? State : Map("deferred", false)
		this.Cancelled := false
	}
	Start() {
		this.State["owner"] := this
		this.State["starts"] := this.State.Get("starts", 0) + 1
		if !this.State.Get("deferred", false)
			this.Publish(_CurlAuthIntegration_Receipt())
		return true
	}
	Publish(Receipt) {
		; Deliberately permits duplicate/late publication to exercise consumer fences.
		this.Callback.Call(this, Receipt)
	}
	Cancel(*) {
		return this.Abort()
	}
	Abort(*) {
		this.Cancelled := true
		this.State["aborts"] := this.State.Get("aborts", 0) + 1
		return !this.State.Get("refuse_retirement", false)
	}
}

_CurlAuthIntegration_CreateImmediate(Callback, *) {
	return _CurlAuthIntegration_Owner(Callback)
}
_CurlAuthIntegration_Create(State, Callback, *) {
	return _CurlAuthIntegration_Owner(Callback, State)
}

class _CurlAuthIntegration_Transport {
	__New(State) {
		this.State := State
	}
	start() {
		this.State["runs"] += 1
		return true
	}
	terminate() {
		this.State["retired"] += 1
		return true
	}
}
_CurlAuthIntegration_Spawn(State, Exe, Args, Done, *) {
	State["args"] := Args
	State["done"] := Done
	return _CurlAuthIntegration_Transport(State)
}
_CurlAuthIntegration_Capture(State, Request) {
	State["configs"].Push(FileRead(Request.ConfigPath, "UTF-8"))
}

_CurlAuthIntegration_Http(ProbeCase := "success") {
	State := Map("deferred", true, "runs", 0, "retired", 0, "configs", [])
	Req := CurlAsyncRequest(Map("create_curl_capability", _CurlAuthIntegration_Create.Bind(State),
		"before_launch", _CurlAuthIntegration_Capture.Bind(State),
		"spawn", _CurlAuthIntegration_Spawn.Bind(State)))
	try {
		Req.Open("POST", "https://auth-fixture.invalid/private", true)
		Req.SetProxy("http://managed.corp:3128")
		Req.SetRequestHeader("Authorization", "Bearer private-provider-token")
		AssertTrue(Req.Send("private-typed-body"))
		Owner := State["owner"]
		AssertEqual(0, State["runs"], "curl cannot run before actual build admission")
		AssertFalse(FileExist(Req.ConfigPath), "provider credentials are not staged while observation is pending")
		AssertFalse(FileExist(Req.BodyPath), "typed context is not staged while observation is pending")
		Receipt := _CurlAuthIntegration_Receipt()
		if ProbeCase == "cancel"
			Req.Abort()
		else if ProbeCase == "unsupported"
			Receipt["capability"]["sspi"] := false
		else if ProbeCase == "unretired"
			Receipt["child_quiesced"] := false
		else if ProbeCase == "timeout"
			Req.SetDeadline(A_TickCount - 1001, 1000)
		else if ProbeCase == "replace"
			Req.CapabilityOwner := _CurlAuthIntegration_Owner((*) => 0)
		Owner.Publish(Receipt)
		Owner.Publish(_CurlAuthIntegration_Receipt())
		if ProbeCase != "success" {
			AssertEqual(0, State["runs"], "stale/unavailable/unfinished capability cannot launch curl")
			AssertFalse(FileExist(Req.ConfigPath), "refused admission cannot leave credentials")
			AssertFalse(FileExist(Req.BodyPath), "refused admission cannot leave typed context")
			return
		}
		AssertEqual(1, State["runs"], "duplicate feature publication admits one child only")
		AssertEqual("--disable", State["args"][1], "ambient curl config cannot broaden authentication")
		AssertContains(State["configs"][1], "proxy-negotiate`n")
		AssertContains(State["configs"][1], 'proxy-user = ":"')
		AssertFalse(InStr(State["configs"][1], "proxy-anyauth"), "native current-user admission forbids ANYAUTH")
		AssertFalse(InStr(State["configs"][1], "proxy-basic"), "native current-user admission forbids Basic downgrade")
		AssertFalse(InStr(State["configs"][1], "proxy-digest"), "native current-user admission forbids Digest downgrade")
		for Argument in State["args"] {
			AssertFalse(InStr(Argument, "private-provider-token"), "provider token must remain outside argv")
			AssertFalse(InStr(Argument, "private-typed-body"), "typed context must remain outside argv")
		}
	} finally {
		Req.Abort()
	}
}
Test("curl auth admission: asynchronous actual-build gate precedes every private artifact", _CurlAuthIntegration_Http)
Test("curl auth admission: cancellation silences late build receipts", _CurlAuthIntegration_Http.Bind("cancel"))
Test("curl auth admission: missing SSPI cannot become current-user authentication", _CurlAuthIntegration_Http.Bind("unsupported"))
Test("curl auth admission: unfinished capability descendants cannot admit transport", _CurlAuthIntegration_Http.Bind("unretired"))
Test("curl auth admission: feature observation consumes the original deadline", _CurlAuthIntegration_Http.Bind("timeout"))
Test("curl auth admission: an old build receipt cannot replace a successor owner", _CurlAuthIntegration_Http.Bind("replace"))

_CurlAuthIntegration_RemoteResolve(State, Url, ContinueFn) {
	State["resolves"] += 1
	ContinueFn.Call(Map("ok", true, "inherit", false, "proxy", "http://managed.corp:3128"))
	return true
}
_CurlAuthIntegration_Remote(ProbeCase := "success") {
	global _LLM_Remote_Async
	SavedRegistry := _LLM_Remote_Async
	_LLM_Remote_Async := Map()
	State := _RemoteCancelPublication_NewState()
	State["deferred"] := true
	State["fail_calls"] := 0
	State["resolves"] := 0
	State["writes"] := []
	State["tick"] := 1313
	Port := _RemoteCancelPublication_CurlPort(State, _RemoteProxy_Run.Bind(State))
	Port["resolve_proxy"] := _CurlAuthIntegration_RemoteResolve.Bind(State)
	Port["create_curl_capability"] := _CurlAuthIntegration_Create.Bind(State)
	Port["write"] := _RemoteProxy_Write.Bind(State)
	Port["tick"] := (*) => State["tick"]
	ReqId := "auth-integration-generation"
	Resolved := Map("Format", "openai", "Model", "fixture", "Token", "private-provider-token")
	try {
		AssertTrue(_LLMRemote_DispatchCurl(ReqId, Resolved, "https://auth-fixture.invalid/private",
			'{}', (*) => 0, _RemoteAdoptionFailure_Record.Bind(State), 1000, Port))
		Reservation := _LLM_Remote_Async[ReqId]
		Owner := State["owner"]
		AssertEqual(0, State["writes"].Length, "feature admission must precede private generation artifacts")
		AssertEqual(0, State["runs"], "generation cannot launch before feature observation")
		Receipt := _CurlAuthIntegration_Receipt()
		if ProbeCase == "cancel"
			LLM_RemoteCancelAsync(ReqId)
		else if ProbeCase == "replace"
			_LLM_Remote_Async[ReqId] := Map("transport", "successor", "cancelled", false)
		else if ProbeCase == "timeout"
			State["tick"] += 1000
		else if ProbeCase == "unsupported"
			Receipt["capability"]["spnego"] := false
		Owner.Publish(Receipt)
		Owner.Publish(_CurlAuthIntegration_Receipt())
		if ProbeCase != "success" {
			AssertEqual(0, State["writes"].Length, "refusal cannot stage credentials")
			AssertEqual(0, State["runs"], "old/expired/unsupported admission cannot dispatch")
			if ProbeCase == "replace"
				AssertEqual("successor", _LLM_Remote_Async[ReqId]["transport"], "old feature completion preserves its replacement")
			return
		}
		AssertEqual(2, State["resolves"], "settings and dynamic PAC must be obtained again after build observation")
		AssertEqual(1, State["runs"], "one admitted build/route launches one child")
		AssertContains(State["writes"][2]["text"], "proxy-negotiate`n")
		AssertFalse(InStr(State["writes"][2]["text"], "proxy-anyauth"), "generation cannot broaden integrated auth")
		AssertFalse(InStr(State["command"]["command_line"], "private-provider-token"), "provider token is private config only")
	} finally {
		if IsSet(Reservation) {
			if Reservation.Has("proxy_deadline")
				SetTimer(Reservation["proxy_deadline"], 0)
			if Reservation.Has("capability_owner")
				Reservation["capability_owner"].Abort()
			if Reservation.Has("process_owner")
				_LLMRemote_CancelCurlReservation(ReqId, Reservation, Port)
		}
		_LLM_Remote_Async := SavedRegistry
	}
}
Test("remote curl auth: actual-build owner precedes private staging and fresh settings", _CurlAuthIntegration_Remote)
Test("remote curl auth: cancelled build receipt cannot launch or linger in the registry", _CurlAuthIntegration_Remote.Bind("cancel"))
Test("remote curl auth: stale build receipt preserves successor", _CurlAuthIntegration_Remote.Bind("replace"))
Test("remote curl auth: original deadline includes build observation", _CurlAuthIntegration_Remote.Bind("timeout"))
Test("remote curl auth: unsupported native Negotiate refuses admission", _CurlAuthIntegration_Remote.Bind("unsupported"))
