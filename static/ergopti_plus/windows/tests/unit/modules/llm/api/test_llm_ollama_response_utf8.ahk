; tests/unit/modules/llm/api/test_llm_ollama_response_utf8.ahk

; ==============================================================================
; MODULE: Ollama Terminal Response Byte Controls
; DESCRIPTION:
; Consume native terminal files through the real generation poll and JSON parser.
; Process handles are passive ports; no curl, network or native exit is claimed.
; ==============================================================================

_OUR_Bytes(Values) {
	Bytes := Buffer(Values.Length)
	for Index, Value in Values
		NumPut("UChar", Value, Bytes, Index - 1)
	return Bytes
}

_OUR_Hex(Bytes) {
	Text := ""
	Loop Bytes.Size
		Text .= Format("{:02X}", NumGet(Bytes, A_Index - 1, "UChar"))
	return Text
}

_OUR_Units(Text) {
	Units := ""
	Loop StrLen(Text)
		Units .= Format("{:04X}", Ord(SubStr(Text, A_Index, 1)))
	return Units
}

_OUR_Directory() {
	global DriverPid
	static Sequence := 0
	Loop 16 {
		Sequence += 1
		Path := A_Temp . "\ergopti_ollama_response_" . DriverPid . "_" . A_TickCount . "_" . Sequence
		if DllCall("Kernel32\CreateDirectoryW", "Str", Path, "Ptr", 0, "Int")
			return Path
		if A_LastError != 183
			throw OSError(A_LastError, "The private terminal directory could not be created.")
	}
	throw Error("No exclusive private terminal directory was available.")
}

_OUR_Write(Path, Pieces, OwnedPaths) {
	Handle := DllCall("Kernel32\CreateFileW", "Str", Path, "UInt", 0x40000000, "UInt", 1,
		"Ptr", 0, "UInt", 1, "UInt", 0x80, "Ptr", 0, "Ptr")
	if Handle == -1
		throw OSError(A_LastError, "The terminal artifact must be created exclusively.")
	OwnedPaths.Push(Path)
	Failure := 0
	try {
		for Piece in Pieces {
			if Piece is String {
				Bytes := Buffer(StrPut(Piece, "UTF-8"))
				Count := StrPut(Piece, Bytes, "UTF-8") - 1
			} else {
				Bytes := Piece
				Count := Bytes.Size
			}
			Written := 0
			if !DllCall("Kernel32\WriteFile", "Ptr", Handle, "Ptr", Bytes.Ptr, "UInt", Count,
				"UInt*", &Written, "Ptr", 0, "Int")
				throw OSError(A_LastError, "The native terminal write failed.")
			AssertEqual(Count, Written, "every original terminal byte must be written")
		}
		if !DllCall("Kernel32\FlushFileBuffers", "Ptr", Handle, "Int")
			throw OSError(A_LastError, "The native terminal write was not durable.")
	} catch as Err {
		Failure := Err
	} finally {
		if !DllCall("Kernel32\CloseHandle", "Ptr", Handle, "Int") && !IsObject(Failure)
			Failure := OSError(A_LastError, "The private terminal handle did not close.")
	}
	if IsObject(Failure)
		throw Failure
}

_OUR_Read(State, StatusPath, ExitPath, BodyPath) {
	State["reads"] += 1
	Terminal := _LLM_CurlReadTerminal(StatusPath, ExitPath, BodyPath)
	State["terminal"] := Terminal
	State["body_units"] := _OUR_Units(Terminal["body"])
	return Terminal
}

_OUR_Close(State, Handle) {
	AssertEqual(State["handle"], Handle, "logical release must retain this exact passive handle")
	State["closes"] += 1
	return true
}

_OUR_Terminate(State, Handle) {
	AssertEqual(State["handle"], Handle, "cleanup must never substitute another passive handle")
	State["terminations"] += 1
	return true
}

_OUR_Wait(State, Handle) {
	AssertEqual(State["handle"], Handle, "a passive wait must retain this exact logical handle")
	State["waits"] += 1
	return 0
}

_OUR_Success(State, Text) {
	State["successes"] += 1
	State["text"] := Text
}

_OUR_Failure(State, *) {
	State["failures"] += 1
}

_OUR_OwnsPath(Paths, Candidate) {
	for Path in Paths
		if Candidate == Path
			return true
	return false
}

_OUR_Retired(ProcessOwner, State, Paths) {
	global _LLM_CurlCleanupDebt
	AssertTrue(ProcessOwner["released"], "the exact logical process owner must retire")
	AssertEqual(0, ProcessOwner["handle"], "a released logical owner must retain no handle")
	AssertFalse(ProcessOwner["releasing"], "the release transaction must be complete")
	AssertEqual(0, ProcessOwner["cleanup_debt_id"], "this exact owner must retain no process debt")
	AssertEqual(1, State["closes"], "a complete terminal receipt must close its logical owner once")
	AssertEqual(0, State["terminations"], "a complete terminal receipt must not request termination")
	AssertEqual(0, State["waits"], "a complete terminal receipt must not enter a wait fallback")
	for Path in Paths
		AssertFalse(FileExist(Path), "the real generation cleanup must remove every private artifact")
	for DebtId, Record in _LLM_CurlCleanupDebt {
		if Record.Get("kind", "paths") == "process"
			AssertFalse(Record["owner"] == ProcessOwner, "no debt may retain this exact logical owner")
		else if Record.Has("paths")
			for Path in Record["paths"]
				AssertFalse(_OUR_OwnsPath(Paths, Path), "no cleanup debt may retain these exact private paths")
	}
}

_OUR_Case(Mode) {
	global _LLM_Ollama_Async, _LLM_Ollama_Pending, _LLM_Ollama_ActiveStreams
	global _LLM_Ollama_IsReady, _LLM_ManagedBootstrap, LLM_OLLAMA_BASE_URL
	global _LLM_CurlCleanupDebt, _LLM_CurlCleanupRetryTimer
	PreviousCritical := Critical("On")
	Saved := Map("registry", _LLM_Ollama_Async, "pending", _LLM_Ollama_Pending,
		"streams", _LLM_Ollama_ActiveStreams, "ready", _LLM_Ollama_IsReady,
		"bootstrap", _LLM_ManagedBootstrap, "origin", LLM_OLLAMA_BASE_URL,
		"retry_timer", _LLM_CurlCleanupRetryTimer)
	_LLM_Ollama_Async := Map()
	_LLM_Ollama_Pending := ""
	_LLM_Ollama_ActiveStreams := []
	_LLM_Ollama_IsReady := true
	_LLM_ManagedBootstrap := 0
	LLM_OLLAMA_BASE_URL := "http://127.0.0.1:1"
	State := Map("handle", 9361, "reads", 0, "closes", 0, "terminations", 0,
		"successes", 0, "failures", 0, "text", "", "body_units", "", "waits", 0)
	OwnedPaths := []
	Directory := ""
	ProcessOwner := 0
	Primary := 0
	CleanupFailure := 0
	ReqId := "ollama_response_utf8_" . Mode
	Port := Map("open_process", (*) => State["handle"],
		"close_process", _OUR_Close.Bind(State), "terminate_process", _OUR_Terminate.Bind(State),
		"wait_process", _OUR_Wait.Bind(State), "read_terminal", _OUR_Read.Bind(State))
	try {
		AssertFalse(A_IsSuspended, "the native decoding witness requires ordinary active admission")
		AssertFalse(Saved["registry"].Has(ReqId), "the private request must not alias a parked owner")
		Directory := _OUR_Directory()
		Paths := [Directory . "\payload.json", Directory . "\body.out",
			Directory . "\body.status", Directory . "\body.exit"]
		Scalar := Mode == "invalid" ? _OUR_Bytes([0xC3, 0x28])
			: Mode == "replacement" ? _OUR_Bytes([0xEF, 0xBF, 0xBD])
			: _OUR_Bytes([0xC3, 0x89, 0x74, 0x75, 0x64, 0x65, 0x20, 0xF0, 0x9F, 0x98, 0x80])
		Expected := Mode == "replacement" ? "x" . Chr(0xFFFD) . "y" : "xÉtude 😀y"
		_OUR_Write(Paths[1], ['{"model":"fixture"}'], OwnedPaths)
		_OUR_Write(Paths[2], ['{"message":{"content":"x', Scalar, 'y"}}'], OwnedPaths)
		_OUR_Write(Paths[3], ["200`r`n"], OwnedPaths)
		; The real curl command commits its exit sidecar after the body and status.
		_OUR_Write(Paths[4], ["0`r`n"], OwnedPaths)
		RawHex := _OUR_Hex(FileRead(Paths[2], "RAW"))
		ExpectedHex := "7B226D657373616765223A7B22636F6E74656E74223A2278" . _OUR_Hex(Scalar) . "79227D7D"
		AssertEqual(ExpectedHex, RawHex, "the decoder must receive the exact original native bytes")
		AssertEqual("3230300D0A", _OUR_Hex(FileRead(Paths[3], "RAW")), "the real status sidecar must retain its bytes")
		AssertEqual("300D0A", _OUR_Hex(FileRead(Paths[4], "RAW")), "the exit commit must retain its CRLF bytes")
		Custody := LLM_OllamaCaptureOriginCustody()
		Origin := Custody.Call("origin")
		ProcessOwner := _LLM_CurlAdoptProcess(4247, Port)
		Entry := Map("pid", 4247, "process_owner", ProcessOwner, "cancelled", false,
			"tmp_payload", Paths[1], "tmp_stdout", Paths[2], "tmp_status", Paths[3], "tmp_exit", Paths[4],
			"start_tick", A_TickCount, "timeout_ms", 20000, "payload_snip", "fixture", "redact", true,
			"base_url", Origin, "origin_custody", Custody, "origin_owned", Custody.Call("owned"),
			"presence_generation", LLM_AuxGeneration(),
			"on_success", LLM_OllamaInvokeOriginCurrent.Bind(Custody, Origin, _OUR_Success.Bind(State), "on_success"),
			"on_fail", LLM_OllamaInvokeOriginCurrent.Bind(Custody, Origin, _OUR_Failure.Bind(State), "on_fail"))
		_LLM_Ollama_Async[ReqId] := Entry
		AssertTrue(_LLM_Ollama_PresenceStillCurrent(Entry), "the real origin custody must admit this exact generation")
		_LLM_Ollama_PollCurl(ReqId, Port)
		Terminal := State["terminal"]
		Invalid := Mode == "invalid"
		FileAppend("RECEIPT ollama-nonstream-response-utf8 mode=" . Mode . " raw=" . RawHex
			. " complete=" . Terminal["complete"] . " exit=" . Terminal["exit"] . " status=" . Terminal["status"]
			. " body_read=" . Terminal["body_read"] . " oversize=" . Terminal["oversize"]
			. " reads=" . State["reads"] . " body_units=" . State["body_units"]
			. " success=" . State["successes"] . " failure=" . State["failures"] . " text_units=" . _OUR_Units(State["text"])
			. " closes=" . State["closes"] . " terminations=" . State["terminations"] . " waits=" . State["waits"]
			. " slot=" . _LLM_Ollama_Async.Has(ReqId) . "`n", "*")
		AssertEqual(1, State["reads"], "the actual generation poll must consume one complete terminal receipt")
		AssertTrue(Terminal["complete"] && Terminal["exit"] == 0 && Terminal["status"] == 200
			&& !Terminal["oversize"], "the native terminal commit and successful HTTP status must qualify this witness")
		if !Invalid
			AssertTrue(Terminal["body_read"], "valid terminal bytes must remain readable through the real decoder")
		AssertFalse(_LLM_Ollama_Async.Has(ReqId), "the exact generation reservation must retire")
		_OUR_Retired(ProcessOwner, State, Paths)
		AssertEqual(Invalid ? 0 : 1, State["successes"], "invalid terminal bytes must not become a successful Ollama prediction")
		AssertEqual(Invalid ? 1 : 0, State["failures"], "only invalid UTF8 must reject this otherwise valid terminal body")
		if !Invalid
			AssertEqual(Expected, State["text"], "valid multibyte scalars and genuine U+FFFD must retain their exact prediction text")
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			if _LLM_Ollama_Async.Has(ReqId) && IsSet(Entry) && _LLM_Ollama_Async[ReqId] == Entry
				_LLM_Ollama_Async.Delete(ReqId)
			if ProcessOwner is Map {
				AssertTrue(_LLM_CurlReleaseProcess(ProcessOwner, true, Port), "cleanup must retire only the fixture's logical handle")
				AssertEqual(0, ProcessOwner["cleanup_debt_id"], "cleanup must not leave this exact logical process debt")
			}
			for Path in OwnedPaths
				if FileExist(Path)
					FileDelete(Path)
			for DebtId, Record in _LLM_CurlCleanupDebt.Clone() {
				OwnedDebt := Record.Get("kind", "paths") == "process"
					? Record["owner"] == ProcessOwner : false
				if Record.Has("paths") && Record["paths"].Length > 0 {
					OwnedDebt := true
					for Path in Record["paths"]
						if !_OUR_OwnsPath(OwnedPaths, Path)
							OwnedDebt := false
				}
				if OwnedDebt
					AssertTrue(_LLM_CurlRetryCleanupRecord(DebtId, Record), "only the exact private cleanup debt may be retried")
			}
			if Directory != "" {
				DirDelete(Directory)
				AssertFalse(DirExist(Directory), "the acknowledged private directory must be retired")
			}
		} catch as Failure {
			CleanupFailure := Failure
		} finally {
			try {
				if _LLM_CurlCleanupRetryTimer != Saved["retry_timer"] {
					if IsObject(_LLM_CurlCleanupRetryTimer)
						SetTimer(_LLM_CurlCleanupRetryTimer, 0)
					_LLM_CurlCleanupRetryTimer := Saved["retry_timer"]
				}
			} catch as Failure {
				if !IsObject(CleanupFailure)
					CleanupFailure := Failure
			} finally {
				_LLM_Ollama_Async := Saved["registry"]
				_LLM_Ollama_Pending := Saved["pending"]
				_LLM_Ollama_ActiveStreams := Saved["streams"]
				_LLM_Ollama_IsReady := Saved["ready"]
				_LLM_ManagedBootstrap := Saved["bootstrap"]
				LLM_OLLAMA_BASE_URL := Saved["origin"]
				Critical(PreviousCritical)
			}
		}
	}
	if IsObject(Primary) {
		if IsObject(CleanupFailure)
			try FileAppend("CLEANUP ollama-nonstream-response-utf8: " . CleanupFailure.Message . "`n", "*")
		throw Primary
	}
	if IsObject(CleanupFailure)
		throw CleanupFailure
}

for Mode in ["invalid", "valid", "replacement"]
	Test("Ollama terminal response: " . Mode . " preserves JSON encoding (ollama-nonstream-response-utf8)", _OUR_Case.Bind(Mode))
