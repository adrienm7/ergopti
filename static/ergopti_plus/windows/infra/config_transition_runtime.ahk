; infra/config_transition_runtime.ahk

; ==============================================================================
; MODULE: Configuration Transition Runtime Boundary
; DESCRIPTION:
; Binds the portable bounded transition journal to strict Windows filesystem
; adapters and to the driver's process-wide terminal configuration barrier.
; Recovery is callable before paths.toml is read; live transitions retain one
; exact owner bundle from their first old snapshot through Reload/Exit.
;
; FEATURES & RATIONALE:
; 1. The portable journal knows only its eight-call port, never AHK/Win32 APIs.
; 2. Boot recovery acquires every recorded target before changing one byte.
; 3. Live callers preflight stale WAL paths before acquiring the dry barrier.
; 4. Strict typed results prevent truthy Maps or string "0" from authorizing IO.
; ==============================================================================

#Requires AutoHotkey v2.0

global _ConfigTransitionRetainedBarrier := false





; ==========================================
; ==========================================
; ======= 1/ Production Port Binding =======
; ==========================================
; ==========================================

; Constructs the exact eight-method production port. Windows-only primitives
; deliberately remain outside ADAPTER_FILE_SYSTEM, whose portable five-method
; contract is consumed by cross-driver compliance tests.
ConfigTransitionProductionPort() {
	return Map(
		"exists", FSStrictExists,
		"read", FSReadUtf8Exact,
		"read_bounded", FSReadUtf8ExactBounded,
		"write_create_durable", FSWriteCreateDurable,
		"move_create", FSAtomicMoveCreate,
		"move_replace", FSAtomicMoveReplace,
		"delete", FSDeleteStrict,
		"hash", CryptoSha256)
}

; Resolves the optional injected port without accepting arbitrary falsey values.
_ConfigTransitionRuntimePort(Port) {
	if (Port is Integer) && Port == 0
		return ConfigTransitionProductionPort()
	return Port
}

; Strict success predicate for public journal results.
ConfigTransitionResultIs(Result, Kind) {
	if !(Kind is String)
		return false
	return (Result is Map)
		&& Result.Has("status") && Result.Has("kind")
		&& (Result["status"] is String) && Result["status"] == "ok"
		&& (Result["kind"] is String) && Result["kind"] == Kind
}

; Creates one exact target intention without leaking the journal's schema into
; every UI caller.
ConfigTransitionPresentTarget(Path, Content, ExpectedOld := 0) {
	Spec := Map("path", Path, "new_present", 1, "new_content", Content)
	if ExpectedOld is Map {
		Spec["expected_old"] := ExpectedOld
	} else if !(ExpectedOld is Integer) || ExpectedOld != 0 {
		throw TypeError("ExpectedOld must be a Map or the integer sentinel 0.")
	}
	return Spec
}

ConfigTransitionAbsentTarget(Path) {
	return Map("path", Path, "new_present", 0, "new_content", "")
}

ConfigTransitionExpectedOld(Present, Content, Port := 0) {
	global CONFIG_TRANSITION_HASH_ABSENT
	if !(Present is Integer) || (Present != 0 && Present != 1)
			|| !(Content is String) || (!Present && Content != "")
		return false
	if !Present
		return Map("present", 0, "hash", CONFIG_TRANSITION_HASH_ABSENT)
	Port := _ConfigTransitionRuntimePort(Port)
	if !(Port is Map)
		return false
	if !_ConfigTransitionPortHash(Port, Content, &Digest, &Detail)
		return false
	return Map("present", 1, "hash", Digest)
}

; Pure reset intention builder shared by the tray action and behavioural tests.
; config.toml remains present to suppress first-run onboarding; the two sibling
; stores become absent in the same crash-recoverable transition.
_ConfigResetTransitionTargets(ConfigPath, TapHoldPath, ApiEntriesPath) {
	return [
		ConfigTransitionPresentTarget(ConfigPath,
			"[_meta]`nschema_version = " . ConfigMigrateCurrentVersion() . "`n"),
		ConfigTransitionAbsentTarget(TapHoldPath),
		ConfigTransitionAbsentTarget(ApiEntriesPath)
	]
}

; Validates a user-selected configuration directory through the same absolute
; Windows-path grammar used by journal targets. A synthetic child lets drive and
; UNC share roots remain valid even though target paths themselves may not end
; in a separator. The returned form has exactly one trailing backslash.
ConfigTransitionNormalizeConfigDir(Path) {
	if !(Path is String) || Path == ""
		return false
	Normalized := StrReplace(Path, "/", "\")
	if !RegExMatch(Normalized, "^[A-Za-z]:\\")
			&& SubStr(Normalized, 1, 2) != "\\"
		return false
	Root := Normalized
	if SubStr(Root, -1) == "\"
		Root := SubStr(Root, 1, StrLen(Root) - 1)
	ProbeName := "__ergopti_config_dir_validation__.tmp"
	ValidatedProbe := _ConfigTransitionNormalizePath(Root . "\" . ProbeName)
	if !(ValidatedProbe is String)
		return false
	return Root . "\"
}

; Selects the boot configuration root without validating an unused default.
; An absent profile must never redirect personal writes to a drive-relative root.
; @param Overrides {Map} Flat locator values returned by ReadPathsToml.
; @param DefaultDir {String} Already-derived ordinary or isolated smoke default.
; @return {String} Exact selected directory; boot preserves separator handling.
ConfigTransitionSelectBootConfigDir(Overrides, DefaultDir) {
	if Overrides.Has("ConfigDirPath") && Overrides["ConfigDirPath"] != ""
		return Overrides["ConfigDirPath"]
	if !(ConfigTransitionNormalizeConfigDir(DefaultDir) is String)
		throw ValueError("The selected default configuration directory is invalid.")
	return DefaultDir
}

; The LogsDirPath override a paths.toml rewrite must keep: the resolved logs
; folder when it differs from the default, else "". Onboarding and a
; configuration-folder change rebuild the whole locator, which would otherwise
; silently send the logs back to the default folder.
; @returns {String}
ConfigTransitionCurrentLogsOverride() {
	global _LogsDir, _DefaultLogsDir
	if !IsSet(_LogsDir) || !IsSet(_DefaultLogsDir)
		return ""
	return (_LogsDir != _DefaultLogsDir) ? _LogsDir : ""
}

; Canonical paths.toml image shared by onboarding and the paths editor. Keeping
; this a pure builder lets the journal snapshot the old locator before any byte
; of new authority reaches disk. Both comment and live value are validated so
; quotes/control bytes can never escape their TOML line.
; @param LogsDir {String} LogsDirPath to store, "" for the OS default.
; @param DefaultLogsDir {String} OS-default logs folder named in the comment.
ConfigTransitionPathsTomlContent(NewDir, DefaultDir := "", LogsDir := "", DefaultLogsDir := "") {
	NormalizedNewDir := ConfigTransitionNormalizeConfigDir(NewDir)
	if !(NormalizedNewDir is String)
		throw ValueError("A paths.toml transition requires a config directory.")
	if !(DefaultDir is String)
		throw TypeError("The default config directory must be a String.")
	NormalizedDefaultDir := ""
	if DefaultDir != "" {
		NormalizedDefaultDir := ConfigTransitionNormalizeConfigDir(DefaultDir)
		if !(NormalizedDefaultDir is String)
			throw ValueError("The default config directory is invalid.")
	}
	if !(LogsDir is String) || !(DefaultLogsDir is String)
		throw TypeError("The logs folders must be Strings.")
	NormalizedLogsDir := ""
	if LogsDir != "" {
		NormalizedLogsDir := ConfigTransitionNormalizeConfigDir(LogsDir)
		if !(NormalizedLogsDir is String)
			throw ValueError("The logs folder is invalid.")
	}
	NormalizedDefaultLogsDir := ""
	if DefaultLogsDir != "" {
		NormalizedDefaultLogsDir := ConfigTransitionNormalizeConfigDir(DefaultLogsDir)
		if !(NormalizedDefaultLogsDir is String)
			throw ValueError("The default logs folder is invalid.")
	}
	DefaultFwd := StrReplace(NormalizedDefaultDir, "\", "/")
	NewFwd := StrReplace(NormalizedNewDir, "\", "/")
	Body := "# Custom paths — auto-generated by ErgoptiPlus.`n"
	Body .= "# Edit this file to point to your personal configuration folder.`n"
	if (DefaultFwd != "")
		Body .= "# If absent or commented out, files are looked up in: "
			. DefaultFwd . "`n"
	Body .= '`nConfigDirPath = "' . NewFwd . '"`n'
	LogsKey := AppDirsLogsOverrideKey()
	if (NormalizedDefaultLogsDir != "")
		Body .= "`n# Logs folder. If absent or commented out, logs are written to: "
			. StrReplace(NormalizedDefaultLogsDir, "\", "/") . "`n"
	if (NormalizedLogsDir != "")
		Body .= LogsKey . ' = "' . StrReplace(NormalizedLogsDir, "\", "/") . '"`n'
	return Body
}





; ============================================
; ============================================
; ======= 2/ Ownership and Live Commit =======
; ============================================
; ============================================

_ConfigTransitionRuntimeOwns(Bundle, Path) {
	return _ConfigWriteLeaseSelectOwner(Bundle, Path) is Object
}

; A failed rollback must not reopen config admission around an unresolved WAL.
; Retain that exact terminal bundle for the next explicit Reload/Exit; lifecycle
; borrows it instead of deadlocking on a second acquisition.
ConfigTransitionRetainBarrier(Bundle) {
	global _ConfigTransitionRetainedBarrier
	PreviousCritical := Critical("On")
	try {
		; Shape is intrinsic; only the actual closed issuer grants custody.
		if !_ConfigWriteLeaseDataObject(Bundle, ["kind", "id", "tokens", "authorized", "shutdown_claimed"])
				|| !_ConfigWriteTerminalTryAcquire([], Bundle)
			return false
		if !(Bundle is Object) || !Bundle.HasOwnProp("kind")
				|| Bundle.kind != "terminal_bundle"
				|| !Bundle.HasOwnProp("tokens") || !(Bundle.tokens is Array)
				|| !_ConfigWriteTerminalIsActive()
			return false
		for Token in Bundle.tokens {
			if !_ConfigWriteLeaseOwns(Token)
				return false
		}
		if (_ConfigTransitionRetainedBarrier is Object)
			return _ConfigTransitionRetainedBarrier == Bundle
		_ConfigTransitionRetainedBarrier := Bundle
		return true
	} finally Critical(PreviousCritical)
}

ConfigTransitionRetainedBarrier() {
	global _ConfigTransitionRetainedBarrier
	PreviousCritical := Critical("On")
	try return (IsSet(_ConfigTransitionRetainedBarrier) && _ConfigTransitionRetainedBarrier is Object)
		? _ConfigTransitionRetainedBarrier : false
	finally Critical(PreviousCritical)
}

; Refusal callback for a transition that lent its bundle to a reload which was
; refused after launch. The bundle comes back owned: RollbackFn(Bundle) restores
; the old state and returns true only when it retained the barrier, exactly as
; the caller's synchronous refusal branch; every other outcome releases it.
ConfigTransitionSettleRefusedReload(RollbackFn, Bundle, *) {
	Retained := false
	try Retained := RollbackFn.Call(Bundle)
	finally {
		if !((Retained is Integer) && Retained == 1)
			_ConfigWriteTerminalRelease(Bundle)
	}
}

; Classifies the resolution of a failed owned operation. Only an absent WAL or
; a verified all-old recovery lets the initiating process continue on its old
; RAM state. Any other outcome retains the global barrier and annotates the
; primary result so UI finally-blocks cannot accidentally reopen admission.
_ConfigTransitionProtectFailedResolution(Primary, Resolution, Bundle) {
	if !(Primary is Map)
		Primary := _ConfigTransitionResult("fatal", "malformed_primary_result")
	Primary["rollback"] := Resolution
	if ConfigTransitionResultIs(Resolution, "absent")
			|| ConfigTransitionResultIs(Resolution, "recovered_old")
		return Primary
	; Never release admission merely because retaining the discoverable bundle
	; itself hit an invariant failure. The initiating caller still owns Bundle,
	; so marking it retained makes its finally block fail closed. If registration
	; failed, later lifecycle acquisition also sees the live terminal barrier as
	; busy and refuses instead of reopening around an unresolved disk image.
	if !ConfigTransitionRetainBarrier(Bundle)
		Primary["barrier_registration_failed"] := 1
	Primary["barrier_retained"] := 1
	Primary["bundle"] := Bundle
	return Primary
}

; Acquires the LLM-aware process-wide barrier over intended targets plus every
; path named by an already-valid transition WAL. The WAL is inspected again
; after acquisition before recovery, closing the read-to-own race.
ConfigTransitionAcquireLifecycleBundle(PathsFile, IntendedPaths, Port := 0,
		AcquireFn := 0, SettleFn := 0) {
	PreviousCritical := Critical("Off")
	try return _ConfigTransitionAcquireLifecycleBundleNonCritical(PathsFile,
		IntendedPaths, Port, AcquireFn, SettleFn)
	finally Critical(PreviousCritical)
}

_ConfigTransitionAcquireLifecycleBundleNonCritical(PathsFile, IntendedPaths,
		Port, AcquireFn, SettleFn) {
	Port := _ConfigTransitionRuntimePort(Port)
	NormalizedLocator := _ConfigTransitionNormalizePath(PathsFile)
	if !(NormalizedLocator is String) || !(IntendedPaths is Array)
		return _ConfigTransitionResult("fatal", "invalid_arguments")
	Inspected := ConfigTransitionInspect(NormalizedLocator, Port)
	if !ConfigTransitionResultIs(Inspected, "absent")
			&& !ConfigTransitionResultIs(Inspected, "ready")
		return Inspected
	AdditionalPaths := [NormalizedLocator]
	for Path in IntendedPaths {
		NormalizedPath := _ConfigTransitionNormalizePath(Path)
		if !(NormalizedPath is String)
			return _ConfigTransitionResult("fatal", "invalid_target_path")
		AdditionalPaths.Push(NormalizedPath)
	}
	if ConfigTransitionResultIs(Inspected, "ready") {
		for Target in Inspected["record"]["targets"]
			AdditionalPaths.Push(Target["path"])
	}
	try Bundle := HasMethod(AcquireFn, "Call")
		? AcquireFn.Call(AdditionalPaths)
		: ConfigWriteAcquireLifecycleBundle(AdditionalPaths)
	catch as Err {
		return _ConfigTransitionResult("retry", "terminal_barrier_failed",
			"Terminal bundle acquisition threw: " . Err.Message)
	}
	if !(Bundle is Object) {
		return _ConfigTransitionResult("retry", "terminal_barrier_busy",
			"Another configuration transaction owns the process-wide barrier.")
	}
	; A full-save accepted before the terminal barrier is an older durable
	; obligation, not work that may run from OnExit after this WAL has committed.
	; Settle it now through the borrowed bundle so the journal snapshots its bytes.
	try Settled := HasMethod(SettleFn, "Call")
		? SettleFn.Call(Bundle)
		: _ConfigFullSaveSettleTerminal(Bundle)
	catch as Err {
		Settled := 0
		SettleDetail := Err.Message
	}
	if !((Settled is Integer) && Settled == 1) {
		_ConfigWriteTerminalRelease(Bundle)
		return _ConfigTransitionResult("retry", "pending_save_unsettled",
			IsSet(SettleDetail) ? SettleDetail
				: "An accepted full configuration save remains non-durable.")
	}
	; Settle the inspected WAL while every named target is owned, before the
	; caller can parse candidate config bytes. Building from a prepared/applying
	; mixed image and only recovering inside Commit would canonize crash debris.
	Recovered := _ConfigTransitionRecoverOwnedNonCritical(NormalizedLocator,
		Bundle, Port, 0)
	if !ConfigTransitionResultIs(Recovered, "absent")
			&& !ConfigTransitionResultIs(Recovered, "recovered_old")
			&& !ConfigTransitionResultIs(Recovered, "recovered_new") {
		return _ConfigTransitionProtectFailedResolution(Recovered,
			Recovered.Clone(), Bundle)
	}
	Result := _ConfigTransitionResult("ok", "bundle_acquired", "",
		Recovered["record"])
	Result["bundle"] := Bundle
	Result["recovery_kind"] := Recovered["kind"]
	return Result
}

; Recovers an existing journal only when the retained bundle owns its locator
; and every recorded target. This is intentionally stricter than relying on the
; terminal flag alone: future lease implementations may become path-scoped.
ConfigTransitionRecoverOwned(PathsFile, Bundle, Port := 0, PauseFn := 0) {
	PreviousCritical := Critical("Off")
	try return _ConfigTransitionRecoverOwnedNonCritical(PathsFile, Bundle,
		Port, PauseFn)
	finally Critical(PreviousCritical)
}

_ConfigTransitionRecoverOwnedNonCritical(PathsFile, Bundle, Port, PauseFn) {
	Port := _ConfigTransitionRuntimePort(Port)
	NormalizedLocator := _ConfigTransitionNormalizePath(PathsFile)
	if !(NormalizedLocator is String)
		return _ConfigTransitionResult("fatal", "invalid_arguments")
	if !_ConfigTransitionRuntimeOwns(Bundle, NormalizedLocator) {
		return _ConfigTransitionResult("fatal", "locator_owner_missing",
			"The terminal bundle does not own the stable locator.")
	}
	Inspected := ConfigTransitionInspect(NormalizedLocator, Port)
	if ConfigTransitionResultIs(Inspected, "absent")
		return Inspected
	if !ConfigTransitionResultIs(Inspected, "ready")
		return Inspected
	for Target in Inspected["record"]["targets"] {
		if !_ConfigTransitionRuntimeOwns(Bundle, Target["path"]) {
			return _ConfigTransitionResult("fatal", "target_owner_missing",
				"The terminal bundle does not own recorded target '"
				. Target["path"] . "'.", Inspected["record"])
		}
	}
	return ConfigTransitionRecover(NormalizedLocator, Port, PauseFn)
}

; Prepares and applies one ordered transition while the caller retains the
; terminal bundle. Failure paths immediately attempt phase-directed rollback;
; the primary result remains authoritative and carries the rollback result for
; logging/tests instead of turning a failed commit into truthy success.
ConfigTransitionCommitOwned(PathsFile, TargetSpecs, Bundle, Port := 0,
		PauseFn := 0) {
	PreviousCritical := Critical("Off")
	try return _ConfigTransitionCommitOwnedNonCritical(PathsFile, TargetSpecs,
		Bundle, Port, PauseFn)
	finally Critical(PreviousCritical)
}

_ConfigTransitionCommitOwnedNonCritical(PathsFile, TargetSpecs, Bundle, Port,
		PauseFn) {
	Port := _ConfigTransitionRuntimePort(Port)
	NormalizedLocator := _ConfigTransitionNormalizePath(PathsFile)
	if !(NormalizedLocator is String) || !(TargetSpecs is Array)
		return _ConfigTransitionResult("fatal", "invalid_arguments")
	if !_ConfigTransitionRuntimeOwns(Bundle, NormalizedLocator)
		return _ConfigTransitionResult("fatal", "locator_owner_missing")
	for Spec in TargetSpecs {
		if !(Spec is Map) || !Spec.Has("path")
			return _ConfigTransitionResult("fatal", "target_schema_invalid")
		NormalizedPath := _ConfigTransitionNormalizePath(Spec["path"])
		if !(NormalizedPath is String)
				|| !_ConfigTransitionRuntimeOwns(Bundle, NormalizedPath)
			return _ConfigTransitionResult("fatal", "target_owner_missing")
	}
	Recovered := _ConfigTransitionRecoverOwnedNonCritical(NormalizedLocator,
		Bundle, Port, 0)
	if !ConfigTransitionResultIs(Recovered, "absent")
			&& !ConfigTransitionResultIs(Recovered, "recovered_old")
			&& !ConfigTransitionResultIs(Recovered, "recovered_new")
		return _ConfigTransitionProtectFailedResolution(Recovered,
			Recovered.Clone(), Bundle)
	Prepared := ConfigTransitionPrepare(NormalizedLocator, TargetSpecs, Port,
		"", PauseFn)
	if !ConfigTransitionResultIs(Prepared, "prepared") {
		Rollback := _ConfigTransitionRecoverOwnedNonCritical(
			NormalizedLocator, Bundle, Port, 0)
		return _ConfigTransitionProtectFailedResolution(Prepared, Rollback,
			Bundle)
	}
	Applied := ConfigTransitionApply(NormalizedLocator, Port, PauseFn)
	if !ConfigTransitionResultIs(Applied, "committed_new") {
		Rollback := _ConfigTransitionRecoverOwnedNonCritical(
			NormalizedLocator, Bundle, Port, 0)
		return _ConfigTransitionProtectFailedResolution(Applied, Rollback,
			Bundle)
	}
	return Applied
}

; Aborts a live transition after a refused Reload. ``committed_new`` normally
; directs boot recovery forward; while this same process still retains the
; terminal bundle, it is permitted to durably demote that phase to ``applying``
; and therefore restore all-old. A crash anywhere after the demotion also rolls
; old at boot, so the caller never releases a barrier around split authority.
ConfigTransitionRollbackOwned(PathsFile, Bundle, Port := 0, PauseFn := 0) {
	PreviousCritical := Critical("Off")
	try return _ConfigTransitionRollbackOwnedNonCritical(PathsFile, Bundle,
		Port, PauseFn)
	finally Critical(PreviousCritical)
}

_ConfigTransitionRollbackOwnedNonCritical(PathsFile, Bundle, Port, PauseFn) {
	global CONFIG_TRANSITION_PHASE_COMMITTED_NEW
	global CONFIG_TRANSITION_PHASE_APPLYING
	Port := _ConfigTransitionRuntimePort(Port)
	NormalizedLocator := _ConfigTransitionNormalizePath(PathsFile)
	if !(NormalizedLocator is String)
		return _ConfigTransitionResult("fatal", "invalid_arguments")
	if !_ConfigTransitionRuntimeOwns(Bundle, NormalizedLocator)
		return _ConfigTransitionResult("fatal", "locator_owner_missing")
	Inspected := ConfigTransitionInspect(NormalizedLocator, Port)
	if ConfigTransitionResultIs(Inspected, "absent")
		return Inspected
	if !ConfigTransitionResultIs(Inspected, "ready")
		return Inspected
	Record := Inspected["record"]
	for Target in Record["targets"] {
		if !_ConfigTransitionRuntimeOwns(Bundle, Target["path"])
			return _ConfigTransitionResult("fatal", "target_owner_missing", "",
				Record)
	}
	if Record["phase"] == CONFIG_TRANSITION_PHASE_COMMITTED_NEW {
		RollbackRecord := _ConfigTransitionWithPhase(Record,
			CONFIG_TRANSITION_PHASE_APPLYING)
		Demoted := _ConfigTransitionPublishWalReplace(Port,
			NormalizedLocator, RollbackRecord)
		if !ConfigTransitionResultIs(Demoted, "wal_phase_published")
			return Demoted
		_ConfigTransitionPause(PauseFn, "phase:rollback_applying")
	}
	return _ConfigTransitionRecoverOwnedNonCritical(NormalizedLocator, Bundle,
		Port, PauseFn)
}

; Emits one English developer diagnostic. UI callers add their existing
; localized MsgBox/notification; boot uses the result in a visible fatal error.
ConfigTransitionLogFailure(Context, Result) {
	PreviousCritical := Critical("Off")
	try {
	Status := (Result is Map) && Result.Has("status")
		? String(Result["status"]) : "malformed"
	Kind := (Result is Map) && Result.Has("kind")
		? String(Result["kind"]) : "malformed_result"
	Detail := (Result is Map) && Result.Has("detail")
		? String(Result["detail"]) : ""
	try LoggerError(Context,
		"Configuration transition failed ({1}/{2}): {3}",
		Status, Kind, Detail)
	return false
	} finally Critical(PreviousCritical)
}





; ==============================================
; ==============================================
; ======= 3/ Pre-locator Boot Recovery =========
; ==============================================
; ==============================================

; Resolves a valid WAL under a dry terminal barrier before paths.toml can be
; read. A malformed/unreadable WAL is returned unchanged as quarantine; no
; cleanup is attempted without a validated ownership namespace.
ConfigTransitionRecoverAtBoot(PathsFile, Port := 0, PauseFn := 0) {
	PreviousCritical := Critical("Off")
	try return _ConfigTransitionRecoverAtBootNonCritical(PathsFile, Port,
		PauseFn)
	finally Critical(PreviousCritical)
}

_ConfigTransitionRecoverAtBootNonCritical(PathsFile, Port, PauseFn) {
	Port := _ConfigTransitionRuntimePort(Port)
	NormalizedLocator := _ConfigTransitionNormalizePath(PathsFile)
	if !(NormalizedLocator is String)
		return _ConfigTransitionResult("fatal", "invalid_arguments")
	Inspected := ConfigTransitionInspect(NormalizedLocator, Port)
	if ConfigTransitionResultIs(Inspected, "absent")
		return Inspected
	if !ConfigTransitionResultIs(Inspected, "ready")
		return Inspected
	OwnedPaths := [NormalizedLocator]
	for Target in Inspected["record"]["targets"]
		OwnedPaths.Push(Target["path"])
	Bundle := _ConfigWriteTerminalTryAcquire(OwnedPaths)
	if !(Bundle is Object) {
		return _ConfigTransitionResult("retry", "terminal_barrier_busy",
			"Boot recovery could not acquire every recorded target.",
			Inspected["record"])
	}
	try return _ConfigTransitionRecoverOwnedNonCritical(NormalizedLocator,
		Bundle, Port, PauseFn)
	finally _ConfigWriteTerminalRelease(Bundle)
}

; Writes an early diagnostic beside the stable locator, then throws. The throw
; is deliberate: continuing into ReadPathsToml after quarantine would let a
; mixed old/new image become live authority and be re-saved as if coherent.
ConfigTransitionRecoverAtBootOrThrow(PathsFile, Port := 0) {
	PreviousCritical := Critical("Off")
	try return _ConfigTransitionRecoverAtBootOrThrowNonCritical(PathsFile, Port)
	finally Critical(PreviousCritical)
}

_ConfigTransitionRecoverAtBootOrThrowNonCritical(PathsFile, Port) {
	Result := _ConfigTransitionRecoverAtBootNonCritical(PathsFile, Port, 0)
	if ConfigTransitionResultIs(Result, "absent")
			|| ConfigTransitionResultIs(Result, "recovered_old")
			|| ConfigTransitionResultIs(Result, "recovered_new")
		return true
	Status := (Result is Map) && Result.Has("status")
		? String(Result["status"]) : "malformed"
	Kind := (Result is Map) && Result.Has("kind")
		? String(Result["kind"]) : "malformed_result"
	Detail := (Result is Map) && Result.Has("detail")
		? String(Result["detail"]) : ""
	Message := "Configuration transition recovery refused before paths.toml "
		. "read (" . Status . "/" . Kind . "): " . Detail
	; LoggerInit has not run and paths.toml is unread: the line goes straight
	; to bootstrap.log in the default logs folder.
	try LoggerAppendBootstrapLine("ERROR", "ConfigTransition", Message)
	throw Error(Message)
}
