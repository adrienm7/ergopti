; tests/unit/modules/llm/api/test_llm_api_remote_completion_reads.ahk

; ==============================================================================
; MODULE: Remote HTTP Completion Read Ownership Tests
; DESCRIPTION:
; WinHTTP wait/status/body calls can pump cancellation or replace the owning
; reservation. Keep custody through those reads so stale work neither queries
; later properties nor publishes a verdict. Public cancellation remains real.
; ==============================================================================

#Requires AutoHotkey v2.0





class _RemoteCompletionReads_Http {
	__New(State, ReqId, Boundary, Outcome, Interrupt) {
		this.State := State
		this.ReqId := ReqId
		this.Boundary := Boundary
		this.Outcome := Outcome
		this.Interrupt := Interrupt
	}

	AtBoundary(Name) {
		global _LLM_Remote_Async
		this.State[Name . "_reads"] += 1
		if Name != this.Boundary
			return
		if this.Interrupt == "cancel"
			LLM_RemoteCancelAsync(this.ReqId)
		else if this.Interrupt == "remove" {
			if _LLM_Remote_Async.Has(this.ReqId)
				_LLM_Remote_Async.Delete(this.ReqId)
		} else if this.Interrupt == "replace"
			_LLM_Remote_Async[this.ReqId] := this.State["successor"]
		if this.Outcome == "throw"
			throw Error("injected HTTP " . Name . " read failure")
	}

	WaitForResponse(*) {
		this.AtBoundary("wait")
		return this.Outcome != "pending"
	}

	Status {
		get {
			this.AtBoundary("status")
			return 200
		}
	}

	ResponseText {
		get {
			this.AtBoundary("body")
			return '{"choices":[{"message":{"content":"owned answer"}}]}'
		}
	}

	Abort() {
		this.State["aborts"] += 1
		return true
	}
}

_RemoteCompletionReads_Case(Boundary, Outcome, Interrupt) {
	global _LLM_Remote_Async
	SavedRegistry := _LLM_Remote_Async
	_LLM_Remote_Async := Map()
	ReqId := "completion_read_" . Boundary . "_" . Outcome . "_" . Interrupt
	State := Map("wait_reads", 0, "status_reads", 0, "body_reads", 0, "aborts", 0,
		"successes", 0, "failures", 0, "reason", "", "text", "",
		"successor", Map("transport", "pending", "cancelled", false))
	Entry := Map("transport", "winhttp", "cancelled", false,
		"format", "openai", "start_tick", A_TickCount, "timeout_ms", 100000,
		"on_success", (Text, Usage) => (State["successes"] += 1, State["text"] := Text),
		"on_fail", (Info) => (State["failures"] += 1, State["reason"] := Info["reason"]))
	Entry["http"] := _RemoteCompletionReads_Http(State, ReqId, Boundary, Outcome, Interrupt)
	_LLM_Remote_Async[ReqId] := Entry
	try {
		_LLMRemote_PollRequest(ReqId)
		Uninterrupted := Interrupt == "none"
		WaitStopped := Boundary == "wait" && (!Uninterrupted || Outcome != "ok")
		StatusStopped := Boundary == "status" && (!Uninterrupted || Outcome == "throw")
		AssertEqual(1, State["wait_reads"], "every fixture must enter the actual wait boundary")
		AssertEqual(WaitStopped ? 0 : 1, State["status_reads"],
			"revoked wait completion must not read status")
		AssertEqual(WaitStopped || StatusStopped ? 0 : 1, State["body_reads"],
			"revoked status completion must not read the response body")
		AssertEqual(Uninterrupted && Outcome == "ok" ? 1 : 0, State["successes"],
			"only the uninterrupted completion may publish its answer")
		AssertEqual(Uninterrupted && Outcome == "throw" ? 1 : 0, State["failures"],
			"only an owned read failure may publish a failure verdict")
		if Uninterrupted && Outcome == "ok"
			AssertEqual("owned answer", State["text"])
		if Uninterrupted && Outcome == "throw"
			AssertEqual("transport", State["reason"])
		if Interrupt == "replace" {
			AssertTrue(_LLM_Remote_Async.Has(ReqId), "a stale read must preserve the successor slot")
			AssertEqual(ObjPtr(State["successor"]), ObjPtr(_LLM_Remote_Async[ReqId]),
				"a stale read must preserve the exact successor reservation")
		} else if Uninterrupted && Outcome == "pending"
			AssertTrue(_LLM_Remote_Async[ReqId] == Entry, "a still-pending positive control retains its owner")
		else
			AssertFalse(_LLM_Remote_Async.Has(ReqId), "terminal or cancelled reads must release their slot")
		if Interrupt == "cancel" {
			Started := A_TickCount
			while State["aborts"] == 0 && A_TickCount - Started < 1000
				Sleep(1)
			AssertTrue(State["aborts"] > 0, "public cancellation must retain its deferred HTTP abort")
		}
	} finally {
		_LLM_Remote_Async := SavedRegistry
	}
}

for Boundary in ["wait", "status", "body"] {
	for Outcome in ["ok", "throw"] {
		for Interrupt in ["none", "cancel", "remove", "replace"] {
			Test("remote HTTP completion: " . Boundary . "/" . Outcome . " preserves " . Interrupt
				. " (remote-http-completion-reads)",
				_RemoteCompletionReads_Case.Bind(Boundary, Outcome, Interrupt))
		}
	}
}
for Interrupt in ["none", "cancel", "remove", "replace"] {
	Test("remote HTTP completion: pending wait preserves " . Interrupt . " (remote-http-completion-reads)",
		_RemoteCompletionReads_Case.Bind("wait", "pending", Interrupt))
}
