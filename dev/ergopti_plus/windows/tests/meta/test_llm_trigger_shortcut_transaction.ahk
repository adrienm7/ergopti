; tests/meta/test_llm_trigger_shortcut_transaction.ahk

; ==============================================================================
; MODULE: LLM Trigger Shortcut Transaction Guard
; DESCRIPTION:
; Structural regression for the causal boundary behind the behavioural suite.
; It prevents the LLM consumer from returning to bind-before-write, requires a
; same-lease durable rollback and old-handle cleanup, and keeps partial recovery
; visible even though the interactive commit correctly returns false.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================
; =========================================
; ======= 1/ Structural Regressions =======
; =========================================
; =========================================

_LLMTG_StagedPlanOwnsEveryBoundary() {
	Body := _DriverFuncBody("_LLM_Menu_BuildTriggerShortcutPlan")
	Assert(Body != "",
		"_LLM_Menu_BuildTriggerShortcutPlan must remain source-visible")
	AssertContains(Body, "_HotkeyRegistrarReserveOwned(",
		"the candidate must be installed native-Off before the writer")
	Assert(InStr(Body, "_HotkeyRegistrarBindOwned(") = 0,
		"the builder must never activate a callback before durability")
	AssertContains(Body, "rollback_updates:",
		"activation refusal must reverse the durable value under the same lease")
	AssertContains(Body, "cleanup:",
		"old-handle retirement must remain a distinct post-activation phase")
	AssertContains(Body, "retain:",
		"every refused opaque-handle cleanup must publish recovery ownership")
	Assert(InStr(Body, "noop: true") = 0,
		"validation, collision and recovery refusals must reach one failure terminal")
}
Test("[llm-trigger-tx-meta] plan stages every causal boundary",
	_LLMTG_StagedPlanOwnsEveryBoundary)

_LLMTG_MenuProjectsPartialRecovery() {
	RowsBody := _DriverFuncBody("_LLM_Menu_TriggerRows")
	PromptBody := _DriverFuncBody("LLM_Menu_PromptTriggerShortcut")
	Assert(RowsBody != "", "_LLM_Menu_TriggerRows must remain source-visible")
	Assert(PromptBody != "",
		"LLM_Menu_PromptTriggerShortcut must remain source-visible")
	AssertContains(RowsBody, "LLM_Menu_TriggerDisplayValue()",
		"the tray label must project the transactional recovery status")
	AssertContains(PromptBody, "LLM_Menu_TriggerNeedsAttention()",
		"a false partial commit must still rebuild the visible warning")
}
Test("[llm-trigger-tx-meta] tray exposes partial recovery",
	_LLMTG_MenuProjectsPartialRecovery)

_LLMTG_RecoveryIsTerminableAndPostLease() {
	RunBody := _DriverFuncBody("LLM_Menu_RunTriggerRecovery")
	ClaimBody := _DriverFuncBody("_LLM_Menu_ClaimTriggerRecovery")
	ClaimedRunBody := _DriverFuncBody("_LLM_Menu_RunClaimedTriggerRecovery")
	AdvanceBody := _DriverFuncBody("_LLM_Menu_AdvanceClaimedTriggerRecovery")
	RetireBody := _DriverFuncBody("_LLM_Menu_RetireTriggerRecoveryHandles")
	RetainBody := _DriverFuncBody("_LLM_Menu_RetainTriggerRecovery")
	ScheduleBody := _DriverFuncBody("_LLM_Menu_ScheduleTriggerRecovery")
	ServiceBody := _DriverFuncBody("LLM_Menu_ServiceTriggerRecovery")
	CommitBody := _DriverFuncBody("LLM_Menu_CommitTriggerShortcut")
	Assert(RunBody != "", "LLM_Menu_RunTriggerRecovery must remain source-visible")
	Assert(ClaimBody != "",
		"_LLM_Menu_ClaimTriggerRecovery must remain source-visible")
	Assert(ClaimedRunBody != "",
		"_LLM_Menu_RunClaimedTriggerRecovery must remain source-visible")
	Assert(AdvanceBody != "",
		"_LLM_Menu_AdvanceClaimedTriggerRecovery must remain source-visible")
	Assert(RetireBody != "",
		"_LLM_Menu_RetireTriggerRecoveryHandles must remain source-visible")
	Assert(RetainBody != "",
		"_LLM_Menu_RetainTriggerRecovery must remain source-visible")
	Assert(ScheduleBody != "",
		"_LLM_Menu_ScheduleTriggerRecovery must remain source-visible")
	Assert(CommitBody != "",
		"LLM_Menu_CommitTriggerShortcut must remain source-visible")
	Assert(ServiceBody != "",
		"LLM_Menu_ServiceTriggerRecovery must remain source-visible")
	AssertContains(RunBody, "_LLM_Menu_ClaimTriggerRecovery(",
		"a timer callback must atomically claim its scheduled ownership")
	AssertContains(ClaimBody, 'Record["running"] := true',
		"claim publication must precede every yielded recovery effect")
	AssertContains(ClaimedRunBody, "_ConfigWriteLeaseTryAcquire(",
		"a recovery attempt must serialize with later config edits")
	SuspendPos := InStr(ClaimedRunBody, "A_IsSuspended")
	LeasePos := InStr(ClaimedRunBody, "_ConfigWriteLeaseTryAcquire(")
	Assert(SuspendPos > 0 && LeasePos > SuspendPos,
		"a timer callback must refuse every observable recovery effect while paused")
	AssertContains(RetireBody, "_HotkeyRegistrarRetire(",
		"recovery must terminate every retained native owner")
	AssertContains(RetireBody, "HotkeyRegistrarChordOf(",
		"already-retired opaque handles must be terminal, not retry forever")
	AssertContains(ClaimedRunBody, "_LLM_Menu_AdvanceClaimedTriggerRecovery(",
		"the claimed recovery must delegate durable advancement through its admitted owner")
	AssertContains(AdvanceBody, "_ConfigInvokeCommitWriter(",
		"rollback recovery must finish the old durable rewrite")
	RollbackPos := InStr(AdvanceBody, 'Record["stage"] = "rollback"')
	RollbackRetirePos := InStr(AdvanceBody,
		"_LLM_Menu_RetireTriggerRecoveryHandles(", , RollbackPos)
	RollbackWriterPos := InStr(AdvanceBody, "_ConfigInvokeCommitWriter(",
		, RollbackPos)
	RollbackCompletePos := InStr(AdvanceBody,
		"_LLM_Menu_CompleteTriggerRecovery(", , RollbackWriterPos)
	Assert(RollbackPos > 0 && RollbackWriterPos > RollbackPos
		&& RollbackRetirePos > RollbackPos && RollbackRetirePos < RollbackWriterPos
		&& RollbackCompletePos > RollbackWriterPos,
		"rollback recovery must retire retained handles before clearing its record")
	AssertContains(ClaimedRunBody, "RefreshFn.Call()",
		"successful recovery must rebuild the already-published warning row")
	AssertContains(RetainBody, "_LLM_Menu_InstallTriggerRecovery(",
		"partial failure must retain and schedule one explicit recovery record")
	AssertContains(ScheduleBody, "LLM_TRIGGER_RECOVERY_MAX_ATTEMPTS",
		"a permanent OS failure must not create an unbounded 250 ms timer loop")
	AssertContains(ScheduleBody, 'Record["running"]',
		"the scheduler must not queue behind an in-flight direct owner")
	AssertContains(ServiceBody, 'Record["running"]',
		"watchdog service must not race an in-flight direct owner")
	RetryPos := InStr(CommitBody, "_LLM_Menu_ClaimTriggerRecovery(0, false)")
	RunClaimedPos := InStr(CommitBody, "_LLM_Menu_RunClaimedTriggerRecovery(")
	CommitPos := InStr(CommitBody, "CS_SaveBuilt(")
	Assert(RetryPos > 0 && RunClaimedPos > RetryPos && CommitPos > RunClaimedPos,
		"a later edit must claim and finish recovery before claiming a new plan")
	Lifecycle := _DriverFuncBody("_SuspendStateWatchdog")
	Resume := _DriverFuncBody("LLM_Menu_OnResume")
	Assert(Lifecycle != "", "_SuspendStateWatchdog must remain source-visible")
	Assert(Resume != "", "LLM_Menu_OnResume must remain source-visible")
	AssertContains(Lifecycle, "LLM_Menu_ServiceTriggerRecovery()",
		"the active watchdog must recover a refused timer arm")
	AssertContains(Resume, "LLM_Menu_ServiceTriggerRecovery()",
		"resume must transfer a timer callback consumed during pause")
	for Spec in [
		{ body: Lifecycle, label: "watchdog" },
		{ body: Resume, label: "resume" }
	] {
		CallPos := InStr(Spec.body, "LLM_Menu_ServiceTriggerRecovery()")
		CatchPos := CallPos > 0
			? InStr(Spec.body, "catch as Err", , CallPos) : 0
		LogPos := CatchPos > 0
			? InStr(Spec.body, 'LoggerError(', , CatchPos) : 0
		Assert(CallPos > 0 && CatchPos > CallPos && LogPos > CatchPos,
			Spec.label . " recovery boundary must log every service exception")
	}
}
Test("[llm-trigger-tx-meta] recovery is terminable and post-lease",
	_LLMTG_RecoveryIsTerminableAndPostLease)

_LLMTG_BootFailureIsVisibleAndStrictlyConsumed() {
	ApplyBody := _DriverFuncBody("LLM_Menu_ApplyTriggerShortcut")
	NotifyBody := _DriverFuncBody("_LLM_Menu_NotifyTriggerApplyFailure")
	InitBody := _DriverFuncBody("LLM_Menu_Init")
	Assert(ApplyBody != "",
		"LLM_Menu_ApplyTriggerShortcut must remain source-visible")
	Assert(NotifyBody != "",
		"_LLM_Menu_NotifyTriggerApplyFailure must remain source-visible")
	Assert(InitBody != "", "LLM_Menu_Init must remain source-visible")
	AssertContains(ApplyBody, "_LLM_Menu_NotifyTriggerApplyFailure(",
		"boot replay refusal must have a user-visible terminal")
	AssertContains(NotifyBody, "NotifierSend(",
		"the boot terminal must use the canonical non-modal notifier")
	Assert(InStr(NotifyBody, "MsgBox(") = 0,
		"shortcut activation failure must never block the tray build")
	AssertContains(InitBody, "TriggerReady := LLM_Menu_ApplyTriggerShortcut(",
		"the deferred boot initializer must consume the replay result")
	AssertContains(InitBody, "TriggerReady is Integer",
		"boot must reject malformed truthy activation statuses")
	FirstRestorePos := InStr(InitBody, "if FirstRestore {")
	ReplayPos := InStr(InitBody, "LLM_Menu_ApplyTriggerShortcut(")
	OverridesGatePos := InStr(InitBody,
		'if FirstRestore && saved_opts.Has("app_profile_overrides")')
	Assert(FirstRestorePos > 0 && ReplayPos > FirstRestorePos,
		"a root tray rebuild must not replay the stale boot trigger snapshot")
	Assert(OverridesGatePos > 0,
		"sibling app-profile state must carry the same one-shot restore condition")
}
Test("[llm-trigger-tx-meta] boot failure is visible and strictly consumed",
	_LLMTG_BootFailureIsVisibleAndStrictlyConsumed)

_LLMTG_PublicSetterLogsSuccess() {
	CommitBody := _DriverFuncBody("LLM_Menu_CommitTriggerShortcut")
	ApplyBody := _DriverFuncBody("LLM_Menu_ApplyTriggerShortcut")
	ReplayTerminalBody := _DriverFuncBody("_LLM_Menu_AcceptTriggerReplay")
	Assert(CommitBody != "",
		"LLM_Menu_CommitTriggerShortcut must remain source-visible")
	Assert(ApplyBody != "",
		"LLM_Menu_ApplyTriggerShortcut must remain source-visible")
	Assert(ReplayTerminalBody != "",
		"_LLM_Menu_AcceptTriggerReplay must remain source-visible")
	AssertContains(CommitBody, 'LoggerDebug("LLM", "Trigger shortcut committed',
		"the public live setter must log its accepted value at DEBUG")
	AssertContains(ReplayTerminalBody,
		'LoggerDebug("LLM", "Trigger shortcut replayed',
		"the shared replay terminal must log the native value it accepted")
	AssertContains(ApplyBody, "_LLM_Menu_AcceptTriggerReplay(",
		"every accepted replay branch must delegate to the logged terminal")
	Assert(InStr(ApplyBody, "return true") = 0,
		"an accepted replay must not bypass its logged success terminal")
}
Test("[llm-trigger-tx-meta] public setter logs accepted authority",
	_LLMTG_PublicSetterLogsSuccess)
