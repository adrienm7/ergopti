; tests/meta/test_remote_poll_deadline.ahk

; ==============================================================================
; MODULE: Remote Poll Deadline Meta Test
; DESCRIPTION:
; Static source guard for the remote-poll-no-deadline-cap finding.
;
; _LLMRemote_PollRequest previously re-armed a 50 ms SetTimer forever with no
; deadline, so a silently-dropped CDN response or stalled WinHTTP request
; would keep the timer firing indefinitely, saturating the message pump and
; dropping keystrokes.
;
; The fix adds two guards to api_remote.ahk:
; a) An absolute-time deadline_tick computed at dispatch and stored in the
;    registry entry.  _LLMRemote_PollRequest checks it and calls on_fail()
;    then returns without re-arming when the deadline passes.
; b) LLM_RemoteCancelAsync() and LLM_RemoteCancelAllAsync() call .Abort() on
;    the WinHTTP ComObject immediately so stalled requests do not keep
;    consuming network bandwidth after cancellation (previously only set
;    cancelled := true).
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Deadline cap assertions ================
; ===================================================
; ===================================================

_RPD_PollHasDeadlineCheck() {
	; Move-resilient: locate the function across the driver source via the framework
	; helper (also strips full-line comments) instead of a pinned api_remote.ahk path.
	Body := _DriverFuncBody("_LLMRemote_PollRequest")
	Assert(Body != "", "_LLMRemote_PollRequest must exist in modules/llm/api_remote.ahk")
	Assert(InStr(Body, "deadline_tick") > 0,
		"_LLMRemote_PollRequest must check deadline_tick — without a cap the poll timer fires forever on a stalled WinHTTP request (remote-poll-no-deadline-cap)")
}
Test("api_remote: _LLMRemote_PollRequest checks deadline_tick to cap infinite poll loop (remote-poll-no-deadline-cap)", _RPD_PollHasDeadlineCheck)

_RPD_DeadlineTickStoredAtDispatch() {
	Body := _DriverFuncBody("LLM_RemoteGenerate_Async")
	Assert(Body != "", "LLM_RemoteGenerate_Async must exist in modules/llm/api_remote.ahk")
	Assert(InStr(Body, "deadline_tick") > 0,
		"LLM_RemoteGenerate_Async must store deadline_tick in the registry entry so _LLMRemote_PollRequest can enforce it")
}
Test("api_remote: LLM_RemoteGenerate_Async stores deadline_tick in the registry entry (remote-poll-no-deadline-cap)", _RPD_DeadlineTickStoredAtDispatch)




; ===================================================
; ===================================================
; ======= 2/ Abort on cancel assertions =============
; ===================================================
; ===================================================

_RPD_CancelAsyncAbortsHttp() {
	Body := _DriverFuncBody("LLM_RemoteCancelAsync")
	Assert(Body != "", "LLM_RemoteCancelAsync must exist in modules/llm/api_remote.ahk")
	Assert(InStr(Body, ".Abort()") > 0,
		"LLM_RemoteCancelAsync must call .Abort() on the WinHTTP object — setting cancelled:=true alone leaves the live HTTP request consuming bandwidth (remote-poll-no-deadline-cap)")
}
Test("api_remote: LLM_RemoteCancelAsync calls .Abort() to kill the live WinHTTP request (remote-poll-no-deadline-cap)", _RPD_CancelAsyncAbortsHttp)

; The invariant here is that a cancelled request is really ABORTED, not merely
; flagged — a flag alone leaves the live request consuming bandwidth. That has
; not changed. What changed is WHERE the abort happens: LLM_RemoteCancelAllAsync
; is reached from the per-keystroke Critical, where a cross-apartment COM call
; blocks the message pump and starves the keyboard hook, so the abort is now
; handed to LLM_DeferCancelKills and executed on the next thread.
;
; The assertion therefore follows the whole chain instead of grepping one token
; in one body. That is strictly stronger: the old form was satisfied by the
; literal string alone and would have stayed green even if the collected object
; were never actually aborted.
;
; LLM_RemoteCancelAsync (singular) deliberately keeps its inline abort — it is
; not reached from the keystroke path, so it pays no Critical penalty.
_RPD_CancelAllAbortsHttp() {
	Body := _DriverFuncBody("LLM_RemoteCancelAllAsync")
	Assert(Body != "", "LLM_RemoteCancelAllAsync must exist in modules/llm/api_remote.ahk")
	Assert(InStr(Body, 'entry["http"]') > 0,
		"LLM_RemoteCancelAllAsync must still collect each live WinHTTP object — setting cancelled:=true alone leaves all live requests consuming bandwidth (remote-poll-no-deadline-cap)")
	Assert(InStr(Body, "LLM_DeferCancelKills(") > 0,
		"LLM_RemoteCancelAllAsync must hand the collected transports to LLM_DeferCancelKills — the abort must still happen, just not under the per-keystroke Critical")

	Runner := _DriverFuncBody("_LLM_RunCancelKills")
	Assert(Runner != "", "_LLM_RunCancelKills must exist — it is where the deferred abort actually runs")
	Assert(InStr(Runner, ".Abort()") > 0,
		"_LLM_RunCancelKills must call .Abort() on every collected WinHTTP object — deferring the abort must not become dropping it (remote-poll-no-deadline-cap)")
}
Test("api_remote: LLM_RemoteCancelAllAsync calls .Abort() to kill all live WinHTTP requests (remote-poll-no-deadline-cap)", _RPD_CancelAllAbortsHttp)
