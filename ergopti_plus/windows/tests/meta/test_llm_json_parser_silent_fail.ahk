; tests/meta/test_llm_json_parser_silent_fail.ahk

; ==============================================================================
; MODULE: LLM JSON Parser Silent Fail Meta Test
; DESCRIPTION:
; Static source guard for the "llm-json-parser-silent-fail" finding.
; ==============================================================================

#Requires AutoHotkey v2.0

_TLJ_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_TLJ_Check() {
	; Move-resilient: the Ollama JSON response parser used to live directly in
	; modules/llm/api_ollama.ahk, but that file is now a thin #Include redirect
	; shim to api_ollama/ollama_payload.ahk (post-split). Scanning the function
	; body by name across the whole driver survives further file moves.
	Body := _DriverFuncBody("LLM_ParseOllamaChatResponse")
	Assert(Body != "", "LLM_ParseOllamaChatResponse must exist in the Ollama API module")
	Assert(InStr(Body, 'Map("error", true') > 0, "LLM_ParseOllamaChatResponse must return a structured error map on parse failure")
	Assert(InStr(Body, "SubStr(") > 0, "LLM_ParseOllamaChatResponse must log the raw response payload")

	Src2 := _TLJ_ReadSource("modules/llm/models.ahk")
	Assert(Src2 != "", "Source file models.ahk must exist")
	Assert(InStr(Src2, "SubStr(") > 0, "models.ahk must log the raw response payload")
}

Test("LLM JSON parsers: log raw payload and return structured error", _TLJ_Check)

; Behavioral regression: _LLM_OllamaParseAsyncBody must forward the structured
; error Map to on_fail (not treat it as the empty-prediction "parse miss" case,
; and never hand the raw Map to on_success as if it were prediction text).
_TLJ_AsyncBodyForwardsParseErrorToOnFail() {
	SuccessCalls := []
	FailArgs     := []
	on_success := (text) => SuccessCalls.Push(text)
	on_fail    := (err := "") => FailArgs.Push(err)

	_LLM_OllamaParseAsyncBody("{not valid json", on_success, on_fail)

	AssertEqual(0, SuccessCalls.Length, "on_success must never fire on a JSON parse failure")
	AssertEqual(1, FailArgs.Length, "on_fail must fire exactly once on a JSON parse failure")
	Err := FailArgs[1]
	AssertTrue((Err is Map) and Err.Has("error") and Err["error"], "on_fail must receive the structured error Map, not an empty string")
}
Test("ollama_streaming: _LLM_OllamaParseAsyncBody forwards a parse-error Map to on_fail",
	_TLJ_AsyncBodyForwardsParseErrorToOnFail)
