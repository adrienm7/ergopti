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
	Assert(InStr(Body, "LLM_Menu_CommitMutation(") > 0
		and InStr(Body, "_LLM_Menu_ApplyBackendCommitted") > 0,
		"LLM_Menu_SetBackend must route its durable candidate through the shared "
		. "post-commit engine initializer; direct live initialization before "
		. "durability would revive F25 as a persistence lie")
	ApplyBody := _DriverFuncBody("_LLM_Menu_ApplyBackendCommitted")
	Assert(InStr(ApplyBody, "LLM_Engine_Init(LLM_Menu_BuildOpts())") > 0,
		"the shared committed callback must propagate the published backend to "
		. "the prediction engine (F25)")
}
Test("menu_llm: LLM_Menu_SetBackend propagates to the prediction engine (F25)", _LSPE_AssertSetBackendCallsEngineInit)

_LSPE_AssertInitCallPrecedesBuild() {
	Body := _DriverFuncBody("_LLM_Menu_ApplyBackendCommitted")
	InitPos  := InStr(Body, "LLM_Engine_Init(LLM_Menu_BuildOpts())")
	BuildPos := InStr(Body, "LLM_Menu_RequestBuild(")
	Assert(InitPos > 0 and BuildPos > 0 and InitPos < BuildPos,
		"LLM_Menu_SetBackend must call LLM_Engine_Init before requesting a menu build, matching every sibling setter's ordering (F25)")
}
Test("menu_llm: LLM_Menu_SetBackend inits the engine before rebuilding the tray (F25)", _LSPE_AssertInitCallPrecedesBuild)

_LSPE_AssertSetModelSuppliesAutoProfileState() {
	Body := _DriverFuncBody("LLM_Menu_SetModel")
	Assert(Body != "", "LLM_Menu_SetModel must exist in ui/menu/menu_llm/actions.ahk")
	MutatorBody := _DriverFuncBody("_LLM_Menu_SetModelCandidate")
	Assert(InStr(Body, "_LLM_Menu_SetModelCandidate") > 0
		and InStr(MutatorBody,
			"LLM_Menu_AutoApplyProfileForModel(Candidate)") > 0,
		"LLM_Menu_SetModel must pass its detached candidate Map to "
		. "LLM_Menu_AutoApplyProfileForModel; resolving against live RAM before "
		. "durability can leak a profile change on writer failure")
	Assert(InStr(Body, "LLM_Menu_AutoApplyProfileForModel()") == 0,
		"LLM_Menu_SetModel must not retain the stale no-argument call after the helper became candidate-scoped")
}
Test("menu_llm: LLM_Menu_SetModel passes its candidate to auto-profile (llm-setmodel-auto-profile-arity)",
	_LSPE_AssertSetModelSuppliesAutoProfileState)

_LSPE_AssertAutoProfileResolverUsesExplicitState() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "the LLM auto-profile source scan must read production code")
	Assert(RegExMatch(Src,
		"\bLLM_Menu_AutoApplyProfileForModel\s*\(MenuState\)\s*\{") > 0,
		"LLM_Menu_AutoApplyProfileForModel must accept the state Map its callers pass")
	Assert(InStr(Src, "LLM_Menu_AutoApplyProfileForModel()") == 0,
		"every auto-profile caller must pass its state explicitly; a no-argument sibling would keep the resolver interface inconsistent")
	Body := _DriverFuncBody("LLM_Menu_AutoApplyProfileForModel")
	Assert(Body != "", "LLM_Menu_AutoApplyProfileForModel must exist")
	Assert(InStr(Body, "MenuState[") > 0
		and InStr(Body, "global _LLM_Menu") == 0,
		"the resolver must read and mutate its explicit state instead of silently rebinding to the live global")
}
Test("menu_llm: every auto-profile path uses explicit state (llm-setmodel-auto-profile-arity)",
	_LSPE_AssertAutoProfileResolverUsesExplicitState)
