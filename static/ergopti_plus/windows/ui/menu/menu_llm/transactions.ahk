; ui/menu/menu_llm/transactions.ahk

; ==============================================================================
; MODULE: LLM Menu Configuration Transactions
; DESCRIPTION:
; Serializes every user-visible LLM menu mutation behind the process-wide
; terminal configuration barrier. A click mutates a detached deep clone, writes
; the complete candidate through the retained config owner, and only then swaps
; live Features and tray state in one short Critical section.
;
; FEATURES & RATIONALE:
; 1. Global admission prevents sibling config writers and lifecycle transitions
;    from interleaving with a menu action, even when they own another path.
; 2. Deep candidates keep nested profile arrays and override Maps unchanged when
;    a writer refuses the transaction.
; 3. Strict status checks reject false, string and malformed adapter results.
; 4. Inherited Critical is disabled across settlement, I/O and live callbacks.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================
; =========================================
; ======= 1/ Detached State Helpers =======
; =========================================
; =========================================

; Clones the complete mutable LLM state graph. Map.Clone() is shallow and would
; leave user_profiles/api_entries arrays shared with the live state, so a failed
; candidate edit could still leak through an aliased child.
LLM_Menu_DeepClone(Value) {
	if Value is Map {
		Copy := Map()
		for Key, Child in Value
			Copy[Key] := LLM_Menu_DeepClone(Child)
		return Copy
	}
	if Value is Array {
		Copy := []
		for Child in Value
			Copy.Push(LLM_Menu_DeepClone(Child))
		return Copy
	}
	return Value
}

/**
 * Converts the current tray state into a Map suitable for LLM_Engine_Init().
 * Kept in this definitions-only transaction module so the complete projection
 * can be exercised without registering actions.ahk's rescue hotkey.
 * @returns {Map} Options map.
 */
LLM_Menu_BuildOpts() {
	global _LLM_Menu
	return Map(
		"model",                   _LLM_Menu["model"],
		"profile_id",              _LLM_Menu["profile_id"],
		"user_profiles",           _LLM_Menu["user_profiles"],
		"n_predictions",           _LLM_Menu["n_predictions"],
		"min_words",               _LLM_Menu["min_words"],
		"max_words",               _LLM_Menu["max_words"],
		"language",                I18nGetLocale(),
		"debounce_ms",             _LLM_Menu["debounce_ms"],
		"ctx_chars",               _LLM_Menu["ctx_chars"],
		"temperature",             _LLM_Menu["temperature"],
		"instant_on_word_end",     _LLM_Menu["instant_on_word_end"],
		"after_hotstring",         _LLM_Menu["after_hotstring"],
		"reset_on_nav",            _LLM_Menu["reset_on_nav"],
		"disable_url_bars",        _LLM_Menu["disable_url_bars"],
		"disable_password_fields", _LLM_Menu["disable_password_fields"],
		"disabled_apps",           _LLM_Menu["disabled_apps"],
		"show_info_bar",           _LLM_Menu["show_info_bar"],
		"streaming",               _LLM_Menu["streaming"],
		"show_all_at_once",        _LLM_Menu["show_all_at_once"],
		"pred_indent",             _LLM_Menu["pred_indent"],
		"auto_raise_temp",         _LLM_Menu["auto_raise_temp"],
		"nav_modifiers",           _LLM_Menu["nav_modifiers"],
		"val_modifiers",           _LLM_Menu["val_modifiers"],
		"backend",                 _LLM_Menu["backend"],
		"ollama_port",             _LLM_Menu["ollama_port"],
		"api_entries",             _LLM_Menu["api_entries"],
		"api_entry_id",            _LLM_Menu["api_entry_id"],
		"inline_autotype",         _LLM_Menu["inline_autotype"],
		"app_profile_overrides",   _LLM_Menu["app_profile_overrides"]
	)
}

_LLM_Menu_SetCandidateValue(Candidate, Key, Value) {
	if !(Candidate is Map) || !(Key is String) || !Candidate.Has(Key)
		return false
	Candidate[Key] := Value
	return true
}

_LLM_Menu_ToggleCandidateBool(Candidate, Key) {
	if !(Candidate is Map) || !(Key is String) || !Candidate.Has(Key)
		return false
	Candidate[Key] := !Candidate[Key]
	return true
}

_LLM_Menu_ApplyAppPickerSelection(Candidate, Selected, Receipt) {
	if !(Candidate is Map) || !(Selected is Array)
			|| !Candidate.Has("disabled_apps")
		return false
	if !AppPicker_ClaimReceipt(Receipt, Candidate["disabled_apps"])
		return false
	Candidate["disabled_apps"] := LLM_Menu_DeepClone(Selected)
	return true
}

_LLM_Menu_PublishCandidate(CandidateFeatures, CandidateMenu) {
	global Features, _LLM_Menu
	if !(CandidateFeatures is Map) || !(CandidateMenu is Map)
		return false
	DisabledAppsChanged := _LLM_Menu.Has("disabled_apps")
		&& CandidateMenu.Has("disabled_apps")
		&& !AppPicker_SelectionsEqual(_LLM_Menu["disabled_apps"],
			CandidateMenu["disabled_apps"])
	PreviousCritical := Critical("On")
	try {
		Features := CandidateFeatures
		_LLM_Menu := CandidateMenu
		if DisabledAppsChanged
			AppPicker_AdvanceOwner("llm:disabled_apps")
		return true
	} finally Critical(PreviousCritical)
}





; =============================================
; =============================================
; ======= 2/ Single-Target Menu Commits =======
; =============================================
; =============================================

; Applies the ordinary post-commit tail shared by scalar LLM settings.
_LLM_Menu_ApplyStandardCommitted(*) {
	LLM_Engine_Init(LLM_Menu_BuildOpts())
	LLM_Menu_RequestBuild("standard_committed")
	return true
}

; Runs one detached config.toml transaction. Optional callables are narrow test
; seams; production uses the terminal bundle, pending-generation settlement,
; trigger quiescence, full collector and strict TOML writer.
LLM_Menu_CommitMutation(Context, MutateFn, ApplyFn := 0, WriterFn := 0,
		NotifyFn := 0, AcquireFn := 0, SettleFn := 0, QuiesceFn := 0,
		CollectFn := 0, PrepareFn := 0, PublishFn := 0) {
	PreviousCritical := Critical("Off")
	try return _LLM_Menu_CommitMutationNonCritical(Context, MutateFn, ApplyFn,
		WriterFn, NotifyFn, AcquireFn, SettleFn, QuiesceFn, CollectFn,
		PrepareFn, PublishFn)
	finally Critical(PreviousCritical)
}

_LLM_Menu_CommitMutationNonCritical(Context, MutateFn, ApplyFn, WriterFn,
		NotifyFn, AcquireFn, SettleFn, QuiesceFn, CollectFn, PrepareFn,
		PublishFn) {
	global ConfigurationFile, Features, _LLM_Menu
	if !(Context is String) || Context == "" || !HasMethod(MutateFn, "Call")
		return ConfigReportPersistenceFailure("the LLM menu mutation", NotifyFn,
			"the candidate mutation contract is invalid")
	if HasMethod(PrepareFn, "Call") != HasMethod(PublishFn, "Call")
		return ConfigReportPersistenceFailure(Context, NotifyFn,
			"candidate preparation requires a matching publication owner")
	if !IsSet(ConfigurationFile) || !(ConfigurationFile is String)
			|| ConfigurationFile == "" || !IsSet(Features) || !(Features is Map)
			|| !IsSet(_LLM_Menu) || !(_LLM_Menu is Map) {
		return ConfigReportPersistenceFailure(Context, NotifyFn,
			"the live LLM configuration state is not initialized")
	}
	try Bundle := HasMethod(AcquireFn, "Call")
		? AcquireFn.Call([ConfigurationFile])
		: LLM_Menu_AcquireLifecycleBundle([ConfigurationFile])
	catch as Err {
		return ConfigReportPersistenceFailure(Context, NotifyFn,
			"terminal configuration admission raised: " . Err.Message)
	}
	if !(Bundle is Object) {
		return ConfigReportPersistenceFailure(Context, NotifyFn,
			"another configuration transaction owns the global barrier")
	}
	PreparedOwner := 0
	PreparedProfileOwner := 0
	ProfileOwnerCommitted := false
	try {
		try Settled := HasMethod(SettleFn, "Call")
			? SettleFn.Call(Bundle) : _ConfigFullSaveSettleTerminal(Bundle)
		catch as Err {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"pending full-save settlement raised: " . Err.Message)
		}
		if !((Settled is Integer) && Settled == 1) {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"an older accepted full save could not be made durable")
		}
		try Quiesced := HasMethod(QuiesceFn, "Call")
			? QuiesceFn.Call(Bundle)
			: LLM_Menu_QuiesceTriggerForLifecycle(Bundle)
		catch as Err {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"LLM trigger quiescence raised: " . Err.Message)
		}
		if !((Quiesced is Integer) && Quiesced == 1) {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"LLM trigger recovery is incomplete")
		}

		CandidateFeatures := LLM_Menu_DeepClone(Features)
		CandidateMenu := LLM_Menu_DeepClone(_LLM_Menu)
		try Mutated := MutateFn.Call(CandidateMenu)
		catch as Err {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"candidate construction raised: " . Err.Message)
		}
		if !((Mutated is Integer) && Mutated == 1) {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"candidate construction was refused")
		}
		if !_LLM_Menu_SyncToFeatures(CandidateFeatures, CandidateMenu) {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"the detached LLM state could not be reconciled into Features")
		}
		try PreparedProfileOwner :=
			_LLM_Menu_PrepareProfileOwnerCandidate(CandidateMenu)
		catch as Err {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"profile hotkey owner preparation raised: " . Err.Message)
		}
		if !(PreparedProfileOwner is Map) {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"profile hotkey owner preparation was refused")
		}
		try Updates := HasMethod(CollectFn, "Call")
			? CollectFn.Call(CandidateFeatures, CandidateMenu)
			: _ConfigCollectFullSaveUpdates(CandidateFeatures, CandidateMenu)
		catch as Err {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"candidate serialization raised: " . Err.Message)
		}
		if !(Updates is Array) {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"candidate serialization returned no update batch")
		}
		if HasMethod(PrepareFn, "Call") {
			; A false result is an ordinary native refusal. An exception means the
			; preparation owner could not restore a process-wide invariant (for
			; example the current HotIf criterion), so it must escape fail-fast.
			; The surrounding finally still releases terminal admission.
			PreparedOwner := PrepareFn.Call(CandidateMenu)
			if !(PreparedOwner is Object) {
				return ConfigReportPersistenceFailure(Context, NotifyFn,
					"candidate preparation was refused")
			}
		}
		OwnerToken := _ConfigWriteLeaseSelectOwner(Bundle, ConfigurationFile)
		if !(OwnerToken is Object) {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"the terminal bundle does not own config.toml")
		}
		if !ConfigCommitBorrowedUpdates(OwnerToken, ConfigurationFile, Updates,
				Context, WriterFn, NotifyFn)
			return false
		try {
			PreviousCritical := Critical("On")
			try {
				if !_LLM_Menu_CommitProfileOwnerCandidate(
						PreparedProfileOwner)
					return ConfigReportPersistenceFailure(Context, NotifyFn,
						"config.toml is durable but the profile hotkey owner commit was refused",
						false)
				ProfileOwnerCommitted := true
				Published := HasMethod(PublishFn, "Call")
					? PublishFn.Call(CandidateFeatures, CandidateMenu, PreparedOwner)
					: _LLM_Menu_PublishCandidate(CandidateFeatures, CandidateMenu)
			} finally Critical(PreviousCritical)
		}
		catch as Err {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"config.toml is durable but live publication raised: "
				. Err.Message, false)
		}
		if !((Published is Integer) && Published == 1) {
			if PreparedProfileOwner.Get("changed", false)
				_LLM_NavEventOwnerQuarantine(
					"Durable profile state could not be published after its native owner commit")
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"config.toml is durable but live publication was refused", false)
		}
		if HasMethod(ApplyFn, "Call") {
			try Applied := ApplyFn.Call(CandidateMenu)
			catch as Err {
				return ConfigReportPersistenceFailure(Context, NotifyFn,
					"config.toml is durable but live application raised: "
					. Err.Message, false)
			}
			if !((Applied is Integer) && Applied == 1) {
				return ConfigReportPersistenceFailure(Context, NotifyFn,
					"config.toml is durable but live application was refused", false)
			}
		}
		return true
	} finally {
		if PreparedProfileOwner is Map && !ProfileOwnerCommitted
			_LLM_Menu_AbortProfileOwnerCandidate(PreparedProfileOwner)
		_ConfigWriteTerminalRelease(Bundle)
	}
}





; ===========================================
; ===========================================
; ======= 3/ API Multi-Target Commits =======
; ===========================================
; ===========================================

; Reports a typed transition failure through both the developer log and the
; ordinary user-visible persistence backstop. Result details are diagnostic;
; only ConfigTransitionResultIs authorizes a state transition.
_LLM_Menu_ReportApiTransitionFailure(Context, Result, NotifyFn := 0,
		StateUnchanged := true) {
	ConfigTransitionLogFailure("LLM.ApiEntries", Result)
	Detail := (Result is Map) && Result.Has("kind")
		&& (Result["kind"] is String)
		? "the API-entry transition ended as '" . Result["kind"] . "'"
		: "the API-entry transition returned a malformed result"
	return ConfigReportPersistenceFailure(Context, NotifyFn, Detail,
		StateUnchanged)
}

; Commits config.toml and api_entries.json as one crash-recoverable authority
; change. The candidate is cloned only after global admission and stale-WAL
; recovery; neither global becomes observable until both new images are durable
; and the committed-new journal has been verified and removed.
LLM_Menu_CommitApiEntriesMutation(Context, MutateFn, ApplyFn := 0,
		Port := 0, NotifyFn := 0, AcquireFn := 0, SettleFn := 0,
		QuiesceFn := 0, CollectFn := 0, BuildConfigFn := 0,
		SerializeFn := 0, PauseFn := 0) {
	PreviousCritical := Critical("Off")
	try return _LLM_Menu_CommitApiEntriesMutationNonCritical(Context,
		MutateFn, ApplyFn, Port, NotifyFn, AcquireFn, SettleFn, QuiesceFn,
		CollectFn, BuildConfigFn, SerializeFn, PauseFn)
	finally Critical(PreviousCritical)
}

_LLM_Menu_CommitApiEntriesMutationNonCritical(Context, MutateFn, ApplyFn,
		Port, NotifyFn, AcquireFn, SettleFn, QuiesceFn, CollectFn,
		BuildConfigFn, SerializeFn, PauseFn) {
	global _PathsFile, ConfigurationFile, Features, _LLM_Menu
	if !(Context is String) || Context == "" || !HasMethod(MutateFn, "Call")
		return ConfigReportPersistenceFailure("the LLM API-entry mutation",
			NotifyFn, "the candidate mutation contract is invalid")
	if !IsSet(_PathsFile) || !(_PathsFile is String) || _PathsFile == ""
			|| !IsSet(ConfigurationFile) || !(ConfigurationFile is String)
			|| ConfigurationFile == "" || !IsSet(Features) || !(Features is Map)
			|| !IsSet(_LLM_Menu) || !(_LLM_Menu is Map) {
		return ConfigReportPersistenceFailure(Context, NotifyFn,
			"the live LLM configuration state is not initialized")
	}
	ApiPath := _LLM_Menu_ApiEntriesPath()
	if !(ApiPath is String) || ApiPath == "" {
		return ConfigReportPersistenceFailure(Context, NotifyFn,
			"api_entries.json has no resolved path")
	}
	try ResolvedPort := _ConfigTransitionRuntimePort(Port)
	catch as Err {
		return ConfigReportPersistenceFailure(Context, NotifyFn,
			"the transition filesystem port raised: " . Err.Message)
	}
	try AcquireResult := ConfigTransitionAcquireLifecycleBundle(_PathsFile,
		[ConfigurationFile, ApiPath], ResolvedPort, AcquireFn, SettleFn)
	catch as Err {
		return ConfigReportPersistenceFailure(Context, NotifyFn,
			"terminal transition admission raised: " . Err.Message)
	}
	if !ConfigTransitionResultIs(AcquireResult, "bundle_acquired")
		return _LLM_Menu_ReportApiTransitionFailure(Context, AcquireResult,
			NotifyFn)
	Bundle := AcquireResult["bundle"]
	ReleaseBundle := true
	try {
		try Quiesced := HasMethod(QuiesceFn, "Call")
			? QuiesceFn.Call(Bundle)
			: LLM_Menu_QuiesceTriggerForLifecycle(Bundle)
		catch as Err {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"LLM trigger quiescence raised: " . Err.Message)
		}
		if !((Quiesced is Integer) && Quiesced == 1) {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"LLM trigger recovery is incomplete")
		}

		CandidateFeatures := LLM_Menu_DeepClone(Features)
		CandidateMenu := LLM_Menu_DeepClone(_LLM_Menu)
		try Mutated := MutateFn.Call(CandidateMenu)
		catch as Err {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"candidate construction raised: " . Err.Message)
		}
		if !((Mutated is Integer) && Mutated == 1) {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"candidate construction was refused")
		}
		if !_LLM_Menu_SyncToFeatures(CandidateFeatures, CandidateMenu) {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"the detached LLM state could not be reconciled into Features")
		}
		try Updates := HasMethod(CollectFn, "Call")
			? CollectFn.Call(CandidateFeatures, CandidateMenu)
			: _ConfigCollectFullSaveUpdates(CandidateFeatures, CandidateMenu)
		catch as Err {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"candidate serialization raised: " . Err.Message)
		}
		if !(Updates is Array) {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"candidate serialization returned no update batch")
		}

		try ConfigBuild := HasMethod(BuildConfigFn, "Call")
			? BuildConfigFn.Call(ConfigurationFile, Updates)
			: TOML_BuildUpdatedContent(ConfigurationFile, Updates)
		catch as Err {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"config.toml rendering raised: " . Err.Message)
		}
		if !(ConfigBuild is Map) || !ConfigBuild.Has("status")
				|| !ConfigBuild.Has("kind") || !ConfigBuild.Has("content")
				|| !ConfigBuild.Has("source_present")
				|| !ConfigBuild.Has("source_content")
				|| !(ConfigBuild["status"] is String)
				|| ConfigBuild["status"] != "ok"
				|| !(ConfigBuild["kind"] is String)
				|| ConfigBuild["kind"] != "rendered"
				|| !(ConfigBuild["content"] is String) {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"config.toml could not be rendered from its exact old image")
		}
		try ApiContent := HasMethod(SerializeFn, "Call")
			? SerializeFn.Call(CandidateMenu)
			: _LLM_Menu_SerializeApiEntries(CandidateMenu)
		catch as Err {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"api_entries.json serialization raised: " . Err.Message)
		}
		if !(ApiContent is String) {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"api_entries.json serialization was refused")
		}

		ConfigExpected := ConfigTransitionExpectedOld(
			ConfigBuild["source_present"], ConfigBuild["source_content"],
			ResolvedPort)
		ApiSnapshotResult := _ConfigTransitionReadSnapshot(ResolvedPort, ApiPath)
		if !(ConfigExpected is Map)
				|| !(ApiSnapshotResult is Map)
				|| !ApiSnapshotResult.Has("status")
				|| !(ApiSnapshotResult["status"] is String)
				|| ApiSnapshotResult["status"] != "ok"
				|| !ApiSnapshotResult.Has("snapshot")
				|| !(ApiSnapshotResult["snapshot"] is Map) {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"the exact pre-transition file images could not be verified")
		}
		ApiSnapshot := ApiSnapshotResult["snapshot"]
		ApiExpected := Map("present", ApiSnapshot["present"],
			"hash", ApiSnapshot["hash"])
		TargetSpecs := [
			ConfigTransitionPresentTarget(ConfigurationFile,
				ConfigBuild["content"], ConfigExpected),
			ConfigTransitionPresentTarget(ApiPath, ApiContent, ApiExpected)
		]
		CommitResult := ConfigTransitionCommitOwned(_PathsFile, TargetSpecs,
			Bundle, ResolvedPort, PauseFn)
		if !ConfigTransitionResultIs(CommitResult, "committed_new") {
			if CommitResult.Has("barrier_retained")
					&& (CommitResult["barrier_retained"] is Integer)
					&& CommitResult["barrier_retained"] == 1
				ReleaseBundle := false
			return _LLM_Menu_ReportApiTransitionFailure(Context, CommitResult,
				NotifyFn)
		}

		; This action keeps running, unlike a paths change followed by Reload.
		; Resolve committed-new now so no discoverable WAL or artifact survives
		; after global admission reopens.
		CleanupResult := ConfigTransitionRecoverOwned(_PathsFile, Bundle,
			ResolvedPort)
		if !ConfigTransitionResultIs(CleanupResult, "recovered_new") {
			ReleaseBundle := false
			ConfigTransitionRetainBarrier(Bundle)
			; committed_new already proves both targets durable. Publish the same
			; candidate so RAM never advertises the rolled-back old authority while
			; the retained barrier forces lifecycle recovery of the WAL.
			Published := _LLM_Menu_PublishApiEntriesCandidate(CandidateFeatures,
				CandidateMenu)
			if Published && HasMethod(ApplyFn, "Call")
				try ApplyFn.Call(CandidateMenu)
			return _LLM_Menu_ReportApiTransitionFailure(Context, CleanupResult,
				NotifyFn, false)
		}
		if !_LLM_Menu_PublishApiEntriesCandidate(CandidateFeatures, CandidateMenu) {
			return ConfigReportPersistenceFailure(Context, NotifyFn,
				"both files are durable but live publication was refused", false)
		}
		if HasMethod(ApplyFn, "Call") {
			try Applied := ApplyFn.Call(CandidateMenu)
			catch as Err {
				return ConfigReportPersistenceFailure(Context, NotifyFn,
					"both files are durable but live application raised: "
					. Err.Message, false)
			}
			if !((Applied is Integer) && Applied == 1) {
				return ConfigReportPersistenceFailure(Context, NotifyFn,
					"both files are durable but live application was refused", false)
			}
		}
		return true
	} finally {
		if ReleaseBundle
			_ConfigWriteTerminalRelease(Bundle)
	}
}
