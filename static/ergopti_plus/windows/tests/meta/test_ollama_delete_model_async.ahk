; tests/meta/test_ollama_delete_model_async.ahk

#Requires AutoHotkey v2.0

; ==============================================================================
; MODULE: Ollama Delete-Model Async Meta Test
; DESCRIPTION:
; Regression guard for F24 — LLM_OllamaDeleteModel ran a synchronous WinHTTP
; DELETE (up to ~10 s) directly on the tray-menu/message-loop thread, the one
; Ollama HTTP surface the async-curl-child migration missed. Mirrors
; test_updater_sync_winhttp_blocks.ahk's source-scan pattern.
; ==============================================================================




; ===================================================
; ===================================================
; ======= 1/ Assertions ==============================
; ===================================================
; ===================================================

_ODMA_AssertPromptDeleteUsesAsync() {
	Body := _DriverFuncBody("_LLM_Menu_PromptDeleteCachedModel")
	Assert(Body != "", "_LLM_Menu_PromptDeleteCachedModel must exist in ui/menu/menu_llm")
	Assert(!InStr(Body, "LLM_OllamaDeleteModel("),
		"_LLM_Menu_PromptDeleteCachedModel must not call the blocking LLM_OllamaDeleteModel (F24: sync-winhttp-blocks-keyboard-on-model-delete)")
	Assert(InStr(Body, "LLM_OllamaDeleteModel_Async(") > 0,
		"_LLM_Menu_PromptDeleteCachedModel must call LLM_OllamaDeleteModel_Async (F24: sync-winhttp-blocks-keyboard-on-model-delete)")
}
Test("menu_models: model-cache delete uses the async curl pattern (F24)", _ODMA_AssertPromptDeleteUsesAsync)

_ODMA_AssertDeleteModelIsCurlChild() {
	Body := _DriverFuncBody("LLM_OllamaDeleteModel_Async")
	Assert(Body != "", "LLM_OllamaDeleteModel_Async must exist in modules/llm/api_ollama")
	Assert(!InStr(Body, 'ComObject("WinHttp.WinHttpRequest.5.1")'),
		"LLM_OllamaDeleteModel_Async must not use a synchronous WinHTTP COM request — it must spawn curl and poll ProcessExist like LLM_OllamaListModels_Async")
	Assert(InStr(Body, "Run(") > 0,
		"LLM_OllamaDeleteModel_Async must launch curl via Run() (curl-child async pattern)")
}
Test("api_ollama: LLM_OllamaDeleteModel_Async spawns a curl child, never a sync WinHTTP request (F24)", _ODMA_AssertDeleteModelIsCurlChild)

_ODMA_AssertBlockingVariantRemoved() {
	; _DriverFuncBody anchors on a column-0 "Name(...) {" definition, so
	; "LLM_OllamaDeleteModel_Async(...)" cannot false-match "LLM_OllamaDeleteModel" —
	; only the retired blocking def would.
	Body := _DriverFuncBodyOrEmpty("LLM_OllamaDeleteModel")
	Assert(Body == "",
		"the blocking LLM_OllamaDeleteModel(tag) must be fully removed once its only caller uses the async variant (F24 — no unused fallback code)")
}
Test("api_ollama: blocking LLM_OllamaDeleteModel is fully retired (F24)", _ODMA_AssertBlockingVariantRemoved)
