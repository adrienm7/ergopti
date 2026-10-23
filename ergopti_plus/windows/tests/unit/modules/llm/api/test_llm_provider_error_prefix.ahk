; tests/unit/modules/llm/api/test_llm_provider_error_prefix.ahk

; ==============================================================================
; MODULE: Provider Error Prefix Boundary Tests
; DESCRIPTION:
; Provider error explanations are bounded to 200 UTF-16 code units before they
; reach the user's error message and the log. SubStr counts code units, so a
; supplementary character (an emoji, many CJK extensions) straddling unit 200
; was cut in half and left a lone high surrogate in the message. Every bounded
; provider explanation must keep whole characters within the same budget and
; keep shorter and boundary-aligned text unchanged.
; ==============================================================================

#Requires AutoHotkey v2.0

; 199 ASCII units, then a supplementary character occupying units 200 and 201.
_LPEP_Straddling() {
	Prefix := ""
	loop 199
		Prefix .= "a"
	return Map("prefix", Prefix, "text", Prefix . Chr(0x1F600) . "tail")
}

_LPEP_HasLoneSurrogate(Text) {
	Units := StrLen(Text)
	loop Units {
		Unit := NumGet(StrPtr(Text), (A_Index - 1) * 2, "UShort")
		if Unit >= 0xD800 && Unit <= 0xDBFF {
			Next := A_Index < Units ? NumGet(StrPtr(Text), A_Index * 2, "UShort") : 0
			if Next < 0xDC00 || Next > 0xDFFF
				return true
		} else if Unit >= 0xDC00 && Unit <= 0xDFFF {
			Previous := A_Index > 1 ? NumGet(StrPtr(Text), (A_Index - 2) * 2, "UShort") : 0
			if Previous < 0xD800 || Previous > 0xDBFF
				return true
		}
	}
	return false
}

_LPEP_ExpectWholePrefix(Label, Message, Expected) {
	AssertFalse(_LPEP_HasLoneSurrogate(Message), Label . ": the bounded explanation must not split a surrogate pair")
	AssertEqual(Expected, Message, Label . ": the bounded explanation keeps the longest whole-character prefix")
}

_LPEP_RemoteServerMessage() {
	Sample := _LPEP_Straddling()
	Body := '{"error":{"message":' . JsonStringLiteral(Sample["text"]) . '}}'
	Result := _LLMRemoteClassifyResponse("openai", Body)
	_LPEP_ExpectWholePrefix("remote provider", Result["server_message"], Sample["prefix"] . "...")
	Short := _LLMRemoteClassifyResponse("openai", '{"error":{"message":"short ' . Chr(0x1F600) . '"}}')
	AssertEqual("short " . Chr(0x1F600), Short["server_message"], "a short explanation stays unchanged")
	Aligned := Sample["prefix"] . "b"
	loop 5
		Aligned .= "c"
	Exact := _LLMRemoteClassifyResponse("openai", '{"error":{"message":' . JsonStringLiteral(Aligned) . '}}')
	AssertEqual(Sample["prefix"] . "b...", Exact["server_message"], "a boundary-aligned explanation keeps all 200 units")
}
Test("provider error prefix: remote server message keeps whole characters (provider-error-prefix)",
	_LPEP_RemoteServerMessage)

_LPEP_OllamaChatError() {
	Sample := _LPEP_Straddling()
	Result := LLM_ParseOllamaChatResponse('{"error":' . JsonStringLiteral(Sample["text"]) . '}')
	AssertTrue(Result is Map && Result.Get("error", false), "an Ollama error reply must be reported as an error")
	_LPEP_ExpectWholePrefix("Ollama chat", Result["message"], "Ollama error: " . Sample["prefix"])
}
Test("provider error prefix: Ollama chat error keeps whole characters (provider-error-prefix)",
	_LPEP_OllamaChatError)

_LPEP_OllamaStreamError() {
	Sample := _LPEP_Straddling()
	Result := _LLM_Ollama_ParseStreamLine('{"error":' . JsonStringLiteral(Sample["text"]) . '}')
	_LPEP_ExpectWholePrefix("Ollama stream", Result["error"], "Ollama stream error: " . Sample["prefix"])
}
Test("provider error prefix: Ollama stream error keeps whole characters (provider-error-prefix)",
	_LPEP_OllamaStreamError)

_LPEP_OllamaStreamFailHint() {
	Sample := _LPEP_Straddling()
	; The hint quotes the raw reply, so the error marker leads the 200 units.
	Raw := '{"error":"' . SubStr(Sample["prefix"], 11) . Chr(0x1F600) . 'tail"}'
	Path := A_Temp . "\ergopti_provider_prefix_" . DllCall("GetCurrentProcessId") . "_" . A_TickCount . ".out"
	FileAppend(Raw, Path, "UTF-8-RAW")
	try Hint := _LLM_Ollama_StreamFailHint(Path)
	finally FileDelete(Path)
	_LPEP_ExpectWholePrefix("Ollama stream hint", Hint, "Ollama error: " . SubStr(Raw, 1, 199))
}
Test("provider error prefix: Ollama stream failure hint keeps whole characters (provider-error-prefix)",
	_LPEP_OllamaStreamFailHint)
