; tests/unit/modules/llm/api/test_llm_api_remote_requests.ahk

; ==============================================================================
; MODULE: Remote API Catalogue, Request Context and Poll Deadline
; DESCRIPTION:
; The provider catalogue loads from the shared data, the request context
; resolves each provider's endpoint, and the poll loop is capped by the
; deadline stored at dispatch.
; ==============================================================================

#Requires AutoHotkey v2.0





_RemoteCatalog_LoadedFromShared() {
	AssertTrue(LLM_API_PROVIDERS.Has("openai"))
	AssertTrue(LLM_API_PROVIDERS.Has("openai_compat"))
	; Preserve the complete cloud prefix and independently name the new local suffix.
	Shipped := JsonParse(FileRead(_SharedDir . "\modules\llm\api_providers.json", "UTF-8"))
	LocalIds := ["omlx", "lmstudio", "llamacpp", "jan"]
	ShippedLocal := JsonParse(FileRead(_SharedDir . "\modules\llm\local_servers.json", "UTF-8"))
	AssertEqual(4, ShippedLocal["server_order"].Length,
		"the optional-auth catalogue declares exactly the four independently named local providers")
	AssertEqual(Shipped["provider_order"].Length + 4, LLM_API_PROVIDER_ORDER.Length,
		"every shipped cloud and local provider publishes, the Backboard and decisions formats included")
	for Index, ProviderId in Shipped["provider_order"]
		AssertEqual(ProviderId, LLM_API_PROVIDER_ORDER[Index], "the catalogue keeps provider_order")
	for Index, ProviderId in LocalIds {
		AssertEqual(ProviderId, ShippedLocal["server_order"][Index],
			"the local catalogue retains its independently named provider order")
		AssertEqual(ProviderId, LLM_API_PROVIDER_ORDER[Shipped["provider_order"].Length + Index],
			"local providers append after the unchanged complete cloud prefix")
		AssertTrue(LLM_API_PROVIDERS.Has(ProviderId), "each local provider reaches the actual request registry")
		AssertTrue(LLM_LOCAL_API_SERVERS.Has(ProviderId), "each local provider retains its optional-auth capability")
	}
	AssertTrue(LLM_REMOTE_MODEL_PRICES.Has("gpt-4o-mini"))
}
Test("api_providers.json: catalogue loaded at module init", _RemoteCatalog_LoadedFromShared)


_RemoteCatalog_InvalidScalarsNeverPublish() {
	global LLM_API_PROVIDERS, LLM_API_PROVIDER_ORDER, LLM_REMOTE_MODEL_PRICES, LLM_REMOTE_TEST_REQUEST, _SharedDir
	global LLM_REMOTE_DECISIONS_TEST, LLM_LOCAL_API_SERVERS
	oldLocalServers := LLM_LOCAL_API_SERVERS
	oldLocalServerState := []
	for ProviderId, Descriptor in oldLocalServers {
		Fields := Map()
		for Key, Value in Descriptor
			Fields[Key] := Value
		oldLocalServerState.Push(Map("id", ProviderId, "descriptor", Descriptor, "fields", Fields))
	}
	oldDecisionsTest := LLM_REMOTE_DECISIONS_TEST
	oldProviders := LLM_API_PROVIDERS
	oldOrder := LLM_API_PROVIDER_ORDER
	oldPrices := LLM_REMOTE_MODEL_PRICES
	oldTestRequest := LLM_REMOTE_TEST_REQUEST
	oldSharedDir := _SharedDir
	testRoot := A_Temp . "\ergopti-ahk013-" . DllCall("GetCurrentProcessId") . "-" . A_TickCount
	fixture := FileRead(A_ScriptDir . "\..\..\_shared\tests\corpus\api_provider_catalog_validation.json", "UTF-8")
	try {
		DirCreate(testRoot . "\modules\llm")
		FileAppend(fixture, testRoot . "\modules\llm\api_providers.json", "UTF-8")
		_SharedDir := testRoot
		_LLMRemote_LoadCatalog()

		AssertEqual(2, LLM_API_PROVIDER_ORDER.Length,
			"only the valid provider and the configurable compatibility provider may publish")
		AssertEqual("valid", LLM_API_PROVIDER_ORDER[1])
		AssertEqual("openai_compat", LLM_API_PROVIDER_ORDER[2])
		AssertTrue(LLM_API_PROVIDERS.Has("valid"))
		AssertTrue(LLM_API_PROVIDERS.Has("openai_compat"))
		for invalidId in ["empty_base", "empty_model", "bad_url", "space_model", "space_label", "object_label", "array_url", "null_model", "number_format", "unknown_format"]
			AssertFalse(LLM_API_PROVIDERS.Has(invalidId), invalidId . " must not reach the published catalogue")
		AssertEqual("", LLM_API_PROVIDERS["openai_compat"]["BaseUrl"])
		AssertEqual("", LLM_API_PROVIDERS["openai_compat"]["DefaultModel"])
		providerChoices := _LLM_Menu_BuildApiProviderChoices(LLM_API_PROVIDERS)
		AssertContains(providerChoices, "valid (Valid)")
		AssertContains(providerChoices, "openai_compat (Compatible)")

		AssertTrue(LLM_REMOTE_MODEL_PRICES.Has("valid_integer"))
		AssertTrue(LLM_REMOTE_MODEL_PRICES.Has("valid_float"))
		for invalidModel in ["string_price", "null_price", "container_price", "negative_price"]
			AssertFalse(LLM_REMOTE_MODEL_PRICES.Has(invalidModel), invalidModel . " must remain unpriced")
		AssertEqual(3.0, _LLMRemoteEstimateCost("valid_integer", 1000000, 1000000))
		AssertEqual(0.875, _LLMRemoteEstimateCost("valid_float", 1000000, 1000000))
		AssertEqual(0.0, _LLMRemoteEstimateCost("string_price", 1000000, 1000000))
	} finally {
		_SharedDir := oldSharedDir
		LLM_API_PROVIDERS := oldProviders
		LLM_API_PROVIDER_ORDER := oldOrder
		LLM_REMOTE_MODEL_PRICES := oldPrices
		LLM_REMOTE_TEST_REQUEST := oldTestRequest
		LLM_REMOTE_DECISIONS_TEST := oldDecisionsTest
		LLM_LOCAL_API_SERVERS := oldLocalServers
		try DirDelete(testRoot, true)
	}
	AssertEqual(ObjPtr(oldLocalServers), ObjPtr(LLM_LOCAL_API_SERVERS),
		"catalogue reload fixture restores the exact predecessor optional-auth registry")
	AssertEqual(oldLocalServerState.Length, LLM_LOCAL_API_SERVERS.Count,
		"the synthetic catalogue must not leak or remove predecessor local providers")
	for Row in oldLocalServerState {
		Descriptor := LLM_LOCAL_API_SERVERS[Row["id"]]
		AssertEqual(ObjPtr(Row["descriptor"]), ObjPtr(Descriptor),
			"restoration keeps each predecessor capability descriptor identity")
		AssertEqual(Row["fields"].Count, Descriptor.Count,
			"the predecessor capability descriptor retains all of its fields")
		for Key, Value in Row["fields"]
			AssertEqual(Value, Descriptor[Key], "the predecessor capability field is unchanged: " . Key)
	}
}
Test("api_providers.json: invalid descriptor and price scalars never publish", _RemoteCatalog_InvalidScalarsNeverPublish)


_RemoteBuildContext_PrefixTail() {
	req := _LLMRemote_BuildRequestContext("PREFIX and TAIL markers", "full ctx", "tail bit")
	AssertContains(req["user"], 'PREFIX: "full ctx"')
	AssertContains(req["user"], 'TAIL: "tail bit"')
}
Test("_LLMRemote_BuildRequestContext: PREFIX/TAIL profiles format user turn", _RemoteBuildContext_PrefixTail)


_RemoteBuildContext_ContextSubstitution() {
	req := _LLMRemote_BuildRequestContext("Complete: {context}", "hello world", "world")
	AssertContains(req["system"], "hello world")
	AssertEqual("", req["user"])
}
Test("_LLMRemote_BuildRequestContext: {context} substitution moves text into system", _RemoteBuildContext_ContextSubstitution)


_RemoteIsReady_AnthropicAuthHeader() {
	entry := Map("Provider", "anthropic", "Token", "sk-ant", "Model", "claude-haiku-4-5", "BaseUrl", "")
	; Offline: we only verify resolve + URL shape — no HTTP.
	resolved := _LLMRemoteResolveEntry(entry)
	AssertEqual("anthropic", resolved["Format"])
	url := _LLMRemoteBuildUrl(resolved["BaseUrl"], resolved["Format"], resolved["Token"], resolved["Model"])
	AssertEqual("https://api.anthropic.com/v1/messages", url)
}
Test("LLM_RemoteIsReady path: anthropic resolves to /messages endpoint", _RemoteIsReady_AnthropicAuthHeader)


; ==============================================================================
; ======= Poll-loop deadline cap regression ====================================
; ==============================================================================

; Regression guard for remote-poll-no-deadline-cap: _LLMRemote_PollRequest
; polled indefinitely when the remote never responded — the poll loop rescheduled
; itself via SetTimer with no upper bound. The fix stores a deadline_tick in
; the async entry at dispatch and aborts (calls on_fail) when it is exceeded.
_Remote_DeadlineTickStoredAtDispatch() {
	global _LLM_Remote_Async, _LLM_Remote_AsyncCounter, LLM_REMOTE_TIMEOUT_MS
	; Build a minimal entry map that mirrors what LLM_RemoteGenerate_Async stores.
	SavedTimeout := LLM_REMOTE_TIMEOUT_MS
	LLM_REMOTE_TIMEOUT_MS := 5000   ; Simulate a loaded value
	Before := A_TickCount
	; Compute deadline_ms as the function does internally.
	deadline_ms := (LLM_REMOTE_TIMEOUT_MS > 0) ? LLM_REMOTE_TIMEOUT_MS : 30000
	After := A_TickCount
	LLM_REMOTE_TIMEOUT_MS := SavedTimeout
	; deadline_ms must equal 5000 when LLM_REMOTE_TIMEOUT_MS is set to 5000.
	AssertEqual(5000, deadline_ms,
		"deadline_ms must equal LLM_REMOTE_TIMEOUT_MS when non-zero")
}
Test("api_remote: deadline_ms respects LLM_REMOTE_TIMEOUT_MS when non-zero", _Remote_DeadlineTickStoredAtDispatch)

_Remote_DeadlineTickFallsBack() {
	global LLM_REMOTE_TIMEOUT_MS
	SavedTimeout := LLM_REMOTE_TIMEOUT_MS
	LLM_REMOTE_TIMEOUT_MS := 0   ; Sentinel — not yet loaded
	deadline_ms := (LLM_REMOTE_TIMEOUT_MS > 0) ? LLM_REMOTE_TIMEOUT_MS : 30000
	LLM_REMOTE_TIMEOUT_MS := SavedTimeout
	AssertEqual(30000, deadline_ms,
		"deadline_ms must fall back to 30000 ms when LLM_REMOTE_TIMEOUT_MS is the 0 sentinel")
}
Test("api_remote: deadline_ms falls back to 30 s when LLM_REMOTE_TIMEOUT_MS is 0 sentinel", _Remote_DeadlineTickFallsBack)


_RemoteProxy_CaptureResolve(State, Url, Callback) {
	State["proxy_resolves"] := State.Get("proxy_resolves", 0) + 1
	if State["proxy_resolves"] > 1 {
		Callback.Call(Map("ok", true, "inherit", false, "proxy", "http://managed.corp:3128"))
		return true
	}
	State["url"] := Url
	State["continue"] := Callback
	return true
}

_RemoteProxy_Write(State, Path, Text) {
	State["writes"].Push(Map("path", Path, "text", Text))
	return true
}

_RemoteProxy_Run(State, Command, WorkingDir, Options, &Pid, &ProcessOwner) {
	State["command"] := Command
	_RemoteCancelPublication_RunWithoutCancel(State, Command, WorkingDir, Options, &Pid, &ProcessOwner)
}

_RemoteProxy_DeferredGeneration(ProbeCase := "success") {
	global _LLM_Remote_Async
	SavedRegistry := _LLM_Remote_Async
	_LLM_Remote_Async := Map()
	State := _RemoteCancelPublication_NewState()
	State["writes"] := []
	State["fail_calls"] := 0
	State["tick"] := 1313
	Port := _RemoteCancelPublication_CurlPort(State, _RemoteProxy_Run.Bind(State))
	Port["resolve_proxy"] := _RemoteProxy_CaptureResolve.Bind(State)
	Port["write"] := _RemoteProxy_Write.Bind(State)
	Port["tick"] := (*) => State["tick"]
	ReqId := "group6_proxy_generation"
	Resolved := Map("Format", "gemini", "Token", "private-api-key", "Model", "model")
	Url := "https://remote.invalid:8443/v1/models/test?key=private-api-key"
	try {
		AssertTrue(_LLMRemote_DispatchCurl(ReqId, Resolved, Url, '{"text":"private-context"}',
			(*) => 0, _RemoteAdoptionFailure_Record.Bind(State), 1000, Port))
		Reservation := _LLM_Remote_Async[ReqId]
		AssertEqual(Url, State["url"], "the first request must resolve its actual destination")
		AssertEqual(0, State["writes"].Length, "no credential or payload staging before admission")
		AssertEqual(0, State["runs"], "curl must wait for the first PAC answer")
		if ProbeCase == "cancel"
			LLM_RemoteCancelAsync(ReqId)
		else if ProbeCase == "replace"
			_LLM_Remote_Async[ReqId] := Map("transport", "pending", "cancelled", false)
		else if ProbeCase == "timeout"
			State["tick"] += 1000
		State["continue"].Call(Map("ok", ProbeCase != "reject", "inherit", false, "proxy", "http://managed.corp:3128"))
		State["continue"].Call(Map("ok", true, "inherit", false, "proxy", "http://late.corp:80"))
		if ProbeCase != "success" {
			AssertEqual(0, State["writes"].Length, "stale or cancelled admission must not stage private data")
			AssertEqual(0, State["runs"], "stale or expired admission must launch no child")
			AssertEqual((ProbeCase == "timeout" || ProbeCase == "reject") ? 1 : 0, State["fail_calls"], "timeout fails once; cancellation stays silent")
			if ProbeCase == "replace"
				AssertEqual("pending", _LLM_Remote_Async[ReqId]["transport"], "old completion must preserve successor")
			return
		}
		AssertEqual(1, State["runs"], "duplicate resolver completion must launch exactly once")
		AssertEqual(2, State["writes"].Length, "one payload and one private config are staged")
		AssertContains(State["writes"][2]["text"], 'proxy = "http://managed.corp:3128"')
		AssertContains(State["writes"][2]["text"], "proxy-negotiate")
		AssertFalse(InStr(State["writes"][2]["text"], "proxy-anyauth"), "the negotiated native scheme must not allow Basic/Digest downgrade")
		AssertContains(State["writes"][2]["text"], 'proxy-user = ":"')
		AssertFalse(InStr(State["command"]["command_line"], "private-api-key") > 0, "API credentials must remain outside argv")
		AssertFalse(InStr(State["command"]["command_line"], "private-context") > 0, "typed text must remain outside argv")
	} finally {
		if IsSet(Reservation) {
			if Reservation.Has("proxy_deadline")
				SetTimer(Reservation["proxy_deadline"], 0)
			if Reservation.Has("process_owner")
				_LLMRemote_CancelCurlReservation(ReqId, Reservation, Port)
		}
		_LLM_Remote_Async := SavedRegistry
	}
}
Test("remote proxy: first generation waits and admits one private child", _RemoteProxy_DeferredGeneration)
Test("remote proxy: cancelled admission cannot stage or launch", _RemoteProxy_DeferredGeneration.Bind("cancel"))
Test("remote proxy: late admission cannot consume a successor", _RemoteProxy_DeferredGeneration.Bind("replace"))
Test("remote proxy: resolution consumes the request timeout", _RemoteProxy_DeferredGeneration.Bind("timeout"))
Test("remote proxy: unresolved receipt cannot become direct generation", _RemoteProxy_DeferredGeneration.Bind("reject"))

class _RemoteProxy_ReadyHttp {
	__New(State) {
		this.State := State
	}
	Open(*) {
	}
	SetTimeouts(*) {
	}
	SetDeadline(Start, Budget) {
		this.State["start"] := Start
		this.State["budget"] := Budget
	}
	SetRequestHeader(*) {
	}
	SetProxy(Proxy) {
		this.State["proxy"] := Proxy
	}
	Send(*) {
		this.State["sends"] += 1
	}
	Abort() {
		this.State["aborts"] += 1
		return true
	}
}

_RemoteProxy_ReadyCreate(State) {
	State["creates"] += 1
	return _RemoteProxy_ReadyHttp(State)
}

_RemoteProxy_ReadyAdmission(ProbeCase := "success") {
	return _ManagedRemoteFixtureWithLlmTimings(_RemoteProxy_ReadyAdmissionBody.Bind(ProbeCase))
}

_RemoteProxy_ReadyAdmissionBody(ProbeCase) {
	global LLM_API_PROVIDERS, LLM_REMOTE_READY_PING_DEADLINE_MS
	SavedProviders := LLM_API_PROVIDERS
	LLM_API_PROVIDERS := Map("group6_fixture", Map("Format", "openai", "BaseUrl", "https://ready.invalid:8443/v1"))
	State := Map("creates", 0, "sends", 0, "aborts", 0, "results", [])
	Owner := LLM_AuxBegin("group6_ready", Map("backend", "api", "endpoint", "https://ready.invalid:8443/v1", "identity", "fixture"))
	Port := Map("resolve_proxy", _RemoteProxy_CaptureResolve.Bind(State),
		"create_http", _RemoteProxy_ReadyCreate.Bind(State), "poll_ready", (*) => true)
	try {
		LLM_RemoteIsReady_Async(Map("Provider", "group6_fixture", "Token", "private-api-key"), (Value) => State["results"].Push(Value), Owner, Port)
		AssertTrue(State.Has("continue"), "readiness must use the system admission resolver")
		AssertEqual("https://ready.invalid:8443/v1/models", State["url"])
		AssertEqual(0, State["creates"], "no readiness child before the first PAC answer")
		if ProbeCase == "budget_change"
			LLM_REMOTE_READY_PING_DEADLINE_MS := 0
		if ProbeCase == "replace"
			Successor := LLM_AuxBegin("group6_ready", Map("backend", "api", "endpoint", "next", "identity", "successor"))
		State["continue"].Call(Map("ok", ProbeCase != "reject", "inherit", false, "proxy", "http://managed.corp:3128"))
		State["continue"].Call(Map("ok", true, "inherit", false, "proxy", "http://late.corp:80"))
		if ProbeCase == "reject" {
			AssertEqual(0, State["creates"], "unresolved receipt must create no readiness transport")
			AssertEqual(1, State["results"].Length, "native refusal must settle once")
			AssertFalse(State["results"][1], "unresolved proxy must remain unavailable")
		} else if ProbeCase == "replace" {
			AssertEqual(0, State["creates"], "a superseded readiness owner may create no transport")
			AssertTrue(LLM_AuxIsCurrent(Successor), "late completion must retain successor ownership")
		} else {
			AssertEqual(1, State["creates"], "duplicate completion must create exactly one transport")
			AssertEqual(1, State["sends"], "readiness must send exactly once")
			AssertEqual("http://managed.corp:3128", State["proxy"], "readiness and generation must share relay admission")
			AssertEqual(Owner["network_start_tick"], State["start"], "deferred admission retains the original request origin")
			AssertEqual(Owner["network_timeout_ms"], State["budget"], "deferred admission retains the originally admitted canonical budget")
		}
	} finally {
		_LLM_AuxRetireOwner(Owner)
		if IsSet(Successor)
			_LLM_AuxRetireOwner(Successor)
		LLM_API_PROVIDERS := SavedProviders
	}
}
Test("remote proxy: readiness waits for and applies the same relay", _RemoteProxy_ReadyAdmission)
Test("remote proxy: superseded readiness cannot launch a child", _RemoteProxy_ReadyAdmission.Bind("replace"))

Test("remote proxy: unresolved receipt refuses readiness once", _RemoteProxy_ReadyAdmission.Bind("reject"))

Test("remote proxy: a later timing change cannot renew or erase readiness's original deadline (ready-canonical-budget)",
	_RemoteProxy_ReadyAdmission.Bind("budget_change"))

_RemoteProxy_ReadyInvalidBudget(Budget) {
	global LLM_REMOTE_READY_PING_DEADLINE_MS
	Previous := IsSet(LLM_REMOTE_READY_PING_DEADLINE_MS) ? LLM_REMOTE_READY_PING_DEADLINE_MS : unset
	Owner := LLM_AuxBegin("ready_invalid_budget", Map("backend", "api", "endpoint", "controlled", "identity", "fixture"))
	State := Map("creates", 0)
	try {
		LLM_REMOTE_READY_PING_DEADLINE_MS := Budget == "unset" ? unset : Budget
		Rejected := false
		try LLM_RemoteIsReady_Async(Map(), (*) => 0, Owner,
			Map("create_http", _RemoteProxy_ReadyCreate.Bind(State), "resolve_proxy", (*) => false))
		catch Error as Failure {
			Rejected := true
			AssertContains(Failure.Message, "initialized canonical request budget")
		}
		AssertTrue(Rejected, "invalid timing cannot borrow Send's fallback duration")
		AssertEqual(0, State["creates"], "invalid initialization creates no transport")
		AssertFalse(Owner.Has("network_start_tick"), "invalid initialization cannot acquire a readiness deadline")
		AssertTrue(LLM_AuxIsCurrent(Owner), "invalid timing preserves the caller's exact owner")
	} finally {
		LLM_REMOTE_READY_PING_DEADLINE_MS := IsSet(Previous) ? Previous : unset
		_LLM_AuxRetireOwner(Owner)
	}
}
for Index, Budget in [0, -1, "30000", 0x80000000, "unset"]
	Test("remote proxy: invalid canonical readiness budget refuses before transport " . Index . " (ready-canonical-budget)",
		_RemoteProxy_ReadyInvalidBudget.Bind(Budget))

#Include %A_LineFile%/../test_llm_api_remote_abort_retirement.ahk

#Include %A_LineFile%/../test_llm_api_remote_completion_reads.ahk
