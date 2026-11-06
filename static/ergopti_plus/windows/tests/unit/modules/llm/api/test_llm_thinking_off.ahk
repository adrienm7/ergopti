; static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_thinking_off.ahk

; ==============================================================================
; MODULE: Thinking Off In Every Windows Cloud Request
; DESCRIPTION:
; Replays _shared/tests/corpus/llm/thinking_off_vectors.json, which the shared
; Lua resolver (macOS, Linux) replays too, through the AutoHotkey port
; (_shared/modules/llm/thinking_off.ahk), the families the driver loaded from
; thinking_off.json and the dialects it loaded from api_providers.json. Then
; pins both request paths: the prediction payload (LLM_RemoteGenerate_Async)
; and the bodies the screen reading and the AI agent write whole
; (_LLM_Vision_Send), with the HTTP 400 refusal of an added field.
;
; ROOT CAUSE ENCODED:
; Only Cerebras' default model had its reasoning turned off, in OpenAI-shape
; prediction bodies only: a Claude 5, Gemini 2.5 or gpt-5.x model spent the
; small budget thinking, and the screen reading carried no rule at all.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================================
; ===============================================
; ======= 1/ Shared corpus (thinking_off) =======
; ===============================================
; ===============================================

_LTO_CorpusText() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\llm\thinking_off_vectors.json"
	AssertTrue(FileExist(Path) != "", "the thinking_off corpus must exist at " . Path)
	return FileRead(Path, "UTF-8")
}

; The vectors of one corpus section, each Map("value", decoded, "text", source).
_LTO_Vectors(Section) {
	Text := _LTO_CorpusText()
	Vectors := []
	for Span in JsonArrayElementSpans(JsonObjectMemberSpans(Text)[Section]["text"])
		Vectors.Push(Map("value", Span["value"], "text", Span["text"]))
	return Vectors
}

; The exact JSON source of one member of a vector.
_LTO_Member(Vector, Name) {
	return JsonObjectMemberSpans(Vector["text"])[Name]["text"]
}

; Sorted dotted form of added paths, for an order-free comparison.
_LTO_Paths(Added) {
	Out := []
	for Path in Added {
		Dotted := ""
		for Name in Path
			Dotted .= (Dotted == "" ? "" : ".") . Name
		Out.Push(Dotted)
	}
	; Insertion sort: a handful of paths
	loop Out.Length {
		I := A_Index
		while (I > 1 && StrCompare(Out[I - 1], Out[I], true) > 0) {
			Swap := Out[I], Out[I] := Out[I - 1], Out[I - 1] := Swap
			I -= 1
		}
	}
	Joined := ""
	for Dotted in Out
		Joined .= (Joined == "" ? "" : ",") . Dotted
	return Joined
}

; The refused names of a vector as a Map.
_LTO_Set(List) {
	Out := Map()
	for Name in List
		Out[Name] := true
	return Out
}

_LTO_NormalizeVectors() {
	Checked := 0
	for Vector in _LTO_Vectors("normalize_vectors") {
		V := Vector["value"]
		AssertEqual(V["normalized"], LLM_ThinkingOffNormalize(V["model"]), V["model"])
		Checked += 1
	}
	AssertTrue(Checked >= 5, "expected at least 5 normalize vectors, found " . Checked)
}
Test("LLM thinking off: model ids normalize as the shared corpus says (thinking-off-everywhere)", _LTO_NormalizeVectors)

_LTO_GlobVectors() {
	Checked := 0
	for Vector in _LTO_Vectors("glob_vectors") {
		V := Vector["value"]
		AssertEqual(V["match"] ? 1 : 0, LLM_ThinkingOffMatches(V["glob"], V["model"]) ? 1 : 0,
			V["glob"] . " / " . V["model"])
		Checked += 1
	}
	AssertTrue(Checked >= 15, "expected at least 15 glob vectors, found " . Checked)
}
Test("LLM thinking off: glob matching replays the shared corpus (thinking-off-everywhere)", _LTO_GlobVectors)

_LTO_MergeVectors() {
	Checked := 0
	for Vector in _LTO_Vectors("merge_vectors") {
		V := Vector["value"]
		Merged := LLM_ThinkingOffMerge(_LTO_Member(Vector, "body"), _LTO_Member(Vector, "fields"), &Added)
		AssertEqual("", _LVS_DeepEqual(JsonParse(Merged), V["expected"]), V["id"])
		AssertEqual(_LTO_Paths(V["added"]), _LTO_Paths(Added), V["id"] . ": added paths")
		Checked += 1
	}
	AssertTrue(Checked >= 8, "expected at least 8 merge vectors, found " . Checked)
}
Test("LLM thinking off: the deep merge replays the shared corpus (thinking-off-everywhere)", _LTO_MergeVectors)

_LTO_BooleanKeepsItsSource() {
	; JsonParse decodes false as 0: only the text proves the literal survives
	Merged := LLM_ThinkingOffMerge('{"model":"m"}', '{"reasoning":{"enabled":false}}')
	AssertContains(Merged, '"reasoning":{"enabled":false}')
}
Test("LLM thinking off: a boolean field is sent as the JSON literal", _LTO_BooleanKeepsItsSource)

_LTO_ResolveVectors() {
	global LLM_API_PROVIDERS, LLM_THINKING_FAMILIES
	AssertTrue(LLM_THINKING_FAMILIES.Length > 0, "the driver loaded thinking_off.json")
	Checked := 0
	for Vector in _LTO_Vectors("resolve_vectors") {
		V := Vector["value"]
		AssertTrue(LLM_API_PROVIDERS.Has(V["provider"]), V["id"] . ": the driver loaded the provider")
		Body := LLM_ThinkingOffApply(LLM_THINKING_FAMILIES, LLM_API_PROVIDERS[V["provider"]]["ThinkingDialect"],
			V["model"], _LTO_Member(Vector, "body"), "", &Family, &Kind, &Added)
		AssertEqual(V.Get("family", 0), Family, V["id"] . ": family")
		AssertEqual(V.Get("kind", ""), Kind, V["id"] . ": kind")
		AssertEqual(_LTO_Paths(V["added"]), _LTO_Paths(Added), V["id"] . ": added paths")
		AssertEqual("", _LVS_DeepEqual(JsonParse(Body), V["expected"]), V["id"])
		Checked += 1
	}
	AssertTrue(Checked >= 40, "expected at least 40 resolve vectors, found " . Checked)
}
Test("LLM thinking off: every family through every dialect replays the shared corpus (thinking-off-everywhere)",
	_LTO_ResolveVectors)

_LTO_RefusalVectors() {
	global LLM_API_PROVIDERS, LLM_THINKING_FAMILIES
	Checked := 0
	for Vector in _LTO_Vectors("refusal_vectors") {
		V := Vector["value"]
		Body := LLM_ThinkingOffApply(LLM_THINKING_FAMILIES, LLM_API_PROVIDERS[V["provider"]]["ThinkingDialect"],
			V["model"], _LTO_Member(Vector, "body"), "", , , &Added)
		Field := LLM_ThinkingOffRefusedField(V["status"], V["message"], Added)
		AssertEqual(V.Get("field", ""), Field, V["id"] . ": refused field")
		if (Field != "")
			Body := LLM_ThinkingOffStrip(Body, Added, Field)
		AssertEqual("", _LVS_DeepEqual(JsonParse(Body), V["expected"]), V["id"])
		Checked += 1
	}
	for Vector in _LTO_Vectors("refused_vectors") {
		V := Vector["value"]
		Body := LLM_ThinkingOffApply(LLM_THINKING_FAMILIES, LLM_API_PROVIDERS[V["provider"]]["ThinkingDialect"],
			V["model"], _LTO_Member(Vector, "body"), _LTO_Set(V["refused"]), &Family, &Kind)
		AssertEqual(V.Get("family", 0), Family, V["id"] . ": family")
		AssertEqual(V.Get("kind", ""), Kind, V["id"] . ": kind")
		AssertEqual("", _LVS_DeepEqual(JsonParse(Body), V["expected"]), V["id"])
		Checked += 1
	}
	AssertTrue(Checked >= 6, "expected at least 6 refusal vectors, found " . Checked)
}
Test("LLM thinking off: a refused field replays the shared corpus (thinking-off-everywhere)", _LTO_RefusalVectors)

_LTO_SamplingAndStoreVectors() {
	global LLM_THINKING_FAMILIES, LLM_THINKING_OFF_MAX_REFUSALS
	Checked := 0
	for Vector in _LTO_Vectors("sampling_vectors") {
		V := Vector["value"]
		AssertEqual(V["default_sampling_only"] ? 1 : 0,
			LLM_ThinkingOffDefaultSamplingOnly(LLM_THINKING_FAMILIES, V["model"]) ? 1 : 0, V["model"])
		Checked += 1
	}
	for Vector in _LTO_Vectors("refusal_store_vectors") {
		V := Vector["value"]
		Refused := LLM_ThinkingOffRefusalsParse(V["stored"], V["now"], LLM_THINKING_FAMILIES.ExpirySec, &Dropped)
		AssertEqual(V["dropped"], Dropped, V["id"] . ": dropped")
		AssertEqual("", _LVS_DeepEqual(Refused, V["refused"]), V["id"])
		Checked += 1
	}
	AssertTrue(Checked >= 12, "expected at least 12 sampling and store vectors, found " . Checked)
	Full := Map()
	loop LLM_THINKING_OFF_MAX_REFUSALS
		AssertTrue(LLM_ThinkingOffRecordRefusal(Full, "p", "m" . A_Index, "thinking", 1))
	AssertFalse(LLM_ThinkingOffRecordRefusal(Full, "p", "one-more", "thinking", 1), "a full store refuses a new pair")
	AssertTrue(LLM_ThinkingOffRecordRefusal(Full, "p", "m1", "reasoning", 1), "a known pair still records")
}
Test("LLM thinking off: default sampling and the refusal store replay the shared corpus (thinking-off-everywhere)",
	_LTO_SamplingAndStoreVectors)

_LTO_OllamaThinkVectors() {
	global LLM_THINKING_FAMILIES
	Checked := 0
	for Vector in _LTO_Vectors("ollama_think_vectors") {
		V := Vector["value"]
		AssertEqual(_LTO_Member(Vector, "think"), LLM_ThinkingOffOllamaThink(LLM_THINKING_FAMILIES, V["model"]), V["model"])
		Checked += 1
	}
	AssertTrue(Checked >= 10, "expected at least 10 Ollama think vectors, found " . Checked)
	AssertEqual("false", LLM_ThinkingOffOllamaThink([], "gpt-oss:20b"), "an unreadable table sends false")
}
Test("LLM thinking off: the Ollama think value replays the shared corpus (thinking-off-everywhere)",
	_LTO_OllamaThinkVectors)

; An empty model reached this from a prediction with none selected and failed it.
_LTO_NormalizeHasNoEmptySegment() {
	AssertEqual("", LLM_ThinkingOffNormalize(""))
	AssertEqual("", LLM_ThinkingOffNormalize("vendor/"))
	AssertEqual("qwen3", LLM_ThinkingOffNormalize("Vendor/Qwen3:4b"))
}
Test("LLM thinking off: an empty model id normalizes to nothing (thinking-off-everywhere)",
	_LTO_NormalizeHasNoEmptySegment)

_LTO_ParseVectors() {
	Checked := 0
	for Vector in _LTO_Vectors("family_parse_vectors") {
		Accepted := true
		try LLM_ThinkingOffParseFamilies(_LTO_Member(Vector, "table"))
		catch
			Accepted := false
		AssertEqual(Vector["value"]["valid"] ? 1 : 0, Accepted ? 1 : 0, Vector["value"]["id"])
		Checked += 1
	}
	for Vector in _LTO_Vectors("dialect_parse_vectors") {
		Accepted := true
		try LLM_ThinkingOffParseDialect(_LTO_Member(Vector, "dialect"))
		catch
			Accepted := false
		AssertEqual(Vector["value"]["valid"] ? 1 : 0, Accepted ? 1 : 0, "dialect " . Vector["value"]["id"])
		Checked += 1
	}
	AssertTrue(Checked >= 15, "expected at least 15 parse vectors, found " . Checked)
}
Test("LLM thinking off: a malformed table is refused whole (thinking-off-everywhere)", _LTO_ParseVectors)





; =============================================
; =============================================
; ======= 2/ Request paths ====================
; =============================================
; =============================================

; Runs Body with every provider's capability listing just read and empty.
; Turning thinking off in a request also schedules the fetch of a missing
; listing: with the process-wide cache still empty, these payload checks armed a
; real HTTP request whose owner and poll outlived them.
_LTO_WithoutListingFetch(Body) {
	global LLM_THINKING_FAMILIES, _LLM_RemoteCapabilities
	Saved := _LLM_RemoteCapabilities
	Fresh := Map()
	for Provider in LLM_THINKING_FAMILIES.Capability["providers"]
		LLM_ModelCapsFinish(Fresh, Provider, "", _LLMRemoteEpochNow())
	AssertTrue(Fresh.Count > 0, "the shared table must name the providers that publish a listing")
	_LLM_RemoteCapabilities := Fresh
	try Body.Call()
	finally _LLM_RemoteCapabilities := Saved
}

_LTO_Resolved(Provider, Model) {
	R := _LLMRemoteResolveEntry(Map("Provider", Provider, "BaseUrl", "", "Token", "sekret", "Model", Model))
	AssertTrue(R is Map, Provider . " must resolve")
	return R
}

_LTO_PredictionPayload() {
	Body := _LLMRemoteApplyThinkingOff(_LTO_Resolved("cerebras", "qwen-3.8-27b"),
		_LLMRemoteBuildPayload("openai", "qwen-3.8-27b", "s", "u", 0, 16))
	; qwen-3.8-27b reasons at xhigh effort by default and stalls tiny probes
	AssertEqual("none", JsonParse(Body)["reasoning_effort"])
	Gemini := _LLMRemoteApplyThinkingOff(_LTO_Resolved("gemini", "gemini-2.5-flash"),
		_LLMRemoteBuildPayload("gemini", "gemini-2.5-flash", "s", "u", 0.3, 40))
	Config := JsonParse(Gemini)["generationConfig"]
	AssertEqual(0, Config["thinkingConfig"]["thinkingBudget"], "the budget lands in generationConfig")
	AssertEqual(40, Config["maxOutputTokens"], "the body's own fields survive")
	Generate := _DriverFuncBody("LLM_RemoteGenerate_Async")
	AssertTrue(InStr(Generate, "_LLMRemoteApplyThinkingOff(") > 0,
		"LLM_RemoteGenerate_Async must turn thinking off in the payload it sends")
	AssertTrue(InStr(Generate, "_LLMRemoteThinkingRetryFail.Bind(") > 0,
		"LLM_RemoteGenerate_Async must give a refused thinking field one more chance")
}
Test("LLM thinking off: the prediction payload turns thinking off (thinking-off-everywhere)",
	_LTO_WithoutListingFetch.Bind(_LTO_PredictionPayload))

_LTO_PrebuiltBodies() {
	global _LLM_Vision_RemoteTransport
	Sent := []
	Saved := _LLM_Vision_RemoteTransport
	try {
		_LLM_Vision_RemoteTransport := (Resolved, Url, Body, OnSuccess, OnFail, CurrentFn) => Sent.Push(Body)
		Opus := _LTO_Resolved("anthropic", "claude-opus-5")
		_LLM_Vision_Send(Map("format", "anthropic", "resolved", Opus, "url", "https://example.invalid"),
			LLM_Vision_BuildRequest("anthropic", Map("model", "claude-opus-5", "system", "s", "text", "t",
				"max_tokens", 64)), (*) => 0, (*) => 0, false, 0)
		Plain := _LTO_Resolved("openai", "gpt-4o-mini")
		_LLM_Vision_Send(Map("format", "openai", "resolved", Plain, "url", "https://example.invalid"),
			LLM_Vision_BuildRequest("openai", Map("model", "gpt-4o-mini", "system", "s", "text", "t",
				"max_tokens", 64)), (*) => 0, (*) => 0, false, 0)
	} finally {
		_LLM_Vision_RemoteTransport := Saved
	}
	AssertEqual(2, Sent.Length, "both bodies reach the transport")
	AssertEqual("disabled", JsonParse(Sent[1])["thinking"]["type"], "the agent's Claude Opus 5 thinks for none")
	AssertFalse(JsonParse(Sent[2]).Has("reasoning_effort"), "a model no rule names is sent as it is")
}
Test("LLM thinking off: the screen reading and the agent turn thinking off (thinking-off-everywhere)",
	_LTO_WithoutListingFetch.Bind(_LTO_PrebuiltBodies))

_LTO_LocalServerPrebuilt() {
	global LLM_LOCAL_API_SERVERS
	for Id in LLM_LOCAL_API_SERVERS {
		Body := _LLMRemoteCompleteBody(_LTO_Resolved(Id, "qwen3.5-4b"),
			LLM_Vision_BuildRequest("openai", Map("model", "qwen3.5-4b", "system", "s", "text", "t",
				"max_tokens", 64)))
		AssertContains(RegExReplace(Body, "\s"), '"chat_template_kwargs":{"enable_thinking":false}',
			Id . ": a screenshot request turns the local server's thinking off")
		AssertEqual(64, JsonParse(Body)["max_tokens"], Id . ": a request field never replaces the budget")
		Oss := JsonParse(_LLMRemoteCompleteBody(_LTO_Resolved(Id, "gpt-oss-20b"),
			LLM_Vision_BuildRequest("openai", Map("model", "gpt-oss-20b", "system", "s", "text", "t", "max_tokens", 64))))
		AssertEqual("low", Oss["chat_template_kwargs"]["reasoning_effort"], Id . ": gpt-oss gets its lowest level on top")
	}
}
Test("LLM thinking off: a local server's screenshot request turns thinking off",
	_LTO_WithoutListingFetch.Bind(_LTO_LocalServerPrebuilt))

; A remote transport that records what it was handed.
_LTO_RecordSent(Sent, Resolved, Url, Body, OnSuccess, OnFail, CurrentFn) {
	Sent.Push(Map("body", Body, "on_fail", OnFail))
}

_LTO_RefusedFieldRetried() {
	global _LLM_Vision_RemoteTransport, _LLM_ThinkingRefused
	Sent := []
	Fails := []
	Saved := _LLM_Vision_RemoteTransport
	SavedRefused := _LLM_ThinkingRefused
	; A fresh store, so an earlier refusal cannot decide this test
	_LLM_ThinkingRefused := Map()
	try {
		_LLM_Vision_RemoteTransport := _LTO_RecordSent.Bind(Sent)
		DeepSeek := _LTO_Resolved("deepseek", "deepseek-chat")
		_LLM_Vision_Send(Map("format", "openai", "resolved", DeepSeek, "url", "https://example.invalid"),
			LLM_Vision_BuildRequest("openai", Map("model", "deepseek-chat", "system", "s", "text", "t",
				"max_tokens", 64)), (*) => 0, (Info := "") => Fails.Push(Info), false, 0)
		AssertEqual("disabled", JsonParse(Sent[1]["body"])["thinking"]["type"], "the generic family turns thinking off")
		Sent[1]["on_fail"].Call(_LLMRemote_FailInfo("http", 400, "Unknown parameter: thinking"))
		AssertEqual(2, Sent.Length, "the request is sent once more")
		AssertFalse(JsonParse(Sent[2]["body"]).Has("thinking"), "without the refused field")
		AssertEqual(0, Fails.Length, "a correction is not a failure")
		Sent[2]["on_fail"].Call(_LLMRemote_FailInfo("http", 400, "Unknown parameter: thinking"))
		AssertEqual(2, Sent.Length, "only once")
		AssertEqual(1, Fails.Length, "the second refusal fails the request")
		Again := _LLMRemoteCompleteBody(DeepSeek, '{"model":"deepseek-chat"}')
		AssertFalse(JsonParse(Again).Has("thinking"), "the refusal is remembered")
	} finally {
		_LLM_Vision_RemoteTransport := Saved
		_LLM_ThinkingRefused := SavedRefused
	}
}
Test("LLM thinking off: a refused field is sent once more without it, then never (thinking-off-everywhere)",
	_LTO_WithoutListingFetch.Bind(_LTO_RefusedFieldRetried))

_LTO_RefusalPersists() {
	global _LLM_ThinkingRefused, LLM_THINKING_REFUSED_KEY
	Saved := _LLM_ThinkingRefused
	try {
		_LLM_ThinkingRefused := Map()
		Resolved := _LTO_Resolved("deepseek", "deepseek-flash")
		Body := _LLMRemoteCompleteBody(Resolved, '{"model":"deepseek-flash"}', &Added)
		AssertTrue(_LLMRemoteThinkingRefusal(Resolved,
			_LLMRemote_FailInfo("http", 400, "thinking is not supported"), Added, &Body))
		Stored := ST_Get(LLM_THINKING_REFUSED_KEY, "")
		AssertTrue(Stored is Map && Stored.Has("deepseek|deepseek-flash"), "the refusal is stored")
		; A restart: the store is read again from the local state store
		_LLM_ThinkingRefused := 0
		Again := _LLMRemoteCompleteBody(Resolved, '{"model":"deepseek-flash"}')
		AssertFalse(JsonParse(Again).Has("thinking"), "the stored refusal is read back")
	} finally {
		_LLM_ThinkingRefused := Saved
		try ST_Set(LLM_THINKING_REFUSED_KEY, Map())
	}
}
Test("LLM thinking off: a refused field is remembered across restarts",
	_LTO_WithoutListingFetch.Bind(_LTO_RefusalPersists))

_LTO_DefaultSamplingOnly() {
	Opus := _LLMRemoteApplyThinkingOff(_LTO_Resolved("anthropic", "claude-opus-4-8"),
		_LLMRemoteBuildPayload("anthropic", "claude-opus-4-8", "s", "u", 0.7, 40))
	AssertFalse(JsonParse(Opus).Has("temperature"), "a non-default temperature is an HTTP 400 on Claude Opus 4.8")
	Haiku := _LLMRemoteApplyThinkingOff(_LTO_Resolved("anthropic", "claude-haiku-4-5"),
		_LLMRemoteBuildPayload("anthropic", "claude-haiku-4-5", "s", "u", 0.7, 40))
	AssertTrue(JsonParse(Haiku).Has("temperature"), "Claude Haiku 4.5 keeps it")
}
Test("LLM thinking off: models that accept only the default sampling get no temperature",
	_LTO_WithoutListingFetch.Bind(_LTO_DefaultSamplingOnly))

_LTO_RetryCancelReachesTheRetry() {
	global _LLM_Remote_RetryOf, _LLM_Remote_Async, _LLM_Remote_AsyncCounter
	AssertEqual(0, _LLM_Remote_Async.Count, "the live cancellation control requires an idle registry")
	Original := ++_LLM_Remote_AsyncCounter, Retry := ++_LLM_Remote_AsyncCounter
	Entry := _LLMRemote_ReserveRequest(Retry, (*) => 0, (*) => 0, 10000, A_TickCount)
	try {
		AssertEqual(Retry, _LLMRemoteRetryOf(Original, Retry), "the retry's id passes through")
		AssertEqual(Retry, _LLM_Remote_RetryOf.Get(Original, 0), "the original id names its live retry")
		LLM_RemoteCancelAsync(Original)
		AssertTrue(Entry["cancelled"], "the original public handle cancels its exact live child")
		AssertFalse(_LLM_Remote_RetryOf.Has(Original), "cancelling the original id reaches the retry")
	} finally {
		LLM_RemoteCancelAsync(Original)
		_LLMRemote_DeleteOwned(Retry, Entry)
	}
}
Test("LLM thinking off: cancelling a prediction cancels its retry", _LTO_RetryCancelReachesTheRetry)


; A synchronous terminal child must not acquire an alias after its callbacks
; already retired it. The first ordinary refusal also controls the no-alias path.
_LATRA_CancelAtFactory(State) {
	global _LLM_Remote_AsyncCounter
	State.FactoryCalls += 1
	State.FactoryChild := _LLM_Remote_AsyncCounter
	LLM_RemoteCancelAsync(State.FactoryChild)
	State.Http := CurlAsyncRequest()
	return State.Http
}

_LATRA_SynchronousChild(FactoryCancel) {
	global _LLM_Remote_RetryOf, _LLM_Remote_Async
	AssertEqual(0, _LLM_Remote_Async.Count, "the public synchronous boundary requires an idle registry")
	Before := _LLM_Remote_RetryOf.Count
	State := {Success: 0, Failure: 0, FactoryCalls: 0, FactoryChild: 0, Http: 0}
	Success := (*) => State.Success += 1
	Failure := (*) => State.Failure += 1
	Resolved := Map("Provider", "openai_compat", "Format", "openai", "Model", "owned-alias-test", "Token", "owned-fixture-token")
	InvalidUrl := "http://127.0.0.1/owned" . Chr(0)
	Original := LLM_RemotePostBody_Async(Resolved, InvalidUrl, "{}", Success, Failure, 10000)
	Child := 0
	try {
		AssertTrue(Original is Integer && Original > 0)
		AssertFalse(_LLM_Remote_Async.Has(Original), "real URL validation must synchronously retire the ordinary reservation")
		AssertEqual(1, State.Failure)
		AssertEqual(0, State.Success)
		AssertEqual(Before, _LLM_Remote_RetryOf.Count, "an ordinary request creates no cancellation alias")
		Port := FactoryCancel ? Map("managed_settings", (*) => 0, "create_http", _LATRA_CancelAtFactory.Bind(State)) : 0
		Url := FactoryCancel ? "http://127.0.0.1:0/owned" : InvalidUrl
		Child := _LLMRemoteRetryOf(Original, LLM_RemotePostBody_Async(Resolved, Url, "{}", Success, Failure, 10000, "", 0, 0, Port))
		AssertTrue(Child is Integer && Child > Original)
		AssertFalse(_LLM_Remote_Async.Has(Child), "the child must already be physically retired before alias publication")
		AssertEqual(FactoryCancel ? 1 : 2, State.Failure)
		AssertEqual(0, State.Success)
		if FactoryCancel {
			AssertEqual(1, State.FactoryCalls)
			AssertEqual(Child, State.FactoryChild)
			AssertTrue(State.Http is CurlAsyncRequest && State.Http.Aborted && State.Http.Completed)
			AssertFalse(State.Http.SendStarted, "factory cancellation must precede managed staging or any network request")
			AssertFalse(IsObject(State.Http.Handle))
			AssertFalse(State.Http.CleanupPending)
		}
		_TestPrint("# RETRY_ALIAS_SYNC factory_cancel=" . FactoryCancel . " failures=" . State.Failure
			. " ordinary=" . Original . " child=" . Child . " child_live=" . _LLM_Remote_Async.Has(Child)
			. " alias_before=" . Before . " alias_after=" . _LLM_Remote_RetryOf.Count)
		AssertFalse(_LLM_Remote_RetryOf.Has(Original), "a completed child cannot gain a post-completion cancellation alias")
		AssertEqual(Before, _LLM_Remote_RetryOf.Count)
	} finally {
		LLM_RemoteCancelAsync(Original)
		if Child && _LLM_Remote_Async.Has(Child)
			LLM_RemoteCancelAsync(Child)
	}
}
Test("LLM retry alias: synchronous public refusal leaves no alias (remote-retry-alias-companion)", _LATRA_SynchronousChild.Bind(false))
Test("LLM retry alias: factory cancellation leaves no alias (remote-retry-alias-companion)", _LATRA_SynchronousChild.Bind(true))

_LATRA_ExactRetirement(Trim := false) {
	global _LLM_Remote_RetryOf, _LLM_Remote_Async, _LLM_Remote_AsyncCounter, LLM_REMOTE_MAX_INFLIGHT
	AssertEqual(0, _LLM_Remote_Async.Count, "the exact-custody control requires an idle registry")
	Before := _LLM_Remote_RetryOf.Count, PreviousLimit := LLM_REMOTE_MAX_INFLIGHT
	Failures := {Count: 0}
	OriginalA := ++_LLM_Remote_AsyncCounter, ChildA := ++_LLM_Remote_AsyncCounter
	OriginalB := ++_LLM_Remote_AsyncCounter, ChildB := ++_LLM_Remote_AsyncCounter
	EntryA := _LLMRemote_ReserveRequest(ChildA, (*) => 0, (*) => Failures.Count += 1, 10000, A_TickCount)
	EntryB := _LLMRemote_ReserveRequest(ChildB, (*) => 0, (*) => 0, 10000, A_TickCount)
	try {
		AssertEqual(ChildA, _LLMRemoteRetryOf(OriginalA, ChildA))
		AssertEqual(ChildB, _LLMRemoteRetryOf(OriginalB, ChildB))
		AssertEqual(Before + 2, _LLM_Remote_RetryOf.Count)
		if Trim {
			LLM_REMOTE_MAX_INFLIGHT := 2
			_LLMRemote_TrimAsyncRegistry()
		} else
			AssertTrue(_LLMRemote_DeleteOwned(ChildA, EntryA), "only exact reservation A is retired")
		AssertEqual(Trim ? 1 : 0, Failures.Count, "a live capacity eviction still reports its failure exactly once")
		AssertFalse(_LLM_Remote_RetryOf.Has(OriginalA), "retired child A must release its own alias")
		AssertEqual(ChildB, _LLM_Remote_RetryOf.Get(OriginalB, 0), "another active alias must remain cancellable")
		AssertTrue(_LLM_Remote_Async.Has(ChildB) && _LLM_Remote_Async[ChildB] == EntryB)
		LLM_RemoteCancelAsync(OriginalB)
		AssertTrue(EntryB["cancelled"], "the preserved alias still reaches exact child B")
		AssertFalse(_LLM_Remote_RetryOf.Has(OriginalB))
		AssertTrue(_LLMRemote_DeleteOwned(ChildB, EntryB))
		AssertEqual(Before, _LLM_Remote_RetryOf.Count)
	} finally {
		LLM_REMOTE_MAX_INFLIGHT := PreviousLimit
		LLM_RemoteCancelAsync(OriginalA)
		LLM_RemoteCancelAsync(OriginalB)
		_LLMRemote_DeleteOwned(ChildA, EntryA)
		_LLMRemote_DeleteOwned(ChildB, EntryB)
	}
}
Test("LLM retry alias: exact retirement preserves another active alias (remote-retry-alias-companion)", _LATRA_ExactRetirement.Bind(false))
Test("LLM retry alias: capacity trim preserves another active alias (remote-retry-alias-companion)", _LATRA_ExactRetirement.Bind(true))
