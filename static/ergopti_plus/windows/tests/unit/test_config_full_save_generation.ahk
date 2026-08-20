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

_CFGFS_Prepare(Path, Ready := true, BootReadFailed := false) {
	global ConfigurationFile, _DriverReady, _ConfigBootReadFailed
	_CFGFS_Reset()
	ConfigurationFile := Path
	_DriverReady := Ready
	_ConfigBootReadFailed := BootReadFailed
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

_CFGFS_ClaimReloadWithoutFinishing() {
	Claimed := ReloadTerminalHandoffClaim("Reload")
	AssertTrue(Claimed is Map,
		"the simulated OnExit path must claim the exact Reload authorization")
	; Returning without Commit/Finish models any reachable refusal gate. The
	; outer ReloadTerminalInvoke must cancel the inert hand-off and return false.
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
		AssertFalse(ReloadTerminalInvoke(Bundle, 0,
			_CFGFS_ClaimReloadWithoutFinishing),
			"an OnExit refusal must return control to the live driver")
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
			_ConfigWriteTerminalRelease(Bundle)
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
	SavedEnabled := Features["llm"]["enabled"]
	SavedMenuEnabled := _LLM_Menu["enabled"]
	HadOnboarding := _LLM_Menu.Has("onboarding_seen")
	if HadOnboarding
		SavedOnboarding := _LLM_Menu["onboarding_seen"]
	HadOverrides := _LLM_Menu.Has("app_profile_overrides")
	if HadOverrides
		SavedOverrides := _LLM_Menu["app_profile_overrides"]
	HadLoaded := IsSet(_LLM_Menu_Loaded)
	if HadLoaded
		SavedLoaded := _LLM_Menu_Loaded
	try {
		_LLM_Menu_Loaded := true
		_LLM_Menu["enabled"] := !SavedEnabled
		_LLM_Menu["onboarding_seen"] := false
		_LLM_Menu["app_profile_overrides"] := Map()
		Updates := _ConfigCollectFullSaveUpdates()
		AssertTrue(Updates is Array and Updates.Length > 0)
		AssertEqual(SavedEnabled, Features["llm"]["enabled"],
			"speculative LLM reconciliation must target only the detached snapshot")
	} finally {
		Features["llm"]["enabled"] := SavedEnabled
		_LLM_Menu["enabled"] := SavedMenuEnabled
		if HadOnboarding
			_LLM_Menu["onboarding_seen"] := SavedOnboarding
		else
			_LLM_Menu.Delete("onboarding_seen")
		if HadOverrides
			_LLM_Menu["app_profile_overrides"] := SavedOverrides
		else
			_LLM_Menu.Delete("app_profile_overrides")
		if HadLoaded
			_LLM_Menu_Loaded := SavedLoaded
		else
			_LLM_Menu_Loaded := unset
	}
}

Test("config full save: detached LLM collection leaves live Features unchanged (config-full-save-generation)",
	_CFGFS_LlmCollectionDoesNotMutateLiveFeatures)
