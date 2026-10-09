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
#Include config_unused_keys.ahk

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
; ExistingOwner may borrow an exact live lease or terminal bundle. Its caller
; retains release responsibility through a subsequent WAL/reload handoff.
ConfigCommitBuilt(Path, Context, BuildFn, WriterFn := 0, NotifyFn := 0, ExistingOwner := 0) {
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return ConfigCommitBuilt(Path, Context, BuildFn, WriterFn, NotifyFn, ExistingOwner)
		finally Critical(InheritedCritical)
	}
	Borrowed := ExistingOwner is Object
	if !Borrowed && (!(ExistingOwner is Integer) || ExistingOwner != 0)
		return ConfigReportPersistenceFailure(Context, NotifyFn, "invalid borrowed configuration owner")
	OwnerToken := Borrowed ? _ConfigWriteLeaseSelectOwner(ExistingOwner, Path)
		: _ConfigWriteLeaseTryAcquire(Path, "built")
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
					PublishOnFinalizeFailure, RollbackUpdates, CleanupFn, RetainFn, !Borrowed)
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
			if !Borrowed
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
		RollbackUpdates := 0, CleanupFn := 0, RetainFn := 0, ReleaseOwner := true) {
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
		if ReleaseOwner
			_ConfigWriteLeaseRelease(OwnerToken)
	}
	if Failed
		return ConfigReportPersistenceFailure(Context, NotifyFn, FailureDetail, StateUnchanged)
	return true
}

_ConfigInvokeCommitWriter(Path, Updates, WriterFn, Stage, &FailureDetail) {
	global ConfigurationFile
	if FileReadActivityBusy(Path) {
		FailureDetail .= (FailureDetail != "" ? "; " : "") . "an exact configuration read is still in progress"
		return false
	}
	try {
		IsConfiguration := IsSet(ConfigurationFile) && ConfigurationFile != ""
			&& _ConfigWriteLeaseKey(Path) == _ConfigWriteLeaseKey(ConfigurationFile)
		if IsConfiguration
			Updates := _ConfigPrepareTypedUpdates(Updates)
		if HasMethod(WriterFn, "Call")
			Written := WriterFn.Call(Path, Updates)
		else
			Written := IsConfiguration ? TOML_ConfigBatchWrite(Path, Updates) : TOML_BatchWrite(Path, Updates)
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

; AHK erases Boolean identity into integers before producers reach persistence.
; Restore only schema-owned Boolean intent on detached update records, never on
; the live feature tree. Generic TOML files do not share this configuration schema.
_ConfigPrepareTypedUpdates(Updates) {
	if !(Updates is Array)
		throw TypeError("Configuration updates must be an Array")
	Typed := []
	for Update in Updates {
		Copy := Update.Clone()
		if !(Copy.HasOwnProp("Delete") && (Copy.Delete is Integer) && Copy.Delete == 1) {
			ExpectedType := TomlConfigExpectedType(Copy.Section, Copy.Key, &Entry)
			Dynamic := ManifestDynamicEntry(TomlConfigManifestPath(Copy.Section) . "." . Copy.Key)
			if Dynamic is Map && !Dynamic.Has("type")
				throw TypeError("Dynamic configuration metadata has no generated type.")
			DynamicBoolean := Dynamic is Map && Dynamic["type"] == "boolean"
			BooleanDomain := ExpectedType == "boolean"
				|| (ExpectedType == "enum" && TomlConfigEnumUsesBooleanLiterals(Entry)) || DynamicBoolean
			if BooleanDomain {
				if Copy.Value is TOML_Bool && (!(Copy.Value.Value is Integer)
						|| (Copy.Value.Value != 0 && Copy.Value.Value != 1))
					throw TypeError("Invalid Boolean serialization sentinel")
				Value := Copy.Value is TOML_Bool ? Copy.Value.Value : Copy.Value
				if DynamicBoolean && (!(Value is Integer) || (Value != 0 && Value != 1))
					throw TypeError("Invalid dynamic Boolean configuration value.")
				if !TomlConfigValueMatchesManifest(Copy.Section, Copy.Key, Value, &ExpectedType)
					throw TypeError("Invalid " . ExpectedType . " configuration value at "
						. Copy.Section . "." . Copy.Key)
				if Value is Integer && (Value == 0 || Value == 1)
					Copy.Value := TOML_Bool(Value)
			}
		}
		Typed.Push(Copy)
	}
	return Typed
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
		Updates.Push(_ConfigSparseOperation(Loc["section"], Loc["key"], Value))
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
		Path := "hotstrings.personal." . SectionName
		FeaturesTarget["hotstrings"]["personal"][SectionName] := Map(
			"enabled", ManifestDefaultFor(Path . ".enabled"),
			"time_activation_seconds", ManifestDefaultFor(Path . ".time_activation_seconds"))
	}
	return true
}

; Section selection persists independently of every category's runtime master.
ToggleAllHotstrings(Value) {
	return _ConfigCommitHotstringIntent("all", "", Value, "the bulk hotstring toggle")
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

; Detached transaction candidates must not share mutable Maps or Arrays with
; either the desired state or the effective runtime.
_HSDeepCloneMap(M) {
		if M is Array {
				Out := []
				for V in M
						Out.Push(_HSDeepCloneMap(V))
				return Out
		}
		if (Type(M) != "Map") {
				return M
		}
		Out := Map()
		for K, V in M {
				Out[K] := _HSDeepCloneMap(V)
		}
		return Out
}

; Resolves a category gate against a detached candidate rather than the live
; global Map, so master-gate application can finish before the atomic publish.
_ConfigCandidateCategoryEnabled(CategoryTarget, Category) {
		global CATEGORY_FOLLOWS_HOTSTRINGS_MASTER
		if CATEGORY_FOLLOWS_HOTSTRINGS_MASTER.Has(Category)
				Category := "Hotstrings"
		if CategoryTarget.Has(Category)
				return CategoryTarget[Category]
		return ManifestDefaultFor("category_enabled." . _CategoryEnabledKey(Category))
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

ToggleCategoryAllFeatures(Category, Value, WriterFn := 0, NotifyFn := 0, ApplyFn := 0) {
	global ConfigurationFile
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return ToggleCategoryAllFeatures(Category, Value, WriterFn, NotifyFn, ApplyFn)
		finally Critical(InheritedCritical)
	}
	Bool := (Value = true or Value = 1)
	if !ConfigCommitBuilt(ConfigurationFile, "the '" . Category . "' category toggle",
			_ConfigBuildCategoryIntentPlan.Bind(Category, Bool), WriterFn, NotifyFn)
		return false
	if HasMethod(ApplyFn, "Call")
		return ApplyFn.Call()
	if _IsLiveHotstringCategory(Category) {
		LoggerStart("Menu", "Applying live category toggle for {1}…", Category)
		RebuildHotstringsLive()
		LoggerSuccess("Menu", "Live category toggle applied for {1}.", Category)
		return true
	}
	return ReloadPreservingSuspend()
}

; The lease is already held before reading desired, effective, or category state.
_ConfigBuildCategoryIntentPlan(Category, Bool) {
	global Features, TapHold, CategoryEnabled
	Desired := _HSDeepCloneMap(MasterGateDesiredFeatures(Features))
	DesiredTapHold := _HSDeepCloneMap(MasterGateDesiredTapHold(TapHold))
	CandidateCategories := CategoryEnabled.Clone()
	if !CandidateCategories.Has(Category)
		throw Error("Unknown category gate: " . Category)
	CandidateCategories[Category] := Bool
	Projected := _HSDeepCloneMap(Desired)
	ProjectedTapHold := _HSDeepCloneMap(DesiredTapHold)
	ApplyMasterGatesToFeatures(Projected, ProjectedTapHold,
		(Name) => _ConfigCandidateCategoryEnabled(CandidateCategories, Name))
	RuntimePatches := []
	CandidateTapHold := 0
	switch Category {
		case "Layout", "Shortcuts", "Hotstrings":
			Root := StrLower(Category)
			if Projected.Has(Root)
				RuntimePatches.Push({ target: Features, key: Root, value: Projected[Root] })
		case "KeyCombinations":
			; Its families live under Features["shortcuts"], which it alone gates.
			if Projected.Has("shortcuts")
				RuntimePatches.Push({ target: Features, key: "shortcuts", value: Projected["shortcuts"] })
		case "TapHolds":
			CandidateTapHold := ProjectedTapHold
		default:
			Root := _CategoryEnabledKey(Category)
			if !Projected.Has("hotstrings") || !Projected["hotstrings"].Has(Root)
				throw Error("Unknown hotstring category state: " . Category)
			RuntimePatches.Push({ target: Features["hotstrings"], key: Root, value: Projected["hotstrings"][Root] })
	}
	Updates := [_ConfigSparseOperation("category_enabled", _CategoryEnabledKey(Category), Bool)]
	return { updates: Updates, publish: _ConfigPublishDesiredState.Bind(Desired,
		RuntimePatches, CandidateCategories, CandidateTapHold) }
}

; Publishing is a bounded reference swap. No filesystem, manifest, or native
; acquisition runs while the input thread is excluded.
_ConfigPublishDesiredState(Desired, RuntimePatches, CandidateCategories := 0, CandidateTapHold := 0) {
	global TapHold, CategoryEnabled
	PreviousCritical := Critical("On")
	try {
		MasterGateState()["features"] := Desired
		for Patch in RuntimePatches
			Patch.target[Patch.key] := Patch.value
		if CandidateCategories is Map
			CategoryEnabled := CandidateCategories
		if CandidateTapHold is Map
			TapHold := CandidateTapHold
	} finally Critical(PreviousCritical)
}

; Select every section of one category while retaining its independent master.
ToggleCategoryAllSections(V1Cat, Enable) {
	return _ConfigCommitHotstringIntent("category", V1Cat, Enable,
		"the '" . V1Cat . "' section toggle")
}

/**
 * Publishes the dynamic families through the conditional reload journal.
 * This category follows the Hotstrings master and owns no additional gate.
 * @param {Integer} Enabled Explicit Boolean posture for every dynamic family.
 * @param {Map} Options Existing journal/lifecycle ports for isolated tests.
 * @returns {Map} Pending or terminal receipt; native refusal restores exact bytes.
 */
HotstringsDynamicScopeApply(Enabled, Options := unset) {
	if !IsSet(Options)
		Options := Map()
	Operations() {
		if !(Enabled is Integer) || (Enabled != 0 && Enabled != 1)
			throw TypeError("A dynamic hotstring scope requires an explicit Boolean target.")
		return _ConfigBuildHotstringIntentPlan("dynamic", "", Enabled).updates
	}
	return ConfigScopeCommitOperations("hotstrings", Enabled ? "enable_all" : "disable_all", Operations, Options)
}

; Select one language pack in a single transaction without changing its masters.
ToggleLanguageAllSections(Pack, Enable) {
	return _ConfigCommitHotstringIntent("language", Pack, Enable,
		"the '" . Pack["id"] . "' language toggle")
}

; Personal section paths come from discovered TOML names; selection remains
; editable while the Hotstrings or Personal master is disabled.
HS_TogglePersonalAllSections(Enable) {
	return _ConfigCommitHotstringIntent("personal", "", Enable,
		"the personal-hotstring section toggle")
}

; Section selection never changes a master checkbox. Users may prepare every
; desired section while all native activation remains disabled.
_ConfigCommitHotstringIntent(Kind, Selector, Enable, Context) {
	global ConfigurationFile
	if !ConfigCommitBuilt(ConfigurationFile, Context,
			_ConfigBuildHotstringIntentPlan.Bind(Kind, Selector, !!Enable))
		return false
	return ReloadPreservingSuspend()
}

; Scope enumeration and personal discovery occur under the same owner as write
; and publication, avoiding a stale pre-lease snapshot during another edit.
_ConfigBuildHotstringIntentPlan(Kind, Selector, Bool) {
	global Features, TapHold, CategoryEnabled, _LegacyTopCategoryMap, ScriptInformation
	Desired := _HSDeepCloneMap(MasterGateDesiredFeatures(Features))
	Entries := []
	switch Kind {
		case "all":
			for Path in _CollectAllHotstringsV2Paths(Desired)
				Entries.Push(Map("path", Path, "value", Bool))
		case "category":
			if !_LegacyTopCategoryMap.Has(Selector)
				throw Error("Unknown hotstring category: " . Selector)
			for Entry in ManifestFeaturesForSection(_LegacyTopCategoryMap[Selector])
				Entries.Push(Map("path", Entry["path"], "value", Bool))
		case "dynamic":
			; Discover the canonical families inside the admitted lease, independent
			; of a menu preview or the mixed legacy tray map. There is no extra gate.
			for Entry in ManifestFeaturesForSection("hotstrings.dynamic")
				Entries.Push(Map("path", Entry["path"], "value", Bool))
		case "language":
			for Category in Selector["categories"] {
				for Entry in ManifestFeaturesForSection("hotstrings." . Category["v2"])
					Entries.Push(Map("path", Entry["path"], "value", Bool))
			}
		case "personal":
			PersonalPath := ScriptInformation.Get("PersonalTomlPath", "")
			if PersonalPath == "" || !FSExists(PersonalPath)
				throw Error("Personal hotstring configuration is unavailable.")
			; A menu preview must not freeze a later admitted scope inventory.
			for Section in ReadPersonalToml(true)["sections_order"] {
				if Section == "-"
					continue
				_ConfigSeedPersonalHotstring(Desired, Section)
				Entries.Push(Map("path", "hotstrings.personal." . StrLower(Section), "value", Bool))
			}
		default:
			throw Error("Unknown hotstring scope: " . Kind)
	}
	if !Entries.Length
		throw Error("The hotstring scope contains no configurable sections.")
	Updates := []
	if _ConfigStageFeatureEntries(Desired, Entries, Updates) != Entries.Length
		throw Error("A hotstring scope feature could not be resolved.")
	Projected := _HSDeepCloneMap(Desired)
	ApplyMasterGatesToFeatures(Projected, Map(), IsCategoryGated)
	CandidateFeatures := _HSDeepCloneMap(Features)
	RuntimePatches := []
	NewPersonalRoot := false
	for Entry in Entries {
		Path := Entry["path"]
		if SubStr(Path, 1, StrLen("hotstrings.personal.")) == "hotstrings.personal."
			_ConfigSeedPersonalHotstring(CandidateFeatures, SubStr(Path, StrLen("hotstrings.personal.") + 1))
		Loc := FeatureLocateV2(CandidateFeatures, Path)
		ProjectedLoc := FeatureLocateV2(Projected, Path)
		if !(Loc is Map) || !(ProjectedLoc is Map)
			throw Error("A hotstring runtime path could not be resolved: " . Path)
		Loc["v2_node"][Loc["key"]] := ProjectedLoc["v2_node"][ProjectedLoc["key"]]
		Current := FeatureLocateV2(Features, Path)
		if Current is Map {
			RuntimePatches.Push({ target: Current["v2_node"], key: Current["key"], value: Loc["v2_node"][Loc["key"]] })
		} else if Features["hotstrings"].Has("personal") {
			Section := SubStr(Path, StrLen("hotstrings.personal.") + 1)
			RuntimePatches.Push({ target: Features["hotstrings"]["personal"], key: Section,
				value: CandidateFeatures["hotstrings"]["personal"][Section] })
		} else {
			NewPersonalRoot := true
		}
	}
	if NewPersonalRoot
		RuntimePatches.Push({ target: Features["hotstrings"], key: "personal", value: CandidateFeatures["hotstrings"]["personal"] })
	return { updates: Updates, publish: _ConfigPublishDesiredState.Bind(Desired, RuntimePatches) }
}

_CategoryEnabledKey(Category) {
		switch Category {
				case "Layout":     return "layout"
				case "Shortcuts":  return "shortcuts"
				case "Hotstrings": return "hotstrings"
				case "TapHolds":   return "tap_holds"
				case "KeyCombinations": return "key_combinations"
				; Hotstring sub-category gates — snake_case to match the v2 schema.
				case "DistancesReduction": return "distances_reduction"
				case "SFBsReduction":      return "sfbs_reduction"
				case "MagicKey":           return "magic_key"
		}
		; Language-pack gates are keyed by their group id ("french_autocorrection");
		; the table is filled when the boot seeds those gates.
		if IsSet(HS_LANGUAGE_GATE_KEYS) and HS_LANGUAGE_GATE_KEYS.Has(Category)
				return HS_LANGUAGE_GATE_KEYS[Category]
		return StrLower(Category)
}

_ConfigCollectFullSaveUpdates(FeaturesSource := unset, MenuSource := unset) {
		global Features, ScriptInformation, ScriptShortcutAssignments
		global GestureAssignments, KeyboardShortcutAssignments
		global LOGGER_MIN_LEVEL, LOGGER_DEFAULT_LEVEL
		global _LLM_Menu_Loaded, _LLM_Menu
		global CategoryEnabled
		global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL
		global UPDATER_INI_SECTION, UPDATER_INI_KEY, UPDATER_INI_INTERVAL_KEY
		global _IniCache, KEYBOARD_SHORTCUT_DEFAULTS
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
				FeatureSnapshot := _HSDeepCloneMap(MasterGateDesiredFeatures(FeatureState))
				; The dedicated category owner below is authoritative for master gates.
				if FeatureSnapshot.Has("category_enabled")
						FeatureSnapshot.Delete("category_enabled")
				if IsSet(_LLM_Menu_SyncToFeatures)
						&& MenuReady && (MenuState is Map)
						&& !_LLM_Menu_SyncToFeatures(FeatureSnapshot, MenuState)
						throw Error("LLM menu state could not be reconciled into the full-save candidate")
				_CollectFeatureUpdates(Updates, "", FeatureSnapshot)
				; The version the boot migration reads (infra/config_migrate.ahk).
				Updates.Push({ Section: "_meta", Key: "schema_version", Value: ConfigMigrateCurrentVersion() })
		}
		Updates.Push({ Section: "script", Key: "locale", Value: I18nGetLocale() })
		Updates.Push({ Section: "script", Key: "log_level", Value: IsSet(LOGGER_MIN_LEVEL) ? LOGGER_MIN_LEVEL : LOGGER_DEFAULT_LEVEL })
		Updates.Push({ Section: "hotstrings", Key: "trigger_char", Value: ScriptInformation["MagicKey"] })
		if IsSet(ScriptShortcutAssignments) {
				for Slot, Action in ScriptShortcutAssignments
						Updates.Push({ Section: "shortcuts.script_control", Key: Slot, Value: Action })
		}
		if IsSet(KeyboardShortcutAssignments)
				CollectKeyboardShortcutUpdates(Updates, KeyboardShortcutAssignments,
						_IniCache.Get("shortcuts.keyboard", Map()), KEYBOARD_SHORTCUT_DEFAULTS)
		if IsSet(GestureAssignments) {
				for Slot, Action in GestureAssignments
						Updates.Push({ Section: "gestures", Key: Slot, Value: Action })
		}
		apps := []
		for proc, _ in MetricsFilters.disabled_apps
				apps.Push(proc)
		Updates.Push({ Section: "metrics", Key: "metrics_enabled", Value: TOML_Bool(MetricsShortcuts.enabled) })
		Updates.Push({ Section: "metrics", Key: "metrics_wpm_menubar_colors", Value: MetricsShortcuts.wpm_menubar_colors })
		Updates.Push({ Section: "metrics", Key: "private_filter_enabled", Value: TOML_Bool(MetricsFilters.private_browsing) })
		Updates.Push({ Section: "metrics", Key: "secure_filter_enabled", Value: TOML_Bool(MetricsFilters.secure_field) })
		Updates.Push({ Section: "metrics", Key: "system_auth_filter_enabled", Value: TOML_Bool(MetricsFilters.system_auth) })
		Updates.Push({ Section: "metrics", Key: "encrypt", Value: TOML_Bool(MetricsFilters.encrypt) })
		Updates.Push({ Section: "metrics", Key: "metrics_disabled_apps", Value: apps })
		Updates.Push({ Section: "metrics", Key: WPMWidgetConst.CFG_VISIBLE, Value: WPMWidget.visible })
		Updates.Push({ Section: "metrics", Key: WPMWidgetConst.CFG_X,       Value: WPMWidget.pos_x })
		Updates.Push({ Section: "metrics", Key: WPMWidgetConst.CFG_Y,       Value: WPMWidget.pos_y })
		Updates.Push({ Section: "metrics", Key: WPMWidgetConst.CFG_COLORS, Value: WPMWidget.use_colors })
		Updates.Push({ Section: "metrics", Key: WPMWidgetConst.CFG_GRAPH, Value: WPMWidget.show_graph })
		; The flat [llm] keys below round-trip through _LLM_Menu DIRECTLY (not via
		; Features), so the _LLM_Menu_SyncToFeatures gate above does not cover them. The
		; boot-armed SaveFullConfig timer fires ~0-100 ms after _DriverReady, while
		; LLM_Menu_Init runs seconds later at the end of the deferred menu build — so
		; without this dedicated gate the first flush writes module defaults
		; (onboarding_seen=0, empty overrides, default ollama_port/…)
		; over the user's saved values. Skipping is safe: TOML_BatchWrite preserves keys
		; it does not re-collect, so the on-disk values survive until the menu has loaded.
		if (MenuReady && (MenuState is Map)) {
				if !MenuState.Has("onboarding_seen")
						|| !LLM_Option_TryNormalize("onboarding_seen",
							MenuState["onboarding_seen"], &OnboardingSeen)
					throw Error("LLM onboarding state could not be serialized into the full-save candidate")
				Updates.Push({ Section: "llm", Key: "onboarding_seen", Value: OnboardingSeen })
				_AppOverridesPayload := _LLM_Menu_SerializeAppProfileOverrides(
						MenuState["app_profile_overrides"])
				if !(_AppOverridesPayload is String)
						throw Error("Could not serialize LLM app-profile overrides")
				Updates.Push({ Section: "llm", Key: "app_profile_overrides", Value: _AppOverridesPayload })
				if IsSet(_LLM_Menu_AppendPersistedUpdates)
						&& !_LLM_Menu_AppendPersistedUpdates(Updates, MenuState)
					throw Error("LLM menu persistence fields could not be serialized into the full-save candidate")
		}
		if IsSet(CategoryEnabled) {
				for _CatName, _CatBool in CategoryEnabled
						Updates.Push({ Section: "category_enabled", Key: _CategoryEnabledKey(_CatName), Value: TOML_Bool(_CatBool) })
		}
		if IsSet(UPDATER_CHECK_INTERVAL)
				Updates.Push({ Section: UPDATER_INI_SECTION, Key: UPDATER_INI_INTERVAL_KEY, Value: UPDATER_CHECK_INTERVAL })
		if IsSet(UPDATER_CHANNEL)
				Updates.Push({ Section: UPDATER_INI_SECTION, Key: UPDATER_INI_KEY, Value: UPDATER_CHANNEL })
		return _ConfigKeepOutdatedEntries(_ConfigSparseUpdates(Updates))
}

; Manifest comparison uses native values; Boolean serialization sentinels belong
; to the final typed writer boundary, after neutral-value deletion is decided.
_ConfigSparseOperation(Section, Key, Value) {
	NativeValue := Value is TOML_Bool ? Value.Value : Value
	return ManifestConfigSparseOperation(Section, Key, NativeValue)
}

; Neutral values delete their previous override in the same atomic batch.
; Schema metadata is owned by migration and is never a user feature default.
_ConfigSparseUpdates(Updates) {
	Sparse := []
	for Update in Updates {
		OwnedElsewhere := TomlConfigSectionSkipKind(Update.Section) == "foreign"
			|| (TomlConfigForeignOwner(Update.Section, Update.Key) != ""
				&& !(ManifestFindEntryByPath(Update.Section . "." . Update.Key) is Map))
		if OwnedElsewhere || (Update.HasOwnProp("Delete") && Update.Delete == 1)
			Sparse.Push(Update)
		else
			Sparse.Push(_ConfigSparseOperation(Update.Section, Update.Key, Update.Value))
	}
	return Sparse
}

; A value the boot load ignored as outdated stays on disk until the user
; removes it with the configuration cleanup, which backs the file up first, or
; chooses a new value for that setting. A full save carrying only the neutral
; value the outdated entry left in memory would erase it silently and leave
; the cleanup nothing to list, so that update is dropped; any other value is
; the user's new choice and replaces the outdated one.
_ConfigKeepOutdatedEntries(Updates) {
	global _ConfigBootOutdatedEntries
	if !IsSet(_ConfigBootOutdatedEntries) || _ConfigBootOutdatedEntries.Count == 0
		return Updates
	Kept := []
	for Update in Updates {
		if _ConfigBootOutdatedEntries.Has(Update.Section . "`n" . Update.Key)
				&& _ConfigUpdateIsNeutral(Update)
			continue
		Kept.Push(Update)
	}
	return Kept
}

; Whether an update only restores its setting's manifest default: a deletion,
; or a value the sparse writer would turn into one.
_ConfigUpdateIsNeutral(Update) {
	if Update.HasOwnProp("Delete")
		return (Update.Delete is Integer) && Update.Delete == 1
	try Sparse := _ConfigSparseOperation(Update.Section, Update.Key, Update.Value)
	catch as Err {
		; No manifest default to compare with: the value is an explicit choice.
		try LoggerDebug("ConfigIO", "[{1}].{2} has no manifest default ({3}); its update is kept.",
			Update.Section, Update.Key, Err.Message)
		return false
	}
	return Sparse.HasOwnProp("Delete") && (Sparse.Delete is Integer) && Sparse.Delete == 1
}

; Targeted repairs and explicit reset do not serialize the incomplete boot tree.
; Every full-state producer, including detached candidates, shares this gate.
ConfigFullStateCanPersist() {
	global _ConfigBootReadFailed, _ConfigBootRejectedOverrides, ConfigurationFile
	; The boot migration refused the file (a newer schema, a failed migration):
	; the loaded tree does not describe it, so it must never be serialized over it.
	if IsSet(ConfigurationFile) {
		Refusal := TOML_WriteRefusal(ConfigurationFile)
		if (Refusal != "") {
			try LoggerError("ConfigIO", "Refusing full-state persistence: config.toml is read-only for this session ({1}).",
				Refusal)
			return false
		}
	}
	if IsSet(_ConfigBootReadFailed) && _ConfigBootReadFailed {
		try LoggerError("ConfigIO", "Refusing full-state persistence: config.toml could not be read at boot. Restart the driver once the file is readable.")
		return false
	}
	if IsSet(_ConfigBootRejectedOverrides) && _ConfigBootRejectedOverrides {
		try LoggerError("ConfigIO", "Refusing full-state persistence: boot rejected {1} override(s). Correct the configuration and restart before saving the loaded tree.",
			_ConfigBootRejectedOverrides)
		return false
	}
	return true
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
		RequestedGeneration := 0
		if RegisterRequest {
			RequestedGeneration := _ConfigFullSaveRequest(true)
			if !RequestedGeneration {
				try LoggerError("ConfigIO", "Refusing a new full save after terminal or disk-reload authority was sealed.")
				return CONFIG_SAVE_FAILED
			}
		}
		; Accepted explicit intent survives refusal; it grants no serializer authority.
		if !ConfigFullStateCanPersist() {
			return CONFIG_SAVE_FAILED
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
			if FileReadActivityBusy(BoundPath)
				return _ConfigArmFullSaveRetry(CONFIG_FULL_SAVE_RETRY_DELAY_MS, TimerFn)
					? CONFIG_SAVE_DEFERRED : CONFIG_SAVE_FAILED
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
				Phase := "source"
				try {
				SourceImage := 0
				if !HasMethod(WriterFn, "Call") {
					; Bind full-snapshot preservation to one admitted generation
					; before collection can run callbacks or change live state.
					SourceImage := TOML_BuildConfigUpdatedContent(BoundPath, [])
					if !(SourceImage is Map) || SourceImage.Get("status", "") != "ok"
							|| SourceImage.Get("kind", "") != "rendered"
						throw Error("The full configuration source could not be admitted.")
					ObsoleteSource := ConfigFullSnapshotCaptureObsoleteSource(SourceImage["source_content"])
				}
				Phase := "collector"
				Updates := HasMethod(CollectFn, "Call")
						? CollectFn.Call()
						: _ConfigCollectFullSaveUpdates()
				if !(Updates is Array)
						throw TypeError("The full configuration collector must return an Array")
				Updates := _ConfigKeepOutdatedEntries(Updates)
				if SourceImage is Map
					Updates := ConfigFullSnapshotPreserveObsoleteSource(ObsoleteSource, Updates)
				Updates := _ConfigPrepareTypedUpdates(Updates)
				; Do NOT FileDelete before writing — TOML_BatchWrite already performs an
				; atomic write (temp file + rename). A FileDelete here creates a data-loss
				; window: if a Reload() or thread interrupt fires between the delete and the
				; write, the user's config is permanently gone with no replacement.
				if FileReadActivityBusy(BoundPath)
					return _ConfigArmFullSaveRetry(CONFIG_FULL_SAVE_RETRY_DELAY_MS, TimerFn)
						? CONFIG_SAVE_DEFERRED : CONFIG_SAVE_FAILED
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
					; Ordinary saves own only collected settings; retired namespaces stay
					; on disk until the user explicitly removes them.
					Written := _TOML_BatchWriteImpl(BoundPath, Updates, [], "write",
						SourceImage["source_content"], SourceImage["source_present"], true)
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
	if FileReadActivityBusy()
		return false
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

_CollectFeatureUpdates(Updates, SectionPath, Node) {
		if (Type(Node) != "Map")
				return
		for Key, Value in Node {
				if (SectionPath == "" and Type(Value) != "Map")
						continue
				Sub := (SectionPath == "") ? TOML_RenderKey(Key) : SectionPath "." TOML_RenderKey(Key)
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
	try Ui_MsgBox(Format(t("dialog.reset_defaults.failed"), Reason),
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
		; interrupting menu edit repopulate the reset file or leave a fresh WAL
		; that makes Reload refuse after the user's files were already removed. A
		; launched reload owns the bundle until OnExit; a later refusal hands it
		; back to the same rollback a refused launch runs here.
		Reloaded := ReloadPreservingSuspend(0, OwnerBundle,
			ConfigTransitionSettleRefusedReload.Bind(
				_ConfigResetRollbackRefusedReload, OwnerBundle))
		if (Reloaded is Integer) && Reloaded == 1 {
			ReleaseBundle := false
			return true
		}
		if _ConfigResetRollbackRefusedReload(OwnerBundle)
			ReleaseBundle := false
		return false
		} finally {
			if ReleaseBundle
				_ConfigWriteTerminalRelease(OwnerBundle)
		}
		} finally Critical(PreviousCritical)
}

; Restores the files a reset removed after its reload was refused.
; @returns {Boolean} True when the rollback failed and the barrier stays
;   retained around the unresolved transition, so the bundle must not be released.
_ConfigResetRollbackRefusedReload(OwnerBundle) {
	global _PathsFile
	RollbackResult := ConfigTransitionRollbackOwned(_PathsFile, OwnerBundle)
	if ConfigTransitionResultIs(RollbackResult, "recovered_old")
			|| ConfigTransitionResultIs(RollbackResult, "absent") {
		_ConfigResetShowFailure("dialog.reset_defaults.reason.reload_refused")
		return false
	}
	ConfigTransitionLogFailure("ConfigResetRollback", RollbackResult)
	Retained := ConfigTransitionRetainBarrier(OwnerBundle)
	_ConfigResetShowFailure("dialog.reset_defaults.reason.rollback",
		RollbackResult)
	return Retained
}

ReadScriptShortcutsConfig() {
		global ScriptShortcutAssignments, SCRIPT_SHORTCUT_SLOTS, _IniCache, GESTURE_ACTIONS
		global ScriptShortcutChordsOn
		; The switch of the chords: absent keeps the manifest default, anything but
		; a TOML boolean stops the boot like a malformed category gate.
		Raw := IniCacheGet(_IniCache, "shortcuts.script_control", "chords_enabled")
		if (Raw != "_")
				ScriptShortcutChordsOn := _FeatureStateValidateBoolean(Raw, "shortcuts.script_control.chords_enabled")
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

; How often the chord cleanup looks again for the release of an AltGr the user
; still held when the chord ended.
global SCRIPT_COMBO_ALTGR_RELEASE_POLL_MS := 50
; Arms that next look. A global holding a function, as _TapHoldKeyIsDown is, so
; tests arm no real timer. It names a wrapper in this file: the timer adapter is
; not included where this file is loaded alone (the feature-state boot smoke).
global _ScriptComboArmFn := _ScriptComboArmTimer

_ScriptComboArmTimer(Callback, DelayMs) {
		return TimerArmOneShotMs(Callback, DelayMs)
}

; Clears the Kana AltGr a script chord may leave logically down, once the
; chord's suffix key is up. A tap-hold that holds AltGr keeps it: its owner
; releases it, and a raw Up here ended the hold while the owner still counted it.
; A user still holding AltGr keeps it too: an Up now ended the layout's AltGr for
; the rest of that hold. Their release normally lifts the key, but one a hotkey
; swallowed would leave it latched, so the cleanup looks again once they let go.
; @param ReleaseFn {Func} Test seam; production releases through the hook.
ResetScriptComboKeys(SuffixSC, ReleaseFn := 0) {
		global _ALTGR_KANA_FIXUP
		if !(IsSet(_ALTGR_KANA_FIXUP) and _ALTGR_KANA_FIXUP)
				return
		KeyWait(SuffixSC, "T2")
		if GetKeyState(SuffixSC, "P")
				return
		_ScriptComboClearAltGr(KS_AltGrKeyName(), A_SendLevel,
				HasMethod(ReleaseFn, "Call") ? ReleaseFn : _ScriptComboReleaseThroughHook, false)
}

; Releases Name unless its tap-hold owner holds it, once the user no longer
; holds it physically; until then it looks again every
; SCRIPT_COMBO_ALTGR_RELEASE_POLL_MS. After such a wait (Waited) only a key the
; user's release left logically down is released: one that went through needs
; no second Up, which could land on their next press. Level is the chord
; hotkey's SendLevel, kept for the Up sent from a timer thread.
_ScriptComboClearAltGr(Name, Level, ReleaseFn, Waited) {
		global _TapHoldKeyIsDown, _ScriptComboArmFn, SCRIPT_COMBO_ALTGR_RELEASE_POLL_MS
		if _TapHoldKeyIsDown.Call(Name, "P") {
				_ScriptComboArmFn.Call(_ScriptComboClearAltGr.Bind(Name, Level, ReleaseFn, true),
						SCRIPT_COMBO_ALTGR_RELEASE_POLL_MS)
				return
		}
		if (Waited and !_TapHoldKeyIsDown.Call(Name, ""))
				return
		PreviousLevel := A_SendLevel
		SendLevel(Level)
		try
				TapHoldReleaseUnlessOwned(Name, ReleaseFn)
		finally
				SendLevel(PreviousLevel)
}

; The chord's Up goes out as SendEvent at the chord hotkey's own SendLevel (3),
; which the driver's hook processes like a key event and so also clears its own
; record of the key being down. A TextSender Up at level 0 is hidden from it.
_ScriptComboReleaseThroughHook(Name) {
		SendEvent("{" . Name . " Up}")
		return true
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

; Whether the chords of a script slot belong to the driver right now: the slot
; runs a catalogue action and, while the driver is paused, only a script-management
; one. Every chord hotkey asks this in its #HotIf (ScriptAltGrChordPlan), so an
; unassigned slot leaves AltGr+Enter, BackSpace, Delete or Escape to the system.
; It used to take the chord anyway and retype the bare key, so AltGr+Entrée typed
; Entrée in a configuration without an assignment, where the system gets
; AltGr+Enter (script-chord-slot-2026-09-30).
; @param Slot {String} A SCRIPT_SHORTCUT_SLOTS id; any other id is a caller bug.
; @param Suspended {Boolean} The pause state to judge by; A_IsSuspended by default.
; @return {Boolean}
ScriptShortcutSlotRunsAction(Slot, Suspended := A_IsSuspended) {
		global ScriptShortcutAssignments, GESTURE_ACTIONS, SCRIPT_SHORTCUT_SUSPEND_ALLOWED
		if !ScriptShortcutAssignments.Has(Slot)
				throw ValueError("Unknown script shortcut slot.", -1, Slot)
		; The submenu's switch: off leaves every chord native and keeps the actions.
		if !ScriptShortcutChordsAreOn()
				return false
		Action := ScriptShortcutAssignments[Slot]
		if (Action == "none" or !GESTURE_ACTIONS.Has(Action))
				return false
		; While suspended these chords stay armed ONLY for script management. Without this
		; scope check the exemption silently widened to whatever the user assigned, so a
		; paused driver still fired arbitrary gesture actions.
		return !Suspended or SCRIPT_SHORTCUT_SUSPEND_ALLOWED.Has(Action)
}

RunScriptShortcutAction(Slot) {
		global ScriptShortcutAssignments, SCRIPT_SHORTCUT_FALLBACKS
		if !ScriptShortcutSlotRunsAction(Slot) {
				; The chord's #HotIf admitted this slot at the press, so only a pause
				; that began before this thread ran gets here: the chord was already
				; taken, and its key is the one thing left to give back.
				LoggerWarn("Shortcuts", "Script slot '{1}' no longer runs '{2}' (paused since the press); sending its key instead.",
						Slot, ScriptShortcutAssignments[Slot])
				SendInput(SCRIPT_SHORTCUT_FALLBACKS[Slot])
				return
		}
		GestureInvokeAction(ScriptShortcutAssignments[Slot], GestureBindingId("script", Slot))
}

SetScriptShortcutAction(Slot, ActionName) {
		global ScriptShortcutAssignments
		if !GestureAssignConfiguredAction(&ScriptShortcutAssignments,
				"script", "shortcuts.script_control", Slot, ActionName)
				return false
		return ReloadPreservingSuspend()
}

; Whether the script chords' switch is on ([shortcuts.script_control] chords_enabled).
; @return {Boolean}
ScriptShortcutChordsAreOn() {
		global ScriptShortcutChordsOn
		return ScriptShortcutChordsOn ? true : false
}

; Turns the script chords' switch on or off, then reloads so every chord's
; criterion and the menu read it. The slots keep their actions either way.
; @param On {Boolean} The new state.
; @param Path {String} The config.toml to write; ConfigurationFile by default.
; @param ReloadFn {Func} Replaces the reload in tests.
; @return {Boolean} False when the write was refused.
SetScriptShortcutChordsOn(On, Path := "", ReloadFn := 0) {
		global ConfigurationFile
		Row := ManifestSparseOperation("shortcuts.script_control.chords_enabled", On ? true : false)
		if !ConfigCommitUpdates(Path != "" ? Path : ConfigurationFile, [Row], "the script chords switch")
				return false
		return HasMethod(ReloadFn, "Call") ? ReloadFn.Call() : ReloadPreservingSuspend()
}

; The rows that put « Raccourcis de gestion du script » back to its preset
; ("recommended": every slot and the switch; an entry equal to its default is a
; deletion) or clear it to the system's behaviour ("clear": every slot's
; manifest `cleared` value, "none", written explicitly because an absent slot
; starts with its preset). Both drop the parameters of script bindings.
; @param Mode {String} "recommended" or "clear".
; @return {Array} Sparse configuration rows.
ScriptShortcutScopeRows(Mode) {
		global SCRIPT_SHORTCUT_SLOTS
		if !(Mode == "recommended" or Mode == "clear")
				throw ValueError("Unknown script shortcut scope mode.", -1, Mode)
		Rows := []
		for Slot in SCRIPT_SHORTCUT_SLOTS {
				Path := "shortcuts.script_control." . Slot
				Rows.Push(Mode == "clear" ? ManifestConfigRow(Path, ManifestValueFor(Path, "cleared"))
						: ManifestSparseOperation(Path, ManifestRecommendedFor(Path)))
		}
		if (Mode == "recommended")
				Rows.Push(ManifestSparseOperation("shortcuts.script_control.chords_enabled",
						ManifestRecommendedFor("shortcuts.script_control.chords_enabled")))
		for Path in ConfigScopeActionParameterPaths() {
				if (ConfigScopeActionParameterDomain(Path) == "script")
						Rows.Push(ManifestConfigRow(Path, , true))
		}
		return Rows
}

; Restores or clears the script chords the way every scope row does: a backup,
; one conditional write, then the reload that reads it (no question asked).
; @param Mode {String} "recommended" or "clear".
; @param Options {Map} Scope ports (path, reload...) for tests.
; @return {Map} The scope receipt.
ScriptShortcutsApplyScope(Mode, Options := unset) {
		return ConfigScopeCommitOperations("shortcuts", Mode, ScriptShortcutScopeRows.Bind(Mode),
				IsSet(Options) ? Options : Map())
}

; The four slot rows of « Raccourcis de gestion du script », each opening the
; shared action picker.
; @return {Array} Renderer rows.
ScriptShortcutRows() {
		global SCRIPT_SHORTCUT_SLOTS, SCRIPT_SHORTCUT_LABELS, ScriptShortcutAssignments, GESTURE_ACTIONS
		Rows := []
		for Slot in SCRIPT_SHORTCUT_SLOTS {
				Current := ScriptShortcutAssignments.Has(Slot) ? ScriptShortcutAssignments[Slot] : "none"
				CurrentLabel := GESTURE_ACTIONS.Has(Current) ? GestureActionDisplayLabel(Current, GestureBindingId("script", Slot)) : t("dialog.action_picker.disabled")
				SlotLabel := t(SCRIPT_SHORTCUT_LABELS[Slot])
				Rows.Push(Map(
					"label",  SlotLabel . " : " . CurrentLabel,
					"action", ((_s, _l) => (*) => ShowActionPicker(_l, ScriptShortcutAssignments.Has(_s) ? ScriptShortcutAssignments[_s] : "none", (Id) => SetScriptShortcutAction(_s, Id), false, GestureBindingId("script", _s)))(Slot, SlotLabel)))
		}
		return Rows
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

/**
 * Collects keyboard settings without materializing implicit neutral defaults.
 * @param {Array} Updates Existing acknowledged writer's speculative rows.
 * @param {Map} Assignments Resolved runtime assignments.
 * @param {Map} Stored Actual raw keyboard records, preserving explicit none.
 * @param {Map} Defaults Actual manifest-derived initial assignments.
 */
CollectKeyboardShortcutUpdates(Updates, Assignments, Stored, Defaults) {
	for Slot, Action in Assignments {
		if Action == "none" && Defaults.Get(Slot, "none") == "none" && !Stored.Has(Slot)
			continue
		Updates.Push({ Section: "shortcuts.keyboard", Key: Slot, Value: Action })
	}
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
		MagicEditorConfigurationChanged()
		return ReloadPreservingSuspend()
}

_MakeKeyboardShortcutHandler(SlotId, ActionName) {
		return (*) => SetKeyboardShortcutAction(SlotId, ActionName)
}

_FormatSlotLabel(SlotId) {
		if SlotId == MagicEditorSlot()["id"]
				return MagicEditorSlotLabel()
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
		Map("prefix", "magic_", "group_key", "menu.shortcuts.group_contextual", "add_key", "menu.shortcuts.add_contextual"),
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
				if Prefix == "magic_" {
						Rows.Push(Map("label", t(GroupInfo["group_key"]), "items", MagicEditorSlotRows()))
						continue
				}
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

/**
 * Removes the custom keyboard slots accepted by this persistence owner's
 * grammar, and the key-combination slots the manifest does not declare.
 */
ConfigIOShortcutScopeOperations(ScopeId, Mode) {
	global KeyboardShortcutAssignments
	if ScopeId != "shortcuts" || !(Mode == "recommended" || Mode == "clear")
		throw ValueError("Shortcut persistence cannot reset another configuration scope.")
	if !IsSet(KeyboardShortcutAssignments) || !(KeyboardShortcutAssignments is Map)
		throw Error("Keyboard shortcut inventory is unavailable.")
	Rows := []
	for Slot in KeyboardShortcutAssignments {
		if TomlConfigForeignOwner("shortcuts.keyboard", Slot) != "ConfigIO"
			continue
		if ManifestFindEntryByPath("shortcuts.keyboard." . Slot)
			continue
		Rows.Push({ Section: "shortcuts.keyboard", Key: Slot, Delete: true })
	}
	for Row in KeyCombinationScopeRows()
		Rows.Push(Row)
	return Rows
}
