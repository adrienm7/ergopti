; tests/unit/modules/llm/api/test_llm_api_remote_retirement.ahk

; ==============================================================================
; MODULE: Remote Curl Retirement Tests
; DESCRIPTION:
; Qualifies exact request retirement across reentrant receipt reads and artifact
; cleanup. Each case owns and restores its fixture state so isolated selection
; and reverse execution preserve cancellation, successor identity and delivery.
; ==============================================================================

#Requires AutoHotkey v2.0





; Curl receipts and artifact removal pump the AHK message loop. A cancellation
; or registry replacement at either boundary must retain the new owner's slot
; and suppress every public verdict from the retired request.
_RemotePollRetirement_Interrupt(State, ReqId) {
	global _LLM_Remote_Async
	if State["interrupt"] == "none"
		return
	if State["interrupt"] == "cancel"
		LLM_RemoteCancelAsync(ReqId)
	else if State["interrupt"] == "remove"
		_LLM_Remote_Async.Delete(ReqId)
	else
		_LLM_Remote_Async[ReqId] := State["successor"]
}

_RemotePollRetirement_Read(State, ReqId, *) {
	if State["boundary"] == "receipt"
		_RemotePollRetirement_Interrupt(State, ReqId)
	return State["terminal"]
}

_RemotePollRetirement_Cleanup(State, ReqId, Entry) {
	State["cleanups"] += 1
	AssertEqual(ObjPtr(State["entry"]), ObjPtr(Entry),
		"cleanup must retain the predecessor artifact owner")
	if State["boundary"] == "cleanup"
		_RemotePollRetirement_Interrupt(State, ReqId)
}

_RemotePollRetirement_PreservesCancellation(Outcome, Boundary, Interrupt) {
	global _LLM_Remote_Async
	SavedRegistry := _LLM_Remote_Async
	_LLM_Remote_Async := Map()
	ReqId := "remote_poll_retirement"
	State := Map("cleanups", 0, "successes", 0, "failures", 0, "reason", "",
		"boundary", Boundary, "interrupt", Interrupt,
		"successor", Map("transport", "pending", "cancelled", false))
	State["terminal"] := Map("complete", Outcome != "timeout", "exit", Outcome == "timeout" ? -1 : 0,
		"status", Outcome == "failure" ? 500 : 200, "body_read", true,
		"body", Outcome == "empty" ? "{}" : (Outcome == "failure"
			? '{"error":{"message":"provider refused"}}' : '{"choices":[{"message":{"content":"obsolete answer"}}]}'))
	Entry := Map("transport", "curl", "cancelled", false,
		"tmp_stdout", "body", "tmp_status", "status", "tmp_exit", "exit",
		"format", "openai", "start_tick", A_TickCount - 1000, "timeout_ms", 1,
		"on_success", (*) => State["successes"] += 1,
		"on_fail", (Info) => (State["failures"] += 1, State["reason"] := Info["reason"]))
	State["entry"] := Entry
	_LLM_Remote_Async[ReqId] := Entry
	Port := Map("read_terminal", _RemotePollRetirement_Read.Bind(State, ReqId),
		"cleanup", _RemotePollRetirement_Cleanup.Bind(State, ReqId))
	try {
		_LLMRemote_PollCurl(ReqId, Port)
		AssertEqual(1, State["cleanups"], "the predecessor artifacts must be cleaned once")
		AssertEqual(Outcome != "timeout", _LLM_CurlTerminalComplete(State["terminal"]),
			"the fixture must distinguish a committed response from a live timed-out child")
		AssertEqual(Interrupt == "none" && Outcome == "success" ? 1 : 0, State["successes"],
			"only an uninterrupted completion may publish success")
		AssertEqual(Interrupt == "none" && Outcome != "success" ? 1 : 0, State["failures"],
			"only an uninterrupted failure may publish its verdict")
		if Interrupt == "none" && Outcome != "success"
			AssertEqual(Outcome == "timeout" ? "timeout" : (Outcome == "empty" ? "unsupported_shape" : "provider_error"),
				State["reason"], "the positive control must reach the intended terminal branch")
		if Interrupt == "replace" {
			AssertTrue(_LLM_Remote_Async.Has(ReqId), "the successor must remain registered")
			AssertEqual(ObjPtr(State["successor"]), ObjPtr(_LLM_Remote_Async[ReqId]),
				"the old poll must preserve the exact successor")
		} else
			AssertFalse(_LLM_Remote_Async.Has(ReqId), "the retired owner must leave no slot")
	} finally {
		_LLM_Remote_Async := SavedRegistry
	}
}

for Outcome in ["success", "failure", "empty", "timeout"] {
	for Boundary in ["receipt", "cleanup"] {
		for Interrupt in ["cancel", "remove", "replace", "none"] {
			Test("remote curl: " . Outcome . " preserves " . Interrupt . " during " . Boundary
				. " (remote-poll-io-retirement)",
				_RemotePollRetirement_PreservesCancellation.Bind(Outcome, Boundary, Interrupt))
		}
	}
}
