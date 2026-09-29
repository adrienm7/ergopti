; static/ergopti_plus/windows/tests/unit/test_llm_remote_formats.ahk

; ==============================================================================
; MODULE: Remote API Formats and Providers (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/llm/remote_formats_vectors.json, which the
; shared Lua module (macOS, Linux) replays too, through
; modules/llm/remote_formats.ahk: Backboard's assistant/thread shapes and
; TypeSafe's decisions shapes, compared as the JSON they are sent as. Then
; drives the remote API layer with only the HTTP transport faked
; (_LLM_Remote_PostBodyFn):
; - the providers of api_providers.json publish in their order, the
;   OpenAI-format ones sending to their own base_url;
; - a Backboard request creates the driver's assistant once per key, then
;   sends a message; a failed creation fails the request and the next one
;   tries again; a model naming no provider is refused;
; - a decisions provider is never sent a chat request, is not a prediction
;   backend and is probed by the Test action with decisions_test;
; - neither format is offered for the screen reading's image step.
;
; The structural JSON comparison is test_llm_vision.ahk's (_LVS_DeepEqual);
; the Test-action fixture is test_llm_api_test_entry.ahk's.
;
; ROOT CAUSE ENCODED:
; A provider whose request shape is not a chat completion fails silently on
; Windows, where the suite runs only in CI: the shapes are pinned to the
; corpus the Lua oracle generated.
; ==============================================================================

#Requires AutoHotkey v2.0





; =================================================
; =================================================
; ======= 1/ Shared corpus (remote_formats) =======
; =================================================
; =================================================

_LRF_Corpus() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\llm\remote_formats_vectors.json"
	AssertTrue(FileExist(Path) != "", "the remote formats corpus must exist at " . Path)
	return JsonParse(FileRead(Path, "UTF-8"))
}

_LRF_Providers() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\modules\llm\api_providers.json", "UTF-8"))
}

; Asserts a built value against its vector, compared as the JSON it is sent
; as; {"absent": true} means none.
_LRF_AssertShape(Expected, Actual, Id) {
	if Expected.Get("absent", false) {
		AssertFalse(IsObject(Actual), Id . ": nothing")
		return
	}
	AssertTrue(IsObject(Actual), Id . ": a value")
	AssertEqual("", _LVS_DeepEqual(Expected, JsonParse(LLM_RemoteFormats_Encode(Actual))), Id)
}

_LRF_HeaderVectors() {
	Checked := 0
	for Vector in _LRF_Corpus()["headers"] {
		AssertEqual(Vector["expected"]["backboard"], LLM_BACKBOARD_KEY_HEADER, Vector["id"] . ": Backboard")
		AssertEqual(Vector["expected"]["decisions"], LLM_DECISIONS_KEY_HEADER, Vector["id"] . ": decisions")
		AssertEqual(Vector["expected"]["bearer"], LLM_RemoteFormats_DecisionsKeyValue("k"), Vector["id"] . ": bearer")
		Checked += 1
	}
	AssertTrue(Checked > 0, "the header vectors are replayed")
}
Test("LLM remote formats: the key headers replay the shared corpus", _LRF_HeaderVectors)

_LRF_BackboardVectors() {
	Corpus := _LRF_Corpus()
	Expected := 0
	Checked := 0
	for Section in ["split_model", "assistant_request", "assistant_id", "message_request", "text",
			"decision_answers"]
		Expected += Corpus[Section].Length
	for Vector in Corpus["split_model"] {
		_LRF_AssertShape(Vector["expected"], LLM_RemoteFormats_BackboardSplitModel(Vector["model"]), Vector["id"])
		Checked += 1
	}
	for Vector in Corpus["assistant_request"] {
		_LRF_AssertShape(Vector["expected"], LLM_RemoteFormats_BackboardAssistantRequest(Vector["base_url"]),
			Vector["id"])
		Checked += 1
	}
	for Vector in Corpus["assistant_id"] {
		Id := LLM_RemoteFormats_BackboardAssistantId(Vector["response"])
		_LRF_AssertShape(Vector["expected"], (Id != "") ? Map("id", Id) : "", Vector["id"])
		Checked += 1
	}
	for Vector in Corpus["message_request"] {
		_LRF_AssertShape(Vector["expected"], LLM_RemoteFormats_BackboardMessageRequest(Vector["base_url"],
			Vector["spec"]), Vector["id"])
		if Vector["spec"].Has("questions")
			AssertEqual("", _LVS_DeepEqual(Vector["spec"]["questions"], LLM_Agent_JevQuestions(LLM_Agent_Config())),
				Vector["id"] . ": the Jev message carries the agent's triage question")
		Checked += 1
	}
	for Vector in Corpus["text"] {
		Found := LLM_RemoteFormats_BackboardText(Vector["response"], &Text)
		_LRF_AssertShape(Vector["expected"], Found ? Map("text", Text) : "", Vector["id"])
		Checked += 1
	}
	for Vector in Corpus["decision_answers"] {
		Answers := LLM_RemoteFormats_BackboardDecisionAnswers(Vector["response"], &Where)
		_LRF_AssertShape(Vector["expected"], IsObject(Answers) ? Map("answers", Answers, "where", Where) : "",
			Vector["id"])
		Checked += 1
	}
	AssertTrue(Checked > 0, "the Backboard vectors are replayed")
	AssertEqual(Expected, Checked, "every Backboard vector is replayed")
}
Test("LLM remote formats: Backboard's shapes replay the shared corpus", _LRF_BackboardVectors)

_LRF_DecisionsVectors() {
	Corpus := _LRF_Corpus()
	Questions := LLM_Agent_JevQuestions(LLM_Agent_Config())
	Checked := 0
	for Vector in Corpus["decisions_body"] {
		_LRF_AssertShape(Vector["expected"], LLM_RemoteFormats_DecisionsBody(Vector["model"], Vector["state"],
			Questions), Vector["id"])
		Checked += 1
	}
	for Vector in Corpus["decisions_answers"] {
		Answers := LLM_RemoteFormats_DecisionsAnswers(Vector["response"])
		_LRF_AssertShape(Vector["expected"], IsObject(Answers) ? Map("answers", Answers) : "", Vector["id"])
		Checked += 1
	}
	AssertTrue(Checked > 0, "the decisions vectors are replayed")
	AssertEqual(Corpus["decisions_body"].Length + Corpus["decisions_answers"].Length, Checked,
		"every decisions vector is replayed")
}
Test("LLM remote formats: the decisions shapes replay the shared corpus", _LRF_DecisionsVectors)

_LRF_EncoderWritesJson() {
	AssertEqual('{"memory":"off","stream":false}',
		LLM_RemoteFormats_Encode(Map("stream", LLM_REMOTE_JSON_FALSE, "memory", "off")),
		"the false sentinel is written false, not 0")
	AssertEqual('{"n":0,"q":["a\"b",null]}',
		LLM_RemoteFormats_Encode(Map("n", 0, "q", ['a"b', JSON_NULL])), "numbers, escapes and null")
	AssertThrows(() => LLM_RemoteFormats_Encode(Map("f", _LRF_EncoderWritesJson)), "a function is refused")
	; The comparison the replay relies on can fail
	AssertTrue(_LVS_DeepEqual(JsonParse('{"a":"x"}'), JsonParse(LLM_RemoteFormats_Encode(Map("a", "y")))) != "",
		"a differing value is caught")
}
Test("LLM remote formats: bodies are written as JSON, false included", _LRF_EncoderWritesJson)





; ========================================================
; ========================================================
; ======= 2/ Catalogue, headers and classification =======
; ========================================================
; ========================================================

_LRF_NewProvidersPublishInOrder() {
	Shipped := _LRF_Providers()
	Choices := _LLM_Menu_BuildApiProviderChoices(LLM_API_PROVIDERS, LLM_API_PROVIDER_ORDER)
	Previous := 0
	for ProviderId in Shipped["provider_order"] {
		AssertTrue(LLM_API_PROVIDERS.Has(ProviderId), ProviderId . " publishes")
		At := InStr(Choices, ProviderId . " (" . Shipped["providers"][ProviderId]["label"] . ")", true)
		AssertTrue(At > Previous, ProviderId . " is listed in provider_order's place")
		Previous := At
	}
	for ProviderId in ["openrouter", "groq", "together", "fireworks"] {
		Provider := LLM_API_PROVIDERS[ProviderId]
		AssertEqual("openai", Provider["Format"], ProviderId . " speaks the OpenAI format")
		AssertEqual(RTrim(Shipped["providers"][ProviderId]["base_url"], "/") . "/chat/completions",
			_LLMRemoteBuildUrl(Provider["BaseUrl"], Provider["Format"], "k", Provider["DefaultModel"]),
			ProviderId . " sends to its own base_url")
	}
	AssertEqual("backboard", LLM_API_PROVIDERS["backboard"]["Format"], "Backboard keeps its format")
	for ProviderId in ["typesafe", "openrouter_jev"] {
		AssertEqual("decisions", LLM_API_PROVIDERS[ProviderId]["Format"], ProviderId . " is a decisions provider")
		AssertEqual(Shipped["providers"][ProviderId]["base_url"],
			_LLMRemoteBuildUrl(LLM_API_PROVIDERS[ProviderId]["BaseUrl"], "decisions", "k", "m"),
			ProviderId . "'s base_url is the full endpoint")
	}
	AssertEqual("", _LVS_DeepEqual(Shipped["decisions_test"]["questions"], LLM_REMOTE_DECISIONS_TEST["questions"]),
		"the decisions probe is api_providers.json's")
}
Test("LLM remote formats: the new providers publish in order and send to their endpoints",
	_LRF_NewProvidersPublishInOrder)

_LRF_KeyHeaders() {
	Backboard := _LLMRemote_BuildCurlConfig("backboard", "key-b", "https://b.invalid/api/assistants")
	AssertContains(Backboard, 'header = "X-API-Key: key-b"', "Backboard's key rides X-API-Key")
	AssertFalse(InStr(Backboard, "Authorization"), "never as a Bearer")
	Decisions := _LLMRemote_BuildCurlConfig("decisions", "key-t", "https://t.invalid/v1/systemone")
	AssertContains(Decisions, 'header = "Authorization: Bearer key-t"', "a decisions key rides a Bearer header")
	AssertContains(Decisions, 'url = "https://t.invalid/v1/systemone"', "to the full endpoint")
}
Test("LLM remote formats: each format carries its key in its own header", _LRF_KeyHeaders)

_LRF_RawClassification() {
	for Fmt in ["backboard", "decisions"] {
		Body := '{"content":"x","thread_id":"t"}'
		Result := _LLMRemoteClassifyResponse(Fmt, Body)
		AssertTrue(Result["ok"], Fmt . ": a JSON object is handed on whole")
		AssertEqual(Body, Result["text"], Fmt . ": as it is")
		Result := _LLMRemoteClassifyResponse(Fmt, '{"error":{"message":"bad key"}}')
		AssertFalse(Result["ok"], Fmt . ": an error envelope fails")
		AssertEqual("provider_error", Result["reason"], Fmt . ": as the provider's verdict")
		AssertEqual("bad key", Result["server_message"], Fmt . ": with its message")
		AssertEqual("nope", _LLMRemoteClassifyResponse(Fmt, '{"detail":"nope"}')["server_message"],
			Fmt . ": a FastAPI detail is the provider's message")
		AssertFalse(_LLMRemoteClassifyResponse(Fmt, "[1]")["ok"], Fmt . ": a non-object fails")
	}
}
Test("LLM remote formats: Backboard and decisions answers are handed on as JSON objects", _LRF_RawClassification)





; =====================================================
; =====================================================
; ======= 3/ Backboard and decisions transports =======
; =====================================================
; =====================================================

; Runs Body(Fx, Lines) with the HTTP transport faked, a fresh assistant cache
; and a log capture; everything is put back.
_LRF_Run(Body) {
	global _LLM_Remote_PostBodyFn, _LLM_Remote_BackboardAssistants, _LOGGER_TEST_SINK, _LOGGER_INFO_ENABLED
	Saved := { Post: _LLM_Remote_PostBodyFn, Cache: _LLM_Remote_BackboardAssistants,
		Sink: _LOGGER_TEST_SINK, Info: _LOGGER_INFO_ENABLED }
	Fx := { Posts: [], Texts: [], Fails: [] }
	Lines := []
	try {
		_LLM_Remote_PostBodyFn := _LRF_FakePost.Bind(Fx)
		_LLM_Remote_BackboardAssistants := Map()
		_LOGGER_INFO_ENABLED := true
		LoggerSetTestSink((Line) => Lines.Push(Line))
		Body.Call(Fx, Lines)
	} finally {
		_LLM_Remote_PostBodyFn := Saved.Post
		_LLM_Remote_BackboardAssistants := Saved.Cache
		_LOGGER_TEST_SINK := Saved.Sink
		_LOGGER_INFO_ENABLED := Saved.Info
	}
}

_LRF_FakePost(Fx, Resolved, Url, Payload, OnSuccess, OnFail, TimeoutMs := 0, Kind := "") {
	Fx.Posts.Push(Map("resolved", Resolved, "url", Url, "body", JsonParse(Payload), "on_success", OnSuccess,
		"on_fail", OnFail, "kind", Kind))
	return Fx.Posts.Length
}

_LRF_BackboardEntry(Model := "openai/gpt-4o-mini") {
	return Map("Id", "bb", "Name", "Backboard", "Provider", "backboard", "BaseUrl", "https://bb.invalid/api/",
		"Token", "key-b", "Model", Model)
}

; Sends one prediction-shaped chat request through the remote API layer.
_LRF_Chat(Fx, Entry) {
	return LLM_RemoteGenerate_Async(Entry, "You predict.", "On se voit", 0.2,
		(Text, Usage := "") => Fx.Texts.Push(Text), (Info := "") => Fx.Fails.Push(Info))
}

_LRF_BackboardCreatesThenMessages() {
	_LRF_Run(_Body)
	_Body(Fx, Lines) {
		_LRF_Chat(Fx, _LRF_BackboardEntry())
		AssertEqual(1, Fx.Posts.Length, "the first request creates the assistant")
		Create := Fx.Posts[1]
		AssertEqual("https://bb.invalid/api/assistants", Create["url"], "at /assistants")
		AssertEqual("", _LVS_DeepEqual(JsonParse(LLM_RemoteFormats_Encode(
			LLM_RemoteFormats_BackboardAssistantRequest("https://bb.invalid/api")["body"])), Create["body"]),
			"with the shared creation body")
		AssertEqual("backboard", Create["resolved"]["Format"], "the key goes in Backboard's header")
		Create["on_success"].Call('{"assistant_id":"asst_123","name":"Ergopti+"}')
		AssertEqual(2, Fx.Posts.Length, "then the message is sent")
		Message := Fx.Posts[2]
		AssertEqual("https://bb.invalid/api/threads/messages", Message["url"], "on a new thread")
		Expected := LLM_RemoteFormats_BackboardMessageRequest("https://bb.invalid/api", Map(
			"assistant_id", "asst_123", "model", "openai/gpt-4o-mini", "system", "You predict.",
			"text", "On se voit"))
		AssertEqual("", _LVS_DeepEqual(JsonParse(LLM_RemoteFormats_Encode(Expected["body"])), Message["body"]),
			"with the shared message body")
		AssertFalse(Message["body"].Has("temperature") || Message["body"].Has("max_tokens"),
			"and no invented temperature or budget")
		Message["on_success"].Call('{"content":"demain","status":"COMPLETED","thread_id":"t1"}')
		AssertEqual("", _LVS_DeepEqual(["demain"], Fx.Texts), "the answer's content is the text")

		_LRF_Chat(Fx, _LRF_BackboardEntry())
		AssertEqual(3, Fx.Posts.Length, "the second request reuses the assistant")
		AssertEqual("asst_123", Fx.Posts[3]["body"]["assistant_id"], "by its id")
		Fx.Posts[3]["on_success"].Call('{"status":"FAILED","thread_id":"t2"}')
		AssertEqual(1, Fx.Fails.Length, "an answer without content fails")
		AssertEqual(1, _LPP_LinesWith(Lines, "WARNING", "status: FAILED"), "with its status in the log")
	}
}
Test("LLM remote formats: Backboard creates its assistant once, then sends messages", _LRF_BackboardCreatesThenMessages)

_LRF_BackboardCreationFailureRetries() {
	_LRF_Run(_Body)
	_Body(Fx, Lines) {
		_LRF_Chat(Fx, _LRF_BackboardEntry())
		Fx.Posts[1]["on_fail"].Call(_LLMRemote_FailInfo("provider_error", 401, "bad key"))
		AssertEqual(1, Fx.Fails.Length, "a failed creation fails the request")
		AssertEqual(1, Fx.Posts.Length, "without sending the message")
		AssertEqual(1, _LPP_LinesWith(Lines, "WARNING", "assistant creation failed (provider_error)"),
			"with its reason in the log")
		_LRF_Chat(Fx, _LRF_BackboardEntry())
		AssertEqual(2, Fx.Posts.Length, "the next request")
		AssertTrue(InStr(Fx.Posts[2]["url"], "/assistants"), "tries the creation again")
		Fx.Posts[2]["on_success"].Call('{"name":"Ergopti+"}')
		AssertEqual(2, Fx.Fails.Length, "a creation answer without an id fails too")
		AssertEqual(1, _LPP_LinesWith(Lines, "WARNING", "keys: name"), "naming the keys it holds")
		_LRF_Chat(Fx, _LRF_BackboardEntry("gpt-4o-mini"))
		AssertEqual(2, Fx.Posts.Length, "a model naming no provider sends nothing")
		AssertEqual("invalid_model", Fx.Fails[3]["reason"], "and is refused as an invalid model")
	}
}
Test("LLM remote formats: a failed Backboard creation fails the request and is retried",
	_LRF_BackboardCreationFailureRetries)

_LRF_DecisionsIsNoChat() {
	_LRF_Run(_Body)
	_Body(Fx, Lines) {
		global _LLM_Menu
		Entry := Map("Id", "jev", "Name", "Jev", "Provider", "typesafe", "BaseUrl", "https://t.invalid/v1/systemone",
			"Token", "key-t", "Model", "jev-latest")
		_LRF_Chat(Fx, Entry)
		AssertEqual(0, Fx.Posts.Length, "a decisions provider is never sent a chat request")
		AssertEqual("not_chat", Fx.Fails[1]["reason"], "the request fails as not a chat")
		AssertEqual(1, _LPP_LinesWith(Lines, "WARNING", "not a chat model"), "and says why")
		Saved := _LLM_Menu
		try {
			_LLM_Menu := Map("enabled", true, "backend", "api", "api_entry_id", "jev", "api_entries", [Entry])
			AssertFalse(_LLM_Menu_SelectedApiEntryIsUsable(), "it is no prediction backend")
			_LLM_Menu["api_entries"].Push(_LRF_BackboardEntry())
			_LLM_Menu["api_entry_id"] := "bb"
			AssertTrue(_LLM_Menu_SelectedApiEntryIsUsable(), "Backboard is one")
		} finally _LLM_Menu := Saved
	}
}
Test("LLM remote formats: a decisions provider is never a chat or prediction backend", _LRF_DecisionsIsNoChat)

_LRF_DecisionsEntryKeepsActive() {
	Candidate := Map("api_entry_id", "prod", "api_entries", [_LAT_FixtureEntry()])
	Jev := Map("Id", "jev", "Name", "Jev", "Provider", "typesafe", "BaseUrl", "https://t.invalid/v1/systemone",
		"Token", "key-t", "Model", "jev-latest")
	AssertTrue(_LLM_Menu_UpsertApiEntryCandidate(Candidate, Jev, ""), "a decisions entry is saved")
	AssertEqual(2, Candidate["api_entries"].Length, "next to the others")
	AssertEqual("prod", Candidate["api_entry_id"], "without taking the prediction backend's place")
	Other := _LRF_BackboardEntry()
	AssertTrue(_LLM_Menu_UpsertApiEntryCandidate(Candidate, Other, ""), "a chat entry is saved")
	AssertEqual("bb", Candidate["api_entry_id"], "and becomes the active one")
	Alone := Map("api_entry_id", "", "api_entries", [])
	AssertTrue(_LLM_Menu_UpsertApiEntryCandidate(Alone, Jev, ""), "a first entry is saved")
	AssertEqual("jev", Alone["api_entry_id"], "and is active when it is the only one")
}
Test("LLM remote formats: a decisions entry never replaces the active prediction entry",
	_LRF_DecisionsEntryKeepsActive)

_LRF_TestActionDecisions() {
	_LRF_Run(_Body)
	_Body(Fx, Lines) {
		global LLM_REMOTE_KIND_API_TEST, _LLM_Menu
		Notices := []
		Jev := Map("Id", "jev", "Name", "Jev", "Provider", "typesafe", "BaseUrl", "https://t.invalid/v1/systemone",
			"Token", "key-t", "Model", "jev-latest")
		SavedMenu := _LAT_FixtureMenu()
		try {
			_LAT_ResetOwners()
			_LLM_Menu["api_entries"].Push(Jev)
			AssertTrue(_LLM_Menu_TestActiveApiEntry((Ok, Tip) => Notices.Push(Map("ok", Ok, "tip", Tip)), "jev"),
				"the probe is dispatched")
			AssertEqual(1, Fx.Posts.Length, "one decisions request")
			Post := Fx.Posts[1]
			AssertEqual("https://t.invalid/v1/systemone", Post["url"], "to the full endpoint")
			Probe := _LRF_Providers()["decisions_test"]
			AssertEqual("", _LVS_DeepEqual(JsonParse(LLM_RemoteFormats_Encode(LLM_RemoteFormats_DecisionsBody(
				"jev-latest", Probe["state"], Probe["questions"]))), Post["body"]), "asking decisions_test verbatim")
			AssertEqual(LLM_REMOTE_KIND_API_TEST, Post["kind"], "as the owned probe")
			Post["on_success"].Call('{"answers":{"ok":{"type":"noul","probability":0.97}},"model":"jev-latest"}')
			AssertEqual(1, Notices.Length, "a verdict is shown")
			AssertTrue(Notices[1]["ok"], "answers mean success")

			AssertTrue(_LLM_Menu_TestActiveApiEntry((Ok, Tip) => Notices.Push(Map("ok", Ok, "tip", Tip)), "jev"),
				"a second probe")
			Fx.Posts[2]["on_success"].Call('{"model":"jev-latest"}')
			AssertFalse(Notices[2]["ok"], "no answers mean failure")
		} finally _LAT_RestoreMenu(SavedMenu)
	}
}
Test("LLM remote formats: the Test action probes a decisions entry with decisions_test", _LRF_TestActionDecisions)

_LRF_TestActionBackboard() {
	_LRF_Run(_Body)
	_Body(Fx, Lines) {
		global _LLM_Menu
		Notices := []
		SavedMenu := _LAT_FixtureMenu()
		try {
			_LAT_ResetOwners()
			_LLM_Menu["api_entries"].Push(_LRF_BackboardEntry())
			AssertTrue(_LLM_Menu_TestActiveApiEntry((Ok, Tip) => Notices.Push(Map("ok", Ok, "tip", Tip)), "bb"),
				"the probe is dispatched")
			Fx.Posts[1]["on_success"].Call('{"assistant_id":"asst_9"}')
			AssertEqual(2, Fx.Posts.Length, "one message after the assistant")
			Body := Fx.Posts[2]["body"]
			AssertEqual(LLM_REMOTE_TEST_REQUEST["system_prompt"], Body["system_prompt"], "with the probe's system prompt")
			AssertEqual(LLM_REMOTE_TEST_REQUEST["user_text"], Body["content"], "and its user text")
			Fx.Posts[2]["on_success"].Call('{"content":"OK","status":"COMPLETED"}')
			AssertEqual(1, Notices.Length, "a verdict is shown")
			AssertTrue(Notices[1]["ok"], "the reply means success")
		} finally _LAT_RestoreMenu(SavedMenu)
	}
}
Test("LLM remote formats: the Test action sends a Backboard entry one message", _LRF_TestActionBackboard)

_LRF_ScreenReadingExcludesBothFormats() {
	Values := Map()
	for Choice in LLM_Vision_BackendChoices()
		Values[Choice["value"]] := true
	for ProviderId in ["backboard", "typesafe", "openrouter_jev"]
		AssertFalse(Values.Has(ProviderId), ProviderId . " cannot read a screenshot")
	for ProviderId in ["openai", "openrouter", "groq", "together", "fireworks"]
		AssertTrue(Values.Has(ProviderId), ProviderId . " can")
}
Test("LLM remote formats: Backboard and the decisions providers are no vision backend",
	_LRF_ScreenReadingExcludesBothFormats)
