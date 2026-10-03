; tests/unit/test_ollama_http_terminal_classification.ahk

; ==============================================================================
; MODULE: Ollama HTTP Terminal Classification Regression Tests
; DESCRIPTION:
; Proves that transport exit, HTTP status, readable body ownership, and the
; endpoint's canonical JSON schema all agree before readiness, tag publication,
; deletion logging, or a true callback can be emitted.
; ==============================================================================

_OHTC_PingRequiresTransportStatusAndSchema() {
	AssertFalse(_LLM_OllamaPingTerminalOk(7, 0, true, ""), "connection refusal is not readiness")
	AssertFalse(_LLM_OllamaPingTerminalOk(0, 404, true, "<html>no</html>"), "HTTP 404 is not readiness")
	AssertFalse(_LLM_OllamaPingTerminalOk(0, 200, true, "{}"), "an arbitrary JSON service is not Ollama")
	AssertTrue(_LLM_OllamaPingTerminalOk(0, 200, true, '{"version":"0.11.0"}'), "typed Ollama version response is ready")
}
Test("AHK-007 Ollama terminal: ping requires exit, 2xx and version schema (ahk-007-ollama-terminal-classification)",
	_OHTC_PingRequiresTransportStatusAndSchema)

_OHTC_TagsRequireCanonicalModelsArray() {
	AssertEqual(0, _LLM_Ollama_ParseTagNames("<html>not Ollama</html>").Length,
		"non-JSON bytes must not become an installed-model list")
	AssertEqual(0, _LLM_Ollama_ParseTagNames('{"decoy":{"name":"not-a-model"}}').Length,
		"a same-named field outside the canonical models array must be ignored")
	Tags := _LLM_Ollama_ParseTagNames('{"models":[{"name":"qwen:latest"},{"name":""},{"other":"skip"}]}')
	AssertEqual(1, Tags.Length, "only valid canonical model rows may publish")
	AssertEqual("qwen:latest", Tags[1], "the exact canonical model name must survive")
}
Test("AHK-007 Ollama terminal: tags navigate the canonical models array (ahk-007-ollama-terminal-classification)",
	_OHTC_TagsRequireCanonicalModelsArray)

_OHTC_RecordDeleteResult(State, Result) {
	State["callback_calls"] += 1
	State["callback_value"] := Result
}

_OHTC_RecordSuccess(State, *) {
	State["success_calls"] += 1
}

_OHTC_RecordWarning(State, *) {
	State["warning_calls"] += 1
}

_OHTC_DeleteRequiresCompleteTerminalEvidence() {
	AssertFalse(_LLM_OllamaDeleteTerminalOk(7, 0, true, ""), "empty body cannot hide transport refusal")
	AssertFalse(_LLM_OllamaDeleteTerminalOk(0, 500, true, ""), "empty 500 is failure")
	AssertFalse(_LLM_OllamaDeleteTerminalOk(0, 204, false, ""), "missing body artifact is incomplete ownership")
	AssertTrue(_LLM_OllamaDeleteTerminalOk(0, 204, true, ""), "complete empty 204 is success")

	State := Map("callback_calls", 0, "callback_value", true, "success_calls", 0, "warning_calls", 0)
	Terminal := Map("exit", 7, "status", 0, "body_read", true, "body", "")
	Result := _LLM_OllamaFinishDelete(Terminal, "private-model",
		_OHTC_RecordDeleteResult.Bind(State), _OHTC_RecordSuccess.Bind(State), _OHTC_RecordWarning.Bind(State))
	AssertFalse(Result, "the terminal finisher must reject nonzero curl exit")
	AssertEqual(1, State["callback_calls"], "terminal failure must deliver one callback")
	AssertFalse(State["callback_value"], "terminal failure callback must be false")
	AssertEqual(0, State["success_calls"], "terminal failure must never emit LoggerSuccess")
	AssertEqual(1, State["warning_calls"], "terminal failure must emit one warning")
}
Test("AHK-007 Ollama terminal: delete failure never logs or calls success (ahk-007-ollama-terminal-classification)",
	_OHTC_DeleteRequiresCompleteTerminalEvidence)


_OHTC_PidReceipt_ReadTerminal(State, *) {
	State["terminal_reads"] += 1
	return State["terminal"]
}

_OHTC_PidReceipt_Terminate(State, Handle) {
	State["terminate_calls"] += 1
	State["terminated_handle"] := Handle
	return true
}

_OHTC_PidReceipt_Close(State, Handle) {
	State["close_calls"] += 1
	State["closed_handle"] := Handle
	return true
}

_OHTC_PidReceipt_RecordResult(State, Value) {
	State["callback_calls"] += 1
	State["value"] := Value
}

_OHTC_PidReceipt_State(Terminal, Handle) {
	return Map(
		"terminal", Terminal,
		"handle", Handle,
		"terminal_reads", 0,
		"terminate_calls", 0,
		"close_calls", 0,
		"terminated_handle", 0,
		"closed_handle", 0,
		"callback_calls", 0,
		"value", "")
}

_OHTC_PidReceipt_Port(State) {
	return Map(
		"open_process", (*) => State["handle"],
		"terminate_process", _OHTC_PidReceipt_Terminate.Bind(State),
		"close_process", _OHTC_PidReceipt_Close.Bind(State),
		"read_terminal", _OHTC_PidReceipt_ReadTerminal.Bind(State))
}

_OHTC_PidReceipt_Owner(Kind) {
	global _LLM_AuxGeneration, _LLM_AuxOwnerCounter, _LLM_AuxOwners
	if !IsSet(_LLM_AuxGeneration)
		_LLM_AuxGeneration := 1
	if !IsSet(_LLM_AuxOwnerCounter)
		_LLM_AuxOwnerCounter := 0
	if !IsSet(_LLM_AuxOwners)
		_LLM_AuxOwners := Map()
	return LLM_AuxBegin(Kind, Map(
		"backend", "ollama", "endpoint", "http://127.0.0.1:11434"))
}

_OHTC_PidReceipt_AssertReleasedWithoutTerminate(State, Message) {
	AssertEqual(1, State["terminal_reads"],
		Message . ": the terminal receipt must be read exactly once")
	AssertEqual(0, State["terminate_calls"],
		Message . ": a complete receipt must never terminate a possibly recycled PID")
	AssertEqual(1, State["close_calls"],
		Message . ": the retained exact process handle must be released once")
	AssertEqual(State["handle"], State["closed_handle"],
		Message . ": cleanup must close the exact adopted handle")
	AssertEqual(1, State["callback_calls"],
		Message . ": the committed result must be delivered exactly once")
}

_OHTC_PidReceipt_AllAuxPollersResolveReceiptBeforeDeadline() {
	PingState := _OHTC_PidReceipt_State(Map(
		"complete", true, "exit", 0, "status", 200,
		"body_read", true, "body", '{"version":"0.11.0"}'), 9101)
	PingPort := _OHTC_PidReceipt_Port(PingState)
	PingProcess := _LLM_CurlAdoptProcess(4242, PingPort)
	PingOwner := _OHTC_PidReceipt_Owner("ahk2_04_ping")
	_LLM_Ollama_PingPoll(PingProcess, "body", "status", "exit",
		_OHTC_PidReceipt_RecordResult.Bind(PingState), A_TickCount - 100000,
		PingOwner, PingPort)
	_OHTC_PidReceipt_AssertReleasedWithoutTerminate(PingState, "ping")
	AssertTrue(PingState["value"], "the typed Ollama version receipt must publish readiness")

	TagsState := _OHTC_PidReceipt_State(Map(
		"complete", true, "exit", 0, "status", 200,
		"body_read", true, "body", '{"models":[{"name":"owned:model"}]}'), 9102)
	TagsPort := _OHTC_PidReceipt_Port(TagsState)
	TagsProcess := _LLM_CurlAdoptProcess(4243, TagsPort)
	TagsOwner := _OHTC_PidReceipt_Owner("ahk2_04_tags")
	_LLM_Ollama_TagsPoll(TagsProcess, "body", "status", "exit",
		_OHTC_PidReceipt_RecordResult.Bind(TagsState), A_TickCount - 100000,
		TagsOwner, TagsPort)
	_OHTC_PidReceipt_AssertReleasedWithoutTerminate(TagsState, "tags")
	AssertTrue(TagsState["value"] is Array,
		"the tags receipt must publish the canonical Array")
	AssertEqual("owned:model", TagsState["value"][1],
		"the exact model from the terminal receipt must survive")

	DeleteState := _OHTC_PidReceipt_State(Map(
		"complete", true, "exit", 0, "status", 204,
		"body_read", true, "body", ""), 9103)
	DeletePort := _OHTC_PidReceipt_Port(DeleteState)
	DeleteProcess := _LLM_CurlAdoptProcess(4244, DeletePort)
	DeleteOwner := _OHTC_PidReceipt_Owner("ahk2_04_delete")
	_LLM_Ollama_DeletePoll(DeleteProcess, "payload", "body", "status", "exit",
		"owned:model", _OHTC_PidReceipt_RecordResult.Bind(DeleteState),
		A_TickCount - 100000, DeleteOwner, DeletePort)
	_OHTC_PidReceipt_AssertReleasedWithoutTerminate(DeleteState, "delete")
	AssertTrue(DeleteState["value"],
		"the complete 204 delete receipt must publish success")
}
Test("Ollama curl polls: terminal receipts precede deadline for every auxiliary child "
	. "(ahk2-04-curl-receipt-first)",
	_OHTC_PidReceipt_AllAuxPollersResolveReceiptBeforeDeadline)


_OHTC_StrictPresenceReceipts() {
	for Status in [200, 401, 403, 404, 500] {
		State := _OHTC_PidReceipt_State(Map("complete", true, "exit", 0, "status", Status,
			"body_read", true, "body", '{"models":[]}'), 9300 + Status)
		Port := _OHTC_PidReceipt_Port(State)
		Process := _LLM_CurlAdoptProcess(4700 + Status, Port)
		Owner := _OHTC_PidReceipt_Owner("todo46_tags_" . Status)
		_LLM_Ollama_TagsPoll(Process, "body", "status", "exit", _OHTC_PidReceipt_RecordResult.Bind(State),
			A_TickCount, Owner, Port, true)
		AssertEqual(1, State["callback_calls"], "strict presence receives one terminal result")
		AssertTrue(State["value"] is Map, "strict admission keeps receipt shape distinct from the legacy array")
		if Status == 200 {
			AssertTrue(State["value"]["ok"], "a canonical empty list is known, not unavailable")
			AssertEqual(0, State["value"]["names"].Count)
		} else {
			AssertFalse(State["value"]["ok"], "HTTP refusal cannot become a missing-model offer")
			AssertEqual("model_list_unavailable", State["value"]["reason"])
		}
		AssertEqual(1, State["close_calls"], "terminal receipt releases the exact native handle")
		AssertEqual(0, State["terminate_calls"])
	}
	for Body in ['{"models":{}}', "not JSON", '{"models":[{}]}'] {
		State := _OHTC_PidReceipt_State(Map("complete", true, "exit", 0, "status", 200,
			"body_read", true, "body", Body), 9901)
		Port := _OHTC_PidReceipt_Port(State)
		Owner := _OHTC_PidReceipt_Owner("todo46_unreadable_tags")
		_LLM_Ollama_TagsPoll(_LLM_CurlAdoptProcess(4991, Port), "body", "status", "exit",
			_OHTC_PidReceipt_RecordResult.Bind(State), A_TickCount, Owner, Port, true)
		AssertEqual("unreadable_model_list", State["value"]["reason"], "malformed successful body is unknown")
	}
}
Test("Ollama local presence: native tags terminal distinguishes empty, HTTP refusal and malformed (todo-46-local-model)",
	_OHTC_StrictPresenceReceipts)


; A terminal sidecar can precede the shell's physical exit; strict enable must
; retain the exact native HANDLE until wait and close both acknowledge it.
_OHTC_EnableReceiptObserve(State, Owner, Value) {
	State["aux_current_at_callback"] := LLM_AuxIsCurrent(Owner)
	_OHTC_PidReceipt_RecordResult(State, Value)
}

_OHTC_EnableReceiptWaitsForPhysicalSettlement() {
	State := _OHTC_PidReceipt_State(Map("complete", true, "exit", 0, "status", 200,
		"body_read", true, "body", '{"version":"0.12.3"}'), 9481)
	State["wait"] := 258
	Port := _OHTC_PidReceipt_Port(State)
	Port["wait_process"] := (*) => State["wait"]
	Process := _LLM_CurlAdoptProcess(48481, Port)
	Owner := _OHTC_PidReceipt_Owner("enable_version_settlement")
	Callback := _OHTC_EnableReceiptObserve.Bind(State, Owner)
	try {
		_LLM_Ollama_PingPoll(Process, "body", "status", "exit", Callback, A_TickCount, Owner, Port, true)
		AssertEqual(0, State["callback_calls"], "a valid HTTP sidecar alone cannot confirm enable")
		AssertEqual(0, State["close_calls"], "the exact running process cannot be abandoned")
		AssertTrue(LLM_AuxIsCurrent(Owner), "the existing auxiliary owner retains the pending native wait")
		State["wait"] := 0
		_LLM_Ollama_PingPoll(Process, "body", "status", "exit", Callback, A_TickCount, Owner, Port, true)
		AssertEqual(1, State["callback_calls"])
		AssertTrue(State["value"] is Map, "opt-in mode publishes the actual terminal receipt")
		AssertEqual(200, State["value"]["status"])
		AssertTrue(LLM_EnableReceipt(State["value"])["admitted"])
		AssertFalse(State["aux_current_at_callback"], "auxiliary settlement precedes the enable callback")
		AssertEqual(1, State["close_calls"])
		AssertEqual(State["handle"], State["closed_handle"])
		AssertEqual(0, State["terminate_calls"], "normal readiness does not terminate a child")
	} finally {
		State["wait"] := 0
		LLM_AuxFinish(Owner)
		_LLM_CurlReleaseProcess(Process, true, _LLM_OllamaPingAcknowledgedPort(Process, Port))
	}
}
Test("Ollama enable receipt: native wait and auxiliary settlement precede confirmed version delivery",
	_OHTC_EnableReceiptWaitsForPhysicalSettlement)

_OHTC_EnableCancellationRequiresExitAcknowledgement() {
	global _LLM_CurlCleanupDebt, _LLM_CurlCleanupRetryTimer
	Saved := Map("debt", _LLM_CurlCleanupDebt, "timer", _LLM_CurlCleanupRetryTimer)
	State := _OHTC_PidReceipt_State(Map("complete", false), 9482)
	State["wait"] := 258
	Port := _OHTC_PidReceipt_Port(State)
	Port["wait_process"] := (*) => State["wait"]
	Process := _LLM_CurlAdoptProcess(48482, Port)
	AcknowledgedPort := _LLM_OllamaPingAcknowledgedPort(Process, Port)
	try {
		_LLM_CurlCleanupDebt := Map()
		_LLM_CurlCleanupRetryTimer := 0
		AssertFalse(_LLM_CurlReleaseProcess(Process, true, AcknowledgedPort),
			"accepted TerminateProcess is not physical exit acknowledgement")
		AssertEqual(1, State["terminate_calls"])
		AssertEqual(0, State["close_calls"])
		AssertFalse(Process["released"], "native debt retains the exact HANDLE")
		AssertEqual(1, _LLM_CurlCleanupDebt.Count)
		AssertFalse(LLM_CurlRetryCleanupDebt(), "a pending wait cannot drain native cleanup debt")
		AssertEqual(1, State["terminate_calls"], "accepted termination is not resent on every retry")
		State["wait"] := 0
		AssertTrue(LLM_CurlRetryCleanupDebt(), "the actual retained process exit settles ownership")
		AssertEqual(1, State["close_calls"])
		AssertEqual(State["handle"], State["closed_handle"])
		AssertTrue(Process["released"])
		AssertEqual(0, _LLM_CurlCleanupDebt.Count)
	} finally {
		State["wait"] := 0
		_LLM_CurlReleaseProcess(Process, true, AcknowledgedPort)
		LLM_CurlRetryCleanupDebt()
		if HasMethod(_LLM_CurlCleanupRetryTimer, "Call")
			SetTimer(_LLM_CurlCleanupRetryTimer, 0)
		_LLM_CurlCleanupDebt := Saved["debt"]
		_LLM_CurlCleanupRetryTimer := Saved["timer"]
	}
}
Test("Ollama enable receipt: accepted native termination retains cleanup debt until exact process exit",
	_OHTC_EnableCancellationRequiresExitAcknowledgement)


_OHTC_EnableSelectedOriginRefusal() {
	global LLM_OLLAMA_BASE_URL
	State := Map("callbacks", 0, "result", 0)
	Owner := LLM_AuxBegin("enable_foreign_version", Map("backend", "ollama",
		"endpoint", LLM_OLLAMA_BASE_URL . "/foreign"))
	OnResult(Value) {
		State["callbacks"] += 1
		State["result"] := Value
	}
	try {
		LLM_OllamaIsRunning_Async(OnResult, Owner, true)
		AssertEqual(1, State["callbacks"], "a foreign origin is refused by the actual native dispatch entry")
		AssertFalse(State["result"]["ok"])
		AssertEqual(0, Owner["process_pid"], "origin mismatch cannot launch curl")
		AssertFalse(LLM_AuxIsCurrent(Owner), "ordinary origin refusal settles auxiliary ownership")
	} finally LLM_AuxFinish(Owner)
}
Test("Ollama enable receipt: actual native entry refuses an owner from another selected origin before dispatch",
	_OHTC_EnableSelectedOriginRefusal)
