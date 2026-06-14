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
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_RPD_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_RPD_FuncBodyStripped(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		Rest := SubStr(Rest, 1, End + 1)
	Out := ""
	loop parse, Rest, "`n", "`r" {
		Line := A_LoopField
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}




; ===================================================
; ===================================================
; ======= 2/ Deadline cap assertions ================
; ===================================================
; ===================================================

_RPD_PollHasDeadlineCheck() {
	Src := _RPD_ReadSource("modules/llm/api_remote.ahk")
	Body := _RPD_FuncBodyStripped(Src, "_LLMRemote_PollRequest(req_id) {")
	Assert(Body != "", "_LLMRemote_PollRequest must exist in modules/llm/api_remote.ahk")
	Assert(InStr(Body, "deadline_tick") > 0,
		"_LLMRemote_PollRequest must check deadline_tick — without a cap the poll timer fires forever on a stalled WinHTTP request (remote-poll-no-deadline-cap)")
}
Test("api_remote: _LLMRemote_PollRequest checks deadline_tick to cap infinite poll loop (remote-poll-no-deadline-cap)", _RPD_PollHasDeadlineCheck)

_RPD_DeadlineTickStoredAtDispatch() {
	Src := _RPD_ReadSource("modules/llm/api_remote.ahk")
	Body := _RPD_FuncBodyStripped(Src, "LLM_RemoteGenerate_Async(Entry,")
	Assert(Body != "", "LLM_RemoteGenerate_Async must exist in modules/llm/api_remote.ahk")
	Assert(InStr(Body, "deadline_tick") > 0,
		"LLM_RemoteGenerate_Async must store deadline_tick in the registry entry so _LLMRemote_PollRequest can enforce it")
}
Test("api_remote: LLM_RemoteGenerate_Async stores deadline_tick in the registry entry (remote-poll-no-deadline-cap)", _RPD_DeadlineTickStoredAtDispatch)




; ===================================================
; ===================================================
; ======= 3/ Abort on cancel assertions =============
; ===================================================
; ===================================================

_RPD_CancelAsyncAbortsHttp() {
	Src := _RPD_ReadSource("modules/llm/api_remote.ahk")
	Body := _RPD_FuncBodyStripped(Src, "LLM_RemoteCancelAsync(req_id) {")
	Assert(Body != "", "LLM_RemoteCancelAsync must exist in modules/llm/api_remote.ahk")
	Assert(InStr(Body, ".Abort()") > 0,
		"LLM_RemoteCancelAsync must call .Abort() on the WinHTTP object — setting cancelled:=true alone leaves the live HTTP request consuming bandwidth (remote-poll-no-deadline-cap)")
}
Test("api_remote: LLM_RemoteCancelAsync calls .Abort() to kill the live WinHTTP request (remote-poll-no-deadline-cap)", _RPD_CancelAsyncAbortsHttp)

_RPD_CancelAllAbortsHttp() {
	Src := _RPD_ReadSource("modules/llm/api_remote.ahk")
	Body := _RPD_FuncBodyStripped(Src, "LLM_RemoteCancelAllAsync() {")
	Assert(Body != "", "LLM_RemoteCancelAllAsync must exist in modules/llm/api_remote.ahk")
	Assert(InStr(Body, ".Abort()") > 0,
		"LLM_RemoteCancelAllAsync must call .Abort() on each WinHTTP object — setting cancelled:=true alone leaves all live requests consuming bandwidth (remote-poll-no-deadline-cap)")
}
Test("api_remote: LLM_RemoteCancelAllAsync calls .Abort() to kill all live WinHTTP requests (remote-poll-no-deadline-cap)", _RPD_CancelAllAbortsHttp)
