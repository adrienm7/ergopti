; static/ergopti_plus/windows/tests/run_llm_model_menu_disabled.ahk
#Requires AutoHotkey v2.0+
SetWorkingDir(A_ScriptDir)
#Warn VarUnset, Off

; ==============================================================================
; MODULE: LLM Model Menu - Disabled-Feature Catalogue Tests
; DESCRIPTION:
; Behavioural guard for the "disabled feature hid every model" regression. Loads
; ui/menu/menu_llm/menu_models.ahk with its real shared manifest/rendering owners
; and isolated catalogue dependencies, proving that the model submenu
; lists the FULL curated catalogue regardless of the enabled / Ollama-ready
; state, mirroring Hammerspoon. It also pins the non-blocking contract: the green
; "installed" dot probe (LLM_IsModelInstalled / LLM_OllamaListModels) must be
; skipped until the daemon is confirmed ready, so a disabled feature never blocks
; the menu on a /api/tags round-trip.
; ==============================================================================

#Include test_framework.ahk

; Fixed commands read the actual shared declaration through the native owners.
; These includes construct no tray root, browser, timer or population owner.
#Include ../infra/json.ahk
#Include ../infra/menu_manifest.ahk
#Include ../infra/menu_startup_commands.ahk
#Include ../adapters/tray_menu.ahk
#Include ../infra/manifest_menu.ahk
global _SharedDir := A_ScriptDir . "\..\..\_shared"
if !DirExist(_SharedDir)
	throw Error("The isolated model menu requires its actual shared manifest directory")

; --- Mutable test state the stubs read/record ---
global _MMD_DepsReady   := false   ; toggled per test
global _MMD_ProbeCalls  := 0       ; LLM_IsModelInstalled call count
global _MMD_ListCalls   := 0       ; LLM_OllamaListModels call count
global _MMD_InfoCalls   := 0       ; LLM_GetModelInfo call count (catalogue-build signal)

; --- Globals the module reads ---
global _LLM_Menu  := Map("backend", "ollama", "model", "Qwen3.5-2B", "enabled", false)

; --- Dependency stubs (must exist at load: AHK resolves calls then) ---
t(key)                       => key
RegisterMenuItem(m, l, cb*)  => m.Add(l, cb.Length ? cb[1] : (*) => 0)
LLM_Deps_IsReady()           => _MMD_DepsReady
_LLM_DefaultFor(k, d := "")  => d
LLM_ModelBrowser_Show()      => ""
LLM_Menu_PromptAddModel()    => ""
_LLM_Menu_BuildApiEntriesMenu() => Menu()
LLM_Menu_SetModel(n*)        => ""


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

; The real command owner must read the current shared metadata, not a shim.
_MMD_BrowserUsesActualSharedRenderer() {
	Root := _MM_GetManifestRoot()
	Assert(Root is Map, "the actual shared manifest must be loaded")
	Item := _MR_FindItemById("llm_model_commands", "llm_browse_models")
	Assert(Item is Map, "the actual shared browser declaration must exist")
	AssertEqual("command", Item["type"], "the real declaration owns a command row")
	SavedI18n := Item["i18n"]
	try {
		Item["i18n"] := "button.ok"
		Row := _LLM_Menu_ModelBrowserRow()
		Assert(Row is Map, "the actual renderer must return the declared command")
		AssertEqual(t("button.ok"), Row["label"],
			"the actual renderer reads changed shared metadata instead of a private caption")
		AssertEqual(false, Row.Get("disabled", false),
			"the existing isolated callable browser port remains available")
		AssertEqual("", Row["action"].Call(),
			"the existing isolated browser receipt passes through the real command owner")
	} finally Item["i18n"] := SavedI18n
	AssertEqual(SavedI18n, Item["i18n"], "the actual shared declaration is restored")
}
Test("model menu: fixed browser command uses the actual shared renderer and metadata",
	_MMD_BrowserUsesActualSharedRenderer)

_MMD_BrowserReadinessUsesActualRenderer() {
	Row := _LLM_Menu_ModelBrowserRow(Map("future", true))
	Assert(Row is Map, "an unavailable port retains its actual declared row")
	AssertEqual(true, Row.Get("disabled", false),
		"the real renderer refuses a browser object without its callable owner")
	AssertEqual(false, Row["action"].Call(),
		"a retained unavailable command refuses through the actual readiness resolver")
}
Test("model menu: actual shared renderer preserves unavailable browser refusal",
	_MMD_BrowserReadinessUsesActualRenderer)

RunTests()
