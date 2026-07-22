; tests/meta/test_llm_setbackend_propagates_to_engine.ahk

#Requires AutoHotkey v2.0

; ==============================================================================
; MODULE: LLM SetBackend Engine-Propagation Meta Test
; DESCRIPTION:
; Regression guard for F25 — LLM_Menu_SetBackend was the sole tray setter that
; skipped the LLM_Engine_Init(LLM_Menu_BuildOpts()) call every sibling setter
; makes (LLM_Menu_SetModel, LLM_Menu_SetProfile, LLM_Menu_SetN, …), so a
; backend switch (Ollama <-> API) never reached the live prediction engine and
; defeated the "stop in-flight generation on backend change" safety net inside
; LLM_Engine_Init.
; ==============================================================================




; ===================================================
; ===================================================
; ======= 1/ Assertions ==============================
; ===================================================
; ===================================================

_LSPE_AssertSetBackendCallsEngineInit() {
	Body := _DriverFuncBody("LLM_Menu_SetBackend")
	Assert(Body != "", "LLM_Menu_SetBackend must exist in ui/menu/menu_llm/actions.ahk")
	Assert(InStr(Body, "LLM_Engine_Init(LLM_Menu_BuildOpts())") > 0,
		"LLM_Menu_SetBackend must call LLM_Engine_Init(LLM_Menu_BuildOpts()) like every sibling setter, or the live engine keeps dispatching to the stale backend (F25)")
}
Test("menu_llm: LLM_Menu_SetBackend propagates to the prediction engine (F25)", _LSPE_AssertSetBackendCallsEngineInit)

_LSPE_AssertInitCallPrecedesBuild() {
	Body := _DriverFuncBody("LLM_Menu_SetBackend")
	InitPos  := InStr(Body, "LLM_Engine_Init(LLM_Menu_BuildOpts())")
	BuildPos := InStr(Body, "LLM_Menu_Build()")
	Assert(InitPos > 0 and BuildPos > 0 and InitPos < BuildPos,
		"LLM_Menu_SetBackend must call LLM_Engine_Init before LLM_Menu_Build, matching every sibling setter's ordering (F25)")
}
Test("menu_llm: LLM_Menu_SetBackend inits the engine before rebuilding the tray (F25)", _LSPE_AssertInitCallPrecedesBuild)
