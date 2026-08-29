; tests/unit/test_ollama_curl_temp_pii_plaintext.ahk

; ==============================================================================
; MODULE: Ollama Curl Temp PII Plaintext Regression Test
; DESCRIPTION:
; Regression test for the ollama-curl-temp-pii-plaintext finding.
;
; The Ollama curl dispatch writes the user's typed context (potential PII) to a
; plaintext temp file (curl --data-binary @file). Writing it to the bare,
; shared %TEMP% root exposes it to any sibling process / clipboard manager /
; sync agent watching that directory. The fix routes every payload + stdout
; file through _LLM_Ollama_TempDir() -- a per-instance subdirectory keyed on the
; current PID plus an instance nonce under %TEMP% -- so the file no longer lands
; in the shared root or aliases a predecessor after PID reuse.
;
; This file combines:
;   - a behavioral test that calls _LLM_Ollama_TempDir() (it is #Included by
;     run_all.ahk via api_ollama.ahk and only creates a benign temp dir) and
;     asserts the returned path is a per-instance directory, not the shared
;     A_Temp root;
;   - a static source guard asserting _LLM_Ollama_DispatchAsync and
;     LLM_OllamaGenerate_Streaming route their temp paths through the
;     hardened-dir helper, not a bare A_Temp join, so the hardening can never
;     regress even when a test port supplies the filesystem primitive.
; ==============================================================================





; ================================================
; ================================================
; ======= 1/ Hardened-dir helper behaviour =======
; ================================================
; ================================================

_OCTPP_TempDirIsPerInstance() {
	dir := _LLM_Ollama_TempDir()
	Assert(StrLen(dir) > 0, "_LLM_Ollama_TempDir() must return a non-empty path")
	; The per-instance dir is keyed on PID + nonce under %TEMP%; it must not be the
	; bare shared root where any sibling process can read the PII payload.
	AssertFalse(dir == A_Temp,
		"_LLM_Ollama_TempDir() must not return the shared A_Temp root -- PII payloads belong in a per-instance subdir (ollama-curl-temp-pii-plaintext)")
	AssertContains(dir, "ergopti_llm_",
		"_LLM_Ollama_TempDir() must route through a per-instance ergopti_llm_<pid>_<nonce> subdirectory (ollama-curl-temp-pii-plaintext)")
}
Test("api_ollama: _LLM_Ollama_TempDir returns a per-instance dir, not shared A_Temp (ollama-curl-temp-pii-plaintext)", _OCTPP_TempDirIsPerInstance)





; ====================================================
; ====================================================
; ======= 2/ Dispatch/stream path source guard =======
; ====================================================
; ====================================================

_OCTPP_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_OCTPP_DispatchUsesHardenedDir() {
	Seg := _DriverFuncBody("_LLM_Ollama_DispatchAsync")
	Assert(Seg != "", "_LLM_Ollama_DispatchAsync must exist in api_ollama.ahk")
	Assert(InStr(Seg, "_LLM_Ollama_TempDir(") > 0,
		"_LLM_Ollama_DispatchAsync must build its payload path from _LLM_Ollama_TempDir(), not a bare A_Temp join (ollama-curl-temp-pii-plaintext)")
	; The payload file name must be joined onto the hardened dir variable, never
	; A_Temp directly, so the PII payload never lands in the shared root.
	Assert(InStr(Seg, "A_Temp . " . Chr(34) . "\ergopti_ollama_") == 0,
		"_LLM_Ollama_DispatchAsync must not join the payload path onto the shared A_Temp root (ollama-curl-temp-pii-plaintext)")
}
Test("api_ollama: _LLM_Ollama_DispatchAsync routes payload through the hardened dir (ollama-curl-temp-pii-plaintext)", _OCTPP_DispatchUsesHardenedDir)

_OCTPP_StreamingUsesHardenedDir() {
	Seg := _DriverFuncBody("LLM_OllamaGenerate_Streaming")
	Assert(Seg != "", "LLM_OllamaGenerate_Streaming must exist in api_ollama.ahk")
	AssertContains(Seg, "_LLM_CurlArtifactPortFn(Port, " . Chr(34) . "temp_dir" . Chr(34)
		. ", _LLM_Ollama_TempDir)",
		"LLM_OllamaGenerate_Streaming must default its temp-dir port to _LLM_Ollama_TempDir(), not a bare A_Temp join (ollama-curl-temp-pii-plaintext)")
	AssertContains(Seg, "try tmp_dir := TempDirFn.Call()",
		"LLM_OllamaGenerate_Streaming must obtain its payload directory through the hardened temp-dir port (ollama-curl-temp-pii-plaintext)")
}
Test("api_ollama: LLM_OllamaGenerate_Streaming routes payload through the hardened dir (ollama-curl-temp-pii-plaintext)", _OCTPP_StreamingUsesHardenedDir)
