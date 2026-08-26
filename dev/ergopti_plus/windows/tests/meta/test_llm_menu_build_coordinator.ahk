; tests/meta/test_llm_menu_build_coordinator.ahk

; ==============================================================================
; MODULE: LLM Menu Build Coordinator Wiring
; DESCRIPTION:
; AHK-010 source-boundary guard. Runtime behavior is covered by the companion
; unit test; this guard proves every production producer transfers work to that
; owner and none calls the raw detached builder directly.
; ==============================================================================

#Requires AutoHotkey v2.0

_LMBCM_AllProducersUseTheCoordinator() {
	RequestProducers := [
		"_LLM_Menu_ApplyToggleCommitted",
		"_LLM_Menu_ApplyBackendCommitted",
		"_LLM_Menu_ApplyModelRuntimeCommitted",
		"_LLM_Menu_ApplyStandardCommitted",
		"_LLM_Menu_ApplyCurrentDepsFailure",
		"_LLM_Menu_ApplyOllamaPortCommitted",
		"_LLM_Menu_AuxBuild",
		"_LLM_Menu_PullModel",
		"_LLM_Menu_RunClaimedTriggerRecovery"
	]
	for _, Name in RequestProducers {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must remain source-visible")
		Assert(InStr(Body, "LLM_Menu_RequestBuild") > 0,
			Name . " must transfer its dirty state to the retained build owner")
		Assert(InStr(Body, "LLM_Menu_Build()") == 0,
			Name . " must never call the raw detached builder")
	}

	for _, Name in ["_LLM_Menu_OnHealthProbeDone",
			"_LLM_Menu_OnInstalledTagsProbeDone",
			"_LLM_Menu_OnDeleteCachedModelDone"] {
		Body := _DriverFuncBody(Name)
		Assert(InStr(Body, "_LLM_Menu_AuxBuild(") > 0,
			Name . " must transfer changed auxiliary state to the retained owner")
		Assert(InStr(Body, "LLM_Menu_Build()") == 0,
			Name . " must never call the raw detached builder")
	}
	DeletePromptBody := _DriverFuncBody("_LLM_Menu_PromptDeleteCachedModel")
	Assert(InStr(DeletePromptBody, "_LLM_Menu_RecordDeleteReconcile") > 0,
		"delete dispatch must retain reconciliation before suspension can cancel it")

	ResumeBody := _DriverFuncBody("LLM_Menu_OnResume")
	Assert(InStr(ResumeBody, "_LLM_Menu_ServiceDeleteReconcile()") > 0,
		"resume must consume retained delete reconciliation")
	Assert(InStr(ResumeBody, "LLM_Menu_ServiceBuilds()") > 0,
		"resume must drain retained work without inventing a new generation")
	Assert(InStr(ResumeBody, "LLM_Menu_Build()") == 0)
}

_LMBCM_BootAndPostPullScheduleOwnedRequests() {
	Source := _DriverSourceNoComments()
	BootWorker := _DriverFuncBody("_TrayRootBuildBoot")
	Assert(InStr(BootWorker,
		"_TrayRootScheduleBootProjectionIfDisabled(") > 0
		&& InStr(BootWorker,
		'LLM_Menu_RequestBuild.Bind("boot")') > 0,
		"the published cold root must schedule an owned request, not the raw builder")
	PullBody := _DriverFuncBody("_LLM_Menu_PullModel")
	Assert(InStr(PullBody,
		'LLM_Menu_RequestBuild.Bind("post_pull")') > 0,
		"post-pull completion must retain its request across Suspend")
	Assert(InStr(Source, "SetTimer(LLM_Menu_Build,") == 0,
		"no timer may bypass the menu build owner")
}

_LMBCM_RawBuilderIsSinglePassAndCoordinatorOwned() {
	RawBody := _DriverFuncBody("LLM_Menu_Build")
	RootWorkerBody := _DriverFuncBody("_LLM_Menu_PublishRoot")
	FactoryBody := _DriverFuncBody("_LLM_Menu_GetBuildCoordinator")
	RequestBody := _DriverFuncBody("LLM_Menu_RequestBuild")
	Assert(RawBody != "" && RootWorkerBody != ""
		&& FactoryBody != "" && RequestBody != "")
	Assert(InStr(RawBody, "static _Building") == 0
		&& InStr(RawBody, "_RequestedGeneration") == 0,
		"the raw builder must be one pass; generation ownership belongs to the coordinator")
	Assert(InStr(FactoryBody, "LLMMenuBuildCoordinator(") > 0
		&& InStr(FactoryBody, "LLM_Menu_Build") > 0,
		"only the coordinator factory may receive the raw builder callback")
	Assert(InStr(RequestBody, ".Request(Reason)") > 0,
		"the public request boundary must delegate to the generation owner")
	Assert(InStr(RawBody,
		"RebuildTrayMenu(0, _LLM_Menu_PublishRoot, true, true)") > 0,
		"the detached LLM builder must request a narrow projection that promotes to a full rebuild on contention")
	Assert(InStr(RootWorkerBody, "initMenu(PublishAuthorizeFn)") > 0,
		"the LLM root projection must attach the staged submenu through the root publication fence")
	Assert(InStr(RootWorkerBody, "InitSubMenus(") == 0
		&& InStr(RootWorkerBody, "_HS_InvalidatePersonalCache(") == 0,
		"an LLM-only repaint must reuse sibling submenus instead of repeating the full personal/extensions scan")
}

Test("llm menu coordinator: every producer transfers to one owner (ahk-010-menu-build-coordinator-wiring)",
	_LMBCM_AllProducersUseTheCoordinator)
Test("llm menu coordinator: boot and post-pull timers schedule owned requests (ahk-010-menu-build-coordinator-wiring)",
	_LMBCM_BootAndPostPullScheduleOwnedRequests)
Test("llm menu coordinator: raw builder is single-pass and owner-only (ahk-010-menu-build-coordinator-wiring)",
	_LMBCM_RawBuilderIsSinglePassAndCoordinatorOwned)
