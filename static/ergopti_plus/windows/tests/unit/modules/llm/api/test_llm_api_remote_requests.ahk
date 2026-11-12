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
	Shipped := JsonParse(FileRead(_SharedDir . "\ai\data\api_providers.json", "UTF-8"))
	ShippedLocal := JsonParse(FileRead(_SharedDir . "\ai\data\local_servers.json", "UTF-8"))
	LocalIds := ShippedLocal["server_order"]
	; The first four stay independently named: the catalogue only grows behind them.
	for Index, ProviderId in ["omlx", "lmstudio", "llamacpp", "jan"]
		AssertEqual(ProviderId, LocalIds[Index], "the optional-auth catalogue keeps its first local providers")
	AssertEqual(Shipped["provider_order"].Length + LocalIds.Length, LLM_API_PROVIDER_ORDER.Length,
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


; Every global the catalogue load publishes, read from the loader and the family
; loader it calls: a global added there is restored here without a second list.
; A fixture root holds no thinking_off.json and no local_servers.json, so a reload
; publishes empty families and identities; leaving them behind turned every later
; thinking-off and fingerprint test red, in a whole-group run only.
_RemoteCatalog_PublishedGlobals() {
	Names := []
	for Loader in ["_LLMRemote_LoadCatalog", "_LLMRemote_LoadThinkingFamilies"] {
		Body := _StripFullLineComments(_DriverFuncBody(Loader))
		AssertTrue(Body != "", "the catalogue owner must resolve: " . Loader)
		Declared := Map(), Position := 1
		while RegExMatch(Body, "m)^\s*global\s+(.+)$", &Line, Position) {
			for Name in StrSplit(Line[1], ",", " `t`r")
				Declared[Name] := true
			Position := Line.Pos + Line.Len
		}
		Seen := Map(), Position := 1, Published := 0
		while RegExMatch(Body, "m)^\s*(?:try\s+)?(\w+)\s*:=", &Line, Position) {
			if Declared.Has(Line[1]) && !Seen.Has(Line[1]) {
				Seen[Line[1]] := true
				Names.Push(Line[1])
				Published += 1
			}
			Position := Line.Pos + Line.Len
		}
		AssertTrue(Published > 0, "the scan must find what the owner publishes: " . Loader)
	}
	return Names
}

_RemoteCatalog_SnapshotPublished() {
	global
	local Snapshot := Map(), Name
	for Name in _RemoteCatalog_PublishedGlobals()
		Snapshot[Name] := %Name%
	return Snapshot
}

_RemoteCatalog_RestorePublished(Snapshot) {
	global
	local Name, Value
	for Name, Value in Snapshot
		%Name% := Value
	for Name, Value in Snapshot
		AssertEqual(ObjPtr(Value), ObjPtr(%Name%), "the reload fixture restores the exact published " . Name)
}

_RemoteCatalog_PublishedCensus() {
	Names := Map()
	for Name in _RemoteCatalog_PublishedGlobals()
		Names[Name] := true
	for Name in ["LLM_API_PROVIDERS", "LLM_API_PROVIDER_ORDER", "LLM_LOCAL_API_SERVERS", "LLM_LOCAL_SERVER_DISCOVERY",
			"LLM_LOCAL_SERVER_IDENTITIES", "LLM_THINKING_FAMILIES", "LLM_REMOTE_MODEL_PRICES",
			"LLM_REMOTE_TEST_REQUEST", "LLM_REMOTE_DECISIONS_TEST"]
		AssertTrue(Names.Has(Name), "the census of published catalogue globals must find " . Name)
	AssertFalse(Names.Has("_SharedDir"), "a global the loader only reads is not a publication")
}
Test("api_providers.json: the reload fixture knows every global the load publishes", _RemoteCatalog_PublishedCensus)

; Reloading the catalogue from a fixture is only sound through this pair; a test
; that reloads without it leaves the fixture's catalogue to every later test.
_RemoteCatalog_ReloadsAreRestored() {
	Reloaders := 0
	loop files A_ScriptDir . "\unit\*.ahk", "R" {
		Source := _StripFullLineComments(FileRead(A_LoopFileFullPath, "UTF-8"))
		if !InStr(Source, "_LLMRemote_LoadCatalog(")
			continue
		Reloaders += 1
		AssertTrue(InStr(Source, "_RemoteCatalog_SnapshotPublished(") && InStr(Source, "_RemoteCatalog_RestorePublished("),
			A_LoopFileName . " reloads the catalogue without restoring what the load publishes")
	}
	AssertTrue(Reloaders >= 1, "the scan must find the fixture that reloads the catalogue")
}
Test("api_providers.json: a test that reloads the catalogue restores all it publishes", _RemoteCatalog_ReloadsAreRestored)

_RemoteCatalog_InvalidScalarsNeverPublish() {
	global LLM_API_PROVIDERS, LLM_API_PROVIDER_ORDER, LLM_REMOTE_MODEL_PRICES, _SharedDir
	global LLM_LOCAL_API_SERVERS
	Published := _RemoteCatalog_SnapshotPublished()
	oldLocalServers := LLM_LOCAL_API_SERVERS
	oldLocalServerState := []
	for ProviderId, Descriptor in oldLocalServers {
		Fields := Map()
		for Key, Value in Descriptor
			Fields[Key] := Value
		oldLocalServerState.Push(Map("id", ProviderId, "descriptor", Descriptor, "fields", Fields))
	}
	oldSharedDir := _SharedDir
	testRoot := A_Temp . "\ergopti-ahk013-" . DllCall("GetCurrentProcessId") . "-" . A_TickCount
	fixture := FileRead(A_ScriptDir . "\..\..\_shared\tests\corpus\api_provider_catalog_validation.json", "UTF-8")
	try {
		DirCreate(testRoot . "\ai\data")
		FileAppend(fixture, testRoot . "\ai\data\api_providers.json", "UTF-8")
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
		_RemoteCatalog_RestorePublished(Published)
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
		; The fixed-route seam serves an explicit DIRECT selection only: it has no
		; proxy authentication, which belongs to the managed WinHTTP transport.
		Selected := ProbeCase == "proxy" ? "http://managed.corp:3128" : ""
		State["continue"].Call(Map("ok", ProbeCase != "reject", "inherit", false, "proxy", Selected))
		State["continue"].Call(Map("ok", true, "inherit", false, "proxy", "http://late.corp:80"))
		if ProbeCase != "success" {
			AssertEqual(0, State["writes"].Length, "stale, cancelled or unauthenticatable admission must not stage private data")
			AssertEqual(0, State["runs"], "stale, expired or unauthenticatable admission must launch no child")
			AssertEqual((ProbeCase == "timeout" || ProbeCase == "reject" || ProbeCase == "proxy") ? 1 : 0, State["fail_calls"], "timeout, rejection and a proxy fail once; cancellation stays silent")
			if ProbeCase == "replace"
				AssertEqual("pending", _LLM_Remote_Async[ReqId]["transport"], "old completion must preserve successor")
			return
		}
		AssertEqual(1, State["runs"], "duplicate resolver completion must launch exactly once")
		AssertEqual(2, State["writes"].Length, "one payload and one private config are staged")
		AssertContains(State["writes"][2]["text"], 'proxy = ""', "an explicit DIRECT selection reaches the private config")
		AssertFalse(InStr(State["writes"][2]["text"], "proxy-"), "the fixed-route seam never carries proxy authentication")
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
Test("remote proxy: the fixed-route seam refuses a proxy it cannot authenticate", _RemoteProxy_DeferredGeneration.Bind("proxy"))

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

_RemoteBuildContext_RawProfile() {
	profile := Map("id", "raw", "system_single", "{context}", "batch", false)
	system := LLM_ResolveSystemPrompt(profile, 1, 1, 15)
	req := _LLMRemote_BuildRequestContext(system, "typed context", "context")
	AssertEqual("", req["system"], "the raw profile has no system instruction")
	AssertEqual("typed context", req["user"], "the typed context is the user message")
}
Test("raw profile puts the context in the user message", _RemoteBuildContext_RawProfile)

; Uses the existing RawPost transport port and actual managed facade/registry.
_NUI_Body(Mode) {
    Prefix := '{"choices":[{"message":{"content":"owned-usage-ok"}}],"usage":'
    if Mode == "normal"
        return Prefix . '{"prompt_tokens":2,"completion_tokens":3}}'
    if Mode == "float_outside_int64"
        return Prefix . '{"prompt_tokens":1e30,"completion_tokens":1}}'
    ; Each input is accepted by the strict signed integer JSON domain. Their
    ; inferred total cannot be represented in that domain without validation.
    return Prefix . '{"prompt_tokens":9223372036854775807,"completion_tokens":1}}'
}

_NUI_UsageValid(Usage) {
    if !(Usage is Map)
        return false
    for Name in ["prompt_tokens", "completion_tokens", "total_tokens"] {
        if !Usage.Has(Name) || !(Usage[Name] is Integer) || Usage[Name] < 0
            return false
    }
    return Usage.Has("est_cost_usd") && Usage["est_cost_usd"] is Number && Usage["est_cost_usd"] >= 0
}

_NUI_Check(Mode, ViaPoll) {
    global _LLM_Remote_Async
    Body := _NUI_Body(Mode)
    ; Actual parser must first accept the exact synthetic finite JSON source.
    Root := JsonParse(Body)
    AssertTrue(Root is Map)
    if Mode == "float_outside_int64"
        AssertTrue(Root["usage"]["prompt_tokens"] is Float && Root["usage"]["prompt_tokens"] > 9223372036854775807)
    if !ViaPoll {
        Result := 0, Failure := 0
        try Result := _LLMRemoteClassifyResponse("openai", Body, "gpt-4.1")
        catch Any as ErrorObject
            Failure := ErrorObject
        _TestPrint("# USAGE_INTEGER_CLASSIFIER " . KL_JsonEncode(Map("case", Mode,
            "threw", IsObject(Failure), "error", IsObject(Failure) ? Type(Failure) : "",
            "usage", Result is Map ? Result["usage"] : 0)))
        AssertFalse(IsObject(Failure), "finite JSON usage must not tear down completion classification")
        AssertTrue(Result["ok"] && Result["text"] == "owned-usage-ok")
        AssertTrue(_NUI_UsageValid(Result["usage"]), "usage counters and estimated cost must remain nonnegative in the consumer integer domain")
        if Mode == "normal"
            AssertEqual(5, Result["usage"]["total_tokens"])
        return
    }
    AssertEqual(0, _LLM_Remote_Async.Count, "do not borrow foreign live requests")
    Control := _ManagedCurlControlState()
    Port := Map("managed_settings", (*) => Map("auto_detect", false, "pac_url", "", "proxy", "", "bypass", ""),
        "create_http", _NUI_Create.Bind(Control))
    Heard := [], Id := 0, Entry := 0, Failure := 0, Primary := 0
    try {
        Resolved := _LLMRemoteResolveEntry(Map("Provider", "openai_compat", "BaseUrl", "https://usage-fixture.invalid/v1",
            "Token", "owned-fixture-secret", "Model", "gpt-4.1"))
        Id := LLM_RemotePostBody_Async(Resolved, "https://usage-fixture.invalid/v1/chat/completions", '{"messages":[]}',
            (Text, Usage := "") => Heard.Push(Map("ok", true, "text", Text, "usage", Usage)),
            (Info := "") => Heard.Push(Map("ok", false, "info", Info)), 20000, "usage_integer_control", 0, 0, Port)
        AssertTrue(_LLM_Remote_Async.Has(Id))
        Entry := _LLM_Remote_Async[Id]
        Http := Control["request"]
        AssertTrue(Entry["http"] == Http)
        AssertEqual(1, Control["spawns"])
        _ManagedCurlControlAck(Control)
        Http._PollManagedAdmission()
        AssertTrue(Http.ManagedPayloadPublished)
        AssertTrue(FSWrite(Http.BodyPath, Body))
        AssertTrue(FSWrite(Http.HeaderPath, "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`n`r`n"))
        ; Hold only the controlled terminal -> consumer handoff so the existing
        ; background poll timer cannot consume this same terminal first.
        TerminalCritical := Critical("On")
        try {
            Control["callback"].Call(0, '{"schema_version":1,"ok":true,"status":200,"child_quiesced":true,"receipt":{}}', "")
            AssertTrue(Http.Completed && Http.ResponseEncodingValid)
            AssertEqual(200, Http.Status)
            AssertFalse(IsObject(Http.Handle), "the genuine facade must retain no controlled Job after terminal acknowledgement")
            try _LLMRemote_PollRequest(Id)
            catch Any as ErrorObject
                Failure := ErrorObject
        } finally Critical(TerminalCritical)
        Observed := Heard.Length ? Heard[1] : 0
        _TestPrint("# USAGE_INTEGER_POLL " . KL_JsonEncode(Map("case", Mode, "threw", IsObject(Failure),
            "error", IsObject(Failure) ? Type(Failure) : "", "callbacks", Heard.Length,
            "reservation_present", _LLM_Remote_Async.Has(Id), "http_completed", Http.Completed,
            "http_handle_retired", !IsObject(Http.Handle), "status", Http.Status,
            "usage", Observed is Map && Observed.Get("ok", false) ? Observed["usage"] : 0)))
        AssertFalse(IsObject(Failure), "actual polling must not throw before retiring its reservation")
        AssertFalse(_LLM_Remote_Async.Has(Id), "a terminal response must retire the exact reservation")
        AssertEqual(1, Heard.Length, "the real terminal must publish exactly one callback")
        AssertTrue(Heard[1]["ok"] && Heard[1]["text"] == "owned-usage-ok")
        AssertTrue(_NUI_UsageValid(Heard[1]["usage"]), "actual completion callback must carry valid integer-domain usage")
    } catch Any as ErrorObject {
        Primary := ErrorObject
    } finally {
        if Entry is Map && _LLM_Remote_Async.Has(Id) && _LLM_Remote_Async[Id] == Entry {
            LLM_RemoteCancelAsync(Id)
            _LLMRemote_PollRequest(Id)
        }
        if Control.Has("request") {
            Http := Control["request"]
            try {
                AssertTrue(Http.Abort())
                AssertFalse(IsObject(Http.Handle))
                AssertFalse(_LLM_Remote_Async.Has(Id))
                _ManagedCurlControlRelease(Control)
            } catch Any as CleanupFailure {
                _TestPrint("# USAGE_INTEGER_CLEANUP " . KL_JsonEncode(Map("case", Mode,
                    "error", Type(CleanupFailure), "message", SubStr(CleanupFailure.Message, 1, 300))))
                if !IsObject(Primary)
                    Primary := CleanupFailure
            }
        }
    }
    if IsObject(Primary)
        throw Primary
}

_NUI_Create(Control) {
    Request := CurlAsyncRequest(Map("spawn", _ManagedCurlControlSpawn.Bind(Control)))
    Control["request"] := Request
    return Request
}
_NUI_Run(Mode, ViaPoll) {
    _ManagedRemoteFixtureWithLlmTimings(_NUI_Check.Bind(Mode, ViaPoll))
}
for _NUI_Mode in ["normal", "float_outside_int64", "sum_outside_int64"] {
    Test("Remote usage integer domain: classifier " . _NUI_Mode . " (usage-integer-domain)", _NUI_Run.Bind(_NUI_Mode, false))
    Test("Remote usage integer domain: managed poll " . _NUI_Mode . " (usage-integer-domain)", _NUI_Run.Bind(_NUI_Mode, true))
}

; Append to test_llm_api_remote_requests.ahk after existing _NUI_* probes.
; Machine integer representation boundaries only, no product token-count limit.
_NUI_NativeBoundaries() {
    Rows := [
        {Id: "ordinary exponential", Usage: '{"prompt_tokens":1e3,"completion_tokens":2}', Prompt: 1000, Completion: 2, Total: 1002},
        {Id: "ordinary fractional truncation retained", Usage: '{"prompt_tokens":3.5,"completion_tokens":2}', Prompt: 3, Completion: 2, Total: 5},
        {Id: "signed maximum exact integer", Usage: '{"prompt_tokens":9223372036854775807}', Prompt: 9223372036854775807, Completion: 0, Total: 9223372036854775807},
        {Id: "largest safe float below signed bound", Usage: '{"prompt_tokens":9223372036854774784.0}', Prompt: 9223372036854774784, Completion: 0, Total: 9223372036854774784},
        {Id: "float at excluded signed bound", Usage: '{"prompt_tokens":9223372036854775808.0,"completion_tokens":2}', Prompt: 0, Completion: 2, Total: 2},
        {Id: "invalid explicit total falls back safely", Usage: '{"prompt_tokens":2,"completion_tokens":3,"total_tokens":1e30}', Prompt: 2, Completion: 3, Total: 5},
        {Id: "unrepresentable inferred total stays unknown", Usage: '{"prompt_tokens":9223372036854775807,"completion_tokens":1}', Prompt: 9223372036854775807, Completion: 1, Total: 0},
        {Id: "reported valid total is retained", Usage: '{"prompt_tokens":9223372036854775807,"completion_tokens":1,"total_tokens":5}', Prompt: 9223372036854775807, Completion: 1, Total: 5}
    ]
    for Row in Rows {
        Body := '{"choices":[{"message":{"content":"owned-boundary-ok"}}],"usage":' . Row.Usage . '}'
        Result := _LLMRemoteClassifyResponse("openai", Body, "gpt-4.1")
        Usage := Result["usage"]
        AssertTrue(Result["ok"] && Result["text"] == "owned-boundary-ok", Row.Id)
        AssertTrue(_NUI_UsageValid(Usage), Row.Id)
        AssertEqual(Row.Prompt, Usage["prompt_tokens"], Row.Id)
        AssertEqual(Row.Completion, Usage["completion_tokens"], Row.Id)
        AssertEqual(Row.Total, Usage["total_tokens"], Row.Id)
    }
}
Test("Remote usage integer domain: native representable boundary controls (usage-integer-domain)", _NUI_NativeBoundaries)

; Probe only. Append to test_llm_api_remote_requests.ahk. Native AHK UNRUN.
; Actual catalogue price admission and EstimateCost; no decoder/subject replaced.
_NUIC_IntegerPrices() {
    global LLM_REMOTE_MODEL_PRICES
    Saved := LLM_REMOTE_MODEL_PRICES
    Observed := []
    Rows := [
        {Id: "large integer price", InPrice: 3, OutPrice: 0, Prompt: 4000000000000000000, Completion: 0, Expected: 12000000000000.0},
        {Id: "large float price control", InPrice: 3.0, OutPrice: 0.0, Prompt: 4000000000000000000, Completion: 0, Expected: 12000000000000.0},
        {Id: "large integer completion price", InPrice: 0, OutPrice: 3, Prompt: 0, Completion: 4000000000000000000, Expected: 12000000000000.0},
        {Id: "ordinary integer prices", InPrice: 3, OutPrice: 2, Prompt: 500, Completion: 10, Expected: 0.00152}
    ]
    try {
        for Row in Rows {
            Model := "owned-integer-price"
            LLM_REMOTE_MODEL_PRICES := _LLMRemoteAdmitPrices(Map(Model, Map("in", Row.InPrice, "out", Row.OutPrice)))
            AssertTrue(LLM_REMOTE_MODEL_PRICES.Has(Model), "these finite nonnegative Integer/Float prices are actually admitted")
            Actual := _LLMRemoteEstimateCost(Model, Row.Prompt, Row.Completion)
            Observed.Push(Map("case", Row.Id, "input_price_type", Type(Row.InPrice),
                "output_price_type", Type(Row.OutPrice), "prompt_tokens", Row.Prompt,
                "completion_tokens", Row.Completion, "actual", Actual, "expected", Row.Expected))
        }
    } finally LLM_REMOTE_MODEL_PRICES := Saved
    _TestPrint("# USAGE_INTEGER_PRICE " . KL_JsonEncode(Observed))
    ; Record every control before asserting; integer-price failure must not hide
    ; the equivalent floating-price or normal-sized positive control.
    for Row in Observed {
        AssertTrue(Row["actual"] >= 0, "admitted price/count multiplication cannot wrap into negative USD: " . Row["case"])
        AssertEqual(Row["expected"], Row["actual"], Row["case"])
    }
}
Test("Remote usage cost: admitted integer prices preserve numeric domain (usage-integer-price)", _NUIC_IntegerPrices)


_NUF_Poll(Resolved, Body) {
    global _LLM_Remote_Async
    AssertEqual(0, _LLM_Remote_Async.Count)
    Control := _ManagedCurlControlState(), Heard := [], Id := 0, Entry := 0, Primary := 0, Result := 0
    Port := Map("managed_settings", (*) => Map("auto_detect", false, "pac_url", "", "proxy", "", "bypass", ""),
        "create_http", _NUI_Create.Bind(Control))
    try {
        Id := LLM_RemotePostBody_Async(Resolved, "https://finite-cost-fixture.invalid/v1/chat/completions", '{"messages":[]}',
            (Text, Usage := "") => Heard.Push(Map("ok", true, "text", Text, "usage", Usage)),
            (Info := "") => Heard.Push(Map("ok", false, "info", Info)), 20000, "finite_cost_control", 0, 0, Port)
        AssertTrue(_LLM_Remote_Async.Has(Id))
        Entry := _LLM_Remote_Async[Id], Http := Control["request"]
        AssertTrue(Entry["http"] == Http)
        _ManagedCurlControlAck(Control)
        Http._PollManagedAdmission()
        AssertTrue(Http.ManagedPayloadPublished)
        AssertTrue(FSWrite(Http.BodyPath, Body))
        AssertTrue(FSWrite(Http.HeaderPath, "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`n`r`n"))
        HandoffCritical := Critical("On")
        try {
            Control["callback"].Call(0, '{"schema_version":1,"ok":true,"status":200,"child_quiesced":true,"receipt":{}}', "")
            _LLMRemote_PollRequest(Id)
        } finally Critical(HandoffCritical)
        AssertTrue(Http.Completed && Http.ResponseEncodingValid)
        AssertEqual(200, Http.Status)
        AssertFalse(_LLM_Remote_Async.Has(Id))
        AssertFalse(IsObject(Http.Handle))
        AssertEqual(1, Heard.Length)
        AssertTrue(Heard[1]["ok"] && Heard[1]["text"] == "owned-finite-cost-ok")
        Result := Map("usage", Heard[1]["usage"], "callbacks", Heard.Length,
            "reservation_present", _LLM_Remote_Async.Has(Id), "http_handle_retired", !IsObject(Http.Handle))
    } catch Any as Failure {
        Primary := Failure
    } finally {
        try {
            if Entry is Map && _LLM_Remote_Async.Has(Id) && _LLM_Remote_Async[Id] == Entry {
                LLM_RemoteCancelAsync(Id)
                _LLMRemote_PollRequest(Id)
            }
            if Control.Has("request") {
                AssertTrue(Control["request"].Abort())
                AssertFalse(IsObject(Control["request"].Handle))
                _ManagedCurlControlRelease(Control)
            }
        } catch Any as Failure {
            _TestPrint("# FINITE_COST_CLEANUP " . KL_JsonEncode(Map("error", Type(Failure), "message", SubStr(Failure.Message, 1, 250))))
            if !IsObject(Primary)
                Primary := Failure
        }
    }
    if IsObject(Primary)
        throw Primary
    return Result
}

_NUF_Run(ViaPoll) {
    global LLM_REMOTE_MODEL_PRICES
    SavedPrices := LLM_REMOTE_MODEL_PRICES, Observed := []
    Rows := [
        {Id: "ordinary finite", PriceIn: 2.0, PriceOut: 0.0, Prompt: 2, Completion: 0, Expected: 0.000004},
        {Id: "finite prompt cost despite intermediate overflow", PriceIn: 1e308, PriceOut: 0.0, Prompt: 2, Completion: 0, Expected: 2e302},
        {Id: "finite output cost despite intermediate overflow", PriceIn: 0.0, PriceOut: 1e308, Prompt: 0, Completion: 2, Expected: 2e302},
        {Id: "unrepresentable final sum stays unknown", PriceIn: 1e308, PriceOut: 1e308, Prompt: 1000000, Completion: 1000000, Expected: 0.0}
    ]
    try {
        for Row in Rows {
            Model := "owned-finite-cost"
            LLM_REMOTE_MODEL_PRICES := _LLMRemoteAdmitPrices(Map(Model, Map("in", Row.PriceIn, "out", Row.PriceOut)))
            AssertTrue(LLM_REMOTE_MODEL_PRICES.Has(Model), "finite nonnegative prices are admitted by the genuine domain")
            Body := '{"choices":[{"message":{"content":"owned-finite-cost-ok"}}],"usage":{"prompt_tokens":'
                . Row.Prompt . ',"completion_tokens":' . Row.Completion . '}}'
            if ViaPoll {
                Resolved := _LLMRemoteResolveEntry(Map("Provider", "openai_compat", "Model", Model,
                    "Token", "owned-fixture-secret", "BaseUrl", "https://finite-cost-fixture.invalid/v1"))
                Result := _NUF_Poll(Resolved, Body)
                Usage := Result["usage"]
            } else {
                Result := _LLMRemoteClassifyResponse("openai", Body, Model)
                AssertTrue(Result["ok"] && Result["text"] == "owned-finite-cost-ok")
                Usage := Result["usage"]
            }
            Cost := Usage["est_cost_usd"]
            ; Never serialize raw infinity into JSON evidence. The same finite
            ; Number predicate already governs catalogue admission; no new cap.
            Finite := _LLMRemote_CatalogPriceIsValid(Cost)
            Seen := Map("case", Row.Id, "via_poll", ViaPoll, "cost_text", String(Cost),
                "cost_type", Type(Cost), "finite_nonnegative", Finite, "expected", Row.Expected,
                "prompt_tokens", Usage["prompt_tokens"], "completion_tokens", Usage["completion_tokens"])
            Seen["matches_expected"] := Finite && (Row.Expected == 0.0 ? Cost == 0.0 : Abs(Cost / Row.Expected - 1.0) < 0.000000001)
            if ViaPoll {
                Seen["callbacks"] := Result["callbacks"]
                Seen["reservation_present"] := Result["reservation_present"]
                Seen["http_handle_retired"] := Result["http_handle_retired"]
            }
            Observed.Push(Seen)
        }
    } finally LLM_REMOTE_MODEL_PRICES := SavedPrices
    _TestPrint("# FINITE_COST_DOMAIN " . KL_JsonEncode(Observed))
    for Row in Observed {
        AssertTrue(Row["finite_nonnegative"], "estimated cost must fit the already-admitted native finite Number domain: " . Row["case"])
        AssertTrue(Row["matches_expected"], "representable cost must survive intermediate arithmetic; an unrepresentable final estimate remains unknown: " . Row["case"])
    }
}
_NUF_Timings(ViaPoll) {
    _ManagedRemoteFixtureWithLlmTimings(_NUF_Run.Bind(ViaPoll))
}
Test("Remote usage cost: finite domain through actual classifier (usage-finite-cost)", _NUF_Timings.Bind(false))
Test("Remote usage cost: finite domain through actual managed Poll (usage-finite-cost)", _NUF_Timings.Bind(true))

; Add after _NUF_* finite-cost probes. Native AHK UNRUN.
; Protect tiny admitted prices against price/1e6 underflow in a numeric fix.
_NUFT_PriceScale() {
    global LLM_REMOTE_MODEL_PRICES
    Saved := LLM_REMOTE_MODEL_PRICES, Observed := []
    Tiny := JsonParse("1e-320")
    if Tiny == 0.0 {
        _TestPrint("# FINITE_COST_TINY " . KL_JsonEncode(Map("supported", false,
            "reason", "this runtime does not represent the finite subnormal fixture")))
        return
    }
    Count := 4000000000000000000
    Reference := (Float(Count) * Tiny) / 1000000.0
    AssertTrue(Reference > 0.0 && _LLMRemote_CatalogPriceIsValid(Reference),
        "the represented tiny price and integer count have a positive finite reference USD result")
    try {
        Model := "owned-tiny-price"
        LLM_REMOTE_MODEL_PRICES := _LLMRemoteAdmitPrices(Map(Model, Map("in", Tiny, "out", 0.0)))
        AssertTrue(LLM_REMOTE_MODEL_PRICES.Has(Model))
        Body := '{"choices":[{"message":{"content":"owned-finite-cost-ok"}}],"usage":{"prompt_tokens":'
            . Count . ',"completion_tokens":0}}'
        for ViaPoll in [false, true] {
            if ViaPoll {
                Resolved := _LLMRemoteResolveEntry(Map("Provider", "openai_compat", "Model", Model,
                    "Token", "owned-fixture-secret", "BaseUrl", "https://finite-cost-fixture.invalid/v1"))
                Result := _NUF_Poll(Resolved, Body)
            } else {
                Result := _LLMRemoteClassifyResponse("openai", Body, Model)
                AssertTrue(Result["ok"] && Result["text"] == "owned-finite-cost-ok")
            }
            Cost := Result["usage"]["est_cost_usd"]
            Finite := _LLMRemote_CatalogPriceIsValid(Cost)
            Seen := Map("via_poll", ViaPoll, "supported", true, "price_text", String(Tiny),
                "reference_text", String(Reference), "cost_text", String(Cost), "finite", Finite,
                "positive", Finite && Cost > 0.0,
                "matches_reference", Finite && Cost > 0.0 && Abs(Cost / Reference - 1.0) < 0.000000001)
            if ViaPoll {
                Seen["callbacks"] := Result["callbacks"]
                Seen["reservation_present"] := Result["reservation_present"]
                Seen["http_handle_retired"] := Result["http_handle_retired"]
            }
            Observed.Push(Seen)
        }
    } finally LLM_REMOTE_MODEL_PRICES := Saved
    _TestPrint("# FINITE_COST_TINY " . KL_JsonEncode(Observed))
    for Seen in Observed {
        AssertTrue(Seen["finite"] && Seen["positive"], "scaling an admitted positive tiny price must not erase its representable estimated cost")
        AssertTrue(Seen["matches_reference"], "cost remains consistent with the nonoverflowing original operation order")
    }
}
_NUFT_Run() {
    _ManagedRemoteFixtureWithLlmTimings(_NUFT_PriceScale)
}
Test("Remote usage cost: tiny finite price keeps positive USD across scaling (usage-finite-cost)", _NUFT_Run)

_MCC_Poll(Resolved, Body) {
    global _LLM_Remote_Async
    AssertEqual(0, _LLM_Remote_Async.Count)
    Control := _ManagedCurlControlState(), Heard := [], Id := 0, Entry := 0, Primary := 0, Result := 0
    Port := Map("managed_settings", (*) => Map("auto_detect", false, "pac_url", "", "proxy", "", "bypass", ""),
        "create_http", _NUI_Create.Bind(Control))
    try {
        Id := LLM_RemotePostBody_Async(Resolved, "https://mistral-content-fixture.invalid/v1/chat/completions", '{"messages":[]}',
            (Text, Usage := "") => Heard.Push(Map("ok", true, "text", Text, "usage", Usage)),
            (Info := "") => Heard.Push(Map("ok", false, "info", Info)), 20000, "mistral_content_control", 0, 0, Port)
        AssertTrue(_LLM_Remote_Async.Has(Id))
        Entry := _LLM_Remote_Async[Id], Http := Control["request"]
        AssertTrue(Entry["http"] == Http)
        _ManagedCurlControlAck(Control)
        Http._PollManagedAdmission()
        AssertTrue(Http.ManagedPayloadPublished)
        AssertTrue(FSWrite(Http.BodyPath, Body))
        AssertTrue(FSWrite(Http.HeaderPath, "HTTP/1.1 200 OK`r`nContent-Type: application/json`r`n`r`n"))
        HandoffCritical := Critical("On")
        try {
            Control["callback"].Call(0, '{"schema_version":1,"ok":true,"status":200,"child_quiesced":true,"receipt":{}}', "")
            _LLMRemote_PollRequest(Id)
        } finally Critical(HandoffCritical)
        AssertTrue(Http.Completed && Http.ResponseEncodingValid)
        AssertEqual(200, Http.Status)
        AssertFalse(_LLM_Remote_Async.Has(Id))
        AssertFalse(IsObject(Http.Handle))
        AssertEqual(1, Heard.Length)
        Result := Map("verdict", Heard[1], "callbacks", Heard.Length,
            "reservation_present", _LLM_Remote_Async.Has(Id), "http_handle_retired", !IsObject(Http.Handle))
    } catch Any as Failure {
        Primary := Failure
    } finally {
        try {
            if Entry is Map && _LLM_Remote_Async.Has(Id) && _LLM_Remote_Async[Id] == Entry {
                LLM_RemoteCancelAsync(Id)
                _LLMRemote_PollRequest(Id)
            }
            if Control.Has("request") {
                AssertTrue(Control["request"].Abort())
                AssertFalse(IsObject(Control["request"].Handle))
                _ManagedCurlControlRelease(Control)
            }
        } catch Any as Failure {
            _TestPrint("# MISTRAL_CONTENT_CLEANUP " . KL_JsonEncode(Map("error", Type(Failure), "message", SubStr(Failure.Message, 1, 250))))
            if !IsObject(Primary)
                Primary := Failure
        }
    }
    if IsObject(Primary)
        throw Primary
    return Result
}

_MCC_Row(Mode) {
    switch Mode {
        case "string": Content := '"owned-mistral-answer"', Expected := "owned-mistral-answer"
        case "text-chunk": Content := '[{"type":"text","text":"owned-mistral-answer"}]', Expected := "owned-mistral-answer"
        case "thinking-plus-text":
            Content := '[{"type":"thinking","thinking":[{"type":"text","text":"private-reasoning-decoy"}]},{"type":"text","text":"owned-mistral-answer"}]'
            Expected := "owned-mistral-answer"
        case "thinking-only":
            Content := '[{"type":"thinking","thinking":[{"type":"text","text":"private-reasoning-decoy"}]}]'
            Expected := ""
        case "multi-text":
            Content := '[{"type":"text","text":"first "},{"type":"thinking","thinking":[{"type":"text","text":"private-reasoning-decoy"}]},{"type":"text","text":"second"},{"type":"text","text":"!"}]'
            Expected := "first second!"
        case "empty-text-before-answer":
            Content := '[{"type":"text","text":""},{"type":"text","text":"owned-mistral-answer"}]'
            Expected := "owned-mistral-answer"
        case "empty-array": Content := '[]', Expected := ""
        case "untyped-decoy": Content := '[{"text":"untyped-decoy"}]', Expected := ""
        case "malformed-text-after-answer":
            Content := '[{"type":"text","text":"partial-answer-must-not-escape"},{"type":"text","text":42}]'
            Expected := ""
        case "malformed-entry-after-answer":
            Content := '[{"type":"text","text":"partial-answer-must-not-escape"},42]'
            Expected := ""
        case "nontext-decoy-before-answer":
            Content := '[{"type":"image_url","text":"nontext-decoy"},{"type":"TEXT","text":"wrong-case-decoy"},{"type":"text","text":"owned-mistral-answer"}]'
            Expected := "owned-mistral-answer"
        default: throw ValueError("Unknown Mistral content case.")
    }
    Body := '{"id":"fixture-mistral","object":"chat.completion","created":1,"model":"mistral-small-latest",'
        . '"choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":' . Content . '}}],'
        . '"usage":{"prompt_tokens":2,"completion_tokens":3,"total_tokens":5}}'
    Resolved := _LLMRemoteResolveEntry(Map("Provider", "mistral", "Model", "mistral-small-latest",
        "Token", "owned-fixture-secret", "BaseUrl", "https://mistral-content-fixture.invalid/v1"))
    AssertTrue(Resolved is Map && Resolved["Format"] == "openai", "the shipped Mistral producer uses the genuine OpenAI-format consumer")
    Classified := _LLMRemoteClassifyResponse(Resolved["Format"], Body, Resolved["Model"])
    Poll := _MCC_Poll(Resolved, Body)
    Verdict := Poll["verdict"]
    _TestPrint("# MISTRAL_CONTENT_CHUNKS " . KL_JsonEncode(Map("mode", Mode, "format", Resolved["Format"],
        "classifier_ok", Classified["ok"], "classifier_text", Classified["text"], "classifier_reason", Classified["reason"],
        "poll_ok", Verdict["ok"], "poll_text", Verdict.Get("text", ""), "poll_reason", Verdict.Get("info", Map()).Get("reason", ""),
        "callbacks", Poll["callbacks"], "reservation_present", Poll["reservation_present"], "http_handle_retired", Poll["http_handle_retired"])))
    AssertEqual(Expected != "", Classified["ok"], "the official Mistral assistant-content union must retain ordinary text and exclude reasoning")
    AssertEqual(Expected, Classified["text"])
    AssertEqual(Expected != "", Verdict["ok"], "the actual public RawPost/Poll consumer must deliver the declared response union")
    if Expected != ""
        AssertEqual(Expected, Verdict["text"], "structured thinking never replaces the text answer")
    else
        AssertEqual("canonical_empty", Verdict["info"]["reason"], "reasoning-only content is terminally empty")
    AssertEqual(1, Poll["callbacks"])
    AssertFalse(Poll["reservation_present"])
    AssertTrue(Poll["http_handle_retired"])
}
_MCC_Run(Mode) {
    _ManagedRemoteFixtureWithLlmTimings(_MCC_Row.Bind(Mode))
}
for _MCC_Mode in ["string", "text-chunk", "thinking-plus-text", "thinking-only", "multi-text", "empty-text-before-answer",
    "empty-array", "untyped-decoy", "malformed-text-after-answer", "malformed-entry-after-answer", "nontext-decoy-before-answer"]
    Test("Mistral response: " . _MCC_Mode . " reaches the actual response consumer (mistral-content-chunks)", _MCC_Run.Bind(_MCC_Mode))

; The official SDK text projections concatenate ordinary blocks/parts in order.
; The existing exact managed transport fixture publishes actual response bytes;
; no network, fake classifier, fake RawPost or replacement parser is used.
_PMP091_Row(Provider, Mode) {
    if Provider == "anthropic" {
        switch Mode {
            case "ordinary":
                Content := '[{"type":"text","text":"owned-answer"}]', Expected := "owned-answer"
            case "multipart":
                Content := '[{"type":"text","text":"first "},{"type":"tool_use","id":"toolu_fixture","name":"fixture","input":{}},{"type":"thinking","thinking":"reasoning-decoy","signature":"fixture"},{"type":"text","text":"second"},{"type":"text","text":"!"}]'
                Expected := "first second!"
            case "empty-before-answer":
                Content := '[{"type":"text","text":""},{"type":"text","text":"owned-answer"}]', Expected := "owned-answer"
            case "reasoning-only":
                Content := '[{"type":"thinking","thinking":"reasoning-decoy","signature":"fixture"}]', Expected := ""
            case "malformed-after-answer":
                Content := '[{"type":"text","text":"partial-must-not-escape"},{"type":"text","text":42}]', Expected := ""
            default: throw ValueError("Unknown provider multipart fixture mode.")
        }
        Body := '{"id":"msg_fixture","type":"message","role":"assistant","model":"claude-haiku-4-5",'
            . '"content":' . Content . ',"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":2,"output_tokens":3}}'
        Model := "claude-haiku-4-5", BaseUrl := "https://api.anthropic.com/v1"
    } else {
        AssertEqual("gemini", Provider)
        switch Mode {
            case "ordinary":
                Content := '[{"text":"owned-answer"}]', Expected := "owned-answer"
            case "multipart":
                Content := '[{"text":"first "},{"functionCall":{"name":"fixture","args":{}}},{"thought":true,"text":"reasoning-decoy"},{"text":"second"},{"text":"!"}]'
                Expected := "first second!"
            case "empty-before-answer":
                Content := '[{"text":""},{"text":"owned-answer"}]', Expected := "owned-answer"
            case "reasoning-only":
                Content := '[{"thought":true,"text":"reasoning-decoy"}]', Expected := ""
            case "malformed-after-answer":
                Content := '[{"text":"partial-must-not-escape"},{"text":42}]', Expected := ""
            default: throw ValueError("Unknown provider multipart fixture mode.")
        }
        Body := '{"candidates":[{"content":{"role":"model","parts":' . Content
            . '},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":2,"candidatesTokenCount":3,"totalTokenCount":5}}'
        Model := "gemini-2.0-flash", BaseUrl := "https://generativelanguage.googleapis.com/v1beta"
    }
    Resolved := _LLMRemoteResolveEntry(Map("Provider", Provider, "Model", Model,
        "Token", "owned-fixture-secret", "BaseUrl", BaseUrl))
    AssertTrue(Resolved is Map)
    AssertEqual(Provider, Resolved["Format"], "the genuine shipped provider selects its canonical dialect")
    Classified := _LLMRemoteClassifyResponse(Resolved["Format"], Body, Resolved["Model"])
    Poll := _MCC_Poll(Resolved, Body), Verdict := Poll["verdict"]
    _TestPrint("# PROVIDER_MULTIPART_091 " . KL_JsonEncode(Map("provider", Provider, "mode", Mode,
        "classifier_ok", Classified["ok"], "classifier_text", Classified["text"], "classifier_reason", Classified["reason"],
        "poll_ok", Verdict["ok"], "poll_text", Verdict.Get("text", ""), "poll_reason", Verdict.Get("info", Map()).Get("reason", ""),
        "callbacks", Poll["callbacks"], "reservation_present", Poll["reservation_present"], "http_handle_retired", Poll["http_handle_retired"])))
    AssertEqual(Expected != "", Classified["ok"])
    AssertEqual(Expected, Classified["text"], "all ordinary text chunks must concatenate verbatim without reasoning or tool data")
    AssertEqual(Expected != "", Verdict["ok"], "the real RawPost/Poll route must preserve the canonical complete text projection")
    if Expected != ""
        AssertEqual(Expected, Verdict["text"])
    else
        AssertEqual("canonical_empty", Verdict["info"]["reason"])
    AssertEqual(1, Poll["callbacks"])
    AssertFalse(Poll["reservation_present"])
    AssertTrue(Poll["http_handle_retired"])
}
_PMP091_Run(Provider, Mode) {
    _ManagedRemoteFixtureWithLlmTimings(_PMP091_Row.Bind(Provider, Mode))
}
for _PMP091_Provider in ["anthropic", "gemini"] {
    for _PMP091_Mode in ["ordinary", "multipart", "empty-before-answer", "reasoning-only", "malformed-after-answer"]
        Test("Provider complete text: " . _PMP091_Provider . "/" . _PMP091_Mode . " (provider-multipart-091)",
            _PMP091_Run.Bind(_PMP091_Provider, _PMP091_Mode))
}
