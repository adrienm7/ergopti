; tests/unit/modules/llm/api/test_llm_api_token_exchange.ahk

; ==============================================================================
; MODULE: API Token Exchange (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/llm/api_token_exchange_vectors.json through the Windows
; port, then drives the access slots, the requests that wait on them and the first
; screen reading through the exchange's test seam: no provider is ever called.
;
; ROOT CAUSE ENCODED:
; Windows refused watsonx and Vertex AI outright: sent as Bearer, the stored key is
; answered HTTP 401, and nothing here could exchange it or sign a service-account
; assertion. The first screen reading must wait for its token, not be refused.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===============================
; ===============================
; ======= 1/ Fixtures ===========
; ===============================
; ===============================

; test_llm_rs256_signer.ahk owns the corpus readers and the PEM armour.
_LTE_ExchangeCorpus() {
	return _LTE_ReadJson("tests\corpus\llm\api_token_exchange_vectors.json")
}

; A corpus block with some fields replaced.
_LTE_Block(Corpus, Name, Set := 0) {
	Copy := Corpus[Name].Clone()
	if Set is Map {
		for Key, Value in Set
			Copy[Key] := Value
	}
	return Copy
}

; The stored key of a request row: its key, or the service-account key file it
; describes, written in the corpus's own JSON field names.
_LTE_StoredKey(Row, Keys) {
	if !Row.Has("service_account")
		return Row["key"]
	Text := "{", Sep := ""
	for Name, Value in Row["service_account"] {
		if (Name == "private_key_of")
			continue
		Text .= Sep . '"' . Name . '":"' . JsonStringContents(Value) . '"', Sep := ","
	}
	if Row["service_account"].Has("private_key_of") {
		Spec := Keys[Row["service_account"]["private_key_of"]]
		Text .= Sep . '"private_key":"' . JsonStringContents(_LTE_Pem(Spec["label"], Spec["body"])) . '"'
	}
	return Text . "}"
}

global LTE_PROVIDER := "token_fixture"
global LTE_BASE_URL := "https://token-fixture.invalid/v1"

; Installs a provider exchanging its key, the exchange seam and an empty cache, runs
; Body(Posts, Lines), and puts everything back.
_LTE_Run(Body) {
	global LLM_API_PROVIDERS, _LLM_TokenExchange_PostFn, _LOGGER_TEST_SINK, _LOGGER_INFO_ENABLED, LTE_PROVIDER, LTE_BASE_URL
	Saved := { Providers: LLM_API_PROVIDERS, Post: _LLM_TokenExchange_PostFn, Sink: _LOGGER_TEST_SINK, Info: _LOGGER_INFO_ENABLED }
	Posts := [], Lines := []
	try {
		Providers := LLM_Menu_DeepClone(LLM_API_PROVIDERS)
		Providers[LTE_PROVIDER] := Map("Label", "Token fixture", "BaseUrl", LTE_BASE_URL, "DefaultModel", "fixture-model",
			"Format", "openai", "ModelExtras", Map(), "ThinkingDialect", Map(), "Auth", _LTE_ExchangeCorpus()["google"])
		LLM_API_PROVIDERS := Providers
		_LLM_TokenExchange_ResetForTest()
		_LLM_TokenExchange_PostFn := (Request, OnAnswer) => Posts.Push(Map("request", Request, "answer", OnAnswer))
		_LOGGER_INFO_ENABLED := true
		LoggerSetTestSink((Line) => Lines.Push(Line))
		Body(Posts, Lines)
	} finally {
		_LOGGER_TEST_SINK := Saved.Sink
		_LOGGER_INFO_ENABLED := Saved.Info
		_LLM_TokenExchange_PostFn := Saved.Post
		LLM_API_PROVIDERS := Saved.Providers
		_LLM_TokenExchange_ResetForTest()
	}
}

; Lets the one-shot timer that builds the exchange run, even under a scenario's Critical.
_LTE_Pump() {
	Previous := Critical("Off")
	Sleep(30)
	Critical(Previous)
}

_LTE_Key() {
	return '{"type":"authorized_user","client_id":"fixture-id","client_secret":"fixture-secret","refresh_token":"fixture-refresh"}'
}

_LTE_Entry() {
	global LTE_PROVIDER, LTE_BASE_URL
	return Map("Id", "token-entry", "Name", "x", "Provider", LTE_PROVIDER, "BaseUrl", LTE_BASE_URL,
		"Token", _LTE_Key(), "Model", "fixture-model")
}

_LTE_Answer(Post, Token := "fixture-access-token", Status := 200) {
	Body := (Status == 200) ? '{"access_token":"' . Token . '","expires_in":3600}' : '{"error":"invalid_grant"}'
	Post["answer"].Call(Map("status", Status, "body", Body))
}

_LTE_AssertNoSecret(Lines) {
	for Line in Lines {
		for Secret in ["fixture-secret", "fixture-refresh", "fixture-access-token", "eyJhbGci"]
			AssertFalse(InStr(Line, Secret, true), "no key, assertion or token reaches a log")
	}
}




; ===================================
; ===================================
; ======= 2/ The exchange corpus ====
; ===================================
; ===================================

_LTE_Parse() {
	Corpus := _LTE_ExchangeCorpus()
	AssertEqual(LLM_TOKEN_EXCHANGE_MIN_EXPIRES_SECONDS, Corpus["min_expires_seconds"])
	AssertEqual(LLM_TOKEN_EXCHANGE_MAX_EXPIRES_SECONDS, Corpus["max_expires_seconds"])
	AssertTrue(Corpus["parse"].Length >= 8, "the corpus holds parse rows")
	for Row in Corpus["parse"] {
		Auth := LLM_TokenExchange_Parse(_LTE_Block(Corpus, Row["block"], Row.Get("set", 0)), &Reason)
		AssertEqual(Row["valid"] ? true : false, Auth is Map, Row["name"] . " (" . Reason . ")")
	}
}
Test("Token exchange: the corpus's auth blocks", _LTE_Parse)

_LTE_Requests() {
	Corpus := _LTE_ExchangeCorpus()
	Keys := _LTE_Rs256Corpus()["keys"]
	AssertTrue(Corpus["requests"].Length >= 4, "the corpus holds request rows")
	for Row in Corpus["requests"] {
		Auth := LLM_TokenExchange_Parse(_LTE_Block(Corpus, Row["block"]), &Reason)
		AssertTrue(Auth is Map, Row["name"])
		Request := LLM_TokenExchange_Request(Auth, _LTE_StoredKey(Row, Keys), Corpus["unix_now"], &Reason)
		if Row.Has("reason") {
			AssertEqual("", Request, Row["name"])
			AssertEqual(Row["reason"], Reason, Row["name"])
			continue
		}
		AssertEqual("", Reason, Row["name"])
		AssertEqual(Corpus[Row["block"]]["token_url"], Request["url"], Row["name"])
		AssertEqual("application/x-www-form-urlencoded", Request["headers"]["Content-Type"], Row["name"])
		if Row.Has("body_prefix")
			AssertEqual(Row["body_prefix"], SubStr(Request["body"], 1, StrLen(Row["body_prefix"])), Row["name"])
		else
			AssertEqual(Row["body"], Request["body"], Row["name"])
	}
}
Test("Token exchange: every request of the corpus, byte for byte, signed assertions included", _LTE_Requests)

_LTE_Catalogue() {
	global _SharedDir
	Providers := _LTE_ReadJson("modules\llm\api_providers.json")["providers"]
	for Id in ["watsonx", "vertex"]
		AssertTrue(LLM_TokenExchange_Parse(Providers[Id]["auth"]) is Map, Id . "'s block is valid")
	Corpus := _LTE_ExchangeCorpus()
	AssertEqual("", _LVS_DeepEqual(Corpus["google"], Providers["vertex"]["auth"]),
		"the catalogue's Vertex AI block is the corpus's Google block")
	AssertTrue(LLM_API_PROVIDERS["vertex"]["Auth"] is Map, "the loaded catalogue carries it")
	AssertTrue(LLM_API_PROVIDERS["watsonx"]["Auth"] is Map)
}
Test("Token exchange: the shipped catalogue's blocks load", _LTE_Catalogue)

_LTE_Answers() {
	Corpus := _LTE_ExchangeCorpus()
	AssertTrue(Corpus["answers"].Length >= 5, "the corpus holds answers")
	for Row in Corpus["answers"] {
		Token := LLM_TokenExchange_Read(Corpus[Row["block"]], Row["status"], Row["json"], Row["now"], &Reason)
		if Row.Has("reason") {
			AssertEqual("", Token, Row["name"])
			AssertEqual(Row["reason"], Reason, Row["name"])
			continue
		}
		AssertEqual(Row["token"], Token["token"], Row["name"])
		AssertEqual(Row["expires_at"], Token["expires_at"], Row["name"])
	}
}
Test("Token exchange: the corpus's answers", _LTE_Answers)

_LTE_States() {
	Corpus := _LTE_ExchangeCorpus()
	AssertTrue(Corpus["states"].Length >= 4, "the corpus holds states")
	for Row in Corpus["states"] {
		Cached := Row.Has("expires_at") ? Map("token", "t", "expires_at", Row["expires_at"]) : 0
		Usable := LLM_TokenExchange_State(Corpus[Row["block"]], Cached, Row["now"], &Refresh)
		AssertEqual(Row["usable"] ? true : false, Usable ? true : false, Row["name"] . ": usable")
		AssertEqual(Row["refresh"] ? true : false, Refresh ? true : false, Row["name"] . ": refresh")
	}
}
Test("Token exchange: the corpus's refresh decisions", _LTE_States)

_LTE_NormalizeKey() {
	Pretty := '{`r`n  "type": "service_account",`n`t"private_key": "a\nb"`n}`n'
	AssertEqual('{  "type": "service_account","private_key": "a\nb"}', LLM_TokenExchange_NormalizeKey(Pretty),
		"a pasted file loses its line breaks, not its escaped ones")
	AssertEqual(" api`tkey ", LLM_TokenExchange_NormalizeKey(" api`tkey "), "a plain key stays exactly as typed")
}
Test("Token exchange: a pasted credentials file fits one stored line", _LTE_NormalizeKey)





; ===================================
; ===================================
; ======= 3/ The access slots =======
; ===================================
; ===================================

_LTE_OneExchange() {
	_LTE_Run(_Body)
	_Body(Posts, Lines) {
		Results := []
		Auth := LLM_API_PROVIDERS[LTE_PROVIDER]["Auth"]
		loop 3
			LLM_TokenExchange_Prepare(LTE_PROVIDER, Auth, _LTE_Key(), (Ok, Failure) => Results.Push(Ok))
		AssertEqual(0, Posts.Length, "nothing is signed or posted on the requesting thread")
		_LTE_Pump()
		AssertEqual(1, Posts.Length, "three waiters share one exchange")
		AssertEqual(0, Results.Length, "they wait for it")
		AssertEqual("https://oauth2.googleapis.com/token", Posts[1]["request"]["url"])
		_LTE_Answer(Posts[1])
		AssertEqual(3, Results.Length, "each waiter hears once")
		AssertTrue(Results[1] && Results[2] && Results[3])
		AssertEqual("fixture-access-token", LLM_TokenExchange_Current(LTE_PROVIDER, Auth, _LTE_Key()))
		LLM_TokenExchange_Prepare(LTE_PROVIDER, Auth, _LTE_Key(), (Ok, Failure) => Results.Push(Ok))
		AssertEqual(4, Results.Length, "a fresh token answers at once")
		_LTE_Pump()
		AssertEqual(1, Posts.Length, "without a second exchange")
		_LTE_AssertNoSecret(Lines)
	}
}
Test("Token exchange: waiters share one exchange and the token is cached", _LTE_OneExchange)

_LTE_Refusal() {
	_LTE_Run(_Body)
	_Body(Posts, Lines) {
		Results := []
		Auth := LLM_API_PROVIDERS[LTE_PROVIDER]["Auth"]
		LLM_TokenExchange_Prepare(LTE_PROVIDER, Auth, _LTE_Key(), (Ok, Failure) => Results.Push(Failure))
		_LTE_Pump()
		_LTE_Answer(Posts[1], "", 400)
		AssertEqual("the token exchange answered HTTP 400", Results[1]["refusal"])
		AssertTrue(Results[1]["key_refused"], "a 4xx is the key's fault")
		LLM_TokenExchange_Prepare(LTE_PROVIDER, Auth, _LTE_Key(), (Ok, Failure) => Results.Push(Failure))
		AssertEqual(2, Results.Length, "during the pause the refusal answers at once")
		_LTE_Pump()
		AssertEqual(1, Posts.Length, "and the token service is left alone")
		AssertEqual("", LLM_TokenExchange_Current(LTE_PROVIDER, Auth, _LTE_Key()), "a keystroke retries nothing either")
		_LTE_Pump()
		AssertEqual(1, Posts.Length)
		AssertTrue(_LVS_LinesMentioning(Lines, "[ERROR]") >= 1, "the refusal is logged")
		_LTE_AssertNoSecret(Lines)
	}
}
Test("Token exchange: a refused key pauses the next attempt", _LTE_Refusal)

_LTE_RefreshMargin() {
	_LTE_Run(_Body)
	_Body(Posts, Lines) {
		Auth := LLM_API_PROVIDERS[LTE_PROVIDER]["Auth"]
		Slot := _LLM_TokenExchange_Slot(LTE_PROVIDER, _LTE_Key())
		Slot["token"] := "old-token"
		Slot["expires_at"] := _LLM_TokenExchange_Now() + 100
		AssertEqual("old-token", LLM_TokenExchange_Current(LTE_PROVIDER, Auth, _LTE_Key()), "still sent in the margin")
		_LTE_Pump()
		AssertEqual(1, Posts.Length, "while a refresh runs behind it")
		_LTE_Answer(Posts[1], "new-token")
		AssertEqual("new-token", LLM_TokenExchange_Current(LTE_PROVIDER, Auth, _LTE_Key()))
	}
}
Test("Token exchange: a token in its refresh margin is sent while it is refreshed", _LTE_RefreshMargin)

_LTE_BadKeyFile() {
	_LTE_Run(_Body)
	_Body(Posts, Lines) {
		Results := []
		Auth := LLM_API_PROVIDERS[LTE_PROVIDER]["Auth"]
		LLM_TokenExchange_Prepare(LTE_PROVIDER, Auth, "not-json", (Ok, Failure) => Results.Push(Failure))
		_LTE_Pump()
		AssertEqual(0, Posts.Length, "nothing is posted for a key that cannot fill the form")
		AssertEqual("the key holds no client_id field", Results[1]["refusal"])
		AssertTrue(Results[1]["key_refused"])
		AssertFalse(_LLM_TokenExchange_Slot(LTE_PROVIDER, "not-json")["pending"], "the slot never stays pending")
	}
}
Test("Token exchange: a key that cannot fill the form settles without a request", _LTE_BadKeyFile)





; =======================================
; =======================================
; ======= 4/ Requests wait for it =======
; =======================================
; =======================================

_LTE_ResolverNeverSendsTheKey() {
	_LTE_Run(_Body)
	_Body(Posts, Lines) {
		Resolved := _LLMRemoteResolveEntry(_LTE_Entry())
		AssertTrue(Resolved is Map, "the entry is usable")
		AssertEqual("", Resolved["Token"], "before its token, no credential at all")
		AssertTrue(_LLMRemote_NeedsAccess(Resolved))
		AssertFalse(InStr(_LLMRemote_BuildCurlConfig(Resolved["Format"], Resolved["Token"], "https://x.invalid/"),
			"fixture-secret"), "the stored key is never a Bearer")
		_LTE_Pump()
		_LTE_Answer(Posts[1])
		AssertFalse(_LLMRemote_NeedsAccess(Resolved))
		AssertContains(_LLMRemote_BuildCurlConfig(Resolved["Format"], Resolved["Token"], "https://x.invalid/"),
			"Authorization: Bearer fixture-access-token", "the request carries the access token")
	}
}
Test("Token exchange: a resolved entry carries the access token, never the stored key", _LTE_ResolverNeverSendsTheKey)

_LTE_GenerateWaits() {
	_LTE_Run(_Body)
	_Body(Posts, Lines) {
		global _LLM_Remote_Async
		Fails := []
		ReqId := LLM_RemoteGenerate_Async(_LTE_Entry(), "s", "u", 0.1, (*) => 0, (Info := "") => Fails.Push(Info))
		AssertTrue(_LLM_Remote_Async.Has(ReqId), "the reservation waits")
		AssertFalse(_LLM_Remote_Async[ReqId].Has("http"), "nothing reached the transport")
		_LTE_Pump()
		_LTE_Answer(Posts[1], "", 401)
		AssertFalse(_LLM_Remote_Async.Has(ReqId), "a refused exchange ends the request")
		AssertEqual(1, Fails.Length, "exactly once")
		AssertEqual("token_exchange", Fails[1]["reason"])
		AssertEqual(401, Fails[1]["status"])
	}
}
Test("Token exchange: a prediction waits for its token and fails with the refusal", _LTE_GenerateWaits)

_LTE_GenerateCancelled() {
	_LTE_Run(_Body)
	_Body(Posts, Lines) {
		global _LLM_Remote_Async
		Heard := []
		ReqId := LLM_RemoteGenerate_Async(_LTE_Entry(), "s", "u", 0.1, (*) => Heard.Push("ok"), (*) => Heard.Push("fail"))
		LLM_RemoteCancelAsync(ReqId)
		_LTE_Pump()
		AssertEqual(1, Posts.Length, "a keystroke's cancel does not stop the exchange the next request needs")
		_LTE_Answer(Posts[1])
		AssertFalse(_LLM_Remote_Async.Has(ReqId), "the cancelled request goes when it settles")
		AssertEqual(0, Heard.Length, "and hears nothing")
		AssertEqual("fixture-access-token", LLM_TokenExchange_Current(LTE_PROVIDER, LLM_API_PROVIDERS[LTE_PROVIDER]["Auth"], _LTE_Key()),
			"the token is kept for the next one")
	}
}
Test("Token exchange: a cancelled prediction leaves the shared exchange running", _LTE_GenerateCancelled)

_LTE_ResumeDispatches() {
	Reservation := Map("cancelled", false, "requester_current", 0)
	global _LLM_Remote_Async
	Id := 0x7FFFFF01
	_LLM_Remote_Async[Id] := Reservation
	Sent := []
	try {
		_LLMRemote_ResumeAfterAccess(Id, Reservation, (*) => Sent.Push("fail"), () => Sent.Push("sent"), true, 0)
		AssertEqual("sent", Sent[1], "a settled token resumes the dispatch")
		AssertEqual(1, Sent.Length)
	} finally _LLM_Remote_Async.Delete(Id)
}
Test("Token exchange: a settled token resumes the waiting dispatch", _LTE_ResumeDispatches)

_LTE_Readiness() {
	_LTE_Run(_Body)
	_Body(Posts, Lines) {
		global LLM_REMOTE_READY_PING_DEADLINE_MS
		SavedDeadline := LLM_REMOTE_READY_PING_DEADLINE_MS
		LLM_REMOTE_READY_PING_DEADLINE_MS := 30000
		try {
			Results := []
			Owner := LLM_RemoteIsReady_Async(_LTE_Entry(), (Value) => Results.Push(Value))
			_LTE_Pump()
			AssertEqual(1, Posts.Length, "saving an entry exchanges its key")
			_LTE_Answer(Posts[1], "", 401)
			AssertEqual(false, Results[1], "a refused key is not reachable")
			AssertEqual(401, Owner["http_status"])
			AssertEqual("menu.llm.api_key_refused_", _LLM_Menu_ApiValidationFailurePrefix(Owner),
				"and is named as the key's fault")

			_LLM_TokenExchange_ResetForTest()
			Results := []
			LLM_RemoteIsReady_Async(_LTE_Entry(), (Value) => Results.Push(Value))
			_LTE_Pump()
			_LTE_Answer(Posts[2])
			AssertEqual(true, Results[1], "an access token proves the key, no model list is asked")
		} finally LLM_REMOTE_READY_PING_DEADLINE_MS := SavedDeadline
	}
}
Test("Token exchange: the save-time validation is the exchange itself", _LTE_Readiness)

_LTE_TestActionWording() {
	Tip := _LLM_Menu_ApiTestTip(false, "x", 0, "", _LLMRemote_AccessFailInfo(Map("status", 400)))
	AssertContains(Tip["body"], t("menu.llm.api_token_exchange_failed"), "the Test action names the exchange")
	Other := _LLM_Menu_ApiTestTip(false, "x", 0, "", _LLMRemote_FailInfo("transport"))
	AssertFalse(InStr(Other["body"], t("menu.llm.api_token_exchange_failed")), "and only it")
}
Test("Token exchange: the Test action words a refused exchange", _LTE_TestActionWording)

_LTE_GeminiRefused() {
	for Id, Provider in LLM_API_PROVIDERS
		AssertFalse(Provider.Get("Auth", "") is Map && Provider["Format"] == "gemini",
			Id . " keeps its credential out of its address")
}
Test("Token exchange: no gemini-format provider exchanges its key", _LTE_GeminiRefused)





; ========================================
; ========================================
; ======= 5/ The first screen read =======
; ========================================
; ========================================

_LTE_VisionMenu() {
	Menu := _LPP_Menu()
	Menu["api_entries"].Push(_LTE_Entry())
	return Menu
}

_LTE_VisionWaits() {
	_LTE_Run(_Exchange)
	_Exchange(Posts, Lines) {
		_LVS_Run(_LTE_VisionMenu(), _Body)
		_Body(Calls, VisionLines, Sent, Fx) {
			AssertTrue(_LVS_Invoke("llm_screen_region", LTE_PROVIDER . "|fixture-model"), "the action is accepted")
			AssertEqual(0, Fx.Captures.Length, "nothing is captured before the token")
			_LTE_Pump()
			AssertEqual(1, Posts.Length, "the key is exchanged")
			AssertEqual(0, Fx.Captures.Length, "still waiting")
			_LTE_Answer(Posts[1])
			AssertEqual(1, Fx.Captures.Length, "the capture starts once the token is known")
			_LVS_Complete(Fx.Captures[1], true)
			AssertEqual(1, Fx.Vision.Length, "the vision request goes")
			AssertContains(_LLMRemote_BuildCurlConfig(Fx.Vision[1]["resolved"]["Format"], Fx.Vision[1]["resolved"]["Token"],
				Fx.Vision[1]["url"]), "Authorization: Bearer fixture-access-token", "with the access token")
			AssertEqual(1, Posts.Length, "a second exchange was not needed")
			_LTE_AssertNoSecret(VisionLines)
		}
	}
}
Test("Token exchange: the first screen reading waits for its token, then captures and sends it", _LTE_VisionWaits)

_LTE_VisionRefused() {
	_LTE_Run(_Exchange)
	_Exchange(Posts, Lines) {
		_LVS_Run(_LTE_VisionMenu(), _Body)
		_Body(Calls, VisionLines, Sent, Fx) {
			AssertTrue(_LVS_Invoke("llm_screen_full", LTE_PROVIDER . "|fixture-model"))
			_LTE_Pump()
			_LTE_Answer(Posts[1], "", 400)
			AssertEqual(0, Fx.Captures.Length, "nothing is captured for a request that is refused")
			AssertEqual(0, Fx.Vision.Length)
			AssertTrue(_LVS_LinesMentioning(VisionLines, "could not be fetched") >= 1, "the reason is logged")
		}
	}
}
Test("Token exchange: a screen reading whose exchange is refused captures nothing", _LTE_VisionRefused)

_LTE_VisionSuperseded() {
	_LTE_Run(_Exchange)
	_Exchange(Posts, Lines) {
		_LVS_Run(_LTE_VisionMenu(), _Body)
		_Body(Calls, VisionLines, Sent, Fx) {
			AssertTrue(_LVS_Invoke("llm_screen_region", LTE_PROVIDER . "|fixture-model"))
			AssertTrue(_LVS_Invoke("llm_screen_full", LTE_PROVIDER . "|fixture-model"))
			_LTE_Pump()
			AssertEqual(1, Posts.Length, "both wait on one exchange")
			_LTE_Answer(Posts[1])
			AssertEqual(1, Fx.Captures.Length, "only the newest action captures")
			AssertEqual("full", Fx.Captures[1].Kind)
		}
	}
}
Test("Token exchange: a newer screen reading drops the one still waiting", _LTE_VisionSuperseded)

; The AI agent resolves its target with a pending token and sends through here.
_LTE_AgentSendWaits() {
	_LTE_Run(_Exchange)
	_Exchange(Posts, Lines) {
		global _LLM_Vision_RemoteTransport
		Saved := _LLM_Vision_RemoteTransport
		Sent := [], Failed := []
		_LLM_Vision_RemoteTransport := (Resolved, Url, Body, OnSuccess, OnFail, CurrentFn) => Sent.Push(Resolved["Token"])
		try {
			Target := Map("format", "openai", "url", "https://x.invalid/", "resolved", _LLMRemoteResolveEntry(_LTE_Entry()))
			_LLM_Vision_Send(Target, "{}", (*) => 0, (Info := "") => Failed.Push(Info), false)
			AssertEqual(0, Sent.Length, "the request waits for its token")
			_LTE_Pump()
			_LTE_Answer(Posts[1])
			AssertEqual("fixture-access-token", Sent[1], "and carries it")

			_LLM_TokenExchange_ResetForTest()
			Target := Map("format", "openai", "url", "https://x.invalid/", "resolved", _LLMRemoteResolveEntry(_LTE_Entry()))
			_LLM_Vision_Send(Target, "{}", (*) => 0, (Info := "") => Failed.Push(Info), false)
			_LTE_Pump()
			_LTE_Answer(Posts[2], "", 400)
			AssertEqual(1, Sent.Length, "a refused exchange sends nothing")
			AssertEqual("token_exchange", Failed[1]["reason"], "and fails with its reason")
		} finally _LLM_Vision_RemoteTransport := Saved
	}
}
Test("Token exchange: a request sent to a named backend waits for its token", _LTE_AgentSendWaits)

_LTE_VisionFreshToken() {
	_LTE_Run(_Exchange)
	_Exchange(Posts, Lines) {
		Slot := _LLM_TokenExchange_Slot(LTE_PROVIDER, _LTE_Key())
		Slot["token"] := "fixture-access-token"
		Slot["expires_at"] := _LLM_TokenExchange_Now() + 3000
		_LVS_Run(_LTE_VisionMenu(), _Body)
		_Body(Calls, VisionLines, Sent, Fx) {
			AssertTrue(_LVS_Invoke("llm_screen_region", LTE_PROVIDER . "|fixture-model"))
			AssertEqual(1, Fx.Captures.Length, "a fresh token captures at once")
			AssertEqual(0, Posts.Length)
		}
	}
}
Test("Token exchange: a screen reading with a fresh token does not wait", _LTE_VisionFreshToken)
