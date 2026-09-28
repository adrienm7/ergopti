; infra/config_scope.ahk

; ==============================================================================
; MODULE: Scoped Configuration Lifecycle
; DESCRIPTION:
; Publishes one manifest-owned config.toml scope through the admitted builder and
; existing conditional WAL. The terminal bundle survives until reload completion
; or verified rollback. Separate-file presets require a different coordinator.
; ==============================================================================

/**
 * Starts one scoped configuration transition without claiming reload completion.
 * @param {String} ScopeId Manifest scope identifier.
 * @param {String} Mode "recommended" or "clear".
 * @param {Map} Providers Explicit runtime inventory callbacks.
 * @param {Map} Options Injected paths and effect ports for owner tests.
 * @returns {Map} Mutable receipt: pending, committed, refused, or recovery_required.
 */
ConfigScopeApply(ScopeId, Mode, Providers, Options := unset) {
	if !IsSet(Options)
		Options := Map()
	if !(Options is Map) || !(Providers is Map)
		throw TypeError("Scoped configuration requires explicit owner maps.")
	Owners := Options.Get("owners", Map("action_parameter_domain", ConfigScopeActionParameterDomain))
	Plan := ManifestScopePlan(ScopeId, Mode, [], Owners)
	if Plan.presets.Length
		throw ValueError("This scope requires a separate-file preset coordinator.")
	Operations() {
		Inventory := ManifestScopeInventory(ScopeId, Providers, Owners)
		return ManifestScopePlan(ScopeId, Mode, Inventory, Owners).operations
	}
	return ConfigScopeCommitOperations(ScopeId, Mode, Operations, Options)
}

/**
 * Publishes owner-validated operations using the same admitted reload transaction.
 * @param {String} ScopeId Receipt domain, without changing operation ownership.
 * @param {String} Mode Receipt action.
 * @param {Func} OperationsFn Validates and builds operations inside the lease.
 * @param {Map} Options Lifecycle and effect ports.
 * @param {Object|Integer} FileOwner Optional owner of additional TOML images.
 * @returns {Map} Pending or terminal transaction receipt.
 */
ConfigScopeCommitOperations(ScopeId, Mode, OperationsFn, Options, FileOwner := 0) {
	global ConfigurationFile, _PathsFile
	Path := Options.Has("path") ? Options["path"] : ConfigurationFile
	Locator := Options.Has("locator") ? Options["locator"] : _PathsFile
	Port := Options.Get("port", 0)
	ReloadFn := Options.Get("reload", ReloadPreservingSuspend)
	BackupFn := Options.Get("backup", FSWriteCreateDurable)
	NotifyFn := Options.Get("notify", 0)
	Stamp := Options.Get("stamp", FormatTime(A_Now, "yyyyMMdd-HHmmss") . "-" . A_TickCount)
	Backup := ConfigUnusedKeysBackupPath(Path, Stamp)
	Receipt := Map("status", "refused", "scope", ScopeId, "mode", Mode, "backup", Backup)
	Paths := [Path]
	if FileOwner is Object {
		for OwnedPath in FileOwner.paths
			Paths.Push(OwnedPath)
	}
	Acquired := ConfigTransitionAcquireLifecycleBundle(Locator, Paths, Port,
		Options.Get("acquire", 0), Options.Get("settle", 0))
	if !ConfigTransitionResultIs(Acquired, "bundle_acquired") {
		Receipt["detail"] := Acquired
		ConfigTransitionLogFailure("ConfigScope", Acquired)
		return Receipt
	}
	Bundle := Acquired["bundle"]
	Transferred := false
	Targets := []
	Transition := 0
	Rollback() {
		try Resolution := ConfigTransitionRollbackOwned(Locator, Bundle, Port)
		catch as Err
			Resolution := Map("status", "fatal", "kind", "rollback_threw", "detail", Err.Message)
		Receipt["detail"] := Resolution
		if ConfigTransitionResultIs(Resolution, "absent") || ConfigTransitionResultIs(Resolution, "recovered_old") {
			Receipt["status"] := "refused"
			return false
		}
		Receipt["status"] := "recovery_required"
		ConfigTransitionRetainBarrier(Bundle)
		ConfigTransitionLogFailure("ConfigScope", Resolution)
		return true
	}
	Refused(*) {
		Retained := false
		try {
			Retained := Rollback()
			ConfigReportPersistenceFailure("the scoped configuration reload", NotifyFn,
				"the replacement driver refused the configuration handoff", !Retained)
		} finally {
			if !Retained
				_ConfigWriteTerminalRelease(Bundle)
		}
	}
	Build() {
		Rows := _ConfigPrepareTypedUpdates(OperationsFn.Call())
		Image := TOML_BuildUpdatedContent(Path, Rows)
		if !(Image is Map) || Image.Get("status", "") != "ok" || Image.Get("kind", "") != "rendered"
			throw Error("The scoped configuration image could not be rendered.")
		Expected := ConfigTransitionExpectedOld(Image["source_present"], Image["source_content"], Port)
		Targets := [ConfigTransitionPresentTarget(Path, Image["content"], Expected)]
		Images := [{ path: Path, image: Image }]
		if FileOwner is Object {
			for Candidate in FileOwner.Build() {
				if !(_ConfigWriteLeaseSelectOwner(Bundle, Candidate.path) is Object)
					throw Error("A scoped file candidate has no admitted owner.")
				Extra := Candidate.image
				if !(Extra is Map) || Extra.Get("status", "") != "ok" || Extra.Get("kind", "") != "rendered"
					throw Error("A scoped file candidate could not be rendered.")
				if Extra["content"] == Extra["source_content"]
					continue
				ExpectedExtra := ConfigTransitionExpectedOld(Extra["source_present"], Extra["source_content"], Port)
				Targets.Push(ConfigTransitionPresentTarget(Candidate.path, Extra["content"], ExpectedExtra))
				Images.Push(Candidate)
			}
			; The journal owns its format and capacity. Validate the complete
			; detached cohort before creating even the first user backup.
			Normalized := _ConfigTransitionNormalizePath(Locator)
			Built := _ConfigTransitionBuildPreparedRecord(Normalized, Targets,
				_ConfigTransitionRuntimePort(Port), _ConfigTransitionNewId())
			if !ConfigTransitionResultIs(Built, "record_built")
				throw Error("The complete scoped cohort cannot enter the journal: " . Built["kind"])
			if !(_ConfigTransitionSerialize(Built["record"], Normalized) is String)
				throw Error("The complete scoped cohort exceeds the journal format.")
		}
		Receipt["backups"] := []
		for Candidate in Images {
			BackupPath := ConfigUnusedKeysBackupPath(Candidate.path, Stamp)
			OldContent := Candidate.image["source_content"]
			BackedUp := BackupFn.Call(BackupPath, OldContent)
			if !(BackedUp is Integer) || BackedUp != 1 || !FSUtf8ExactMatches(BackupPath, OldContent)
				throw Error("The exclusive scoped backup could not be created and verified.")
			Receipt["backups"].Push(BackupPath)
		}
		return { updates: Rows }
	}
	Publish(_Path, _Rows) {
		Transition := ConfigTransitionCommitOwned(Locator, Targets, Bundle, Port)
		Receipt["detail"] := Transition
		return ConfigTransitionResultIs(Transition, "committed_new")
	}
	try {
		Prepare := Options.Get("prepare", ConfigScopePrepareLifecycle)
		Prepared := Prepare.Call(Path, Bundle)
		if !(Prepared is Integer) || Prepared != 1 {
			ConfigReportPersistenceFailure("the scoped configuration", NotifyFn,
				"native trigger recovery refused lifecycle preparation")
			return Receipt
		}
		if !ConfigCommitBuilt(Path, "the scoped configuration", Build, Publish, NotifyFn, Bundle) {
			; A throwing writer may have prepared a WAL before its error reached
			; the gateway. Resolve that debt before reopening admission.
			Transferred := Rollback()
			return Receipt
		}
		Receipt["status"] := "pending"
		try Launched := ReloadFn.Call((*) => Receipt["status"] := "committed", Bundle, Refused)
		catch as Err {
			Launched := false
			Receipt["reload_error"] := Err.Message
		}
		if (Launched is Integer) && Launched == 1 {
			Transferred := true
			return Receipt
		}
		Transferred := Rollback()
		ConfigReportPersistenceFailure("the scoped configuration reload", NotifyFn,
			"the replacement driver was not launched", !Transferred)
		return Receipt
	} finally {
		if !Transferred
			_ConfigWriteTerminalRelease(Bundle)
	}
}

; Stabilize the existing native/journal owner before rendering the new image.
; Otherwise a later reload reconciliation could republish old trigger settings.
ConfigScopePrepareLifecycle(Path, Bundle) {
	Quiesced := LLM_Menu_QuiesceTriggerForLifecycle(Bundle)
	if !(Quiesced is Integer) || Quiesced != 1
		return false
	Prepared := LLM_TriggerJournalPrepareDestructive(Path, Bundle)
	return (Prepared is Integer) && Prepared == 1
}

; The existing action owner validates grammar and catalogue parameter capability.
ConfigScopeActionParameterDomain(Path) {
	Prefix := "action_parameters."
	if SubStr(Path, 1, StrLen(Prefix)) != Prefix
		return ""
	Key := SubStr(Path, StrLen(Prefix) + 1)
	if !TomlConfigActionParameterIsOwned(Key)
		return ""
	return SubStr(Key, 1, InStr(Key, "__") - 1)
}

; Only keys accepted by the binding owner can enter the manifest inventory.
ConfigScopeActionParameterPaths() {
	global GestureActionParameters
	if !IsSet(GestureActionParameters) || !(GestureActionParameters is Map)
		throw Error("Action parameter inventory is unavailable.")
	Paths := []
	for Key in GestureActionParameters {
		Path := "action_parameters." . Key
		if ConfigScopeActionParameterDomain(Path) != ""
			Paths.Push(Path)
	}
	return Paths
}
