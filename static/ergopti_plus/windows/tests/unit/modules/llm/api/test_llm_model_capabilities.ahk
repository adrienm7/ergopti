; static/ergopti_plus/windows/tests/unit/modules/llm/api/test_llm_model_capabilities.ahk

; ==============================================================================
; MODULE: Model Capabilities In Windows Cloud Requests
; DESCRIPTION:
; Replays _shared/tests/corpus/llm/model_capabilities_vectors.json, which the
; shared Lua module (macOS, Linux) replays too, through the AutoHotkey port
; (_shared/modules/llm/model_capabilities.ahk): recorded OpenRouter, Anthropic
; and Gemini listings, the controls they say a model lacks, the request bodies
; that follow through LLM_ThinkingOffApply, and the listing cache. Then pins
; that the driver consults the cache when it completes a body and fetches a
; listing off the prediction path.
;
; ROOT CAUSE ENCODED:
; A control a model does not take went out anyway and came back as an HTTP
; 400, then a retry: the listing that says so was never read.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===============================================
; ===============================================
; ======= 1/ Shared corpus ======================
; ===============================================
; ===============================================

_LMC_CorpusText() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\llm\model_capabilities_vectors.json"
	AssertTrue(FileExist(Path) != "", "the model capabilities corpus must exist at " . Path)
	return FileRead(Path, "UTF-8")
}

; The vectors of one corpus section, each Map("value", decoded, "text", source).
_LMC_Vectors(Section) {
	Vectors := []
	for Span in JsonArrayElementSpans(JsonObjectMemberSpans(_LMC_CorpusText())[Section]["text"])
		Vectors.Push(Map("value", Span["value"], "text", Span["text"]))
	return Vectors
}

; The records of one recorded listing answer.
_LMC_Records(Listing) {
	Records := LLM_ModelCapsParse(Listing, JsonParse(_LMC_CorpusText())["answers"][Listing], &Reason)
	AssertTrue(Records is Map, Listing . " answer must parse (" . Reason . ")")
	return Records
}

_LMC_ParseVectors() {
	Answers := JsonParse(_LMC_CorpusText())["answers"]
	Checked := 0
	for Vector in _LMC_Vectors("parse_vectors") {
		V := Vector["value"]
		Records := LLM_ModelCapsParse(V["listing"], Answers[V["answer"]], &Reason)
		AssertEqual(V.Get("reason", ""), Reason, V["id"] . ": reason")
		if V.Has("models")
			AssertEqual(V["models"], Records.Count, V["id"] . ": models kept")
		Checked += 1
	}
	AssertTrue(Checked >= 5, "expected at least 5 parse vectors, found " . Checked)
}
Test("LLM model capabilities: listings parse as the shared corpus says (thinking-off-capabilities)", _LMC_ParseVectors)

_LMC_LacksVectors() {
	Checked := 0
	for Vector in _LMC_Vectors("lacks_vectors") {
		V := Vector["value"]
		Record := LLM_ModelCapsRecord(_LMC_Records(V["listing"]), V["model"])
		AssertEqual(V["lacks"] ? 1 : 0,
			LLM_ModelCapsLacks(Record, V["kind"], V.Get("level", ""), _LTO_Member(Vector, "fields")) ? 1 : 0,
			V["model"] . " " . V["kind"])
		Checked += 1
	}
	AssertTrue(Checked >= 7, "expected at least 7 lacks vectors, found " . Checked)
}
Test("LLM model capabilities: a listed lack replays the shared corpus (thinking-off-capabilities)", _LMC_LacksVectors)

_LMC_ResolveVectors() {
	global LLM_API_PROVIDERS, LLM_THINKING_FAMILIES
	AssertTrue(LLM_THINKING_FAMILIES.HasOwnProp("Capability"), "the driver loaded capability_listing")
	Checked := 0
	for Vector in _LMC_Vectors("resolve_vectors") {
		V := Vector["value"]
		Listing := LLM_THINKING_FAMILIES.Capability["providers"][V["provider"]]
		Record := LLM_ModelCapsRecord(_LMC_Records(Listing), V["model"])
		Body := LLM_ThinkingOffApply(LLM_THINKING_FAMILIES, LLM_API_PROVIDERS[V["provider"]]["ThinkingDialect"],
			V["model"], _LTO_Member(Vector, "body"), "", &Family, &Kind, &Added,
			(K, Level, Template) => LLM_ModelCapsLacks(Record, K, Level, Template))
		AssertEqual(V.Get("kind", ""), Kind, V["id"] . ": kind")
		AssertEqual("", _LVS_DeepEqual(JsonParse(Body), V["expected"]), V["id"])
		Checked += 1
	}
	AssertTrue(Checked >= 10, "expected at least 10 resolve vectors, found " . Checked)
}
Test("LLM model capabilities: a lacking control is skipped before sending (thinking-off-capabilities)", _LMC_ResolveVectors)

_LMC_CacheVectors() {
	global LLM_THINKING_FAMILIES
	Ttl := LLM_THINKING_FAMILIES.Capability["ttl_sec"]
	Checked := 0
	for Vector in _LMC_Vectors("cache_vectors") {
		V := Vector["value"]
		Cache := Map()
		for Index, Step in V["steps"] {
			Where := V["id"] . " step " . Index
			Op := Step["op"]
			if (Op == "needs")
				AssertEqual(Step["expect"] ? 1 : 0, LLM_ModelCapsNeedsFetch(Cache, "p", Step["now"], Ttl) ? 1 : 0, Where)
			else if (Op == "begin")
				LLM_ModelCapsBegin(Cache, "p")
			else if (Op == "finish")
				LLM_ModelCapsFinish(Cache, "p", Step.Has("listing") ? _LMC_Records(Step["listing"]) : "", Step["now"])
			else {
				Records := LLM_ModelCapsRecords(Cache, "p")
				AssertEqual(Step["models"], Records is Map ? Records.Count : 0, Where)
			}
		}
		Checked += 1
	}
	AssertTrue(Checked >= 5, "expected at least 5 cache vectors, found " . Checked)
}
Test("LLM model capabilities: the listing cache replays the shared corpus (thinking-off-capabilities)", _LMC_CacheVectors)





; ===============================================
; ===============================================
; ======= 2/ Driver wiring ======================
; ===============================================
; ===============================================

_LMC_DriverSkipsALackingControl() {
	global _LLM_RemoteCapabilities
	Saved := _LLM_RemoteCapabilities
	try {
		; A fresh listing: nothing is fetched while the test runs
		_LLM_RemoteCapabilities := Map()
		LLM_ModelCapsBegin(_LLM_RemoteCapabilities, "openrouter")
		LLM_ModelCapsFinish(_LLM_RemoteCapabilities, "openrouter", _LMC_Records("openrouter"), _LLMRemoteEpochNow())
		Lacking := _LLMRemoteApplyThinkingOff(_LTO_Resolved("openrouter", "mistralai/mistral-small-2603"),
			_LLMRemoteBuildPayload("openai", "mistralai/mistral-small-2603", "s", "u", 0, 16))
		AssertFalse(JsonParse(Lacking).Has("reasoning"), "the listing says the model takes no reasoning")
		Listed := _LLMRemoteApplyThinkingOff(_LTO_Resolved("openrouter", "qwen/qwen3-235b-a22b"),
			_LLMRemoteBuildPayload("openai", "qwen/qwen3-235b-a22b", "s", "u", 0, 16))
		AssertContains(Listed, '"reasoning":{"enabled":false}', "a listed control is still sent")
		AssertTrue(_LLM_RemoteCapabilities["openrouter"].Get("pending", false) == false, "a fresh listing is not fetched")
	} finally {
		_LLM_RemoteCapabilities := Saved
	}
	Ready := _DriverFuncBody("LLM_RemoteIsReady_Async")
	AssertTrue(Ready != "", "LLM_RemoteIsReady_Async must exist")
	AssertTrue(InStr(Ready, 'Owner["listing_query"]') > 0, "the listing asks for its largest page")
	Refresh := _DriverFuncBody("_LLMRemoteRefreshCapabilities")
	AssertTrue(Refresh != "" && InStr(Refresh, "SetTimer(") > 0, "the fetch waits for a one-shot timer")
}
Test("LLM model capabilities: the driver skips a control the listing says a model lacks (thinking-off-capabilities)",
	_LMC_DriverSkipsALackingControl)
