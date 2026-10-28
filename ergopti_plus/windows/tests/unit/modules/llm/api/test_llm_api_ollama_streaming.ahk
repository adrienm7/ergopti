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
	_LLM_Ollama_Async[fake_id] := Map("requester_current", 0, "pid", 0, "tmp_payload", tmp_payload, "tmp_stdout", tmp_stdout,
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
	_LLM_Ollama_Async[fake_id] := Map("requester_current", 0, "pid", 0, "tmp_payload", tmp_payload, "tmp_stdout", tmp_stdout,
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
	_LLM_Ollama_Async[fake_id] := Map("requester_current", 0, "pid", 0, "process_owner", 0,
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

#Include %A_LineFile%/../test_llm_api_ollama_stream_utf8.ahk

#Include %A_LineFile%/../test_llm_api_ollama_stream_nul.ahk


; Reader cancellation fixtures retain a real completed native process too.
; Their supplied provider bytes remain independent from this exit-only child.
_OllamaStream_CompletedNativeOwner() {
	Owner := 0
	try {
		Pid := 0
		; cmd consumes a command expression after /C, not separately quoted argv.
		Command := _Q(A_ComSpec) . ' /D /C "exit /b 0"'
		_LLM_CurlArtifactRun(Command, "", "Hide", &Pid, &Owner)
		Start := A_TickCount
		while !_LLM_CurlProcessExited(Owner) && TickElapsed(Start) < 5000
			Sleep(10)
		AssertTrue(_LLM_CurlProcessExited(Owner), "the reader fixture child must acknowledge exit")
		ExitCode := 0
		Diagnostic := ""
		AssertTrue(_SR_TreeReadExitCode(Owner["handle"], &ExitCode, &Diagnostic),
			"the reader fixture keeps its actual native exit receipt")
		AssertEqual(0, ExitCode, "reader cancellation starts from a successful transport")
		return Owner
	} catch as Err {
		if Owner is Map
			_LLM_CurlReleaseProcess(Owner, true)
		throw Err
	}
}

; The live poll must fence the same real-reader return boundary as final flush.
; Only cancellation is injected: production reads/parses every JSONL byte.
_OllamaLivePoll_ReaderCancellation(CancelAtRead, Boundary := "read", FinalOnly := false) {
	global _LLM_Ollama_ActiveStreams, _LLM_Ollama_IsReady, _LLM_ManagedBootstrap
	SavedStreams := _LLM_Ollama_ActiveStreams
	SavedReady := _LLM_Ollama_IsReady
	SavedBootstrap := _LLM_ManagedBootstrap
	ObservedFn := Boundary == "parse" ? _LLM_Ollama_ParseStreamLine : _LLM_Ollama_ReadStreamText
	HadReadCall := ObservedFn.HasOwnProp("Call")
	SavedReadCall := HadReadCall ? ObservedFn.GetOwnPropDesc("Call") : 0
	State := Map("read_calls", 0, "partials", 0, "successes", 0, "failures", 0, "text", "")
	Path := A_Temp . "\ergopti_live_poll_cancel_" . A_TickCount . "_" . Random(1, 1000000)
	Handle := { Pid: 0, ProcessOwner: 0, Cancelled: false,
		TmpPayload: Path . ".json", TmpStdout: Path . ".out" }
	try {
		AssertFalse(HadReadCall, "the production reader starts with its genuine Call boundary")
		_LLM_ManagedBootstrap := 0
		_LLM_Ollama_IsReady := true
		Handle.ProcessOwner := _OllamaStream_CompletedNativeOwner()
		Handle.Pid := Handle.ProcessOwner["pid"]
		_LLM_Ollama_ActiveStreams := [Handle]
		FileAppend('{"message":{"content":"live answer"},"done":true}' . (FinalOnly ? "" : "`n"),
			Handle.TmpStdout, "UTF-8-RAW")
		ObservedFn.DefineProp("Call", {Call: ObserveRead})
		_LLM_Ollama_StreamPoll(Handle, Map("acc", "", "last_pos", 0),
			(Text) => (State["partials"] += 1, State["text"] := Text),
			(*) => State["successes"] += 1, (*) => State["failures"] += 1)
		AssertEqual(1, State["read_calls"], "the real production owner returned once through the injected boundary")
		AssertEqual(CancelAtRead ? 0 : 1, State["partials"], "a cancelled live read cannot deliver partial text")
		AssertEqual(CancelAtRead ? 0 : 1, State["successes"], "only the live positive control completes")
		AssertEqual(CancelAtRead ? 1 : 0, State["failures"], "cancellation settles exactly once")
		if !CancelAtRead
			AssertEqual("live answer", State["text"], "the control parses production JSONL")
		AssertFalse(FileExist(Handle.TmpStdout), "the settled poll removes its private response")
		AssertEqual(0, _LLM_Ollama_ActiveStreams.Length, "the poll relinquishes its exact stream handle")
	} finally {
		_LLM_CurlReleaseProcess(Handle.ProcessOwner, true)
		if ObservedFn.HasOwnProp("Call")
			ObservedFn.DeleteProp("Call")
		if HadReadCall
			ObservedFn.DefineProp("Call", SavedReadCall)
		if FileExist(Handle.TmpStdout)
			FileDelete(Handle.TmpStdout)
		_LLM_Ollama_ActiveStreams := SavedStreams
		_LLM_Ollama_IsReady := SavedReady
		_LLM_ManagedBootstrap := SavedBootstrap
	}
	ObserveRead(Self, Args*) {
		ObservedFn.DeleteProp("Call")
		Chunk := ObservedFn.Call(Args*)
		State["read_calls"] += 1
		if CancelAtRead
			LLM_OllamaCancelStream(Handle)
		return Chunk
	}
}
Test("Ollama live poll: read cancellation rejects partial delivery (ollama-live-read-cancellation)", _OllamaLivePoll_ReaderCancellation.Bind(true))
Test("Ollama live poll: unchanged read delivers real JSONL (ollama-live-read-cancellation)", _OllamaLivePoll_ReaderCancellation.Bind(false))


; A partial can launch the next request while retiring this one. Its final
; unterminated record must never publish or acquire the successor's cleanup.
_OllamaLivePoll_PartialCancellationKeepsSuccessor() {
	global _LLM_Ollama_ActiveStreams, _LLM_Ollama_IsReady, _LLM_ManagedBootstrap
	SavedStreams := _LLM_Ollama_ActiveStreams
	SavedReady := _LLM_Ollama_IsReady
	SavedBootstrap := _LLM_ManagedBootstrap
	Path := A_Temp . "\ergopti_live_partial_cancel_" . A_TickCount . "_" . Random(1, 1000000)
	Handle := { Pid: 0, ProcessOwner: 0, Cancelled: false,
		TmpPayload: Path . ".json", TmpStdout: Path . ".out" }
	Successor := { Pid: 0, ProcessOwner: 0, Cancelled: false,
		TmpPayload: Path . "_next.json", TmpStdout: Path . "_next.out" }
	State := Map("partials", 0, "successes", 0, "failures", 0)
	try {
		_LLM_ManagedBootstrap := 0
		_LLM_Ollama_IsReady := true
		Handle.ProcessOwner := _OllamaStream_CompletedNativeOwner()
		Handle.Pid := Handle.ProcessOwner["pid"]
		_LLM_Ollama_ActiveStreams := [Handle]
		FileAppend('{"message":{"content":"first"},"done":false}' . "`n"
			. '{"message":{"content":" stale final"},"done":true}', Handle.TmpStdout, "UTF-8-RAW")
		FileAppend("owned next payload", Successor.TmpPayload, "UTF-8-RAW")
		FileAppend("owned next response", Successor.TmpStdout, "UTF-8-RAW")
		_LLM_Ollama_StreamPoll(Handle, Map("acc", "", "last_pos", 0), Partial,
			(*) => State["successes"] += 1, (*) => State["failures"] += 1)
		AssertEqual(1, State["partials"], "the admitted first partial cannot be followed by stale final text")
		AssertEqual(0, State["successes"], "a partial cancellation cannot settle as successful")
		AssertEqual(1, State["failures"], "the canceled original is settled once")
		AssertFalse(FileExist(Handle.TmpStdout), "the old response is removed")
		AssertEqual(1, _LLM_Ollama_ActiveStreams.Length, "the successor keeps its registration")
		AssertTrue(_LLM_Ollama_ActiveStreams[1] == Successor, "cleanup retires the exact original handle")
		AssertEqual("owned next payload", FileRead(Successor.TmpPayload, "UTF-8-RAW"))
		AssertEqual("owned next response", FileRead(Successor.TmpStdout, "UTF-8-RAW"))
		AssertFalse(Successor.Cancelled, "the new request retains its own cancellation intent")
	} finally {
		_LLM_CurlReleaseProcess(Handle.ProcessOwner, true)
		for FilePath in [Handle.TmpPayload, Handle.TmpStdout, Successor.TmpPayload, Successor.TmpStdout]
			if FileExist(FilePath)
				FileDelete(FilePath)
		_LLM_Ollama_ActiveStreams := SavedStreams
		_LLM_Ollama_IsReady := SavedReady
		_LLM_ManagedBootstrap := SavedBootstrap
	}
	Partial(Text) {
		global _LLM_Ollama_ActiveStreams
		AssertEqual("first", Text, "the live poll reads only the completed first record")
		State["partials"] += 1
		LLM_OllamaCancelStream(Handle)
		_LLM_Ollama_ActiveStreams.Push(Successor)
	}
}
Test("Ollama live poll: partial cancellation preserves the successor (ollama-live-read-cancellation)", _OllamaLivePoll_PartialCancellationKeepsSuccessor)

Test("Ollama live poll: parser cancellation rejects partial delivery (ollama-live-parse-cancellation)", _OllamaLivePoll_ReaderCancellation.Bind(true, "parse"))
Test("Ollama final flush: parser cancellation rejects partial delivery (ollama-live-parse-cancellation)", _OllamaLivePoll_ReaderCancellation.Bind(true, "parse", true))


; Capability inspection reads a real executable before private-directory setup.
; Its yielding boundary must already own the cancellation handle for this request.
_OllamaStreaming_EarlyReservation(CancelAtGate, Boundary := "capability") {
	global _LLM_Ollama_ActiveStreams, _LLM_Ollama_IsReady, _LLM_ManagedBootstrap
	SavedStreams := _LLM_Ollama_ActiveStreams
	SavedReady := _LLM_Ollama_IsReady
	SavedBootstrap := _LLM_ManagedBootstrap
	GateFn := Boundary == "origin" ? LLM_OllamaCaptureOriginCustody : _HTTP_CurlRuntimeLimitSupported
	HadGateCall := GateFn.HasOwnProp("Call")
	SavedGateCall := HadGateCall ? GateFn.GetOwnPropDesc("Call") : 0
	Directory := A_Temp . "\ergopti_early_stream_" . A_TickCount . "_" . Random(1, 1000000)
	State := Map("gates", 0, "writes", 0, "runs", 0, "failures", 0, "bytes", 0)
	try {
		AssertFalse(HadGateCall, "the capability owner starts without a foreign observer")
		DirCreate(Directory)
		_LLM_ManagedBootstrap := 0
		_LLM_Ollama_IsReady := true
		_LLM_Ollama_ActiveStreams := []
		GateFn.DefineProp("Call", {Call: ObserveGate})
		Port := Map("temp_dir", (*) => Directory, "write", WritePayload,
			"run", _OllamaStreaming_RecordUnexpectedRun.Bind(State))
		Handle := LLM_OllamaGenerate_Streaming("fixture-model", "system", "private context", 0.2,
			(*) => 0, (*) => 0, (*) => State["failures"] += 1, "", "", false, "", Port)
		AssertEqual(1, State["gates"], "the genuine executable capability read must complete")
		AssertEqual(CancelAtGate ? 0 : 1, State["writes"], "early cancellation must fence sensitive payload staging")
		AssertEqual(0, State["runs"], "the fixture never starts a network child")
		AssertEqual(1, State["failures"], "the canceled or write-refused request settles once")
		AssertEqual(0, _LLM_Ollama_ActiveStreams.Length, "failed dispatch relinquishes its reservation")
		AssertEqual(CancelAtGate, Handle.Cancelled, "the returned handle retains the cancellation intent")
		if !CancelAtGate
			AssertTrue(State["bytes"] > 0, "the positive control exercised an actual UTF-8 payload file")
		Files := 0
		Loop Files Directory . "\*", "F"
			Files += 1
		AssertEqual(0, Files, "a refused dispatch leaves no private payload behind")
	} finally {
		if GateFn.HasOwnProp("Call")
			GateFn.DeleteProp("Call")
		if HadGateCall
			GateFn.DefineProp("Call", SavedGateCall)
		if DirExist(Directory)
			DirDelete(Directory, true)
		_LLM_Ollama_ActiveStreams := SavedStreams
		_LLM_Ollama_IsReady := SavedReady
		_LLM_ManagedBootstrap := SavedBootstrap
	}
	ObserveGate(Self, Args*) {
		GateFn.DeleteProp("Call")
		Supported := GateFn.Call(Args*)
		if Boundary == "capability"
			AssertTrue(Supported, "the fixture requires a genuinely supported Windows curl executable")
		else
			AssertTrue(HasMethod(Supported, "Call"), "the original origin admission produced its genuine custody receipt")
		State["gates"] += 1
		if CancelAtGate
			LLM_OllamaCancelStreams()
		return Supported
	}
	WritePayload(Path, Payload) {
		State["writes"] += 1
		AssertTrue(FSWrite(Path, Payload), "the control must write through the actual filesystem owner")
		State["bytes"] := FileGetSize(Path)
		; Refuse after the real write so the production refusal owner must clean
		; the actual payload; this probe must never send a request to a server.
		return false
	}
}
Test("Ollama stream: capability-read cancellation owns its reservation (ollama-stream-early-reservation)", _OllamaStreaming_EarlyReservation.Bind(true))
Test("Ollama stream: unchanged capability read reaches payload staging (ollama-stream-early-reservation)", _OllamaStreaming_EarlyReservation.Bind(false))
Test("Ollama stream: origin-read cancellation owns its reservation (ollama-stream-early-reservation)", _OllamaStreaming_EarlyReservation.Bind(true, "origin"))


; Moving reservation ahead of payload preparation must retain fail-fast errors
; without leaking this handle or replacing another stream's ownership.
_OllamaStreaming_PreparationFailureRetiresReservation() {
	global _LLM_Ollama_ActiveStreams, _LLM_Ollama_IsReady, _LLM_ManagedBootstrap
	SavedStreams := _LLM_Ollama_ActiveStreams
	SavedReady := _LLM_Ollama_IsReady
	SavedBootstrap := _LLM_ManagedBootstrap
	Other := { Pid: 0, ProcessOwner: 0, Cancelled: false, TmpPayload: "", TmpStdout: "" }
	Failure := 0
	Callbacks := 0
	try {
		_LLM_ManagedBootstrap := 0
		_LLM_Ollama_IsReady := true
		_LLM_Ollama_ActiveStreams := [Other]
		try LLM_OllamaGenerate_Streaming("fixture-model", "system", "context", Map(),
			(*) => 0, (*) => 0, (*) => Callbacks += 1)
		catch as Err
			Failure := Err
		AssertTrue(Failure is TypeError, "actual numeric payload formatting must retain its TypeError")
		AssertEqual(0, Callbacks, "a preparation exception remains fail-fast rather than a network verdict")
		AssertEqual(1, _LLM_Ollama_ActiveStreams.Length, "preparation failure retires only its new reservation")
		AssertTrue(_LLM_Ollama_ActiveStreams[1] == Other, "the existing stream keeps its original identity")
		AssertFalse(Other.Cancelled, "the existing stream's cancellation state is unchanged")
	} finally {
		_LLM_Ollama_ActiveStreams := SavedStreams
		_LLM_Ollama_IsReady := SavedReady
		_LLM_ManagedBootstrap := SavedBootstrap
	}
}
Test("Ollama stream: preparation failure retires its exact reservation (ollama-stream-early-reservation)", _OllamaStreaming_PreparationFailureRetiresReservation)


; A complete provider frame cannot overrule a failed native transport receipt.
_OllamaStream_NativeExitStatus(ExitCode, Queryable := true) {
	global _LLM_Ollama_ActiveStreams, _LLM_Ollama_IsReady, _LLM_ManagedBootstrap
	SavedStreams := _LLM_Ollama_ActiveStreams
	SavedReady := _LLM_Ollama_IsReady
	SavedBootstrap := _LLM_ManagedBootstrap
	Directory := A_Temp . "\ergopti_stream_exit_" . A_TickCount . "_" . Random(1, 1000000)
	Script := Directory . "\child.ahk"
	Owner := 0
	State := Map("partials", 0, "successes", 0, "failures", 0, "text", "")
	try {
		DirCreate(Directory)
		SplitPath(A_LineFile, , &TestDirectory)
		FixtureScript := TestDirectory . "\..\..\..\..\fixtures\ollama_stream_exit_child.ahk"
		AssertTrue(FileExist(FixtureScript), "the standalone native child source must exist")
		FileCopy(FixtureScript, Script)
		Output := Directory . "\response.jsonl"
		Command := _SR_BuildDirectCommandLine(A_AhkPath, ["/ErrorStdOut", Script, Output, String(ExitCode)])
		Pid := 0
		_LLM_CurlArtifactRun(Command, Directory, "Hide", &Pid, &Owner)
		AssertTrue(Owner is Map && Owner.Get("handle", 0) != 0,
			"the fixture retains the actual native child handle")
		Start := A_TickCount
		while !_LLM_CurlProcessExited(Owner) && TickElapsed(Start) < 5000
			Sleep(10)
		AssertTrue(_LLM_CurlProcessExited(Owner), "the native child exits within the fixture deadline")
		NativeExit := 0
		AssertTrue(DllCall("Kernel32\GetExitCodeProcess", "Ptr", Owner["handle"], "UInt*", &NativeExit, "Int"),
			"the native exit receipt is queryable before production retirement")
		AssertEqual(ExitCode, NativeExit, "the native child produced the requested transport exit status")
		AssertEqual('{"message":{"content":"native answer"},"done":true}' . "`n",
			FileRead(Output, "UTF-8-RAW"), "every exit mode emits identical complete provider bytes")
		if !Queryable {
			RestrictedHandle := 0
			CurrentProcess := DllCall("Kernel32\GetCurrentProcess", "Ptr")
			AssertTrue(DllCall("Kernel32\DuplicateHandle", "Ptr", CurrentProcess,
				"Ptr", Owner["handle"], "Ptr", CurrentProcess, "Ptr*", &RestrictedHandle,
				"UInt", 0x00100001, "Int", false, "UInt", 0, "Int"),
				"an exact duplicate preserves terminate/synchronize rights without query rights")
			CreatorHandle := Owner["handle"]
			Owner["handle"] := RestrictedHandle
			AssertTrue(DllCall("Kernel32\CloseHandle", "Ptr", CreatorHandle, "Int"),
				"the creator query handle is retired after exact-object custody transfer")
			QueryExit := 0
			QueryDiagnostic := ""
			AssertFalse(_SR_TreeReadExitCode(RestrictedHandle, &QueryExit, &QueryDiagnostic),
				"the real native query is refused when the exact handle lacks query rights")
			AssertTrue(QueryDiagnostic != "", "the failed query retains its native diagnostic")
		}
		Handle := {Pid: Pid, ProcessOwner: Owner, Cancelled: false,
			TmpPayload: Directory . "\payload.json", TmpStdout: Output}
		_LLM_ManagedBootstrap := 0
		_LLM_Ollama_IsReady := true
		_LLM_Ollama_ActiveStreams := [Handle]
		_LLM_Ollama_StreamPoll(Handle, Map("acc", "", "last_pos", 0),
			(Text) => (State["partials"] += 1, State["text"] := Text),
			(Text) => (State["successes"] += 1, State["text"] := Text), (*) => State["failures"] += 1)
		AssertEqual(ExitCode == 0 && Queryable ? 1 : 0, State["successes"],
			"a provider done frame succeeds only after a successful transport exit")
		AssertEqual(ExitCode == 0 && Queryable ? 0 : 1, State["failures"],
			"a nonzero native transport exit settles failure exactly once")
		if ExitCode == 0 && Queryable
			AssertEqual("native answer", State["text"], "the positive completion carries the actual parsed provider text")
		AssertTrue(Owner.Get("released", false), "the terminal child handle is acknowledged and released")
		AssertEqual(0, Owner.Get("handle", 0), "no native handle remains after terminal delivery")
		AssertFalse(FileExist(Output), "the terminal response is removed")
		AssertEqual(0, _LLM_Ollama_ActiveStreams.Length, "the exact stream registration is retired")
	} finally {
		if Owner is Map
			_LLM_CurlReleaseProcess(Owner, true)
		_LLM_Ollama_ActiveStreams := SavedStreams
		_LLM_Ollama_IsReady := SavedReady
		_LLM_ManagedBootstrap := SavedBootstrap
		if DirExist(Directory)
			DirDelete(Directory, true)
	}
}
Test("Ollama streaming: native transport exit zero allows done (ollama-native-stream-exit)", _OllamaStream_NativeExitStatus.Bind(0))
Test("Ollama streaming: truncated transfer exit rejects done (ollama-native-stream-exit)", _OllamaStream_NativeExitStatus.Bind(18))
Test("Ollama streaming: timeout exit rejects done (ollama-native-stream-exit)", _OllamaStream_NativeExitStatus.Bind(28))
Test("Ollama streaming: signaled exit 259 rejects done (ollama-native-stream-exit)", _OllamaStream_NativeExitStatus.Bind(259))
Test("Ollama streaming: unavailable native exit receipt fails closed (ollama-native-stream-exit)", _OllamaStream_NativeExitStatus.Bind(0, false))

; The provider's terminal marker is a JSON boolean, independent of AHK coercion.
_OllamaStream_DoneLiteral(SourceTail, ExpectedSuccess) {
	Source := '{"message":{"content":"typed answer"}' . SourceTail . '}'
	Parsed := _LLM_Ollama_ParseStreamLine(Source)
	State := Map("acc", "")
	Observed := Map("partials", 0)
	_LLM_Ollama_ConsumeStreamChunk(Source . "`n", State, (*) => Observed["partials"] += 1)
	Result := _LLM_Ollama_StreamTerminalResult(State)
	AssertEqual(ExpectedSuccess, Result["ok"],
		"only the last decoded JSON boolean true may authorize terminal completion")
	if ExpectedSuccess {
		AssertTrue(Parsed["ok"], "the literal-true control is parsed through the genuine envelope owner")
		AssertTrue(Parsed["done"], "the valid marker is actually admitted")
		AssertEqual("typed answer", Result["text"], "the completed provider text stays byte-exact")
		AssertEqual(1, Observed["partials"], "the valid control reaches the actual consumer callback")
	}
}
for _OllamaDoneVector in [
	["literal true", ',"done":true', true],
	["literal false", ',"done":false', false],
	["missing marker", '', false],
	["integer one", ',"done":1', false],
	["decimal one", ',"done":1.0', false],
	["exponent one", ',"done":1e0', false],
	["quoted one", ',"done":"1"', false],
	["quoted true", ',"done":"true"', false],
	["null marker", ',"done":null', false],
	["array marker", ',"done":[true]', false],
	["object marker", ',"done":{"value":true}', false],
	["last true duplicate", ',"done":"1","done":true', true],
	["last quoted duplicate", ',"done":true,"done":"1"', false],
	["escaped last true", ',"done":"1","d\u006fne":true', true],
	["escaped last quoted", ',"done":true,"d\u006fne":"1"', false]]
	Test("Ollama done marker: " . _OllamaDoneVector[1] . " keeps JSON type (ollama-stream-done-kind)",
		_OllamaStream_DoneLiteral.Bind(_OllamaDoneVector[2], _OllamaDoneVector[3]))

; curl creates its stdout file after CreateProcessW returns; absence is pending,
; whereas a sharing refusal remains a genuine I/O failure.
_OllamaStream_InitialOutput(Mode) {
	Directory := A_Temp . "\ergopti_stream_start_" . A_TickCount . "_" . Random(1, 1000000)
	Path := Directory . (Mode == "missing-parent" ? "\absent\response.jsonl" : "\response.jsonl")
	Lock := 0
	try {
		DirCreate(Directory)
		if Mode == "empty" || Mode == "locked"
			FileAppend("", Path, "UTF-8-RAW")
		if Mode == "locked" {
			Lock := DllCall("Kernel32\CreateFileW", "Str", Path, "UInt", 0x80000000,
				"UInt", 0, "Ptr", 0, "UInt", 3, "UInt", 0x80, "Ptr", 0, "Ptr")
			AssertTrue(Lock != -1 && Lock != 0, "the real exclusive fixture handle must be owned")
		}
		NativeError := 0
		try {
			NativeFile := FileOpen(Path, "r")
			NativeFile.Close()
		} catch OSError as Err
			NativeError := Err.Number
		AssertEqual(Mode == "missing" ? 2 : Mode == "missing-parent" ? 3 : Mode == "locked" ? 32 : 0, NativeError,
			"the genuine Windows open must establish the requested file-state prerequisite")
		State := Map("last_pos", 0, "stream_bytes_pending", true)
		ReadError := 0, Chunk := "unexpected"
		try Chunk := _LLM_Ollama_ReadStreamText(Path, State)
		catch OSError as Err
			ReadError := Err.Number
		AssertEqual(Mode == "locked" ? 32 : Mode == "missing-parent" ? 3 : 0, ReadError,
			"a not-yet-created curl output remains pending while a sharing refusal stays visible")
		if Mode == "missing" || Mode == "empty" {
			AssertEqual("", Chunk, "pending and empty output deliver zero provider bytes")
			AssertEqual(0, State["last_pos"], "pending output never advances the stream cursor")
			AssertFalse(State["stream_bytes_pending"], "the next tick receives no stale drain claim")
		}
	} finally {
		if Lock && Lock != -1
			DllCall("Kernel32\CloseHandle", "Ptr", Lock)
		if DirExist(Directory)
			DirDelete(Directory, true)
	}
}
for _OllamaStartMode in ["missing", "empty", "locked", "missing-parent"]
	Test("Ollama initial output: " . _OllamaStartMode . " preserves file state (ollama-stream-initial-output)",
		_OllamaStream_InitialOutput.Bind(_OllamaStartMode))

; Keep the fixture's successful native child independent from provider bytes.
_OllamaStream_CompletedNativeOwnerControl() {
	Owner := _OllamaStream_CompletedNativeOwner()
	try {
		AssertTrue(Owner is Map && Owner.Get("handle", 0) != 0,
			"the exit-only control retains the actual completed process handle")
		AssertEqual(0, DllCall("Kernel32\WaitForSingleObject", "Ptr", Owner["handle"], "UInt", 0, "UInt"),
			"native acknowledgement independently confirms the fixture process completed")
		AssertTrue(_LLM_CurlReleaseProcess(Owner), "the completed native owner releases normally")
		AssertTrue(Owner.Get("released", false), "the real release acknowledgement is retained")
		AssertEqual(0, Owner.Get("handle", 0), "the exact completed handle is retired")
	} finally _LLM_CurlReleaseProcess(Owner, true)
}
Test("Ollama live fixture: completed native owner starts from exit zero (ollama-live-native-owner)",
	_OllamaStream_CompletedNativeOwnerControl)
