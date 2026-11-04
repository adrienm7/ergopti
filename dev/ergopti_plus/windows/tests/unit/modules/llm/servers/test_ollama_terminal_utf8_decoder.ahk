; tests/unit/modules/llm/servers/test_ollama_terminal_utf8_decoder.ahk

; ==============================================================================
; MODULE: Ollama Terminal Decoder Native File Controls
; DESCRIPTION:
; Qualify BOM, embedded NUL, empty DELETE and native byte bounds separately from
; the frozen generation witness. Only the size observation is controlled.
; ==============================================================================

_OTUD_Read(State, Path, Options := "") {
	Value := FileRead(Path, Options)
	if Path == State["body_path"] {
		State["body_reads"] += 1
		State["raw_size"] := Value is Buffer ? Value.Size : -1
	}
	return Value
}

_OTUD_Case(Mode) {
	Directory := ""
	OwnedPaths := []
	Primary := 0
	CleanupFailure := 0
	try {
		; The existing witness owns the checked native file helpers, not a parser.
		Directory := _OUR_Directory()
		BodyPath := Directory . "\decoder.body"
		StatusPath := Directory . "\decoder.status"
		ExitPath := Directory . "\decoder.exit"
		Payload := '{"message":{"content":"Étude 😀"}}'
		Status := Mode == "empty-delete" ? 204 : 200
		Expected := Payload
		ExpectedUnits := ""
		if Mode == "bom"
			Pieces := [_OUR_Bytes([0xEF, 0xBB, 0xBF]), Payload]
		else if Mode == "nul" {
			Tail := '{"second":true}'
			Expected := Payload . Chr(0) . Tail
			ExpectedUnits := _OUR_Units(Payload) . "0000" . _OUR_Units(Tail)
			Pieces := [Payload, _OUR_Bytes([0]), Tail]
		} else if Mode == "empty-delete" {
			Expected := ""
			Pieces := []
		} else if Mode == "utf16-bom"
			Pieces := [_OUR_Bytes([0xFF, 0xFE, 0x7B, 0, 0x7D, 0])]
		else {
			Expected := Mode == "limit-exact" ? "null" : "null    "
			Pieces := [Expected]
		}
		_OUR_Write(BodyPath, Pieces, OwnedPaths)
		_OUR_Write(StatusPath, [String(Status) . "`r`n"], OwnedPaths)
		_OUR_Write(ExitPath, ["0`r`n"], OwnedPaths)
		RawHex := _OUR_Hex(FileRead(BodyPath, "RAW"))
		State := Map("body_path", BodyPath, "body_reads", 0, "raw_size", -1)
		if Mode == "limit-drift"
			Terminal := _LLM_CurlReadTerminal(StatusPath, ExitPath, BodyPath, 4,
				_OTUD_Read.Bind(State), (*) => 4)
		else
			Terminal := _LLM_CurlReadTerminal(StatusPath, ExitPath, BodyPath, Mode == "limit-exact" ? 4 : 0)
		FileAppend("RECEIPT ollama-terminal-decoder mode=" . Mode . " raw=" . RawHex
			. " complete=" . Terminal["complete"] . " exit=" . Terminal["exit"] . " status=" . Terminal["status"]
			. " body_read=" . Terminal["body_read"] . " oversize=" . Terminal["oversize"]
			. " body_units=" . _OUR_Units(Terminal["body"]) . " observed_read_bytes=" . State["raw_size"]
			. " body_reads=" . State["body_reads"] . "`n", "*")
		AssertTrue(Terminal["complete"], "the real exit sidecar must commit the terminal receipt")
		AssertEqual(0, Terminal["exit"], "decoding must preserve the native terminal exit receipt")
		AssertEqual(Status, Terminal["status"], "decoding must preserve the HTTP status receipt")
		if Mode == "limit-drift" {
			AssertEqual(8, StrLen(RawHex) // 2, "the actual file must exceed the controlled size observation")
			AssertEqual(1, State["body_reads"], "the terminal must read the real native body once")
			AssertEqual(5, State["raw_size"], "the native allocation must stop at one byte beyond the four-byte bound")
			AssertTrue(Terminal["oversize"], "the actual byte image must override the stale size observation")
			AssertFalse(Terminal["body_read"], "an oversized image must never become response text")
		} else if Mode == "utf16-bom" {
			AssertEqual("FFFE7B007D00", RawHex, "the non-UTF8 JSON vector must retain its native bytes")
			AssertFalse(Terminal["body_read"], "a JSON terminal reader must refuse UTF16 instead of inferring a charset")
			AssertEqual("", Terminal["body"], "refused encoding must not publish repaired or fallback text")
		} else {
			AssertTrue(Terminal["body_read"], "valid UTF8 and empty DELETE bodies must remain readable")
			AssertFalse(Terminal["oversize"], "valid admitted bytes must remain within the body bound")
			AssertEqual(ExpectedUnits != "" ? ExpectedUnits : _OUR_Units(Expected), _OUR_Units(Terminal["body"]), "the decoder must preserve the entire independent scalar span")
			if Mode == "nul" {
				AssertEqual(StrLen(Payload) + 1 + StrLen(Tail), StrLen(Terminal["body"]), "NUL must not hide the bytes after it")
				AssertThrows(() => JsonParse(Terminal["body"]), "the real JSON parser must reject the retained NUL and trailing root")
			} else if Mode == "empty-delete"
				AssertTrue(_LLM_OllamaDeleteTerminalOk(Terminal["exit"], Terminal["status"],
					Terminal["body_read"], Terminal["body"]), "the existing DELETE classifier must admit its empty success")
			else if Mode == "bom" {
				AssertEqual("EFBBBF", SubStr(RawHex, 1, 6), "the native file must actually begin with a UTF8 BOM")
				AssertEqual("Étude 😀", LLM_ParseOllamaChatResponse(Terminal["body"]), "the real chat parser must consume the BOM-free multibyte body")
			} else
				AssertEqual("6E756C6C", RawHex, "an exact-bound valid body must retain all four original bytes")
		}
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			for Path in OwnedPaths {
				if FileExist(Path)
					FileDelete(Path)
				AssertFalse(FileExist(Path), "the exact owned decoder artifact must retire")
			}
			if Directory != "" {
				DirDelete(Directory)
				AssertFalse(DirExist(Directory), "the acknowledged private decoder directory must retire")
			}
		} catch as Failure {
			CleanupFailure := Failure
		}
	}
	if IsObject(Primary) {
		if IsObject(CleanupFailure)
			try FileAppend("CLEANUP ollama-terminal-decoder: " . CleanupFailure.Message . "`n", "*")
		throw Primary
	}
	if IsObject(CleanupFailure)
		throw CleanupFailure
}

for Mode in ["bom", "nul", "empty-delete", "utf16-bom", "limit-exact", "limit-drift"]
	Test("Ollama terminal decoder: " . Mode . " preserves its byte contract (ollama-terminal-decoder)", _OTUD_Case.Bind(Mode))
