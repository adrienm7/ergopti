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


; Structured receipt delivery keeps its current slot until exact handback.
_OHTD_Schedule(World, Callback, Period) {
	if Period == 0 {
		World["timer_cancels"] += 1
		return
	}
	if World["schedule_refused"]
		throw Error("controlled delivery scheduler refusal")
	World["timers"].Push(Callback)
}

_OHTD_Delivered(World, Value) {
	World["callback_calls"] += 1
	World["callback_current"] := LLM_AuxIsCurrent(World["owner"])
	World["result"] := Value
	if World["callback_refused"]
		throw Error("controlled callback failure")
}

_OHTD_Finalize(World) {
	World["finalizer_calls"] += 1
	if HasMethod(World.Get("finalizer_action", 0), "Call")
		World["finalizer_action"].Call()
	if !World["finalizer_ack"]
		throw Error("controlled finalizer refusal")
}

_OHTD_CurlDebt(World) {
	Process := Map("pid", 49551, "handle", 9551, "released", false)
	Port := Map("terminate_process", (*) => (World["terminates"] += 1, true),
		"wait_process", (*) => World["wait"],
		"close_process", (*) => (World["closes"] += 1, true))
	World["debt_process"] := Process
	World["debt_port"] := _LLM_OllamaPingAcknowledgedPort(Process, Port)
	AssertFalse(_LLM_CurlReleaseProcess(Process, true, World["debt_port"]),
		"accepted termination does not settle an exact process whose wait is pending")
}

_OHTD_AuxDebt(World) {
	Resources := Map("cancel", (*) => (World["debt_cancels"] += 1, World["debt_ack"]),
		"finalizer", (*) => World["debt_finalizers"] += 1)
	AssertFalse(_LLM_AuxCleanupDetached(Resources, true),
		"the real auxiliary retry owner retains the refused cancellation")
}

_OHTD_Deliver(World, Value := unset) {
	if !IsSet(Value)
		Value := Map("ok", true, "status", 200, "body", '{"version":"0.12.3"}')
	try return _LLM_OllamaPingDeliver(World["owner"], _OHTD_Delivered.Bind(World), Value, true,
		_OHTD_Schedule.Bind(World))
	finally _OHTD_CancelFixtureCurlRetry()
}

_OHTD_CancelFixtureCurlRetry() {
	global _LLM_CurlCleanupRetryTimer
	; Curl's real retry operator can arm a one-shot while Critical is held.
	; Cancel that exact function before another manual retry resets its field.
	if HasMethod(_LLM_CurlCleanupRetryTimer, "Call")
		SetTimer(_LLM_CurlCleanupRetryTimer, 0)
	_LLM_CurlCleanupRetryTimer := (*) => 0
}

_OHTD_Pump(World) {
	AssertTrue(World["timers"].Length > 0, "pending delivery owns a recorded one-shot")
	try World["timers"][World["timers"].Length].Call()
	finally _OHTD_CancelFixtureCurlRetry()
}

_OHTD_AssertDelivered(World) {
	AssertEqual(1, World["callback_calls"], "the admitted terminal callback is delivered exactly once")
	AssertFalse(World["callback_current"], "physical handback and slot retirement precede the callback")
	AssertFalse(LLM_AuxIsCurrent(World["owner"]))
	AssertTrue(World["owner"]["ping_delivery"]["delivered"])
}

_OHTD_WithFixture(Body) {
	global _LLM_AuxGeneration, _LLM_AuxOwnerCounter, _LLM_AuxOwners
	global _LLM_AuxCleanupDebt, _LLM_AuxCleanupDebtCounter
	global _LLM_CurlCleanupDebt, _LLM_CurlCleanupDebtCounter, _LLM_CurlCleanupRetryTimer
	global LLM_OLLAMA_BASE_URL
	PreviousCritical := Critical("On")
	Saved := Map("generation", _LLM_AuxGeneration, "counter", _LLM_AuxOwnerCounter,
		"owners", _LLM_AuxOwners, "aux_debt", _LLM_AuxCleanupDebt,
		"aux_counter", _LLM_AuxCleanupDebtCounter, "curl_debt", _LLM_CurlCleanupDebt,
		"curl_counter", _LLM_CurlCleanupDebtCounter, "curl_timer", _LLM_CurlCleanupRetryTimer)
	World := Map("callback_calls", 0, "callback_current", true, "result", 0,
		"timers", [], "timer_cancels", 0, "schedule_refused", false, "callback_refused", false,
		"finalizer_ack", true, "finalizer_calls", 0, "own_cancels", 0,
		"wait", 258, "terminates", 0, "closes", 0,
		"debt_ack", false, "debt_cancels", 0, "debt_finalizers", 0)
	FirstError := 0
	CleanupError := 0
	try {
		_LLM_AuxOwners := Map()
		_LLM_AuxCleanupDebt := Map()
		_LLM_CurlCleanupDebt := Map()
		; No process is created. Any real one-shot acquired by CurlRetry is
		; cancelled by exact function before manual retry or ledger restoration.
		_LLM_CurlCleanupRetryTimer := (*) => 0
		Owner := LLM_AuxBegin("structured_delivery_regression", Map("backend", "ollama",
			"endpoint", LLM_OLLAMA_BASE_URL))
		World["owner"] := Owner
		AssertTrue(LLM_AuxBindResources(Owner, Map(
			"cancel", (*) => (World["own_cancels"] += 1, true),
			"finalizer", _OHTD_Finalize.Bind(World))))
		Body.Call(World)
	} catch as Err {
		FirstError := Err
	} finally {
		try {
			_OHTD_CancelFixtureCurlRetry()
			World["wait"] := 0
			World["debt_ack"] := true
			World["finalizer_ack"] := true
			World["finalizer_action"] := 0
			LLM_AuxInvalidate("structured_delivery_fixture_retirement")
			AssertTrue(LLM_AuxRetryCleanupDebt(), "all exact recording finalizers must hand back")
			AssertTrue(LLM_CurlRetryCleanupDebt(), "all exact recording process capabilities must hand back")
		} catch as Err {
			CleanupError := Err
		} finally {
			try _OHTD_CancelFixtureCurlRetry()
			catch as Err {
				if !IsObject(CleanupError)
					CleanupError := Err
				Saved["aux_counter"] += 1
				Saved["aux_debt"][Saved["aux_counter"]] := Map("resources",
					Map("timer", _LLM_CurlCleanupRetryTimer), "cancel_work", true, "running", false)
			}
			; Unexpected debts stay strongly owned in the predecessor ledger even
			; when a causal mutation makes cleanup itself fail.
			for _, Record in _LLM_AuxCleanupDebt {
				Saved["aux_counter"] += 1
				Saved["aux_debt"][Saved["aux_counter"]] := Record
			}
			for _, Record in _LLM_CurlCleanupDebt {
				Saved["curl_counter"] += 1
				Saved["curl_debt"][Saved["curl_counter"]] := Record
				if Record.Get("kind", "") == "process"
					Record["owner"]["cleanup_debt_id"] := Saved["curl_counter"]
			}
			_LLM_AuxGeneration := Saved["generation"]
			_LLM_AuxOwnerCounter := Saved["counter"]
			_LLM_AuxOwners := Saved["owners"]
			_LLM_AuxCleanupDebt := Saved["aux_debt"]
			_LLM_AuxCleanupDebtCounter := Saved["aux_counter"]
			_LLM_CurlCleanupDebt := Saved["curl_debt"]
			_LLM_CurlCleanupDebtCounter := Saved["curl_counter"]
			_LLM_CurlCleanupRetryTimer := Saved["curl_timer"]
			Critical(PreviousCritical)
		}
	}
	if IsObject(FirstError)
		throw FirstError
	if IsObject(CleanupError)
		throw CleanupError
}

_OHTD_CurlPendingThenExactAck(World) {
	_OHTD_CurlDebt(World)
	AssertFalse(_OHTD_Deliver(World))
	AssertTrue(LLM_AuxIsCurrent(World["owner"]), "pending delivery retains its exact current slot")
	AssertFalse(World["owner"]["cleanup_claimed"], "the retry timer must remain cancellable")
	AssertEqual(0, World["callback_calls"])
	_OHTD_Pump(World)
	AssertEqual(0, World["callback_calls"], "multiple pending polls never waive the process wait")
	AssertEqual(0, World["closes"])
	AssertEqual(1, World["terminates"], "accepted termination is never retried as an insertion or new process")
	World["wait"] := 0
	_OHTD_Pump(World)
	_OHTD_AssertDelivered(World)
	AssertEqual(1, World["closes"])
	AssertTrue(World["debt_process"]["released"])
	AssertEqual(200, World["result"]["status"])
	AssertFalse(_OHTD_Deliver(World, Map("ok", false, "status", 0, "body", "")))
	_OHTD_Pump(World)
	AssertEqual(1, World["callback_calls"], "late repeated calls cannot deliver or replace the first terminal receipt")
}
Test("Ollama structured delivery: pending curl wait retains slot then exact ACK delivers once",
	_OHTD_WithFixture.Bind(_OHTD_CurlPendingThenExactAck))

_OHTD_AuxPendingThenAck(World) {
	_OHTD_AuxDebt(World)
	AssertFalse(_OHTD_Deliver(World))
	AssertTrue(LLM_AuxIsCurrent(World["owner"]))
	AssertEqual(0, World["callback_calls"])
	AssertEqual(0, World["debt_finalizers"])
	World["debt_ack"] := true
	_OHTD_Pump(World)
	_OHTD_AssertDelivered(World)
	AssertEqual(1, World["debt_finalizers"])
}
Test("Ollama structured delivery: pending auxiliary cancellation keeps both barriers",
	_OHTD_WithFixture.Bind(_OHTD_AuxPendingThenAck))

_OHTD_OwnFinalizerRefusal(World) {
	World["finalizer_ack"] := false
	AssertFalse(_OHTD_Deliver(World))
	AssertEqual(0, World["callback_calls"])
	AssertTrue(LLM_AuxIsCurrent(World["owner"]))
	AssertEqual(1, World["finalizer_calls"])
	World["finalizer_ack"] := true
	_OHTD_Pump(World)
	_OHTD_AssertDelivered(World)
	AssertEqual(2, World["finalizer_calls"], "only the refused exact finalizer is retried")
	AssertEqual(0, World["own_cancels"], "successful completion preserves the existing non-cancellation contract")
}
Test("Ollama structured delivery: its own refused finalizer retains the callback",
	_OHTD_WithFixture.Bind(_OHTD_OwnFinalizerRefusal))

_OHTD_CancelPending(World, Transition) {
	_OHTD_CurlDebt(World)
	AssertFalse(_OHTD_Deliver(World))
	if Transition == "cancel"
		_LLM_AuxRetireOwner(World["owner"], true)
	else if Transition == "generation"
		LLM_AuxInvalidate("structured_delivery_generation")
	else {
		Successor := LLM_AuxBegin(World["owner"]["kind"], Map("backend", "ollama",
			"endpoint", World["owner"]["endpoint"]))
		AssertTrue(LLM_AuxIsCurrent(Successor))
	}
	AssertFalse(LLM_AuxIsCurrent(World["owner"]))
	AssertTrue(World["timer_cancels"] > 0, "the exact pending retry timer is retired")
	World["wait"] := 0
	AssertTrue(LLM_CurlRetryCleanupDebt())
	_OHTD_Pump(World)
	AssertFalse(_OHTD_Deliver(World))
	AssertEqual(0, World["callback_calls"], "obsolete terminal data cannot survive cancellation or replacement")
	AssertTrue(World["debt_process"]["released"])
}
_OHTD_TransitionCase(Transition, World) {
	_OHTD_CancelPending(World, Transition)
}
for Transition in ["cancel", "generation", "replacement"]
	Test("Ollama structured delivery: " . Transition . " keeps late pending callbacks inert",
		_OHTD_WithFixture.Bind(_OHTD_TransitionCase.Bind(Transition)))

_OHTD_SelectedOriginRefusal(World) {
	_OHTD_CurlDebt(World)
	World["owner"]["endpoint"] .= "/foreign"
	; This actual dispatch entry refuses before process acquisition. The first
	; terminal result stays false even if a later observer offers a success map.
	LLM_OllamaIsRunning_Async(_OHTD_Delivered.Bind(World), World["owner"], true)
	_OHTD_CancelFixtureCurlRetry()
	AssertEqual(0, World["callback_calls"])
	AssertEqual(0, World["owner"]["process_pid"])
	AssertTrue(LLM_AuxIsCurrent(World["owner"]))
	World["wait"] := 0
	AssertTrue(_OHTD_Deliver(World))
	_OHTD_AssertDelivered(World)
	AssertFalse(World["result"]["ok"], "a repeated delivery cannot replace the recorded origin refusal")
	AssertEqual(0, World["result"]["status"])
}
Test("Ollama structured delivery: actual selected-origin refusal survives pending cleanup",
	_OHTD_WithFixture.Bind(_OHTD_SelectedOriginRefusal))

_OHTD_SchedulerRefusal(World) {
	_OHTD_CurlDebt(World)
	World["schedule_refused"] := true
	AssertFalse(_OHTD_Deliver(World))
	AssertTrue(LLM_AuxIsCurrent(World["owner"]), "a refused retry arm retains the current delivery authority")
	AssertFalse(World["owner"]["cleanup_claimed"])
	AssertEqual("delivery_schedule_refused", World["owner"]["ping_delivery"]["first_error"])
	AssertEqual(0, World["owner"]["timer"])
	AssertEqual(0, World["callback_calls"])
	World["schedule_refused"] := false
	World["wait"] := 0
	AssertTrue(_OHTD_Deliver(World))
	_OHTD_AssertDelivered(World)
	AssertEqual("delivery_schedule_refused", World["owner"]["ping_delivery"]["first_error"],
		"later recovery never erases the first scheduling refusal")
}
Test("Ollama structured delivery: a late scheduler refusal retains authority and first diagnostic",
	_OHTD_WithFixture.Bind(_OHTD_SchedulerRefusal))

_OHTD_CallbackFailure(World) {
	World["callback_refused"] := true
	AssertTrue(_OHTD_Deliver(World), "the existing callback boundary logs and abandons callback failure")
	_OHTD_AssertDelivered(World)
	AssertFalse(_OHTD_Deliver(World))
	AssertEqual(1, World["callback_calls"], "callback failure does not restore consumed authority")
}
Test("Ollama structured delivery: a throwing callback cannot regain delivery authority",
	_OHTD_WithFixture.Bind(_OHTD_CallbackFailure))

_OHTD_CancelDuringFinalizer(World) {
	World["finalizer_action"] := (*) => LLM_AuxInvalidate("structured_delivery_during_finalizer")
	AssertFalse(_OHTD_Deliver(World))
	AssertFalse(LLM_AuxIsCurrent(World["owner"]))
	AssertEqual(0, World["callback_calls"], "cleanup reentry cannot consume an invalidated ticket")
	AssertEqual(0, World["timers"].Length, "an invalidated owner cannot arm another retry")
	AssertTrue(LLM_AuxRetryCleanupDebt())
}
Test("Ollama structured delivery: finalizer reentry revalidates the exact generation",
	_OHTD_WithFixture.Bind(_OHTD_CancelDuringFinalizer))

_OHTD_EnableSnapshot(Captured) {
	Live := Captured.Clone()
	Live["generation"] := LLM_AuxGeneration()
	Live["blocked"] := !LLM_AuxRetryCleanupDebt() || !LLM_CurlRetryCleanupDebt()
	return Live
}

_OHTD_EnableNotify(World, Request) {
	World["notices"] += 1
	return false
}

_OHTD_EnableDelivery(World, Request, Value) {
	_OHTD_Delivered(World, Value)
	_LLM_Menu_EnableOnReceipt(Request, Value)
}

_OHTD_EnablePending(World, CancelPending) {
	global _LLM_Menu_EnableAdmission, LLM_OLLAMA_BASE_URL
	SavedRequest := _LLM_Menu_EnableAdmission
	Request := 0
	try {
		LLM_AuxFinish(World["owner"])
		World["owner"] := LLM_AuxBegin("ollama_enable_admission", Map(
			"backend", "ollama", "endpoint", LLM_OLLAMA_BASE_URL . "/foreign"))
		Captured := Map("backend", "ollama", "model", "recording:model",
			"origin", LLM_OLLAMA_BASE_URL, "generation", LLM_AuxGeneration(),
			"enabled", false, "paused", false, "blocked", false)
		World["notices"] := 0
		Request := Map("active", true, "captured", Captured, "aux", World["owner"],
			"port", Map("snapshot", _OHTD_EnableSnapshot.Bind(Captured),
				"notify", _OHTD_EnableNotify.Bind(World)))
		_LLM_Menu_EnableAdmission := Request
		_OHTD_CurlDebt(World)
		Callback := _OHTD_EnableDelivery.Bind(World, Request)
		LLM_OllamaIsRunning_Async(Callback, World["owner"], true)
		_OHTD_CancelFixtureCurlRetry()
		AssertEqual(0, World["callback_calls"])
		AssertTrue(Request["active"], "pending typed refusal still owns the real enable request")
		AssertTrue(LLM_AuxIsCurrent(World["owner"]))
		if CancelPending {
			AssertFalse(LLM_Menu_CancelEnableAdmission(), "cancel retains the exact outstanding process debt")
			_OHTD_CancelFixtureCurlRetry()
			AssertFalse(Request["active"])
			AssertEqual(0, _LLM_Menu_EnableAdmission)
			AssertFalse(LLM_AuxIsCurrent(World["owner"]))
			World["wait"] := 0
			AssertTrue(LLM_CurlRetryCleanupDebt())
			AssertFalse(_LLM_OllamaPingDeliver(World["owner"], Callback,
				Map("ok", true, "status", 200, "body", '{"version":"late"}'), true))
			AssertEqual(0, World["callback_calls"])
			AssertEqual(0, World["notices"])
		} else {
			World["wait"] := 0
			AssertTrue(_LLM_OllamaPingDeliver(World["owner"], Callback,
				Map("ok", true, "status", 200, "body", '{"version":"late"}'), true))
			_OHTD_AssertDelivered(World)
			AssertFalse(World["result"]["ok"], "actual setup refusal cannot become a repeated success packet")
			AssertEqual(1, World["notices"], "the original refusal reaches the actual enable consumer exactly once")
			AssertFalse(Request["active"], "terminal refusal retires the actual enable request")
			AssertEqual(0, _LLM_Menu_EnableAdmission)
		}
	} finally {
		if Request is Map && Request.Get("active", false)
			LLM_Menu_CancelEnableAdmission()
		_LLM_Menu_EnableAdmission := SavedRequest
	}
}

_OHTD_EnableRefusalCase(World) {
	_OHTD_EnablePending(World, false)
}
Test("Ollama structured delivery: typed setup refusal settles and cleans the actual enable request",
	_OHTD_WithFixture.Bind(_OHTD_EnableRefusalCase))

_OHTD_EnableCancelCase(World) {
	_OHTD_EnablePending(World, true)
}
Test("Ollama structured delivery: cancelling actual enable before ACK keeps late refusal inert",
	_OHTD_WithFixture.Bind(_OHTD_EnableCancelCase))
