; tests/unit/platform/network/test_managed_response_utf8.ahk

; ==============================================================================
; MODULE: Managed Response Byte Decoding Controls
; DESCRIPTION:
; Exercise native response files through the real managed facade and remote
; JSON consumer. The process boundary is controlled; no network wire is claimed.
; ==============================================================================

_MRU_Bytes(Values) {
	Bytes := Buffer(Values.Length)
	for Index, Value in Values
		NumPut("UChar", Value, Bytes, Index - 1)
	return Bytes
}

_MRU_Write(Path, Pieces) {
	File := FileOpen(Path, "w", "UTF-8-RAW")
	if !IsObject(File)
		throw Error("The private response file could not be opened.")
	try {
		for Piece in Pieces {
			if Piece is String {
				Bytes := Buffer(StrPut(Piece, "UTF-8"))
				Count := StrPut(Piece, Bytes, "UTF-8") - 1
			} else {
				Bytes := Piece
				Count := Bytes.Size
			}
			AssertEqual(Count, File.RawWrite(Bytes, Count), "the private body must contain every original byte")
		}
	} finally File.Close()
}

_MRU_ByteHex(Bytes) {
	Text := ""
	Loop Bytes.Size
		Text .= Format("{:02X}", NumGet(Bytes, A_Index - 1, "UChar"))
	return Text
}

_MRU_WriteOpaque(Path, Bytes, State) {
	Handle := DllCall("Kernel32\CreateFileW", "Str", Path, "UInt", 0x40000000, "UInt", 1,
		"Ptr", 0, "UInt", 1, "UInt", 0x80, "Ptr", 0, "Ptr")
	if Handle == -1
		throw OSError(A_LastError, "The private binary output must be created exclusively.")
	State["opaque_owned"] := true
	try {
		Written := 0
		if !DllCall("Kernel32\WriteFile", "Ptr", Handle, "Ptr", Bytes.Ptr, "UInt", Bytes.Size,
			"UInt*", &Written, "Ptr", 0, "Int")
			throw OSError(A_LastError, "The private binary output write failed.")
		AssertEqual(Bytes.Size, Written, "exclusive binary output must retain every original byte")
	} finally {
		if !DllCall("Kernel32\CloseHandle", "Ptr", Handle, "Int")
			throw OSError(A_LastError, "The private binary output handle did not close.")
	}
}

_MRU_UnitHex(Text) {
	Units := ""
	Loop StrLen(Text)
		Units .= Format("{:04X}", Ord(SubStr(Text, A_Index, 1)))
	return Units
}

_MRU_Factory(State) {
	return State["request"]
}

_MRU_Success(State, Text, Usage) {
	State["successes"] += 1
	State["text"] := Text
}

_MRU_Failure(State, Info) {
	State["failures"] += 1
	State["reason"] := Info["reason"]
}

_MRU_Case(Mode) {
	global _LLM_Remote_Async, _HTTP_CURL_CLEANUP_DEBTS, _HTTP_CURL_ABORT_DEBTS
	PreviousCritical := Critical("On")
	SavedRegistry := _LLM_Remote_Async
	_LLM_Remote_Async := Map()
	State := _ManagedCurlControlState()
	State["successes"] := 0
	State["failures"] := 0
	State["text"] := ""
	State["reason"] := ""
	State["opaque_owned"] := false
	OutputPath := ""
	Primary := 0
	CleanupFailure := 0
	try {
		Request := _ManagedCurlControlNew(State)
		Settings := (*) => Map("auto_detect", false, "pac_url", "", "proxy", "", "bypass", "")
		Remote := InStr(Mode, "remote-") == 1
		ReqId := "managed_response_utf8_" . Mode
		AssertFalse(SavedRegistry.Has(ReqId), "the private poll ID must not alias a parked request")
		if Remote {
			Resolved := Map("Format", "openai", "Token", "fixture-token", "Model", "fixture")
			Entry := _LLMRemote_ReserveRequest(ReqId, _MRU_Success.Bind(State), _MRU_Failure.Bind(State),
				20000, A_TickCount, Resolved)
			Port := Map("managed_settings", Settings, "create_http", _MRU_Factory.Bind(State))
			AssertTrue(_LLMRemote_DispatchManagedCurl(ReqId, Entry, Resolved,
				"https://safe.invalid/api", '{"model":"fixture"}', Port), "the real managed JSON caller must dispatch")
			AssertTrue(Entry["http"] == Request, "the real reservation must retain the actual facade")
		} else {
			Request.SetManagedRouting(Settings)
			if Mode == "opaque-binary" {
				OutputPath := Request.BodyPath . ".opaque"
				AssertFalse(FileExist(OutputPath), "the caller-owned binary path must begin absent")
				Request.SetOutputFile(OutputPath)
			}
			AssertTrue(Request.Send("fixture-body"), "the generic facade must dispatch through its existing API")
		}
		AssertEqual(1, State["spawns"], "only the external process launch is controlled")
		AssertTrue(IsObject(Request.ManagedAdmissionFn), "the request must own the actual admission callback")
		SetTimer(Request.ManagedAdmissionFn, 0)
		_ManagedCurlControlAck(State)
		Request._PollManagedAdmission()
		AssertTrue(Request.ManagedPayloadPublished, "the exact real admission must publish its transport input")
		Status := Mode == "empty-204" ? 204 : 200
		ContentType := Mode == "utf16-bom" ? "text/plain;charset=utf-16" : "application/json"
		Header := "HTTP/1.1 " . Status . " OK`r`nContent-Type: " . ContentType . "`r`n`r`n"
		_MRU_Write(Request.HeaderPath, [Header])
		Expected := ""
		if Remote {
			Prefix := '{"choices":[{"message":{"content":"'
			Suffix := '"}}]}'
			if Mode == "remote-invalid" {
				Pieces := [Prefix . "x", _MRU_Bytes([0xC3, 0x28]), "y" . Suffix]
			} else if Mode == "remote-replacement" {
				Pieces := [Prefix . "x", _MRU_Bytes([0xEF, 0xBF, 0xBD]), "y" . Suffix]
				Expected := "x" . Chr(0xFFFD) . "y"
			} else {
				Expected := "Étude 😀"
				Pieces := [Prefix . Expected . Suffix]
			}
		} else if Mode == "opaque-binary"
			Pieces := [_MRU_Bytes([0, 0xFF, 0xD8, 0xC3, 0x28, 0])]
		else if Mode == "utf16-bom" {
			Pieces := [_MRU_Bytes([0xFF, 0xFE, 0x71, 0, 0x72, 0])]
			Expected := "qr"
		} else if Mode == "generic-invalid" {
			Pieces := [_MRU_Bytes([0x78, 0xC3, 0x28, 0x79])]
			Expected := "x" . Chr(0xFFFD) . "(y"
		} else
			Pieces := []
		BodyPath := OutputPath != "" ? OutputPath : Request.BodyPath
		if Mode == "opaque-binary"
			_MRU_WriteOpaque(BodyPath, Pieces[1], State)
		else
			_MRU_Write(BodyPath, Pieces)
		OriginalHex := _MRU_ByteHex(FileRead(BodyPath, "RAW"))
		State["callback"].Call(0, '{"schema_version":1,"ok":true,"status":' . Status
			. ',"child_quiesced":true,"receipt":{}}', "")
		AssertTrue(Request.Completed, "the real managed terminal must settle the facade")
		if Remote
			_LLMRemote_PollRequest(ReqId)
		FileAppend("RECEIPT managed-response-utf8 mode=" . Mode . " raw=" . OriginalHex
			. " status=" . Request.Status . " body_units=" . _MRU_UnitHex(Request.ResponseText)
			. " success=" . State["successes"] . " failure=" . State["failures"]
			. " text_units=" . _MRU_UnitHex(State["text"]) . " reason=" . State["reason"] . "`n", "*")
		if Remote {
			AssertFalse(_LLM_Remote_Async.Has(ReqId), "the real consumer must retire its exact terminal reservation")
			Invalid := Mode == "remote-invalid"
			AssertEqual(Invalid ? 0 : 1, State["successes"], "malformed response bytes must never become successful JSON text")
			AssertEqual(Invalid ? 1 : 0, State["failures"], "only invalid response encoding must reject the completion")
			if !Invalid
				AssertEqual(Expected, State["text"], "valid scalar text and genuine U+FFFD must reach the real success callback unchanged")
		} else {
			AssertEqual(Status, Request.Status, "generic completion keeps its existing HTTP status")
			if Mode == "opaque-binary" {
				AssertTrue(FileExist(OutputPath), "facade cleanup must preserve the caller-owned binary path")
				AssertEqual("00FFD8C32800", _MRU_ByteHex(FileRead(OutputPath, "RAW")), "opaque output must preserve every byte")
				AssertEqual("", Request.ResponseText, "binary output must bypass text materialization")
			} else
				AssertEqual(Expected, Request.ResponseText, "generic empty, BOM and legacy String behavior must remain intact")
		}
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			try {
				_ManagedCurlControlRelease(State)
				if IsSet(Request) {
					AssertFalse(IsObject(Request.Handle), "the exact completed request must release its controlled handle")
					AssertFalse(IsObject(Request.ManagedCapture), "the exact private capture must be retired")
					AssertFalse(Request.CleanupPending, "the exact request must not leave silent file cleanup debt")
					AssertFalse(_HTTP_CURL_CLEANUP_DEBTS.Has(Request.CleanupDebtId), "only this request's cleanup debt must be absent")
					AssertFalse(_HTTP_CURL_ABORT_DEBTS.Has(Request.CleanupDebtId), "only this request's abort debt must be absent")
					for Path in [Request.BodyPath, Request.HeaderPath]
						AssertFalse(FileExist(Path), "every private request artifact must be retired")
				}
				if State.Has("directory")
					AssertFalse(DirExist(State["directory"]), "the private managed capture directory must be removed")
			} finally {
				if State["opaque_owned"] && FileExist(OutputPath)
					FileDelete(OutputPath)
			}
		} catch as Failure {
			CleanupFailure := Failure
		} finally {
			_LLM_Remote_Async := SavedRegistry
			Critical(PreviousCritical)
		}
	}
	if IsObject(Primary)
		throw Primary
	if IsObject(CleanupFailure)
		throw CleanupFailure
}

for Mode in ["remote-invalid", "remote-valid", "remote-replacement", "generic-invalid", "utf16-bom", "opaque-binary", "empty-204"]
	Test("managed response bytes: " . Mode . " preserves its encoding contract (managed-response-utf8)", _MRU_Case.Bind(Mode))
