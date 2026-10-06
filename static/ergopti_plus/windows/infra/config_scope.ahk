; infra/config_scope.ahk

; ==============================================================================
; MODULE: Scoped Configuration Lifecycle
; DESCRIPTION:
; Publishes manifest-owned settings and detached file-owner images through the
; admitted builder and existing conditional WAL. The terminal bundle survives
; until reload completion or verified rollback of the complete cohort.
; ==============================================================================

#Include %A_LineFile%\..\..\..\_shared\ahk\config_obsolete_parents.ahk

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
	PresetOwner := Options.Get("preset_owner", 0)
	if Plan.presets.Length {
		if !(PresetOwner is TapHoldScopeOwner) || ScopeId != "tap_holds"
				|| Plan.presets.Length != 1 || Plan.presets[1].preset != "tap_hold"
				|| PresetOwner.mode != Mode
			throw ValueError("This scope requires its matching separate-file preset owner.")
	} else if !(PresetOwner is Integer) || PresetOwner != 0
		throw ValueError("This scope does not declare a separate-file preset.")
	Operations() {
		Inventory := ManifestScopeInventory(ScopeId, Providers, Owners)
		Candidate := ManifestScopePlan(ScopeId, Mode, Inventory, Owners)
		if Options.Has("supplement") {
			Supplement := Options["supplement"].Call(ScopeId, Mode)
			if !(Supplement is Array)
				throw TypeError("The scoped owner supplement must return a dense operation array.")
			loop Supplement.Length {
				if !Supplement.Has(A_Index) || !IsObject(Supplement[A_Index])
					throw TypeError("The scoped owner supplement contains an invalid operation.")
				Candidate.operations.Push(Supplement[A_Index])
			}
		}
		return Candidate.operations
	}
	return ConfigScopeCommitOperations(ScopeId, Mode, Operations, Options, PresetOwner)
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
		; Admit one fresh source generation before deriving any scope effect.
		; Clear and recommendations do not own obsolete-entry cleanup.
		Image := TOML_BuildConfigUpdatedContent(Path, [])
		if !(Image is Map) || Image.Get("status", "") != "ok" || Image.Get("kind", "") != "rendered"
			throw Error("The scoped configuration source could not be admitted.")
		Rows := _ConfigPrepareTypedUpdates(ConfigScopePreserveObsoleteSource(
			Image["source_content"], OperationsFn.Call()))
		; Reuse the existing build-only writer admission with that same image.
		; This also rechecks source drift and a refusal latched by inventory.
		Rendered := _TOML_BatchWriteImpl(Path, Rows, [], "build",
			Image["source_content"], Image["source_present"], true)
		Image := _TOML_FinalizeBuildResult(Rendered, Image["source_present"], Image["source_content"])
		if Image.Get("status", "") != "ok" || Image.Get("kind", "") != "rendered"
			throw Error("The scoped configuration image could not be rendered.")
		Expected := ConfigTransitionExpectedOld(Image["source_present"], Image["source_content"], Port)
		if !(Expected is Map)
			throw Error("The scoped configuration precondition could not be established.")
		Targets := [ConfigTransitionPresentTarget(Path, Image["content"], Expected)]
		Images := [{ path: Path, image: Image }]
		if FileOwner is Object {
			for Candidate in FileOwner.Build() {
				if !(_ConfigWriteLeaseSelectOwner(Bundle, Candidate.path) is Object)
					throw Error("A scoped file candidate has no admitted owner.")
				Extra := Candidate.image
				if !(Extra is Map) || Extra.Get("status", "") != "ok" || Extra.Get("kind", "") != "rendered"
					throw Error("A scoped file candidate could not be rendered.")
				if Extra.Has("force_target") && (!(Extra["force_target"] is Integer)
						|| (Extra["force_target"] != 0 && Extra["force_target"] != 1))
					throw TypeError("A scoped source precondition must be an explicit Boolean.")
				if Extra["content"] == Extra["source_content"] && !Extra.Get("force_target", false)
					continue
				ExpectedExtra := ConfigTransitionExpectedOld(Extra["source_present"], Extra["source_content"], Port)
				if !(ExpectedExtra is Map)
					throw Error("An additional scoped file precondition could not be established.")
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

/**
 * Protects obsolete settings in the exact admitted source from ordinary scopes.
 * Metadata and source shape use the same classifier as the real native loader.
 * Neutral descendants cannot repair an obsolete scalar/array table parent;
 * nonneutral collisions require an explicit source repair or cleanup first.
 * @param {String} Source Exact image captured under the lifecycle lease.
 * @param {Array} Updates Requested manifest/owner effects, without publication.
 * @returns {Array} Effects that preserve every classified obsolete source value.
 */
ConfigScopePreserveObsoleteSource(Source, Updates) {
	if !(Source is String) || !(Updates is Array)
		throw TypeError("Scoped source preparation requires an exact image and operation array.")
	Obsolete := ConfigObsoleteSourceEntries(Source)
	return ConfigObsoleteParentsPreserve(ConfigObsoleteSourceOperations(Updates), Obsolete)
}

; Whole-state producers intentionally repeat some paths: feature values precede
; their dedicated runtime owners. Preserve that ordered contract, while checking
; every occurrence against the same exact obsolete source. A later neutral row
; cannot erase the refusal owed by an earlier nonneutral collision.
ConfigFullSnapshotPreserveObsoleteSource(Obsolete, Updates) {
	if !(Obsolete is Array) || !(Updates is Array)
		throw TypeError("Full snapshot preparation requires captured obsolete paths and operation arrays.")
	Rows := []
	for Operation in ConfigObsoleteSourceOperations(Updates) {
		for Row in ConfigObsoleteParentsPreserve([Operation], Obsolete)
			Rows.Push(Row)
	}
	return Rows
}

; Native metadata admission is shared by scoped and full-state source owners.
; It never reads a boot warning cache or grants unknown roots cleanup ownership.
ConfigObsoleteSourceEntries(Source) {
	return ConfigObsoleteSnapshotEntries(ConfigTomlDecodeSnapshot(Source))
}

; Capture full-state source admission before the collector can invoke callbacks.
; Present stamps must already be current: ordinary snapshots do not perform
; migrations or repair invalid/newer versions. Genuinely unstamped images keep
; their existing first-save contract; the captured writer still fences absence.
ConfigFullSnapshotCaptureObsoleteSource(Source) {
	if !(Source is String)
		throw TypeError("Full snapshot admission requires an exact source image.")
	Snapshot := ConfigTomlDecodeSnapshot(Source)
	if Snapshot.Document.Has("_meta") {
		Meta := Snapshot.Document["_meta"]
		if !(Meta is Map)
			throw TypeError("The full configuration schema metadata is not a table.")
		if Meta.Has("schema_version") {
			Outcome := ConfigMigrateClassify(Snapshot.Document, ConfigMigrateShippedRegistry(), &Version)
			if Outcome != "current"
				throw Error("The full configuration schema stamp is not current: " . Outcome)
		}
	}
	return ConfigObsoleteSnapshotEntries(Snapshot)
}

ConfigObsoleteSnapshotEntries(Snapshot) {
	Seed := ManifestBuildFeaturesMap()
	Obsolete := []
	Classify(Parts, Typed, Raw) {
		Section := _ConfigTomlSection(Parts), Key := Parts[Parts.Length]
		if TomlConfigSectionSkipKind(Section == "" ? TOML_RenderKey(Key) : Section) != ""
			return
		Value := _ConfigTomlNativeValue(Typed)
		Literal := Raw is Map ? TOML_RenderValue(Typed) : TOML_StripInlineComment(Raw)
		Reason := TomlConfigOutdatedReason(Seed, Section, Key, Value, Literal)
		; The native loader classifies declared wrong types before foreign
		; ownership, then ignores unknown/foreign values whose type already fits.
		if TomlConfigValueMatchesManifest(Section, Key, Value, &ExpectedType, Literal) {
			if TomlConfigUnknownKind(Seed, Section, Key, &ForeignOwner) != "" || ForeignOwner != ""
				return
		}
		if Reason != "" {
			Obsolete.Push({ parts: Parts.Clone(), descendants: !(Typed is Map) })
			return
		}
		if Typed is Map {
			Children := Raw is Map ? Raw : _ConfigTomlRawTree(Typed, Raw)
			for ChildKey, Child in Typed {
				ChildParts := Parts.Clone()
				ChildParts.Push(ChildKey)
				Classify(ChildParts, Child, Children[ChildKey])
			}
		}
	}
	for Row in Snapshot.Rows
		Classify(_TOML_ConfigPath(Row.Section, Row.Key), Row.Typed, Row.ChildRaw is Map ? Row.ChildRaw : Row.Raw)
	return Obsolete
}

; Prepare native semantic paths and neutrality without changing caller records.
ConfigObsoleteSourceOperations(Updates) {
	Operations := []
	loop Updates.Length {
		if !Updates.Has(A_Index) || !IsObject(Updates[A_Index])
			throw TypeError("Scoped source preparation requires dense operation records.")
		Update := Updates[A_Index]
		Operations.Push({ parts: _TOML_ConfigPath(Update.Section, Update.Key),
			neutral: _ConfigUpdateIsNeutral(Update), row: Update })
	}
	return Operations
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

/** Returns terminal scope callbacks; each click creates a fresh transaction. */
ConfigScopeMenuCommands(ScopeId, Providers, Options := unset) {
	OwnedOptions := IsSet(Options) ? Options : Map()
	return Map(
		"scope_restore", (*) => ConfigScopeApply(ScopeId, "recommended", Providers, OwnedOptions),
		"scope_clear", (*) => ConfigScopeApply(ScopeId, "clear", Providers, OwnedOptions))
}
