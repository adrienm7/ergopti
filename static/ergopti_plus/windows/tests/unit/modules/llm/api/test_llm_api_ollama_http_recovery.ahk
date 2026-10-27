; tests/unit/modules/llm/api/test_llm_api_ollama_http_recovery.ahk

; ==============================================================================
; MODULE: Native Ollama HTTP Recovery Controls
; DESCRIPTION:
; A streaming HTTP refusal must leave the separate non-streaming chat owner's
; typed model-removal recovery intact. The actual public chat, tags preflight,
; Windows curl, native process receipts and loopback peer execute unchanged.
; Only explicit consent and download UI boundaries are observed.
; ==============================================================================

#Requires AutoHotkey v2.0

_OllamaHttp_NativeRecovery(BodyKind, ExpectedOffer, RetirementWitness := 0) {
	global _LLM_Ollama_Async, _LLM_Ollama_Pending, _LLM_Ollama_PreflightPort
	global _LLM_AuxGeneration, _LLM_AuxOwners, _LLM_AuxCleanupDebt
	global _LLM_ManagedBootstrap, LLM_OLLAMA_BASE_URL
	global _LLM_LocalModelOfferPort, _LLM_LocalModelNotified, _LLM_LocalModelAsking
	Saved := Map("async", _LLM_Ollama_Async, "pending", _LLM_Ollama_Pending,
		"port", _LLM_Ollama_PreflightPort, "generation", _LLM_AuxGeneration,
		"owners", _LLM_AuxOwners, "debt", _LLM_AuxCleanupDebt,
		"bootstrap", _LLM_ManagedBootstrap, "origin", LLM_OLLAMA_BASE_URL,
		"offer_port", _LLM_LocalModelOfferPort, "notified", _LLM_LocalModelNotified,
		"asking", _LLM_LocalModelAsking)
	PreviousCritical := Critical("Off")
	Directory := A_Temp . "\ergopti_http_recovery_" . A_TickCount . "_" . Random(1, 1000000)
	ReadyPath := Directory . "\port.txt", TranscriptPath := Directory . "\receipt.jsonl"
	PeerOwner := 0, PostOwner := 0, Entry := 0, Id := 0
	State := Map("successes", 0, "failures", [], "offers", [], "installs", [])
	try {
		DirCreate(Directory)
		SplitPath(A_LineFile, , &TestDirectory)
		PeerScript := TestDirectory . "\..\..\..\..\fixtures\ollama_stream_http_peer.ahk"
		AssertTrue(FileExist(PeerScript), "the genuine loopback HTTP peer source must exist")
		Command := _SR_BuildDirectCommandLine(A_AhkPath,
			["/ErrorStdOut", PeerScript, ReadyPath, TranscriptPath, "404", BodyKind])
		PeerPid := 0
		_LLM_CurlArtifactRun(Command, Directory, "Hide", &PeerPid, &PeerOwner)
		Started := A_TickCount
		while !FileExist(ReadyPath) && !_LLM_CurlProcessExited(PeerOwner) && TickElapsed(Started) < 5000
			Sleep(10)
		AssertTrue(FileExist(ReadyPath), "the native service must publish its actual bound port")
		Ready := FileRead(ReadyPath, "UTF-8-RAW")
		AssertTrue(RegExMatch(Ready, "^[0-9]{1,5}`n\z"), "the service ready record has its exact decimal/LF grammar")
		Port := Integer(SubStr(Ready, 1, -1))
		AssertTrue(Port > 0 && Port <= 65535, "the native service owns a valid ephemeral loopback port")
		_LLM_Ollama_Async := Map(), _LLM_Ollama_Pending := ""
		_LLM_AuxOwners := Map(), _LLM_AuxCleanupDebt := Map()
		_LLM_ManagedBootstrap := 0
		_LLM_LocalModelOfferPort := 0
		_LLM_LocalModelNotified := Map(), _LLM_LocalModelAsking := false
		LLM_OLLAMA_BASE_URL := "http://127.0.0.1:" . Port
		_LLM_Ollama_PreflightPort := 0
		Payload := '{"model":"FiXtUrE-MoDeL","messages":[{"role":"user","content":"synthetic private context"}],"stream":false}'
		Id := LLM_OllamaChat_Async(Payload, _OllamaHttp_ObserveSuccess.Bind(State),
			_OllamaHttp_ObserveFailure.Bind(State))
		AssertTrue(_LLM_Ollama_Async.Has(Id), "the real public chat must reserve its actual asynchronous slot")
		Entry := _LLM_Ollama_Async[Id]
		if IsObject(RetirementWitness)
			Entry["test_retirement_witness"] := RetirementWitness
		Started := A_TickCount
		while State["successes"] + State["failures"].Length == 0 && TickElapsed(Started) < 10000
			Sleep(10)
		PostOwner := Entry.Get("process_owner", 0)
		AssertTrue(PostOwner is Map, "strict real tags admission must retain the actual native POST owner")
		AssertTrue(Entry["presence_admitted"], "the actual tags response must admit the selected model")
		AssertEqual("FiXtUrE-MoDeL", Entry["presence_model"], "the real admission captures exact requested spelling")
		AssertTrue(Entry["redact"], "the public caller-written body keeps its private diagnostic policy")
		AssertEqual(0, State["successes"], "an HTTP404 never becomes a successful public prediction")
		AssertEqual(1, State["failures"].Length, "the actual native HTTP404 settles exactly one failure")

		Started := A_TickCount
		while !PostOwner.Get("released", false) && TickElapsed(Started) < 5000
			Sleep(10)
		AssertTrue(PostOwner.Get("released", false), "the exact native POST Job must acknowledge retirement")
		AssertTrue(PostOwner.Get("terminal", 0) is Map, "the real POST Job retains its native completion receipt")
		AssertEqual(0, PostOwner["terminal"]["exit"], "HTTP404 is independent of a successful native transport exit")
		Started := A_TickCount
		while !_LLM_CurlProcessExited(PeerOwner) && TickElapsed(Started) < 5000
			Sleep(10)
		AssertTrue(_LLM_CurlProcessExited(PeerOwner), "the real server completes tags and the HTTP404 response")
		PeerExit := 0, Diagnostic := ""
		AssertTrue(_SR_TreeReadExitCode(PeerOwner["handle"], &PeerExit, &Diagnostic))
		AssertEqual(0, PeerExit, "the native service successfully sent both declared HTTP responses")
		Records := []
		for Line in StrSplit(FileRead(TranscriptPath, "UTF-8-RAW"), "`n", "`r")
			if Line != ""
				Records.Push(JsonParse(Line))
		AssertEqual(2, Records.Length, "the real transport must complete tags and one inference request")
		AssertEqual("GET", Records[1]["method"]), AssertEqual("/api/tags", Records[1]["path"])
		AssertEqual(200, Records[1]["status"], "the genuine tags request succeeds")
		AssertEqual("POST", Records[2]["method"]), AssertEqual("/api/chat", Records[2]["path"])
		AssertEqual(404, Records[2]["status"], "the actual inference response is HTTP404")
		Failure := State["failures"][1]
		AssertTrue(Failure is Map, "the real terminal classifier preserves a typed failure")
		AssertEqual(ExpectedOffer, LLM_LocalModelIsMissing(Failure),
			"only a response for the captured admitted model retains typed missing-model recovery")
		_LLM_LocalModelOfferPort := Map("confirm", _OllamaHttp_ObserveConfirm.Bind(State), "install", _OllamaHttp_ObserveInstall.Bind(State))
		LLM_LocalModelOffer(Failure)
		AssertEqual(ExpectedOffer, State["offers"].Length, "foreign or private provider echoes cannot acquire consent")
		AssertEqual(ExpectedOffer, State["installs"].Length, "only captured matching identity may reach download admission")
		if ExpectedOffer {
			AssertEqual(Entry["presence_model"], Failure["model"], "the native error response cannot replace admitted spelling")
			AssertEqual(Entry["presence_model"], State["installs"][1]["model"])
			AssertEqual(Entry["base_url"], State["installs"][1]["origin"])
		} else
			AssertEqual("model_identity_mismatch", Failure["reason"], "the refusal retains the exact affinity failure")
		AssertEqual(0, _LLM_Ollama_Async.Count, "the completed public chat slot must retire")
		AssertEqual(0, _LLM_AuxOwners.Count, "the actual native tags owner must retire")
		AssertEqual(0, _LLM_AuxCleanupDebt.Count, "no preflight native resource debt may be hidden")
		for Key in ["tmp_payload", "tmp_stdout", "tmp_status", "tmp_exit"]
			AssertFalse(FileExist(Entry[Key]), "the original private " . Key . " artifact must retire")
	} finally {
		try {
			if Entry is Map && _LLM_Ollama_Async.Has(Id) {
				Entry["cancelled"] := true
				_LLM_CurlReleaseEntryProcess(Entry, true)
				_LLM_Ollama_CleanupCurlFiles(Entry)
				_LLM_Ollama_DeleteAsyncOwned(Id, Entry)
			}
			for _, Owner in _LLM_AuxOwners.Clone()
				_LLM_AuxRetireOwner(Owner, true)
			for Owner in [PostOwner, PeerOwner] {
				if !(Owner is Map)
					continue
				Released := _LLM_CurlReleaseProcess(Owner, true), Started := A_TickCount
				while !Released && TickElapsed(Started) < 5000 {
					Sleep(10)
					Released := _LLM_CurlReleaseProcess(Owner, true)
				}
				AssertTrue(Released, "an exact native fixture process must retire before its private files")
			}
			Started := A_TickCount
			while !LLM_AuxRetryCleanupDebt() && TickElapsed(Started) < 5000
				Sleep(10)
			AssertEqual(0, _LLM_AuxCleanupDebt.Count, "the fixture must settle all actual auxiliary cleanup debt")
		} finally {
			_LLM_Ollama_Async := Saved["async"], _LLM_Ollama_Pending := Saved["pending"]
			_LLM_Ollama_PreflightPort := Saved["port"], _LLM_AuxGeneration := Saved["generation"]
			_LLM_AuxOwners := Saved["owners"], _LLM_AuxCleanupDebt := Saved["debt"]
			_LLM_ManagedBootstrap := Saved["bootstrap"], LLM_OLLAMA_BASE_URL := Saved["origin"]
			_LLM_LocalModelOfferPort := Saved["offer_port"], _LLM_LocalModelNotified := Saved["notified"]
			_LLM_LocalModelAsking := Saved["asking"]
			if DirExist(Directory)
				DirDelete(Directory, true)
			Critical(PreviousCritical)
		}
	}
}

for _OllamaRecoveryVector in [["matching", 1], ["foreign", 0], ["private", 0]]
	Test("Ollama native HTTP404: " . _OllamaRecoveryVector[1] . " preserves admitted model recovery (ollama-native-http-model-recovery)",
		_OllamaStream_WithBootTimings.Bind(_OllamaHttp_NativeRecovery.Bind(_OllamaRecoveryVector[1], _OllamaRecoveryVector[2])))

_OllamaHttp_NativeRequestRetirement(BodyKind, ExpectedOffer) {
	Counter := Map("deleted", 0)
	_LLM_TestReleaseIndependentWitness(Counter)
	AssertEqual(1, Counter["deleted"], "a released independent witness must prove actual object destruction")
	Counter["deleted"] := 0
	_OllamaHttp_NativeRecovery(BodyKind, ExpectedOffer, _LLM_TestRetirementWitness(Counter))
	AssertEqual(1, Counter["deleted"], "the actual completed native chat must release its private entry and callback closure")
}

for _OllamaRetirementVector in [["matching", 1], ["foreign", 0], ["private", 0]]
	Test("Ollama native request: " . _OllamaRetirementVector[1] . " releases its private request closure (ollama-native-request-retirement)",
		_OllamaStream_WithBootTimings.Bind(_OllamaHttp_NativeRequestRetirement.Bind(_OllamaRetirementVector[1], _OllamaRetirementVector[2])))

; Bound observers retain only their explicit state, never the native fixture frame.
_OllamaHttp_ObserveSuccess(State, *) {
	State["successes"] += 1
}

_OllamaHttp_ObserveFailure(State, Failure := "") {
	State["failures"].Push(Failure)
}

_OllamaHttp_ObserveConfirm(State, Title, Text) {
	State["offers"].Push(Text)
	return true
}

_OllamaHttp_ObserveInstall(State, Origin, Model) {
	State["installs"].Push(Map("origin", Origin, "model", Model))
	return false
}


_OllamaHttp_RetryRetirement(State) {
	State["attempts"] += 1
	if State["refuse"]
		throw Error("Injected retirement acknowledgement refusal.")
}

_OllamaHttp_RetirementRetry() {
	global _LLM_AuxOwners, _LLM_AuxCleanupDebt
	SavedOwners := _LLM_AuxOwners, SavedDebt := _LLM_AuxCleanupDebt
	Owner := 0, State := Map("attempts", 0, "refuse", true)
	Path := A_Temp . "\ergopti_tag_retirement_" . A_TickCount . "_" . Random(1, 1000000) . ".json"
	try {
		_LLM_AuxOwners := Map(), _LLM_AuxCleanupDebt := Map()
		AssertTrue(FSWriteCreateDurable(Path, "synthetic retired tags"), "the finalizer must own an actual private artifact")
		AssertEqual("synthetic retired tags", FileRead(Path, "UTF-8-RAW"))
		Owner := LLM_AuxBegin("test_tags_retirement_retry")
		Owner["on_retired"] := _OllamaHttp_RetryRetirement.Bind(State)
		AssertTrue(LLM_AuxBindResources(Owner,
			Map("finalizer", _LLM_Ollama_TagsFinalize.Bind([Path], Owner))))
		AssertTrue(LLM_AuxFinish(Owner), "the original owner must transfer its resource cleanup")
		AssertEqual(1, State["attempts"], "the actual cleanup owner must attempt the original retirement callback")
		AssertFalse(FileExist(Path), "the real private artifact retires before callback acknowledgement")
		AssertEqual(1, _LLM_AuxCleanupDebt.Count, "a thrown callback retains its exact acknowledged-cleanup debt")
		AssertTrue(HasMethod(Owner["on_retired"], "Call"), "a refused acknowledgement cannot lose its retry capability")
		State["refuse"] := false
		AssertTrue(LLM_AuxRetryCleanupDebt(), "retry must deliver the retained retirement acknowledgement")
		AssertEqual(2, State["attempts"], "exactly one failed and one successful callback run")
		AssertEqual(0, _LLM_AuxCleanupDebt.Count, "successful acknowledgement settles the original cleanup debt")
		AssertEqual(0, Owner["on_retired"], "successful retirement releases the reverse callback capture")
		_LLM_Ollama_TagsFinalize([Path], Owner)
		AssertEqual(2, State["attempts"], "an acknowledged finalizer cannot deliver retirement twice")
	} finally {
		try {
			State["refuse"] := false
			if Owner is Map && LLM_AuxIsCurrent(Owner)
				_LLM_AuxRetireOwner(Owner, true)
			AssertTrue(LLM_AuxRetryCleanupDebt(), "the fixture cannot abandon actual finalizer cleanup debt")
			if FileExist(Path)
				FSDelete(Path)
		} finally {
			_LLM_AuxOwners := SavedOwners, _LLM_AuxCleanupDebt := SavedDebt
		}
	}
}

Test("Ollama tags retirement: acknowledgement retries and then releases once (ollama-native-request-retirement)",
	_OllamaHttp_RetirementRetry)
