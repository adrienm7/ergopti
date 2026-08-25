; static/ergopti_plus/windows/tests/meta/test_remote_curl_forwards_usage_meta.ahk

; ==============================================================================
; MODULE: Regression — the curl transport must forward the provider usage block
;         (remote-curl-drops-usage-meta)
; DESCRIPTION:
; The remote backend has two transports. _LLMRemote_PollRequest (WinHTTP) records
; the model id at dispatch, extracts the provider ``usage`` block and passes it as
; the second success argument. _LLMRemote_PollCurl did none of the three.
;
; ROOT CAUSE ENCODED: the connect-blocking fix added a second transport that
; copied only part of its sibling's contract, and the new transport SHORT-CIRCUITS
; the old one — LLM_RemoteGenerate_Async returns as soon as _LLMRemote_DispatchCurl
; owns the request, and that only declines when curl.exe is absent, which is no
; shipping Windows. So the only code path producing usage metadata was dead on
; every host, and the engine's `if (meta is Map)` gate left prompt_tokens /
; completion_tokens / total_tokens / est_cost_usd at zero. Because the finalizer
; only writes those fields when they are > 0, the keylogger event came out
; well-formed rather than truncated: nothing logged, nothing missing, just a cost
; report that is silently always zero.
;
; The behavioral suite drives the real poll with deterministic terminal
; receipts. This source guard independently pins the single-classifier wiring,
; so a future transport cannot split text and usage back into two parses.
;
; SCOPE: source-level. The poll tail runs only on a real curl child exit.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================================================
; ===================================================================
; ======= 1/ The curl poll completes like its WinHTTP sibling =======
; ===================================================================
; ===================================================================

_RCFU_CurlPollExtractsAndForwardsUsage() {
	Poll := _DriverFuncBody("_LLMRemote_PollCurl")
	Assert(Poll != "", "_LLMRemote_PollCurl must exist in the driver source")

	Assert(InStr(Poll, "_LLMRemoteClassifyTerminal(") > 0,
		"_LLMRemote_PollCurl must classify terminal evidence, completion and usage through one parsed response owner")

	Assert(InStr(Poll, 'Classified["text"], Classified["usage"]') > 0,
		"_LLMRemote_PollCurl must forward text and usage from the same classified root as the two success arguments")
}

; The cost estimate is priced per model, so the entry has to remember which model
; it dispatched against.
_RCFU_CurlEntryRecordsTheDispatchModel() {
	Disp := _DriverFuncBody("_LLMRemote_DispatchCurl")
	Assert(Disp != "", "_LLMRemote_DispatchCurl must exist in the driver source")

	Assert(InStr(Disp, "model_id_at_dispatch") > 0,
		"the curl registry entry must carry model_id_at_dispatch, or the usage extractor has no model key to price the response against and est_cost_usd stays 0 even when the token counts arrive")
}





; ====================================================
; ====================================================
; ======= 2/ A rejected request is diagnosable =======
; ====================================================
; ====================================================

; curl writes a provider ERROR body (401 bad key, 429 quota) to the same file as
; a success, and only the parse miss tells them apart. Failing there without a
; log line makes a rejected API key indistinguishable from a silent model.
_RCFU_CurlPollLogsItsFailureBranches() {
	Poll := _DriverFuncBody("_LLMRemote_PollCurl")
	Assert(Poll != "", "_LLMRemote_PollCurl must exist in the driver source")

	Warns := 0
	Pos := 1
	while (F := InStr(Poll, "LoggerWarn(", false, Pos)) {
		Pos := F + 1
		Warns += 1
	}
	Assert(Warns >= 3,
		"every failure branch of _LLMRemote_PollCurl (deadline, empty body, unparseable body) must log. Found " . Warns . " warning(s): a branch that calls on_fail with nothing in the log turns a rejected API key into 'predictions just do not appear' with an empty log to go on")
}


Test("meta remote-curl-drops-usage-meta: the curl poll extracts and forwards the usage block",
	_RCFU_CurlPollExtractsAndForwardsUsage)
Test("meta remote-curl-drops-usage-meta: the curl entry records the dispatch model",
	_RCFU_CurlEntryRecordsTheDispatchModel)
Test("meta remote-curl-drops-usage-meta: every curl failure branch is diagnosable",
	_RCFU_CurlPollLogsItsFailureBranches)
