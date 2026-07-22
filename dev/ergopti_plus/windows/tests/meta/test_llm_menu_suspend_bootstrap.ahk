; tests/meta/test_llm_menu_suspend_bootstrap.ahk

; ============================================================================== 
; MODULE: LLM Menu Bootstrap Suspend Fence Meta Test
; DESCRIPTION:
; Guards every asynchronous Ollama lifecycle entry that can otherwise rebuild
; the tray or start the bridge after native Suspend has disabled only hotkeys.
; ============================================================================== 

#Requires AutoHotkey v2.0

_LMSB_ActionsLifecycleEntriesAreSuspendFenced() {
	for Name in ["LLM_Menu_BootstrapOllama", "LLM_Menu_OnDepsReady", "LLM_Menu_OnDepsFailed", "LLM_Menu_TryStartBridge", "LLM_Menu_StartBridge"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name " must exist in ui/menu/menu_llm/actions.ahk")
		Assert(InStr(Body, "if A_IsSuspended") > 0,
			Name " must defer its lifecycle work while suspended because timer and dependency callbacks bypass native Suspend")
		Assert(InStr(Body, '"bootstrap_pending"') > 0,
			Name " must record suspended lifecycle work for replay after resume")
	}
}
Test("LLM tray: suspended bootstrap and dependency callbacks are fenced (llm-menu-suspend-bootstrap)", _LMSB_ActionsLifecycleEntriesAreSuspendFenced)

_LMSB_ResumeReplaysPendingBootstrap() {
	Body := _DriverFuncBody("LLM_Menu_OnResume")
	Assert(Body != "", "LLM_Menu_OnResume must exist in ui/menu/menu_llm/actions.ahk")
	Assert(InStr(Body, '"bootstrap_pending"') > 0,
		"LLM_Menu_OnResume must consume the pending suspended lifecycle marker")
	Assert(InStr(Body, "SetTimer(() => LLM_Menu_BootstrapOllama(false), -1)") > 0,
		"LLM_Menu_OnResume must replay bootstrap asynchronously after resume")
	Lifecycle := _DriverFuncBody("Ergopti_OnSuspendResume")
	Assert(Lifecycle != "", "Ergopti_OnSuspendResume must exist")
	Assert(InStr(Lifecycle, "LLM_Menu_OnResume()") > 0,
		"Ergopti_OnSuspendResume must hand pending LLM lifecycle work to LLM_Menu_OnResume")
}
Test("LLM tray: resume replays deferred bootstrap exactly once (llm-menu-suspend-bootstrap)", _LMSB_ResumeReplaysPendingBootstrap)
