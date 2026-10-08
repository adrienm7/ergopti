; tests/unit/test_config_full_save_generation.ahk

; ==============================================================================
; MODULE: Full-configuration save generations
; DESCRIPTION:
; Behavioural proof that every accepted full-save request remains represented
; until its exact collected batch reaches the writer and is acknowledged.
; Deferred wake-ups are coalesced one-shots; malformed writer statuses fail
; closed; speculative LLM reconciliation never mutates live Features.
; ==============================================================================

#Requires AutoHotkey v2.0

global _CFGFS_TimerCalls := 0
global _CFGFS_TimerDelay := 0
global _CFGFS_TimerThrows := false
global _CFGFS_WriterCalls := 0
global _CFGFS_WriterResult := true
global _CFGFS_SeenUpdates := 0
global _CFGFS_SeenPath := ""
global _CFGFS_RequestDuringWrite := false
global _CFGFS_CollectCalls := 0
global _CFGFS_CollectValue := "old"
global _CFGFS_NotifyCalls := 0
global _CFGFS_TimerCritical := -1
global _CFGFS_WriterCritical := -1
global _CFGFS_CollectCritical := -1
global _CFGFS_NotifyCritical := -1

_CFGFS_Reset() {
	global _CFGFS_TimerCalls, _CFGFS_TimerDelay, _CFGFS_TimerThrows
	global _CFGFS_WriterCalls, _CFGFS_WriterResult, _CFGFS_SeenUpdates
	global _CFGFS_SeenPath
	global _CFGFS_RequestDuringWrite, _CFGFS_CollectCalls
	global _CFGFS_CollectValue, _CFGFS_NotifyCalls
	global _CFGFS_TimerCritical, _CFGFS_WriterCritical
	global _CFGFS_CollectCritical, _CFGFS_NotifyCritical
	_ConfigFullSaveCoordinator({
		requested_generation: 0,
		committed_generation: 0,
		settled_generation: 0,
		terminal_required_generation: 0,
		bound_path: "",
		bound_path_key: "",
		reload_required: false,
		timer_armed: false,
		reported_failure_generation: 0
	})
	_CFGFS_TimerCalls := 0
	_CFGFS_TimerDelay := 0
	_CFGFS_TimerThrows := false
	_CFGFS_WriterCalls := 0
	_CFGFS_WriterResult := true
	_CFGFS_SeenUpdates := 0
	_CFGFS_SeenPath := ""
	_CFGFS_RequestDuringWrite := false
	_CFGFS_CollectCalls := 0
	_CFGFS_CollectValue := "old"
	_CFGFS_NotifyCalls := 0
	_CFGFS_TimerCritical := -1
	_CFGFS_WriterCritical := -1
	_CFGFS_CollectCritical := -1
	_CFGFS_NotifyCritical := -1
}

_CFGFS_CaptureRuntime() {
	global ConfigurationFile, _DriverReady, _ConfigBootReadFailed
	return Map(
		"path_set", IsSet(ConfigurationFile),
		"path", IsSet(ConfigurationFile) ? ConfigurationFile : "",
		"ready_set", IsSet(_DriverReady),
		"ready", IsSet(_DriverReady) ? _DriverReady : false,
		"boot_failed_set", IsSet(_ConfigBootReadFailed),
		"boot_failed", IsSet(_ConfigBootReadFailed)
			? _ConfigBootReadFailed : false)
}

_CFGFS_RestoreRuntime(Runtime) {
	global ConfigurationFile, _DriverReady, _ConfigBootReadFailed
	if Runtime["path_set"]
		ConfigurationFile := Runtime["path"]
	else
		ConfigurationFile := unset
	if Runtime["ready_set"]
		_DriverReady := Runtime["ready"]
	else
		_DriverReady := unset
	if Runtime["boot_failed_set"]
		_ConfigBootReadFailed := Runtime["boot_failed"]
	else
		_ConfigBootReadFailed := unset
}

_CFGFS_Prepare(Path, Ready := true, BootReadFailed := false, CompleteNativeBoot := true) {
	global ConfigurationFile, _DriverReady, _ConfigBootReadFailed
	_CFGFS_Reset()
	ConfigurationFile := Path
	_DriverReady := Ready
	_ConfigBootReadFailed := BootReadFailed
	; Membership alone does not mean the actual native Boot has completed.
	if !ConfigMigrateBoot(Path, "known")
		ConfigSchemaPrepareSource(Path)
	; Unready/read-error and explicit pre-Boot refusal subjects remain readonly.
	if !Ready || BootReadFailed || !CompleteNativeBoot
		return
	if ConfigSchemaCanPrepareWrite(Path)
		return
	Present := FSStrictExists(Path)
	Before := Present ? FSReadUtf8Exact(Path) : ""
	if Present {
		; Preserve original unversioned/old/invalid/newer sources. This helper
		; never stamps or silently migrates an independent legacy expectation.
		try Document := TOML_ParseDocument(Before)
		catch
			return
		if !Document.Has("_meta") || !(Document["_meta"] is Map)
				|| !Document["_meta"].Has("schema_version")
			return
		Version := Document["_meta"]["schema_version"]
		if !_ConfigMigrateIsVersion(Version) || Version != ConfigMigrateCurrentVersion()
			return
	}
	; Only genuine ordinary-current or fresh absent subjects reach default Boot.
	Boot := ConfigMigrateBoot(Path)
	if (Boot is Map) && Boot.Get("status", "") != (Present ? "current" : "absent")
		_CFGFS_TraceActualBootRefusal(Boot)
	AssertTrue(Boot is Map, "the actual native default Boot returns its real result")
	AssertEqual(Present ? "current" : "absent", Boot["status"],
		"the current/fresh fixture completes actual native startup without migration")
	AssertEqual(0, Boot["read_only"])
	AssertEqual(Present, FSStrictExists(Path), "native startup preserves actual fixture presence")
	if Present
		AssertTrue(FSUtf8ExactMatches(Path, Before), "ordinary current startup preserves every independent source byte")
	AssertTrue(ConfigSchemaCanPrepareWrite(Path), "actual Boot, not public membership, admits later native writes")
}

_CFGFS_Timer(Callback, DelayMs) {
	global _CFGFS_TimerCalls, _CFGFS_TimerDelay, _CFGFS_TimerThrows
	global _CFGFS_TimerCritical
	_CFGFS_TimerCalls += 1
	_CFGFS_TimerDelay := DelayMs
	_CFGFS_TimerCritical := A_IsCritical
	if _CFGFS_TimerThrows
		throw Error("injected timer failure")
	return true
}

_CFGFS_Collect() {
	global _CFGFS_CollectCalls, _CFGFS_CollectValue
	global _CFGFS_CollectCritical
	_CFGFS_CollectCalls += 1
	_CFGFS_CollectCritical := A_IsCritical
	return [{ Section: "full_save_test", Key: "value",
		Value: _CFGFS_CollectValue }]
}

_CFGFS_ThrowingCollect() {
	global _CFGFS_CollectCalls
	_CFGFS_CollectCalls += 1
	throw Error("injected collector failure")
}

_CFGFS_Writer(Path, Updates) {
	global _CFGFS_WriterCalls, _CFGFS_WriterResult, _CFGFS_SeenUpdates
	global _CFGFS_SeenPath
	global _CFGFS_RequestDuringWrite
	global _CFGFS_WriterCritical
	_CFGFS_WriterCalls += 1
	_CFGFS_WriterCritical := A_IsCritical
	_CFGFS_SeenPath := Path
	_CFGFS_SeenUpdates := Updates
	if _CFGFS_RequestDuringWrite {
		_CFGFS_RequestDuringWrite := false
		_ConfigFullSaveRequest()
	}
	return _CFGFS_WriterResult
}

_CFGFS_Notify(Message, Options) {
	global _CFGFS_NotifyCalls, _CFGFS_NotifyCritical
	_CFGFS_NotifyCalls += 1
	_CFGFS_NotifyCritical := A_IsCritical
}

_CFGFS_PendingGenerationCannotRebaseAcrossPaths() {
	global ConfigurationFile, _CFGFS_WriterCalls, _CFGFS_SeenPath
	global CONFIG_SAVE_DEFERRED, CONFIG_SAVE_FAILED
	Runtime := _CFGFS_CaptureRuntime()
	OldPath := A_Temp . "\ergopti_full_save_bound_old.toml"
	NewPath := A_Temp . "\ergopti_full_save_bound_new.toml"
	_CFGFS_Prepare(OldPath)
	Owner := _ConfigWriteLeaseTryAcquire(OldPath, "block-old-path")
	Bundle := false
	try {
		Generation := 0
		AssertEqual(CONFIG_SAVE_DEFERRED, SaveFullConfig(_CFGFS_Writer,
			_CFGFS_Timer, true, 0, _CFGFS_Collect, &Generation))
		AssertEqual(1, Generation)
		AssertEqual(OldPath, _ConfigFullSaveBoundPath())
		_ConfigWriteLeaseRelease(Owner)
		Owner := false

		ConfigurationFile := NewPath
		AssertEqual(CONFIG_SAVE_FAILED, _ConfigDrainFullSave(_CFGFS_Writer,
			_CFGFS_Timer, 0, _CFGFS_Collect),
			"a deferred old-path generation must not write the newly published path")
		AssertEqual(0, _CFGFS_WriterCalls)
		AssertTrue(_ConfigFullSaveHasPending())

		Bundle := _ConfigWriteTerminalTryAcquire([OldPath, NewPath])
		AssertTrue(Bundle is Object)
		AssertFalse(_ConfigFullSaveSettleTerminal(Bundle, _CFGFS_Writer,
			_CFGFS_Timer, _CFGFS_Collect),
			"terminal ownership cannot legitimize new-path RAM for an old-path request")
		AssertEqual(0, _CFGFS_WriterCalls)

		ConfigurationFile := OldPath
		AssertTrue(_ConfigFullSaveSettleTerminal(Bundle, _CFGFS_Writer,
			_CFGFS_Timer, _CFGFS_Collect))
		AssertEqual(1, _CFGFS_WriterCalls)
		AssertEqual(OldPath, _CFGFS_SeenPath,
			"the accepted generation must reach its exact original path")
		AssertFalse(_ConfigFullSaveHasPending())
		AssertEqual("", _ConfigFullSaveBoundPath(),
			"a fully settled coordinator must release its path binding")
	} finally {
		if (Owner is Object)
			_ConfigWriteLeaseRelease(Owner)
		if (Bundle is Object)
			_ConfigWriteTerminalRelease(Bundle)
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}

Test("config full save: pending generations never rebase across paths "
	. "(config-full-save-path-binding)",
	_CFGFS_PendingGenerationCannotRebaseAcrossPaths)

_CFGFS_BlockedOwnerQueuesLatestState() {
	global ConfigurationFile, _DriverReady, _ConfigBootReadFailed
	global _CFGFS_CollectValue, _CFGFS_WriterCalls, _CFGFS_TimerCalls
	global _CFGFS_CollectCalls, _CFGFS_SeenUpdates
	global CONFIG_SAVE_DEFERRED, CONFIG_SAVE_OK
	Runtime := _CFGFS_CaptureRuntime()
	Path := A_Temp . "\ergopti_full_save_blocked.toml"
	_CFGFS_Prepare(Path)
	Owner := _ConfigWriteLeaseTryAcquire(Path, "outer-test")
	try {
		AssertTrue(Owner is Object)
		Result := SaveFullConfig(_CFGFS_Writer, _CFGFS_Timer, true, 0,
			_CFGFS_Collect)
		AssertEqual(CONFIG_SAVE_DEFERRED, Result)
		AssertEqual(0, _CFGFS_CollectCalls,
			"a losing owner must defer before reading live state")
		AssertEqual(0, _CFGFS_WriterCalls)
		AssertEqual(1, _CFGFS_TimerCalls)
		AssertTrue(_ConfigFullSaveHasPending())
		_ConfigWriteLeaseRelease(Owner)
		Owner := 0

		_CFGFS_CollectValue := "new"
		AssertEqual(CONFIG_SAVE_OK, _SaveFullConfigDeferred(
			_CFGFS_Writer, _CFGFS_Timer, _CFGFS_Notify, _CFGFS_Collect))
		AssertEqual(1, _CFGFS_WriterCalls)
		AssertEqual("new", _CFGFS_SeenUpdates[1].Value,
			"the deferred drain must collect the post-publication state")
		AssertFalse(_ConfigFullSaveHasPending())
	} finally {
		if (Owner is Object)
			_ConfigWriteLeaseRelease(Owner)
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}

Test("config full save: blocked owner queues the latest state (config-full-save-generation)",
	_CFGFS_BlockedOwnerQueuesLatestState)

_CFGFS_WriterReceivesBatchAndStrictStatus() {
	global _CFGFS_WriterResult, _CFGFS_SeenUpdates, _CFGFS_TimerCalls
	global CONFIG_SAVE_OK, CONFIG_SAVE_FAILED
	Runtime := _CFGFS_CaptureRuntime()
	try {
		_CFGFS_Prepare(A_Temp . "\ergopti_full_save_batch.toml")
		AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(
			_CFGFS_Writer, _CFGFS_Timer, true, 0, _CFGFS_Collect))
		AssertTrue(_CFGFS_SeenUpdates is Array)
		AssertEqual("full_save_test", _CFGFS_SeenUpdates[1].Section)
		AssertEqual("value", _CFGFS_SeenUpdates[1].Key)
		AssertEqual("old", _CFGFS_SeenUpdates[1].Value)
		AssertFalse(_ConfigFullSaveHasPending())

		_CFGFS_Prepare(A_Temp . "\ergopti_full_save_string_status.toml")
		_CFGFS_WriterResult := "1"
		AssertEqual(CONFIG_SAVE_FAILED, SaveFullConfig(
			_CFGFS_Writer, _CFGFS_Timer, true, 0, _CFGFS_Collect),
			"a string that compares equal to 1 must not acknowledge durability")
		AssertTrue(_ConfigFullSaveHasPending())
		AssertEqual(1, _CFGFS_TimerCalls,
			"a malformed writer status must retain and re-arm the obligation")
	} finally {
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}

Test("config full save: writer receives batch and status is strict (config-full-save-generation) (config-full-save-writer-contract)",
	_CFGFS_WriterReceivesBatchAndStrictStatus)

_CFGFS_DefaultWriterPreservesObsoleteDriverNamespace() {
	global CONFIG_SAVE_OK
	Runtime := _CFGFS_CaptureRuntime()
	Path := A_Temp . "\ergopti_full_save_legacy_namespace_"
		. A_ScriptHwnd . "_" . A_TickCount . ".toml"
	Source := "_meta.schema_version = " . ConfigMigrateCurrentVersion() . "`n[ahk.layout]`nergopti_base = false`n`n"
		. "[layout]`nergopti_base = true`n`n"
		. "[future_extension]`nkeep = 42`n"
	Expected := Chr(0xFEFF) . Source . "[full_save_test]`n" . 'value = "old"' . "`n"
	try {
		FileAppend(Source, Path, "UTF-8-RAW")
		AssertEqual(Source, FSReadUtf8Exact(Path))
		_CFGFS_Prepare(Path)
		Before := _ConfigFullSaveCoordinator()
		AssertEqual(0, Before.requested_generation)
		AssertEqual(0, Before.committed_generation)
		AssertEqual(0, Before.settled_generation)
		Generation := 0
		Result := SaveFullConfig(0, _CFGFS_Timer, true, 0,
			_CFGFS_Collect, &Generation)
		AssertTrue(Result is Integer)
		AssertEqual(CONFIG_SAVE_OK, Result)
		AssertEqual(1, Generation)
		After := _ConfigFullSaveCoordinator()
		AssertEqual(Generation, After.requested_generation)
		AssertEqual(Generation, After.committed_generation)
		AssertEqual(Generation, After.settled_generation)
		AssertFalse(_ConfigFullSaveHasPending())
		AssertEqual(Expected, FSReadUtf8Exact(Path),
			"the complete obsolete and future source remains exact around the collected update")
		Data := ParseTomlFile(Path)
		AssertTrue(Data.Has("ahk.layout"),
			"ordinary full saves must preserve the obsolete namespace until explicit cleanup")
		AssertTrue(Data.Has("layout"),
			"preserving the legacy namespace must preserve canonical sections")
		AssertTrue(Data.Has("future_extension"),
			"ordinary saves must preserve unrelated forward-compatible sections")
		AssertEqual(42, Data["future_extension"]["keep"])
		AssertEqual("old", TOML_Read(Path, "full_save_test", "value", "missing"),
			"the fresh native reader must observe the new explicit namespace")
	} finally {
		if FileExist(Path)
			FileDelete(Path)
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}

Test("config full save: canonical writer preserves obsolete [ahk.*] sections "
	. "(config-full-save-obsolete-preservation)",
	_CFGFS_DefaultWriterPreservesObsoleteDriverNamespace)

_CFGFS_DefaultWriterPreservesCompleteObsoletePrefix() {
	global CONFIG_SAVE_OK
	Runtime := _CFGFS_CaptureRuntime()
	Folder := A_Temp . "\ergopti_full_save_obsolete_"
		. A_ScriptHwnd . "_" . A_TickCount
	AssertTrue(DllCall("CreateDirectoryW", "Str", Folder, "Ptr", 0, "Int"),
		"the fixture must exclusively own its native directory")
	Path := Folder . "\config.toml"
	Retired := "# Retired user entries remain until explicit cleanup.`n"
		. "[ahk]`n" . 'retired = "opaque"' . " # retain exact spelling`n`n"
		. "[ahk.layout]`nergopti_base = false`n`n"
		. "[ahk.layout.deep]`n" . 'future = {enabled = true, label = "retain"}' . "`n`n"
		. "[ahk_future]`nkeep = 42`n`n"
	Source := "_meta.schema_version = " . ConfigMigrateCurrentVersion() . "`n" . Retired . "[full_save_test]`n" . 'value = "before"' . "`n"
	Expected := Chr(0xFEFF) . "_meta.schema_version = " . ConfigMigrateCurrentVersion() . "`n" . Retired . "[full_save_test]`n" . 'value = "old"' . "`n"
	try {
		AssertEqual(1, FSWriteCreateDurable(Path, Source))
		AssertEqual(Source, FSReadUtf8Exact(Path))
		_CFGFS_Prepare(Path)
		AssertEqual(0, _ConfigFullSaveCoordinator().requested_generation)
		AssertEqual(0, _ConfigFullSaveCoordinator().committed_generation)
		AssertEqual(0, _ConfigFullSaveCoordinator().settled_generation)
		Generation := 0
		Result := SaveFullConfig(0, _CFGFS_Timer, true, 0,
			_CFGFS_Collect, &Generation)
		AssertTrue(Result is Integer)
		AssertEqual(CONFIG_SAVE_OK, Result)
		AssertEqual(1, Generation)
		AssertEqual(Generation, _ConfigFullSaveCoordinator().requested_generation)
		AssertEqual(Generation, _ConfigFullSaveCoordinator().committed_generation)
		AssertEqual(Generation, _ConfigFullSaveCoordinator().settled_generation)
		AssertFalse(_ConfigFullSaveHasPending())
		AssertEqual(Expected, FSReadUtf8Exact(Path),
			"root, nested and deeper obsolete sections, comments and future values remain byte-exact")
		Data := TOML_ParseDocument(FSReadUtf8Exact(Path))
		AssertEqual("opaque", Data["ahk"]["retired"])
		AssertTrue(Data["ahk"]["layout"]["ergopti_base"] is TOML_Bool)
		AssertEqual(false, Data["ahk"]["layout"]["ergopti_base"].Value)
		AssertTrue(Data["ahk"]["layout"]["deep"]["future"]["enabled"] is TOML_Bool)
		AssertEqual(true, Data["ahk"]["layout"]["deep"]["future"]["enabled"].Value)
		AssertEqual("retain", Data["ahk"]["layout"]["deep"]["future"]["label"])
		AssertEqual(42, Data["ahk_future"]["keep"])
		AssertEqual("old", Data["full_save_test"]["value"])

		; A semantic no-op still acknowledges its own exact new generation.
		Generation := 0
		Result := SaveFullConfig(0, _CFGFS_Timer, true, 0,
			_CFGFS_Collect, &Generation)
		AssertTrue(Result is Integer)
		AssertEqual(CONFIG_SAVE_OK, Result)
		AssertEqual(2, Generation)
		AssertEqual(Generation, _ConfigFullSaveCoordinator().requested_generation)
		AssertEqual(Generation, _ConfigFullSaveCoordinator().committed_generation)
		AssertEqual(Generation, _ConfigFullSaveCoordinator().settled_generation)
		AssertFalse(_ConfigFullSaveHasPending())
		AssertEqual(Expected, FSReadUtf8Exact(Path),
			"a repeated ordinary save preserves the entire already durable image")
	} finally {
		if FileExist(Path)
			FileDelete(Path)
		if DirExist(Folder)
			DirDelete(Folder)
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}

Test("config full save: preserves root and nested obsolete namespaces plus exact no-op generations "
	. "(config-full-save-obsolete-preservation)",
	_CFGFS_DefaultWriterPreservesCompleteObsoletePrefix)

_CFGFS_NewGenerationIsNotOverAcknowledged() {
	global _CFGFS_RequestDuringWrite, _CFGFS_WriterCalls, _CFGFS_TimerCalls
	global CONFIG_SAVE_OK
	Runtime := _CFGFS_CaptureRuntime()
	try {
		_CFGFS_Prepare(A_Temp . "\ergopti_full_save_new_generation.toml")
		_CFGFS_RequestDuringWrite := true
		AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(
			_CFGFS_Writer, _CFGFS_Timer, true, 0, _CFGFS_Collect))
		AssertEqual(1, _CFGFS_WriterCalls)
		AssertTrue(_ConfigFullSaveHasPending(),
			"a request created during I/O must outlive the older acknowledgement")
		AssertEqual(1, _CFGFS_TimerCalls)
		AssertEqual(CONFIG_SAVE_OK, _SaveFullConfigDeferred(
			_CFGFS_Writer, _CFGFS_Timer, _CFGFS_Notify, _CFGFS_Collect))
		AssertEqual(2, _CFGFS_WriterCalls)
		AssertFalse(_ConfigFullSaveHasPending())
	} finally {
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}

Test("config full save: in-write requests are never over-acknowledged (config-full-save-generation)",
	_CFGFS_NewGenerationIsNotOverAcknowledged)

_CFGFS_RetryTimersAreOneShotAndCoalesced() {
	global _CFGFS_TimerCalls, _CFGFS_TimerDelay
	Path := A_Temp . "\ergopti_full_save_retry_timer.toml"
	_CFGFS_Reset()
	try {
		_ConfigFullSaveRequest(true, Path)
		AssertTrue(_ConfigArmFullSaveRetry(250, _CFGFS_Timer))
		AssertEqual(-250, _CFGFS_TimerDelay)
		AssertTrue(_ConfigArmFullSaveRetry(-900, _CFGFS_Timer))
		AssertEqual(1, _CFGFS_TimerCalls,
			"one pending generation may own only one wake-up")

		_CFGFS_Reset()
		_ConfigFullSaveRequest(true, Path)
		AssertFalse(_ConfigArmFullSaveRetry(0, _CFGFS_Timer),
			"zero would cancel the promised retry and must fail closed")
		AssertEqual(0, _CFGFS_TimerCalls)
		AssertFalse(_ConfigFullSaveCoordinator().timer_armed)
	} finally {
		_CFGFS_Reset()
	}
}

Test("config full save: retries are one-shot and coalesced (config-full-save-generation)",
	_CFGFS_RetryTimersAreOneShotAndCoalesced)

_CFGFS_CollectorFailureStaysPendingAndVisible() {
	global _CFGFS_CollectCalls, _CFGFS_WriterCalls
	global _CFGFS_TimerCalls, _CFGFS_NotifyCalls
	global CONFIG_SAVE_FAILED
	Runtime := _CFGFS_CaptureRuntime()
	try {
		_CFGFS_Prepare(A_Temp . "\ergopti_full_save_collector_failure.toml")
		_ConfigFullSaveRequest()
		AssertEqual(CONFIG_SAVE_FAILED, _SaveFullConfigDeferred(
			_CFGFS_Writer, _CFGFS_Timer, _CFGFS_Notify,
			_CFGFS_ThrowingCollect))
		AssertEqual(1, _CFGFS_CollectCalls)
		AssertEqual(0, _CFGFS_WriterCalls)
		AssertTrue(_ConfigFullSaveHasPending())
		AssertEqual(1, _CFGFS_TimerCalls)
		AssertEqual(1, _CFGFS_NotifyCalls)
	} finally {
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}

Test("config full save: collector failure stays pending and visible (config-full-save-generation)",
	_CFGFS_CollectorFailureStaysPendingAndVisible)

_CFGFS_UnreadySaveIsTypedDeferred() {
	global _CFGFS_CollectCalls, _CFGFS_WriterCalls, _CFGFS_TimerDelay
	global CONFIG_SAVE_DEFERRED
	Runtime := _CFGFS_CaptureRuntime()
	try {
		_CFGFS_Prepare(A_Temp . "\ergopti_full_save_unready.toml", false)
		AssertEqual(CONFIG_SAVE_DEFERRED, SaveFullConfig(
			_CFGFS_Writer, _CFGFS_Timer, true, 0, _CFGFS_Collect))
		AssertEqual(0, _CFGFS_CollectCalls)
		AssertEqual(0, _CFGFS_WriterCalls)
		AssertTrue(_ConfigFullSaveHasPending())
		AssertTrue(_CFGFS_TimerDelay < 0)
	} finally {
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}

Test("config full save: unready requests return typed DEFERRED (config-full-save-generation)",
	_CFGFS_UnreadySaveIsTypedDeferred)

_CFGFS_AcceptedDeferredDrainsAtTerminal() {
	global _CFGFS_CollectValue, _CFGFS_WriterCalls, _CFGFS_SeenUpdates
	global CONFIG_SAVE_DEFERRED
	Runtime := _CFGFS_CaptureRuntime()
	Path := A_Temp . "\ergopti_full_save_terminal_drain.toml"
	_CFGFS_Prepare(Path)
	Owner := _ConfigWriteLeaseTryAcquire(Path, "blocking-test")
	Bundle := false
	try {
		AssertTrue(Owner is Object)
		Generation := 0
		AssertEqual(CONFIG_SAVE_DEFERRED, SaveFullConfig(_CFGFS_Writer,
			_CFGFS_Timer, true, 0, _CFGFS_Collect, &Generation))
		AssertEqual(1, Generation)
		AssertEqual(0, _CFGFS_WriterCalls)
		_ConfigWriteLeaseRelease(Owner)
		Owner := 0
		_CFGFS_CollectValue := "terminal-latest"
		Bundle := _ConfigWriteTerminalTryAcquire([Path])
		AssertTrue(Bundle is Object)
		AssertTrue(_ConfigFullSaveSettleTerminal(Bundle, _CFGFS_Writer,
			_CFGFS_Timer, _CFGFS_Collect))
		AssertEqual(1, _CFGFS_WriterCalls)
		AssertEqual("terminal-latest", _CFGFS_SeenUpdates[1].Value)
		AssertFalse(_ConfigFullSaveHasPending())
	} finally {
		if (Owner is Object)
			_ConfigWriteLeaseRelease(Owner)
		if (Bundle is Object)
			_ConfigWriteTerminalRelease(Bundle)
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}
Test("config full save: accepted deferred generation drains at terminal "
	. "(config-full-save-terminal-drain)",
	_CFGFS_AcceptedDeferredDrainsAtTerminal)

_CFGFS_TerminalWriteFailureRefusesSettlement() {
	global _CFGFS_WriterResult, _CFGFS_WriterCalls
	Runtime := _CFGFS_CaptureRuntime()
	Path := A_Temp . "\ergopti_full_save_terminal_failure.toml"
	_CFGFS_Prepare(Path)
	Bundle := false
	try {
		AssertEqual(1, _ConfigFullSaveRequest())
		_CFGFS_WriterResult := false
		Bundle := _ConfigWriteTerminalTryAcquire([Path])
		AssertTrue(Bundle is Object)
		AssertFalse(_ConfigFullSaveSettleTerminal(Bundle, _CFGFS_Writer,
			_CFGFS_Timer, _CFGFS_Collect))
		AssertEqual(1, _CFGFS_WriterCalls)
		AssertTrue(_ConfigFullSaveHasPending(),
			"failed terminal I/O must retain the accepted obligation")
		AssertEqual(0, _ConfigFullSaveCoordinator().committed_generation)
	} finally {
		if (Bundle is Object)
			_ConfigWriteTerminalRelease(Bundle)
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}
Test("config full save: terminal write failure refuses exit "
	. "(config-full-save-terminal-refusal)",
	_CFGFS_TerminalWriteFailureRefusesSettlement)

_CFGFS_BootOnlyGenerationCannotBrickRestart() {
	global _CFGFS_WriterCalls
	Runtime := _CFGFS_CaptureRuntime()
	Path := A_Temp . "\ergopti_full_save_boot_terminal.toml"
	; Production queues this optional canonicalization only after a successful
	; boot read. Its optional provenance, not an unreachable boot-failed flag,
	; is what permits terminal abandonment.
	_CFGFS_Prepare(Path, true, false)
	Bundle := false
	try {
		AssertEqual(1, _ConfigFullSaveRequest(false))
		Bundle := _ConfigWriteTerminalTryAcquire([Path])
		AssertTrue(Bundle is Object)
		AssertTrue(_ConfigFullSaveSettleTerminal(Bundle, _CFGFS_Writer,
			_CFGFS_Timer, _CFGFS_Collect))
		AssertEqual(0, _CFGFS_WriterCalls,
			"terminal-optional boot canonicalization may die with the process")
		AssertFalse(_ConfigFullSaveHasPending())
		State := _ConfigFullSaveCoordinator()
		AssertEqual(0, State.committed_generation,
			"abandonment must not masquerade as durable commit")
		AssertEqual(1, State.settled_generation)
	} finally {
		if (Bundle is Object)
			_ConfigWriteTerminalRelease(Bundle)
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}
Test("config full save: boot-only generation cannot brick restart "
	. "(config-full-save-terminal-boot-abandon)",
	_CFGFS_BootOnlyGenerationCannotBrickRestart)

_CFGFS_BootReadFailureCannotAbandonRequiredRepair() {
	global _CFGFS_WriterCalls
	Runtime := _CFGFS_CaptureRuntime()
	Path := A_Temp . "\ergopti_full_save_boot_required.toml"
	_CFGFS_Prepare(Path, true, true)
	Bundle := false
	try {
		AssertEqual(1, _ConfigFullSaveRequest(true))
		Bundle := _ConfigWriteTerminalTryAcquire([Path])
		AssertTrue(Bundle is Object)
		AssertFalse(_ConfigFullSaveSettleTerminal(Bundle, _CFGFS_Writer,
			_CFGFS_Timer, _CFGFS_Collect),
			"an unsafe serializer must refuse exit rather than erase a user repair")
		AssertEqual(0, _CFGFS_WriterCalls,
			"boot-read failure must still prevent serialization of default-derived RAM")
		AssertTrue(_ConfigFullSaveHasPending(),
			"the mandatory repair must remain owned by the surviving process")
		State := _ConfigFullSaveCoordinator()
		AssertEqual(0, State.committed_generation)
		AssertEqual(0, State.settled_generation,
			"refusal must not masquerade as either commit or optional abandonment")
	} finally {
		if (Bundle is Object)
			_ConfigWriteTerminalRelease(Bundle)
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}
Test("config full save: boot-read failure cannot abandon a required repair "
	. "(config-full-save-terminal-required-boot-read)",
	_CFGFS_BootReadFailureCannotAbandonRequiredRepair)

_CFGFS_RejectedExactGenerationIsNeverRetried() {
	global _CFGFS_WriterResult, _CFGFS_WriterCalls
	global CONFIG_SAVE_FAILED, CONFIG_SAVE_RESOLVE_RELOAD
	Runtime := _CFGFS_CaptureRuntime()
	Path := A_Temp . "\ergopti_full_save_exact_reject.toml"
	_CFGFS_Prepare(Path)
	Bundle := false
	try {
		_CFGFS_WriterResult := false
		Generation := 0
		AssertEqual(CONFIG_SAVE_FAILED, SaveFullConfig(_CFGFS_Writer,
			_CFGFS_Timer, true, 0, _CFGFS_Collect, &Generation))
		AssertEqual(1, _CFGFS_WriterCalls)
		AssertEqual(CONFIG_SAVE_RESOLVE_RELOAD,
			_ConfigFullSaveResolveFailure(Generation, _CFGFS_Timer))
		_CFGFS_WriterResult := true
		Bundle := _ConfigWriteTerminalTryAcquire([Path])
		AssertTrue(Bundle is Object)
		AssertTrue(_ConfigFullSaveSettleTerminal(Bundle, _CFGFS_Writer,
			_CFGFS_Timer, _CFGFS_Collect))
		AssertEqual(1, _CFGFS_WriterCalls,
			"a disk-authoritative rejected generation must never resurrect at exit")
		AssertEqual(0, _ConfigFullSaveCoordinator().committed_generation)
	} finally {
		if (Bundle is Object)
			_ConfigWriteTerminalRelease(Bundle)
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}
Test("config full save: rejected exact generation is never terminally retried "
	. "(config-full-save-exact-reject)",
	_CFGFS_RejectedExactGenerationIsNeverRetried)

; Models the later OnExit(Reload) that claims the launched reload and then
; meets a refusal gate: the hand-off must give control back to the live driver.
_CFGFS_ClaimReloadWithoutFinishing() {
	Claimed := ReloadTerminalHandoffClaim("Reload")
	AssertTrue(Claimed is Map,
		"the simulated OnExit path must claim the exact Reload authorization")
	AssertTrue(ReloadTerminalHandoffRefuseForShutdown("Reload", "test gate"),
		"a vetoed close request must refuse the launched reload")
}

_CFGFS_ReturnedReloadRestoresRejectedGeneration() {
	global _CFGFS_WriterResult, _CFGFS_WriterCalls, _CFGFS_TimerCalls
	global _CFGFS_CollectValue, _CFGFS_SeenUpdates
	global CONFIG_SAVE_FAILED, CONFIG_SAVE_OK, CONFIG_SAVE_RESOLVE_RELOAD
	Runtime := _CFGFS_CaptureRuntime()
	Path := A_Temp . "\ergopti_full_save_returned_reload.toml"
	_CFGFS_Prepare(Path)
	Bundle := false
	try {
		_CFGFS_WriterResult := false
		Generation := 0
		AssertEqual(CONFIG_SAVE_FAILED, SaveFullConfig(_CFGFS_Writer,
			_CFGFS_Timer, true, 0, _CFGFS_Collect, &Generation))
		AssertEqual(CONFIG_SAVE_RESOLVE_RELOAD,
			_ConfigFullSaveResolveFailure(Generation, _CFGFS_Timer))
		AssertTrue(_ConfigFullSaveCoordinator().reload_required)
		AssertFalse(_ConfigFullSaveHasPending(),
			"the exact rejection is settled only while Reload can still finish")

		Bundle := _ConfigWriteTerminalTryAcquire([Path])
		AssertTrue(Bundle is Object)
		Port := _RTP_NewPort()
		Record := _RTP_Pending(Bundle, Port)
		_CFGFS_ClaimReloadWithoutFinishing()
		AssertFalse(ReloadTerminalHandoffPending(),
			"an OnExit refusal must return control to the live driver")
		; Pending(false) excludes a withdrawing record; it does not acknowledge exit.
		loop 2 {
			AssertTrue(_ReloadTerminalHandoffOwns(Record), "The exact withdrawing record remains published before terminal.")
			AssertEqual(Bundle, Record["bundle"])
			AssertTrue(_ConfigWriteTerminalIsActive() && Bundle.authorized && Bundle.shutdown_claimed,
				"The generation fixture retains the exact claimed bundle while its successor lives.")
			AssertFalse(Record["stop_acknowledged"])
			AssertEqual(0, Port["probe"]["closed"])
			AssertEqual(1, Port["probe"]["terminated"], "The native stop request is issued only once.")
			_RTP_RunArmed(Port)
		}
		Port["probe"]["alive"] := false
		_RTP_RunArmed(Port)
		_RTP_RunArmed(Port)
		AssertTrue(Record["stop_acknowledged"] && Record["close_acknowledged"])
		AssertEqual("refused", Record["state"])
		AssertFalse(_ReloadTerminalHandoffOwns(Record), "Full handback precedes the original bundle release and generation restoration.")
		AssertFalse(Bundle.authorized || Bundle.shutdown_claimed)
		AssertEqual(1, Port["probe"]["closed"])
		_ConfigWriteTerminalRelease(Bundle)
		Bundle := false

		AssertTrue(_ConfigFullSaveResumeRejected(Generation, _CFGFS_Timer),
			"a returned Reload must withdraw only its exact disk-authority decision")
		State := _ConfigFullSaveCoordinator()
		AssertFalse(State.reload_required,
			"the surviving driver must accept later save generations")
		AssertTrue(_ConfigFullSaveHasPending(),
			"the still-visible live candidate must again be a terminal obligation")
		AssertEqual(2, _CFGFS_TimerCalls,
			"restoring the obligation must arm a fresh wake-up after rejection canceled the old one")

		_CFGFS_WriterResult := true
		_CFGFS_CollectValue := "still-visible-candidate"
		AssertEqual(CONFIG_SAVE_OK, _SaveFullConfigDeferred(_CFGFS_Writer,
			_CFGFS_Timer, _CFGFS_Notify, _CFGFS_Collect))
		AssertEqual("still-visible-candidate", _CFGFS_SeenUpdates[1].Value,
			"the restored obligation must persist the candidate still shown in RAM")
		AssertFalse(_ConfigFullSaveHasPending())

		_CFGFS_CollectValue := "later-action"
		NextGeneration := 0
		AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(_CFGFS_Writer,
			_CFGFS_Timer, true, 0, _CFGFS_Collect, &NextGeneration))
		AssertEqual(Generation + 1, NextGeneration,
			"the refusal must not permanently seal later user actions")
		AssertEqual("later-action", _CFGFS_SeenUpdates[1].Value)
		AssertFalse(_ConfigFullSaveHasPending())
	} finally {
		if (Bundle is Object)
			_RTP_Cleanup(Bundle)
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}
Test("config full save: returned Reload restores exact rejected generation "
	. "(config-full-save-returned-reload)",
	_CFGFS_ReturnedReloadRestoresRejectedGeneration)

_CFGFS_CoalescedFailurePreservesOlderAcceptance() {
	global _CFGFS_WriterResult, _CFGFS_WriterCalls, _CFGFS_CollectValue
	global CONFIG_SAVE_DEFERRED, CONFIG_SAVE_FAILED
	global CONFIG_SAVE_RESOLVE_DEFERRED
	Runtime := _CFGFS_CaptureRuntime()
	Path := A_Temp . "\ergopti_full_save_coalesced_failure.toml"
	_CFGFS_Prepare(Path)
	Owner := _ConfigWriteLeaseTryAcquire(Path, "older-accepted")
	Bundle := false
	try {
		FirstGeneration := 0
		AssertEqual(CONFIG_SAVE_DEFERRED, SaveFullConfig(_CFGFS_Writer,
			_CFGFS_Timer, true, 0, _CFGFS_Collect, &FirstGeneration))
		AssertEqual(1, FirstGeneration)
		_ConfigWriteLeaseRelease(Owner)
		Owner := 0
		_CFGFS_WriterResult := false
		SecondGeneration := 0
		AssertEqual(CONFIG_SAVE_FAILED, SaveFullConfig(_CFGFS_Writer,
			_CFGFS_Timer, true, 0, _CFGFS_Collect, &SecondGeneration))
		AssertEqual(2, SecondGeneration)
		AssertEqual(CONFIG_SAVE_RESOLVE_DEFERRED,
			_ConfigFullSaveResolveFailure(SecondGeneration, _CFGFS_Timer),
			"the newer failure cannot select disk authority over an older promise")
		_CFGFS_WriterResult := true
		_CFGFS_CollectValue := "coalesced-latest"
		Bundle := _ConfigWriteTerminalTryAcquire([Path])
		AssertTrue(Bundle is Object)
		AssertTrue(_ConfigFullSaveSettleTerminal(Bundle, _CFGFS_Writer,
			_CFGFS_Timer, _CFGFS_Collect))
		AssertEqual(2, _CFGFS_WriterCalls)
		AssertFalse(_ConfigFullSaveHasPending())
	} finally {
		if (Owner is Object)
			_ConfigWriteLeaseRelease(Owner)
		if (Bundle is Object)
			_ConfigWriteTerminalRelease(Bundle)
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}
Test("config full save: coalesced failure preserves older acceptance "
	. "(config-full-save-coalesced-failure)",
	_CFGFS_CoalescedFailurePreservesOlderAcceptance)

_CFGFS_TerminalSealRefusesNewGeneration() {
	global _CFGFS_CollectCalls, _CFGFS_WriterCalls, _CFGFS_TimerCalls
	global CONFIG_SAVE_FAILED
	Runtime := _CFGFS_CaptureRuntime()
	Path := A_Temp . "\ergopti_full_save_terminal_seal.toml"
	_CFGFS_Prepare(Path)
	Bundle := _ConfigWriteTerminalTryAcquire([Path])
	try {
		AssertTrue(Bundle is Object)
		Generation := -1
		AssertEqual(CONFIG_SAVE_FAILED, SaveFullConfig(_CFGFS_Writer,
			_CFGFS_Timer, true, 0, _CFGFS_Collect, &Generation))
		AssertEqual(0, Generation)
		AssertEqual(0, _CFGFS_CollectCalls)
		AssertEqual(0, _CFGFS_WriterCalls)
		AssertEqual(0, _CFGFS_TimerCalls)
		AssertFalse(_ConfigFullSaveHasPending())
	} finally {
		if (Bundle is Object)
			_ConfigWriteTerminalRelease(Bundle)
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}
Test("config full save: terminal seal refuses new accepted generations "
	. "(config-full-save-terminal-seal)",
	_CFGFS_TerminalSealRefusesNewGeneration)

_CFGFS_BootReadFailureNeverAcknowledges() {
	global _CFGFS_WriterCalls
	global CONFIG_SAVE_FAILED
	Runtime := _CFGFS_CaptureRuntime()
	try {
		_CFGFS_Prepare(A_Temp . "\ergopti_full_save_boot_read.toml", true, true)
		_ConfigFullSaveRequest()
		AssertEqual(CONFIG_SAVE_FAILED, _ConfigDrainFullSave(
			_CFGFS_Writer, _CFGFS_Timer, 0, _CFGFS_Collect))
		AssertEqual(0, _CFGFS_WriterCalls)
		AssertTrue(_ConfigFullSaveHasPending(),
			"an unread boot snapshot must remain unacknowledged")
	} finally {
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}

Test("config full save: boot-read refusal retains its generation (config-full-save-generation)",
	_CFGFS_BootReadFailureNeverAcknowledges)

_CFGFS_InheritedCriticalNeverWrapsSaveWork() {
	global _CFGFS_WriterResult
	global _CFGFS_TimerCritical, _CFGFS_WriterCritical
	global _CFGFS_CollectCritical, _CFGFS_NotifyCritical
	global CONFIG_SAVE_OK, CONFIG_SAVE_FAILED
	Runtime := _CFGFS_CaptureRuntime()
	try {
		_CFGFS_Prepare(A_Temp . "\ergopti_full_save_critical_success.toml")
		PreviousCritical := Critical("On")
		try {
			AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(_CFGFS_Writer,
				_CFGFS_Timer, true, 0, _CFGFS_Collect))
			AssertTrue(A_IsCritical,
				"SaveFullConfig must restore its caller's Critical state")
		} finally Critical(PreviousCritical)
		AssertEqual(0, _CFGFS_CollectCritical,
			"full-save collection may traverse large live maps and must be interruptible")
		AssertEqual(0, _CFGFS_WriterCritical,
			"durable full-config I/O must never inherit caller Critical")

		_CFGFS_Prepare(A_Temp . "\ergopti_full_save_critical_failure.toml")
		_ConfigFullSaveRequest()
		_CFGFS_WriterResult := false
		PreviousCritical := Critical("On")
		try {
			AssertEqual(CONFIG_SAVE_FAILED, _SaveFullConfigDeferred(
				_CFGFS_Writer, _CFGFS_Timer, _CFGFS_Notify, _CFGFS_Collect))
			AssertTrue(A_IsCritical,
				"the deferred boundary must restore its caller's Critical state")
		} finally Critical(PreviousCritical)
		AssertEqual(0, _CFGFS_CollectCritical)
		AssertEqual(0, _CFGFS_WriterCritical)
		AssertEqual(0, _CFGFS_TimerCritical,
			"SetTimer registration must remain interruptible")
		AssertEqual(0, _CFGFS_NotifyCritical,
			"failure feedback must remain interruptible")
	} finally {
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
	}
}
Test("config full save: inherited Critical cannot wrap collection IO timers or feedback "
	. "(config-full-save-inherited-critical)",
	_CFGFS_InheritedCriticalNeverWrapsSaveWork)

_CFGFS_LlmCollectionDoesNotMutateLiveFeatures() {
	global Features, _LLM_Menu, _LLM_Menu_Loaded
	SavedFeatures := Features
	SavedEnabled := Features["llm"]["enabled"]
	SavedMenu := _LLM_Menu
	HadLoaded := IsSet(_LLM_Menu_Loaded)
	if HadLoaded
		SavedLoaded := _LLM_Menu_Loaded
	try {
		Features := ManifestBuildFeaturesMap()
		Features["llm"]["enabled"] := SavedEnabled
		_LLM_Menu := _HSDeepCloneMap(SavedMenu)
		_LLM_Menu_Loaded := true
		_LLM_Menu["enabled"] := !SavedEnabled
		_LLM_Menu["onboarding_seen"] := false
		_LLM_Menu["app_profile_overrides"] := Map()
		; A filtered run must not depend on profiles seeded by an earlier test.
		_LLM_Menu["user_profiles"] := []
		Updates := _ConfigCollectFullSaveUpdates()
		AssertTrue(Updates is Array and Updates.Length > 0)
		AssertEqual(SavedEnabled, Features["llm"]["enabled"],
			"speculative LLM reconciliation must target only the detached snapshot")
	} finally {
		Features := SavedFeatures
		_LLM_Menu := SavedMenu
		if HadLoaded
			_LLM_Menu_Loaded := SavedLoaded
		else
			_LLM_Menu_Loaded := unset
	}
}

Test("config full save: detached LLM collection leaves live Features unchanged (config-full-save-generation)",
	_CFGFS_LlmCollectionDoesNotMutateLiveFeatures)

_CFGFS_LlmAppendRefusalAbortsWholeCollection() {
	global Features, _LLM_Menu
	CandidateFeatures := _HSDeepCloneMap(Features)
	CandidateMenu := _HSDeepCloneMap(_LLM_Menu)
	CandidateMenu["onboarding_seen"] := false
	CandidateMenu["app_profile_overrides"] := Map()
	CandidateMenu["user_profiles"] := Map("wrong", "container")
	Thrown := false
	Failure := ""
	try _ConfigCollectFullSaveUpdates(CandidateFeatures, CandidateMenu)
	catch as Err {
		Thrown := true
		Failure := Err.Message . " @ " . Err.File . ":" . Err.Line . " " . Err.Stack
	}
	AssertTrue(Thrown,
		"a refused LLM serialization must abort the full-save candidate, not persist a partial image")
	AssertContains(Failure, "LLM menu persistence fields",
		"the collector must consume the append helper's explicit refusal")
}
Test("config full save: LLM append refusal aborts the whole candidate "
	. "(llm-persisted-option-type-boundary-collector-atomic)",
	_CFGFS_LlmAppendRefusalAbortsWholeCollection)

#Include %A_LineFile%\..\..\fixtures\startup_full_save_observer.ahk

_CFGFS_StartupObserverDrain() {
	return _ConfigDrainFullSave(_CFGFS_Writer, _CFGFS_Timer, 0, _CFGFS_Collect)
}

_CFGFS_StartupObserver(Kind) {
	global _CFGFS_WriterResult, _CFGFS_WriterCalls, _CFGFS_CollectCalls
	Runtime := _CFGFS_CaptureRuntime(), SavedCoordinator := _ConfigFullSaveCoordinator()
	Path := A_Temp . "\ergopti_startup_save_observer_" . A_ScriptHwnd . ".toml"
	Bundle := false
	_CFGFS_Prepare(Path)
	try {
		AssertEqual(1, _ConfigFullSaveRequest(false))
		if Kind == "writer-refused"
			_CFGFS_WriterResult := false
		if Kind == "optional-abandoned" {
			Bundle := _ConfigWriteTerminalTryAcquire([Path])
			Assert(Bundle is Object)
			AssertTrue(_ConfigFullSaveSettleTerminal(Bundle, _CFGFS_Writer, _CFGFS_Timer, _CFGFS_Collect))
			_ConfigWriteTerminalRelease(Bundle)
			Bundle := false
			AssertFalse(_ConfigFullSaveHasPending())
		}
		if Kind == "complete" {
			AssertTrue(_StartupSmokeRequireFullSaveAcknowledged(_CFGFS_StartupObserverDrain))
			AssertEqual(1, _CFGFS_WriterCalls)
			AssertEqual(1, _CFGFS_CollectCalls)
			AssertFalse(_ConfigFullSaveHasPending())
		} else {
			Refusal := false
			try _StartupSmokeRequireFullSaveAcknowledged(_CFGFS_StartupObserverDrain)
			catch as Err {
				Expected := Kind == "writer-refused"
					? "The startup smoke full-save drain did not acknowledge its existing generation."
					: "The startup smoke boot full-save generation is not committed."
				if Type(Err) != "Error" || !(Err.Message == Expected)
					throw Err
				Refusal := true
			}
			AssertTrue(Refusal, "startup readiness must refuse without an actual committed generation")
			AssertEqual(Kind == "writer-refused" ? 1 : 0, _CFGFS_WriterCalls, "no rejected writer is retried")
		}
		State := _ConfigFullSaveCoordinator()
		AssertEqual(1, State.requested_generation, "the observer must not create another request")
		AssertEqual(Kind == "complete" ? 1 : 0, State.committed_generation)
		AssertEqual(Kind == "writer-refused" ? 0 : 1, State.settled_generation)
	} finally {
		if Bundle is Object
			_ConfigWriteTerminalRelease(Bundle)
		_CFGFS_RestoreRuntime(Runtime)
		_CFGFS_Reset()
		_ConfigFullSaveCoordinator(SavedCoordinator)
	}
}

Test("startup full-save acknowledgment: pending boot generation drains exactly once", _CFGFS_StartupObserver.Bind("complete"))
Test("startup full-save acknowledgment: actual writer refusal cannot publish ready", _CFGFS_StartupObserver.Bind("writer-refused"))
Test("startup full-save acknowledgment: dropped optional boot generation cannot publish ready", _CFGFS_StartupObserver.Bind("optional-abandoned"))

; These subjects use the real default collector, renderer, native writer and
; final acknowledgement. Only the candidate's logical owner is withdrawn.
_CFGFS_DurableDebtFixture(Subject) {
	global Features, _LLM_Menu_Loaded, _ConfigBootRejectedOverrides, _ConfigBootOutdatedEntries
	Runtime := _CFGFS_CaptureRuntime(), Coordinator := _ConfigFullSaveCoordinator()
	PreviousFeatures := Features, HadLoaded := IsSet(_LLM_Menu_Loaded)
	PreviousLoaded := HadLoaded ? _LLM_Menu_Loaded : false
	PreviousRejected := _ConfigBootRejectedOverrides, PreviousOutdated := _ConfigBootOutdatedEntries
	Dir := A_Temp . "\ergopti-native-fullsave-debt-" . A_TickCount . "-" . Random(1, 999999)
	DirCreate(Dir), Path := Dir . "\config.toml"
	try {
		Features := ManifestBuildFeaturesMap()
		_LLM_Menu_Loaded := false
		_ConfigBootRejectedOverrides := 0
		_ConfigBootOutdatedEntries := Map()
		_CFGFS_Prepare(Path)
		AssertEqual(CONFIG_SAVE_OK, SaveFullConfig(0, _CFGFS_Timer), "the actual default full save establishes a genuine current native source")
		AssertTrue(FSStrictExists(Path))
		Subject.Call(Path)
	} finally {
		Features := PreviousFeatures
		_LLM_Menu_Loaded := HadLoaded ? PreviousLoaded : unset
		_ConfigBootRejectedOverrides := PreviousRejected
		_ConfigBootOutdatedEntries := PreviousOutdated
		_ConfigFullSaveCoordinator(Coordinator)
		_CFGFS_RestoreRuntime(Runtime)
		DirDelete(Dir, true)
	}
}

_CFGFS_CreateActualDurableDebt(Path, Updates, ExistingOwner := 0) {
	State := { allowed: true, publications: 0 }
	Plan := { updates: Updates,
		admission: () => State.allowed,
		finalize: () => (State.allowed := false, true),
		publish: () => State.publications += 1 }
	AssertFalse(ConfigCommitBuilt(Path, "the native debt regression", () => Plan, 0, (*) => true, ExistingOwner), "actual durable success followed by logical withdrawal must refuse")
	AssertEqual(0, State.publications, "the withdrawn runtime candidate is never published")
	AssertTrue(_ConfigPublicationHasRecoveryDebt(Path))
	AssertTrue(_ConfigFullSavePublicationDebtNeedsRetention(), "private debt plus genuine mandatory pending intent requires orderly shutdown retention")
	AssertFalse(ConfigSchemaCanPrepareWrite(Path), "ordinary writes cannot borrow reconciliation permission")
}

_CFGFS_DebtMatchingDefaultFullSave(Path) {
	Generation := _ConfigFullSaveRequest(true, Path)
	AssertTrue(Generation > 0)
	_CFGFS_CreateActualDurableDebt(Path, [{ Section: "journal_debt_test", Key: "retained", Value: "native" }])
	Before := FSReadUtf8Exact(Path), BeforeTime := FileGetTime(Path, "M")
	AssertContains(Before, 'retained = "native"', "the actual native write reached disk before logical withdrawal")
	AssertEqual(CONFIG_SAVE_OK, _ConfigDrainFullSave(0, _CFGFS_Timer))
	AssertEqual(Before, FSReadUtf8Exact(Path), "genuine reconciliation preserves every exact durable byte")
	AssertEqual(BeforeTime, FileGetTime(Path, "M"), "source-preserving acknowledgement never replaces the target")
	AssertFalse(_ConfigPublicationHasRecoveryDebt(Path))
	AssertFalse(_ConfigFullSavePublicationDebtNeedsRetention(), "settled intent restores the ordinary bounded shutdown policy")
	AssertEqual(Generation, _ConfigFullSaveCoordinator().committed_generation)
	AssertFalse(_ConfigFullSaveHasPending())
}
Test("config full save: genuine default native noop reconciles matching durable debt (config-full-save-debt-matching)", _CFGFS_DurableDebtFixture.Bind(_CFGFS_DebtMatchingDefaultFullSave))

_CFGFS_DebtConflictRetainsBothAndCanRetry(Path) {
	global LOGGER_MIN_LEVEL, LOGGER_DEFAULT_LEVEL
	OldLevel := LOGGER_MIN_LEVEL
	DiskLevel := OldLevel == "DEBUG" ? "INFO" : "DEBUG"
	Generation := _ConfigFullSaveRequest(true, Path)
	_CFGFS_CreateActualDurableDebt(Path, [{ Section: "script", Key: "log_level", Value: DiskLevel }])
	Before := FSReadUtf8Exact(Path)
	try {
		AssertEqual(CONFIG_SAVE_FAILED, _ConfigDrainFullSave(0, _CFGFS_Timer), "conflicting RAM cannot overwrite retained durable authority")
		AssertEqual(Before, FSReadUtf8Exact(Path))
		AssertEqual(OldLevel, LOGGER_MIN_LEVEL, "blocked reconciliation never silently chooses disk over RAM")
		AssertTrue(_ConfigPublicationHasRecoveryDebt(Path))
		AssertTrue(_ConfigFullSaveHasPending(), "the mandatory accepted request remains represented")
		AssertTrue(_ConfigFullSaveCoordinator().committed_generation < Generation)
		; An external configuration editor can restore the retained runtime choice;
		; ordinary menu writers correctly remain blocked by the durable debt.
		DiskLine := 'log_level = "' . DiskLevel . '"' . "`n"
		RepairLine := OldLevel == LOGGER_DEFAULT_LEVEL ? ""
			: 'log_level = "' . OldLevel . '"' . "`n"
		AssertContains(Before, DiskLine, "the independently authored physical row identifies the user's edit")
		Repaired := StrReplace(Before, DiskLine, RepairLine, true)
		AssertFalse(Repaired == Before)
		AssertTrue(FSWriteDurable(Path, Repaired), "the real external-file edit preserves every other source byte")
		AssertEqual(CONFIG_SAVE_OK, _ConfigDrainFullSave(0, _CFGFS_Timer))
		AssertFalse(_ConfigPublicationHasRecoveryDebt(Path))
		AssertFalse(_ConfigFullSaveHasPending())
		AssertEqual(OldLevel, LOGGER_MIN_LEVEL, "the genuine retry does not mutate the retained runtime authority")
		AssertEqual(Repaired, FSReadUtf8Exact(Path))
	} finally LOGGER_MIN_LEVEL := OldLevel
}
Test("config full save: conflicting durable debt retains bytes and mandatory request until actual reconciliation (config-full-save-debt-conflict)", _CFGFS_DurableDebtFixture.Bind(_CFGFS_DebtConflictRetainsBothAndCanRetry))

_CFGFS_DebtCannotUseSuppliedCollectorOrOwnerClone(Path) {
	_ConfigFullSaveRequest(true, Path)
	_CFGFS_CreateActualDurableDebt(Path, [{ Section: "journal_debt_test", Key: "retained", Value: "native" }])
	Before := FSReadUtf8Exact(Path), Calls := []
	AssertEqual(CONFIG_SAVE_FAILED, _ConfigDrainFullSave((*) => (Calls.Push("writer"), true), _CFGFS_Timer, 0, () => (Calls.Push("collector"), [])))
	AssertEqual(0, Calls.Length, "supplied producers are refused before invocation")
	Owner := _ConfigWriteLeaseTryAcquire(Path, "native-debt-clone-control")
	AssertTrue(Owner is Object)
	try {
		Clone := { key: Owner.key, id: Owner.id, kind: Owner.kind }
		AssertFalse(_ConfigPublicationReconcileFullSave(Path, Clone), "same-id cloned native owner cannot settle private debt")
		AssertTrue(_ConfigPublicationHasRecoveryDebt(Path))
		AssertEqual(Before, FSReadUtf8Exact(Path))
		AssertTrue(_ConfigPublicationReconcileFullSave(Path, Owner), "the exact genuine owner retains the real positive route")
	} finally _ConfigWriteLeaseRelease(Owner)
}
Test("config full save: copied ownership and supplied producers cannot settle native debt (config-full-save-debt-identity)", _CFGFS_DurableDebtFixture.Bind(_CFGFS_DebtCannotUseSuppliedCollectorOrOwnerClone))

; The real default collector enumerates the native metrics filter Map. This
; fixture uses that actual callback boundary without supplying a replacement
; collector, renderer, schema owner or acknowledgement.
_CFGFS_DebtObservedFilterMap(Source, Actor) {
	Observed := _CFGFS_DebtObservedFilters()
	Observed.CaseSense := Source.CaseSense
	Observed.Actor := Actor
	for Proc, Value in Source
		Observed[Proc] := Value
	return Observed
}
class _CFGFS_DebtObservedFilters extends Map {
	Actor := 0
	__Enum(VarCount) {
		Next := super.__Enum(VarCount), First := true
		Enumerate(&Proc, &Value) {
			if First {
				First := false
				this.Actor.Call()
			}
			return Next(&Proc, &Value)
		}
		return Enumerate
	}
}

_CFGFS_DebtAcknowledgesOnlyCapturedGeneration(Path) {
	global MetricsFilters
	Generation := _ConfigFullSaveRequest(true, Path)
	_CFGFS_CreateActualDurableDebt(Path, [{ Section: "journal_debt_test", Key: "retained", Value: "native" }])
	OriginalFilters := MetricsFilters.disabled_apps
	Before := FSReadUtf8Exact(Path)
	try {
		MetricsFilters.disabled_apps := _CFGFS_DebtObservedFilterMap(OriginalFilters,
			() => _ConfigFullSaveRequest(true, Path))
		AssertEqual(CONFIG_SAVE_OK, _ConfigDrainFullSave(0, _CFGFS_Timer))
		AssertFalse(_ConfigPublicationHasRecoveryDebt(Path))
		AssertEqual(Generation, _ConfigFullSaveCoordinator().committed_generation,
			"the real collector's newer request cannot be acknowledged by the captured earlier proof")
		AssertEqual(Generation + 1, _ConfigFullSaveCoordinator().requested_generation)
		AssertTrue(_ConfigFullSaveHasPending())
		AssertEqual(Before, FSReadUtf8Exact(Path))
		MetricsFilters.disabled_apps := OriginalFilters
		AssertEqual(CONFIG_SAVE_OK, _ConfigDrainFullSave(0, _CFGFS_Timer))
		AssertFalse(_ConfigFullSaveHasPending(), "the genuine later drain owns its own newer generation")
	} finally MetricsFilters.disabled_apps := OriginalFilters
}
Test("config full save: real collector cannot over-ack newer requests while reconciling native debt (config-full-save-debt-generation)", _CFGFS_DurableDebtFixture.Bind(_CFGFS_DebtAcknowledgesOnlyCapturedGeneration))

_CFGFS_DebtAppearingInsideDefaultCollectorWithdrawsCapturedAdmission(Path) {
	global MetricsFilters
	Generation := _ConfigFullSaveRequest(true, Path)
	Before := FSReadUtf8Exact(Path)
	NoopAdmission := ConfigMigrateBoot(Path, "capture_noop")
	WriteAdmission := ConfigMigrateBoot(Path, "capture_write", Before)
	AssertTrue(HasMethod(NoopAdmission, "Call"))
	AssertTrue(HasMethod(WriteAdmission, "Call"))
	OriginalFilters := MetricsFilters.disabled_apps
	try {
		MetricsFilters.disabled_apps := _CFGFS_DebtObservedFilterMap(OriginalFilters,
			() => _CFGFS_CreateActualDurableDebt(Path, [], _ConfigWriteLeaseCurrent(Path)))
		AssertEqual(CONFIG_SAVE_FAILED, _ConfigDrainFullSave(0, _CFGFS_Timer),
			"actual late durable debt withdraws the ordinary full-save candidate before publication")
		AssertEqual(Before, FSReadUtf8Exact(Path), "the nested genuine native noop isolates debt withdrawal from source drift")
		AssertFalse(NoopAdmission.Call(Before, 1), "captured native noop permission observes later private debt")
		AssertFalse(WriteAdmission.Call(Before, 1, Before), "captured native replacement permission observes later private debt")
		AssertTrue(_ConfigPublicationHasRecoveryDebt(Path))
		AssertTrue(_ConfigFullSaveHasPending())
		AssertTrue(_ConfigFullSaveCoordinator().committed_generation < Generation)
		MetricsFilters.disabled_apps := OriginalFilters
		AssertEqual(CONFIG_SAVE_OK, _ConfigDrainFullSave(0, _CFGFS_Timer))
		AssertFalse(_ConfigPublicationHasRecoveryDebt(Path))
		AssertFalse(_ConfigFullSaveHasPending())
	} finally MetricsFilters.disabled_apps := OriginalFilters
}
Test("config full save: debt added inside the actual collector withdraws captured noop and write guards (config-full-save-debt-late-withdrawal)", _CFGFS_DurableDebtFixture.Bind(_CFGFS_DebtAppearingInsideDefaultCollectorWithdrawsCapturedAdmission))

_CFGFS_GenuineCoordinatorObserver(Name, Path) {
	global MetricsFilters
	Generation := _ConfigFullSaveRequest(true, Path)
	AssertTrue(Generation > 0)
	_CFGFS_CreateActualDurableDebt(Path, [{ Section: "journal_debt_test", Key: "retained", Value: "native" }])
	State := _ConfigFullSaveCoordinator()
	Descriptor := Object.Prototype.GetOwnPropDesc.Call(State, Name)
	Original := Descriptor.Value, Hits := { count: 0 }, OriginalFilters := MetricsFilters.disabled_apps
	Before := FSReadUtf8Exact(Path), BeforeTime := FileGetTime(Path, "M")
	Committed := State.committed_generation, Settled := State.settled_generation
	Owner := _ConfigWriteLeaseTryAcquire(Path, "actual coordinator purity subject")
	AssertTrue(Owner is Object)
	Observe() {
		State.DefineProp(Name, { Get: (*) => (Hits.count += 1, Original) })
	}
	try {
		MetricsFilters.disabled_apps := _CFGFS_DebtObservedFilterMap(OriginalFilters, Observe)
		AssertFalse(_ConfigPublicationReconcileFullSave(Path, Owner),
			"the actual default collector cannot acknowledge matching native debt through a changed coordinator getter")
		AssertFalse(FSNativeAcknowledge(() => _ConfigFullSaveCoordinatorDataAdmitted(State)),
			"the actual current native acknowledgement refuses the same genuine descriptor")
		AssertTrue(_ConfigFullSavePublicationDebtNeedsRetention(),
			"private actual accepted mandatory request plus debt survives malformed public metadata without getter execution")
		AssertEqual(0, Hits.count, "no public coordinator getter executes from the native final predicate or held-debt query")
		AssertEqual(Before, FSReadUtf8Exact(Path)), AssertEqual(BeforeTime, FileGetTime(Path, "M"))
		AssertTrue(_ConfigPublicationHasRecoveryDebt(Path), "false acknowledgment preserves the exact native publication debt")
		AssertEqual(Generation, State.requested_generation, "the actually accepted captured generation remains pending")
		for Pair in [["committed_generation", Committed], ["settled_generation", Settled]] {
			if Pair[1] == Name
				AssertEqual(Pair[2], Descriptor.Value, "the original scalar acknowledgment image remains retained")
			else
				AssertEqual(Pair[2], Object.Prototype.GetOwnPropDesc.Call(State, Pair[1]).Value,
					"the other actual generation remains unacknowledged")
		}
		State.DefineProp(Name, Descriptor)
		MetricsFilters.disabled_apps := OriginalFilters
		AssertTrue(_ConfigPublicationReconcileFullSave(Path, Owner),
			"exact original descriptor repair admits the actual default collector/rendered strict native noop")
		AssertFalse(_ConfigPublicationHasRecoveryDebt(Path)), AssertFalse(_ConfigFullSaveHasPending())
		AssertEqual(Generation, State.committed_generation), AssertEqual(Generation, State.settled_generation)
		AssertEqual(Before, FSReadUtf8Exact(Path)), AssertEqual(BeforeTime, FileGetTime(Path, "M"))
		AssertEqual(0, Hits.count)
	} finally {
		State.DefineProp(Name, Descriptor)
		MetricsFilters.disabled_apps := OriginalFilters
		AssertTrue(_ConfigWriteLeaseRelease(Owner))
	}
}
for Name in ["bound_path_key", "committed_generation", "settled_generation"]
	Test("config full save: actual matching debt noop refuses genuine coordinator observer " . Name,
		_CFGFS_DurableDebtFixture.Bind(_CFGFS_GenuineCoordinatorObserver.Bind(Name)))

_CFGFS_ActualIntentSurvivesPublicCoordinatorReplacement(Path) {
	Generation := _ConfigFullSaveRequest(true, Path)
	_CFGFS_CreateActualDurableDebt(Path, [{ Section: "journal_debt_test", Key: "retained", Value: "native" }])
	Original := _ConfigFullSaveCoordinator(), Before := FSReadUtf8Exact(Path)
	Replacement := { requested_generation: 0, committed_generation: 0,
		settled_generation: 0, terminal_required_generation: 0, bound_path: "",
		bound_path_key: "", reload_required: false, timer_armed: false, reported_failure_generation: 0 }
	Owner := _ConfigWriteLeaseTryAcquire(Path, "actual coordinator replacement subject")
	AssertTrue(Owner is Object)
	try {
		_ConfigFullSaveCoordinator(Replacement)
		AssertTrue(_ConfigFullSavePublicationDebtNeedsRetention(),
			"valid zero public replacement cannot hide the actual original accepted request/debt evidence")
		AssertFalse(_ConfigPublicationReconcileFullSave(Path, Owner),
			"a new public data object never inherits the original genuine accepted request owner")
		AssertEqual(Before, FSReadUtf8Exact(Path)), AssertTrue(_ConfigPublicationHasRecoveryDebt(Path))
		AssertEqual(0, Replacement.committed_generation), AssertEqual(0, Replacement.settled_generation)
		_ConfigFullSaveCoordinator(Original)
		AssertTrue(_ConfigPublicationReconcileFullSave(Path, Owner), "exact original state repair admits actual native matching-source settlement")
		AssertEqual(Generation, Original.committed_generation), AssertEqual(Generation, Original.settled_generation)
		AssertFalse(_ConfigPublicationHasRecoveryDebt(Path)), AssertFalse(_ConfigFullSavePublicationDebtNeedsRetention())
		AssertEqual(Before, FSReadUtf8Exact(Path))
	} finally {
		_ConfigFullSaveCoordinator(Original)
		AssertTrue(_ConfigWriteLeaseRelease(Owner))
	}
}
Test("config full save: actual native intent survives a valid zero public coordinator replacement",
	_CFGFS_DurableDebtFixture.Bind(_CFGFS_ActualIntentSurvivesPublicCoordinatorReplacement))

_CFGFS_ActualTerminalDebtCannotLookSettled(Mode, Path) {
	global CONFIG_SAVE_FAILED
	Generation := _ConfigFullSaveRequest(true, Path)
	AssertTrue(Generation > 0)
	_CFGFS_CreateActualDurableDebt(Path, [{ Section: "journal_debt_test", Key: "retained", Value: "native" }])
	Original := _ConfigFullSaveCoordinator(), Before := FSReadUtf8Exact(Path)
	BeforeTime := FileGetTime(Path, "M"), Hits := { count: 0 }
	Descriptor := Object.Prototype.GetOwnPropDesc.Call(Original, "requested_generation")
	Committed := Original.committed_generation
	Settled := Original.settled_generation, Required := Original.terminal_required_generation
	Bundle := _ConfigWriteTerminalTryAcquire([Path])
	AssertTrue(Bundle is Object, "the actual terminal issuer owns the native configuration path")
	Repair() {
		Original.DefineProp("requested_generation", Descriptor)
		Original.settled_generation := Settled
		Original.terminal_required_generation := Required
		_ConfigFullSaveCoordinator(Original)
	}
	try {
		switch Mode {
		case "replacement":
			_ConfigFullSaveCoordinator({ requested_generation: 0, committed_generation: 0,
				settled_generation: 0, terminal_required_generation: 0, bound_path: "",
				bound_path_key: "", reload_required: false, timer_armed: false, reported_failure_generation: 0 })
		case "scalar":
			Original.settled_generation := Generation
			Original.terminal_required_generation := 0
		case "getter":
			Original.DefineProp("requested_generation", { Get: (*) => (Hits.count += 1, Generation) })
		}
		AssertTrue(_ConfigFullSavePublicationDebtNeedsRetention(),
			"the real accepted request and real native debt survive misleading public terminal metadata")
		AssertFalse(_ConfigFullSaveSettleTerminal(Bundle, 0, _CFGFS_Timer),
			"the actual shutdown drain cannot report settled or optional abandonment for retained mandatory native debt")
		Token := _ConfigWriteLeaseSelectOwner(Bundle, Path)
		AssertTrue(Token is Object)
		AssertEqual(CONFIG_SAVE_FAILED, _ConfigDrainFullSave(0, _CFGFS_Timer, Token),
			"the actual default drain cannot turn false public settlement into CONFIG_SAVE_OK")
		AssertFalse(_ConfigFullSaveAbandonThrough(Generation),
			"the actual optional abandonment owner retains this accepted mandatory native debt")
		AssertEqual(0, Hits.count, "no misleading coordinator getter is invoked by pending, shutdown or abandonment checks")
		AssertTrue(_ConfigPublicationHasRecoveryDebt(Path)), AssertEqual(Before, FSReadUtf8Exact(Path))
		AssertEqual(BeforeTime, FileGetTime(Path, "M"))
		AssertEqual(Committed, Object.Prototype.GetOwnPropDesc.Call(Original, "committed_generation").Value)
		Repair()
		AssertTrue(_ConfigFullSaveSettleTerminal(Bundle, 0, _CFGFS_Timer),
			"exact genuine metadata repair permits the actual default collector and strict native noop settlement")
		AssertEqual(Generation, Original.committed_generation), AssertEqual(Generation, Original.settled_generation)
		AssertFalse(_ConfigPublicationHasRecoveryDebt(Path)), AssertFalse(_ConfigFullSavePublicationDebtNeedsRetention())
		AssertEqual(Before, FSReadUtf8Exact(Path)), AssertEqual(BeforeTime, FileGetTime(Path, "M"))
		AssertEqual(0, Hits.count)
	} finally {
		Original.DefineProp("requested_generation", Descriptor)
		_ConfigFullSaveCoordinator(Original)
		AssertTrue(_ConfigWriteTerminalRelease(Bundle))
	}
}
for Mode in ["replacement", "scalar", "getter"]
	Test("config full save: genuine terminal debt cannot look settled through public coordinator " . Mode,
		_CFGFS_DurableDebtFixture.Bind(_CFGFS_ActualTerminalDebtCannotLookSettled.Bind(Mode)))

_CFGFS_GenuineDefaultDrainCoordinatorObserver(Name, Path) {
	global MetricsFilters, CONFIG_SAVE_FAILED, CONFIG_SAVE_OK
	Generation := _ConfigFullSaveRequest(true, Path)
	AssertTrue(Generation > 0)
	_CFGFS_CreateActualDurableDebt(Path, [{ Section: "journal_debt_test", Key: "retained", Value: "native" }])
	State := _ConfigFullSaveCoordinator(), Descriptor := Object.Prototype.GetOwnPropDesc.Call(State, Name)
	Original := Descriptor.Value, Hits := { count: 0 }, OriginalFilters := MetricsFilters.disabled_apps
	Committed := State.committed_generation, Settled := State.settled_generation
	Before := FSReadUtf8Exact(Path), BeforeTime := FileGetTime(Path, "M")
	Getter := (*) => (Hits.count += 1, Original)
	Observe() {
		State.DefineProp(Name, { Get: Getter })
	}
	try {
		MetricsFilters.disabled_apps := _CFGFS_DebtObservedFilterMap(OriginalFilters, Observe)
		AssertEqual(CONFIG_SAVE_FAILED, _ConfigDrainFullSave(0, _CFGFS_Timer),
			"actual default drain and its real retry tail refuse the genuine collector-withdrawn coordinator")
		AssertTrue(_ConfigFullSaveHasPending(), "malformed actual metadata cannot prove absence of the retained obligation")
		AssertTrue(_ConfigFullSavePublicationDebtNeedsRetention())
		AssertFalse(_ConfigArmFullSaveRetry(-100, _CFGFS_Timer), "retry must refuse before reading the same malformed genuine counters")
		AssertFalse(_ConfigFullSaveAcknowledge(Generation), "actual generation acknowledgement refuses before counter getter execution")
		AssertFalse(_ConfigFullSaveRejectExact(Generation), "failure resolution must not select disk or retire accepted native debt through corrupted metadata")
		AssertEqual(0, Hits.count, "default drain, pending query, retry, acknowledgement and failure policy execute no coordinator observer")
		for Pair in [["committed_generation", Committed], ["settled_generation", Settled]] {
			CurrentDescriptor := Object.Prototype.GetOwnPropDesc.Call(State, Pair[1])
			if Pair[1] == Name {
				AssertFalse(CurrentDescriptor.HasOwnProp("Value"), "the withdrawn actual getter descriptor was never replaced with acknowledged data")
				AssertTrue(CurrentDescriptor.Get == Getter, "the exact independently installed getter descriptor remains uncalled and unmodified")
				AssertEqual(Pair[2], Descriptor.Value, "the independently captured original generation scalar remains retained for exact repair")
			} else {
				AssertTrue(CurrentDescriptor.HasOwnProp("Value"))
				AssertEqual(Pair[2], CurrentDescriptor.Value, "the other actual generation remains unacknowledged")
			}
		}
		AssertTrue(_ConfigPublicationHasRecoveryDebt(Path)), AssertEqual(Before, FSReadUtf8Exact(Path))
		AssertEqual(BeforeTime, FileGetTime(Path, "M"))
		State.DefineProp(Name, Descriptor), MetricsFilters.disabled_apps := OriginalFilters
		AssertEqual(CONFIG_SAVE_OK, _ConfigDrainFullSave(0, _CFGFS_Timer),
			"exact original descriptor repair permits actual default native noop debt closure and captured generation acknowledgement")
		AssertFalse(_ConfigPublicationHasRecoveryDebt(Path)), AssertFalse(_ConfigFullSaveHasPending())
		AssertEqual(Generation, State.committed_generation), AssertEqual(Generation, State.settled_generation)
		AssertEqual(Before, FSReadUtf8Exact(Path)), AssertEqual(BeforeTime, FileGetTime(Path, "M"))
		AssertEqual(0, Hits.count)
	} finally {
		State.DefineProp(Name, Descriptor)
		MetricsFilters.disabled_apps := OriginalFilters
	}
}
for Name in ["bound_path_key", "committed_generation", "settled_generation"]
	Test("config full save: genuine default drain and retry tail refuse actual coordinator observer " . Name,
		_CFGFS_DurableDebtFixture.Bind(_CFGFS_GenuineDefaultDrainCoordinatorObserver.Bind(Name)))

; The same genuine readonly constructor was known before this helper ran.
_CFGFS_KnownCurrentSourceCompletesActualBoot() {
	Runtime := _CFGFS_CaptureRuntime(), Coordinator := _ConfigFullSaveCoordinator()
	Dir := A_Temp . "\ergopti-fullsave-known-current-" . A_TickCount . "-" . Random(1, 999999)
	DirCreate(Dir), Path := Dir . "\config.toml"
	Source := "_meta.schema_version = " . ConfigMigrateCurrentVersion() . "`n[private]`nkeep = 42`n"
	try {
		AssertTrue(FSWriteDurable(Path, Source))
		Prepared := ConfigSchemaPrepareSource(Path)
		AssertEqual("current", Prepared["status"]), AssertEqual(1, Prepared["read_only"])
		AssertTrue(ConfigMigrateBoot(Path, "known"))
		AssertFalse(ConfigSchemaCanPrepareWrite(Path), "real readonly preparation does not complete native Boot")
		_CFGFS_Prepare(Path)
		AssertTrue(ConfigSchemaCanPrepareWrite(Path), "the same known source now completed genuine default Boot")
		AssertTrue(FSUtf8ExactMatches(Path, Source), "real startup preserves the complete independently authored current image")
		_CFGFS_Prepare(Path)
		AssertTrue(ConfigSchemaCanPrepareWrite(Path), "already booted current source is reused without a second Boot")
		AssertTrue(FSUtf8ExactMatches(Path, Source))
	} finally {
		_CFGFS_RestoreRuntime(Runtime), _ConfigFullSaveCoordinator(Coordinator)
		DirDelete(Dir, true)
	}
}
Test("config full save fixture: known readonly current source completes actual default Boot once", _CFGFS_KnownCurrentSourceCompletesActualBoot)

_CFGFS_ExplicitReadonlyKeepsPreBootWriterRefusal() {
	global CONFIG_SAVE_FAILED, _CFGFS_CollectCalls, _CFGFS_WriterCalls
	Runtime := _CFGFS_CaptureRuntime(), Coordinator := _ConfigFullSaveCoordinator()
	Dir := A_Temp . "\ergopti-fullsave-preboot-refusal-" . A_TickCount . "-" . Random(1, 999999)
	DirCreate(Dir), Path := Dir . "\config.toml"
	Source := "_meta.schema_version = " . ConfigMigrateCurrentVersion() . "`n[private]`nkeep = 42`n"
	try {
		AssertTrue(FSWriteDurable(Path, Source))
		_CFGFS_Prepare(Path, true, false, false)
		AssertTrue(ConfigMigrateBoot(Path, "known"))
		AssertFalse(ConfigSchemaCanPrepareWrite(Path), "explicit readonly custody does not manufacture native READY")
		AssertEqual(CONFIG_SAVE_FAILED, SaveFullConfig(_CFGFS_Writer, _CFGFS_Timer, true, 0, _CFGFS_Collect))
		AssertEqual(0, _CFGFS_CollectCalls), AssertEqual(0, _CFGFS_WriterCalls)
		AssertTrue(FSUtf8ExactMatches(Path, Source), "the actual pre-Boot writer refusal retains all original bytes")
	} finally {
		_CFGFS_RestoreRuntime(Runtime), _ConfigFullSaveCoordinator(Coordinator)
		DirDelete(Dir, true)
	}
}
Test("config full save fixture: explicit readonly source retains real pre-Boot writer refusal", _CFGFS_ExplicitReadonlyKeepsPreBootWriterRefusal)

; Temporary qualification observation after the real native Boot result. It
; never acquires, clears, repairs or replaces any native/source/writer owner.
_CFGFS_TraceActualBootRefusal(Boot) {
	global TEST_RESULTS_FILE
	Status := Boot.Get("status", "missing")
	if !(Status is String) || !InStr("|absent|current|migrated|newer|invalid|unsupported|failed|", "|" . Status . "|")
		Status := "noncanonical"
	ReadOnly := Boot.Get("read_only", "missing")
	if !(ReadOnly is Integer)
		ReadOnly := "noninteger"
	Detail := Boot.Get("detail", "")
	; Only exact closed native policy messages are safe to publish. Other
	; messages may contain paths or source excerpts, so they stay unlogged.
	ClosedDetails := Map(
		"the actual boot registry owner refused before migration effects", true,
		"another configuration transaction owns the file", true,
		"the migration source/lease lost registry admission", true,
		"the original native source classification remains refused for this session", true,
		"the actual registry owner changed before native boot migration", true,
		"the completed native migration lost its exact boot source/registry handoff", true)
	if !(Detail is String) || !ClosedDetails.Has(Detail)
		Detail := "redacted noncanonical detail"
	TerminalActive := _ConfigWriteTerminalIsActive() ? 1 : 0
	Line := "# group1-actual-boot-refusal: status=" . Status
		. ";read_only=" . ReadOnly . ";detail=" . Detail
		. ";terminal_active=" . TerminalActive . "`r`n"
	; The real reporter's acquired results file is the reliable CI channel.
	; Missing observation never replaces the original native outcome/assertion.
	try _TestResultsWrite(TEST_RESULTS_FILE, Line)
}
