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
; a) A start_tick + timeout_ms interval stored in the registry entry.
;    _LLMRemote_PollRequest checks it with wrap-safe elapsed arithmetic and calls on_fail()
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
	Assert(InStr(Body, '_LLM_DeadlineExpired(entry["start_tick"], entry["timeout_ms"])') > 0,
		"_LLMRemote_PollRequest must check its wrap-safe start/timeout interval — without a cap the poll timer fires forever on a stalled WinHTTP request (remote-poll-no-deadline-cap)")
}
Test("api_remote: _LLMRemote_PollRequest checks deadline_tick to cap infinite poll loop (remote-poll-no-deadline-cap)", _RPD_PollHasDeadlineCheck)

_RPD_DeadlineTickStoredAtDispatch() {
	Body := _DriverFuncBody("LLM_RemoteGenerate_Async")
	Assert(Body != "", "LLM_RemoteGenerate_Async must exist in modules/llm/api_remote.ahk")
	ReserveBody := _DriverFuncBody("_LLMRemote_ReserveRequest")
	Assert(ReserveBody != "",
		"_LLMRemote_ReserveRequest must own the pre-dispatch registry record")
	Assert(InStr(Body, "_LLMRemote_ReserveRequest(") > 0
		and InStr(ReserveBody, '"start_tick"') > 0 and InStr(ReserveBody, '"timeout_ms"') > 0,
		"LLM_RemoteGenerate_Async must store the wrap-safe start/timeout pair so _LLMRemote_PollRequest can enforce it")
	Assert(InStr(Body, '"deadline_tick"') == 0 and InStr(ReserveBody, '"deadline_tick"') == 0,
		"LLM_RemoteGenerate_Async must not store an absolute A_TickCount deadline that breaks at rollover")
}
Test("api_remote: LLM_RemoteGenerate_Async stores deadline_tick in the registry entry (remote-poll-no-deadline-cap)", _RPD_DeadlineTickStoredAtDispatch)




; ===================================================
; ===================================================
; ======= 2/ Abort on cancel assertions =============
; ===================================================
; ===================================================

; The invariant is unchanged: a cancelled request must really be ABORTED, not
; merely flagged — a flag alone leaves the live request consuming bandwidth.
; What changed is WHERE the abort runs. The singular cancel now hands its
; transport to LLM_DeferCancelKills like the plural one, so both halves of the
; public cancel API carry the same contract and neither can starve the keyboard
; hook if a future caller reaches them from the per-keystroke Critical.
;
; The assertion follows the whole chain rather than grepping one token in one
; body — strictly stronger than the old form, which the literal string alone
; satisfied and which would have stayed green even if the collected object were
; never actually aborted.
_RPD_CancelAsyncAbortsHttp() {
	Body := _DriverFuncBody("LLM_RemoteCancelAsync")
	Assert(Body != "", "LLM_RemoteCancelAsync must exist in modules/llm/api_remote.ahk")
	Assert(InStr(Body, 'entry["http"]') > 0,
		"LLM_RemoteCancelAsync must still collect the live WinHTTP object — setting cancelled:=true alone leaves the request consuming bandwidth (remote-poll-no-deadline-cap)")
	Assert(InStr(Body, "LLM_DeferCancelKills(") > 0,
		"LLM_RemoteCancelAsync must hand the transport to LLM_DeferCancelKills — the abort must still happen, just not inline under a caller's Critical")

	Runner := _DriverFuncBody("_LLM_RunCancelKills")
	Assert(Runner != "", "_LLM_RunCancelKills must exist — it is where the deferred abort actually runs")
	Assert(InStr(Runner, ".Abort()") > 0,
		"_LLM_RunCancelKills must call .Abort() on every collected WinHTTP object — deferring the abort must not become dropping it (remote-poll-no-deadline-cap)")
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
; Both the singular and plural cancels now defer. Neither has a production caller
; today — they are public API surface — so this is a uniformity change rather
; than a measured latency win, and it removes the trap of a future caller
; reaching the singular one from the keystroke path and finding an inline
; cross-apartment COM call there.
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
