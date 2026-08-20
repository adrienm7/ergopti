; infra/config_io.ahk

; ==============================================================================
; MODULE: Config I/O — feature toggles, persistence & shortcut config
; DESCRIPTION:
; Reading/writing the user config: the bulk feature/hotstring/category toggles,
; SaveFullConfig + _CollectFeatureUpdates, ReloadWithDefaultConfig, and the
; script/keyboard shortcut slot configuration (read/run/set/menu). Extracted
; verbatim from ErgoptiPlus.ahk (the entry-point decomposition) and #Include'd in
; place; functions are hoisted so their boot-time call sites (SaveFullConfig
; SetTimer, ReadScript/KeyboardShortcutsConfig) are unaffected.
; ==============================================================================

#Include config_write_lease.ahk

; Reports one user-visible error for a configuration mutation that did not
; reach disk. The TOML writer already logs its low-level failure; this adds the
; action context and the notification a boolean-returning caller otherwise
; loses. NotifyFn is injectable so behavioural tests can count the signal
; without displaying a real TrayTip.
ConfigReportPersistenceFailure(Context, NotifyFn := 0, Detail := "", StateUnchanged := true) {
	if (Detail != "") {
		try LoggerError("Config", "Could not persist {1}: {2}.", Context, Detail)
	} else if StateUnchanged {
		try LoggerError("Config", "Could not persist {1}; live state was left unchanged.", Context)
	} else {
		try LoggerError("Config", "Could not fully persist {1}.", Context)
	}
	MessageKey := StateUnchanged ? "dialog.bulk_toggle.save_failed" : "onboarding.error.write_failed"
	; Failure reporting is a backstop, never a second failure source. Translation,
	; an injected UI seam, or the native notifier can each throw while the driver
	; is already handling a refused write. Preserve the false status and the
	; file-log evidence instead of escaping the menu/timer callback.
	try {
		Message := t(MessageKey)
		Options := Map("title", t("paths_editor.save_failed_title"), "level", "error")
		if HasMethod(NotifyFn, "Call")
			NotifyFn.Call(Message, Options)
		else
			NotifierSend(Message, Options)
	} catch as Err {
		try LoggerError("Config", "Could not present the persistence failure notification: {1}.", Err.Message)
	}
	return false
}

; SaveFullConfig has three explicit outcomes. Callers must compare against the
; named constants: DEFERRED means a coalesced retry owns eventual persistence,
; never that the bytes have already reached disk.
global CONFIG_SAVE_FAILED := 0
global CONFIG_SAVE_OK := 1
global CONFIG_SAVE_DEFERRED := 2
global CONFIG_SAVE_RESOLVE_BLOCKED := 0
global CONFIG_SAVE_RESOLVE_RELOAD := 1
global CONFIG_SAVE_RESOLVE_DEFERRED := 2
global CONFIG_FULL_SAVE_RETRY_DELAY_MS := -100
global CONFIG_FULL_SAVE_FAILURE_RETRY_DELAY_MS := -1000
global CONFIG_FULL_SAVE_BOOT_DELAY_MS := -500

; A one-shot timer is only a wake-up mechanism: Reload terminates it. Keep the
; actual full-save obligation in a generation counter so a terminal transition
; can synchronously prove that every accepted request reached disk first.
_ConfigFullSaveCoordinator(Replacement := unset) {
	static State := {
		requested_generation: 0,
		committed_generation: 0,
		settled_generation: 0,
		terminal_required_generation: 0,
		bound_path: "",
		bound_path_key: "",
		reload_required: false,
		timer_armed: false,
		reported_failure_generation: 0
	}
	if IsSet(Replacement)
		State := Replacement
	return State
}

_ConfigFullSaveRequest(TerminalRequired := true, Path := unset) {
	global ConfigurationFile
	RequestPath := IsSet(Path) ? String(Path)
		: (IsSet(ConfigurationFile) ? String(ConfigurationFile) : "")
	RequestKey := _ConfigWriteLeaseKey(RequestPath)
	if (RequestKey = "") {
		try LoggerError("ConfigIO", "Refusing a full-save request without a concrete configuration path.")
		return 0
	}
	State := _ConfigFullSaveCoordinator()
	PreviousCritical := Critical("On")
	try {
		if State.reload_required || _ConfigWriteTerminalIsActive()
			return 0
		if State.requested_generation > State.settled_generation {
			if (State.bound_path_key != RequestKey)
				return 0
		} else {
			State.bound_path := RequestPath
			State.bound_path_key := RequestKey
		}
		State.requested_generation += 1
		if TerminalRequired
			State.terminal_required_generation := State.requested_generation
		return State.requested_generation
	} finally {
		Critical(PreviousCritical)
	}
}

_ConfigFullSaveBoundPath() {
	State := _ConfigFullSaveCoordinator()
	PreviousCritical := Critical("On")
	try return State.bound_path
	finally Critical(PreviousCritical)
}

_ConfigFullSavePathMatches(Path) {
	State := _ConfigFullSaveCoordinator()
	Key := _ConfigWriteLeaseKey(Path)
	PreviousCritical := Critical("On")
	try return State.bound_path_key != "" && State.bound_path_key == Key
	finally Critical(PreviousCritical)
}

_ConfigFullSaveReleaseBindingIfSettled(State) {
	if State.requested_generation <= State.settled_generation
			&& !State.reload_required {
		State.bound_path := ""
		State.bound_path_key := ""
	}
}

_ConfigFullSaveHasPending() {
	State := _ConfigFullSaveCoordinator()
	PreviousCritical := Critical("On")
	try return State.requested_generation > State.settled_generation
	finally Critical(PreviousCritical)
}

_ConfigFullSaveCapture() {
	State := _ConfigFullSaveCoordinator()
	PreviousCritical := Critical("On")
	try return State.requested_generation
	finally Critical(PreviousCritical)
}

_ConfigFullSaveAcknowledge(TargetGeneration) {
	State := _ConfigFullSaveCoordinator()
	PreviousCritical := Critical("On")
	try {
		TargetGeneration := Min(TargetGeneration, State.requested_generation)
		if (TargetGeneration > State.committed_generation)
			State.committed_generation := TargetGeneration
		if (TargetGeneration > State.settled_generation)
			State.settled_generation := TargetGeneration
		_ConfigFullSaveReleaseBindingIfSettled(State)
	} finally {
		Critical(PreviousCritical)
	}
}

; Selects disk authority for one failed request only when no older accepted
; generation would be discarded with it. Settled is not committed: rejection
; is a policy decision, never a claim that the bytes reached disk.
_ConfigFullSaveRejectExact(Generation) {
	if !(Generation is Integer) || Generation <= 0
		return false
	State := _ConfigFullSaveCoordinator()
	PreviousCritical := Critical("On")
	try {
		if Generation != State.requested_generation
				|| Generation != State.settled_generation + 1
			return false
		State.settled_generation := Generation
		State.reload_required := true
		State.timer_armed := false
		return true
	} finally Critical(PreviousCritical)
}

_ConfigFullSaveResolveFailure(Generation, TimerFn := 0) {
	global CONFIG_SAVE_RESOLVE_BLOCKED, CONFIG_SAVE_RESOLVE_RELOAD
	global CONFIG_SAVE_RESOLVE_DEFERRED, CONFIG_FULL_SAVE_FAILURE_RETRY_DELAY_MS
	if ((Generation is Integer) && Generation == 0)
		return CONFIG_SAVE_RESOLVE_RELOAD
	if _ConfigFullSaveRejectExact(Generation)
		return CONFIG_SAVE_RESOLVE_RELOAD
	if _ConfigFullSaveHasPending()
			&& _ConfigArmFullSaveRetry(CONFIG_FULL_SAVE_FAILURE_RETRY_DELAY_MS,
				TimerFn)
		return CONFIG_SAVE_RESOLVE_DEFERRED
	return CONFIG_SAVE_RESOLVE_BLOCKED
}

; Reload is the terminal act that makes an exact rejected generation truly
; disk-authoritative. If Reload returns because an OnExit gate refused process
; death, that decision never completed: keeping the seal would make every later
; menu save a permanent no-op while RAM still displays the rejected candidate.
; Restore only the exact single rejected generation and retain it as a pending
; user obligation. A genuinely accepted Reload never returns to call this seam.
_ConfigFullSaveResumeRejected(Generation, TimerFn := 0) {
	global CONFIG_FULL_SAVE_FAILURE_RETRY_DELAY_MS
	if !(Generation is Integer) || Generation <= 0
		return false
	State := _ConfigFullSaveCoordinator()
	PreviousCritical := Critical("On")
	try {
		if !State.reload_required
				|| Generation != State.requested_generation
				|| Generation != State.settled_generation
				|| Generation <= State.committed_generation
			return false
		State.settled_generation := Generation - 1
		State.reload_required := false
		State.timer_armed := false
	} finally Critical(PreviousCritical)
	return _ConfigArmFullSaveRetry(CONFIG_FULL_SAVE_FAILURE_RETRY_DELAY_MS,
		TimerFn)
}

_ConfigFullSaveAbandonThrough(TargetGeneration) {
	State := _ConfigFullSaveCoordinator()
	PreviousCritical := Critical("On")
	try {
		TargetGeneration := Min(TargetGeneration, State.requested_generation)
		if (TargetGeneration > State.settled_generation)
			State.settled_generation := TargetGeneration
		State.timer_armed := false
		_ConfigFullSaveReleaseBindingIfSettled(State)
		return true
	} finally Critical(PreviousCritical)
}

_ConfigFullSaveTimerStarted() {
	State := _ConfigFullSaveCoordinator()
	PreviousCritical := Critical("On")
	try State.timer_armed := false
	finally Critical(PreviousCritical)
}

; Coalesces wake-ups but never erases the generation when SetTimer itself
; fails. TimerFn mirrors SetTimer(Callback, DelayMs) in behavioural tests.
_ConfigArmFullSaveRetry(DelayMs, TimerFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		; SetTimer and failure logging can yield. The coordinator lock below is
		; sufficient for memory state; never extend a caller's Critical span over
		; timer registration.
		Critical("Off")
		try return _ConfigArmFullSaveRetry(DelayMs, TimerFn)
		finally Critical(InheritedCritical)
	}
	State := _ConfigFullSaveCoordinator()
	PreviousCritical := Critical("On")
	try {
		if (State.requested_generation <= State.settled_generation)
			return true
		if State.timer_armed
			return true
		State.timer_armed := true
	} finally {
		Critical(PreviousCritical)
	}
	try {
		if (DelayMs = 0)
			throw ValueError("A full-save retry delay cannot be zero.")
		if HasMethod(TimerFn, "Call")
			TimerFn.Call(_SaveFullConfigDeferred, -Abs(DelayMs))
		else
			SetTimer(_SaveFullConfigDeferred, -Abs(DelayMs))
		return true
	} catch as Err {
		PreviousCritical := Critical("On")
		try State.timer_armed := false
		finally Critical(PreviousCritical)
		try LoggerError("ConfigIO", "Could not arm the pending full-save retry: {1}.", Err.Message)
		return false
	}
}

_ConfigQueueFullSave(DelayMs, TimerFn := 0, TerminalRequired := true) {
	if !_ConfigFullSaveRequest(TerminalRequired)
		return false
	return _ConfigArmFullSaveRetry(DelayMs, TimerFn)
}

; Commits one logical config mutation in one TOML read-modify-write cycle and,
; when supplied, finalizes reversible non-memory side effects and publishes the
; detached candidate before releasing ownership. FinalizeFn runs outside
; Critical (it may call a guarded OS adapter). PublishFn runs inside one short
; Critical window and must contain memory swaps only. A throw from either is a
; PARTIAL failure because the durable write has already succeeded.
ConfigCommitUpdates(Path, Updates, Context, WriterFn := 0, NotifyFn := 0,
		PublishFn := 0, FinalizeFn := 0, CompensateFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		; The global path owner supplies isolation. Never inherit a caller's
		; Critical span into durable I/O, finalization, recovery or feedback.
		Critical("Off")
		try return ConfigCommitUpdates(Path, Updates, Context, WriterFn,
			NotifyFn, PublishFn, FinalizeFn, CompensateFn)
		finally Critical(InheritedCritical)
	}
	OwnerToken := _ConfigWriteLeaseTryAcquire(Path, "targeted")
	if !(OwnerToken is Object) {
		FailureDetail := "another configuration transaction is already in progress"
		StateUnchanged := true
		_ConfigRunPrecommitCompensation(CompensateFn, &FailureDetail, &StateUnchanged)
		return ConfigReportPersistenceFailure(Context, NotifyFn,
				FailureDetail, StateUnchanged)
	}
	return _ConfigCommitOwned(OwnerToken, Path, Updates, Context, WriterFn,
			NotifyFn, PublishFn, FinalizeFn, CompensateFn, false)
}

; Executes one strict update batch while the caller retains its transition
; barrier. Paths/onboarding must keep the same owner through paths.toml or
; Reload publication, so consuming and releasing it inside _ConfigCommitOwned
; would reopen the exact interleaving window the barrier exists to close.
ConfigCommitBorrowedUpdates(OwnerToken, Path, Updates, Context,
		WriterFn := 0, NotifyFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return ConfigCommitBorrowedUpdates(OwnerToken, Path, Updates,
			Context, WriterFn, NotifyFn)
		finally Critical(InheritedCritical)
	}
	if !_ConfigWriteLeaseOwns(OwnerToken, Path)
		return ConfigReportPersistenceFailure(Context, NotifyFn,
			"the borrowed configuration owner is stale or owns another path")
	FailureDetail := ""
	if !_ConfigInvokeCommitWriter(Path, Updates, WriterFn,
			"the borrowed configuration writer", &FailureDetail)
		return ConfigReportPersistenceFailure(Context, NotifyFn,
			FailureDetail)
	return true
}

; Claims the path before reading any mutable live state, then asks BuildFn for a
; detached transaction plan. This closes the read/clone -> acquire window that
; otherwise lets a sibling publish between a stale snapshot and its later write.
; BuildFn returns { updates, publish?, finalize?, compensate?, cleanup?,
; rollback_updates?, retain? }. A rollback batch is written through the same
; writer while this exact lease is still held when primary finalization fails.
ConfigCommitBuilt(Path, Context, BuildFn, WriterFn := 0, NotifyFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return ConfigCommitBuilt(Path, Context, BuildFn, WriterFn, NotifyFn)
		finally Critical(InheritedCritical)
	}
	OwnerToken := _ConfigWriteLeaseTryAcquire(Path, "built")
	if !(OwnerToken is Object)
		return ConfigReportPersistenceFailure(Context, NotifyFn,
				"another configuration transaction is already in progress")
	Plan := 0
	FailureDetail := ""
	Transferred := false
	NoOp := false
	CompensateFn := 0
	RetainFn := 0
	StateUnchanged := true
	try {
		try Plan := BuildFn.Call()
		catch as Err
			FailureDetail := "candidate construction failed: " . Err.Message
		if (FailureDetail == "" && !(Plan is Object))
			FailureDetail := "candidate construction was refused"
		if (FailureDetail == "") {
			; Resolve the two unwind callbacks before inspecting the rest of the
			; contract. Even a malformed/noop getter may follow a prepared side effect.
			CompensateFn := _ConfigPlanGet(Plan, "compensate", 0)
			RetainFn := _ConfigPlanGet(Plan, "retain", 0)
			NoOp := !!_ConfigPlanGet(Plan, "noop", false)
		}
		if (FailureDetail == "" && !NoOp) {
			Updates := _ConfigPlanGet(Plan, "updates", 0)
			if !(Updates is Array)
				FailureDetail := "candidate construction returned no update batch"
		}
		if (FailureDetail == "" && !NoOp) {
			; Resolve every optional plan property while this frame still owns the
			; release. A custom getter may throw; that must not strand the path.
			; Compensation and retention come first so a later throwing getter cannot
			; strand a side effect that BuildFn already prepared.
			PublishFn := _ConfigPlanGet(Plan, "publish", 0)
			FinalizeFn := _ConfigPlanGet(Plan, "finalize", 0)
			CleanupFn := _ConfigPlanGet(Plan, "cleanup", 0)
			RollbackUpdates := _ConfigPlanGet(Plan, "rollback_updates", 0)
			PublishOnFinalizeFailure := !!_ConfigPlanGet(Plan,
				"publish_on_finalize_failure", false)
			Transferred := true
			return _ConfigCommitOwned(OwnerToken, Path, Updates, Context, WriterFn,
					NotifyFn, PublishFn, FinalizeFn, CompensateFn,
					PublishOnFinalizeFailure, RollbackUpdates, CleanupFn, RetainFn)
		}
	} catch as Err {
		FailureDetail := "candidate plan inspection failed: " . Err.Message
	} finally {
		if !Transferred {
			if (FailureDetail != "") {
				Compensated := _ConfigRunPrecommitCompensation(CompensateFn,
					&FailureDetail, &StateUnchanged)
				if !Compensated
					_ConfigRunRecoveryRetention(RetainFn, "compensation_failed",
						&FailureDetail, &StateUnchanged)
			}
			_ConfigWriteLeaseRelease(OwnerToken)
		}
	}
	if NoOp
		return true
	return ConfigReportPersistenceFailure(Context, NotifyFn, FailureDetail,
		StateUnchanged)
}

_ConfigPlanGet(Plan, Key, Default := 0) {
	if (Plan is Map)
		return Plan.Get(Key, Default)
	return Plan.HasOwnProp(Key) ? Plan.%Key% : Default
}

_ConfigCommitOwned(OwnerToken, Path, Updates, Context, WriterFn, NotifyFn,
		PublishFn, FinalizeFn, CompensateFn, PublishOnFinalizeFailure := false,
		RollbackUpdates := 0, CleanupFn := 0, RetainFn := 0) {
	Failed := false
	FailureDetail := ""
	StateUnchanged := true
	DurableCommitted := false
	PrimaryFinalized := false
	try {
		; A misspelled plan callback used to be treated as "not supplied": the
		; writer committed, publication was skipped, and the gateway returned true.
		; Validate the complete optional-callback contract before durable I/O so a
		; malformed plan cannot split disk state from live state.
		if !_ConfigValidateCommitCallbacks(PublishFn, FinalizeFn, CompensateFn,
				CleanupFn, RetainFn, RollbackUpdates,
				&FailureDetail, &StateUnchanged)
			Failed := true
		if !Failed && !_ConfigInvokeCommitWriter(Path, Updates, WriterFn,
				"the configuration writer", &FailureDetail) {
			Failed := true
		}
		if !Failed
			DurableCommitted := true
		if Failed && !DurableCommitted {
			Compensated := _ConfigRunPrecommitCompensation(CompensateFn,
					&FailureDetail, &StateUnchanged)
			if !Compensated
				_ConfigRunRecoveryRetention(RetainFn, "compensation_failed",
					&FailureDetail, &StateUnchanged)
		}
		if !Failed && HasMethod(FinalizeFn, "Call") {
			try {
				FinalizeResult := FinalizeFn.Call()
				if !(FinalizeResult is Integer) || FinalizeResult != 1 {
					Failed := true
					StateUnchanged := false
					FailureDetail := "the durable write succeeded but finalization was refused"
				}
			}
			catch as Err {
				Failed := true
				StateUnchanged := false
				FailureDetail := "the durable write succeeded but finalization failed: " . Err.Message
			}
		}
		if DurableCommitted && !Failed
			PrimaryFinalized := true
		if DurableCommitted && Failed && (RollbackUpdates is Array) {
			; Activation is exception-atomic, so compensation can discard the inert
			; candidate before restoring the previous durable value. Both operations
			; remain under this owner; no full-save or sibling writer can interleave.
			Compensated := _ConfigRunPrecommitCompensation(CompensateFn,
					&FailureDetail, &StateUnchanged)
			; Never rewrite old durability while the rejected native candidate may
			; still be live. Recovery owns that ambiguity and must quiesce it first.
			RollbackWritten := false
			if Compensated
				RollbackWritten := _ConfigInvokeCommitWriter(Path, RollbackUpdates,
					WriterFn, "the durable rollback writer", &FailureDetail)
			if Compensated && RollbackWritten {
				StateUnchanged := true
			} else {
				StateUnchanged := false
				RecoveryStage := Compensated
					? "rollback_failed" : "compensation_failed"
				_ConfigRunRecoveryRetention(RetainFn, RecoveryStage,
					&FailureDetail, &StateUnchanged)
			}
		}
		if PrimaryFinalized && HasMethod(CleanupFn, "Call") {
			CleanupOk := false
			try CleanupOk := CleanupFn.Call()
			catch as Err {
				FailureDetail .= (FailureDetail != "" ? "; " : "")
					. "post-commit cleanup failed: " . Err.Message
			}
			if !(CleanupOk is Integer) || CleanupOk != 1 {
				if (FailureDetail == "")
					FailureDetail := "post-commit cleanup was refused"
				Failed := true
				StateUnchanged := false
				_ConfigRunRecoveryRetention(RetainFn, "cleanup_failed",
					&FailureDetail, &StateUnchanged)
			}
		}
		; Cleanup happens only after the forward durable value and primary native
		; authority agree. A cleanup failure therefore publishes that forward
		; authority plus its explicit recovery handle instead of losing either.
		ShouldPublish := PrimaryFinalized
			|| (DurableCommitted && PublishOnFinalizeFailure
				&& !(RollbackUpdates is Array))
		if ShouldPublish && HasMethod(PublishFn, "Call") {
			PublishingAfterFailure := Failed
			PreviousCritical := Critical("On")
			try PublishFn.Call()
			catch as Err {
				Failed := true
				StateUnchanged := false
				FailureDetail .= (FailureDetail != "" ? "; " : "")
					. (PublishingAfterFailure
						? "authoritative live publication after finalization failure also failed: "
						: "the durable write succeeded but live publication failed: ")
					. Err.Message
			} finally {
				Critical(PreviousCritical)
			}
		}
	} finally {
		_ConfigWriteLeaseRelease(OwnerToken)
	}
	if Failed
		return ConfigReportPersistenceFailure(Context, NotifyFn, FailureDetail, StateUnchanged)
	return true
}

_ConfigInvokeCommitWriter(Path, Updates, WriterFn, Stage, &FailureDetail) {
	try {
		if HasMethod(WriterFn, "Call")
			Written := WriterFn.Call(Path, Updates)
		else
			Written := TOML_BatchWrite(Path, Updates)
	} catch as Err {
		FailureDetail .= (FailureDetail != "" ? "; " : "")
			. Stage . " failed: " . Err.Message
		return false
	}
	if !((Written is Integer) && Written == 1) {
		FailureDetail .= (FailureDetail != "" ? "; " : "")
			. Stage . " refused or returned a malformed status"
		return false
	}
	return true
}

_ConfigValidateCommitCallbacks(PublishFn, FinalizeFn, CompensateFn,
		CleanupFn, RetainFn, RollbackUpdates,
		&FailureDetail, &StateUnchanged) {
	Valid := true
	for Spec in [
			{ name: "live-publication", fn: PublishFn },
			{ name: "finalization", fn: FinalizeFn },
			{ name: "pre-commit compensation", fn: CompensateFn },
			{ name: "post-commit cleanup", fn: CleanupFn },
			{ name: "recovery retention", fn: RetainFn }
		] {
		Fn := Spec.fn
		if (Fn is Integer) && Fn == 0
			continue
		if HasMethod(Fn, "Call")
			continue
		Valid := false
		FailureDetail .= (FailureDetail != "" ? "; " : "")
			. Spec.name . " callback is not callable"
		if (Spec.name == "pre-commit compensation"
				|| Spec.name == "recovery retention")
			StateUnchanged := false
	}
	if !((RollbackUpdates is Integer) && RollbackUpdates == 0)
			&& !(RollbackUpdates is Array) {
		Valid := false
		FailureDetail .= (FailureDetail != "" ? "; " : "")
			. "durable rollback updates must be an Array"
		StateUnchanged := false
	}
	return Valid
}

_ConfigRunRecoveryRetention(RetainFn, Stage, &FailureDetail, &StateUnchanged) {
	if (RetainFn is Integer) && RetainFn == 0
		return true
	if !HasMethod(RetainFn, "Call") {
		StateUnchanged := false
		FailureDetail .= (FailureDetail != "" ? "; " : "")
			. "recovery retention callback is not callable"
		return false
	}
	Retained := false
	try Retained := RetainFn.Call(Stage)
	catch as Err {
		StateUnchanged := false
		FailureDetail .= (FailureDetail != "" ? "; " : "")
			. "recovery retention raised an error: " . Err.Message
		return false
	}
	if !(Retained is Integer) || Retained != 1 {
		StateUnchanged := false
		FailureDetail .= (FailureDetail != "" ? "; " : "")
			. "recovery retention was refused"
		return false
	}
	return true
}

; Undo a reversible effect that had to be prepared before the durable writer
; (for example reserving a replacement native hotkey Off). This runs before ownership
; is released and before a notifier can yield, so no observer sees a failed
; transaction's prepared state after the user is told it was rejected.
_ConfigRunPrecommitCompensation(CompensateFn, &FailureDetail, &StateUnchanged) {
	if (CompensateFn is Integer) && CompensateFn == 0
		return true
	if !HasMethod(CompensateFn, "Call") {
		StateUnchanged := false
		FailureDetail .= (FailureDetail != "" ? "; " : "")
			. "pre-commit compensation callback is not callable"
		return false
	}
	Compensated := false
	try Compensated := CompensateFn.Call()
	catch as Err {
		StateUnchanged := false
		FailureDetail .= (FailureDetail != "" ? "; " : "")
			. "pre-commit compensation raised an error: " . Err.Message
		return false
	}
	if !(Compensated is Integer) || Compensated != 1 {
		StateUnchanged := false
		FailureDetail .= (FailureDetail != "" ? "; " : "")
			. "pre-commit compensation was refused or returned a malformed status"
		return false
	}
	return true
}

; Timer-owned full saves drain an existing generation; they never create a new
; one. A stale one-shot left behind by a synchronous reload barrier is therefore
; a no-op. Failed writes keep their generation pending and retry with backoff.
_SaveFullConfigDeferred(WriterFn := 0, TimerFn := 0, NotifyFn := 0,
		CollectFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _SaveFullConfigDeferred(WriterFn, TimerFn, NotifyFn,
			CollectFn)
		finally Critical(InheritedCritical)
	}
	global CONFIG_SAVE_FAILED, CONFIG_FULL_SAVE_FAILURE_RETRY_DELAY_MS
	_ConfigFullSaveTimerStarted()
	if !_ConfigFullSaveHasPending()
		return true
	Result := _ConfigDrainFullSave(WriterFn, TimerFn, 0, CollectFn)
	if (Result = CONFIG_SAVE_FAILED) {
		_ConfigReportDeferredFullSaveFailure(NotifyFn)
		_ConfigArmFullSaveRetry(CONFIG_FULL_SAVE_FAILURE_RETRY_DELAY_MS, TimerFn)
	}
	return Result
}

_ConfigReportDeferredFullSaveFailure(NotifyFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _ConfigReportDeferredFullSaveFailure(NotifyFn)
		finally Critical(InheritedCritical)
	}
	State := _ConfigFullSaveCoordinator()
	PreviousCritical := Critical("On")
	try {
		if (State.reported_failure_generation >= State.requested_generation)
			return false
		State.reported_failure_generation := State.requested_generation
	} finally {
		Critical(PreviousCritical)
	}
	return ConfigReportPersistenceFailure(
		"the deferred full configuration save", NotifyFn, "", false)
}

; Applies canonical feature entries to a detached candidate and appends their
; TOML triples to the caller-owned batch. No live Map is touched here.
_ConfigStageFeatureEntries(FeaturesTarget, Entries, Updates) {
	Applied := 0
	for Entry in Entries {
		V2Path := Entry["path"]
		Value := Entry["value"]
		Prop := Entry.Has("prop") ? Entry["prop"] : ""
		Loc := FeatureLocateV2(FeaturesTarget, V2Path, Prop)
		if !(Loc is Map) {
			try LoggerWarn("Config", "Could not stage unresolved feature path '{1}'.", V2Path)
			continue
		}
		Loc["v2_node"][Loc["key"]] := Value
		Updates.Push({ Section: Loc["section"], Key: Loc["key"], Value: Value })
		Applied += 1
	}
	return Applied
}

; Seeds a runtime-discovered personal section only in the detached candidate.
_ConfigSeedPersonalHotstring(FeaturesTarget, SectionName) {
	SectionName := StrLower(SectionName)
	if !FeaturesTarget.Has("hotstrings")
		return false
	if !FeaturesTarget["hotstrings"].Has("personal")
		FeaturesTarget["hotstrings"]["personal"] := Map()
	if !FeaturesTarget["hotstrings"]["personal"].Has(SectionName) {
		FeaturesTarget["hotstrings"]["personal"][SectionName] := Map(
			"enabled", false,
			"time_activation_seconds", 0)
	}
	return true
}

ToggleAllFeaturesOn(*) {
		MsgBox(t("dialog.enable_all.warning"))
		ToggleAllFeatures(1)
}
ToggleAllFeaturesOff(*) {
		ToggleAllFeatures(0)
}


; Clear every gesture, keyboard and script-control binding, appending the
; matching TOML writes to the shared ``Updates`` accumulator.
;
; ``Updates`` is taken BY VALUE on purpose. It is an Array, so it already
; mutates by reference, and the sibling walker _CollectFeatureFlipUpdates takes
; the same accumulator the same way. Declaring it ByRef here made the one call
; site (which passes the bare variable) raise a TypeError on every invocation of
; "tout desactiver" — AHK v2 requires & at the call site for a ByRef parameter.
_GlobalClearAllBindings(GestureTarget, KeyboardTarget, ScriptTarget, Updates) {
		global GESTURE_SLOTS, KEYBOARD_SHORTCUT_DEFAULTS, SCRIPT_SHORTCUT_SLOTS, _IniCache
		for Slot in GESTURE_SLOTS {
				GestureTarget[Slot] := "none"
				Updates.Push({ Section: "gestures", Key: Slot, Value: "none" })
		}
		KbWritten := Map()
		for Slot, _ in KEYBOARD_SHORTCUT_DEFAULTS {
				KeyboardTarget[Slot] := "none"
				Updates.Push({ Section: "shortcuts.keyboard", Key: Slot, Value: "none" })
				KbWritten[Slot] := true
		}
		if IsSet(_IniCache) and _IniCache.Has("shortcuts.keyboard") {
				for Slot, _ in _IniCache["shortcuts.keyboard"] {
						if !KbWritten.Has(Slot) {
								KeyboardTarget[Slot] := "none"
								Updates.Push({ Section: "shortcuts.keyboard", Key: Slot, Value: "none" })
						}
				}
		}
		for Slot in SCRIPT_SHORTCUT_SLOTS {
				ScriptTarget[Slot] := "none"
				Updates.Push({ Section: "shortcuts.script_control", Key: Slot, Value: "none" })
		}
}

; Recursively force every leaf under Node to Bool ("tout activer"/"tout
; desactiver"), mutating the caller's detached tree and appending the required
; {Section, Key, Value} TOML writes to Updates. Extracted out of ToggleAllFeatures
; as a standalone module function (rather than a nested closure) so the flip
; logic is directly testable without triggering ToggleAllFeatures's trailing
; Reload(). The walked nesting IS the TOML section: ManifestBuildFeaturesMap
; files each feature under its manifest section verbatim, so descending the tree
; reconstructs that section exactly. It used to need a per-leaf manifest lookup
; (ManifestResolveFeatureSection) because the tree was built with the ahk. driver
; prefix stripped, which merged a shared section and an AHK-only one under the
; same top-level key and made the walked path ambiguous. Lot 4 removed the silos
; and with them the ambiguity.
_CollectFeatureFlipUpdates(Bool, SectionPath, Node, Updates) {
		if (Type(Node) != "Map")
				return
		if Node.Has("enabled") and (Type(Node["enabled"]) != "Map") {
				Node["enabled"] := Bool
				Updates.Push({ Section: SectionPath, Key: "enabled", Value: Bool })
				return
		}
		for K, V in Node {
				if (Type(V) == "Map")
						_CollectFeatureFlipUpdates(Bool, SectionPath . "." . K, V, Updates)
				else {
						Node[K] := Bool
						Updates.Push({ Section: SectionPath, Key: K, Value: Bool })
				}
		}
}

ToggleAllFeatures(Value) {
		global Features, CategoryEnabled, ConfigurationFile, TapHold
		global GestureAssignments, KeyboardShortcutAssignments, ScriptShortcutAssignments
		if !IsSet(Features)
				return false
		Bool := (Value = true or Value = 1)
		CandidateFeatures := _HSDeepCloneMap(Features)
		CandidateCategories := CategoryEnabled.Clone()
		CandidateTapHold := _HSDeepCloneMap(TapHold)
		CandidateGestures := GestureAssignments.Clone()
		CandidateKeyboard := KeyboardShortcutAssignments.Clone()
		CandidateScript := ScriptShortcutAssignments.Clone()
		Updates := []
		for TopKey, TopVal in CandidateFeatures {
				if (Type(TopVal) == "Map")
						_CollectFeatureFlipUpdates(Bool, TopKey, TopVal, Updates)
		}
		for Category, _ in CandidateCategories {
				CandidateCategories[Category] := Bool
				Updates.Push({ Section: "category_enabled", Key: _CategoryEnabledKey(Category), Value: Bool })
		}
		CandidateGate := (Category) => _ConfigCandidateCategoryEnabled(
				CandidateCategories, Category)
		ApplyMasterGatesToFeatures(CandidateFeatures, CandidateTapHold, CandidateGate, LoggerDebug)
		Updates.Push({ Section: "metrics", Key: WPMWidgetConst.CFG_VISIBLE, Value: Bool ? "1" : "0" })
		Updates.Push({ Section: "metrics", Key: WPMWidgetConst.CFG_COLORS,  Value: Bool ? "1" : "0" })
		Updates.Push({ Section: "metrics", Key: WPMWidgetConst.CFG_GRAPH,   Value: Bool ? "1" : "0" })
		if !Bool
				_GlobalClearAllBindings(CandidateGestures, CandidateKeyboard, CandidateScript, Updates)
		if !ConfigCommitUpdates(ConfigurationFile, Updates, "the bulk feature toggle")
				return false

		; Publish all coupled in-memory views in one non-yielding window. Every
		; expensive walk and the file write happened against detached candidates.
		PreviousCritical := Critical("On")
		try {
				Features := CandidateFeatures
				CategoryEnabled := CandidateCategories
				GestureAssignments := CandidateGestures
				KeyboardShortcutAssignments := CandidateKeyboard
				ScriptShortcutAssignments := CandidateScript
				TapHold := CandidateTapHold
				WPMWidget.visible := Bool
				WPMWidget.use_colors := Bool
				WPMWidget.show_graph := Bool
		} finally {
				Critical(PreviousCritical)
		}
		return ReloadPreservingSuspend()
}

ToggleAllHotstringsOn(*) {
		ToggleAllHotstrings(1)
}
ToggleAllHotstringsOff(*) {
		ToggleAllHotstrings(0)
}
ToggleAllHotstrings(Value) {
		global CategoryEnabled, ConfigurationFile, Features
		Bool := (Value = true or Value = 1)
		CandidateCategories := CategoryEnabled.Clone()
		CandidateFeatures := _HSDeepCloneMap(Features)
		CandidateCategories["Hotstrings"] := Bool
		Updates := [{ Section: "category_enabled", Key: "hotstrings", Value: Bool }]
		Entries := []
		for V2Path in _CollectAllHotstringsV2Paths(CandidateFeatures)
				Entries.Push(Map("path", V2Path, "value", Bool))
		Applied := _ConfigStageFeatureEntries(CandidateFeatures, Entries, Updates)
		if (Applied != Entries.Length)
				return ConfigReportPersistenceFailure("the bulk hotstring toggle", 0,
					"one or more feature paths could not be resolved")
		if !ConfigCommitUpdates(ConfigurationFile, Updates, "the bulk hotstring toggle")
				return false
		PreviousCritical := Critical("On")
		try {
				CategoryEnabled := CandidateCategories
				Features := CandidateFeatures
		} finally {
				Critical(PreviousCritical)
		}
		return ReloadPreservingSuspend()
}

IsCategoryAllEnabled(Categories) {
	if (Categories.Length == 0)
		return true
	for Cat in Categories {
		if !IsCategoryGated(Cat)
			return false
	}
	return true
}

; Deep-clone a (possibly nested) Map. Used to snapshot per-section hotstring
; Features so a live category toggle can restore them independently of later
; mutations. Non-Map values are returned as-is (leaf bool / number / string).
_HSDeepCloneMap(M) {
		if (Type(M) != "Map") {
				return M
		}
		Out := Map()
		for K, V in M {
				Out[K] := _HSDeepCloneMap(V)
		}
		return Out
}

; Snapshots a category from detached Features into a detached snapshot Map.
_HSSnapshotCategoryTo(FeaturesTarget, SnapshotTarget, V2Cat) {
		if (FeaturesTarget.Has("hotstrings") and FeaturesTarget["hotstrings"].Has(V2Cat))
				SnapshotTarget[V2Cat] := _HSDeepCloneMap(FeaturesTarget["hotstrings"][V2Cat])
}

; Restores a category into detached Features from a detached snapshot Map.
_HSRestoreCategoryFrom(FeaturesTarget, SnapshotTarget, V2Cat) {
		if !(SnapshotTarget.Has(V2Cat) and FeaturesTarget.Has("hotstrings")
				and FeaturesTarget["hotstrings"].Has(V2Cat))
				return
		Target := FeaturesTarget["hotstrings"][V2Cat]
		for Section, SecMap in SnapshotTarget[V2Cat]
				Target[Section] := _HSDeepCloneMap(SecMap)
}

; Snapshot one category's current (un-gated) section states into _HSCategorySnapshot.
_HSSnapshotCategory(V2Cat) {
		global Features, _HSCategorySnapshot
		if IsSet(Features) and IsSet(_HSCategorySnapshot)
				_HSSnapshotCategoryTo(Features, _HSCategorySnapshot, V2Cat)
}

; Snapshot every hotstring category. Called once at boot, before gating.
_HSSnapshotAllCategories() {
		global Features
		if (IsSet(Features) and Features.Has("hotstrings")) {
				for V2Cat, _ in Features["hotstrings"] {
						_HSSnapshotCategory(V2Cat)
				}
		}
}

; Restore a category's section states from the snapshot, in place (the category Map
; keeps its identity; each section entry is replaced with a fresh clone).
_HSRestoreCategory(V2Cat) {
		global Features, _HSCategorySnapshot
		; IsSet on BOTH globals. _HSCategorySnapshot is declared in ErgoptiPlus.ahk,
		; which the headless test harness does not load, so reading it first threw an
		; unset error before the IsSet(Features) guard beside it could apply.
		if !(IsSet(_HSCategorySnapshot) and _HSCategorySnapshot.Has(V2Cat) and IsSet(Features)
				and Features.Has("hotstrings") and Features["hotstrings"].Has(V2Cat)) {
				return
		}
		_HSRestoreCategoryFrom(Features, _HSCategorySnapshot, V2Cat)
}

; Resolves a category gate against a detached candidate rather than the live
; global Map, so master-gate application can finish before the atomic publish.
_ConfigCandidateCategoryEnabled(CategoryTarget, Category) {
		global CATEGORY_FOLLOWS_HOTSTRINGS_MASTER
		if CATEGORY_FOLLOWS_HOTSTRINGS_MASTER.Has(Category)
				return CategoryTarget.Get("Hotstrings", true)
		return CategoryTarget.Get(Category, true)
}

; Hotstring sub-categories whose entire content the live rebuild can apply, so
; flipping their master gate rebuilds in-process instead of Reloading. Only Rolls
; and SFBsReduction qualify: every other gated hotstring category holds a feature
; the rebuild can't apply (DistancesReduction -> the E-circumflex deadkey,
; Autocorrection -> the multiple-punctuation rule, MagicKey -> the J-to-star layout
; remap) or is the Hotstrings master that gates those too.
_IsLiveHotstringCategory(Category) {
		static Live := Map("Rolls", true, "SFBsReduction", true)
		return Live.Has(Category)
}

ToggleCategoryAllFeatures(Category, Value) {
		global CategoryEnabled, ConfigurationFile, Features, TapHold, _HSCategorySnapshot
		Bool := (Value = true or Value = 1)
		if _IsLiveHotstringCategory(Category) {
				V2Cat := _CategoryEnabledKey(Category)
				try LoggerDebug("Menu", "Live category toggle: {1} -> {2}.", Category, Bool ? "ON" : "OFF")
				CandidateFeatures := _HSDeepCloneMap(Features)
				CandidateCategories := CategoryEnabled.Clone()
				CandidateTapHold := _HSDeepCloneMap(TapHold)
				if IsSet(_HSCategorySnapshot)
						CandidateSnapshot := _HSDeepCloneMap(_HSCategorySnapshot)
				else
						CandidateSnapshot := Map()
				if Bool
						_HSRestoreCategoryFrom(CandidateFeatures, CandidateSnapshot, V2Cat)
				else
						_HSSnapshotCategoryTo(CandidateFeatures, CandidateSnapshot, V2Cat)
				CandidateCategories[Category] := Bool
				CandidateGate := (CandidateCategory) => _ConfigCandidateCategoryEnabled(
						CandidateCategories, CandidateCategory)
				ApplyMasterGatesToFeatures(CandidateFeatures, CandidateTapHold, CandidateGate, LoggerDebug)
				Updates := [{ Section: "category_enabled", Key: V2Cat, Value: Bool }]
				if !ConfigCommitUpdates(ConfigurationFile, Updates, "the '" . Category . "' category toggle")
						return false

				; Only reference swaps sit under Critical. Candidate construction,
				; manifest I/O and persistence all completed before this window.
				_TcafCrit := Critical("On")
				try {
						Features := CandidateFeatures
						CategoryEnabled := CandidateCategories
						TapHold := CandidateTapHold
						_HSCategorySnapshot := CandidateSnapshot
				} finally {
						Critical(_TcafCrit)
				}
				LoggerStart("Menu", "Applying live category toggle for {1}…", Category)
				RebuildHotstringsLive()
				LoggerSuccess("Menu", "Live category toggle applied for {1}.", Category)
				return true
		}
		CandidateCategories := CategoryEnabled.Clone()
		CandidateCategories[Category] := Bool
		Updates := [{ Section: "category_enabled", Key: _CategoryEnabledKey(Category), Value: Bool }]
		if !ConfigCommitUpdates(ConfigurationFile, Updates, "the '" . Category . "' category toggle")
				return false
		CategoryEnabled := CandidateCategories
		return ReloadPreservingSuspend()
}

; Force every section of one hotstring category on/off (bulk action), scoped to
; a single manifest section. Mirrors ToggleAllHotstrings but per-category:
; enabling also lifts the Hotstrings master gate and (when the category has one)
; the category gate, so the activation is immediately effective; disabling just
; clears the sections. ``V1Cat`` is the PascalCase category id (e.g. "Rolls",
; "DynamicHotstrings").
ToggleCategoryAllSections(V1Cat, Enable) {
		global CategoryEnabled, ConfigurationFile, _LegacyTopCategoryMap, Features
		Bool := (Enable = true or Enable = 1)
		V2Section := _LegacyTopCategoryMap.Has(V1Cat) ? _LegacyTopCategoryMap[V1Cat] : ""
		if (V2Section == "") {
				try LoggerWarn("Menu", "ToggleCategoryAllSections: no v2 section for '{1}' — skipped.", V1Cat)
				return
		}
		CandidateCategories := CategoryEnabled.Clone()
		CandidateFeatures := _HSDeepCloneMap(Features)
		Updates := []
		if Bool {
				; Master gate must be on for any hotstring to fire.
				if !CandidateCategories.Has("Hotstrings") or !CandidateCategories["Hotstrings"] {
						CandidateCategories["Hotstrings"] := true
						Updates.Push({ Section: "category_enabled", Key: "hotstrings", Value: true })
				}
				; Lift this category's own gate too, when it has one (flat categories do;
				; DynamicHotstrings / Personal follow the master directly).
				if (CandidateCategories.Has(V1Cat) and !CandidateCategories[V1Cat]) {
						CandidateCategories[V1Cat] := true
						Updates.Push({ Section: "category_enabled", Key: _CategoryEnabledKey(V1Cat), Value: true })
				}
		}
		Entries := []
		for _, Entry in ManifestFeaturesForSection(V2Section)
				Entries.Push(Map("path", Entry["path"], "value", Bool))
		Applied := _ConfigStageFeatureEntries(CandidateFeatures, Entries, Updates)
		if (Applied != Entries.Length)
				return ConfigReportPersistenceFailure("the '" . V1Cat . "' section toggle", 0,
					"one or more feature paths could not be resolved")
		if !ConfigCommitUpdates(ConfigurationFile, Updates, "the '" . V1Cat . "' section toggle")
				return false
		PreviousCritical := Critical("On")
		try {
				CategoryEnabled := CandidateCategories
				Features := CandidateFeatures
		} finally {
				Critical(PreviousCritical)
		}
		return ReloadPreservingSuspend()
}

; Force every personal hotstring section (from personal_hotstrings.toml) on/off.
; Personal sections are runtime-discovered, so their v2 paths are built from the
; TOML section names (hotstrings.personal.<lower(section)>). Enabling lifts the
; Hotstrings master gate so the sections fire immediately.
HS_TogglePersonalAllSections(Enable) {
		global CategoryEnabled, ConfigurationFile, ScriptInformation, Features
		Bool := (Enable = true or Enable = 1)
		PersonalSectionsPath := IsSet(ScriptInformation) ? ScriptInformation.Get("PersonalTomlPath", "") : ""
		if (PersonalSectionsPath == "" or !FileExist(PersonalSectionsPath)) {
				; Reachable on a fresh install (no personal_hotstrings.toml yet) or after
				; relocating the config dir: the menu item does nothing and says nothing.
				; The sibling ToggleCategoryAllSections logs on the equivalent bail.
				try LoggerWarn("Hotstrings", "Personal sections toggle ignored — no personal hotstrings file at '{1}'.", PersonalSectionsPath)
				return
		}
		CandidateCategories := CategoryEnabled.Clone()
		CandidateFeatures := _HSDeepCloneMap(Features)
		Updates := []
		if (Bool and (!CandidateCategories.Has("Hotstrings") or !CandidateCategories["Hotstrings"])) {
				CandidateCategories["Hotstrings"] := true
				Updates.Push({ Section: "category_enabled", Key: "hotstrings", Value: true })
		}
		Data := ReadPersonalToml()
		Entries := []
		for _, SecName in Data["sections_order"] {
				if (SecName != "-") {
						_ConfigSeedPersonalHotstring(CandidateFeatures, SecName)
						Entries.Push(Map("path", "hotstrings.personal." . StrLower(SecName), "value", Bool))
				}
		}
		Applied := _ConfigStageFeatureEntries(CandidateFeatures, Entries, Updates)
		if (Applied != Entries.Length)
				return ConfigReportPersistenceFailure("the personal-hotstring section toggle", 0,
					"one or more personal feature paths could not be resolved")
		if !ConfigCommitUpdates(ConfigurationFile, Updates, "the personal-hotstring section toggle")
				return false
		PreviousCritical := Critical("On")
		try {
				CategoryEnabled := CandidateCategories
				Features := CandidateFeatures
		} finally {
				Critical(PreviousCritical)
		}
		return ReloadPreservingSuspend()
}

_CategoryEnabledKey(Category) {
		switch Category {
				case "Layout":     return "layout"
				case "Shortcuts":  return "shortcuts"
				case "Hotstrings": return "hotstrings"
				case "TapHolds":   return "tap_holds"
				; Hotstring sub-category gates — snake_case to match the v2 schema.
				case "DistancesReduction": return "distances_reduction"
				case "SFBsReduction":      return "sfbs_reduction"
				case "MagicKey":           return "magic_key"
				default: return StrLower(Category)
		}
}

_ConfigCollectFullSaveUpdates(FeaturesSource := unset, MenuSource := unset) {
		global Features, ScriptInformation, ScriptShortcutAssignments
		global GestureAssignments, KeyboardShortcutAssignments
		global LOGGER_MIN_LEVEL, LOGGER_DEFAULT_LEVEL
		global _LLM_Menu_Loaded, _LLM_Menu
		global CategoryEnabled
		global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL
		global UPDATER_INI_SECTION, UPDATER_INI_KEY, UPDATER_INI_INTERVAL_KEY
		Updates := []
		HasFeatureCandidate := IsSet(FeaturesSource)
		FeatureState := HasFeatureCandidate ? FeaturesSource
			: (IsSet(Features) ? Features : false)
		HasMenuCandidate := IsSet(MenuSource)
		MenuState := HasMenuCandidate ? MenuSource
			: (IsSet(_LLM_Menu) ? _LLM_Menu : false)
		MenuReady := HasMenuCandidate
			|| (IsSet(_LLM_Menu_Loaded) && _LLM_Menu_Loaded)
		if (FeatureState is Map) {
				; Full-save collection is speculative until TOML_BatchWrite commits. Keep
				; LLM menu reconciliation detached so a refused writer cannot publish a
				; state that only existed in the failed serialization candidate.
				FeatureSnapshot := _HSDeepCloneMap(FeatureState)
				if IsSet(_LLM_Menu_SyncToFeatures)
						&& MenuReady && (MenuState is Map)
						&& !_LLM_Menu_SyncToFeatures(FeatureSnapshot, MenuState)
						throw Error("LLM menu state could not be reconciled into the full-save candidate")
				_CollectFeatureUpdates(Updates, "",
						_PruneMasterGatedFeatures(FeatureSnapshot))
				Updates.Push({ Section: "_meta", Key: "schema_version", Value: 2 })
		}
		Updates.Push({ Section: "script", Key: "locale", Value: I18nGetLocale() })
		Updates.Push({ Section: "script", Key: "log_level", Value: IsSet(LOGGER_MIN_LEVEL) ? LOGGER_MIN_LEVEL : LOGGER_DEFAULT_LEVEL })
		Updates.Push({ Section: "hotstrings", Key: "trigger_char", Value: ScriptInformation["MagicKey"] })
		if IsSet(ScriptShortcutAssignments) {
				for Slot, Action in ScriptShortcutAssignments
						Updates.Push({ Section: "shortcuts.script_control", Key: Slot, Value: Action })
		}
		if IsSet(KeyboardShortcutAssignments) {
				for Slot, Action in KeyboardShortcutAssignments
						Updates.Push({ Section: "shortcuts.keyboard", Key: Slot, Value: Action })
		}
		if IsSet(GestureAssignments) {
				for Slot, Action in GestureAssignments
						Updates.Push({ Section: "gestures", Key: Slot, Value: Action })
		}
		apps := []
		for proc, _ in MetricsFilters.disabled_apps
				apps.Push(proc)
		Updates.Push({ Section: "metrics", Key: "metrics_enabled", Value: TOML_Bool(MetricsShortcuts.enabled) })
		Updates.Push({ Section: "metrics", Key: "metrics_shortcut_typing", Value: MetricsShortcuts.typing_str })
		Updates.Push({ Section: "metrics", Key: "metrics_shortcut_apps", Value: MetricsShortcuts.apps_str })
		Updates.Push({ Section: "metrics", Key: "metrics_wpm_menubar_colors", Value: MetricsShortcuts.wpm_menubar_colors })
		Updates.Push({ Section: "metrics", Key: "private_filter_enabled", Value: TOML_Bool(MetricsFilters.private_browsing) })
		Updates.Push({ Section: "metrics", Key: "secure_filter_enabled", Value: TOML_Bool(MetricsFilters.secure_field) })
		Updates.Push({ Section: "metrics", Key: "system_auth_filter_enabled", Value: TOML_Bool(MetricsFilters.system_auth) })
		Updates.Push({ Section: "metrics", Key: "encrypt", Value: TOML_Bool(MetricsFilters.encrypt) })
		Updates.Push({ Section: "metrics", Key: "metrics_disabled_apps", Value: apps })
		Updates.Push({ Section: "metrics", Key: WPMWidgetConst.CFG_VISIBLE, Value: WPMWidget.visible ? "1" : "0" })
		Updates.Push({ Section: "metrics", Key: WPMWidgetConst.CFG_X,       Value: String(WPMWidget.pos_x) })
		Updates.Push({ Section: "metrics", Key: WPMWidgetConst.CFG_Y,       Value: String(WPMWidget.pos_y) })
		Updates.Push({ Section: "metrics", Key: WPMWidgetConst.CFG_COLORS,  Value: WPMWidget.use_colors ? "1" : "0" })
		Updates.Push({ Section: "metrics", Key: WPMWidgetConst.CFG_GRAPH,   Value: WPMWidget.show_graph  ? "1" : "0" })
		; The flat [llm] keys below round-trip through _LLM_Menu DIRECTLY (not via
		; Features), so the _LLM_Menu_SyncToFeatures gate above does not cover them. The
		; boot-armed SaveFullConfig timer fires ~0-100 ms after _DriverReady, while
		; LLM_Menu_Init runs seconds later at the end of the deferred menu build — so
		; without this dedicated gate the first flush writes module defaults
		; (onboarding_seen=0, empty overrides, default trigger_shortcut/ollama_port/…)
		; over the user's saved values. Skipping is safe: TOML_BatchWrite preserves keys
		; it does not re-collect, so the on-disk values survive until the menu has loaded.
		if (MenuReady && (MenuState is Map)) {
				Updates.Push({ Section: "llm", Key: "onboarding_seen", Value: MenuState["onboarding_seen"] ? "1" : "0" })
				_AppOverridesStr := ""
				for _AppName, _AppProfileId in MenuState["app_profile_overrides"] {
						if (_AppOverridesStr != "")
								_AppOverridesStr .= ";"
						_AppOverridesStr .= _AppName . "=" . _AppProfileId
				}
				Updates.Push({ Section: "llm", Key: "app_profile_overrides", Value: _AppOverridesStr })
				if IsSet(_LLM_Menu_AppendPersistedUpdates)
						_LLM_Menu_AppendPersistedUpdates(Updates, MenuState)
		}
		if IsSet(CategoryEnabled) {
				for _CatName, _CatBool in CategoryEnabled
						Updates.Push({ Section: "category_enabled", Key: _CategoryEnabledKey(_CatName), Value: TOML_Bool(_CatBool) })
		}
		if IsSet(UPDATER_CHECK_INTERVAL)
				Updates.Push({ Section: UPDATER_INI_SECTION, Key: UPDATER_INI_INTERVAL_KEY, Value: UPDATER_CHECK_INTERVAL })
		if IsSet(UPDATER_CHANNEL)
				Updates.Push({ Section: UPDATER_INI_SECTION, Key: UPDATER_INI_KEY, Value: UPDATER_CHANNEL })
		return Updates
}

SaveFullConfig(WriterFn := 0, TimerFn := 0, RegisterRequest := true,
		ExistingOwner := 0, CollectFn := 0, &RequestedGeneration := 0) {
		InheritedCritical := A_IsCritical
		if InheritedCritical {
			; Collectors traverse live state and writers perform durable TOML I/O.
			; The path owner supplies serialization without freezing input dispatch.
			Critical("Off")
			try return SaveFullConfig(WriterFn, TimerFn, RegisterRequest,
				ExistingOwner, CollectFn, &RequestedGeneration)
			finally Critical(InheritedCritical)
		}
		global ConfigurationFile
		global CONFIG_SAVE_FAILED, CONFIG_SAVE_OK, CONFIG_SAVE_DEFERRED
		global CONFIG_FULL_SAVE_RETRY_DELAY_MS, CONFIG_FULL_SAVE_FAILURE_RETRY_DELAY_MS
		; Guard: the driver must be fully initialised before writing config — prevents
		; a partial config flush triggered by the -500 ms boot timer from clobbering the
		; user's file with uninitialised defaults (e.g. before Features or GestureAssignments
		; have been populated by ApplyConfigToml and the deferred tray-menu build).
		global _DriverReady
		; Guard: refuse to serialize the feature tree when boot could not READ an
		; existing config.toml. In that case ApplyConfigToml applied nothing and the
		; tree below is ManifestBuildFeaturesMap() DEFAULTS — writing it out replaces
		; the user's whole configuration with factory values. TOML_BatchWrite's own
		; TOML_ReadFailed guard cannot catch this: it re-parses at write time, and a
		; transient lock (sync client, AV scan, backup) has usually cleared by then,
		; so the write looks perfectly safe while the payload is already wrong.
		; Returns false — not a bare return — so a caller (and the regression test)
		; can tell "refused" from "deferred until ready" and from a completed save.
		global _ConfigBootReadFailed
		if (IsSet(_ConfigBootReadFailed) && _ConfigBootReadFailed) {
			try LoggerError("ConfigIO", "Refusing to save: config.toml could not be read at boot, so the in-memory feature tree holds defaults rather than the user's settings. Restart the driver once the file is readable.")
			return CONFIG_SAVE_FAILED
		}
		RequestedGeneration := 0
		if RegisterRequest {
			RequestedGeneration := _ConfigFullSaveRequest(true, ConfigurationFile)
			if !RequestedGeneration {
				try LoggerError("ConfigIO", "Refusing a new full save after terminal or disk-reload authority was sealed.")
				return CONFIG_SAVE_FAILED
			}
		}
		if !_ConfigFullSaveHasPending()
			return CONFIG_SAVE_OK
		BoundPath := _ConfigFullSaveBoundPath()
		; A deferred generation belongs to the path that accepted it. Re-reading
		; ConfigurationFile here used to silently rebase old-path work onto a newly
		; selected config directory. Refuse before collecting live state: that state
		; may already describe the new path and must never overwrite the old file.
		if (BoundPath = "" || !_ConfigFullSavePathMatches(ConfigurationFile)) {
			try LoggerError("ConfigIO", "Refusing to rebase a pending full save from '{1}' onto '{2}'. Settle the original path before publishing a config relocation.",
				BoundPath, ConfigurationFile)
			return CONFIG_SAVE_FAILED
		}
		if !_DriverReady {
			return _ConfigArmFullSaveRetry(CONFIG_FULL_SAVE_RETRY_DELAY_MS, TimerFn)
				? CONFIG_SAVE_DEFERRED
				: CONFIG_SAVE_FAILED
		}
		; Claim before reading ANY live global. Waiting here would deadlock: an AHK
		; callback that interrupted the owner cannot let that owner resume. Defer a
		; coalesced one-shot instead; it will collect the post-publication state.
		BorrowedOwner := ExistingOwner is Object
		if BorrowedOwner {
			if !_ConfigWriteLeaseOwns(ExistingOwner, BoundPath) {
				try LoggerError("ConfigIO", "Refusing a full save through a stale configuration owner.")
				return CONFIG_SAVE_FAILED
			}
			OwnerToken := ExistingOwner
		} else {
			OwnerToken := _ConfigWriteLeaseTryAcquire(BoundPath, "full")
		}
		if !(OwnerToken is Object) {
			return _ConfigArmFullSaveRetry(CONFIG_FULL_SAVE_RETRY_DELAY_MS, TimerFn)
				? CONFIG_SAVE_DEFERRED
				: CONFIG_SAVE_FAILED
		}
		TargetGeneration := _ConfigFullSaveCapture()
		Result := CONFIG_SAVE_FAILED
		try {
				Phase := "collector"
				try {
						Updates := HasMethod(CollectFn, "Call")
								? CollectFn.Call()
								: _ConfigCollectFullSaveUpdates()
						if !(Updates is Array)
								throw TypeError("The full configuration collector must return an Array")
						; Do NOT FileDelete before writing — TOML_BatchWrite already performs an
						; atomic write (temp file + rename). A FileDelete here creates a data-loss
						; window: if a Reload() or thread interrupt fires between the delete and the
						; write, the user's config is permanently gone with no replacement.
						Phase := "writer"
				; RETURNED, not discarded. TOML_BatchWrite fails without throwing when
				; the staging file cannot be opened or the atomic replace is refused, and
				; every caller that dropped this boolean turned that into a silent no-op:
				; the live toggles mutate memory, re-init the engine and rebuild the menu
				; with no Reload, so memory, engine and menu all showed a state that never
				; reached disk — and the next restart silently undid it.
				if HasMethod(WriterFn, "Call")
					Written := WriterFn.Call(BoundPath, Updates)
				else
					Written := TOML_BatchWrite(BoundPath, Updates)
				} catch as Err {
						Written := false
						try LoggerError("ConfigIO", "The full configuration {1} raised an error: {2}.",
								Phase, Err.Message)
				}
				if ((Written is Integer) && Written == 1)
					Result := CONFIG_SAVE_OK
				else
					Result := CONFIG_SAVE_FAILED
				if (Result = CONFIG_SAVE_OK)
						_ConfigFullSaveAcknowledge(TargetGeneration)
		} finally {
			if !BorrowedOwner
				_ConfigWriteLeaseRelease(OwnerToken)
		}
		if _ConfigFullSaveHasPending() {
			RetryDelay := (Result = CONFIG_SAVE_OK)
				? CONFIG_FULL_SAVE_RETRY_DELAY_MS
				: CONFIG_FULL_SAVE_FAILURE_RETRY_DELAY_MS
			if !_ConfigArmFullSaveRetry(RetryDelay, TimerFn)
				Result := CONFIG_SAVE_FAILED
		}
		return Result
}

; Drains an already-recorded obligation. Both the deferred timer and the reload
; barrier use this entry so neither invents a fresh generation while checking
; whether work remains.
_ConfigDrainFullSave(WriterFn := 0, TimerFn := 0, ExistingOwner := 0,
		CollectFn := 0) {
	return SaveFullConfig(WriterFn, TimerFn, false, ExistingOwner, CollectFn)
}

; Resolves every accepted in-memory save before process death. Optional boot
; canonicalization and unreadable-boot state may be abandoned, but a user-facing
; obligation must reach the exact owned config path or refuse shutdown.
_ConfigFullSaveSettleTerminal(OwnerBundle, WriterFn := 0, TimerFn := 0,
		CollectFn := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return _ConfigFullSaveSettleTerminal(OwnerBundle, WriterFn,
			TimerFn, CollectFn)
		finally Critical(InheritedCritical)
	}
	global ConfigurationFile
	global CONFIG_SAVE_OK
	State := _ConfigFullSaveCoordinator()
	PreviousCritical := Critical("On")
	try {
		Requested := State.requested_generation
		Settled := State.settled_generation
		Required := State.terminal_required_generation
		BoundPath := State.bound_path
	} finally Critical(PreviousCritical)
	if Requested <= Settled
		return true
	; Only generations admitted as terminal-optional (the boot canonicalizer)
	; may be abandoned. _ConfigBootReadFailed is not provenance: a later user
	; mutation can enqueue a mandatory repair while that flag remains true. The
	; ordinary drain will refuse unsafe serialization and therefore keep such a
	; required generation pending, which correctly refuses process death.
	if Required <= Settled
		return _ConfigFullSaveAbandonThrough(Requested)
	if (BoundPath = "" || !_ConfigFullSavePathMatches(ConfigurationFile)) {
		try LoggerError("ConfigIO", "Terminal full-save drain refused because the active configuration path no longer matches the accepted generation path.")
		return false
	}
	OwnerToken := _ConfigWriteLeaseSelectOwner(OwnerBundle, BoundPath)
	if !(OwnerToken is Object) {
		try LoggerError("ConfigIO", "Terminal full-save drain refused a bundle that did not own config.toml.")
		return false
	}
	Result := _ConfigDrainFullSave(WriterFn, TimerFn, OwnerToken, CollectFn)
	return (Result is Integer) && Result == CONFIG_SAVE_OK
		&& !_ConfigFullSaveHasPending()
}

; Resolve the CategoryEnabled master-gate label that owns a Features node key
; ("layout" -> "Layout", "distances_reduction" -> "DistancesReduction"), or ""
; when that key has no dedicated gate. Derived from CategoryEnabled through
; _CategoryEnabledKey rather than a second table, so a new master gate is picked
; up here automatically instead of being silently unprotected.
_MasterGateLabelFor(NodeKey) {
		global CategoryEnabled
		if !IsSet(CategoryEnabled)
				return ""
		for Category, _Bool in CategoryEnabled {
				if (_CategoryEnabledKey(Category) == NodeKey)
						return Category
		}
		return ""
}

; True when the Features node named NodeKey may be serialized right now. A node
; with no gate is always persistable; a gated one only while its master is on.
_MasterGateAllowsPersist(NodeKey) {
		Label := _MasterGateLabelFor(NodeKey)
		if (Label == "")
				return true
		return IsCategoryGated(Label)
}

; Return a shallow view of Features with every master-gated-OFF branch removed,
; for the walker below to flatten.
;
; ApplyMasterGatesToFeatures (infra/master_gates.ahk) zeroes those branches IN
; PLACE as a RUNTIME gate, and its own contract states the per-feature state on
; disk is NOT touched and is restored at the next Reload once the master flips
; back on. SaveFullConfig had no notion of that distinction: it walked the same
; live map, so the boot-armed save wrote the runtime zeroes back as if they were
; the user's intent, and re-enabling the category later revealed every child
; unticked with nothing logged. TOML_BatchWrite preserves keys it does not
; re-collect, so omitting the branch is exactly what "leave the disk alone"
; means — the same mechanism the [llm] block already relies on.
_PruneMasterGatedFeatures(FeaturesMap) {
		Pruned := Map()
		if (Type(FeaturesMap) != "Map")
				return Pruned
		for TopKey, TopVal in FeaturesMap {
				; Non-Map top-level entries are skipped by the walker anyway.
				if (Type(TopVal) != "Map")
						continue
				if !_MasterGateAllowsPersist(TopKey) {
						try LoggerDebug("ConfigIO", "Not serializing '{1}': its master gate is off, so the in-memory tree holds runtime zeroes rather than the user's settings.", TopKey)
						continue
				}
				if (TopKey != "hotstrings") {
						Pruned[TopKey] := TopVal
						continue
				}
				; Hotstring sub-categories own gates independent of the Hotstrings
				; master and are zeroed the same way when theirs is off.
				SubTree := Map()
				for SubKey, SubVal in TopVal {
						if (Type(SubVal) == "Map" and !_MasterGateAllowsPersist(SubKey)) {
								try LoggerDebug("ConfigIO", "Not serializing 'hotstrings.{1}': its sub-category gate is off.", SubKey)
								continue
						}
						SubTree[SubKey] := SubVal
				}
				Pruned[TopKey] := SubTree
		}
		return Pruned
}

_CollectFeatureUpdates(Updates, SectionPath, Node) {
		if (Type(Node) != "Map")
				return
		for Key, Value in Node {
				if (SectionPath == "" and Type(Value) != "Map")
						continue
				Sub := (SectionPath == "") ? Key : SectionPath "." Key
				if (Type(Value) == "Map")
						_CollectFeatureUpdates(Updates, Sub, Value)
				else
						Updates.Push({ Section: SectionPath, Key: Key, Value: Value })
		}
}

; Presents one localized reset refusal without exposing a stale, deletion-only
; explanation. Typed transition results retain their exact stable status/kind
; pair so the user can identify the refused transaction in the error log.
_ConfigResetShowFailure(ReasonKey, Result := 0) {
	Reason := t(ReasonKey)
	if Result is Map {
		Status := Result.Has("status") && (Result["status"] is String)
			? Result["status"] : "malformed"
		Kind := Result.Has("kind") && (Result["kind"] is String)
			? Result["kind"] : "malformed_result"
		Reason := Format(Reason, Status, Kind)
	}
	try MsgBox(Format(t("dialog.reset_defaults.failed"), Reason),
		t("dialog.reset_defaults.failed_title"), "Iconx")
}

ReloadWithDefaultConfig(*) {
		global _ConfigDir, _AhkSubDir, ConfigurationFile, _PathsFile
		PreviousCritical := Critical("Off")
		try {
		AhkDir := _ConfigDir . _AhkSubDir
		TapHoldPath := AhkDir . "tap_hold.toml"
		ApiEntriesPath := AhkDir . "api_entries.json"
		TransitionPaths := [ConfigurationFile, TapHoldPath, ApiEntriesPath]
		AcquireResult := ConfigTransitionAcquireLifecycleBundle(_PathsFile,
			TransitionPaths)
		if !ConfigTransitionResultIs(AcquireResult, "bundle_acquired") {
			ConfigTransitionLogFailure("ConfigReset", AcquireResult)
				try LoggerError("Config", "Reset to defaults refused because another configuration transaction owns config.toml.")
				_ConfigResetShowFailure(
					"dialog.reset_defaults.reason.acquire", AcquireResult)
				return false
		}
		OwnerBundle := AcquireResult["bundle"]
		ReleaseBundle := true
		try {
				if !LLM_Menu_QuiesceTriggerForLifecycle(OwnerBundle) {
						try LoggerError("Config", "Reset to defaults refused because LLM trigger native recovery is incomplete.")
						_ConfigResetShowFailure(
							"dialog.reset_defaults.reason.trigger_recovery")
						return false
				}
				if !LLM_TriggerJournalPrepareDestructive(ConfigurationFile,
						OwnerBundle) {
						try LoggerError("Config", "Reset to defaults refused because LLM trigger journal recovery is incomplete.")
						_ConfigResetShowFailure(
							"dialog.reset_defaults.reason.trigger_journal")
						return false
				}
		; Write a minimal config so Onboarding_Run() skips the wizard on reload.
		; The user chose "reset defaults" — there is a separate "Setup wizard"
		; menu item for re-running the first-run flow. Without this placeholder
		; the deleted config.toml triggers Onboarding_Run unconditionally.
		; All three intentions share one WAL: the placeholder is target 1, then the
		; two deletions. A failed/colliding apply rolls every file back before this
		; function can report success or invoke Reload.
		TargetSpecs := _ConfigResetTransitionTargets(ConfigurationFile,
			TapHoldPath, ApiEntriesPath)
		CommitResult := ConfigTransitionCommitOwned(_PathsFile, TargetSpecs,
			OwnerBundle)
		if !ConfigTransitionResultIs(CommitResult, "committed_new") {
			ConfigTransitionLogFailure("ConfigReset", CommitResult)
			if CommitResult.Has("barrier_retained")
					&& (CommitResult["barrier_retained"] is Integer)
					&& CommitResult["barrier_retained"] == 1
				ReleaseBundle := false
			_ConfigResetShowFailure(
				"dialog.reset_defaults.reason.commit", CommitResult)
			return false
		}
		; Keep the destructive owner through Reload. Releasing here lets an
		; interrupting trigger edit repopulate the reset file or leave a fresh WAL
		; that makes Reload refuse after the user's files were already removed.
		Reloaded := ReloadPreservingSuspend(0, OwnerBundle)
		if (Reloaded is Integer) && Reloaded == 1
			return true
		RollbackResult := ConfigTransitionRollbackOwned(_PathsFile, OwnerBundle)
		if !ConfigTransitionResultIs(RollbackResult, "recovered_old")
				&& !ConfigTransitionResultIs(RollbackResult, "absent") {
			ConfigTransitionLogFailure("ConfigResetRollback", RollbackResult)
			if ConfigTransitionRetainBarrier(OwnerBundle)
				ReleaseBundle := false
			_ConfigResetShowFailure(
				"dialog.reset_defaults.reason.rollback", RollbackResult)
		} else
			_ConfigResetShowFailure(
				"dialog.reset_defaults.reason.reload_refused")
		return false
		} finally {
			if ReleaseBundle
				_ConfigWriteTerminalRelease(OwnerBundle)
		}
		} finally Critical(PreviousCritical)
}

ReadScriptShortcutsConfig() {
		global ScriptShortcutAssignments, SCRIPT_SHORTCUT_SLOTS, _IniCache, GESTURE_ACTIONS
		for Slot in SCRIPT_SHORTCUT_SLOTS {
				Value := IniCacheGet(_IniCache, "shortcuts.script_control", Slot)
				if (Value != "_" and (Value == "none" or GESTURE_ACTIONS.Has(Value)))
						ScriptShortcutAssignments[Slot] := Value
				else if (Value != "_")
						; Mirrors ReadKeyboardShortcutsConfig. An action retired by an
						; upgrade, or a hand-edited config, leaves the slot on its
						; compiled-in default — so AltGr+Enter fires a DIFFERENT action than
						; the one configured, with nothing in the log to explain it.
						try LoggerWarn("Shortcuts", "Script slot '{1}' has unknown action '{2}' — falling back to '{3}'.", Slot, Value,
								ScriptShortcutAssignments.Has(Slot) ? ScriptShortcutAssignments[Slot] : "(none)")
		}
}

ResetScriptComboKeys(SuffixSC) {
		global _ALTGR_KANA_FIXUP
		if !(IsSet(_ALTGR_KANA_FIXUP) and _ALTGR_KANA_FIXUP)
				return
		KeyWait(SuffixSC, "T2")
		if !GetKeyState(SuffixSC, "P")
				SendEvent("{SC138 Up}")
}

; The ONLY actions allowed to run while the driver is suspended. The script AltGr
; chords keep a dedicated suspend-exempt hotkey set purely so script management stays
; keyboard-reachable while paused (otherwise a user who paused from the tray has no
; keyboard way back). Anything else the user assigns to those slots must obey
; "pause = tout éteint" — single source of truth for that allowlist.
global SCRIPT_SHORTCUT_SUSPEND_ALLOWED := Map(
		"script_pause_toggle", true,
		"script_reload", true,
		"script_quit", true,
		"open_personal_shortcuts", true,
)

RunScriptShortcutAction(Slot) {
		global ScriptShortcutAssignments, GESTURE_ACTIONS, SCRIPT_SHORTCUT_FALLBACKS
		global SCRIPT_SHORTCUT_SUSPEND_ALLOWED
		Action := ScriptShortcutAssignments.Has(Slot) ? ScriptShortcutAssignments[Slot] : "none"
		if (Action == "none") {
				SendInput(SCRIPT_SHORTCUT_FALLBACKS[Slot])
				return
		}
		if !GESTURE_ACTIONS.Has(Action) {
				SendInput(SCRIPT_SHORTCUT_FALLBACKS[Slot])
				return
		}
		; While suspended these chords stay armed ONLY for script management. Without this
		; scope check the exemption silently widened to whatever the user assigned, so a
		; paused driver still fired arbitrary gesture actions. Fall back to the slot's
		; native key instead, exactly like an unassigned slot.
		if (A_IsSuspended and !SCRIPT_SHORTCUT_SUSPEND_ALLOWED.Has(Action)) {
				SendInput(SCRIPT_SHORTCUT_FALLBACKS[Slot])
				return
		}
		GestureInvokeAction(Action, GestureBindingId("script", Slot))
}

SetScriptShortcutAction(Slot, ActionName) {
		global ScriptShortcutAssignments
		if !GestureAssignConfiguredAction(&ScriptShortcutAssignments,
				"script", "shortcuts.script_control", Slot, ActionName)
				return false
		return ReloadPreservingSuspend()
}

BuildScriptShortcutsMenu() {
		global SCRIPT_SHORTCUT_SLOTS, SCRIPT_SHORTCUT_LABELS, ScriptShortcutAssignments, GESTURE_ACTIONS
		Rows := []
		for Slot in SCRIPT_SHORTCUT_SLOTS {
				Current := ScriptShortcutAssignments.Has(Slot) ? ScriptShortcutAssignments[Slot] : "none"
				CurrentLabel := GESTURE_ACTIONS.Has(Current) ? GestureActionDisplayLabel(Current, GestureBindingId("script", Slot)) : t("dialog.action_picker.disabled")
				SlotLabel := t(SCRIPT_SHORTCUT_LABELS[Slot])
				Rows.Push(Map(
					"label",  SlotLabel . " : " . CurrentLabel,
					"action", ((_s, _l) => (*) => ShowActionPicker(_l, ScriptShortcutAssignments.Has(_s) ? ScriptShortcutAssignments[_s] : "none", (Id) => SetScriptShortcutAction(_s, Id)))(Slot, SlotLabel)))
		}
		SMenu := Menu()
		MenuRenderer_AppendRows(SMenu, "shortcuts_menu", "script_control", Rows)
		return SMenu
}

/**
 * Resolves a keyboard-shortcut slot id to a canonical chord string.
 *
 * The slot id is our own vocabulary ("ctrl_shift_v", "win_sc029"); the chord is
 * the cross-driver one. Everything AutoHotkey-specific — that Ctrl is "^", that
 * Space is "{Space}" — now lives in the HotkeyRegistrar adapter, which is the
 * only layer allowed to know it. This function previously emitted a native
 * AutoHotkey spec directly, which is why the macOS driver had to reimplement the
 * same slot grammar from scratch.
 * @param {String} SlotId e.g. "ctrl_shift_v", "win_e", "alt_space".
 * @returns {String} The canonical chord, or "" when the slot names no modifier.
 */
_KeyboardSlotChord(SlotId) {
		if SubStr(SlotId, 1, 10) = "ctrl_shift"
				Mods := ["ctrl", "shift"]
		else if SubStr(SlotId, 1, 4) = "ctrl"
				Mods := ["ctrl"]
		else if SubStr(SlotId, 1, 3) = "win"
				Mods := ["cmd"]
		else if SubStr(SlotId, 1, 3) = "alt"
				Mods := ["alt"]
		else
				return ""
		if SubStr(SlotId, 1, 10) = "ctrl_shift"
				Suffix := SubStr(SlotId, 12)
		else
				Suffix := SubStr(SlotId, InStr(SlotId, "_") + 1)
		; Slot-id spellings for keys whose canonical name is a character. The
		; brace-wrapped AutoHotkey forms that used to live here moved to the adapter
		static _SlotKeyNames := Map("period", ".", "comma", ",", "enter", "return")
		Key := _SlotKeyNames.Has(Suffix) ? _SlotKeyNames[Suffix] : Suffix
		Formatted := ChordFormat(Mods, Key)
		return Formatted["ok"] ? Formatted["label"] : ""
}

ReadKeyboardShortcutsConfig() {
		global KeyboardShortcutAssignments, KEYBOARD_SHORTCUT_DEFAULTS, _IniCache, GESTURE_ACTIONS
		for Slot, Action in KEYBOARD_SHORTCUT_DEFAULTS
				KeyboardShortcutAssignments[Slot] := Action
		; Read EVERY persisted slot, not just the shipped defaults.
		;
		; The slot picker offers every modifier chord in GESTURE_ACTIONS — roughly
		; 600 of them — while KEYBOARD_SHORTCUT_DEFAULTS holds 15. Iterating only
		; the defaults meant a slot the user added (say win_b) was written to
		; config.toml by SetKeyboardShortcutAction, and then never read back on the
		; Reload that same function triggers: absent from KeyboardShortcutAssignments,
		; so no hotkey is registered and the entry vanishes from the menu too. The
		; value stays on disk, so nothing looks lost — the addition just appears not
		; to have taken.
		;
		; _GlobalClearAllBindings already walks _IniCache for exactly these
		; non-default slots, which is what shows this to be a drift between the
		; clear path and the read path rather than a deliberate restriction.
		SlotsToRead := Map()
		for Slot, _ in KEYBOARD_SHORTCUT_DEFAULTS
				SlotsToRead[Slot] := true
		if IsSet(_IniCache) and _IniCache.Has("shortcuts.keyboard") {
				for Slot, _ in _IniCache["shortcuts.keyboard"]
						SlotsToRead[Slot] := true
		}

		for Slot, _ in SlotsToRead {
				Value := IniCacheGet(_IniCache, "shortcuts.keyboard", Slot)
				if (Value != "_" and (Value == "none" or GESTURE_ACTIONS.Has(Value)))
						KeyboardShortcutAssignments[Slot] := Value
				else if (Value != "_")
						; Falling back to the shipped default is the right behaviour; doing
						; it silently is not. The key then fires a DIFFERENT action than the
						; one the user configured, and nothing anywhere says why. A slot with
						; no default resolves to "" here, which reads as "unassigned".
						try LoggerWarn("Shortcuts", "Keyboard slot '{1}' has unknown action '{2}' — falling back to '{3}'.", Slot, Value,
								KeyboardShortcutAssignments.Has(Slot) ? KeyboardShortcutAssignments[Slot] : "(none)")
		}
}

RunKeyboardShortcutAction(SlotId) {
		global KeyboardShortcutAssignments, GESTURE_ACTIONS
		Action := KeyboardShortcutAssignments.Has(SlotId) ? KeyboardShortcutAssignments[SlotId] : "none"
		if (Action == "none" or !GESTURE_ACTIONS.Has(Action))
				return
		GestureInvokeAction(Action, GestureBindingId("keyboard", SlotId))
}

SetKeyboardShortcutAction(SlotId, ActionName) {
		global KeyboardShortcutAssignments
		if !GestureAssignConfiguredAction(&KeyboardShortcutAssignments,
				"keyboard", "shortcuts.keyboard", SlotId, ActionName)
				return false
		return ReloadPreservingSuspend()
}

_MakeKeyboardShortcutHandler(SlotId, ActionName) {
		return (*) => SetKeyboardShortcutAction(SlotId, ActionName)
}

_FormatSlotLabel(SlotId) {
		static _ModLabels := Map("ctrl_shift_", "Ctrl + Shift + ", "ctrl_", "Ctrl + ", "win_", "Win + ", "alt_", "Alt + ")
		; Only the two NAMED keys are translatable — ".", "," and "²" are the glyphs
		; themselves. The map holds i18n KEYS, never labels: a static initialised with
		; t() would freeze the language at first call, and the menu is rebuilt on a
		; language switch expecting the new one.
		static _KeyNameKeys := Map("space", "common.key_space", "enter", "common.key_enter")
		static _KeyGlyphs := Map("period", ".", "comma", ",", "sc029", "²")
		for Prefix, ModLabel in _ModLabels {
				if (SubStr(SlotId, 1, StrLen(Prefix)) = Prefix) {
						Suffix := SubStr(SlotId, StrLen(Prefix) + 1)
						if _KeyNameKeys.Has(Suffix)
								Key := t(_KeyNameKeys[Suffix])
						else if _KeyGlyphs.Has(Suffix)
								Key := _KeyGlyphs[Suffix]
						else
								Key := StrUpper(Suffix)
						return ModLabel . Key
				}
		}
		return SlotId
}

; The keyboard-shortcut groups, in display order. The i18n KEYS are stored, never
; the translated labels: a static initialised with t() would freeze the language
; at first call, and the menu is rebuilt on a language switch expecting the new one
global KEYBOARD_SLOT_GROUPS := [
		Map("prefix", "alt_", "group_key", "menu.shortcuts.alt_group", "add_key", "menu.shortcuts.alt_add"),
		Map("prefix", "ctrl_", "group_key", "menu.shortcuts.ctrl_group", "add_key", "menu.shortcuts.ctrl_add"),
		Map("prefix", "ctrl_shift_", "group_key", "menu.shortcuts.ctrl_shift_group", "add_key", "menu.shortcuts.ctrl_shift_add"),
		Map("prefix", "win_", "group_key", "menu.shortcuts.win_group", "add_key", "menu.shortcuts.win_add"),
]

/**
 * The list provider for the manifest's "keyboard_slots" entry.
 *
 * Returns row DATA, never a Menu: the renderer owns the menu shape, which is
 * what removed the whole class of bug this used to be. It was a Menu.Insert
 * splice with no idempotence check, and AHK v2's Insert APPENDS on an existing
 * label rather than merging, so every updater-driven tray refresh grew the
 * submenu by five more rows. A provider cannot splice anything.
 * @returns {Array} Rows of Map("label", …, "items", …) for the renderer.
 */
KeyboardSlotRows() {
		global KeyboardShortcutAssignments, GESTURE_ACTIONS, KEYBOARD_SLOT_GROUPS

		Rows := []
		for GroupInfo in KEYBOARD_SLOT_GROUPS {
				Prefix := GroupInfo["prefix"]
				Items := []
				for Slot, Action in KeyboardShortcutAssignments {
						if (SubStr(Slot, 1, StrLen(Prefix)) != Prefix)
								continue
						; A slot only belongs to the LONGEST prefix that matches it, or
						; "ctrl_shift_v" would appear in the Ctrl group as well
						IsExactPrefix := true
						for OtherGroup in KEYBOARD_SLOT_GROUPS {
								OtherPrefix := OtherGroup["prefix"]
								if (OtherPrefix != Prefix and StrLen(OtherPrefix) > StrLen(Prefix) and SubStr(Slot, 1, StrLen(OtherPrefix)) == OtherPrefix) {
										IsExactPrefix := false
										break
								}
						}
						if !IsExactPrefix or (Action == "none")
								continue
						ActionLabel := GESTURE_ACTIONS.Has(Action) ? GestureActionDisplayLabel(Action, GestureBindingId("keyboard", Slot)) : Action
						Items.Push(Map(
								"label", _FormatSlotLabel(Slot) . " : " . ActionLabel,
								"action", ((_s) => (*) => ShowKeyboardShortcutPicker(_s))(Slot)
						))
				}
				Items.Push(Map(
						"label", t(GroupInfo["add_key"]),
						"action", ((_p) => (*) => ShowKeyboardSlotPicker(_p))(Prefix)
				))
				Rows.Push(Map("label", t(GroupInfo["group_key"]), "items", Items))
		}
		return Rows
}
