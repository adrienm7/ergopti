; tests/meta/test_stream_handle_type.ahk

; ==============================================================================
; MODULE: Stream Handle Type Meta Test
; DESCRIPTION:
; Static source guard for the T-W02 regression:
; "_LLM_Ollama_RemoveStreamHandle uses IsObject/HasOwnProp, not 'is Map'".
;
; Stream handles returned by LLM_OllamaGenerate_Streaming are plain object
; literals ({ Pid, Cancelled, TmpPayload, TmpStdout }), not Map instances.
; The old implementation tested ``handle is Map``, which always evaluates to
; false for object literals — _LLM_Ollama_RemoveStreamHandle became a permanent
; no-op and _LLM_Ollama_ActiveStreams grew without bound across streaming calls.
;
; The fix replaces the ``is Map`` guard with ``IsObject`` + ``HasOwnProp("Pid")``
; and filters entries by Pid equality. This meta-static test scans api_ollama.ahk
; so a regression that reintroduces ``is Map`` fails the suite immediately.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Source scan helpers =======
; ======================================
; ======================================

_SHT_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}





; ==================================================
; ==================================================
; ======= 2/ IsObject / HasOwnProp assertion =======
; ==================================================
; ==================================================

_SHT_AssertHandleTypeCheck() {
	Src := _SHT_ReadSource("modules/llm/api_ollama.ahk")
	Body := _DriverFuncBody("_LLM_Ollama_RemoveStreamHandle")
	Assert(Body != "", "_LLM_Ollama_RemoveStreamHandle declaration must exist in api_ollama.ahk")

	; Regression guard: the old broken check used ``is Map`` on an object literal,
	; which always evaluates to false — the function was permanently a no-op
	Assert(!InStr(Body, "is Map"),
		"_LLM_Ollama_RemoveStreamHandle must NOT use 'is Map' — stream handles are object literals, not Map instances (T-W02)")

	; The correct guard must use IsObject to tolerate both object literals and Maps
	Assert(InStr(Body, "IsObject") > 0,
		"_LLM_Ollama_RemoveStreamHandle must use IsObject() to validate the handle (T-W02)")

	; HasOwnProp ensures the object actually carries a Pid before we dereference it
	Assert(InStr(Body, "HasOwnProp") > 0,
		"_LLM_Ollama_RemoveStreamHandle must use HasOwnProp() to check for the Pid property (T-W02)")
}
Test("api_ollama: _LLM_Ollama_RemoveStreamHandle uses IsObject/HasOwnProp, not 'is Map' (T-W02)", _SHT_AssertHandleTypeCheck)





; ==============================================================
; ==============================================================
; ======= 3/ Object-reference filtering assertion ==============
; ==============================================================
; ==============================================================

_SHT_AssertObjectReferenceComparison() {
	Src := _SHT_ReadSource("modules/llm/api_ollama.ahk")
	Body := _DriverFuncBody("_LLM_Ollama_RemoveStreamHandle")
	Assert(Body != "", "_LLM_Ollama_RemoveStreamHandle declaration must exist in api_ollama.ahk")

	; The correct fix compares by OBJECT REFERENCE (h != handle), not by Pid.
	; Windows reuses PIDs of short-lived processes; a PID collision would silently
	; remove the wrong still-active handle from the registry (T-W02 fix).
	Assert(InStr(Body, "h != handle") > 0,
		"_LLM_Ollama_RemoveStreamHandle must filter by object reference (h != handle), not by PID (T-W02)")
}
Test("api_ollama: _LLM_Ollama_RemoveStreamHandle filters by object reference, not PID (T-W02)", _SHT_AssertObjectReferenceComparison)
