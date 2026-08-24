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

	for Name in ["_LLM_Ollama_PingPoll", "_LLM_Ollama_TagsPoll"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must exist for the AHK-003 ownership guard")
		OwnerPos := InStr(Body, "owner_generation != LLM_AuxGeneration()")
		ProcessPos := InStr(Body, "ProcessExist(pid)")
		Assert(OwnerPos > 0 && ProcessPos > 0 && OwnerPos < ProcessPos,
			Name . " must reject stale ownership before timeout or callback delivery")
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

Test("[ahk-003-meta] every backend lifecycle producer preserves ownership",
	_LBLM_BackendLifecycleProducersAreOwned)
