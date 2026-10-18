; tests/unit/modules/llm/api/test_llm_api_ollama_streaming.ahk

; ==============================================================================
; MODULE: Ollama Spawn and Streaming
; DESCRIPTION:
; _LLM_Ollama_DoSpawn and the streaming generation skip their payload and
; curl launch once cancelled or suspended, the stream parser keeps typed
; verdicts and provider errors, the growing-file reader preserves split
; UTF-8, and stream ids stay unique.
; ==============================================================================

#Requires AutoHotkey v2.0





_OllamaDoSpawn_SkipsWhenCancelled() {
	global _LLM_Ollama_Async
	fake_id := 99930
	tmp_payload := A_Temp . "\ergopti_test_dospawn_cancel_" . fake_id . ".json"
	tmp_stdout := A_Temp . "\ergopti_test_dospawn_cancel_" . fake_id . ".out"
	try FSDelete(tmp_payload)
	failed := 0
	job := Map("on_success", (*) => 0, "on_fail", (*) => failed += 1)
	_LLM_Ollama_Async[fake_id] := Map("pid", 0, "tmp_payload", tmp_payload, "tmp_stdout", tmp_stdout,
		"on_success", job["on_success"], "on_fail", job["on_fail"], "cancelled", true,
		"start_tick", A_TickCount, "timeout_ms", 5000, "payload_snip", "")
	_LLM_Ollama_DoSpawn(fake_id, '{"model":"m"}', tmp_payload, tmp_stdout, job)
	AssertFalse(FileExist(tmp_payload) != "", "a cancelled deferred spawn must never write the PII payload file to disk")
	AssertFalse(_LLM_Ollama_Async.Has(fake_id), "the cancelled entry must be removed from the registry")
	AssertEqual(1, failed, "on_fail must fire exactly once for a spawn skipped due to cancellation")
	try FSDelete(tmp_payload)
}
Test("_LLM_Ollama_DoSpawn: skips writing payload + launching curl when cancelled before dispatch (F23)", _OllamaDoSpawn_SkipsWhenCancelled)


; F23: the deferred spawn must also never fire once the driver is suspended,
; even though no cancel was issued (the two menu/engine paths that call
; LLM_OllamaCancelAllAsync on suspend are a separate safety net — this guard
; is the last line of defence inside the spawn itself).
_OllamaDoSpawn_SkipsWhenSuspended() {
	global _LLM_Ollama_Async
	fake_id := 99931
	tmp_payload := A_Temp . "\ergopti_test_dospawn_susp_" . fake_id . ".json"
	tmp_stdout := A_Temp . "\ergopti_test_dospawn_susp_" . fake_id . ".out"
	try FSDelete(tmp_payload)
	failed := 0
	job := Map("on_success", (*) => 0, "on_fail", (*) => failed += 1)
	_LLM_Ollama_Async[fake_id] := Map("pid", 0, "tmp_payload", tmp_payload, "tmp_stdout", tmp_stdout,
		"on_success", job["on_success"], "on_fail", job["on_fail"], "cancelled", false,
		"start_tick", A_TickCount, "timeout_ms", 5000, "payload_snip", "")
	Suspend(1)
	try {
		_LLM_Ollama_DoSpawn(fake_id, '{"model":"m"}', tmp_payload, tmp_stdout, job)
	} finally {
		Suspend(0)
	}
	AssertFalse(FileExist(tmp_payload) != "", "a deferred spawn firing after Suspend must never write the PII payload file to disk")
	AssertEqual(1, failed, "on_fail must fire exactly once for a spawn skipped due to suspend")
	try FSDelete(tmp_payload)
}
Test("_LLM_Ollama_DoSpawn: skips writing payload + launching curl when driver is suspended (F23)", _OllamaDoSpawn_SkipsWhenSuspended)


; F23: an entry that vanished before the tick fired (e.g. TrimAsyncRegistry
; already evicted it and fired on_fail) must be a silent no-op — calling
; on_fail again here would violate the "exactly once" async contract.
_OllamaDoSpawn_MissingEntryIsSilentNoOp() {
	global _LLM_Ollama_Async
	fake_id := 99932
	if _LLM_Ollama_Async.Has(fake_id)  ; ensure absent — Map.Delete() throws on a missing key
		_LLM_Ollama_Async.Delete(fake_id)
	failed := 0
	job := Map("on_success", (*) => 0, "on_fail", (*) => failed += 1)
	tmp_payload := A_Temp . "\ergopti_test_dospawn_missing_" . fake_id . ".json"
	_LLM_Ollama_DoSpawn(fake_id, '{"model":"m"}', tmp_payload, tmp_payload, job)
	AssertEqual(0, failed, "a spawn tick for an already-evicted entry must not re-fire on_fail")
	try FSDelete(tmp_payload)
}
Test("_LLM_Ollama_DoSpawn: missing registry entry is a silent no-op, not a second on_fail (F23)", _OllamaDoSpawn_MissingEntryIsSilentNoOp)


_OllamaDoSpawn_CancelDuringWrite(State, Path, Payload) {
	State["writes"] += 1
	LLM_OllamaCancelAllAsync()
	return true
}

_OllamaDoSpawn_RecordUnexpectedRun(State, Command, WorkingDir, Options, &Pid, &ProcessOwner) {
	State["runs"] += 1
	Pid := 99933
	ProcessOwner := Map("pid", Pid, "handle", 99933, "released", false)
}

_OllamaDoSpawn_CancelledWhileWriting() {
	global _LLM_Ollama_ActiveStreams, _LLM_Ollama_Async, _LLM_Ollama_Pending
	fake_id := 99933
	State := Map("writes", 0, "runs", 0, "polls", 0, "deletes", 0, "failed", 0)
	Port := Map(
		"write", _OllamaDoSpawn_CancelDuringWrite.Bind(State),
		"delete", (Path) => (State["deletes"] += 1, true),
		"run", _OllamaDoSpawn_RecordUnexpectedRun.Bind(State),
		"poll", (ReqId) => State["polls"] += 1)
	_LLM_Ollama_Async := Map()
	_LLM_Ollama_ActiveStreams := []
	_LLM_Ollama_Pending := ""
	job := Map("on_success", (*) => 0, "on_fail", (*) => State["failed"] += 1)
	_LLM_Ollama_Async[fake_id] := Map("pid", 0, "process_owner", 0,
		"tmp_payload", "write-race.json", "tmp_stdout", "write-race.out",
		"tmp_status", "write-race.status", "tmp_exit", "write-race.exit",
		"on_success", job["on_success"], "on_fail", job["on_fail"], "cancelled", false,
		"start_tick", A_TickCount, "timeout_ms", 5000, "payload_snip", "")
	try {
		_LLM_Ollama_DoSpawn(fake_id, '{"model":"m"}', "write-race.json",
			"write-race.out", job, Port)
		AssertEqual(1, State["writes"], "the payload write seam must run once")
		AssertEqual(0, State["runs"], "cancellation during payload write must prevent the curl launch")
		AssertEqual(0, State["polls"], "a cancelled pre-launch request must not arm a poll")
		AssertFalse(_LLM_Ollama_Async.Has(fake_id), "the cancelled request must be retired before launch")
		AssertEqual(1, State["failed"], "cancellation during payload write must fail exactly once")
	} finally {
		_LLM_Ollama_Async := Map()
		_LLM_Ollama_ActiveStreams := []
		_LLM_Ollama_Pending := ""
	}
}
Test("_LLM_Ollama_DoSpawn: cancellation during payload write prevents curl launch (AHK-153)", _OllamaDoSpawn_CancelledWhileWriting)


_OllamaStreaming_CancelDuringTempDir(State) {
	State["temp_dirs"] += 1
	LLM_OllamaCancelStreams()
	return A_Temp
}

_OllamaStreaming_CancelledWhileOpeningTempDir() {
	global _LLM_Ollama_ActiveStreams
	State := Map("temp_dirs", 0, "writes", 0, "runs", 0, "failed", 0)
	Port := Map(
		"temp_dir", _OllamaStreaming_CancelDuringTempDir.Bind(State),
		"write", (Path, Payload) => (State["writes"] += 1, true),
		"run", _OllamaStreaming_RecordUnexpectedRun.Bind(State))
	_LLM_Ollama_ActiveStreams := []
	try {
		handle := LLM_OllamaGenerate_Streaming("m", "s", "private text", 0.1,
			(*) => 0, (*) => 0, (*) => State["failed"] += 1,
			"", "", false, "", Port)
		AssertTrue(handle.Cancelled, "cancelling during private-directory setup must mark the pre-launch stream handle")
		AssertEqual(1, State["temp_dirs"], "the private-directory seam must run once")
		AssertEqual(0, State["writes"], "cancellation during private-directory setup must prevent the payload write")
		AssertEqual(0, State["runs"], "cancellation during private-directory setup must prevent the curl launch")
		AssertEqual(1, State["failed"], "the cancelled pre-write stream must fail exactly once")
		AssertEqual(0, _LLM_Ollama_ActiveStreams.Length, "a cancelled pre-write stream must leave no active handle")
	} finally {
		_LLM_Ollama_ActiveStreams := []
	}
}
Test("LLM_OllamaGenerate_Streaming: cancellation during private-directory setup prevents payload write (AHK-153)", _OllamaStreaming_CancelledWhileOpeningTempDir)


_OllamaStreaming_CancelDuringWrite(State, Path, Payload) {
	State["writes"] += 1
	LLM_OllamaCancelStreams()
	return true
}

_OllamaStreaming_RecordUnexpectedRun(State, Command, WorkingDir, Options, &Pid, &ProcessOwner) {
	State["runs"] += 1
	Pid := 99934
	ProcessOwner := Map("pid", Pid, "handle", 99934, "released", false)
}

_OllamaStreaming_CancelledWhileWriting() {
	global _LLM_Ollama_ActiveStreams
	State := Map("writes", 0, "runs", 0, "failed", 0)
	Port := Map(
		"temp_dir", (*) => A_Temp,
		"write", _OllamaStreaming_CancelDuringWrite.Bind(State),
		"run", _OllamaStreaming_RecordUnexpectedRun.Bind(State))
	_LLM_Ollama_ActiveStreams := []
	try {
		handle := LLM_OllamaGenerate_Streaming("m", "s", "private text", 0.1,
			(*) => 0, (*) => 0, (*) => State["failed"] += 1,
			"", "", false, "", Port)
		AssertTrue(handle.Cancelled, "cancelling during a payload write must mark the pre-launch stream handle")
		AssertEqual(1, State["writes"], "the streaming payload write seam must run once")
		AssertEqual(0, State["runs"], "a cancelled streaming payload write must not launch curl")
		AssertEqual(1, State["failed"], "the cancelled streaming request must fail exactly once")
		AssertEqual(0, _LLM_Ollama_ActiveStreams.Length, "a cancelled pre-launch stream must leave no active handle")
	} finally {
		_LLM_Ollama_ActiveStreams := []
	}
}
Test("LLM_OllamaGenerate_Streaming: cancellation during payload write prevents curl launch (AHK-153)", _OllamaStreaming_CancelledWhileWriting)


_OllamaStreamErrorOverridesPartialText() {
	Partials := []
	State := Map("acc", "", "last_pos", 0)
	_LLM_Ollama_ConsumeStreamChunk(
		'{"message":{"content":"partial"},"done":false}' . "`n",
		State, (Text) => Partials.Push(Text))
	_LLM_Ollama_ConsumeStreamChunk(
		'{"error":"model runner stopped"}' . "`n",
		State, (Text) => Partials.Push(Text))
	Result := _LLM_Ollama_StreamTerminalResult(State)
	AssertFalse(Result["ok"],
		"a provider error must remain terminal even after valid partial text")
	AssertContains(Result["error"], "model runner stopped")
	AssertEqual("partial", State["acc"],
		"diagnostics may retain accepted partial text without promoting it to success")
	CompletedState := Map("acc", "", "last_pos", 0)
	_LLM_Ollama_ConsumeStreamChunk(
		'{"message":{"content":"complete"},"done":true}' . "`n",
		CompletedState, (*) => 0)
	Completed := _LLM_Ollama_StreamTerminalResult(CompletedState)
	AssertTrue(Completed["ok"], "a canonical done envelope must still complete")
	AssertEqual("complete", Completed["text"])
}
Test("Ollama stream: provider error overrides accumulated text (AHK-072)",
	_OllamaStreamErrorOverridesPartialText)

_OllamaStreamParserReturnsTypedVerdicts() {
	EmptyToken := _LLM_Ollama_ParseStreamLine(
		'{"message":{"content":""},"done":true}')
	AssertTrue(EmptyToken["ok"], "an empty final token is a valid stream envelope")
	AssertTrue(EmptyToken["done"])
	AssertEqual("", EmptyToken["token"])
	Malformed := _LLM_Ollama_ParseStreamLine("{not json")
	AssertFalse(Malformed["ok"], "malformed JSON must not collapse into an empty token")
	Assert(Malformed["error"] != "", "malformed JSON needs a durable failure reason")
}
Test("Ollama stream: parser distinguishes empty tokens from failures (AHK-072)",
	_OllamaStreamParserReturnsTypedVerdicts)

_TLAO_AppendRawBytes(Path, Bytes) {
	Payload := Buffer(Bytes.Length)
	for Index, Byte in Bytes
		NumPut("UChar", Byte, Payload, Index - 1)
	Handle := DllCall("Kernel32\CreateFileW", "Str", Path,
		"UInt", 0x40000000, "UInt", 0x3, "Ptr", 0, "UInt", 4,
		"UInt", 0x80, "Ptr", 0, "Ptr")
	Assert(Handle != -1, "test fixture must open its growing stream")
	try {
		EndPos := 0
		Assert(DllCall("Kernel32\SetFilePointerEx", "Ptr", Handle,
			"Int64", 0, "Int64*", &EndPos, "UInt", 2, "Int"),
			"test fixture must seek to the growing stream tail")
		Written := 0
		Assert(DllCall("Kernel32\WriteFile", "Ptr", Handle, "Ptr", Payload,
			"UInt", Payload.Size, "UInt*", &Written, "Ptr", 0, "Int"),
			"test fixture must write its raw byte fragment")
		AssertEqual(Bytes.Length, Written,
			"test fixture must publish every requested raw byte")
	} finally {
		DllCall("Kernel32\CloseHandle", "Ptr", Handle)
	}
}

_OllamaStreamReaderPreservesSplitUtf8() {
	Cases := [
		Map("bytes", [0xC3, 0xA9], "text", Chr(0xE9)),
		Map("bytes", [0xE2, 0x82, 0xAC], "text", Chr(0x20AC)),
		Map("bytes", [0xF0, 0x9F, 0x99, 0x82], "text", Chr(0x1F642))
	]
	for CaseIndex, CaseData in Cases {
		loop CaseData["bytes"].Length - 1 {
			SplitAt := A_Index
			Path := A_Temp . "\ergopti_ollama_utf8_split_" . A_TickCount
				. "_" . CaseIndex . "_" . SplitAt . ".bin"
			try {
				First := []
				Rest := []
				for Index, Byte in CaseData["bytes"] {
					if Index <= SplitAt
						First.Push(Byte)
					else
						Rest.Push(Byte)
				}
				_TLAO_AppendRawBytes(Path, First)
				State := Map("last_pos", 0)
				AssertEqual("", _LLM_Ollama_ReadStreamText(Path, State),
					"a poll must retain an incomplete UTF-8 code point")
				AssertEqual(0, State["last_pos"],
					"an incomplete code point must not advance the byte cursor")
				Rest.Push(0x0A)
				_TLAO_AppendRawBytes(Path, Rest)
				AssertEqual(CaseData["text"] . "`n",
					_LLM_Ollama_ReadStreamText(Path, State),
					"the next poll must reconstruct the exact UTF-8 code point")
				AssertEqual(CaseData["bytes"].Length + 1, State["last_pos"],
					"the cursor must advance only through complete newline records")
			} finally {
				try FileDelete(Path)
			}
		}
	}
}

Test("Ollama stream: growing-file reader preserves split UTF-8 code points (AHK-081)",
	_OllamaStreamReaderPreservesSplitUtf8)

_OllamaStreamReaderBoundsUnterminatedRecords() {
	Path := A_Temp . "\ergopti_ollama_record_limit_" . A_TickCount . ".txt"
	try {
		FileAppend("123456789", Path, "UTF-8-RAW")
		State := Map("last_pos", 0)
		Failure := ""
		try _LLM_Ollama_ReadStreamText(Path, State, false, 8)
		catch as Err
			Failure := Err.Message
		AssertContains(Failure, "record exceeds 8 bytes",
			"a non-delimited record at the read ceiling must fail instead of being re-read forever")
		AssertEqual(0, State["last_pos"],
			"a rejected oversized record must not advance the JSONL checkpoint")

		FileDelete(Path)
		FileAppend("a`nb`nc`nd`ne`n", Path, "UTF-8-RAW")
		State := Map("last_pos", 0)
		AssertEqual("a`nb`nc`nd`n", _LLM_Ollama_ReadStreamText(Path, State, true, 8),
			"the terminal reader must drain only one bounded group of complete records")
		AssertTrue(State["stream_bytes_pending"],
			"the terminal reader must advertise records left for its next deferred slice")
		AssertEqual("e`n", _LLM_Ollama_ReadStreamText(Path, State, true, 8),
			"the next bounded terminal slice must preserve the remaining record")
		AssertFalse(State["stream_bytes_pending"],
			"the pending marker must clear only once the terminal tail is exhausted")
	} finally {
		try FileDelete(Path)
	}
}
Test("Ollama stream: reader bounds malformed records and terminal slices (AHK-156)",
	_OllamaStreamReaderBoundsUnterminatedRecords)




; ===================================================
; ===================================================
; ======= 6/ Stream UID helper =======================
; ===================================================
; ===================================================

_OllamaStreamUid_IsUnique() {
	uid1 := _LLM_Ollama_NextStreamUid()
	uid2 := _LLM_Ollama_NextStreamUid()
	AssertFalse(uid1 == uid2, "consecutive UIDs must differ")
}
Test("_LLM_Ollama_NextStreamUid: consecutive calls return distinct values", _OllamaStreamUid_IsUnique)


_OllamaStreamUid_IsNonEmpty() {
	uid := _LLM_Ollama_NextStreamUid()
	Assert(StrLen(uid) > 0, "UID must be non-empty")
}
Test("_LLM_Ollama_NextStreamUid: returns non-empty string", _OllamaStreamUid_IsNonEmpty)

#Include %A_LineFile%/../test_llm_api_ollama_final_flush.ahk
