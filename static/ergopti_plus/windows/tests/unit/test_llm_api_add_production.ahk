; tests/unit/test_llm_api_add_production.ahk

; ==============================================================================
; MODULE: Production API Add Form Regression Tests
; DESCRIPTION:
; Calls the actual four-step Windows form with injected modal answers while the
; original private source owner, DPAPI and two-target WAL own real disk changes.
; A native AutoHotkey run is required; Linux source checks do not execute this suite.
; ==============================================================================

#Requires AutoHotkey v2.0

/** Modal answer owner around the existing genuine native publication fixture. */
class _WAA_Form {
	__New(Provider) {
		global LLM_API_PROVIDERS, LLM_LOCAL_API_SERVERS, LLM_API_PROVIDER_ORDER
		this.PriorProviders := LLM_API_PROVIDERS
		this.PriorServers := LLM_LOCAL_API_SERVERS
		this.PriorOrder := LLM_API_PROVIDER_ORDER
		this.World := 0
		this.Provider := Provider
		this.Inputs := []
		this.Answers := [Provider, "  http://127.0.0.1:8000/v1  ", " private form token ", "  Qwen/independent-model  "]
		this.CancelAt := 0
		this.CancelResult := "Cancel"
		this.ChangeAt := 0
		this.Change := ""
		this.ThrowAt := 0
		this.Offers := 0
		this.OfferAnswer := false
		this.OfferThrows := false
		this.Tests := []
		this.Ready := []
		this.Notices := []
		try {
			this.World := _LSP_World()
			AssertTrue(LLM_API_PROVIDERS.Has(Provider), "the production catalogue must own the selected provider")
			this.World.ConfigImage .= '[personal]`nmarker = "unowned-form-sentinel"`n'
			AssertTrue(FSWriteDurable(this.World.ConfigPath, this.World.ConfigImage))
			this.World.Capture()
			SourceOptions := this.World.Owner.Options.Clone()
			SourceOptions["notify"] := ObjBindMethod(this, "Notify")
			this.Port := Map("input", ObjBindMethod(this, "Input"), "source_options", SourceOptions,
				"notify", ObjBindMethod(this, "Notify"), "ask_test", ObjBindMethod(this, "Ask"),
				"test_entry", ObjBindMethod(this, "TestEntry"), "ready", ObjBindMethod(this, "ReadyPing"))
		} catch as Err {
			this.Restore()
			throw Err
		}
	}

	Restore() {
		global LLM_API_PROVIDERS, LLM_LOCAL_API_SERVERS, LLM_API_PROVIDER_ORDER
		try {
			if this.World is _LSP_World
				this.World.Restore()
		} finally {
			LLM_API_PROVIDERS := this.PriorProviders
			LLM_LOCAL_API_SERVERS := this.PriorServers
			LLM_API_PROVIDER_ORDER := this.PriorOrder
		}
	}

	Input(Prompt, Title, Options, Default) {
		global _LLM_Menu
		this.Inputs.Push(Map("prompt", Prompt, "title", Title, "options", Options, "default", Default))
		Step := this.Inputs.Length
		if Step == this.ThrowAt
			throw Error("Independent injected native input failure")
		if Step == this.ChangeAt {
			if this.Change == "menu"
				_LLM_Menu := LLM_Menu_DeepClone(_LLM_Menu)
			else if this.Change == "active"
				_LLM_Menu["api_entry_id"] := "native-first"
			else if this.Change == "config" {
				this.ForeignConfig := StrReplace(this.World.ConfigImage, "unowned-form-sentinel", "external-form-sentinel")
				AssertTrue(FSWriteDurable(this.World.ConfigPath, this.ForeignConfig))
			} else if this.Change == "api" {
				this.ForeignApi := StrReplace(this.World.ApiImage, "independent-first", "external-model-sentinel")
				AssertTrue(FSWriteDurable(this.World.ApiPath, this.ForeignApi))
			} else
				throw Error("Unknown independent form mutation")
		}
		if Step == this.CancelAt
			return {Result: this.CancelResult, Value: "cancelled value is never saved"}
		return {Result: "OK", Value: this.Answers[Step]}
	}

	Notify(Body, Options) {
		this.Notices.Push(Body)
		if this.World.FailApiMove && this.World.PhysicalFault is Object
			return this.World.Notify(Body, Options)
		return true
	}

	Ask() {
		global _LLM_Menu
		this.Offers += 1
		AssertEqual(4, this.Inputs.Length, "the offer follows all four answers")
		AssertEqual(3, _LLM_Menu["api_entries"].Length, "RAM publication precedes the offer")
		AssertEqual(3, JsonParse(FSReadUtf8Exact(this.World.ApiPath)).Length, "durable API publication precedes the offer")
		AssertFalse(_ConfigWriteTerminalIsActive(), "the WAL owner must settle before a post-save offer")
		if this.OfferThrows
			throw Error("Independent injected offer failure")
		return this.OfferAnswer
	}

	TestEntry(Unused, EntryId) {
		this.Tests.Push(EntryId)
		return true
	}

	ReadyPing(Entry, Callback, Owner) {
		this.Ready.Push(LLM_Menu_DeepClone(Entry))
		AssertTrue(HasMethod(Callback, "Call"))
		AssertTrue(LLM_AuxFinish(Owner), "the injected transport retires its actual auxiliary owner")
		return true
	}

	Run() {
		return _LLM_Menu_PromptApiEntry("", this.Port)
	}

	AssertNoSave() {
		AssertEqual(this.World.ConfigImage, FSReadUtf8Exact(this.World.ConfigPath))
		AssertEqual(this.World.ApiImage, FSReadUtf8Exact(this.World.ApiPath))
		AssertEqual(0, this.World.ApplyCalls)
		AssertEqual(0, this.Offers)
		AssertEqual(0, this.Tests.Length)
		AssertEqual(0, this.Ready.Length)
		AssertFalse(_ConfigWriteTerminalIsActive(), "an uncommitted form must retain no transition owner")
	}
}

_WAA_Accepted(Provider, OfferAnswer := false) {
	global _LLM_Menu, LLM_API_PROVIDERS
	Form := _WAA_Form(Provider)
	Form.OfferAnswer := OfferAnswer
	try {
		AssertTrue(Form.Run(), "the actual form reports saved only after native acknowledgement")
		AssertEqual(4, Form.Inputs.Length)
		AssertContains(Form.Inputs[1]["prompt"], Provider)
		AssertEqual(LLM_API_PROVIDERS[Provider]["BaseUrl"], Form.Inputs[2]["default"])
		AssertContains(Form.Inputs[3]["options"], "Password", "secret input remains masked")
		AssertEqual(LLM_API_PROVIDERS[Provider]["DefaultModel"], Form.Inputs[4]["default"])
		AssertEqual(3, _LLM_Menu["api_entries"].Length)
		Saved := _LLM_Menu["api_entries"][3]
		AssertEqual(Provider, Saved["Provider"])
		AssertEqual("http://127.0.0.1:8000/v1", Saved["BaseUrl"])
		AssertEqual(" private form token ", Saved["Token"], "secret spaces are exact credentials")
		AssertEqual("Qwen/independent-model", Saved["Model"])
		AssertEqual(Provider . "/Qwen/independent-model", Saved["Name"])
		AssertEqual(Saved["Id"], _LLM_Menu["api_entry_id"])
		AssertEqual(1, Form.World.ApplyCalls)
		Persisted := JsonParse(FSReadUtf8Exact(Form.World.ApiPath))
		AssertEqual(3, Persisted.Length)
		AssertEqual(Saved["Id"], Persisted[3]["Id"])
		AssertTrue(LLM_ApiToken_IsValidEnvelope(Persisted[3]["Token"]))
		AssertEqual(Saved["Token"], LLM_ApiToken_Decrypt(Persisted[3]["Token"]))
		AssertFalse(InStr(FSReadUtf8Exact(Form.World.ApiPath), "private form token") > 0)
		AssertEqual("private-first-sentinel", LLM_ApiToken_Decrypt(Persisted[1]["Token"]))
		AssertEqual("independent-first", Persisted[1]["Model"])
		AssertContains(FSReadUtf8Exact(Form.World.ConfigPath), 'marker = "unowned-form-sentinel"')
		AssertEqual(1, Form.Offers)
		ExpectedTests := (OfferAnswer is Integer) && OfferAnswer == 1 ? 1 : 0
		AssertEqual(ExpectedTests, Form.Tests.Length)
		if ExpectedTests
			AssertEqual(Saved["Id"], Form.Tests[1])
		AssertEqual(1, Form.Ready.Length)
		AssertEqual(Saved["Id"], Form.Ready[1]["Id"])
		AssertEqual("http://127.0.0.1:8000/v1", Form.Ready[1]["BaseUrl"])
		AssertEqual(0, Form.Notices.Length)
		AssertFalse(_ConfigWriteTerminalIsActive())
	} finally Form.Restore()
}

_WAA_Keyless(Provider) {
	global _LLM_Menu, LLM_LOCAL_API_SERVERS
	Form := _WAA_Form(Provider)
	Form.Answers[3] := ""
	try {
		AssertTrue(Form.Run(), "generic loopback entries may save a deliberately empty local credential")
		Saved := _LLM_Menu["api_entries"][3]
		Persisted := JsonParse(FSReadUtf8Exact(Form.World.ApiPath))
		AssertEqual("", Saved["Token"])
		AssertEqual("", Persisted[3]["Token"], "empty local secrets need no invented DPAPI envelope")
		AssertFalse(LocalServerAuthTokenAllowed(Provider, "", LLM_LOCAL_API_SERVERS), "provider-only generic authentication remains strict")
		Resolved := _LLMRemoteResolveEntry(Saved)
		AssertTrue(Resolved is Map, "the actual consumer admits only the explicit loopback endpoint")
		AssertEqual("http://127.0.0.1:8000/v1", Resolved["BaseUrl"])
		AssertEqual("", Resolved["Token"])
		Remote := LLM_Menu_DeepClone(Saved)
		Remote["BaseUrl"] := "https://foreign.invalid/v1"
		AssertEqual("", _LLMRemoteResolveEntry(Remote), "empty tokens never qualify a remote generic provider")
		AssertEqual(1, Form.Ready.Length, "keyless save still requires a real server response in production")
	} finally Form.Restore()
}

_WAA_Cancelled(Provider, Step, Result) {
	Form := _WAA_Form(Provider)
	Form.CancelAt := Step
	Form.CancelResult := Result
	try {
		AssertFalse(Form.Run())
		AssertEqual(Step, Form.Inputs.Length, "cancel/timeout stops every subsequent prompt")
		AssertEqual(0, Form.Notices.Length, "ordinary cancellation stays silent")
		Form.AssertNoSave()
	} finally Form.Restore()
}

_WAA_Stale(Provider, Step, Mutation) {
	global _LLM_Menu
	Form := _WAA_Form(Provider)
	Form.ChangeAt := Step
	Form.Change := Mutation
	try {
		AssertFalse(Form.Run(), "modal reentrancy cannot commit an obsolete form against fresh state")
		AssertEqual(Step, Form.Inputs.Length)
		AssertEqual(1, Form.Notices.Length, "stale source refusal is observable")
		if Mutation == "config" {
			AssertEqual(Form.ForeignConfig, FSReadUtf8Exact(Form.World.ConfigPath))
			AssertEqual(Form.World.ApiImage, FSReadUtf8Exact(Form.World.ApiPath))
		} else if Mutation == "api" {
			AssertEqual(Form.ForeignApi, FSReadUtf8Exact(Form.World.ApiPath))
			AssertEqual(Form.World.ConfigImage, FSReadUtf8Exact(Form.World.ConfigPath))
		} else {
			AssertEqual(Form.World.ConfigImage, FSReadUtf8Exact(Form.World.ConfigPath))
			AssertEqual(Form.World.ApiImage, FSReadUtf8Exact(Form.World.ApiPath))
			AssertTrue(_LLM_Menu != Form.World.OldMenu || Mutation == "active")
			if Mutation == "active"
				AssertEqual("native-first", _LLM_Menu["api_entry_id"])
		}
		AssertEqual(0, Form.World.ApplyCalls)
		AssertEqual(0, Form.Offers)
		AssertEqual(0, Form.Ready.Length)
		AssertFalse(_ConfigWriteTerminalIsActive())
	} finally Form.Restore()
}

_WAA_InvalidAnswer(Provider, Field) {
	Form := _WAA_Form(Provider)
	Form.Answers[Field] := " "
	try {
		AssertFalse(Form.Run())
		AssertEqual(Field, Form.Inputs.Length)
		AssertEqual(1, Form.Notices.Length)
		Form.AssertNoSave()
	} finally Form.Restore()
}

_WAA_SerializationRefused(Provider) {
	Form := _WAA_Form(Provider)
	Form.Port["source_options"]["serialize"] := (*) => false
	try {
		AssertFalse(Form.Run(), "a native serializer refusal cannot advertise a saved entry")
		AssertEqual(4, Form.Inputs.Length)
		AssertEqual(1, Form.Notices.Length)
		Form.AssertNoSave()
	} finally Form.Restore()
}

_WAA_SecondTargetLocked(Provider) {
	Form := _WAA_Form(Provider)
	Form.World.FailApiMove := true
	try {
		AssertFalse(Form.Run(), "the actual second-target sharing violation must refuse the complete form")
		AssertEqual(4, Form.Inputs.Length)
		AssertEqual(1, Form.Notices.Length)
		AssertTrue(Form.World.PhysicalFault is _LSP_PhysicalSourceFault)
		AssertEqual(0, Form.World.PhysicalFault.Handle, "the exact native obstruction closes after both refusal observations")
		AssertEqual(2, Form.World.PhysicalFault.NativeRefusals)
		Form.AssertNoSave()
	} finally Form.Restore()
}

_WAA_ForeignApiField(Provider) {
	Form := _WAA_Form(Provider)
	Foreign := StrReplace(Form.World.ApiImage, '"Name":"Original first"', '"Name":"Original first","FutureSetting":"private-foreign-field"')
	AssertTrue(Foreign != Form.World.ApiImage)
	try {
		AssertTrue(FSWriteDurable(Form.World.ApiPath, Foreign))
		AssertFalse(Form.Run(), "the six-field writer must refuse unknown personal API data")
		AssertEqual(0, Form.Inputs.Length)
		AssertEqual(Foreign, FSReadUtf8Exact(Form.World.ApiPath))
		AssertEqual(Form.World.ConfigImage, FSReadUtf8Exact(Form.World.ConfigPath))
		AssertEqual(1, Form.Notices.Length)
		AssertEqual(0, Form.Offers)
		AssertEqual(0, Form.Ready.Length)
	} finally Form.Restore()
}

_WAA_InputThrows(Provider) {
	Form := _WAA_Form(Provider)
	Form.ThrowAt := 2
	try {
		AssertThrows(ObjBindMethod(Form, "Run"), "native input exceptions remain actual failures")
		AssertEqual(2, Form.Inputs.Length)
		Form.AssertNoSave()
	} finally Form.Restore()
}

_WAA_OfferThrows(Provider) {
	Form := _WAA_Form(Provider)
	Form.OfferThrows := true
	try {
		AssertTrue(Form.Run(), "an optional offer failure cannot undo a completed native save")
		AssertEqual(1, Form.Offers)
		AssertEqual(0, Form.Tests.Length)
		AssertEqual(1, Form.Ready.Length)
		AssertEqual(3, JsonParse(FSReadUtf8Exact(Form.World.ApiPath)).Length)
	} finally Form.Restore()
}

/** Injected response object; exercises the actual readiness validator, not a native server. */
class _WAA_ReadyHttp {
	__New(State, Status, Body) {
		this.State := State
		this.Status := Status
		this.ResponseText := Body
	}
	Open(Method, Url, Async) {
		AssertEqual("GET", Method)
		AssertEqual("http://127.0.0.1:8000/v1/models", Url)
		AssertTrue(Async)
		this.State["opens"] += 1
	}
	SetTimeouts(*) {
	}
	SetDeadline(*) {
	}
	SetRequestHeader(Key, Value) {
		this.State["headers"][Key] := Value
	}
	SetProxy(*) {
	}
	Send(*) {
		this.State["sends"] += 1
		return true
	}
	WaitForResponse(*) {
		return true
	}
	Abort() {
		this.State["aborts"] += 1
		return true
	}
}

_WAA_ReadyCreate(State, Status, Body) {
	State["creates"] += 1
	return _WAA_ReadyHttp(State, Status, Body)
}

_WAA_ReadyResolve(Url, Callback) {
	AssertEqual("http://127.0.0.1:8000/v1/models", Url)
	Callback.Call(Map("ok", true, "inherit", false, "proxy", ""))
	return true
}

_WAA_ReadyReply(Provider, Status, Body, Expected) {
	return _ManagedRemoteFixtureWithLlmTimings(_WAA_ReadyReplyBody.Bind(Provider, Status, Body, Expected))
}

_WAA_ReadyReplyBody(Provider, Status, Body, Expected) {
	global _LLM_Menu
	Form := _WAA_Form(Provider)
	Form.Answers[3] := ""
	Owner := 0
	try {
		AssertTrue(Form.Run())
		Entry := _LLM_Menu["api_entries"][3]
		State := Map("creates", 0, "opens", 0, "sends", 0, "aborts", 0, "headers", Map(), "results", [])
		Owner := LLM_AuxBegin("windows-api-add-ready", Map("backend", "api", "endpoint", Entry["BaseUrl"], "identity", Entry["Id"]))
		Port := Map("resolve_proxy", _WAA_ReadyResolve, "create_http", _WAA_ReadyCreate.Bind(State, Status, Body))
		LLM_RemoteIsReady_Async(Entry, (Value) => State["results"].Push(Value), Owner, Port)
		AssertEqual(1, State["creates"], "an admitted explicit keyless loopback endpoint reaches the real dispatch owner")
		AssertEqual(1, State["opens"])
		AssertEqual(1, State["sends"])
		AssertFalse(State["headers"].Has("Authorization"), "empty local keys cannot invent a Bearer credential")
		AssertEqual(1, State["results"].Length)
		AssertEqual(Expected, State["results"][1], "actual /models receipt validation controls readiness")
		AssertFalse(LLM_AuxIsCurrent(Owner), "each reply settles its exact original auxiliary owner")
		AssertEqual(3, JsonParse(FSReadUtf8Exact(Form.World.ApiPath)).Length, "a rejected response keeps the acknowledged saved entry")
	} finally {
		if Owner is Map
			_LLM_AuxRetireOwner(Owner)
		Form.Restore()
	}
}

for Provider in ["openai", "openai_compat"] {
	Test("Windows API Add: " . Provider . " oMLX exact native save (windows-api-add-production)", _WAA_Accepted.Bind(Provider))
	Test("Windows API Add: " . Provider . " keyless generic loopback uses actual resolver (windows-api-add-production)", _WAA_Keyless.Bind(Provider))
	Test("Windows API Add: " . Provider . " accepted probe uses saved id (windows-api-add-production)", _WAA_Accepted.Bind(Provider, true))
	Test("Windows API Add: " . Provider . " string consent cannot dispatch probe (windows-api-add-production)", _WAA_Accepted.Bind(Provider, "1"))
	for Result in ["Cancel", "Timeout"] {
		Loop 4
			Test("Windows API Add: " . Provider . " " . Result . " field " . A_Index . " (windows-api-add-production)", _WAA_Cancelled.Bind(Provider, A_Index, Result))
	}
	for Mutation in ["menu", "active", "config", "api"] {
		Loop 4
			Test("Windows API Add: " . Provider . " obsolete " . Mutation . " field " . A_Index . " (windows-api-add-production)", _WAA_Stale.Bind(Provider, A_Index, Mutation))
	}
	Test("Windows API Add: " . Provider . " invalid provider refuses (windows-api-add-production)", _WAA_InvalidAnswer.Bind(Provider, 1))
	Test("Windows API Add: " . Provider . " empty model refuses (windows-api-add-production)", _WAA_InvalidAnswer.Bind(Provider, 4))
	Test("Windows API Add: " . Provider . " serialization refusal keeps both sources (windows-api-add-production)", _WAA_SerializationRefused.Bind(Provider))
	Test("Windows API Add: " . Provider . " real second-target refusal rolls both sources back (windows-api-add-production)", _WAA_SecondTargetLocked.Bind(Provider))
	Test("Windows API Add: " . Provider . " foreign API fields remain exact (windows-api-add-production)", _WAA_ForeignApiField.Bind(Provider))
	Test("Windows API Add: " . Provider . " native input exception remains failure (windows-api-add-production)", _WAA_InputThrows.Bind(Provider))
	Test("Windows API Add: " . Provider . " optional offer exception retains save (windows-api-add-production)", _WAA_OfferThrows.Bind(Provider))
}

for Provider in ["openai", "openai_compat"] {
	Test("Windows API Add: " . Provider . " actual readiness owner accepts valid model JSON (windows-api-add-production)", _WAA_ReadyReply.Bind(Provider, 200, '{"data":[{"id":"independent"}]}', true))
	Test("Windows API Add: " . Provider . " actual readiness owner accepts an empty model list (windows-api-add-production)", _WAA_ReadyReply.Bind(Provider, 200, '{"data":[]}', true))
	Test("Windows API Add: " . Provider . " actual readiness owner refuses 401 (windows-api-add-production)", _WAA_ReadyReply.Bind(Provider, 401, '{"data":[{"id":"independent"}]}', false))
	Test("Windows API Add: " . Provider . " actual readiness owner refuses 403 (windows-api-add-production)", _WAA_ReadyReply.Bind(Provider, 403, '{"data":[{"id":"independent"}]}', false))
	Test("Windows API Add: " . Provider . " actual readiness owner refuses HTML (windows-api-add-production)", _WAA_ReadyReply.Bind(Provider, 200, '<html>not a model API</html>', false))
	Test("Windows API Add: " . Provider . " actual readiness owner refuses 204 (windows-api-add-production)", _WAA_ReadyReply.Bind(Provider, 204, '{"data":[{"id":"independent"}]}', false))
}
