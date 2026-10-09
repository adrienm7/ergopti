; static/ergopti_plus/windows/tests/meta/test_remote_token_not_on_argv.ahk

; ==============================================================================
; MODULE: Regression — the provider token must never reach the curl command line
;         (remote-token-on-argv)
; DESCRIPTION:
; When the remote POST moved from WinHTTP to a curl child, the auth header moved
; with it — from process memory onto argv. _LLMRemote_DispatchCurl spliced
; `-H "Authorization: Bearer <token>"` (or `x-api-key`, or the Gemini URL that
; carries `?key=<token>`) straight into the command line it handed to Run().
;
; ROOT CAUSE ENCODED: argv is a weaker boundary than the file the same subsystem
; had already hardened. Win32_Process.CommandLine is readable by any same-user
; process with no elevation, and process-creation telemetry (Sysmon event 1, EDR
; agents, several AV products) copies argv verbatim into logs this driver does
; not control and cannot purge. The typed-context payload was moved into a
; per-PID temp directory for exactly this class of reason
; (test_ollama_curl_temp_pii_plaintext.ahk); the credential in the same command
; line was not brought along. curl reads both the URL and its headers from a
; --config file, so the credential can travel by the boundary that was already
; accepted — and be deleted on every completion path.
;
; SCOPE: source-level. There is no failure mode to observe: the request succeeds
; either way, which is precisely why nothing would ever report this.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==========================================================
; ==========================================================
; ======= 1/ Credentials travel by file, not by argv =======
; ==========================================================
; ==========================================================

_RTNA_DispatchPutsNoCredentialOnTheCommandLine() {
	Disp := _DriverFuncBody("_LLMRemote_DispatchCurl")
	Assert(Disp != "", "_LLMRemote_DispatchCurl must exist in the driver source")

	Assert(InStr(Disp, "_LLMRemote_BuildCurlAuthArgs") == 0,
		"the auth header must not be spliced into the curl command line. A same-user process reads it from Win32_Process.CommandLine with no elevation, and Sysmon/EDR copy argv into logs the driver cannot purge (remote-token-on-argv)")

	Assert(InStr(Disp, "--config") > 0,
		"credentials must travel through a curl --config file — the same hardened per-PID directory the typed-context payload already uses")

	Assert(InStr(Disp, "_LLM_Ollama_TempDir") > 0,
		"that config file must live in _LLM_Ollama_TempDir(), not the shared %TEMP% root — the per-PID directory is what the PII payload hardening bought")
}

; No surviving helper may put the token back on argv by another name.
_RTNA_NoHelperEmitsATokenBearingHeaderArg() {
	Args := _DriverFuncBodyOrEmpty("_LLMRemote_BuildCurlAuthArgs")
	Assert(Args == "" or InStr(Args, '"-H "') == 0,
		"no surviving helper may emit a -H argument carrying the token — moving the splice one function away does not move it off the command line")

	Disp := _DriverFuncBody("_LLMRemote_DispatchCurl")
	Assert(Disp != "",
		"_LLMRemote_DispatchCurl() must exist — an absent body makes the two absence "
		. "assertions below pass without proving anything")
	Assert(InStr(Disp, "Bearer") == 0 and InStr(Disp, "x-api-key") == 0,
		"the dispatch function must not name an auth header at all: whatever it concatenates ends up in argv")
}





; ===============================================================
; ===============================================================
; ======= 2/ The file carrying the token is always reaped =======
; ===============================================================
; ===============================================================

; Moving the credential into a file only helps if the file dies with the request.
; Every completion path — cancelled, deadline, registry trim, normal completion —
; funnels through _LLMRemote_CurlCleanup, so the deletion belongs there.
_RTNA_ConfigFileIsDeletedOnEveryPath() {
	Clean := _DriverFuncBody("_LLMRemote_CurlCleanup")
	Assert(Clean != "", "_LLMRemote_CurlCleanup must exist in the driver source")

	Assert(InStr(Clean, "tmp_config") > 0,
		"the config file carrying the token must be deleted in _LLMRemote_CurlCleanup — that is the one place every completion path (cancel, deadline, trim, success) already goes through, so anywhere else leaves a plaintext credential behind on some branch")

	Disp := _DriverFuncBody("_LLMRemote_DispatchCurl")
	Assert(InStr(Disp, "tmp_config") > 0,
		"the dispatch must register tmp_config on the registry entry, or the cleanup has nothing to find")
}


Test("meta remote-token-on-argv: the curl dispatch puts no credential on the command line",
	_RTNA_DispatchPutsNoCredentialOnTheCommandLine)
Test("meta remote-token-on-argv: no helper emits a token-bearing -H argument",
	_RTNA_NoHelperEmitsATokenBearingHeaderArg)
Test("meta remote-token-on-argv: the config file is deleted on every completion path",
	_RTNA_ConfigFileIsDeletedOnEveryPath)
