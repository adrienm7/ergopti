; tests/meta/test_ollama_reachability_async_nonblocking.ahk

; ==============================================================================
; MODULE: Ollama Reachability Probe Non-Blocking Test
; DESCRIPTION:
; Regression guard for the boot-time freeze where the IA tray menu took ~14 s to
; appear and keystrokes / prediction-cancel were unresponsive for seconds.
;
; Root cause: LLM_OllamaIsRunning_Async used the WinHttpRequest.5.1 COM object in
; "async" mode (Open(...,true) + Send()). Despite the async flag, that object
; performs the TCP connect SYNCHRONOUSLY on the calling (message-loop) thread, and
; against a cold/busy local daemon the connect blocked for up to ~9 s. Fired from
; the boot bootstrap, it froze the message loop — the tray build that ran during
; that window logged "built in 13860ms", and keystroke/pointer cancel callbacks
; were starved (the user's "menu prend une éternité" + "taper/bouger n'annule pas").
;
; THE FIX (the contract this test pins): the reachability probe runs a curl CHILD
; PROCESS (the same pattern the generation path already uses for exactly this
; reason) and only polls a durable terminal receipt — instant — so the AHK message loop is never
; blocked. The connect happens in curl's own process.
;
; Source-level (mirrors the sibling async-contract meta tests): the function is
; trivial to introspect and a behavioural harness would need to stub Run + the
; filesystem + a live daemon.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================
; ====================================
; ======= 1/ Non-blocking ping =======
; ====================================
; ====================================

_MetaCheckReachabilityNonBlocking() {
	Body := _DriverFuncBody("LLM_OllamaIsRunning_Async")
	Assert(Body != "", "api_ollama.ahk must define LLM_OllamaIsRunning_Async()")

	; It must NOT use the blocking WinHTTP COM send on the message-loop thread.
	Assert(!InStr(Body, ".Send("),
		"LLM_OllamaIsRunning_Async must NOT call WinHTTP http.Send() — its synchronous "
		. "connect blocks the message loop for seconds against a cold daemon (the boot freeze)")
	Assert(!InStr(Body, 'ComObject("WinHttp'),
		"LLM_OllamaIsRunning_Async must NOT create a WinHttpRequest COM object — use a curl child")

	; It MUST spawn a curl child and hand off to the non-blocking poll.
	Assert(InStr(Body, "curl") and InStr(Body, "_LLM_CurlRunOwned("),
		"LLM_OllamaIsRunning_Async must run a curl child process for the reachability ping")
	Assert(InStr(Body, "_LLM_Ollama_PingPoll("),
		"LLM_OllamaIsRunning_Async must hand off to _LLM_Ollama_PingPoll (poll the child, don't block)")

	; The poll must check the durable receipt — never a blocking wait or recyclable PID.
	PollBody := _DriverFuncBody("_LLM_Ollama_PingPoll")
	Assert(PollBody != "", "api_ollama.ahk must define _LLM_Ollama_PingPoll()")
	Assert(InStr(PollBody, "_LLM_CurlTerminalComplete(") > 0
		and InStr(PollBody, "ProcessExist(") = 0,
		"_LLM_Ollama_PingPoll must poll the durable terminal receipt, never a recyclable PID")
	Assert(InStr(PollBody, "ReadTerminalFn.Call(") > 0
		and InStr(PollBody, "_LLM_OllamaPingTerminalOk(") > 0,
		"_LLM_Ollama_PingPoll must classify exit, HTTP status, readable body, and the Ollama version schema before readiness")
	; Either call shape satisfies the invariant. The completion callbacks now go
	; through _LLM_InvokeCallback so a throw inside one cannot vanish, which
	; changes the SPELLING of the hand-off but not the contract being asserted:
	; the poll must still deliver its boolean through on_result rather than
	; returning it or dropping it.
	Assert(InStr(PollBody, "on_result(") or InStr(PollBody, "on_result,"),
		"_LLM_Ollama_PingPoll must deliver the boolean result via on_result")
}

Test("meta llm: Ollama reachability probe is non-blocking curl, not WinHTTP (ollama-reachability-winhttp-connect-blocks)",
	_MetaCheckReachabilityNonBlocking)

_MetaCheckInstallerDoesNotProbeWingetSynchronously() {
	Body := _DriverFuncBody("LLM_Deps_RunInstaller")
	Assert(Body != "", "LLM_Deps_RunInstaller must exist in ollama_deps_checker.ahk")
	Assert(InStr(Body, "RunWait(") = 0,
		"LLM_Deps_RunInstaller must not RunWait for 'where winget' on the menu thread")
	Assert(InStr(Body, "FileExist(WingetPath)") > 0,
		"the local winget alias must be checked without spawning a probe process")
	Assert(InStr(Body, "ShellRunner_SpawnTreeOwned") > 0 and InStr(Body, "Task.start()") > 0,
		"LLM_Deps_RunInstaller must launch winget asynchronously under exact process-tree ownership")
	Assert(_DriverFuncBodyOrEmpty("_LLM_Deps_HasWinget") = "",
		"the synchronous _LLM_Deps_HasWinget helper must not be reintroduced")
}
Test("meta llm: installer launches winget without a synchronous availability probe (ollama-winget-menu-block)",
	_MetaCheckInstallerDoesNotProbeWingetSynchronously)
