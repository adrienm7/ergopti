; tests/unit/modules/llm/api/test_llm_api_ollama_stream_utf8.ahk

; ==============================================================================
; MODULE: Ollama Stream UTF-8 Admission Tests
; DESCRIPTION:
; StrGet repairs malformed UTF-8 with replacement characters. The growing-file
; reader must reject those bytes before moving its cursor or publishing a
; completion. Fixtures use the owning streaming suite's native raw-byte writer.
; ==============================================================================

#Requires AutoHotkey v2.0





_OllamaStreamUtf8_EncodingBoundary(Bytes, Expected, Newline) {
	global _LLM_Ollama_ActiveStreams, _LLM_Ollama_IsReady, _LLM_ManagedBootstrap
	SavedStreams := _LLM_Ollama_ActiveStreams
	SavedReady := _LLM_Ollama_IsReady
	SavedBootstrap := _LLM_ManagedBootstrap
	_LLM_Ollama_IsReady := true
	_LLM_ManagedBootstrap := 0
	Path := A_Temp . "\ergopti_stream_utf8_" . A_TickCount . "_" . Random(1, 1000000)
	Handle := { Pid: 0, ProcessOwner: 0, Cancelled: false,
		TmpPayload: Path . ".json", TmpStdout: Path . ".out" }
	_LLM_Ollama_ActiveStreams := [Handle]
	State := Map("partials", 0, "successes", 0, "failures", 0, "text", "")
	try {
		FileAppend('{"message":{"content":"', Handle.TmpStdout, "UTF-8-RAW")
		_TLAO_AppendRawBytes(Handle.TmpStdout, Bytes)
		FileAppend('"},"done":true}' . (Newline ? "`n" : ""), Handle.TmpStdout, "UTF-8-RAW")
		Cursor := Map("last_pos", 0)
		ReadError := ""
		ReadText := ""
		try ReadText := _LLM_Ollama_ReadStreamText(Handle.TmpStdout, Cursor, true)
		catch as Err
			ReadError := Err.Message
		if Expected == "" {
			AssertContains(ReadError, "UTF-8", "invalid bytes must be refused instead of silently repaired")
			AssertEqual(0, Cursor["last_pos"], "a rejected encoding must retain its original byte checkpoint")
		} else {
			AssertEqual("", ReadError, "valid multibyte UTF-8 must still be admitted")
			AssertContains(ReadText, Expected, "the real reader must preserve the complete Unicode scalar")
			AssertEqual(FileGetSize(Handle.TmpStdout), Cursor["last_pos"],
				"only an accepted byte image may advance the checkpoint")
		}
		_LLM_Ollama_StreamFinalFlush(Handle, Map("acc", "", "last_pos", 0),
			(*) => State["partials"] += 1,
			(Text) => (State["successes"] += 1, State["text"] := Text),
			(*) => State["failures"] += 1)
		AssertEqual(Expected == "" ? 0 : 1, State["partials"], "encoding refusal must publish no partial")
		AssertEqual(Expected == "" ? 0 : 1, State["successes"], "only exact UTF-8 may become a completion")
		AssertEqual(Expected == "" ? 1 : 0, State["failures"], "malformed encoding must settle failure once")
		AssertEqual(Expected, State["text"], "no replacement text may cross the completion callback")
		AssertFalse(FileExist(Handle.TmpStdout), "terminal encoding refusal must still clean its real output")
		AssertEqual(0, _LLM_Ollama_ActiveStreams.Length, "encoding settlement must retire the stream handle")
	} finally {
		if FileExist(Handle.TmpStdout)
			FileDelete(Handle.TmpStdout)
		_LLM_Ollama_ActiveStreams := SavedStreams
		_LLM_Ollama_IsReady := SavedReady
		_LLM_ManagedBootstrap := SavedBootstrap
	}
}

for Utf8Sample in [
	["missing continuation", [0xC3], ""],
	["stray continuation", [0x80], ""],
	["overlong scalar", [0xC0, 0xAF], ""],
	["encoded surrogate", [0xED, 0xA0, 0x80], ""],
	["scalar above Unicode", [0xF4, 0x90, 0x80, 0x80], ""],
	["broken continuation", [0xE2, 0x28, 0xA1], ""],
	["two-byte scalar", [0xC3, 0xA9], Chr(0xE9)],
	["three-byte scalar", [0xE2, 0x82, 0xAC], Chr(0x20AC)],
	["four-byte scalar", [0xF0, 0x9F, 0x99, 0x82], Chr(0x1F642)],
	["literal replacement scalar", [0xEF, 0xBF, 0xBD], Chr(0xFFFD)]
] {
	for Newline in [false, true] {
		Test("Ollama stream UTF-8: " . Utf8Sample[1] . " with newline=" . Newline
			. " (ollama-stream-utf8-admission)",
			_OllamaStreamUtf8_EncodingBoundary.Bind(Utf8Sample[2], Utf8Sample[3], Newline))
	}
}


_OllamaStreamUtf8_PartialEof(Bytes, Expected, SplitAt) {
	Path := A_Temp . "\ergopti_stream_utf8_eof_" . A_TickCount . "_" . Random(1, 1000000)
	try {
		FileAppend('{"message":{"content":"', Path, "UTF-8-RAW")
		First := [], Rest := []
		for Index, Byte in Bytes {
			if Index <= SplitAt
				First.Push(Byte)
			else
				Rest.Push(Byte)
		}
		_TLAO_AppendRawBytes(Path, First)
		Cursor := Map("last_pos", 0)
		AssertEqual("", _LLM_Ollama_ReadStreamText(Path, Cursor),
			"temporary EOF inside a scalar must remain pending")
		AssertEqual(0, Cursor["last_pos"], "an unfinished JSONL record must retain its byte checkpoint")
		_TLAO_AppendRawBytes(Path, Rest)
		FileAppend('"},"done":true}' . "`n", Path, "UTF-8-RAW")
		AssertContains(_LLM_Ollama_ReadStreamText(Path, Cursor), Expected,
			"the next poll must decode the completed scalar exactly")
		AssertEqual(FileGetSize(Path), Cursor["last_pos"], "the complete record advances its cursor once")
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}

for Utf8Sample in [
	[[0xC3, 0xA9], Chr(0xE9)],
	[[0xE2, 0x82, 0xAC], Chr(0x20AC)],
	[[0xF0, 0x9F, 0x99, 0x82], Chr(0x1F642)]
] {
	loop Utf8Sample[1].Length - 1 {
		Test("Ollama stream UTF-8: pending " . Utf8Sample[1].Length . "-byte scalar at " . A_Index
			. " (ollama-stream-utf8-admission)",
			_OllamaStreamUtf8_PartialEof.Bind(Utf8Sample[1], Utf8Sample[2], A_Index))
	}
}
