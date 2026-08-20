; tests/meta/test_llm_menu_persistence_transactions_20260813.ahk

; ==============================================================================
; MODULE: LLM menu persistence transaction class guard
; DESCRIPTION:
; Enumerates the complete persistent action class. Every user path must enter a
; detached transaction (or the dedicated trigger journal), and API CRUD must
; keep config.toml plus api_entries.json under one transition WAL.
; ==============================================================================

#Requires AutoHotkey v2.0

_LMPT_AssertTransactionBody(FuncName, RequiredCall) {
	Body := _DriverFuncBody(FuncName)
	Assert(Body != "", FuncName . " must remain an auditable production entry point")
	Assert(InStr(Body, RequiredCall) > 0,
		FuncName . " must route through " . RequiredCall
		. " instead of mutating live LLM state before persistence")
	Assert(InStr(Body, "LLM_Menu_SaveConfig(") == 0,
		FuncName . " must not use the legacy mutate-then-full-save path")
}

_LMPT_EveryPersistentActionUsesDetachedTransaction() {
	Standard := [
		"LLM_Menu_OnToggle", "LLM_Menu_OnInstantToggle", "LLM_Menu_ToggleBool",
		"LLM_Menu_SetBackend", "LLM_Menu_SetModel", "LLM_Menu_SetProfile",
		"LLM_Menu_SetN", "LLM_Menu_SetIndent", "LLM_Menu_OnAppPickerSave",
		"_LLM_Menu_AddOverrideForActiveApp", "_LLM_Menu_ClearOverrideFor",
		"_LLM_Menu_ToggleAutoProfile", "LLM_Menu_OnUserProfileClick",
		"LLM_Menu_PromptCreateProfile", "LLM_Menu_PromptEditProfile",
		"LLM_Menu_CloneActiveBuiltinProfile", "LLM_Menu_PromptNumeric",
		"_LLM_AssignAndRebuild", "LLM_Menu_PromptOllamaPort",
		"LLM_Menu_ResetOllamaPort", "LLM_Menu_PromptMaxWords",
		"LLM_Menu_PromptTemperature", "LLM_Menu_PromptNavModifiers",
		"LLM_Menu_PromptValModifiers", "_LLM_Menu_SelectApiEntry",
		"_PromptEdWeb_PersistProfile", "LLM_Menu_EnsureModelReady"
	]
	for FuncName in Standard
		_LMPT_AssertTransactionBody(FuncName, "LLM_Menu_CommitMutation(")
	for FuncName in ["_LLM_Menu_PromptApiEntry",
			"_LLM_Menu_RemoveActiveApiEntry"]
		_LMPT_AssertTransactionBody(FuncName,
			"LLM_Menu_CommitApiEntriesMutation(")
	_LMPT_AssertTransactionBody("LLM_Menu_PromptTriggerShortcut",
		"LLM_Menu_CommitTriggerShortcut(")
}
Test("meta LLM menu: all persistent handlers use detached transactions "
	. "(llm-menu-persistence-class-guard)",
	_LMPT_EveryPersistentActionUsesDetachedTransaction)

_LMPT_ApiTransactionUsesOneWalAndPublishesLast() {
	Body := _DriverFuncBody("_LLM_Menu_CommitApiEntriesMutationNonCritical")
	Assert(Body != "", "the API multi-target transaction implementation must exist")
	AcquirePos := InStr(Body, "ConfigTransitionAcquireLifecycleBundle(")
	ConfigTargetPos := InStr(Body,
		"ConfigTransitionPresentTarget(ConfigurationFile")
	ApiTargetPos := InStr(Body, "ConfigTransitionPresentTarget(ApiPath")
	CommitPos := InStr(Body, "ConfigTransitionCommitOwned(")
	RecoverPos := InStr(Body, "ConfigTransitionRecoverOwned(")
	PublishPos := InStr(Body, "_LLM_Menu_PublishCandidate(")
	Assert(AcquirePos > 0 && ConfigTargetPos > AcquirePos
		&& ApiTargetPos > ConfigTargetPos && CommitPos > ApiTargetPos
		&& RecoverPos > CommitPos && PublishPos > RecoverPos,
		"API CRUD must acquire global admission, journal config.toml and "
		. "api_entries.json together, verify committed-new cleanup, and only then "
		. "publish RAM")
	Assert(InStr(Body, "ConfigTransitionExpectedOld(") > 0
		&& InStr(Body, "_ConfigTransitionReadSnapshot(") > 0,
		"both API transition targets must pin the exact pre-commit authority")
	Assert(InStr(Body, "_ConfigFullSaveSettleTerminal") == 0,
		"transition acquisition owns pending-generation settlement exactly once")
}
Test("meta LLM menu: API CRUD journals both authorities before publication "
	. "(llm-api-entry-two-target-wal-guard)",
	_LMPT_ApiTransactionUsesOneWalAndPublishesLast)

_LMPT_ApiIdRoundTripsAndPromptEditorRechecksEpoch() {
	AppendBody := _DriverFuncBody("_LLM_Menu_AppendPersistedUpdates")
	RestoreBody := _DriverFuncBody("_LLM_Menu_RestoreSavedOptsOnce")
	BuildBody := _DriverFuncBody("LLM_Menu_BuildSavedOpts")
	Assert(InStr(AppendBody, 'Key: "api_entry_id"') > 0
		&& InStr(BuildBody, '"api_entry_id"') > 0
		&& InStr(RestoreBody, '"api_entry_id"') > 0,
		"the active API entry must round-trip through config.toml instead of "
		. "silently reverting to the first JSON entry after restart")
	ContextBody := _DriverFuncBody("_PromptEdWeb_ApplyProfileForContext")
	PersistBody := _DriverFuncBody("_PromptEdWeb_PersistProfile")
	Assert(InStr(ContextBody, "_PromptEdWeb_IsCurrentContext(EditId, Epoch)") > 0,
		"the candidate mutator must reject an epoch that changed while terminal "
		. "admission or WAL recovery yielded")
	Assert(InStr(PersistBody, "LLM_Menu_CommitMutation(") > 0
		&& InStr(PersistBody, "_PromptEdWeb_ApplyProfileForContext") > 0,
		"production prompt-editor saves must recheck their bound context inside "
		. "the detached transaction")
}
Test("meta LLM menu: API selection round-trips and prompt editor rechecks epoch "
	. "(llm-api-id-prompt-epoch-guard)",
	_LMPT_ApiIdRoundTripsAndPromptEditorRechecksEpoch)

