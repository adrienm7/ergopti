; tests/meta/test_stream_final_flush_sleep_blocks_thread.ahk

; ==============================================================================
; MODULE: Streaming Final-Flush Non-Blocking Meta Test
; DESCRIPTION:
; Static source guard for the stream-final-flush-sleep-blocks-thread finding.
;
; _LLM_Ollama_StreamPoll's end-of-stream flush used a synchronous Sleep(40)
; loop (up to 5 iterations = ~200 ms) inside a timer callback to paper over a
; child-process stdout flush lag. A blocking Sleep inside the AHK message-pump
; thread freezes input handling -- the moment streaming is re-enabled the user
; would feel up to 200 ms of input lag / dropped keystrokes per prediction.
;
; The fix moves the final flush into _LLM_Ollama_StreamFinalFlush, which
; re-arms itself as a one-shot SetTimer between reads instead of Sleep()ing, so
; the message pump stays live. This meta-static guard asserts the streaming
; poll + final-flush bodies contain no Sleep( call so the blocking flush can
; never be reintroduced once streaming is turned back on. Meta-static because
; driving the streaming poll requires a real curl child process.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ No-blocking-Sleep assertions ===========
; ===================================================
; ===================================================

_SFFSBT_StreamPollHasNoSleep() {
	; Move-resilient: locate _LLM_Ollama_StreamPoll() by name via the framework
	; helper instead of a pinned modules/llm/api_ollama.ahk read.
	Body := _DriverFuncBody("_LLM_Ollama_StreamPoll")
	Assert(Body != "", "_LLM_Ollama_StreamPoll must exist in api_ollama.ahk")
	Assert(InStr(Body, "Sleep(") == 0,
		"_LLM_Ollama_StreamPoll must not block the message pump with Sleep( -- the end-of-stream flush must re-arm a timer instead (stream-final-flush-sleep-blocks-thread)")
}
Test("api_ollama: _LLM_Ollama_StreamPoll has no blocking Sleep (stream-final-flush-sleep-blocks-thread)", _SFFSBT_StreamPollHasNoSleep)

_SFFSBT_FinalFlushIsNonBlocking() {
	Body := _DriverFuncBody("_LLM_Ollama_StreamFinalFlush")
	Assert(Body != "", "_LLM_Ollama_StreamFinalFlush must exist -- the end-of-stream flush must live in a re-armed function, not a Sleep loop")
	Assert(InStr(Body, "Sleep(") == 0,
		"_LLM_Ollama_StreamFinalFlush must not block with Sleep( (stream-final-flush-sleep-blocks-thread)")
	Assert(InStr(Body, "SetTimer(") > 0,
		"_LLM_Ollama_StreamFinalFlush must re-arm a one-shot SetTimer to retry the flush non-blockingly (stream-final-flush-sleep-blocks-thread)")
}
Test("api_ollama: _LLM_Ollama_StreamFinalFlush re-arms a timer instead of sleeping (stream-final-flush-sleep-blocks-thread)", _SFFSBT_FinalFlushIsNonBlocking)
