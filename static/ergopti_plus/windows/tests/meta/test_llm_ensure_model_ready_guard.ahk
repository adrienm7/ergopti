; tests/meta/test_llm_ensure_model_ready_guard.ahk

; ==============================================================================
; MODULE: LLM EnsureModelReady Deps-Ready Guard Test
; DESCRIPTION:
; Regression guard for the ~2.2 s boot freeze traced to the menu build. The
; "Tray menu built" phase was dominated entirely by LLM_Tray_Init, whose
; LLM_Tray_EnsureModelReady() ran a SYNCHRONOUS installed-models probe
; (LLM_IsModelInstalled -> _LLM_GetInstalledTagsCached -> LLM_OllamaListModels,
; a blocking GET /api/tags with a 5 s WinHTTP timeout). At boot the Ollama deps
; state is "pending", so a dead-port connect to localhost:11434 froze the
; synchronous menu build for ~2 s on every start — even with the LLM feature
; switched off.
;
; THE FIX: LLM_Tray_EnsureModelReady() bails on !LLM_Deps_IsReady() before any
; installed-models probe, mirroring the same non-blocking contract that
; LLM_Tray_BuildModelMenu already honours. The model auto-correct still runs
; once the daemon is confirmed up: the deps-ready bridge-start path calls
; EnsureModelReady again with LLM_Deps_IsReady() == true, where the probe
; returns in milliseconds.
;
; This is a source-level assertion (not a behavioural harness) because
; actions.ahk references dozens of cross-module functions that would all need
; stubbing to load standalone; the byte-offset check mirrors the sibling
; meta/test_llm_tray_init_order.ahk and is resilient to unrelated edits.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckEnsureModelReadyGuard() {
	; Locate ui/tray_llm/actions.ahk relative to the tests/ directory.
	SplitPath(A_ScriptDir, , &WindowsDir)
	ActionsFile := WindowsDir . "\ui\tray_llm\actions.ahk"

	try {
		Body := FileRead(ActionsFile)
	} catch {
		return
	}

	FnPos := InStr(Body, "LLM_Tray_EnsureModelReady() {")
	Assert(FnPos > 0,
		"actions.ahk must define LLM_Tray_EnsureModelReady() — entry point not found")

	; Scope the search to the function body: in this tab-indented codebase the
	; only column-0 closing brace after the declaration is the function's own,
	; so the first "`n}" after FnPos bounds the body precisely.
	BodyEnd := InStr(Body, "`n}", false, FnPos)
	if (BodyEnd == 0)
		BodyEnd := StrLen(Body) + 1
	FnBody := SubStr(Body, FnPos, BodyEnd - FnPos)

	GuardPos := InStr(FnBody, "!LLM_Deps_IsReady()")
	ProbePos := InStr(FnBody, "LLM_IsModelInstalled(")

	Assert(GuardPos > 0,
		"LLM_Tray_EnsureModelReady must bail on !LLM_Deps_IsReady() before any "
		. "blocking installed-models probe — without it the boot-time call froze "
		. "the menu build ~2 s on a dead-port connect to localhost:11434")

	Assert(ProbePos > 0,
		"LLM_Tray_EnsureModelReady must still call LLM_IsModelInstalled() so the "
		. "model auto-correct runs once the Ollama daemon is confirmed ready")

	Assert(GuardPos < ProbePos,
		"the LLM_Deps_IsReady() guard must precede LLM_IsModelInstalled() in "
		. "LLM_Tray_EnsureModelReady (guard at offset " . GuardPos
		. ", probe at offset " . ProbePos . ")")
}

Test("meta llm: EnsureModelReady guards the blocking probe on deps-ready",
	_MetaCheckEnsureModelReadyGuard)
