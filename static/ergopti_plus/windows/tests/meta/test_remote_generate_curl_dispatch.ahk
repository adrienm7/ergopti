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
; message loop only polls ProcessExist. WinHTTP remains as a fallback only when curl
; is unavailable on the host, and its resolve+connect is bounded by a short timeout.
;
; Meta-static because modules/llm is not in the headless runner's include graph, and
; the live POST cannot be exercised without a remote-API key.
; ==============================================================================

#Requires AutoHotkey v2.0


_RGC_AssertCurlDispatch() {
	gen := _DriverFuncBody("LLM_RemoteGenerate_Async")
	Assert(gen != "", "LLM_RemoteGenerate_Async must exist")
	Assert(InStr(gen, "_LLMRemote_DispatchCurl(req_id") > 0,
		"LLM_RemoteGenerate_Async must try the curl child (_LLMRemote_DispatchCurl) before the blocking WinHTTP path (remote-generate-connect-blocks)")

	disp := _DriverFuncBody("_LLMRemote_DispatchCurl")
	Assert(disp != "", "_LLMRemote_DispatchCurl must exist")
	Assert(InStr(disp, "curl.exe") > 0 and InStr(disp, "Run(") > 0,
		"_LLMRemote_DispatchCurl must launch a curl child via Run so the connect happens off the message-loop thread (remote-generate-connect-blocks)")
	Assert(!InStr(disp, "http.Send") and !InStr(disp, "WinHttpRequest"),
		"_LLMRemote_DispatchCurl must not perform a synchronous WinHTTP Send on the dispatch path (remote-generate-connect-blocks)")

	poll := _DriverFuncBody("_LLMRemote_PollCurl")
	Assert(poll != "", "_LLMRemote_PollCurl must exist")
	Assert(InStr(poll, "ProcessExist") > 0,
		"_LLMRemote_PollCurl must poll ProcessExist (non-blocking), never block on the connect (remote-generate-connect-blocks)")
}
Test("LLM remote: generation dispatches through a curl child for a non-blocking connect (remote-generate-connect-blocks)", _RGC_AssertCurlDispatch)
