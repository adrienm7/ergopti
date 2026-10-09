; static/ergopti_plus/windows/tests/unit/test_llm_keep_alive_from_shared_defaults.ahk

; ==============================================================================
; MODULE: Regression — llm_ollama_keep_alive must come from the shared JSON
;         (llm-keep-alive-not-loaded-on-windows)
; DESCRIPTION:
; LLM_Defaults_Load enumerates the keys it sources from
; _shared/modules/llm/defaults.json group by group: booleans, numbers, strings,
; temperature, arrays. llm_ollama_keep_alive is a string and appeared in none of
; them, so LLM_Defaults never held the key at all.
;
; ROOT CAUSE ENCODED: the loader's fail-fast `missing` list only covers the keys
; it explicitly enumerates, so an OMITTED key is not a missing key — it is simply
; absent, and absence is silent by construction. Downstream,
; api_ollama/init.ahk guards on LLM_Defaults.Has("llm_ollama_keep_alive"), a
; condition that was therefore permanently false, and the payload builder fell
; back to a literal that happened to equal the canonical value. Editing the
; shared JSON changed macOS and left Windows alone, with nothing logged and
; nothing to notice until the two drivers pinned model weights in VRAM for
; different durations.
;
; The assertion is written against the JSON itself rather than against "30m", so
; it pins the SINGLE SOURCE and not today's spelling of the value.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===========================================================
; ===========================================================
; ======= 1/ The loader sources the key from the JSON =======
; ===========================================================
; ===========================================================

_LLMKA_LoaderSourcesKeepAliveFromSharedJson() {
	global LLM_Defaults
	LLM_Defaults_Load()

	AssertTrue(LLM_Defaults.Has("llm_ollama_keep_alive"),
		"LLM_Defaults_Load must source llm_ollama_keep_alive from defaults.json. api_ollama/init.ahk copies it under a Has() guard, so omitting it from the loader's key lists leaves that guard permanently false and the Ollama payload is built from a hardcoded literal instead of the shared canonical")

	Raw := ""
	try Raw := FileRead(LLM_GetSharedPath("defaults.json"), "UTF-8")
	Assert(Raw != "", "the shared defaults.json must be readable for this test to mean anything")

	Assert(RegExMatch(Raw, 'i)"llm_ollama_keep_alive"\s*:\s*"([^"]*)"', &M) > 0,
		"defaults.json must still declare llm_ollama_keep_alive — it is the cross-driver source both this driver and api_ollama.lua read")

	AssertEqual(M[1], LLM_Defaults["llm_ollama_keep_alive"],
		"the loaded value must be the one in defaults.json verbatim. Comparing against the JSON rather than against a literal is the point: a test that pinned today's value would keep passing while the loader served a stale in-code default")
}
Test("LLM defaults: llm_ollama_keep_alive is sourced from the shared defaults.json",
	_LLMKA_LoaderSourcesKeepAliveFromSharedJson)





; ========================================================
; ========================================================
; ======= 2/ The loaded value is actually consumed =======
; ========================================================
; ========================================================

; Loading a key nothing reads would restore the same silence by another route.
_LLMKA_LoadedValueIsWiredToTheOllamaGlobal() {
	Src := _DriverSourceNoComments()

	Assert(InStr(Src, 'LLM_Defaults["llm_ollama_keep_alive"]') > 0,
		"the Ollama layer must read llm_ollama_keep_alive out of LLM_Defaults — a key the loader sources but nobody consumes is the same dead value wearing a different hat")

	Assert(InStr(Src, "LLM_OLLAMA_KEEP_ALIVE") > 0,
		"and it must reach the global the payload builder reads, or the shared value stops at the loader")
}
Test("LLM defaults: the loaded keep_alive reaches the Ollama payload global",
	_LLMKA_LoadedValueIsWiredToTheOllamaGlobal)
