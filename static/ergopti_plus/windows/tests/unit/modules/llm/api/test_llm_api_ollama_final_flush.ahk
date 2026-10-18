; tests/unit/modules/llm/api/test_llm_api_ollama_final_flush.ahk

; ==============================================================================
; MODULE: Ollama Stream Final Flush Cancellation Tests
; DESCRIPTION:
; A completed curl process still has a deferred final-flush continuation. Public
; cancellation must fence its real file reads, partial callback and final verdict
; just as it fences the live poll, including a final record without a newline.
; ==============================================================================

#Requires AutoHotkey v2.0





_OllamaFinalFlush_Partial(State, Handle, Boundary, Text) {
	State["partials"] += 1
	if Boundary == "partial"
		LLM_OllamaCancelStream(Handle)
}

_OllamaFinalFlush_ReadCancelled(Handle, Path, State, Final) {
	; Preserve the actual reader boundary: only cancellation is injected, after
	; real JSONL bytes have been read and before the flush can publish them.
	Chunk := _LLM_Ollama_ReadStreamText(Path, State, Final)
	LLM_OllamaCancelStream(Handle)
	return Chunk
}

_OllamaFinalFlush_CancellationBoundary(Boundary, Newline) {
	global _LLM_Ollama_ActiveStreams, _LLM_Ollama_IsReady, _LLM_ManagedBootstrap
	SavedStreams := _LLM_Ollama_ActiveStreams
	SavedReady := _LLM_Ollama_IsReady
	SavedBootstrap := _LLM_ManagedBootstrap
	_LLM_ManagedBootstrap := 0
	_LLM_Ollama_IsReady := true
	State := Map("partials", 0, "successes", 0, "failures", 0, "text", "")
	Path := A_Temp . "\ergopti_flush_cancel_" . A_TickCount . "_" . Random(1, 1000000)
	Handle := { Pid: 0, ProcessOwner: 0, Cancelled: false,
		TmpPayload: Path . ".json", TmpStdout: Path . ".out" }
	_LLM_Ollama_ActiveStreams := [Handle]
	try {
		FileAppend('{"message":{"content":"complete answer"},"done":true}'
			. (Newline ? "`n" : ""), Handle.TmpStdout, "UTF-8-RAW")
		if Boundary == "before"
			LLM_OllamaCancelStream(Handle)
		_LLM_Ollama_StreamFinalFlush(Handle, Map("acc", "", "last_pos", 0),
			_OllamaFinalFlush_Partial.Bind(State, Handle, Boundary),
			(Text) => (State["successes"] += 1, State["text"] := Text),
			(*) => State["failures"] += 1,
			Boundary == "read" ? _OllamaFinalFlush_ReadCancelled.Bind(Handle) : _LLM_Ollama_ReadStreamText)
		AssertEqual(Boundary == "before" || Boundary == "read" ? 0 : 1, State["partials"],
			"a cancelled final flush must read no further partial completion")
		AssertEqual(Boundary == "none" ? 1 : 0, State["successes"],
			"cancellation must prevent the final-flush success handoff")
		AssertEqual(Boundary == "none" ? 0 : 1, State["failures"],
			"stream cancellation must retain its single failure settlement")
		if Boundary == "none"
			AssertEqual("complete answer", State["text"], "the positive control must drain the real completion")
		AssertFalse(FileExist(Handle.TmpStdout), "the final-flush owner must remove its real output file")
		AssertEqual(0, _LLM_Ollama_ActiveStreams.Length, "a settled flush must release its active handle")
	} finally {
		if FileExist(Handle.TmpStdout)
			FileDelete(Handle.TmpStdout)
		_LLM_ManagedBootstrap := SavedBootstrap
		_LLM_Ollama_IsReady := SavedReady
		_LLM_Ollama_ActiveStreams := SavedStreams
	}
}

for Boundary in ["before", "read", "partial", "none"] {
	for Newline in [false, true] {
		Test("Ollama final flush: cancellation " . Boundary . " with newline=" . Newline
			. " (ollama-final-flush-cancellation)",
			_OllamaFinalFlush_CancellationBoundary.Bind(Boundary, Newline))
	}
}
