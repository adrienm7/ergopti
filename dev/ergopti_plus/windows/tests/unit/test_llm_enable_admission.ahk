; tests/unit/test_llm_enable_admission.ahk

; ==============================================================================
; MODULE: Confirmed Local AI Enable Regression Tests
; DESCRIPTION:
; Exercises the real tray toggle, auxiliary result delivery and borrowed config
; transaction. Native HTTP and backend application are scoped fixture boundaries;
; failed, stale or unowned receipts cannot publish the enabled preference.
; ==============================================================================

#Requires AutoHotkey v2.0





; =======================================
; =======================================
; ======= 1/ Shared Policy Corpus =======
; =======================================
; =======================================

_LEA_SharedCorpus() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\llm\enable_admission.json", "UTF-8"))
	AssertTrue(Corpus["receipts"].Length >= 12, "receipt corpus must cover genuine refusal boundaries")
	AssertTrue(Corpus["current"].Length >= 10, "current-state corpus must cover stale ownership")
	for Vector in Corpus["receipts"]
		AssertEqual(Vector["expected"], LLM_EnableReceipt(Vector["result"])["admitted"], Vector["name"])
	for Vector in Corpus["current"]
		AssertEqual(Vector["expected"], LLM_EnableCurrent(Vector["captured"], Vector["live"]), Vector["name"])
	AssertTrue(LLM_EnableRequiresProbe("ollama"))
	AssertFalse(LLM_EnableRequiresProbe("api"), "configured API enable retains its independent admission")
}
Test("AI enable admission: independent shared receipt and current-state corpus", _LEA_SharedCorpus)





; ======================================
; ======================================
; ======= 2/ Actual Enable Owner =======
; ======================================
; ======================================

_LEA_Cancel(State) {
	State["cancels"] += 1
	return State["cancel_ack"]
}

_LEA_Probe(State, Callback, Owner) {
	State["probes"] += 1
	State["callback"] := Callback
	State["owner"] := Owner
	return LLM_AuxBindResources(Owner, Map("cancel", _LEA_Cancel.Bind(State),
		"finalizer", (*) => true))
}

_LEA_Write(State, Path, Updates) {
	global _LLM_Menu
	State["writes"] += 1
	State["enabled_at_write"] := _LLM_Menu["enabled"]
	State["lease_at_write"] := _ConfigWriteTerminalIsActive()
	return State["writer_ack"] ? TOML_BatchWrite(Path, Updates) : false
}

_LEA_Apply(State, *) {
	global _LLM_Menu, ConfigurationFile
	State["applies"] += 1
	State["enabled_at_apply"] := _LLM_Menu["enabled"]
	State["disk_at_apply"] := FileRead(ConfigurationFile, "UTF-8")
	return true
}

_LEA_Notify(State, Request) {
	State["notices"] += 1
	State["notice_origin"] := Request["captured"]["origin"]
	if HasMethod(State.Get("modal_mutation", 0), "Call")
		State["modal_mutation"].Call()
	return State.Get("retry", false)
}

_LEA_WithFixture(Body) {
	global ConfigurationFile, LLM_OLLAMA_BASE_URL, _LLM_Menu_EnableAdmission, _LLM_AuxGeneration
	global _LLM_AuxOwners, _LLM_AuxCleanupDebt, _LLM_CurlCleanupDebt
	global _LLM_CurlCleanupRetryTimer
	Previous := _LMT_InstallFixture()
	Saved := Map("origin", LLM_OLLAMA_BASE_URL, "request", _LLM_Menu_EnableAdmission,
		"generation", _LLM_AuxGeneration, "owners", _LLM_AuxOwners,
		"aux_debt", _LLM_AuxCleanupDebt, "curl_debt", _LLM_CurlCleanupDebt,
		"curl_timer", _LLM_CurlCleanupRetryTimer)
	Failure := 0
	CleanupAcknowledged := false
	State := Map("probes", 0, "writes", 0, "applies", 0, "notices", 0,
		"cancels", 0, "cancel_ack", true, "writer_ack", true, "callback", 0, "owner", 0)
	Path := A_Temp . "\ergopti_enable_receipt_" . DllCall("GetCurrentProcessId")
		. "_" . A_TickCount . "_" . Random(1, 1000000) . ".toml"
	try {
		ConfigurationFile := Path
		AssertTrue(FSWrite(Path, '[llm]`nenabled = false`n`n[foreign]`nvalue = "keep"`n'))
		LLM_OLLAMA_BASE_URL := "http://127.0.0.1:18148"
		_LLM_Menu_EnableAdmission := 0
		_LLM_AuxOwners := Map()
		_LLM_AuxCleanupDebt := Map()
		_LLM_CurlCleanupDebt := Map()
		_LLM_CurlCleanupRetryTimer := 0
		State["port"] := Map("probe", _LEA_Probe.Bind(State), "writer", _LEA_Write.Bind(State),
			"apply", _LEA_Apply.Bind(State), "notify", _LEA_Notify.Bind(State),
			"persistence_notify", _LMT_Notify, "acquire", _LMT_Acquire,
			"settle", _LMT_Settle, "collect", _LMT_Collect)
		Body.Call(State)
	} catch as Err {
		Failure := Err
	} finally {
		State["cancel_ack"] := true
		LLM_Menu_CancelEnableAdmission()
		LLM_AuxRetirePrefix("ollama_enable_admission")
		Started := A_TickCount
		while !(CleanupAcknowledged := LLM_AuxRetryCleanupDebt() && LLM_CurlRetryCleanupDebt())
				&& ((A_TickCount - Started) & 0xFFFFFFFF) < 5000
			Sleep(10)
		; Unexpected real native debts remain owned even when the fixture fails.
		for Id, Debt in _LLM_AuxCleanupDebt
			Saved["aux_debt"][Id] := Debt
		for Id, Debt in _LLM_CurlCleanupDebt
			Saved["curl_debt"][Id] := Debt
		if HasMethod(_LLM_CurlCleanupRetryTimer, "Call")
			SetTimer(_LLM_CurlCleanupRetryTimer, 0)
		_LLM_Menu_EnableAdmission := Saved["request"]
		_LLM_AuxGeneration := Saved["generation"]
		_LLM_AuxOwners := Saved["owners"]
		_LLM_AuxCleanupDebt := Saved["aux_debt"]
		_LLM_CurlCleanupDebt := Saved["curl_debt"]
		_LLM_CurlCleanupRetryTimer := Saved["curl_timer"]
		LLM_OLLAMA_BASE_URL := Saved["origin"]
		_LMT_RestoreFixture(Previous)
		if FileExist(Path)
			FileDelete(Path)
		if !CleanupAcknowledged {
			_LLM_CurlScheduleCleanupRetry()
		}
	}
	if !CleanupAcknowledged
		throw Error((IsObject(Failure) ? Failure.Message . " | " : "")
			. "Enable fixture retained unacknowledged native cleanup debt.")
	if IsObject(Failure)
		throw Failure
}

_LEA_Answer(State, Receipt) {
	return _LLM_OllamaPingDeliver(State["owner"], State["callback"], Receipt, true)
}

_LEA_ConfirmedEnable(State) {
	global _LLM_Menu, ConfigurationFile, _LLM_Menu_EnableAdmission
	AssertTrue(LLM_Menu_OnToggle(State["port"]), "the actual tray action starts fresh admission")
	AssertEqual(1, State["probes"])
	AssertFalse(_LLM_Menu["enabled"], "the public toggle keeps RAM off before native readiness")
	AssertContains(FileRead(ConfigurationFile, "UTF-8"), "enabled = false", "pending probes cannot persist enable")
	AssertEqual(0, State["writes"])
	_LEA_Answer(State, Map("ok", true, "status", 200, "body", '{"version":"0.12.3"}'))
	AssertEqual(1, State["writes"], "one settled receipt enters the real borrowed writer")
	AssertFalse(State["enabled_at_write"], "old RAM survives until persistence acknowledges")
	AssertTrue(State["lease_at_write"], "the real terminal lease owns the durable write")
	AssertEqual(1, State["applies"])
	AssertTrue(State["enabled_at_apply"])
	AssertContains(State["disk_at_apply"], "enabled = true", "durability precedes backend activation")
	AssertContains(State["disk_at_apply"], 'value = "keep"', "the source owner preserves foreign settings")
	AssertEqual(0, State["cancels"], "successful native completion is not cancellation")
	AssertFalse(LLM_AuxIsCurrent(State["owner"]), "native auxiliary ownership settles before publication")
	AssertEqual(0, _LLM_Menu_EnableAdmission)
	_LEA_Answer(State, Map("ok", true, "status", 200, "body", '{"version":"late"}'))
	AssertEqual(1, State["writes"], "duplicate native answers cannot persist or activate twice")
}
_LEA_ConfirmedEnableCase() {
	_LEA_WithFixture(_LEA_ConfirmedEnable)
}
Test("AI enable admission: actual tray toggle publishes only after owned version and persistence", _LEA_ConfirmedEnableCase)

_LEA_RefusedReceipt(State, Receipt) {
	global _LLM_Menu, ConfigurationFile
	AssertTrue(LLM_Menu_OnToggle(State["port"]))
	_LEA_Answer(State, Receipt)
	AssertFalse(_LLM_Menu["enabled"], "HTTP/schema refusal preserves disabled RAM")
	AssertContains(FileRead(ConfigurationFile, "UTF-8"), "enabled = false", "refusal preserves durable OFF")
	AssertEqual(0, State["writes"])
	AssertEqual(0, State["applies"], "no backend start/install follows a refused receipt")
	AssertEqual(1, State["notices"], "one refusal names the actual selected origin")
	AssertEqual("http://127.0.0.1:18148", State["notice_origin"])
}
_LEA_RefusedReceipts() {
	for Receipt in [Map("ok", false, "status", 0, "body", ""),
		Map("ok", true, "status", 302, "body", '{"version":"redirect"}'),
		Map("ok", true, "status", 503, "body", '{"version":"refused"}'),
		Map("ok", true, "status", 200, "body", '{}'),
		Map("ok", true, "status", 200, "body", '{"version":""}')]
		_LEA_WithFixture(_LEA_RefusedReceipt.Bind(, Receipt))
}
Test("AI enable admission: actual consumer preserves OFF on connection, redirect, HTTP and schema refusal", _LEA_RefusedReceipts)

_LEA_StaleReceipt(State, Kind) {
	global _LLM_Menu, ConfigurationFile, _LLM_AuxGeneration, LLM_OLLAMA_BASE_URL
	AssertTrue(LLM_Menu_OnToggle(State["port"]))
	switch Kind {
		case "model": _LLM_Menu["model"] := "another-model"
		case "origin": LLM_OLLAMA_BASE_URL := "http://127.0.0.1:28148"
		case "generation": _LLM_AuxGeneration += 1
		case "source": FSWrite(ConfigurationFile, FileRead(ConfigurationFile, "UTF-8") . "# later user edit`n")
	}
	State["callback"].Call(Map("ok", true, "status", 200, "body", '{"version":"late"}'))
	AssertEqual(0, State["writes"], "a stale source or lifecycle cannot authorize the writer")
	AssertEqual(0, State["applies"])
	AssertFalse(_LLM_Menu["enabled"])
	AssertContains(FileRead(ConfigurationFile, "UTF-8"), "enabled = false")
	if Kind == "source"
		AssertContains(FileRead(ConfigurationFile, "UTF-8"), "# later user edit", "source refusal must not erase the user's edit")
}
_LEA_StaleReceipts() {
	for Kind in ["model", "origin", "generation", "source"]
		_LEA_WithFixture(_LEA_StaleReceipt.Bind(, Kind))
}
Test("AI enable admission: actual owner fences late source, model, origin and generation answers", _LEA_StaleReceipts)

_LEA_WriterRefusal(State) {
	global _LLM_Menu, ConfigurationFile
	State["writer_ack"] := false
	AssertTrue(LLM_Menu_OnToggle(State["port"]))
	_LEA_Answer(State, Map("ok", true, "status", 200, "body", '{"version":"confirmed"}'))
	AssertEqual(1, State["writes"], "the exact durable owner was allowed to refuse")
	AssertEqual(0, State["applies"], "durable refusal never activates the backend")
	AssertFalse(_LLM_Menu["enabled"])
	AssertContains(FileRead(ConfigurationFile, "UTF-8"), "enabled = false")
	AssertFalse(_ConfigWriteTerminalIsActive(), "ordinary refusal releases the exact lease")
}
_LEA_WriterRefusalCase() {
	_LEA_WithFixture(_LEA_WriterRefusal)
}
Test("AI enable admission: real borrowed writer refusal preserves OFF and releases ownership", _LEA_WriterRefusalCase)

_LEA_CancelDebt(State) {
	global _LLM_Menu, _LLM_Menu_EnableAdmission
	State["cancel_ack"] := false
	AssertTrue(LLM_Menu_OnToggle(State["port"]))
	OldCallback := State["callback"]
	AssertFalse(LLM_Menu_OnToggle(State["port"]), "the second click fences pending enable immediately")
	AssertEqual(0, _LLM_Menu_EnableAdmission)
	AssertFalse(LLM_Menu_OnToggle(State["port"]), "a refused native cancel prevents a successor probe")
	AssertEqual(1, State["probes"])
	OldCallback.Call(Map("ok", true, "status", 200, "body", '{"version":"late"}'))
	AssertFalse(_LLM_Menu["enabled"])
	AssertEqual(0, State["writes"])
	State["cancel_ack"] := true
	AssertTrue(LLM_Menu_OnToggle(State["port"]), "actual native cleanup acknowledgement permits a fresh request")
	AssertEqual(2, State["probes"])
	OldCallback.Call(Map("ok", true, "status", 200, "body", '{"version":"old"}'))
	AssertTrue(_LLM_Menu_EnableAdmission is Map, "late old completion cannot clear the current owner")
	AssertEqual(0, State["writes"])
}
_LEA_CancelDebtCase() {
	_LEA_WithFixture(_LEA_CancelDebt)
}
Test("AI enable admission: cancellation debt blocks successors and late answers retain current identity", _LEA_CancelDebtCase)





; ==============================================
; ==============================================
; ======= 3/ Actual Native Curl Receipts =======
; ==============================================
; ==============================================

_LEA_NativeServerCase(State, Status, Body, Expected) {
	global _LLM_Menu, LLM_OLLAMA_BASE_URL, ConfigurationFile
	Prefix := A_Temp . "\ergopti_enable_http_" . DllCall("Kernel32\GetCurrentProcessId", "UInt")
		. "_" . A_TickCount . "_" . Random(1, 1000000)
	ReadyPath := Prefix . ".ready", RequestPath := Prefix . ".request"
	ReleasePath := Prefix . ".release", BodyPath := Prefix . ".body"
	Server := 0, Failure := 0
	ServerReceipt := {Calls: 0, Code: "pending", Errors: ""}
	OnServerDone(Code, Output, Errors) {
		ServerReceipt.Calls += 1
		ServerReceipt.Code := Code
		ServerReceipt.Errors := Errors
	}
	try {
		AssertTrue(FSWrite(BodyPath, Body))
		Script := A_ScriptDir . "\fixtures\ollama_enable_server.ps1"
		Server := ShellRunner_SpawnTreeOwned("powershell.exe", ["-NoProfile", "-NonInteractive",
			"-WindowStyle", "Hidden", "-ExecutionPolicy", "Bypass", "-File", Script,
			ReadyPath, RequestPath, ReleasePath, BodyPath, String(Status)], OnServerDone)
		AssertTrue(Server.start(), "the exact native server tree must acknowledge launch")
		AssertTrue(_NDB_WaitForReadyPort(ReadyPath, &Port), "server readiness requires an actual bound loopback port")
		LLM_OLLAMA_BASE_URL := "http://127.0.0.1:" . Port
		_LLM_Menu["ollama_port"] := Port
		State["port"].Delete("probe")
		AssertTrue(LLM_Menu_OnToggle(State["port"]), "the real toggle must launch the genuine curl version request")
		Started := A_TickCount
		RequestLine := ""
		while RequestLine != "GET /api/version HTTP/1.1" && ((A_TickCount - Started) & 0xFFFFFFFF) < 5000 {
			try RequestLine := Trim(FileRead(RequestPath, "UTF-8"))
			if RequestLine != "GET /api/version HTTP/1.1"
				Sleep(5)
		}
		AssertEqual("GET /api/version HTTP/1.1", RequestLine, "native curl must publish the complete actual wire request")
		AssertFalse(_LLM_Menu["enabled"], "actual HTTP waiting cannot publish enable before the held response")
		AssertEqual(0, State["writes"])
		AssertTrue(FSWrite(ReleasePath, "release"))
		Started := A_TickCount
		while State["applies"] + State["notices"] == 0 && ((A_TickCount - Started) & 0xFFFFFFFF) < 5000
			Sleep(5)
		AssertEqual(Expected, _LLM_Menu["enabled"], "actual transport result must agree with durable enable admission")
		AssertEqual(Expected ? 1 : 0, State["writes"])
		AssertEqual(Expected ? 1 : 0, State["applies"])
		AssertEqual(Expected ? 0 : 1, State["notices"], "a real HTTP/schema refusal remains explained and off")
		AssertContains(FileRead(ConfigurationFile, "UTF-8"), Expected ? "enabled = true" : "enabled = false")
		Started := A_TickCount
		while ServerReceipt.Calls == 0 && ((A_TickCount - Started) & 0xFFFFFFFF) < 5000 {
			_SR_TreePoll()
			Sleep(5)
		}
		AssertEqual(1, ServerReceipt.Calls, "native server completion must be observed exactly once")
		AssertEqual(0, ServerReceipt.Code, "native server must exit cleanly: " . ServerReceipt.Errors)
		AssertContains(FileRead(RequestPath, "UTF-8"), "followed=false", "curl cannot auto-follow a foreign readiness redirect")
	} catch as Err {
		Failure := Err
	} finally {
		if IsObject(Server) {
			try {
				if Server.terminate() != true || Server.detach() != true
					throw Error("Native loopback server retirement was not acknowledged.")
			} catch as CleanupError {
				Failure := Error((IsObject(Failure) ? Failure.Message . " | " : "") . CleanupError.Message)
			}
		}
		for Path in [ReadyPath, RequestPath, ReleasePath, BodyPath]
			if FileExist(Path)
				FileDelete(Path)
	}
	if IsObject(Failure)
		throw Failure
}

_LEA_NativeServerCases() {
	_LEA_WithFixture(_LEA_NativeServerCase.Bind(, 200, '{"version":"0.12.3"}', true))
	_LEA_WithFixture(_LEA_NativeServerCase.Bind(, 200, '{}', false))
	_LEA_WithFixture(_LEA_NativeServerCase.Bind(, 302, '{"version":"redirect"}', false))
}
Test("AI enable admission: genuine native curl holds OFF until exact version and refuses malformed/redirect origins",
	_LEA_NativeServerCases)


_LEA_ConfirmedTailIsSilent() {
	State := Map("calls", 0, "show_ui", true, "candidate", 0)
	Candidate := Map("enabled", true)
	Apply(Received, ShowUi) {
		State["calls"] += 1
		State["show_ui"] := ShowUi
		State["candidate"] := Received
		return true
	}
	AssertTrue(_LLM_Menu_EnableApplyCommitted(Candidate, Map("toggle_apply", Apply)))
	AssertEqual(1, State["calls"], "confirmed enable reuses the existing committed tail")
	AssertTrue(State["candidate"] == Candidate)
	AssertFalse(State["show_ui"], "a version receipt cannot authorize an automatic installer fallback")
}
Test("AI enable admission: confirmed version retains the existing silent model lifecycle without installer permission",
	_LEA_ConfirmedTailIsSilent)


_LEA_ExplicitRetry(State) {
	global _LLM_Menu, _LLM_Menu_EnableAdmission
	State["retry"] := true
	AssertTrue(LLM_Menu_OnToggle(State["port"]))
	OldRequest := _LLM_Menu_EnableAdmission
	_LEA_Answer(State, Map("ok", false, "status", 0, "body", ""))
	AssertEqual(1, State["notices"])
	AssertEqual(2, State["probes"], "only the user's retry starts a fresh native request")
	AssertFalse(_LLM_Menu["enabled"])
	AssertEqual(0, State["writes"])
	AssertTrue(_LLM_Menu_EnableAdmission is Map)
	AssertTrue(ObjPtr(OldRequest) != ObjPtr(_LLM_Menu_EnableAdmission), "retry acquires a fresh request identity")
	_LEA_Answer(State, Map("ok", true, "status", 200, "body", '{"version":"fresh"}'))
	AssertEqual(1, State["writes"], "only the new confirmed receipt enters persistence")
	AssertTrue(_LLM_Menu["enabled"])
}
_LEA_ExplicitRetryCase() {
	_LEA_WithFixture(_LEA_ExplicitRetry)
}
Test("AI enable admission: explicit retry starts a fresh owner and requires a new confirmed response", _LEA_ExplicitRetryCase)

_LEA_RetryFencesModalChange(State) {
	global _LLM_Menu
	State["retry"] := true
	State["modal_mutation"] := (*) => _LLM_Menu["model"] := "changed-during-offer"
	AssertTrue(LLM_Menu_OnToggle(State["port"]))
	_LEA_Answer(State, Map("ok", false, "status", 0, "body", ""))
	AssertEqual(1, State["probes"], "post-modal retry cannot retarget a changed settings snapshot")
	AssertEqual(0, State["writes"])
	AssertFalse(_LLM_Menu["enabled"])
}
_LEA_RetryFencesModalChangeCase() {
	_LEA_WithFixture(_LEA_RetryFencesModalChange)
}
Test("AI enable admission: explicit retry rechecks the actual settings after its modal offer", _LEA_RetryFencesModalChangeCase)

_LEA_ReentrantSourceRead(State) {
	State["source_reads"] += 1
	if State["source_reads"] == 1 {
		OtherPort := State["port"].Clone()
		OtherPort.Delete("read_source")
		State["other_started"] := LLM_Menu_RequestEnableAdmission(OtherPort)
	}
	return _LLM_Menu_EnableReadSource()
}
_LEA_SourceReadKeepsWinningOwner(State) {
	global _LLM_Menu_EnableAdmission
	State["source_reads"] := 0
	State["port"]["read_source"] := _LEA_ReentrantSourceRead.Bind(State)
	AssertFalse(LLM_Menu_RequestEnableAdmission(State["port"]), "a yielding source read cannot overwrite a newer owner")
	AssertTrue(State["other_started"])
	AssertEqual(1, State["probes"], "only the owner which acquired the pending slot dispatches")
	AssertTrue(_LLM_Menu_EnableAdmission is Map)
	AssertEqual(0, State["writes"])
}
_LEA_SourceReadKeepsWinningOwnerCase() {
	_LEA_WithFixture(_LEA_SourceReadKeepsWinningOwner)
}
Test("AI enable admission: reentrant source observation preserves the winning native request", _LEA_SourceReadKeepsWinningOwnerCase)
