; tests/meta/test_llm_ensure_model_ready_guard.ahk

; ==============================================================================
; MODULE: LLM EnsureModelReady Deps-Ready Guard Test
; DESCRIPTION:
; Regression guard for the ~2.2 s boot freeze traced to the menu build. The
; "Tray menu built" phase was dominated entirely by LLM_Menu_Init, whose
; LLM_Menu_EnsureModelReady() ran a SYNCHRONOUS installed-models probe
; (LLM_IsModelInstalled -> _LLM_GetInstalledTagsCached -> LLM_OllamaListModels,
; a blocking GET /api/tags with a 5 s WinHTTP timeout). At boot the Ollama deps
; state is "pending", so a dead-port connect to localhost:11434 froze the
; synchronous menu build for ~2 s on every start — even with the LLM feature
; switched off.
;
; THE FIX: LLM_Menu_EnsureModelReady() bails on !LLM_Deps_IsReady() before any
; installed-models probe, mirroring the same non-blocking contract that
; LLM_Menu_BuildModelMenu already honours. The model auto-correct still runs
; once the daemon is confirmed up: the deps-ready bridge-start path calls
; EnsureModelReady again with LLM_Deps_IsReady() == true, where the probe
; returns in milliseconds.
;
; This is a source-level assertion (not a behavioural harness) because
; actions.ahk references dozens of cross-module functions that would all need
; stubbing to load standalone; the byte-offset check mirrors the sibling
; meta/test_llm_menu_init_order.ahk and is resilient to unrelated edits.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckEnsureModelReadyGuard() {
	; Move-resilient: locate LLM_Menu_EnsureModelReady() across the whole driver
	; source via the framework helper instead of a pinned ui/menu/menu_llm path.
	FnBody := _DriverFuncBody("LLM_Menu_EnsureModelReady")
	Assert(FnBody != "",
		"actions.ahk must define LLM_Menu_EnsureModelReady() — entry point not found")

	GuardPos := InStr(FnBody, "!LLM_Deps_IsReady()")
	ProbePos := InStr(FnBody, "LLM_IsModelInstalled(")

	Assert(GuardPos > 0,
		"LLM_Menu_EnsureModelReady must bail on !LLM_Deps_IsReady() before any "
		. "blocking installed-models probe — without it the boot-time call froze "
		. "the menu build ~2 s on a dead-port connect to localhost:11434")

	Assert(ProbePos > 0,
		"LLM_Menu_EnsureModelReady must still call LLM_IsModelInstalled() so the "
		. "model auto-correct runs once the Ollama daemon is confirmed ready")

	Assert(GuardPos < ProbePos,
		"the LLM_Deps_IsReady() guard must precede LLM_IsModelInstalled() in "
		. "LLM_Menu_EnsureModelReady (guard at offset " . GuardPos
		. ", probe at offset " . ProbePos . ")")
}

Test("meta llm: EnsureModelReady guards the blocking probe on deps-ready",
	_MetaCheckEnsureModelReadyGuard)
