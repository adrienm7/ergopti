; tests/meta/test_llm_streaming_fixes.ahk

; ==============================================================================
; MODULE: LLM Streaming Three-Fix Guard Meta Test
; DESCRIPTION:
; Static source guard for three audit findings in modules/llm/api_ollama.ahk.
;
; ROOT CAUSES ENCODED:
;
; 1. more_to_read INVERTED (llm-stream-more-to-read-inverted):
;    The original logic set more_to_read := false when the output file was empty,
;    meaning "no retry needed" — exactly backwards. With an empty file curl may
;    have just finished but not yet flushed its OS write buffer. The fix:
;      more_to_read := (!FileExist(handle.TmpStdout) or FileGetSize(handle.TmpStdout) = 0)
;    — true when empty (retry), false when the file has data (already drained).
;
; 2. LEFTOVER NOT FLUSHED (llm-stream-leftover-not-flushed):
;    A streaming JSON response whose last line lacks a trailing newline remains
;    in state["leftover"] indefinitely. _LLM_Ollama_StreamFinalFlush never flushed
;    this residual, producing "Streaming finished with empty response" for any
;    model that omits the trailing newline on the final token. The fix appends a
;    synthetic newline and processes the leftover before the final result check.
;
; 3. PID COLLISION IN HANDLE REGISTRY (llm-stream-pid-collision):
;    _LLM_Ollama_RemoveStreamHandle filtered by h.Pid != handle.Pid. Windows
;    aggressively reuses PIDs of short-lived processes, so a completed stream's
;    PID can be reused by a new unrelated process. The fix compares by object
;    reference (h != handle), which is stable for the lifetime of the handle
;    object, preventing silent removal of an unrelated active stream.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ more_to_read logic not inverted ========
; ==================================================
; ==================================================

_LLMSF_StripComments(Src) {
	Out := ""
	for Line in StrSplit(Src, "`n", "`r") {
		if !RegExMatch(Line, "^\s*;")
			Out .= Line . "`n"
	}
	return Out
}

_LLMSF_MoreToReadNotInverted() {
	; Move-resilient: scan the modules/llm dir via the framework helper. The
	; present-anchors here are unique to api_ollama.ahk within that dir, and the
	; comments are stripped so absent-checks cannot false-fail on a comment.
	Raw := _DriverDirConcat("modules/llm")
	Src := _LLMSF_StripComments(Raw)

	; The correct form: true when file is absent or empty (retry needed)
	Assert(InStr(Src, "more_to_read := (!FileExist(") > 0,
		"more_to_read must be assigned as (!FileExist(...) — true when file is empty/absent means retry is needed (llm-stream-more-to-read-inverted)")

	; The old inverted form must not be present
	Assert(InStr(Src, "more_to_read := (FileExist(") = 0 and InStr(Src, "more_to_read := FileExist(") = 0,
		"more_to_read must not be the non-negated FileExist form — that form is inverted (llm-stream-more-to-read-inverted)")
}
Test("api_ollama: more_to_read is true when file empty (retry needed), not inverted (llm-stream-more-to-read-inverted)", _LLMSF_MoreToReadNotInverted)




; ======================================================
; ======================================================
; ======= 2/ leftover flushed before final check ========
; ======================================================
; ======================================================

_LLMSF_LeftoverFlushedBeforeFinalCheck() {
	Raw := _DriverDirConcat("modules/llm")
	Src := _LLMSF_StripComments(Raw)

	; The leftover flush must call ConsumeStreamChunk with a synthetic newline
	Assert(InStr(Src, "state[" . Chr(34) . "leftover" . Chr(34) . "]") > 0,
		"api_ollama.ahk must reference state[leftover] in the final flush path")

	; Accept both the pre-fix form (passing state["leftover"] directly) and the
	; post-fix form (copying to a local before clearing, then passing the local).
	; The important invariant is that ConsumeStreamChunk is called in the flush path.
	Assert(InStr(Src, "ConsumeStreamChunk(") > 0,
		"api_ollama.ahk must flush leftover by calling ConsumeStreamChunk in the final flush path (llm-stream-leftover-not-flushed)")

	; The flush must append a synthetic newline so the JSON line is parsed as complete.
	; Chr(96) is the AHK backtick char (0x60); Chr(96)."n" matches the two-char literal backtick+n in source.
	; Accept either the direct form (state["leftover"] . "`n") or the local-copy form (_resid . "`n").
	BtN := Chr(34) . Chr(96) . "n" . Chr(34)
	Assert(InStr(Src, "state[" . Chr(34) . "leftover" . Chr(34) . "] . " . BtN) > 0
		or InStr(Src, "_resid . " . BtN) > 0,
		"api_ollama.ahk must append a newline to leftover before flushing — the last JSON line may lack a trailing newline (llm-stream-leftover-not-flushed)")
}
Test("api_ollama: StreamFinalFlush flushes state[leftover] with synthetic newline before result check (llm-stream-leftover-not-flushed)", _LLMSF_LeftoverFlushedBeforeFinalCheck)





; =====================================================
; =====================================================
; ======= 3/ stream handle removed by reference =======
; =====================================================
; =====================================================

_LLMSF_HandleRemovedByReference() {
	Raw := _DriverDirConcat("modules/llm")
	Src := _LLMSF_StripComments(Raw)

	; Object reference comparison must be present
	Assert(InStr(Src, "if h != handle") > 0,
		"api_ollama.ahk must compare stream handles by object reference (h != handle), not by PID (llm-stream-pid-collision)")

	; PID comparison must not be present
	Assert(InStr(Src, "h.Pid != handle.Pid") = 0 and InStr(Src, "h.Pid == handle.Pid") = 0,
		"api_ollama.ahk must not compare handles by PID — Windows reuses PIDs of short-lived processes (llm-stream-pid-collision)")
}
Test("api_ollama: RemoveStreamHandle uses object reference (h != handle), not PID comparison (llm-stream-pid-collision)", _LLMSF_HandleRemovedByReference)


_AHK011_EffectiveStreamingOwnsEveryWindowsBoundary() {
	HelperName := "LLM_EffectiveStreaming"
	Boundaries := [
		["LLM_Engine_Init", "engine admission"],
		["LLM_Engine_FirePrediction", "request dispatch"],
		["_LLM_Menu_SyncToFeatures", "durable persistence"],
		["_LLM_Menu_RestoreSavedOptsOnce", "saved-state restore"],
		["LLM_Menu_ToggleBool", "menu mutation"],
		["_LLM_Menu_ApplyBackendCommitted", "backend transition"],
		["LLM_Menu_BuildDisplayMenu", "visible menu state"]
	]
	for Boundary in Boundaries {
		Body := _DriverFuncBody(Boundary[1])
		Assert(Body != "",
			Boundary[2] . " boundary must remain discoverable")
		AssertContains(Body, HelperName . "(",
			Boundary[2] . " must consume the one effective streaming policy")
	}
	DisplayBody := _DriverFuncBody("LLM_Menu_BuildDisplayMenu")
	RowsBody := _DriverFuncBody("_LLM_Menu_DisplayRows")
	SnapshotBody := _DriverFuncBody("_LLM_Menu_StreamingSnapshot")
	CommandBody := _DriverFuncBody("_LLM_Menu_StreamingCommand")
	Assert(RowsBody != "" && SnapshotBody != "" && CommandBody != "",
		"shared row providers and native admission owners must remain discoverable")
	AssertContains(DisplayBody, 'MenuRenderer_Build("llm_display_menu"',
		"visible streaming must project the actual shared menu declaration")
	AssertContains(DisplayBody, '"llm_token_streaming_enabled", (*) => LLM_EffectiveStreaming(',
		"the shared checkbox binds the actual effective native transport policy")
	AssertContains(DisplayBody, '"llm_token_streaming_ready", (*) => LLM_DisplayStreamingReady(StreamingSource)',
		"the shared row binds acknowledged native owner availability")
	AssertContains(DisplayBody, '"llm_token_streaming", (*) => _LLM_Menu_StreamingCommand(StreamingSource, StreamingCommand)',
		"a retained shared row dispatches through its captured native owner")
	AssertContains(DisplayBody, 'StreamingCommand := (*) => LLM_Menu_ToggleBool("streaming")',
		"an admitted command retains the existing acknowledged settings transaction")
	AssertContains(CommandBody, "LLM_DisplayStreamingIntent(Expected, _LLM_Menu_StreamingSnapshot())",
		"the actual command compares its captured and current owner before mutation")
	GuardPosition := InStr(CommandBody, 'if !Decision["admitted"]')
	CallPosition := InStr(CommandBody, "Command.Call()")
	Assert(GuardPosition > 0 && CallPosition > GuardPosition
		&& InStr(SubStr(CommandBody, GuardPosition, CallPosition - GuardPosition), "return false") > 0,
		"a refused native owner must return before invoking the acknowledged command")
	AssertContains(SnapshotBody, "!IsSet(_LLM_Engine)",
		"an unset engine must remain unavailable without reading it")
	AssertContains(SnapshotBody, "!(_LLM_Engine is Map)",
		"non-map runtime owners must remain unavailable")
	for Key in ["backend", "enabled"] {
		HasPosition := InStr(SnapshotBody, '!_LLM_Engine.Has("' . Key . '")')
		ReadPosition := InStr(SnapshotBody, '_LLM_Engine["' . Key . '"]')
		Assert(HasPosition > 0 && ReadPosition > HasPosition,
			"an incomplete engine must be refused before reading " . Key)
	}
	Assert(InStr(RowsBody, '"llm_token_streaming"') = 0
		&& InStr(RowsBody, 't("menu.llm.show_streaming")') = 0
		&& InStr(RowsBody, 'LLM_Menu_ToggleBool("streaming")') = 0,
		"native row providers must not duplicate or bypass the shared streaming declaration")
	Matches := 0
	for Row in _MR_GetManifestRoot()["llm_display_menu"] {
		if Row.Get("id", "") != "llm_token_streaming"
			continue
		Matches += 1
		AssertEqual("check", Row["type"])
		AssertEqual("menu.llm.show_streaming", Row["i18n"])
		AssertEqual(1, Row["checked_when"].Length)
		AssertEqual("llm_token_streaming_enabled", Row["checked_when"][1])
		AssertEqual(1, Row["disabled_when"].Length)
		AssertEqual("llm_token_streaming_ready", Row["disabled_when"][1])
		AssertEqual("grey", Row["unavailable"])
		AssertEqual("platform_reason.token_streaming_transport_missing", Row["reason_key"])
	}
	AssertEqual(1, Matches, "exactly one authoritative shared declaration owns the visible streaming row")
	DispatchBody := _DriverFuncBody("LLM_Engine_FirePrediction")
	Assert(InStr(DispatchBody, "streaming_enabled := false") = 0,
		"backend branches must not silently override the published setting")
}
Test("AHK-011: effective streaming policy owns every Windows boundary",
	_AHK011_EffectiveStreamingOwnsEveryWindowsBoundary)
