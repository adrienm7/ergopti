; static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_thinking_off.ahk

; ==============================================================================
; MODULE: Thinking Off In Every Windows Cloud Request
; DESCRIPTION:
; Replays _shared/tests/corpus/llm/thinking_off_vectors.json, which the shared
; Lua resolver (macOS, Linux) replays too, through the AutoHotkey port
; (_shared/modules/llm/thinking_off.ahk) and the rules the driver loaded from
; api_providers.json. Then pins both request paths: the prediction payload
; (LLM_RemoteGenerate_Async) and the bodies the screen reading and the AI
; agent write whole (_LLM_Vision_Send).
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
		Id := Vector["value"]["id"]
		Merged := LLM_ThinkingOffMerge(_LTO_Member(Vector, "body"), _LTO_Member(Vector, "fields"))
		AssertEqual("", _LVS_DeepEqual(JsonParse(Merged), Vector["value"]["expected"]), Id)
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

_LTO_ProviderVectors() {
	global LLM_API_PROVIDERS
	Checked := 0
	for Vector in _LTO_Vectors("provider_vectors") {
		V := Vector["value"]
		AssertTrue(LLM_API_PROVIDERS.Has(V["provider"]), V["id"] . ": the driver loaded the provider")
		Rules := LLM_API_PROVIDERS[V["provider"]]["ThinkingOff"]
		Body := LLM_ThinkingOffApply(Rules, V["model"], _LTO_Member(Vector, "body"), &Index)
		AssertEqual(V.Get("rule", 0), Index, V["id"] . ": rule index")
		AssertEqual("", _LVS_DeepEqual(JsonParse(Body), V["expected"]), V["id"])
		Checked += 1
	}
	AssertTrue(Checked >= 40, "expected at least 40 provider vectors, found " . Checked)
}
Test("LLM thinking off: the shipped rules replay the shared corpus (thinking-off-everywhere)", _LTO_ProviderVectors)

_LTO_ParseVectors() {
	Checked := 0
	for Vector in _LTO_Vectors("parse_vectors") {
		V := Vector["value"]
		Accepted := true
		try LLM_ThinkingOffParse(_LTO_Member(Vector, "thinking_off"))
		catch
			Accepted := false
		AssertEqual(V["valid"] ? 1 : 0, Accepted ? 1 : 0, V["id"])
		Checked += 1
	}
	AssertTrue(Checked >= 15, "expected at least 15 parse vectors, found " . Checked)
}
Test("LLM thinking off: a malformed list is refused whole (thinking-off-everywhere)", _LTO_ParseVectors)





; =============================================
; =============================================
; ======= 2/ Request paths ====================
; =============================================
; =============================================

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
}
Test("LLM thinking off: the prediction payload turns thinking off (thinking-off-everywhere)", _LTO_PredictionPayload)

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
	_LTO_PrebuiltBodies)

_LTO_LocalServerPrebuilt() {
	global LLM_LOCAL_API_SERVERS
	for Id in LLM_LOCAL_API_SERVERS {
		Body := _LLMRemoteCompleteBody(_LTO_Resolved(Id, "qwen3.5-4b"),
			LLM_Vision_BuildRequest("openai", Map("model", "qwen3.5-4b", "system", "s", "text", "t",
				"max_tokens", 64)))
		AssertContains(RegExReplace(Body, "\s"), '"chat_template_kwargs":{"enable_thinking":false}',
			Id . ": a screenshot request turns the local server's thinking off")
		AssertEqual(64, JsonParse(Body)["max_tokens"], Id . ": a request field never replaces the budget")
	}
}
Test("LLM thinking off: a local server's screenshot request turns thinking off", _LTO_LocalServerPrebuilt)
