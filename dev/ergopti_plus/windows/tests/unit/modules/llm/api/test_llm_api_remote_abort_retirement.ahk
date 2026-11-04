; tests/unit/modules/llm/api/test_llm_api_remote_abort_retirement.ahk

; ==============================================================================
; MODULE: Remote HTTP Abort Retirement Tests
; DESCRIPTION:
; WinHTTP Abort can pump cancellation or eviction before the poll resumes. Every
; abandonment branch must retire only its exact reservation and suppress stale
; failure delivery while retaining a reentrant successor. No network is used.
; ==============================================================================

#Requires AutoHotkey v2.0





class _RemoteAbortRetirement_Http {
	__New(State, ReqId, Outcome, Interrupt) {
		this.State := State
		this.ReqId := ReqId
		this.Outcome := Outcome
		this.Interrupt := Interrupt
	}

	WaitForResponse(*) {
		this.State["waits"] += 1
		throw Error("injected disconnected HTTP request")
	}

	Abort() {
		global _LLM_Remote_Async
		this.State["aborts"] += 1
		if this.Interrupt == "cancel"
			this.State["entry"]["cancelled"] := true
		else if this.Interrupt == "remove"
			_LLM_Remote_Async.Delete(this.ReqId)
		else if this.Interrupt == "replace"
			_LLM_Remote_Async[this.ReqId] := this.State["successor"]
		return true
	}
}

_RemoteAbortRetirement_Case(Outcome, Interrupt) {
	global _LLM_Remote_Async
	SavedRegistry := _LLM_Remote_Async
	_LLM_Remote_Async := Map()
	ReqId := 998031
	State := Map("waits", 0, "aborts", 0, "successes", 0, "failures", 0, "reason", "",
		"successor", Map("transport", "pending", "cancelled", false))
	Entry := Map("transport", "winhttp", "cancelled", Outcome == "cancelled",
		"start_tick", A_TickCount - (Outcome == "deadline" ? 1000 : 0),
		"timeout_ms", Outcome == "deadline" ? 1 : 100000,
		"on_success", (*) => State["successes"] += 1,
		"on_fail", (Info) => (State["failures"] += 1, State["reason"] := Info["reason"]))
	State["entry"] := Entry
	Entry["http"] := _RemoteAbortRetirement_Http(State, ReqId, Outcome, Interrupt)
	_LLM_Remote_Async[ReqId] := Entry
	try {
		_LLMRemote_PollRequest(ReqId)
		AssertEqual(1, State["aborts"], "the abandoned HTTP transport must be aborted once")
		AssertEqual(Outcome == "exception" ? 1 : 0, State["waits"],
			"the fixture must reach the selected abandonment branch")
		AssertEqual(0, State["successes"], "an abandoned request must publish no completion")
		AssertEqual(Interrupt == "none" && Outcome != "cancelled" ? 1 : 0, State["failures"],
			"only the uninterrupted failing owner may deliver its terminal failure")
		if Interrupt == "none" && Outcome != "cancelled"
			AssertEqual(Outcome == "deadline" ? "timeout" : "transport", State["reason"],
				"the positive control must preserve the selected failure reason")
		if Interrupt == "replace" {
			AssertTrue(_LLM_Remote_Async.Has(ReqId), "Abort must preserve the successor slot")
			AssertEqual(ObjPtr(State["successor"]), ObjPtr(_LLM_Remote_Async[ReqId]),
				"Abort must retain the exact successor reservation")
		} else
			AssertFalse(_LLM_Remote_Async.Has(ReqId), "the retired request must leave no slot")
	} finally {
		_LLM_Remote_Async := SavedRegistry
	}
}

for Outcome in ["cancelled", "deadline", "exception"] {
	for Interrupt in ["none", "cancel", "remove", "replace"] {
		Test("remote HTTP Abort: " . Outcome . " preserves " . Interrupt
			. " (remote-http-abort-retirement)", _RemoteAbortRetirement_Case.Bind(Outcome, Interrupt))
	}
}
