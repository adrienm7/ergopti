; tests/meta/test_llm_backend_lifecycle_ownership.ahk

; ==============================================================================
; MODULE: LLM backend lifecycle producer coverage
; DESCRIPTION:
; AHK-003 spans every deferred backend producer and both Ollama poll families.
; This guard inventories that class so a sibling timer cannot silently keep the
; old backend alive after a switch or deliver a timeout without ownership.
; ==============================================================================

#Requires AutoHotkey v2.0

_LBLM_CountOccurrences(Haystack, Needle) {
	if Needle == ""
		return 0
	Count := 0
	Pos := 1
	while (Found := InStr(Haystack, Needle, true, Pos)) {
		Count += 1
		Pos := Found + StrLen(Needle)
	}
	return Count
}

_LBLM_BackendLifecycleProducersAreOwned() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must be readable for AHK-003")
	AssertEqual(0, _LBLM_CountOccurrences(Src,
		"SetTimer(() => LLM_Menu_BootstrapCurrentBackend"),
		"no backend bootstrap producer may reinterpret mutable state from an anonymous timer")
	ScheduleCalls := _LBLM_CountOccurrences(Src,
		"LLM_Menu_ScheduleBackendLifecycle(")
	Assert(ScheduleCalls >= 6,
		"boot, toggle, backend change, API-entry change and resume must share the owned scheduler")
	ModelApplyBody := _DriverFuncBody("_LLM_Menu_ApplyModelCommitted")
	Assert(InStr(ModelApplyBody, "LLM_Menu_ApplyModelLifecycleCommitted(") > 0,
		"model publication must enter the definitions-only lifecycle owner before runtime apply")
	for Name in ["_LLM_Menu_SelectApiEntry", "_LLM_Menu_PromptApiEntry",
			"_LLM_Menu_RemoveActiveApiEntry"] {
		Body := _DriverFuncBody(Name)
		Assert(InStr(Body, "_LLM_Menu_ApplyApiEntriesCommitted") > 0,
			Name . " must re-run API lifecycle admission after its durable commit")
	}
	TriggerBody := _DriverFuncBody("LLM_Menu_TriggerPrediction")
	Assert(InStr(TriggerBody, "_LLM_Menu_BackendIsReadyForUse()") > 0,
		"manual prediction must use backend-specific readiness")
	Assert(InStr(TriggerBody, "LLM_Deps_IsReady()") = 0,
		"manual API prediction must not inherit Ollama readiness")

	for Name in ["_LLM_Ollama_PingPoll", "_LLM_Ollama_TagsPoll",
			"_LLM_Ollama_DeletePoll"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must exist for the AHK-003 ownership guard")
		OwnerPos := InStr(Body, "!LLM_AuxIsCurrent(Owner)")
		ProcessPos := InStr(Body, "ProcessExist(pid)")
		Assert(OwnerPos > 0 && ProcessPos > 0 && OwnerPos < ProcessPos,
			Name . " must reject stale ownership before timeout or callback delivery")
	}

	for Producer in Map(
		"_LLM_Menu_FireHealthProbe", '"menu_health"',
		"_LLM_Menu_FireInstalledTagsProbe", '"menu_tags"',
		"_LLM_Menu_PromptDeleteCachedModel", '"menu_delete:"') {
		Body := _DriverFuncBody(Producer)
		Assert(Body != "", Producer . " must remain an inventoried auxiliary producer")
		Assert(InStr(Body, "_LLM_Menu_BeginOllamaAux(") > 0,
			Producer . " must publish its owner before dispatch")
	}
	ApiBody := _DriverFuncBody("_LLM_Menu_PromptApiEntry")
	Assert(ApiBody != "", "API-entry validation producer must remain reachable")
	Assert(InStr(ApiBody, 'LLM_AuxBegin("api_validation:"') > 0,
		"API validation must bind the stable entry identity before dispatch")
	Assert(InStr(ApiBody, "ValidationOwner), ValidationOwner)") > 0,
		"the callback and remote poll must share the same validation owner")

	CancelBody := _DriverFuncBody("LLM_Menu_CancelOllamaOwnership")
	Assert(CancelBody != "", "the Ollama ownership retirement boundary must exist")
	Assert(InStr(CancelBody, '_LLM_Menu_ResetOllamaAuxState') > 0,
		"backend and endpoint transfer must expire health and installed-tag state")
	for Transport in ["LLM_OllamaIsRunning_Async",
			"LLM_OllamaListModels_Async", "LLM_OllamaDeleteModel_Async"] {
		Body := _DriverFuncBody(Transport)
		Assert(InStr(Body, "LLM_AuxBindResources(Owner") > 0,
			Transport . " must bind its process and finalizer to the owner receipt")
	}
	RemoteBody := _DriverFuncBody("LLM_RemoteIsReady_Async")
	Assert(InStr(RemoteBody, "LLM_AuxBindResources(Owner") > 0,
		"remote validation must bind its exact WinHTTP abort resource")
	ApiTransactionBody := _DriverFuncBody("_LLM_Menu_CommitApiEntriesMutationNonCritical")
	Assert(InStr(ApiTransactionBody, "_LLM_Menu_PublishApiEntriesCandidate(") > 0,
		"API-entry transaction must retire validations at its publication boundary")
	for PortProducer in ["LLM_Menu_PromptOllamaPort", "LLM_Menu_ResetOllamaPort"] {
		Body := _DriverFuncBody(PortProducer)
		Assert(InStr(Body, "_LLM_Menu_PrepareOllamaPortCandidate") > 0
				&& InStr(Body, "_LLM_Menu_PublishOllamaPortCandidate") > 0,
			PortProducer . " must retire endpoint A before publishing endpoint B")
	}

	CheckBody := _DriverFuncBody("LLM_Deps_CheckAndInstall")
	Assert(CheckBody != "", "LLM_Deps_CheckAndInstall must exist")
	EpochPos := InStr(CheckBody, "captured_epoch := _LLM_Deps_Epoch")
	TimerPos := InStr(CheckBody, "SetTimer(")
	Assert(EpochPos > 0 && TimerPos > EpochPos,
		"the dependency timer must capture its epoch before it is armed")
	Assert(InStr(CheckBody, "show_ui, captured_epoch)", true, TimerPos) > TimerPos,
		"the deferred dependency callback must carry the captured epoch, not reread the current one")
	for Name in ["LLM_Deps_AsyncCheck", "LLM_Deps_DoCheck",
			"LLM_Deps_RunInstaller", "LLM_Deps_PollServerReady"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must exist for the dependency ownership guard")
		Assert(InStr(Body, "captured_epoch != _LLM_Deps_Epoch") > 0,
			Name . " must reject a preempted dependency generation")
	}
}

_LBLM_OllamaReadinessWritersAreOwned() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must be readable for AHK2-13")
	AssertEqual(6, _LBLM_CountOccurrences(Src, "_LLM_Ollama_IsReady :="),
		"every Ollama readiness writer must remain in the reviewed owner inventory")

	FinalizeBody := _DriverFuncBody("_LLM_Engine_FinalizeRequest")
	BackendGuardPos := InStr(FinalizeBody,
		'state.Get("backend", "") == "ollama"')
	ReadyWritePos := InStr(FinalizeBody, "_LLM_Ollama_IsReady := true")
	Assert(BackendGuardPos > 0 && ReadyWritePos > BackendGuardPos,
		"the common prediction finalizer may publish readiness only for Ollama")

	for Owner in [
		"_LLM_Ollama_OnWarmupDone",
		"LLM_OllamaNoteInferenceSuccess",
		"_LLM_Menu_WarmCurrentOllamaModel"
	] {
		Body := _DriverFuncBody(Owner)
		Assert(Body != "", Owner . " must remain an explicit Ollama readiness owner")
		Assert(InStr(Body, "_LLM_Ollama_IsReady :=") > 0,
			Owner . " must retain its inventoried readiness publication")
	}
}

Test("[ahk-003-meta] every backend lifecycle producer preserves ownership",
	_LBLM_BackendLifecycleProducersAreOwned)
Test("[ahk2-13-meta] every Ollama readiness writer remains backend-owned",
	_LBLM_OllamaReadinessWritersAreOwned)
