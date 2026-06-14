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
	Src1 := _TLJ_ReadSource("modules/llm/api_ollama.ahk")
	Assert(Src1 != "", "Source file api_ollama.ahk must exist")
	Assert(InStr(Src1, 'Map("error", true') > 0, "api_ollama.ahk must return a structured error map on parse failure")
	Assert(InStr(Src1, "SubStr(") > 0, "api_ollama.ahk must log the raw response payload")

	Src2 := _TLJ_ReadSource("modules/llm/models.ahk")
	Assert(Src2 != "", "Source file models.ahk must exist")
	Assert(InStr(Src2, "SubStr(") > 0, "models.ahk must log the raw response payload")
}

Test("LLM JSON parsers: log raw payload and return structured error", _TLJ_Check)
