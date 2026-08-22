; tests/meta/test_llm_trigger_journal_lifecycle.ahk

; ==============================================================================
; MODULE: LLM Trigger Journal Lifecycle Guard
; DESCRIPTION:
; Structural regression for the process-death boundary around the user-editable
; LLM trigger. Runtime tests prove journal replay; these assertions ensure boot,
; reload, shutdown and every path-changing writer cannot bypass that recovery.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================
; =========================================
; ======= 1/ Structural Regressions =======
; =========================================
; =========================================

_LLMJG_BootRecoversBeforeAnyConfigConsumer() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must remain readable for the WAL guard")
	JournalInclude := InStr(Src, "#Include trigger_journal.ahk", true)
	Assert(JournalInclude > 0,
		"the stable trigger WAL module must remain in the production include graph")
	ShortcutInclude := InStr(Src, "#Include trigger_shortcut.ahk", true,
		JournalInclude)
	Assert(ShortcutInclude > JournalInclude,
		"the journal API must load before the shortcut transaction references it")

	BootInclude := InStr(Src, "#Include infra/boot.ahk", true)
	Assert(BootInclude > 0, "the boot path resolver must remain source-visible")
	RecoveryGate := InStr(Src,
		"if !LLM_TriggerJournalRecoverAtBoot()", true, BootInclude)
	Onboarding := InStr(Src, "Onboarding_Run()", true, RecoveryGate)
	FirstParse := InStr(Src,
		"global _IniCache := ParseTomlFile(ConfigurationFile)", true,
		RecoveryGate)
	Assert(RecoveryGate > BootInclude,
		"boot must resolve paths.toml before opening the stable journal")
	Assert(Onboarding > RecoveryGate && FirstParse > RecoveryGate,
		"journal recovery must precede onboarding and the first config parse")
}
Test("[llm-trigger-wal-meta] boot recovers before every config consumer",
	_LLMJG_BootRecoversBeforeAnyConfigConsumer)

_LLMJG_TransactionOrdersEveryDurableBoundary() {
	Build := _StripFullLineComments(
		_DriverFuncBody("_LLM_Menu_BuildTriggerShortcutPlan"))
	Prepare := _StripFullLineComments(
		_DriverFuncBody("_LLM_TriggerJournalPrepareTransaction"))
	Activate := _StripFullLineComments(
		_DriverFuncBody("_LLM_Menu_ActivatePreparedTrigger"))
	Abort := _StripFullLineComments(
		_DriverFuncBody("_LLM_Menu_AbortPreparedTrigger"))
	Writer := _StripFullLineComments(
		_DriverFuncBody("_LLM_Menu_TriggerJournalWriter"))
	Commit := _StripFullLineComments(
		_DriverFuncBody("LLM_Menu_CommitTriggerShortcut"))
	for Spec in [
		{ body: Build, name: "_LLM_Menu_BuildTriggerShortcutPlan" },
		{ body: Prepare, name: "_LLM_TriggerJournalPrepareTransaction" },
		{ body: Activate, name: "_LLM_Menu_ActivatePreparedTrigger" },
		{ body: Abort, name: "_LLM_Menu_AbortPreparedTrigger" },
		{ body: Writer, name: "_LLM_Menu_TriggerJournalWriter" },
		{ body: Commit, name: "LLM_Menu_CommitTriggerShortcut" }
	] {
		Assert(Spec.body != "", Spec.name . " must remain source-visible")
	}

	ReconcilePos := InStr(Build, "LLM_TriggerJournalReconcile(", true)
	ReservePos := InStr(Build, "_HotkeyRegistrarReserveResolvedOwned(", true)
	PendingPos := InStr(Build,
		"_LLM_TriggerJournalPrepareTransaction(", true)
	Assert(ReconcilePos > 0 && ReservePos > ReconcilePos
		&& PendingPos > ReservePos,
		"old WAL authority must settle before reserve-Off, then pending publication")

	OwnershipPos := InStr(Prepare, "_ConfigWriteLeaseOwns(", true)
	PrepareReconcilePos := InStr(Prepare,
		"LLM_TriggerJournalReconcile(", true)
	SnapshotPos := InStr(Prepare,
		"_LLM_TriggerJournalReadSnapshot(", true)
	PublishPos := InStr(Prepare, "_LLM_TriggerJournalPublish(", true)
	Assert(OwnershipPos > 0 && PrepareReconcilePos > OwnershipPos
		&& SnapshotPos > PrepareReconcilePos && PublishPos > SnapshotPos,
		"pending intent must derive from an owned, reconciled durable snapshot")

	ActivatePos := InStr(Activate, "_HotkeyRegistrarActivate(", true)
	CommittedNewPos := InStr(Activate,
		"_LLM_TriggerJournalCommitNew(", true)
	Assert(CommittedNewPos > 0 && ActivatePos > CommittedNewPos,
		"native activation requires already-durable committed_new authority")
	AssertContains(Abort, "_HotkeyRegistrarRetire(",
		"post-activation compensation must retire the native candidate")
	AssertContains(Abort, "_HotkeyRegistrarAbort(",
		"pre-activation compensation must discard the inert reservation")

	ForwardPos := InStr(Writer, "_LLM_TriggerJournalInvokeWriter(", true)
	VerifyPos := InStr(Writer, "_LLM_TriggerJournalVerifyNew(", true)
	RollbackPos := InStr(Writer, "_LLM_TriggerJournalRollback(", true)
	Assert(ForwardPos > 0 && VerifyPos > ForwardPos && RollbackPos > VerifyPos,
		"an ambiguous forward result must be verified then reconciled under one lease")
	GatewayPos := InStr(Commit, "GatewayWriter :=", true)
	SavePos := InStr(Commit, "CS_SaveBuilt(", true)
	Assert(GatewayPos > 0 && SavePos > GatewayPos,
		"the generic config transaction must receive the journal-aware writer")
	AssertContains(Commit, "GatewayWriter, NotifyFn",
		"no raw writer may bypass the durable trigger gateway")
}
Test("[llm-trigger-wal-meta] transaction orders every durable boundary",
	_LLMJG_TransactionOrdersEveryDurableBoundary)

_LLMJG_LifecycleAndPathWritersDrainStableAuthority() {
	ReloadWrapper := _StripFullLineComments(
		_DriverFuncBody("ReloadPreservingSuspend"))
	ReloadBody := _StripFullLineComments(
		_DriverFuncBody("_ReloadPreservingSuspendNonCritical"))
	ShutdownBody := _StripFullLineComments(
		_DriverFuncBody("Ergopti_OnShutdown"))
	ResetBody := _StripFullLineComments(
		_DriverFuncBody("ReloadWithDefaultConfig"))
	PathsBody := _StripFullLineComments(
		_DriverFuncBody("_PathsFile_Write"))
	OnboardingBody := _StripFullLineComments(
		_DriverFuncBody("_Onboarding_Commit"))
	TransitionCommit := _StripFullLineComments(
		_DriverFuncBody("_ConfigTransitionCommitOwnedNonCritical"))
	QuiesceBody := _StripFullLineComments(
		_DriverFuncBody("LLM_Menu_QuiesceTriggerForLifecycle"))
	for Spec in [
		{ body: ReloadWrapper, name: "ReloadPreservingSuspend" },
		{ body: ReloadBody, name: "ReloadPreservingSuspend" },
		{ body: ShutdownBody, name: "Ergopti_OnShutdown" },
		{ body: ResetBody, name: "ReloadWithDefaultConfig" },
		{ body: PathsBody, name: "_PathsFile_Write" },
		{ body: OnboardingBody, name: "_Onboarding_Commit" },
		{ body: TransitionCommit,
			name: "_ConfigTransitionCommitOwnedNonCritical" },
		{ body: QuiesceBody, name: "LLM_Menu_QuiesceTriggerForLifecycle" }
	] {
		Assert(Spec.body != "", Spec.name . " must remain source-visible")
	}

	AssertContains(ReloadWrapper, 'Critical("Off")',
		"reload must defuse inherited Critical before any durable boundary")
	AssertContains(ReloadWrapper, "_ReloadPreservingSuspendNonCritical(",
		"the public reload entry point must delegate only after Critical is off")
	ReloadRetained := InStr(ReloadBody,
		"ConfigTransitionRetainedBarrier()", true)
	ReloadAcquire := InStr(ReloadBody,
		"LLM_Menu_AcquireLifecycleBundle()", true)
	ReloadOwnerCheck := InStr(ReloadBody,
		"_ConfigWriteLeaseSelectOwner(OwnerBundle", true)
	ReloadDrain := InStr(ReloadBody,
		"LLM_Menu_QuiesceTriggerForLifecycle(", true)
	Handoff := InStr(ReloadBody, "SuspendHandoffReload(", true,
		ReloadDrain)
	ReloadRelease := InStr(ReloadBody,
		"_ConfigWriteTerminalRelease(OwnerBundle)", true, Handoff)
	Assert(ReloadRetained > 0 && ReloadAcquire > ReloadRetained
		&& ReloadOwnerCheck > ReloadAcquire && ReloadDrain > ReloadOwnerCheck
		&& Handoff > ReloadDrain && ReloadRelease > Handoff,
		"reload must hold the global bundle from WAL drain through hand-off")
	AssertContains(ReloadBody, "ExistingBundle",
		"reload must accept a caller-owned multi-target transition bundle")
	AssertContains(ReloadBody,
		"LLM_Menu_QuiesceTriggerForLifecycle(OwnerBundle)",
		"reload recovery must quiesce native and disk authority under one owner")

	HandoffClaim := InStr(ShutdownBody, "ReloadTerminalHandoffClaim(", true)
	RetainedBarrier := InStr(ShutdownBody,
		"ConfigTransitionRetainedBarrier()", true)
	ShutdownAcquire := InStr(ShutdownBody,
		"LLM_Menu_AcquireLifecycleBundle()", true)
	ReleaseGate := InStr(ShutdownBody, "TapHoldShutdownReleaseGate()", true,
		ShutdownAcquire)
	FullSaveGate := InStr(ShutdownBody,
		"_ConfigFullSaveSettleTerminal(ShutdownOwners)", true)
	ShutdownDrain := InStr(ShutdownBody,
		"LLM_Menu_QuiesceTriggerForLifecycle(", true, FullSaveGate)
	UpdaterGate := InStr(ShutdownBody,
		"_Updater_RecoveryMayEnterTerminalShutdown()", true)
	KeyloggerTeardown := InStr(ShutdownBody, "KL_BeginShutdown()", true)
	Assert(HandoffClaim > 0 && RetainedBarrier > HandoffClaim
		&& ShutdownAcquire > RetainedBarrier && ReleaseGate > ShutdownAcquire
		&& FullSaveGate > ReleaseGate && ShutdownDrain > FullSaveGate
		&& UpdaterGate > ShutdownDrain && KeyloggerTeardown > ShutdownDrain,
		"shutdown must settle accepted writes and the WAL before teardown")
	AssertContains(ShutdownBody, 'StrCompare(reason, "Reload", true) != 0',
		"read-only malformed-journal exit is forbidden for Reload")

	ResetLease := InStr(ResetBody,
		"ConfigTransitionAcquireLifecycleBundle(", true)
	ResetDrain := InStr(ResetBody,
		"LLM_Menu_QuiesceTriggerForLifecycle(", true)
	DestructivePrepare := InStr(ResetBody,
		"LLM_TriggerJournalPrepareDestructive(", true)
	ResetCommit := InStr(ResetBody, "ConfigTransitionCommitOwned(", true)
	ResetReload := InStr(ResetBody, "ReloadPreservingSuspend(", true)
	ResetRollback := InStr(ResetBody, "ConfigTransitionRollbackOwned(", true)
	ResetRelease := InStr(ResetBody,
		"_ConfigWriteTerminalRelease(OwnerBundle)", true)
	Assert(ResetLease > 0 && ResetDrain > ResetLease
		&& DestructivePrepare > ResetDrain && ResetCommit > DestructivePrepare
		&& ResetReload > ResetCommit && ResetRollback > ResetReload
		&& ResetRelease > ResetRollback,
		"reset must WAL-commit all targets and retain ownership through rollback")
	Assert(InStr(ResetBody, "FileDelete(", true) = 0,
		"reset must not bypass its multi-target WAL with raw deletion")

	PathsLease := InStr(PathsBody,
		"ConfigTransitionAcquireLifecycleBundle(", true)
	PathsDrain := InStr(PathsBody,
		"LLM_Menu_QuiesceTriggerForLifecycle(", true)
	PathsWrite := InStr(PathsBody, "ConfigTransitionCommitOwned(", true)
	PathsReload := InStr(PathsBody, "ReloadPreservingSuspend(", true)
	PathsRollback := InStr(PathsBody, "ConfigTransitionRollbackOwned(", true)
	PathsRelease := InStr(PathsBody,
		"_ConfigWriteTerminalRelease(OwnerBundle)", true)
	Assert(PathsLease > 0 && PathsDrain > PathsLease
		&& PathsWrite > PathsDrain && PathsReload > PathsWrite
		&& PathsRollback > PathsReload && PathsRelease > PathsRollback,
		"paths.toml must hold config ownership from quiescence through reload")
	AssertContains(PathsBody, "ReloadPreservingSuspend(0, OwnerBundle)",
		"the paths writer must lend its exact bundle to reload")
	Assert(InStr(PathsBody, "FileOpen(", true) = 0,
		"paths.toml publication must not bypass the transition WAL")

	OnboardingLease := InStr(OnboardingBody,
		"ConfigTransitionAcquireLifecycleBundle(", true)
	OnboardingDrain := InStr(OnboardingBody,
		"LLM_Menu_QuiesceTriggerForLifecycle(", true)
	CandidateBuild := InStr(OnboardingBody,
		"TOML_BuildUpdatedContent(", true)
	TransitionWrite := InStr(OnboardingBody,
		"ConfigTransitionCommitOwned(", true)
	GlobalPublish := InStr(OnboardingBody,
		"_ConfigDir := CandidateDir", true)
	OnboardingReload := InStr(OnboardingBody,
		"ReloadPreservingSuspend(BeforeReloadFn, OwnerBundle)", true)
	OnboardingRollback := InStr(OnboardingBody,
		"ConfigTransitionRollbackOwned(", true)
	OnboardingRelease := InStr(OnboardingBody,
		"_ConfigWriteTerminalRelease(OwnerBundle)", true)
	Assert(OnboardingLease > 0 && OnboardingDrain > OnboardingLease
		&& CandidateBuild > OnboardingDrain
		&& TransitionWrite > CandidateBuild && GlobalPublish > TransitionWrite,
		"onboarding must persist candidate config and redirect before live publication")
	Assert(OnboardingReload > GlobalPublish
		&& OnboardingRollback > OnboardingReload
		&& OnboardingRelease > OnboardingRollback,
		"onboarding must retain every path owner through reload and rollback")
	AssertContains(OnboardingBody,
		"LLM_Menu_QuiesceTriggerForLifecycle(OwnerBundle)",
		"onboarding must quiesce native and disk authority before relocation")

	CommitOwner := InStr(TransitionCommit,
		"_ConfigTransitionRuntimeOwns(Bundle", true)
	CommitRecover := InStr(TransitionCommit,
		"_ConfigTransitionRecoverOwnedNonCritical(", true)
	CommitPrepare := InStr(TransitionCommit, "ConfigTransitionPrepare(", true)
	CommitApply := InStr(TransitionCommit, "ConfigTransitionApply(", true)
	Assert(CommitOwner > 0 && CommitRecover > CommitOwner
		&& CommitPrepare > CommitRecover && CommitApply > CommitPrepare,
		"the WAL gateway must verify bundle ownership, recover, prepare, then apply")

	QuiesceOwner := InStr(QuiesceBody,
		"_ConfigWriteLeaseSelectOwner(OwnerBundle", true)
	ClaimPos := InStr(QuiesceBody,
		"_LLM_Menu_ClaimTriggerRecovery(", true)
	AdvancePos := InStr(QuiesceBody,
		"_LLM_Menu_AdvanceClaimedTriggerRecovery(", true)
	ReconcilePos := InStr(QuiesceBody,
		"LLM_TriggerJournalReconcile(", true)
	Assert(QuiesceOwner > 0 && ClaimPos > QuiesceOwner
		&& AdvancePos > ClaimPos && ReconcilePos > ClaimPos,
		"lifecycle recovery must own disk authority before draining native recovery")
	AssertContains(QuiesceBody, "_ConfigWriteTerminalRelease(OwnerBundle)",
		"self-owned quiescence must release its whole terminal bundle")
}
Test("[llm-trigger-wal-meta] lifecycle and path writers drain stable authority",
	_LLMJG_LifecycleAndPathWritersDrainStableAuthority)

_LLMJG_LocatorIsStableAcrossConfigRelocation() {
	PathBody := _StripFullLineComments(
		_DriverFuncBody("_LLM_TriggerJournalPath"))
	DestructiveBody := _StripFullLineComments(
		_DriverFuncBody("LLM_TriggerJournalPrepareDestructive"))
	Assert(PathBody != "", "_LLM_TriggerJournalPath must remain source-visible")
	Assert(DestructiveBody != "",
		"LLM_TriggerJournalPrepareDestructive must remain source-visible")
	AssertContains(PathBody, "_PathsFile . LLM_TRIGGER_JOURNAL_SUFFIX",
		"the WAL must stay beside the stable paths.toml locator")
	Assert(InStr(PathBody, "ConfigurationFile", true) = 0,
		"a relocatable config directory must never own the WAL location")
	CriticalPos := InStr(DestructiveBody, 'Critical("Off")', true)
	LeasePos := InStr(DestructiveBody,
		"_ConfigWriteLeaseSelectOwner(ExistingOwners, ConfigPath)", true)
	ReconcilePos := InStr(DestructiveBody,
		"LLM_TriggerJournalReconcile(", true)
	DeletePos := InStr(DestructiveBody, "_LLM_TriggerJournalDelete(", true)
	Assert(CriticalPos > 0 && LeasePos > CriticalPos
		&& ReconcilePos > LeasePos && DeletePos > ReconcilePos,
		"destructive cleanup requires non-Critical bundle ownership and reconciliation")
}
Test("[llm-trigger-wal-meta] locator remains stable across config relocation",
	_LLMJG_LocatorIsStableAcrossConfigRelocation)
