; static/ergopti_plus/windows/tests/run_llm_model_menu_disabled.ahk
#Requires AutoHotkey v2.0+
SetWorkingDir(A_ScriptDir)
#Warn VarUnset, Off

; ==============================================================================
; MODULE: LLM Model Menu - Disabled-Feature Catalogue Tests
; DESCRIPTION:
; Behavioural guard for the "disabled feature hid every model" regression. Loads
; ui/menu/menu_llm/menu_models.ahk with stubbed dependencies (so this doubles as a
; parse/load check of the catalogue builder) and proves that the model submenu
; lists the FULL curated catalogue regardless of the enabled / Ollama-ready
; state, mirroring Hammerspoon. It also pins the non-blocking contract: the green
; "installed" dot probe (LLM_IsModelInstalled / LLM_OllamaListModels) must be
; skipped until the daemon is confirmed ready, so a disabled feature never blocks
; the menu on a /api/tags round-trip.
; ==============================================================================

#Include test_framework.ahk

; --- Mutable test state the stubs read/record ---
global _MMD_DepsReady   := false   ; toggled per test
global _MMD_ProbeCalls  := 0       ; LLM_IsModelInstalled call count
global _MMD_ListCalls   := 0       ; LLM_OllamaListModels call count
global _MMD_InfoCalls   := 0       ; LLM_GetModelInfo call count (catalogue-build signal)

; --- Globals the module reads ---
global _LLM_Menu  := Map("backend", "ollama", "model", "Qwen3.5-2B", "enabled", false)
global JSON_NULL  := { __null: true }   ; sentinel object: only an exact == match counts as null

; --- Dependency stubs (must exist at load: AHK resolves calls then) ---
t(key)                       => key
RegisterMenuItem(m, l, cb*)  => m.Add(l, cb.Length ? cb[1] : (*) => 0)
LLM_Deps_IsReady()           => _MMD_DepsReady
_LLM_DefaultFor(k, d := "")  => d
LLM_ModelBrowser_Show()      => ""
LLM_Menu_PromptAddModel()    => ""
_LLM_Menu_BuildApiEntriesMenu() => Menu()
LLM_Menu_SetModel(n*)        => ""

; --- Renderer stubs ---
; The catalogue is row DATA since 2026-08-07 and the shared renderer materialises
; it; this harness loads menu_models.ahk alone, so the two entry points it calls
; are stubbed. Both walk the rows the way the real renderer does — a row with
; ``items`` becomes a submenu, a row without a label raises — so a provider that
; returns a malformed row still fails the suite instead of rendering nothing.
_MMD_RenderRows(TargetMenu, Rows) {
	Added := 0
	for Row in Rows {
		if (Row.Has("separator") and Row["separator"]) {
			TargetMenu.Add()
			continue
		}
		if (Row.Has("items"))
			TargetMenu.Add(Row["label"], _MMD_RowsToMenu(Row["items"]))
		else
			TargetMenu.Add(Row["label"], Row.Has("action") ? Row["action"] : (*) => 0)
		Added += 1
	}
	return Added
}
_MMD_RowsToMenu(Rows) {
	Sub := Menu()
	_MMD_RenderRows(Sub, Rows)
	return Sub
}
MenuRenderer_AppendRows(TargetMenu, MenuKey, ListId, Rows) => _MMD_RenderRows(TargetMenu, Rows)
MenuRenderer_FillFromList(TargetMenu, MenuKey, ListId, Provider) {
	try TargetMenu.Delete()
	return _MMD_RenderRows(TargetMenu, Provider())
}

LLM_IsModelInstalled(name) {
	global _MMD_ProbeCalls
	_MMD_ProbeCalls += 1
	return true
}
LLM_OllamaListModels() {
	global _MMD_ListCalls
	_MMD_ListCalls += 1
	return ["qwen3.5:2b"]
}
LLM_GetModelInfo(name) {
	global _MMD_InfoCalls
	_MMD_InfoCalls += 1
	return Map("params_b", 2.0, "active_b", 2.0, "ram_gb", 1.8, "type", "chat")
}
LLM_GetModelPresets() {
	return [
		Map("label", "Meta (Llama)", "families", [
			Map("label", "Llama 3.1", "models", [
				Map("name", "Llama-3.1-8B", "type", "chat",
					"parameters", Map("total", "8B"),
					"urls", Map("ollama", "https://ollama.com/library/llama3.1:8b", "hf", "https://hf/llama"))
			])
		]),
		Map("label", "Qwen", "families", [
			Map("label", "Qwen3.5", "models", [
				Map("name", "Qwen3.5-2B", "type", "chat",
					"parameters", Map("total", "2B"),
					"urls", Map("ollama", "https://ollama.com/library/qwen3.5:2b"))
			])
		])
	]
}

#Include ../ui/menu/menu_llm/menu_models.ahk

; Isolated suite: bail if a stale lock ever hangs RunTests.
_MmdWatchdog(*) {
	try FileAppend("`n[WATCHDOG] run_llm_model_menu_disabled timed out`n", "*")
	ExitApp(2)
}
SetTimer(_MmdWatchdog, -60000)

_MMD_ResetCounters() {
	global _MMD_ProbeCalls, _MMD_ListCalls, _MMD_InfoCalls
	_MMD_ProbeCalls := 0
	_MMD_ListCalls  := 0
	_MMD_InfoCalls  := 0
}





; =========================================================
; ======= 1/ Catalogue is built whatever the state ========
; =========================================================

_MMD_AppendBuildsFullCatalogueWhenNotReady() {
	global _MMD_DepsReady
	_MMD_DepsReady := false
	_MMD_ResetCounters()
	any := _LLM_Menu_AppendCatalogue(Menu(), LLM_GetModelPresets(), "", false)
	AssertTrue(any, "the full catalogue must still be built when the feature/daemon is not ready")
	AssertEqual(0, _MMD_ProbeCalls, "install probe must be skipped when deps are not ready (non-blocking)")
}
Test("model menu: catalogue is built (no install probe) when not ready", _MMD_AppendBuildsFullCatalogueWhenNotReady)

_MMD_AppendProbesWhenReady() {
	global _MMD_DepsReady
	_MMD_DepsReady := true
	_MMD_ResetCounters()
	any := _LLM_Menu_AppendCatalogue(Menu(), LLM_GetModelPresets(), "", true)
	AssertTrue(any, "the catalogue must be built when ready too")
	AssertTrue(_MMD_ProbeCalls > 0, "install probe must run to paint the green dot when the daemon is ready")
}
Test("model menu: install probe runs when the daemon is ready", _MMD_AppendProbesWhenReady)





; =========================================================
; ======= 2/ Row title green-dot honours deps_ready ========
; =========================================================

_MMD_RowTitleNoDotWhenNotReady() {
	; U+1F7E2 GREEN CIRCLE - referenced via Chr() so the test stays ASCII-only.
	dot := Chr(0x1F7E2)
	title_off := _LLM_Menu_BuildModelRowTitle("Llama-3.1-8B", "", false)
	Assert(!InStr(title_off, dot), "row title must NOT show the installed dot while deps are not ready")
	title_on := _LLM_Menu_BuildModelRowTitle("Llama-3.1-8B", "", true)
	AssertContains(title_on, dot, "row title MUST show the installed dot once deps are ready (model is installed)")
}
Test("model menu: row green dot only when deps ready", _MMD_RowTitleNoDotWhenNotReady)





; =========================================================
; ======= 3/ BuildModelMenu builds catalogue if OFF ========
; =========================================================

_MMD_BuildModelMenuListsAllWhenDisabled() {
	global _LLM_Menu, _MMD_DepsReady, _MMD_InfoCalls
	; Reproduce the user's exact state: feature OFF, Ollama never bootstrapped.
	_LLM_Menu := Map("backend", "ollama", "model", "Qwen3.5-2B", "enabled", false)
	_MMD_DepsReady := false
	_MMD_ResetCounters()
	menu := LLM_Menu_BuildModelMenu()
	AssertTrue(IsObject(menu), "BuildModelMenu must return a Menu, not crash, when the feature is off")
	; The OLD bug short-circuited to a placeholder before any catalogue work, so
	; GetModelInfo was never reached. Reaching it proves the full catalogue built.
	AssertTrue(_MMD_InfoCalls > 0,
		"BuildModelMenu must build the full catalogue (GetModelInfo reached) even when the feature is off")
	AssertEqual(0, _MMD_ProbeCalls, "menu build must not probe Ollama while the feature is off (non-blocking)")
}
Test("model menu: BuildModelMenu lists the full catalogue when the feature is disabled", _MMD_BuildModelMenuListsAllWhenDisabled)

RunTests()
