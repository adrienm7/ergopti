; tests/meta/test_remote_catalog_load_graceful.ahk

; ==============================================================================
; MODULE: Remote Catalog Graceful-Load Meta Test
; DESCRIPTION:
; Regression guard for the graceful-load contract on the LLM remote provider
; catalogue (_LLMRemote_LoadCatalog / api_providers.json).
;
; Before the fix, a missing or malformed api_providers.json caused
; _LLMRemote_LoadCatalog() to throw uncaught at module load time, which crashed
; the driver boot sequence entirely. The correct behaviour is to catch that
; error, log it, and fall back to empty provider/price Maps so the driver
; remains functional with just the local Ollama backend.
;
; This test asserts that the call to _LLMRemote_LoadCatalog in api_remote.ahk
; is wrapped in a try/catch block that (a) assigns empty Maps to all three
; globals on failure and (b) logs an ERROR rather than propagating the exception.
;
; SCOPE: source introspection of modules/llm/api_remote.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ====================================================
; ====================================================
; ======= 1/ Source scan helpers =====================
; ====================================================
; ====================================================

_RCLG_ReadSource() {
	return _DriverDirConcat("modules/llm")
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_RCLG_LoadCallIsWrapped() {
	Src := _RCLG_ReadSource()
	Assert(Src != "", "modules/llm/ source must be readable")

	; Locate the try-wrapped call site in api_remote.ahk
	CallPos := InStr(Src, "try _LLMRemote_LoadCatalog()")
	Assert(CallPos > 0,
		"_LLMRemote_LoadCatalog() must be called inside a 'try' wrapper — a missing or malformed api_providers.json must not crash the driver at boot")
}

Test("api_remote: _LLMRemote_LoadCatalog() call is try-wrapped (remote-catalog-load-graceful)",
	_RCLG_LoadCallIsWrapped)


_RCLG_CatchFallsBackToEmptyMaps() {
	Src := _RCLG_ReadSource()

	CallPos := InStr(Src, "try _LLMRemote_LoadCatalog()")
	Assert(CallPos > 0,
		"_LLMRemote_LoadCatalog() must be called with try — prerequisite for this test")

	; The catch block must assign safe empty Maps to all three catalogue globals
	CatchSeg := SubStr(Src, CallPos, 400)
	Assert(InStr(CatchSeg, "catch") > 0,
		"try _LLMRemote_LoadCatalog() must be followed by a catch block that handles load failure gracefully")
	Assert(InStr(CatchSeg, "LLM_API_PROVIDERS := Map()") > 0,
		"catch block must reset LLM_API_PROVIDERS to Map() so callers see an empty table rather than a stale or undefined value")
	Assert(InStr(CatchSeg, "LLM_API_PROVIDER_ORDER := []") > 0,
		"catch block must reset LLM_API_PROVIDER_ORDER to [] so iteration is safe even when the catalogue failed to load")
	Assert(InStr(CatchSeg, "LLM_REMOTE_MODEL_PRICES := Map()") > 0,
		"catch block must reset LLM_REMOTE_MODEL_PRICES to Map() so price lookups do not throw on a failed catalogue load")
}

Test("api_remote: catch block resets all three catalogue globals to empty containers (remote-catalog-load-graceful)",
	_RCLG_CatchFallsBackToEmptyMaps)


_RCLG_CatchLogsError() {
	Src := _RCLG_ReadSource()

	CallPos := InStr(Src, "try _LLMRemote_LoadCatalog()")
	Assert(CallPos > 0,
		"_LLMRemote_LoadCatalog() must be called with try — prerequisite for this test")

	CatchSeg := SubStr(Src, CallPos, 400)
	Assert(InStr(CatchSeg, "LoggerError") > 0,
		"catch block must call LoggerError so a catalogue load failure is visible in the log rather than swallowed silently")
}

Test("api_remote: catch block logs an ERROR on catalogue load failure (remote-catalog-load-graceful)",
	_RCLG_CatchLogsError)
