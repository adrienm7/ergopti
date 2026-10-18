; tests/unit/modules/llm/api/test_llm_api_ollama_retirement.ahk

; ==============================================================================
; MODULE: Ollama Curl Retirement Tests
; DESCRIPTION:
; Qualifies exact request retirement across reentrant receipt reads and artifact
; cleanup. Each case owns and restores its fixture state so isolated selection
; and reverse execution preserve cancellation, successor identity and delivery.
; ==============================================================================

#Requires AutoHotkey v2.0





; Artifact cleanup pumps the same AHK message loop as receipt reads. Keep the
; public cancellation contract and the exact successor slot across both calls.
_OllamaPollRetirement_Interrupt(State, ReqId) {
	global _LLM_Ollama_Async
	if State["interrupt"] == "none"
		return
	if State["interrupt"] == "cancel"
		LLM_OllamaCancelAllAsync()
	else if State["interrupt"] == "remove"
		_LLM_Ollama_Async.Delete(ReqId)
	else
		_LLM_Ollama_Async[ReqId] := State["successor"]
}

_OllamaPollRetirement_Read(State, ReqId, *) {
	if State["boundary"] == "receipt"
		_OllamaPollRetirement_Interrupt(State, ReqId)
	return State["terminal"]
}

_OllamaPollRetirement_Cleanup(State, ReqId, Entry) {
	State["cleanups"] += 1
	AssertEqual(ObjPtr(State["entry"]), ObjPtr(Entry),
		"cleanup must retain the predecessor artifact owner")
	if State["boundary"] == "cleanup"
		_OllamaPollRetirement_Interrupt(State, ReqId)
}

_OllamaPollRetirement_PreservesCancellation(Outcome, Boundary, Interrupt) {
	global _LLM_Ollama_Async, _LLM_Ollama_Pending, _LLM_Ollama_ActiveStreams, _LLM_Ollama_IsReady
	SavedReady := _LLM_Ollama_IsReady
	_LLM_Ollama_IsReady := true
	SavedRegistry := _LLM_Ollama_Async
	SavedPending := _LLM_Ollama_Pending
	SavedStreams := _LLM_Ollama_ActiveStreams
	_LLM_Ollama_Async := Map()
	_LLM_Ollama_Pending := ""
	_LLM_Ollama_ActiveStreams := []
	ReqId := 999041
	State := Map("cleanups", 0, "successes", 0, "failures", 0, "reason", "",
		"boundary", Boundary, "interrupt", Interrupt,
		"successor", Map("cancelled", false))
	State["terminal"] := Map("complete", Outcome != "timeout", "exit", Outcome == "timeout" ? -1 : 0,
		"status", Outcome == "failure" ? 500 : 200, "body_read", true,
		"body", Outcome == "empty" ? "{}" : '{"message":{"content":"obsolete answer"}}')
	Entry := Map("cancelled", false,
		"tmp_stdout", "body", "tmp_status", "status", "tmp_exit", "exit",
		"start_tick", A_TickCount - 1000, "timeout_ms", 1,
		"on_success", (*) => State["successes"] += 1,
		"on_fail", (*) => State["failures"] += 1)
	State["entry"] := Entry
	_LLM_Ollama_Async[ReqId] := Entry
	Port := Map("read_terminal", _OllamaPollRetirement_Read.Bind(State, ReqId),
		"cleanup", _OllamaPollRetirement_Cleanup.Bind(State, ReqId))
	try {
		_LLM_Ollama_PollCurl(ReqId, Port)
		AssertEqual(1, State["cleanups"], "the predecessor artifacts must be cleaned once")
		AssertEqual(Outcome != "timeout", _LLM_CurlTerminalComplete(State["terminal"]),
			"the fixture must distinguish a committed response from a live timed-out child")
		AssertEqual(Interrupt == "none" && Outcome == "success" ? 1 : 0, State["successes"],
			"only an uninterrupted completion may publish success")
		AssertEqual(Interrupt == "none" && Outcome != "success" ? 1 : 0, State["failures"],
			"only an uninterrupted failure may publish its verdict")
		if Interrupt == "replace" {
			AssertTrue(_LLM_Ollama_Async.Has(ReqId), "the successor must remain registered")
			AssertEqual(ObjPtr(State["successor"]), ObjPtr(_LLM_Ollama_Async[ReqId]),
				"the old poll must preserve the exact successor")
		} else
			AssertFalse(_LLM_Ollama_Async.Has(ReqId), "the retired owner must leave no slot")
	} finally {
		_LLM_Ollama_IsReady := SavedReady
		_LLM_Ollama_Async := SavedRegistry
		_LLM_Ollama_Pending := SavedPending
		_LLM_Ollama_ActiveStreams := SavedStreams
	}
}

for Outcome in ["success", "failure", "empty", "timeout"] {
	for Boundary in ["receipt", "cleanup"] {
		for Interrupt in ["cancel", "remove", "replace", "none"] {
			Test("Ollama curl: " . Outcome . " preserves " . Interrupt . " during " . Boundary
				. " (ollama-poll-io-retirement)",
				_OllamaPollRetirement_PreservesCancellation.Bind(Outcome, Boundary, Interrupt))
		}
	}
}
