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
		AssertTrue(Results[1]["key_refused"], "the OAuth invalid-grant HTTP 400 identifies a refused credential")
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

_LTE_StatusClassification(Status, KeyRefused := false) {
	_LTE_Run(_Body)
	_Body(Posts, Lines) {
		Results := []
		Auth := LLM_API_PROVIDERS[LTE_PROVIDER]["Auth"]
		LLM_TokenExchange_Prepare(LTE_PROVIDER, Auth, _LTE_Key(), (Ok, Failure) => Results.Push(Failure))
		_LTE_Pump()
		AssertEqual(1, Posts.Length)
		Posts[1]["answer"].Call(Map("status", Status, "body",
			KeyRefused ? '{"error":"invalid_grant"}' : '{"error":"temporarily_unavailable"}'))
		AssertEqual(1, Results.Length)
		AssertEqual(Status, Results[1]["status"], "The actual exchange status must survive settlement")
		AssertEqual(KeyRefused, Results[1]["key_refused"], "Only an explicit authentication status may classify the key as refused")
		Slot := _LLM_TokenExchange_Slot(LTE_PROVIDER, _LTE_Key())
		AssertTrue(Slot["retry_at"] > _LLM_TokenExchange_Now(), "The existing bounded retry pause must remain active")
		LLM_TokenExchange_Prepare(LTE_PROVIDER, Auth, _LTE_Key(), (Ok, Failure) => Results.Push(Failure))
		_LTE_Pump()
		AssertEqual(2, Results.Length)
		AssertEqual(Status, Results[2]["status"])
		AssertEqual(KeyRefused, Results[2]["key_refused"])
		AssertEqual(1, Posts.Length, "A second waiter must not bypass the shared retry pause")
		_LTE_AssertNoSecret(Lines)
	}
}
for _LTE_TransientStatus in [404, 405, 408, 413, 429, 503]
	Test("Token exchange: HTTP " . _LTE_TransientStatus . " preserves a non-authentication refusal (token-status-classification)",
		_LTE_StatusClassification.Bind(_LTE_TransientStatus))

for _LTE_AuthStatus in [400, 401, 403]
	Test("Token exchange: HTTP " . _LTE_AuthStatus . " retains explicit authentication refusal (token-status-authentication)",
		_LTE_StatusClassification.Bind(_LTE_AuthStatus, true))

_LTE_NonAuthReadiness(Status) {
	_LTE_Run(_Body)
	_Body(Posts, Lines) {
		global LLM_REMOTE_READY_PING_DEADLINE_MS
		SavedDeadline := LLM_REMOTE_READY_PING_DEADLINE_MS
		Owner := 0
		LLM_REMOTE_READY_PING_DEADLINE_MS := 30000
		try {
			Results := []
			Owner := LLM_RemoteIsReady_Async(_LTE_Entry(), (Value) => Results.Push(Value))
			_LTE_Pump()
			AssertEqual(1, Posts.Length)
			Posts[1]["answer"].Call(Map("status", Status, "body", '{"error":"temporarily_unavailable"}'))
			AssertEqual(1, Results.Length)
			AssertEqual(false, Results[1])
			AssertEqual(Status, Owner["http_status"], "Validation must not rewrite the actual transient status to HTTP 401")
			AssertEqual("menu.llm.api_unreachable_", _LLM_Menu_ApiValidationFailurePrefix(Owner),
				"Validation must report service availability rather than accuse the stored key")
			_LTE_AssertNoSecret(Lines)
		} finally {
			if Owner is Map
				LLM_AuxFinish(Owner)
			LLM_REMOTE_READY_PING_DEADLINE_MS := SavedDeadline
		}
	}
}
for _LTE_ReadyStatus in [408, 429]
	Test("Token exchange: validation retains HTTP " . _LTE_ReadyStatus . " without key refusal (token-status-readiness)",
		_LTE_NonAuthReadiness.Bind(_LTE_ReadyStatus))


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
	Reservation := Map("cancelled", false, "requester_current", 0, "start_tick", A_TickCount, "timeout_ms", 20000)
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


; Raw body retries retain the current access token and original requester.
; Existing token engine and managed facade execute unchanged; only native spawn
; uses the existing explicit I/O port. This is not proof of native wire success.
_LTERP_NewHttp(Control) {
    Request := CurlAsyncRequest(Map("spawn", _ManagedCurlControlSpawn.Bind(Control)))
    Control["request"] := Request
    return Request
}

_LTERP_Header(Control, Expected) {
    Request := Control["request"]
    AssertEqual(1, Control["spawns"])
    AssertFalse(Request.ManagedPayloadPublished)
    SetTimer(Request.ManagedAdmissionFn, 0)
    _ManagedCurlControlAck(Control)
    Request._PollManagedAdmission()
    AssertTrue(Request.ManagedPayloadPublished)
    Published := JsonParse(FSReadUtf8Exact(Control["directory"] . "transport.json"))
    Found := []
    for Header in Published["headers"]
        if StrLower(Header["name"]) == "authorization"
            Found.Push(Header["value"])
    AssertEqual(1, Found.Length)
    AssertEqual("Bearer " . Expected, Found[1], "the real managed transport image must use the current slot token")
    AssertEqual(Request.CleanupDebtId, Published["request_id"])
    return Published
}

_LTERP_Body(Mode, Posts, Lines) {
    global LTE_PROVIDER, _LLM_Remote_Async
    AssertEqual(0, _LLM_Remote_Async.Count, "no foreign reservation may be borrowed")
    AssertFalse(A_IsSuspended)
    Control := _ManagedCurlControlState()
    Port := Map("managed_settings", (*) => Map("auto_detect", false, "pac_url", "", "proxy", "", "bypass", ""),
        "create_http", _LTERP_NewHttp.Bind(Control))
    Heard := [], Id := 0, Owner := 0
    Slot := _LLM_TokenExchange_Slot(LTE_PROVIDER, _LTE_Key())
    Slot["token"] := "old-token", Slot["expires_at"] := _LLM_TokenExchange_Now() + 3600
    Resolved := _LLMRemoteResolveEntry(_LTE_Entry())
    AssertFalse(_LLMRemote_NeedsAccess(Resolved), "the original access preparation must really consume its fresh slot")
    AssertEqual("old-token", Resolved["Token"])
    if Mode == "renewed"
        Slot["token"] := "new-token"
    else if Mode != "fresh"
        Slot["expires_at"] := _LLM_TokenExchange_Now() - 1
    try {
        Id := LLM_RemotePostBody_Async(Resolved, "https://token-fixture.invalid/v1/chat/completions",
            '{"messages":[]}', (*) => Heard.Push("ok"), (Info := "") => Heard.Push(Info),
            20000, "token_rawpost_control", 0, 0, Port)
        AssertTrue(Id is Integer && Id > 0)
        AssertTrue(_LLM_Remote_Async.Has(Id))
        Owner := _LLM_Remote_Async[Id]
        Origin := Owner["start_tick"], Duration := Owner["timeout_ms"]
        if Mode == "fresh" || Mode == "renewed" {
            AssertEqual(0, Posts.Length, "a fresh cached token must not start exchange")
            Published := _LTERP_Header(Control, Mode == "fresh" ? "old-token" : "new-token")
        } else {
            AssertFalse(Owner.Has("http"), "expired tokens must not reach any transport before exchange")
            AssertEqual(0, Control["spawns"])
            _LTE_Pump()
            AssertEqual(1, Posts.Length, "the genuine token engine must start one exchange")
            if Mode == "cancel"
                LLM_RemoteCancelAsync(Id)
            else if Mode == "deadline"
                Owner["start_tick"] := (A_TickCount - Duration - 1) & 0xFFFFFFFF
            if Mode == "pause"
                Suspend(true)
            try _LTE_Answer(Posts[1], "new-token")
            finally {
                if Mode == "pause"
                    Suspend(false)
            }
            if Mode == "exchange" {
                AssertTrue(_LLM_Remote_Async.Has(Id) && _LLM_Remote_Async[Id] == Owner,
                    "exchange must resume the same reservation")
                AssertEqual(Origin, Owner["start_tick"], "exchange cannot reset the original clock")
                AssertEqual(Duration, Owner["timeout_ms"])
                Published := _LTERP_Header(Control, "new-token")
            } else {
                AssertFalse(_LLM_Remote_Async.Has(Id), "retired requester cannot resume dispatch")
                AssertEqual(0, Control["spawns"], "cancel, expiry or pause cannot publish any managed token image")
                if Mode == "deadline" {
                    AssertEqual(1, Heard.Length, "a spent live request reports its original timeout once")
                    AssertEqual("timeout", Heard[1]["reason"])
                } else
                    AssertEqual(0, Heard.Length, "cancelled or suspended requester cannot publish a verdict")
            }
        }
        if Mode == "fresh" || Mode == "renewed" || Mode == "exchange" {
            AssertEqual(Origin, Control["input"]["started_tick"])
            AssertEqual(Duration, Control["input"]["deadline_ms"])
            AssertEqual('{"messages":[]}', Published["body"])
        }
        AssertEqual(Mode == "fresh" ? "old-token" : "new-token", Slot["token"])
    } finally {
        if A_IsSuspended
            Suspend(false)
        if Owner is Map && _LLM_Remote_Async.Has(Id) && _LLM_Remote_Async[Id] == Owner {
            LLM_RemoteCancelAsync(Id)
            _LLMRemote_PollRequest(Id)
        }
        if Control.Has("request") {
            Request := Control["request"]
            Request.Abort()
            AssertFalse(IsObject(Request.Handle), "controlled exact Job retirement must finish before releasing controls")
        }
        AssertFalse(_LLM_Remote_Async.Has(Id), "an exact failed retirement must stay visible and fail qualification")
        _ManagedCurlControlRelease(Control)
    }
}

_LTERP_Run(Mode) {
    _ManagedRemoteFixtureWithLlmTimings(_LTE_Run.Bind(_LTERP_Body.Bind(Mode)))
}
for _LTERP_Mode in ["fresh", "renewed", "exchange", "cancel", "deadline", "pause"]
    Test("Token exchange: raw POST " . _LTERP_Mode . " preserves current access and owner (token-rawpost-owner)",
        _LTERP_Run.Bind(_LTERP_Mode))

; Public readiness, genuine token engine/PostFn and actual AHK timer delivery.
_LTED_Reply(State, Post, Owner, Expired) {
    PreviousCritical := Critical("On")
    try {
        State.TimerCalls += 1
        AssertTrue(LLM_AuxIsCurrent(Owner), "the controlled answer timer must enter before the real deadline timer")
        AssertFalse(_LLM_DeadlineExpired(Owner["network_start_tick"], Owner["network_timeout_ms"]),
            "the answer timer must begin under the live original clock")
        if Expired {
            ; Model a reply handler whose processing straddles the actual budget.
            ; No origin/deadline is changed; the due deadline timer cannot interrupt
            ; this real timer thread. Waiting is bounded by the owned 96 ms budget.
            while !_LLM_DeadlineExpired(Owner["network_start_tick"], Owner["network_timeout_ms"]) {
            }
        }
        State.ElapsedAtAnswer := TickElapsed(Owner["network_start_tick"])
        State.OwnerCurrentAtAnswer := LLM_AuxIsCurrent(Owner)
        _LTE_Answer(Post, "fixture-access-token")
    } catch Any as Failure {
        State.Failure := Failure
    } finally {
        State.TimerDone := true
        Critical(PreviousCritical)
    }
}

_LTED_Body(Expired, Posts, Lines) {
    global LLM_REMOTE_READY_PING_DEADLINE_MS, _LLM_AuxOwners, LTE_PROVIDER, LLM_API_PROVIDERS
    SavedBudget := LLM_REMOTE_READY_PING_DEADLINE_MS
    State := {TimerCalls: 0, TimerDone: false, Failure: 0, ElapsedAtAnswer: -1, OwnerCurrentAtAnswer: false}
    Heard := [], Owner := 0, Reply := 0
    PreviousCritical := Critical("Off")
    try {
        AssertFalse(A_IsSuspended)
        AssertEqual(0, _LLM_AuxOwners.Count, "no foreign auxiliary owner may be borrowed")
        LLM_REMOTE_READY_PING_DEADLINE_MS := 96
        Owner := LLM_RemoteIsReady_Async(_LTE_Entry(), (Value) => Heard.Push(Value))
        Origin := Owner["network_start_tick"], Budget := Owner["network_timeout_ms"]
        _LTE_Pump()
        AssertEqual(1, Posts.Length, "the genuine exchange must be pending")
        AssertEqual(0, Heard.Length, "readiness waits for the genuine token answer")
        Reply := _LTED_Reply.Bind(State, Posts[1], Owner, Expired)
        SetTimer(Reply, -1)
        StartedWait := A_TickCount
        while !State.TimerDone && TickElapsed(StartedWait) < 3000
            Sleep(1)
        AssertTrue(State.TimerDone, "the actual owned answer timer must execute")
        if IsObject(State.Failure)
            throw State.Failure
        AssertEqual(1, State.TimerCalls)
        AssertTrue(State.OwnerCurrentAtAnswer)
        AssertEqual(Origin, Owner["network_start_tick"], "the real original clock must remain unchanged")
        AssertEqual(Budget, Owner["network_timeout_ms"])
        AssertEqual(1, Heard.Length, "the actual request must settle exactly once")
        _TestPrint("# TOKEN_READY_DEADLINE " . KL_JsonEncode(Map("expired", Expired,
            "elapsed_at_answer", State.ElapsedAtAnswer, "budget", Budget,
            "owner_current_at_answer", State.OwnerCurrentAtAnswer,
            "answer_timer_calls", State.TimerCalls, "posts", Posts.Length, "reachable", Heard[1])))
        AssertEqual(!Expired, Heard[1], "a late usable token must not turn an expired validation into success")
        AssertFalse(LLM_AuxIsCurrent(Owner))
        ; The deadline belongs to this requester, not to the shared token cache.
        AssertEqual("fixture-access-token", LLM_TokenExchange_Current(LTE_PROVIDER,
            LLM_API_PROVIDERS[LTE_PROVIDER]["Auth"], _LTE_Key()))
    } finally {
        if IsObject(Reply)
            SetTimer(Reply, 0)
        if Owner is Map && LLM_AuxIsCurrent(Owner)
            LLM_AuxFinish(Owner)
        LLM_REMOTE_READY_PING_DEADLINE_MS := SavedBudget
        Critical(PreviousCritical)
    }
}

_LTED_Run(Expired) {
    _ManagedRemoteFixtureWithLlmTimings(_LTE_Run.Bind(_LTED_Body.Bind(Expired)))
}
Test("Token exchange: readiness accepts a timely actual token timer (token-ready-deadline)", _LTED_Run.Bind(false))
Test("Token exchange: readiness refuses a late actual token timer (token-ready-deadline)", _LTED_Run.Bind(true))

; Actual token engine, private Post, managed facade, timers and Suspend state.
; Existing controlled Job supplies only the native process I/O boundary.
_LTEP_NewHttp(Controls) {
    Control := _ManagedCurlControlState()
    Http := CurlAsyncRequest(Map("spawn", _ManagedCurlControlSpawn.Bind(Control)))
    Control["request"] := Http
    Controls.Push(Control)
    return Http
}

_LTEP_Post(Controls, Request, OnAnswer) {
    Reader := (*) => Map("auto_detect", false, "pac_url", "", "proxy", "", "bypass", "")
    Port := Map("managed_settings", Reader, "create_http", _LTEP_NewHttp.Bind(Controls))
    _LLM_TokenExchange_Post(Request, OnAnswer, Port)
}

_LTEP_Wait(Predicate, Budget := 2000) {
    Start := A_TickCount
    while !Predicate.Call() && TickElapsed(Start) < Budget
        Sleep(1)
    return Predicate.Call()
}

_LTEP_Admit(Control) {
    Http := Control["request"]
    AssertEqual(1, Control["spawns"])
    AssertFalse(Http.Completed || Http.Aborted)
    AssertTrue(IsObject(Http.Handle))
    _ManagedCurlControlAck(Control)
    Http._PollManagedAdmission()
    AssertTrue(Http.ManagedPayloadPublished, "actual exchange body must reach real managed publication")
}

_LTEP_Terminal(Control, Status) {
    Http := Control["request"]
    Body := Status == 200 ? '{"access_token":"fixture-access-token","expires_in":3600}' : '{"error":"invalid_grant"}'
    AssertTrue(FSWrite(Http.BodyPath, Body))
    AssertTrue(FSWrite(Http.HeaderPath, "HTTP/1.1 " . Status . " Owned`r`nContent-Type: application/json`r`n`r`n"))
    Control["callback"].Call(0, '{"schema_version":1,"ok":true,"status":' . Status
        . ',"child_quiesced":true,"receipt":{}}', "")
    AssertTrue(Http.Completed)
}

_LTEP_Body(Mode, Posts, Lines) {
    global _LLM_TokenExchange_PostFn, LLM_API_PROVIDERS, LTE_PROVIDER, LLM_REMOTE_TIMEOUT_MS
    Controls := [], Results := [], CleanupIssues := [], Primary := 0, Slot := 0
    SavedPost := _LLM_TokenExchange_PostFn, SavedTimeout := LLM_REMOTE_TIMEOUT_MS
    PreviousCritical := Critical("Off")
    try {
        AssertFalse(A_IsSuspended)
        _LLM_TokenExchange_PostFn := _LTEP_Post.Bind(Controls)
        ; Timeout control uses a genuine short owned deadline, never a moved tick.
        if Mode == "timeout"
            LLM_REMOTE_TIMEOUT_MS := 250
        Auth := LLM_API_PROVIDERS[LTE_PROVIDER]["Auth"]
        Slot := _LLM_TokenExchange_Slot(LTE_PROVIDER, _LTE_Key())
        LLM_TokenExchange_Prepare(LTE_PROVIDER, Auth, _LTE_Key(),
            (Ok, Failure) => Results.Push(Map("ok", Ok, "failure", Failure, "paused", A_IsSuspended)))
        AssertTrue(_LTEP_Wait(() => Controls.Length == 1), "the real token Begin timer must create its facade")
        Control := Controls[1], Http := Control["request"]
        _LTEP_Admit(Control)
        if Mode == "pause" || Mode == "resume_before_poll" {
            ReplyCritical := Critical("On")
            try {
                Suspend(true)
                AssertTrue(A_IsSuspended)
                ; Same genuine late terminal, but the consumer can be held until
                ; AFTER resume. The provenance must survive that scheduling gap.
                _LTEP_Terminal(Control, 200)
                if Mode == "resume_before_poll" {
                    AssertTrue(Slot["pending"], "the token consumer must not have run under this short controlled critical section")
                    Suspend(false)
                }
            } finally Critical(ReplyCritical)
        } else if Mode != "timeout"
            _LTEP_Terminal(Control, Mode == "denied" ? 403 : 200)
        AssertTrue(_LTEP_Wait(() => !Slot["pending"]), "the actual token polling timer must settle its slot")
        AssertEqual(1, Results.Length)
        AssertFalse(IsObject(Http.Handle), "native controlled ownership must retire before resume")
        if Mode == "pause" || Mode == "resume_before_poll" {
            AssertTrue(Http.Aborted, "actual managed admission must reject the late response while suspended")
            AssertEqual(0, Http.Status)
            AssertEqual(Mode == "pause", Results[1]["paused"], "real token timer must observe the requested settlement phase")
            Suspend(false)
        }
        if Mode == "timeout" {
            AssertTrue(Http.Aborted)
            AssertEqual(0, Http.Status)
        }
        BeforeNext := Controls.Length
        LLM_TokenExchange_Prepare(LTE_PROVIDER, Auth, _LTE_Key(),
            (Ok, Failure) => Results.Push(Map("ok", Ok, "failure", Failure, "paused", A_IsSuspended)))
        if Mode == "pause" || Mode == "resume_before_poll"
            _LTEP_Wait(() => Controls.Length == BeforeNext + 1 || Results.Length > 1)
        RetryActive := Slot.Has("retry_at") && Slot["retry_at"] > _LLM_TokenExchange_Now()
        FirstFailure := Results[1]["failure"]
        _TestPrint("# TOKEN_PAUSE_RETRY " . KL_JsonEncode(Map("case", Mode,
            "first_ok", Results[1]["ok"], "first_status", FirstFailure is Map ? FirstFailure["status"] : 0,
            "first_key_refused", FirstFailure is Map ? FirstFailure["key_refused"] : false,
            "http_completed", Http.Completed, "http_aborted", Http.Aborted,
            "settled_while_paused", Results[1]["paused"],
            "payload_published", Http.ManagedPayloadPublished,
            "retry_active", RetryActive, "post_count_before_resume", BeforeNext,
            "post_count_after_resume", Controls.Length, "verdicts", Results.Length)))
        if Mode == "pause" || Mode == "resume_before_poll" {
            AssertFalse(Results[1]["ok"])
            AssertFalse(RetryActive, "revocation by user pause must not impose a provider-failure cooldown after resume")
            AssertEqual(2, Controls.Length, "resume must be able to start a real next exchange immediately")
            AssertEqual(1, Results.Length, "the new requester waits for its new exchange instead of hearing a cached refusal")
        } else if Mode == "success" {
            AssertTrue(Results[1]["ok"] && Results[2]["ok"])
            AssertFalse(RetryActive)
            AssertEqual(1, Controls.Length, "the usable token answers from cache")
        } else {
            AssertFalse(Results[1]["ok"] || Results[2]["ok"])
            AssertEqual(Mode == "denied" ? 403 : 0, FirstFailure["status"])
            AssertEqual(Mode == "denied", FirstFailure["key_refused"])
            AssertTrue(RetryActive, "genuine 403 and timeout failures retain the intended bounded cooldown")
            AssertEqual(1, Controls.Length)
        }
    } catch Any as Failure {
        Primary := Failure
    } finally {
        if A_IsSuspended
            Suspend(false)
        for Control in Controls {
            Http := Control["request"]
            try {
                AssertTrue(Http.Abort(), "the exact controlled Job must retire")
                AssertFalse(IsObject(Http.Handle))
            } catch Any as Failure {
                CleanupIssues.Push(Map("phase", "facade-abort", "error", Type(Failure), "message", SubStr(Failure.Message, 1, 300)))
                if !IsObject(Primary)
                    Primary := Failure
            }
        }
        if Slot is Map {
            try AssertTrue(_LTEP_Wait(() => !Slot["pending"]), "all actual token timers must settle before slot reset")
            catch Any as Failure {
                CleanupIssues.Push(Map("phase", "slot-settlement", "error", Type(Failure), "message", SubStr(Failure.Message, 1, 300)))
                if !IsObject(Primary)
                    Primary := Failure
            }
        }
        for Control in Controls {
            try {
                if !IsObject(Control["request"].Handle)
                    _ManagedCurlControlRelease(Control)
            } catch Any as Failure {
                CleanupIssues.Push(Map("phase", "control-release", "error", Type(Failure), "message", SubStr(Failure.Message, 1, 300)))
                if !IsObject(Primary)
                    Primary := Failure
            }
        }
        _LLM_TokenExchange_PostFn := SavedPost
        LLM_REMOTE_TIMEOUT_MS := SavedTimeout
        Critical(PreviousCritical)
        if CleanupIssues.Length > 0
            _TestPrint("# TOKEN_PAUSE_CLEANUP " . KL_JsonEncode(Map("case", Mode, "issues", CleanupIssues,
                "slot_pending", Slot is Map ? Slot["pending"] : false)))
    }
    if IsObject(Primary)
        throw Primary
}

_LTEP_Run(Mode) {
    _ManagedRemoteFixtureWithLlmTimings(_LTE_Run.Bind(_LTEP_Body.Bind(Mode)))
}
for _LTEP_Mode in ["success", "denied", "timeout", "pause", "resume_before_poll"]
    Test("Token exchange: actual managed " . _LTEP_Mode . " preserves correct retry policy (token-managed-pause)",
        _LTEP_Run.Bind(_LTEP_Mode))


_LTEWB_Observe(State) {
    State.Observed := true
}
_LTEWB_Body(Backend, Late, Posts, Lines) {
    global _LLM_Remote_Async, LLM_API_PROVIDERS, LTE_PROVIDER
    AssertFalse(A_IsSuspended)
    AssertEqual(0, _LLM_Remote_Async.Count)
    Heard := [], Shared := [], State := {Observed: false}, Observer := _LTEWB_Observe.Bind(State)
    Id := 0, Owner := 0, Primary := 0, Answered := false
    Slot := _LLM_TokenExchange_Slot(LTE_PROVIDER, _LTE_Key())
    PreviousCritical := Critical("Off")
    try {
        Success := (Text, Usage := "") => Heard.Push(Map("ok", true))
        Failure := (Info := "") => Heard.Push(Map("ok", false, "info", Info))
        ; Only the late case needs a budget that expires: the immediate control
        ; proves a reply inside the budget, and at 96 ms a loaded machine's
        ; reply could arrive after its own deadline and read as a timeout.
        Budget := Late ? 96 : 10000
        if Backend == "generate"
            Id := LLM_RemoteGenerate_Async(_LTE_Entry(), "Fixture system.", "Fixture user.", 0.1,
                Success, Failure, "", 8, "token_wait_budget", Budget)
        else {
            Resolved := _LLMRemoteResolveEntry(_LTE_Entry())
            Id := LLM_RemotePostBody_Async(Resolved, "https://token-fixture.invalid/v1/chat/completions", '{"messages":[]}',
                Success, Failure, Budget, "token_wait_budget")
        }
        AssertTrue(_LLM_Remote_Async.Has(Id))
        Owner := _LLM_Remote_Async[Id]
        Origin := Owner["start_tick"]
        AssertEqual(Budget, Owner["timeout_ms"])
        _LTE_Pump()
        AssertEqual(1, Posts.Length, "the actual token Begin timer must start one shared exchange")
        Slot := _LLM_TokenExchange_Slot(LTE_PROVIDER, _LTE_Key())
        AssertTrue(Slot["pending"])
        AssertFalse(Owner.Has("http"), "no remote request may dispatch before access preparation")
        AssertEqual(0, Heard.Length, "fixture must reach its pending phase before reply/deadline")
        LLM_TokenExchange_Prepare(LTE_PROVIDER, LLM_API_PROVIDERS[LTE_PROVIDER]["Auth"], _LTE_Key(),
            (Ok, Failure) => Shared.Push(Map("ok", Ok, "failure", Failure)))
        if Late {
            ; This observer timer is armed after the request and after Begin.
            ; Any proper original deadline timer is already due earlier; no
            ; origin is moved, no Critical region withholds its delivery.
            SetTimer(Observer, -(Budget + 1))
            Started := A_TickCount
            while !State.Observed && TickElapsed(Started) < 2000
                Sleep(1)
            AssertTrue(State.Observed)
            AssertTrue(_LLM_DeadlineExpired(Origin, Budget))
            BeforeCount := Heard.Length
            BeforePresent := _LLM_Remote_Async.Has(Id)
            BeforeElapsed := TickElapsed(Origin)
            BeforePending := Slot["pending"]
            BeforeShared := Shared.Length
            ; Preserve the shared exchange and give its genuine valid token to
            ; another waiter, even though this particular request has expired.
            Answered := true
            _LTE_Answer(Posts[1], "fixture-access-token")
            AssertEqual("fixture-access-token", LLM_TokenExchange_Current(LTE_PROVIDER,
                LLM_API_PROVIDERS[LTE_PROVIDER]["Auth"], _LTE_Key()))
            AssertEqual(1, Shared.Length)
            AssertTrue(Shared[1]["ok"])
            _TestPrint("# TOKEN_WAIT_BUDGET " . KL_JsonEncode(Map("backend", Backend, "late", Late,
                "budget", Budget, "elapsed_before_reply", BeforeElapsed,
                "callbacks_before_reply", BeforeCount, "reservation_before_reply", BeforePresent,
                "shared_pending_before_reply", BeforePending, "other_waiters_before_reply", BeforeShared,
                "callbacks_after_reply", Heard.Length, "reservation_after_reply", _LLM_Remote_Async.Has(Id),
                "other_waiter_ok", Shared[1]["ok"], "token_posts", Posts.Length)))
            AssertTrue(BeforePending && BeforeShared == 0, "one request budget must not cancel the shared token lease")
            AssertEqual(1, BeforeCount, "the request's own deadline must settle without waiting for the shared exchange")
            AssertFalse(BeforePresent, "expired request must retire while the token exchange remains pending")
            AssertEqual(1, Heard.Length, "late token must not publish a second verdict")
            AssertFalse(Heard[1]["ok"])
            AssertEqual("timeout", Heard[1]["info"]["reason"])
        } else {
            AssertFalse(_LLM_DeadlineExpired(Origin, Budget), "the immediate control must still have its real budget")
            Answered := true
            _LTE_Answer(Posts[1], "", 403)
            _TestPrint("# TOKEN_WAIT_BUDGET " . KL_JsonEncode(Map("backend", Backend, "late", Late,
                "budget", Budget, "elapsed_after_reply", TickElapsed(Origin), "callbacks", Heard.Length,
                "reservation_present", _LLM_Remote_Async.Has(Id), "token_posts", Posts.Length)))
            AssertEqual(1, Heard.Length)
            AssertFalse(Heard[1]["ok"])
            AssertEqual("token_exchange", Heard[1]["info"]["reason"])
            AssertEqual(403, Heard[1]["info"]["status"])
            AssertEqual(1, Shared.Length)
            AssertFalse(Shared[1]["ok"])
        }
        AssertFalse(_LLM_Remote_Async.Has(Id))
        AssertFalse(Owner.Has("http"), "both the spent-budget and refusal controls must dispatch no remote transport")
    } catch Any as Failure {
        Primary := Failure
    } finally {
        try {
            SetTimer(Observer, 0)
            if Owner is Map && _LLM_Remote_Async.Has(Id) && _LLM_Remote_Async[Id] == Owner
                LLM_RemoteCancelAsync(Id)
            StartedCleanup := A_TickCount
            while !Answered && Posts.Length == 0 && Slot["pending"] && TickElapsed(StartedCleanup) < 1000
                Sleep(1)
            if !Answered && Posts.Length {
                ; Settle rather than forget the real token callback. HTTP403
                ; cannot dispatch a remote request during fixture cleanup.
                _LTE_Answer(Posts[1], "", 403)
                Answered := true
            }
            if Owner is Map && _LLM_Remote_Async.Has(Id) && _LLM_Remote_Async[Id] == Owner {
                LLM_RemoteCancelAsync(Id)
                _LLMRemote_PollRequest(Id)
            }
            AssertFalse(_LLM_Remote_Async.Has(Id))
            AssertFalse(Slot["pending"], "the actual shared Begin/answer must settle before fixture ports restore")
        } catch Any as CleanupFailure {
            _TestPrint("# TOKEN_WAIT_BUDGET_CLEANUP " . KL_JsonEncode(Map("backend", Backend,
                "error", Type(CleanupFailure), "message", SubStr(CleanupFailure.Message, 1, 250))))
            if !IsObject(Primary)
                Primary := CleanupFailure
        }
        Critical(PreviousCritical)
    }
    if IsObject(Primary)
        throw Primary
}
_LTEWB_Run(Backend, Late) {
    _ManagedRemoteFixtureWithLlmTimings(_LTE_Run.Bind(_LTEWB_Body.Bind(Backend, Late)))
}
for _LTEWB_Backend in ["generate", "rawpost"] {
    Test("Token exchange request budget: " . _LTEWB_Backend . " immediate reply (token-wait-request-budget)", _LTEWB_Run.Bind(_LTEWB_Backend, false))
    Test("Token exchange request budget: " . _LTEWB_Backend . " pending beyond deadline (token-wait-request-budget)", _LTEWB_Run.Bind(_LTEWB_Backend, true))
}

; Add after existing _LTEWB_* probes. Native AHK UNRUN.
_LTEWDF_WaitBudget(Owner) {
    State := {Observed: false}, Observe := _LTEWB_Observe.Bind(State)
    try {
        SetTimer(Observe, -(Owner["timeout_ms"] + 1))
        Started := A_TickCount
        while !State.Observed && TickElapsed(Started) < 2000
            Sleep(1)
        AssertTrue(State.Observed)
        AssertTrue(_LLM_DeadlineExpired(Owner["start_tick"], Owner["timeout_ms"]))
    } finally SetTimer(Observe, 0)
}

_LTEWDF_Body(CancelShort, Posts, Lines) {
    global _LLM_Remote_Async, LLM_API_PROVIDERS, LTE_PROVIDER
    AssertFalse(A_IsSuspended)
    AssertEqual(0, _LLM_Remote_Async.Count)
    Short := [], Long := [], Ids := [], Owners := [], Answered := false, Primary := 0
    Slot := _LLM_TokenExchange_Slot(LTE_PROVIDER, _LTE_Key())
    PreviousCritical := Critical("Off")
    try {
        Id1 := LLM_RemoteGenerate_Async(_LTE_Entry(), "s", "u", 0.1,
            (*) => Short.Push(Map("ok", true)), (Info := "") => Short.Push(Map("ok", false, "info", Info)),
            "", 8, "short_access_wait", 96)
        Ids.Push(Id1)
        Owner1 := _LLM_Remote_Async[Id1]
        Owners.Push(Owner1)
        if !CancelShort {
            Resolved := _LLMRemoteResolveEntry(_LTE_Entry())
            Id2 := LLM_RemotePostBody_Async(Resolved, "https://token-fixture.invalid/v1/chat/completions", '{"messages":[]}',
                (*) => Long.Push(Map("ok", true)), (Info := "") => Long.Push(Map("ok", false, "info", Info)),
                20000, "long_access_wait")
            Ids.Push(Id2)
            Owner2 := _LLM_Remote_Async[Id2]
            Owners.Push(Owner2)
        }
        _LTE_Pump()
        AssertEqual(1, Posts.Length)
        AssertTrue(Slot["pending"])
        AssertEqual(0, Short.Length)
        if CancelShort
            LLM_RemoteCancelAsync(Id1)
        _LTEWDF_WaitBudget(Owner1)
        BeforeShort := Short.Length, BeforePresent := _LLM_Remote_Async.Has(Id1)
        BeforeTimer := Owner1.Has("access_deadline")
        BeforePending := Slot["pending"]
        if !CancelShort {
            BeforeLong := Long.Length, BeforeLongPresent := _LLM_Remote_Async.Has(Id2)
            BeforeLongTimer := Owner2.Has("access_deadline")
        }
        Answered := true
        ; No transport can dispatch: the sole cancelled owner is gone, or the
        ; live long waiter receives a genuine access refusal instead of a token.
        _LTE_Answer(Posts[1], CancelShort ? "fixture-access-token" : "", CancelShort ? 200 : 403)
        Receipt := Map("cancel_short", CancelShort, "token_posts", Posts.Length,
            "short_callbacks_before", BeforeShort, "short_present_before", BeforePresent,
            "short_timer_before", BeforeTimer, "shared_pending_before", BeforePending,
            "short_callbacks_after", Short.Length, "short_present_after", _LLM_Remote_Async.Has(Id1))
        if !CancelShort {
            Receipt["long_callbacks_before"] := BeforeLong
            Receipt["long_present_before"] := BeforeLongPresent
            Receipt["long_timer_before"] := BeforeLongTimer
            Receipt["long_callbacks_after"] := Long.Length
            Receipt["long_present_after"] := _LLM_Remote_Async.Has(Id2)
            Receipt["long_timer_after"] := Owner2.Has("access_deadline")
        }
        _TestPrint("# TOKEN_WAIT_OWNER " . KL_JsonEncode(Receipt))
        AssertTrue(BeforePending, "retiring one request must leave the shared access exchange pending")
        AssertFalse(BeforePresent)
        AssertFalse(BeforeTimer, "retired request must release its exact bound deadline callback")
        AssertEqual(CancelShort ? 0 : 1, BeforeShort)
        AssertEqual(CancelShort ? 0 : 1, Short.Length)
        if CancelShort {
            AssertEqual("fixture-access-token", LLM_TokenExchange_Current(LTE_PROVIDER,
                LLM_API_PROVIDERS[LTE_PROVIDER]["Auth"], _LTE_Key()))
        } else {
            AssertEqual("timeout", Short[1]["info"]["reason"])
            AssertEqual(0, BeforeLong)
            AssertTrue(BeforeLongPresent && BeforeLongTimer, "the other actual request keeps its own deadline and authority")
            AssertEqual(1, Long.Length)
            AssertFalse(Long[1]["ok"])
            AssertEqual("token_exchange", Long[1]["info"]["reason"])
            AssertEqual(403, Long[1]["info"]["status"])
            AssertFalse(_LLM_Remote_Async.Has(Id2))
            AssertFalse(Owner2.Has("access_deadline"), "settlement must also release the live waiter's deadline callback")
        }
        AssertFalse(Slot["pending"])
        for Owner in Owners
            AssertFalse(Owner.Has("http"), "these controls must launch no remote transport")
    } catch Any as Failure {
        Primary := Failure
    } finally {
        try {
            for Index, Id in Ids
                if Index <= Owners.Length && _LLM_Remote_Async.Has(Id) && _LLM_Remote_Async[Id] == Owners[Index]
                    LLM_RemoteCancelAsync(Id)
            StartedCleanup := A_TickCount
            while !Answered && Posts.Length == 0 && Slot["pending"] && TickElapsed(StartedCleanup) < 1000
                Sleep(1)
            if !Answered && Posts.Length {
                _LTE_Answer(Posts[1], "", 403)
                Answered := true
            }
            for Index, Id in Ids {
                if Index <= Owners.Length && _LLM_Remote_Async.Has(Id) && _LLM_Remote_Async[Id] == Owners[Index] {
                    LLM_RemoteCancelAsync(Id)
                    _LLMRemote_PollRequest(Id)
                }
                AssertFalse(_LLM_Remote_Async.Has(Id))
            }
            AssertFalse(Slot["pending"])
        } catch Any as CleanupFailure {
            _TestPrint("# TOKEN_WAIT_OWNER_CLEANUP " . KL_JsonEncode(Map("cancel_short", CancelShort,
                "error", Type(CleanupFailure), "message", SubStr(CleanupFailure.Message, 1, 250))))
            if !IsObject(Primary)
                Primary := CleanupFailure
        }
        Critical(PreviousCritical)
    }
    if IsObject(Primary)
        throw Primary
}
_LTEWDF_Run(CancelShort) {
    _ManagedRemoteFixtureWithLlmTimings(_LTE_Run.Bind(_LTEWDF_Body.Bind(CancelShort)))
}
Test("Token exchange request budget: short expiry retains another actual request (token-wait-request-budget)", _LTEWDF_Run.Bind(false))
Test("Token exchange request budget: cancelled pending owner retires silently (token-wait-request-budget)", _LTEWDF_Run.Bind(true))

; Add after existing _LTEWB_* probes. Native AHK UNRUN.
; Intrinsic native timer range only; no product timeout ceiling is invented.
_LTEWBI_Body(Backend, Posts, Lines) {
    global _LLM_Remote_Async, _LLM_Remote_AsyncCounter, LTE_PROVIDER
    AssertFalse(A_IsSuspended)
    AssertEqual(0, _LLM_Remote_Async.Count)
    Before := _LLM_Remote_AsyncCounter
    Slot := _LLM_TokenExchange_Slot(LTE_PROVIDER, _LTE_Key())
    Heard := [], Raised := 0, CapturedId := 0, CapturedOwner := 0, Answered := false, Primary := 0
    PreviousCritical := Critical("On")
    try {
        try {
            Timeout := 1 << 40
            if Backend == "generate"
                LLM_RemoteGenerate_Async(_LTE_Entry(), "s", "u", 0.1,
                    (*) => Heard.Push("ok"), (*) => Heard.Push("fail"), "", 8, "invalid_access_delay_control", Timeout)
            else {
                Resolved := _LLMRemoteResolveEntry(_LTE_Entry())
                LLM_RemotePostBody_Async(Resolved, "https://token-fixture.invalid/v1/chat/completions", '{"messages":[]}',
                    (*) => Heard.Push("ok"), (*) => Heard.Push("fail"), Timeout, "invalid_access_delay_control")
            }
        } catch Any as Failure {
            Raised := Failure
        }
        After := _LLM_Remote_AsyncCounter
        if After == Before + 1 && _LLM_Remote_Async.Has(After)
                && _LLM_Remote_Async[After].Get("kind", "") == "invalid_access_delay_control" {
            CapturedId := After
            CapturedOwner := _LLM_Remote_Async[After]
        }
        Receipt := Map("backend", Backend, "raised", IsObject(Raised),
            "error", IsObject(Raised) ? Type(Raised) : "", "registry_count", _LLM_Remote_Async.Count,
            "counter_delta", After - Before, "callbacks", Heard.Length,
            "token_posts_at_rejection", Posts.Length, "shared_pending", Slot["pending"])
        ; Allow the already shared Begin timer only after the rejection snapshot.
        Critical(PreviousCritical)
        _TestPrint("# TOKEN_WAIT_INVALID_TIMER " . KL_JsonEncode(Receipt))
        AssertTrue(IsObject(Raised) && Raised is ValueError, "the existing native-range refusal must propagate unchanged")
        AssertTrue(InStr(Raised.Message, "refuses a timer delay", true) > 0)
        AssertEqual(1, Receipt["counter_delta"], "constructor uses a real unique reservation before its native timing boundary")
        AssertEqual(0, Receipt["registry_count"], "a refused timer cannot retain the constructor's reservation")
        AssertEqual(0, Receipt["callbacks"], "invalid native timing raises rather than manufacturing an asynchronous verdict")
        AssertEqual(0, Receipt["token_posts_at_rejection"], "no native/shared PostFn started before the invalid timer was refused")
        AssertTrue(Receipt["shared_pending"], "rejecting this request must not revoke the shared credential preparation")
    } catch Any as Failure {
        Primary := Failure
    } finally {
        Critical(PreviousCritical)
        try {
            if CapturedOwner is Map && _LLM_Remote_Async.Has(CapturedId) && _LLM_Remote_Async[CapturedId] == CapturedOwner
                LLM_RemoteCancelAsync(CapturedId)
            StartedCleanup := A_TickCount
            while Posts.Length == 0 && Slot["pending"] && TickElapsed(StartedCleanup) < 1000
                Sleep(1)
            if Posts.Length && !Answered {
                _LTE_Answer(Posts[1], "", 403)
                Answered := true
            }
            if CapturedOwner is Map && _LLM_Remote_Async.Has(CapturedId) && _LLM_Remote_Async[CapturedId] == CapturedOwner {
                LLM_RemoteCancelAsync(CapturedId)
                _LLMRemote_PollRequest(CapturedId)
            }
            AssertEqual(0, _LLM_Remote_Async.Count)
            AssertFalse(Slot["pending"], "settle the actual queued Begin before fixture ports restore")
        } catch Any as CleanupFailure {
            _TestPrint("# TOKEN_WAIT_INVALID_TIMER_CLEANUP " . KL_JsonEncode(Map("backend", Backend,
                "error", Type(CleanupFailure), "message", SubStr(CleanupFailure.Message, 1, 250))))
            if !IsObject(Primary)
                Primary := CleanupFailure
        }
    }
    if IsObject(Primary)
        throw Primary
}
_LTEWBI_Run(Backend) {
    _ManagedRemoteFixtureWithLlmTimings(_LTE_Run.Bind(_LTEWBI_Body.Bind(Backend)))
}
for _LTEWBI_Backend in ["generate", "rawpost"]
    Test("Token exchange request budget: " . _LTEWBI_Backend . " refuses unrepresentable native delay cleanly (token-wait-request-budget)",
        _LTEWBI_Run.Bind(_LTEWBI_Backend))

; Append to test_llm_api_token_exchange.ahk; select (token-margin-integer-domain).
_LTEMD_Parse() {
    Corpus := _LTE_ExchangeCorpus()
    Rows := [
        Map("name", "ordinary", "default", 3600, "margin", 60, "valid", true),
        Map("name", "last_integer_below_odd_half", "default", 61, "margin", 30, "valid", true),
        Map("name", "above_odd_half", "default", 61, "margin", 31, "valid", false),
        Map("name", "equal_even_half", "default", 60, "margin", 30, "valid", false),
        Map("name", "integer_double_overflow", "default", 3600, "margin", 0x4000000000000000, "valid", false),
        Map("name", "max_native_integer", "default", 3600, "margin", 0x7FFFFFFFFFFFFFFF, "valid", false)]
    Receipts := [], Results := []
    for Row in Rows {
        Raw := _LTE_Block(Corpus, "google", Map("default_expires_seconds", Row["default"],
            "refresh_margin_seconds", Row["margin"]))
        Auth := LLM_TokenExchange_Parse(Raw, &Reason)
        Receipt := Map("name", Row["name"], "admitted", Auth is Map, "reason", Reason)
        if Auth is Map {
            Cached := LLM_TokenExchange_Read(Auth, 200, Map(Auth["token_field"], "fixture-token",
                Auth["expires_field"], Row["default"]), 1000)
            Receipt["usable"] := LLM_TokenExchange_State(Auth, Cached, 1001, &Refresh)
            Receipt["refresh_one_second_after_issue"] := Refresh
        }
        Receipts.Push(Receipt)
        Results.Push(Map("row", Row, "receipt", Receipt))
    }
    _TestPrint("# TOKEN_MARGIN_INTEGER_DOMAIN " . KL_JsonEncode(Receipts))
    for Result in Results {
        Row := Result["row"], Receipt := Result["receipt"]
        AssertEqual(Row["valid"], Receipt["admitted"], Row["name"] . ": the margin must stay strictly below half the lifetime")
        if Row["valid"] {
            AssertTrue(Receipt["usable"], Row["name"])
            AssertFalse(Receipt["refresh_one_second_after_issue"], Row["name"] . ": a newly issued token is fresh")
        }
    }
}
Test("Token exchange: refresh-margin validation cannot overflow (token-margin-integer-domain)", _LTEMD_Parse)
