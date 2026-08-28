; tests/meta/test_remote_generate_curl_dispatch.ahk

; ==============================================================================
; MODULE: Remote Generate Curl-Dispatch Meta Test
; DESCRIPTION:
; Static source guard for finding remote-generate-connect-blocks (F-H03, full fix).
;
; WinHttpRequest.5.1's "async" mode (Open(...,true) + Send()) makes only the
; RESPONSE wait asynchronous; the DNS resolve + TCP connect still run SYNCHRONOUSLY
; on the message-loop thread that pumps the PrefixWatcher InputHook. So a stalled
; remote host froze typing (and dropped keystrokes) for the whole connect on every
; remote-API prediction fire — exactly the class the Ollama paths were migrated off
; WinHTTP onto curl child processes to fix.
;
; The fix dispatches the remote POST through a curl child process (mirror of
; _LLM_Ollama_DispatchAsync): the connect happens in curl's own process and the AHK
; message loop only polls the durable terminal sidecar. A missing curl transport
; fails closed instead of falling back to a blocking WinHTTP request.
;
; Meta-static because modules/llm is not in the headless runner's include graph, and
; the live POST cannot be exercised without a remote-API key.
; ==============================================================================

#Requires AutoHotkey v2.0


_RGC_AssertCurlDispatch() {
	gen := _DriverFuncBody("LLM_RemoteGenerate_Async")
	Assert(gen != "", "LLM_RemoteGenerate_Async must exist")
	Assert(InStr(gen, "_LLMRemote_DispatchCurl(req_id") > 0,
		"LLM_RemoteGenerate_Async must dispatch through the curl child")
	Assert(!InStr(gen, "_LLMRemote_DispatchWinHttp("),
		"remote generation must never fall back to WinHTTP on the AHK thread")

	disp := _DriverFuncBody("_LLMRemote_DispatchCurl")
	Assert(disp != "", "_LLMRemote_DispatchCurl must exist")
	Assert(InStr(disp, "curl.exe") > 0 and InStr(disp, "_LLM_CurlRunOwned(RunFn") > 0,
		"_LLMRemote_DispatchCurl must launch through its child-process port so the connect happens off the message-loop thread (remote-generate-connect-blocks)")
	Assert(!InStr(disp, "http.Send") and !InStr(disp, "WinHttpRequest"),
		"_LLMRemote_DispatchCurl must not perform a synchronous WinHTTP Send on the dispatch path (remote-generate-connect-blocks)")
	runner := _DriverFuncBody("_LLM_CurlArtifactRun")
	Assert(runner != "", "the default curl artifact runner must exist")
	Assert(InStr(runner, 'DllCall("Kernel32\CreateProcessW"') > 0
		and InStr(runner, "ProcessOwner := Map(") > 0,
		"the default child-process port must create and retain the exact process handle in one native call")

	poll := _DriverFuncBody("_LLMRemote_PollCurl")
	Assert(poll != "", "_LLMRemote_PollCurl must exist")
	Assert(InStr(poll, "_LLM_CurlTerminalComplete(") > 0
		and InStr(poll, "ProcessExist(") = 0,
		"_LLMRemote_PollCurl must poll the durable sidecar without blocking or trusting a recyclable PID (remote-generate-connect-blocks)")
}
Test("LLM remote: generation dispatches through a curl child for a non-blocking connect (remote-generate-connect-blocks)", _RGC_AssertCurlDispatch)

_RGC_AssertEveryCurlLaunchPublishesNativeOwnership() {
	for FunctionName in ["_LLMRemote_DispatchCurl", "LLM_OllamaIsRunning_Async",
			"LLM_OllamaListModels_Async", "LLM_OllamaDeleteModel_Async",
			"_LLM_Ollama_DoSpawn", "LLM_OllamaGenerate_Streaming"] {
		Body := _DriverFuncBody(FunctionName)
		Assert(Body != "", FunctionName . " must remain present")
		Assert(InStr(Body, "_LLM_CurlRunOwned(") > 0,
			FunctionName . " must receive an exact process owner from the launch call")
		Assert(!InStr(Body, "_LLM_CurlAdoptProcess("),
			FunctionName . " must not launch first and adopt through fallible OpenProcess")
	}
}
Test("LLM curl: every launch site acquires exact ownership atomically (AHK-079)",
	_RGC_AssertEveryCurlLaunchPublishesNativeOwnership)
