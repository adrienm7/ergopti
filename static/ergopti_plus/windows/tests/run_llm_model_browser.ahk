; static/ergopti_plus/windows/tests/run_llm_model_browser.ahk
#Requires AutoHotkey v2.0+
SetWorkingDir(A_ScriptDir)
#Warn VarUnset, Off

; ==============================================================================
; MODULE: LLM Model Browser Tests
; DESCRIPTION:
; Loads ui/llm_model_browser.ahk with stubbed dependencies (so this also acts as a
; parse/load check of the new WebView2 code) and verifies the catalogue-injection
; path that feeds the shared web table: _LLM_MBW_InjectCatalogue() must build a
; well-formed injectModels({backend,active,models:[…]}) call, MoE-aware, with the
; installed flag resolved from the Ollama tag list. The numeric/JS-string helpers
; are checked too since they shape every cell value.
; ==============================================================================

#Include test_framework.ahk

; --- Globals the browser module reads ---
global _LLM_Menu   := Map("model", "Qwen3.5-2B")
global _VendorDir  := A_ScriptDir
global _SharedDir  := A_ScriptDir
global _I18nLocale := "fr"

; --- Dependency stubs (must exist at load: AHK resolves calls then) ---
global _TestIndex := Map()
; Controls whether the install scan runs. The catalogue must list every model
; regardless; only the green dot needs Ollama, so the scan is gated on this.
global _MBW_DepsReady     := true
global _MBW_OllamaListHits := 0   ; counts the (blocking) /api/tags probe calls
t(key)                 => key
LoggerError(args*)     => ""
LoggerStart(args*)     => ""
JsonParse(s)           => Map()
LLM_Menu_SetModel(n)   => ""
LLM_Deps_IsReady()     => _MBW_DepsReady
LLM_OllamaListModels() {
	global _MBW_OllamaListHits
	_MBW_OllamaListHits += 1
	return ["qwen3.5:2b"]
}
LLM_GetModelIndex()    => _TestIndex
LLM_GetModelInfo(n)    => (_TestIndex.Has(n) ? _TestIndex[n] : Map())

; Minimal WebView2 stand-in so IsSet(WebView2) resolves and the class reference in
; the (never-called here) ShowWeb path loads. The tests never create a webview.
class WebView2 {
	static create(args*) {
		return { CoreWebView2: {} }
	}
}

#Include ../ui/model_browser/init.ahk

; Isolated suite: bail if a stale lock ever hangs RunTests.
_LlmMbWatchdog(*) {
	try FileAppend("`n[WATCHDOG] run_llm_model_browser timed out`n", "*")
	ExitApp(2)
}
SetTimer(_LlmMbWatchdog, -60000)




; =========================================================
; ======= 1/ Numeric + JS-string helpers ==================
; =========================================================

_MBNum_Integer() {
	AssertEqual("8", _LLM_MBW_Num(8))
	AssertEqual("8", _LLM_MBW_Num(8.0))
}
Test("LLM_MBW_Num: integer renders without decimals", _MBNum_Integer)

_MBNum_Float() {
	AssertEqual("4.22", _LLM_MBW_Num(4.22))
}
Test("LLM_MBW_Num: float keeps two decimals", _MBNum_Float)

_MBNum_NonNumber() {
	AssertEqual("0", _LLM_MBW_Num("abc"))
}
Test("LLM_MBW_Num: non-number defaults to 0", _MBNum_NonNumber)

_MBJsStr_Escapes() {
	AssertEqual('"a\"b"', _LLM_MBW_JsStr('a"b'))
}
Test("LLM_MBW_JsStr: escapes double quotes", _MBJsStr_Escapes)




; =========================================================
; ======= 2/ Catalogue injection ==========================
; =========================================================

_MBInject_BuildsCatalogue() {
	global _TestIndex, _LLM_MBW_Queue, _LLM_MBW_Ready, _MBW_DepsReady
	; One installed dense model + one MoE model.
	_TestIndex := Map(
		"Qwen3.5-2B", Map("params_b", 2.0, "ram_gb", 1.8, "speed_tok_s", 90, "type", "chat", "ollama", "qwen3.5:2b"),
		"gemma-4-E2B-it", Map("params_b", 5.12, "active_b", 2.0, "ram_gb", 3.3, "speed_tok_s", 40, "type", "chat", "ollama", "gemma:e2b")
	)
	; Daemon ready -> the install scan runs and Qwen is flagged installed.
	_MBW_DepsReady := true
	; No webview is set, so _LLM_MBW_Eval queues the JS instead of executing it.
	_LLM_MBW_Ready := false
	_LLM_MBW_Queue := []
	_LLM_MBW_InjectCatalogue()

	AssertEqual(1, _LLM_MBW_Queue.Length, "catalogue injection should queue exactly one JS call")
	js := _LLM_MBW_Queue[1]
	AssertContains(js, 'injectModels({backend:"ollama"')
	AssertContains(js, '"Qwen3.5-2B"')
	AssertContains(js, "params_b:5.12")     ; gemma total
	AssertContains(js, "active_b:2")        ; gemma active
	AssertContains(js, "is_moe:true")       ; gemma is MoE
	AssertContains(js, "installed:true")    ; Qwen tag qwen3.5:2b is in the installed list
}
Test("LLM_MBW_InjectCatalogue: builds the injectModels() payload", _MBInject_BuildsCatalogue)

; Regression: with the feature OFF the Ollama daemon is down, so the install
; scan must be skipped — otherwise its synchronous /api/tags probe stalls the
; WebView2 message callback and injectModels() never fires (empty table). The
; full catalogue must STILL be injected; only the installed dot is dropped.
_MBInject_DisabledStillListsAllModels() {
	global _TestIndex, _LLM_MBW_Queue, _LLM_MBW_Ready, _MBW_DepsReady, _MBW_OllamaListHits
	_TestIndex := Map(
		"Qwen3.5-2B", Map("params_b", 2.0, "ram_gb", 1.8, "speed_tok_s", 90, "type", "chat", "ollama", "qwen3.5:2b"),
		"gemma-4-E2B-it", Map("params_b", 5.12, "active_b", 2.0, "ram_gb", 3.3, "speed_tok_s", 40, "type", "chat", "ollama", "gemma:e2b")
	)
	_MBW_DepsReady     := false   ; feature disabled / daemon not reachable
	_MBW_OllamaListHits := 0
	_LLM_MBW_Ready := false
	_LLM_MBW_Queue := []
	_LLM_MBW_InjectCatalogue()

	AssertEqual(1, _LLM_MBW_Queue.Length, "catalogue must still be injected when the daemon is not ready")
	js := _LLM_MBW_Queue[1]
	AssertContains(js, '"Qwen3.5-2B"')        ; every model is still listed…
	AssertContains(js, '"gemma-4-E2B-it"')
	AssertContains(js, "installed:false")     ; …just without the installed dot
	Assert(!InStr(js, "installed:true"), "no model may be flagged installed while the daemon is not scanned")
	AssertEqual(0, _MBW_OllamaListHits, "the blocking /api/tags probe must NOT run when the daemon is not ready")
}
Test("LLM_MBW_InjectCatalogue: lists all models without probing when the feature is off", _MBInject_DisabledStillListsAllModels)

RunTests()
