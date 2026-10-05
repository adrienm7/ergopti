; tests/meta/test_config_transition_integration.ahk

; ==============================================================================
; MODULE: Configuration Transition Integration Meta Tests
; DESCRIPTION:
; Guards the transitive production wiring that a unit-tested journal cannot see:
; include order, recovery before paths.toml parsing, terminal barrier lifetime,
; config-before-locator ordering, strict result checks, visible refusal, rollback,
; and the absence of raw multi-file mutations in UI entry points.
;
; FEATURES & RATIONALE:
; 1. Assertions strip full-line comments so prose cannot create a false green.
; 2. Every migrated caller is enumerated; one hardened site cannot hide a twin.
; 3. Critical inheritance is rejected at the runtime and public UI boundaries.
; 4. Reset intentions are structurally tied to the pure behavioural helper.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================
; =========================================
; ======= 1/ Boot and Include Order =======
; =========================================
; =========================================

_CTIM_BootRecoversBeforeLocatorRead() {
	Entry := _StripFullLineComments(_DriverFuncOrFileText("ErgoptiPlus.ahk"))
	Assert(Entry != "", "the production entrypoint must be readable")
	CoreInclude := InStr(Entry, "#Include infra/config_transition.ahk", true)
	RuntimeInclude := InStr(Entry,
		"#Include infra/config_transition_runtime.ahk", true)
	BootInclude := InStr(Entry, "#Include infra/boot.ahk", true)
	Assert(CoreInclude > 0 && RuntimeInclude > CoreInclude
		&& BootInclude > RuntimeInclude,
		"production must load core then runtime before boot auto-execute")
	Boot := _StripFullLineComments(_DriverFuncOrFileText("infra/boot.ahk"))
	Locator := InStr(Boot, "global _PathsFile :=", true)
	Recover := InStr(Boot,
		"ConfigTransitionRecoverAtBootOrThrow(_PathsFile)", true)
	Read := InStr(Boot,
		"global _PathsOverrides := ReadPathsToml(_PathsFile)", true)
	Assert(Locator > 0 && Recover > Locator && Read > Recover,
		"boot must resolve the stable locator, recover WAL, then read paths.toml")
}

; Reads one production file by root-relative path. Unlike the concatenated
; source helper, this preserves top-level auto-execute ordering inside boot.ahk.
_DriverFuncOrFileText(RelativePath) {
	SplitPath(A_ScriptDir, , &Root)
	try return FileRead(Root . "\" . StrReplace(RelativePath, "/", "\"),
		"UTF-8")
	catch
		return ""
}

Test("config transition integration: recovery precedes paths.toml read "
	. "(config-transition-integration-boot-order)",
	_CTIM_BootRecoversBeforeLocatorRead)





; ==============================================
; ==============================================
; ======= 2/ Caller Transaction Ordering =======
; ==============================================
; ==============================================

; A launched Reload is refused, if ever, only after the caller returned (see
; infra/reload_terminal_handoff.ahk). So the rollback lives in one helper that
; runs both when no successor launched and from the refusal callback, and a
; pending Reload keeps the bundle instead of the caller releasing it.
_CTIM_AssertCommonCaller(Name, CommitNeedle, ReloadNeedle, RollbackName,
		SyncRollbackNeedle) {
	Body := _StripFullLineComments(_DriverFuncBody(Name))
	Assert(Body != "", Name . " must exist")
	CriticalOff := InStr(Body, 'Critical("Off")', true)
	Acquire := InStr(Body, "ConfigTransitionAcquireLifecycleBundle(", true)
	Commit := InStr(Body, CommitNeedle, true)
	Strict := InStr(Body,
		'ConfigTransitionResultIs(CommitResult, "committed_new")', true)
	Reload := InStr(Body, ReloadNeedle, true)
	Settle := InStr(Body, "ConfigTransitionSettleRefusedReload.Bind(", true)
	Handoff := Reload ? InStr(Body, "ReleaseBundle := false", true, Reload) : 0
	SyncRollback := Reload ? InStr(Body, SyncRollbackNeedle, true, Reload) : 0
	BarrierFlag := InStr(Body, 'CommitResult.Has("barrier_retained")', true)
	Release := InStr(Body, "_ConfigWriteTerminalRelease(OwnerBundle)", true)
	Assert(CriticalOff > 0 && Acquire > CriticalOff,
		Name . " must drop inherited Critical before adapter/file/logger work")
	Assert(Acquire > 0 && Commit > Acquire,
		Name . " must acquire the global lifecycle bundle, then commit")
	Assert(Strict > Commit && BarrierFlag > Strict && Reload > BarrierFlag
		&& Settle > Reload && Handoff > Settle && SyncRollback > Handoff
		&& Release > SyncRollback,
		Name . " must strictly validate commit, lend the bundle to Reload with "
		. "its rollback, keep it on launch, roll back on refusal, then release")
	RollbackBody := _StripFullLineComments(_DriverFuncBody(RollbackName))
	Assert(RollbackBody != "", RollbackName . " must exist")
	Rollback := InStr(RollbackBody, "ConfigTransitionRollbackOwned(", true)
	Retain := InStr(RollbackBody, "ConfigTransitionRetainBarrier(OwnerBundle)",
		true)
	Assert(Rollback > 0 && Retain > Rollback
		&& InStr(RollbackBody, "return Retained", true) > Retain,
		RollbackName . " must retain unsafe rollback authority and say so")
	SettleBody := _StripFullLineComments(
		_DriverFuncBody("ConfigTransitionSettleRefusedReload"))
	Assert(InStr(SettleBody, "RollbackFn.Call(Bundle)", true) > 0
		&& InStr(SettleBody, "_ConfigWriteTerminalRelease(Bundle)", true)
			> InStr(SettleBody, "finally", true),
		"a refusal after launch must release the bundle unless the rollback retained it")
	Assert(InStr(Body, "ConfigTransitionLogFailure(", true) > 0,
		Name . " must log transition refusal with typed detail")
	DirectNotice := InStr(Body, "MsgBox(", true) > 0
		or InStr(Body, "_Onboarding_CommitError(", true) > 0
	DelegatedNotice := InStr(Body, "_ConfigResetShowFailure(", true) > 0
	Assert(DirectNotice or DelegatedNotice,
		Name . " must visibly report a user-requested transition refusal")
	if DelegatedNotice {
		NoticeBody := _StripFullLineComments(
			_DriverFuncBody("_ConfigResetShowFailure"))
		Assert(NoticeBody != "" && InStr(NoticeBody, "MsgBox(", true) > 0,
			Name . " must delegate only to a helper that actually presents a visible refusal")
	}
	for Forbidden in ["FileOpen(", "FileDelete(", "FSAppend(", "FSMove("]
		Assert(InStr(Body, Forbidden, true) == 0,
			Name . " must not bypass the multi-file journal via " . Forbidden)
}

_CTIM_PathsEditorUsesOneTransition() {
	_CTIM_AssertCommonCaller("_PathsFile_Write",
		"ConfigTransitionCommitOwned(",
		"ReloadPreservingSuspend(0, OwnerBundle,",
		"_PathsFile_RollbackRefusedReload",
		"_PathsFile_RollbackRefusedReload(OwnerBundle)")
	Body := _StripFullLineComments(_DriverFuncBody("_PathsFile_Write"))
	Normalize := InStr(Body, "ConfigTransitionNormalizeConfigDir(N)", true)
	Acquire := InStr(Body, "ConfigTransitionAcquireLifecycleBundle(", true)
	DirCreatePos := InStr(Body, "DirCreate(", true)
	Build := InStr(Body, "ConfigTransitionPathsTomlContent(", true)
	Spec := InStr(Body, "ConfigTransitionPresentTarget(_PathsFile", true)
	Commit := InStr(Body, "ConfigTransitionCommitOwned(", true)
	Assert(Normalize > 0 && Acquire > Normalize
		&& (DirCreatePos == 0 || DirCreatePos > Normalize),
		"paths editor must reject invalid directories before acquisition or I/O")
	OwnerArg := InStr(Body, "OwnerBundle)", true, Spec)
	Assert(Build > 0 && Commit > Build && Spec > Commit && OwnerArg > Spec,
		"paths editor must build bytes then pass the locator intention inside the one journal commit; AHK evaluates that argument before entering the commit")
}
Test("config transition integration: paths editor holds one terminal WAL "
	. "(config-transition-integration-paths-editor)",
	_CTIM_PathsEditorUsesOneTransition)

_CTIM_OnboardingOrdersConfigBeforeLocator() {
	_CTIM_AssertCommonCaller("_Onboarding_Commit",
		"ConfigTransitionCommitOwned(",
		"ReloadPreservingSuspend(BeforeReloadFn, OwnerBundle,",
		"_Onboarding_RollbackRefusedReload",
		"Rollback.Call(OwnerBundle)")
	Body := _StripFullLineComments(_DriverFuncBody("_Onboarding_Commit"))
	Assert(Body != "", "the onboarding transaction implementation must be available")
	Normalize := InStr(Body,
		"ConfigTransitionNormalizeConfigDir(CandidateDir)", true)
	DirCreatePos := InStr(Body, "DirCreate(CandidateDir)", true)
	Acquire := InStr(Body, "ConfigTransitionAcquireLifecycleBundle(", true)
	Build := InStr(Body, "TOML_BuildConfigUpdatedContent(CandidateConfig", true)
	Typed := InStr(Body, "updates := _ConfigPrepareTypedUpdates(updates)", true)
	ConfigSpec := InStr(Body,
		"ConfigTransitionPresentTarget(CandidateConfig", true)
	LocatorSpec := InStr(Body,
		"ConfigTransitionPresentTarget(_PathsFile", true)
	Commit := InStr(Body, "ConfigTransitionCommitOwned(", true)
	Publish := InStr(Body, "_ConfigDir := CandidateDir", true)
	Assert(Normalize > 0 && DirCreatePos > Normalize && Acquire > Normalize,
		"onboarding must reject invalid directories before acquisition or I/O")
	Assert(Build > 0 && ConfigSpec > Build && LocatorSpec > ConfigSpec
		&& Commit > LocatorSpec && Publish > Commit,
		"onboarding must declare config first, locator last, commit, then publish globals")
	Assert(Typed > Acquire && Build > Typed,
		"a relocated onboarding config must receive schema typing before candidate rendering")
	Assert(InStr(Body, "ConfigCommitBorrowedUpdates(", true) == 0,
		"onboarding must not publish config.toml outside the multi-file WAL")
}
Test("config transition integration: onboarding orders config before locator "
	. "(config-transition-integration-onboarding-order)",
	_CTIM_OnboardingOrdersConfigBeforeLocator)

_CTIM_ResetUsesThreeTargetIntention() {
	_CTIM_AssertCommonCaller("ReloadWithDefaultConfig",
		"ConfigTransitionCommitOwned(",
		"ReloadPreservingSuspend(0, OwnerBundle,",
		"_ConfigResetRollbackRefusedReload",
		"_ConfigResetRollbackRefusedReload(OwnerBundle)")
	Body := _StripFullLineComments(_DriverFuncBody("ReloadWithDefaultConfig"))
	Build := InStr(Body, "_ConfigResetTransitionTargets(", true)
	Commit := InStr(Body, "ConfigTransitionCommitOwned(", true)
	Assert(Build > 0 && Commit > Build,
		"reset must build all three target intentions before one journal commit")
	Helper := _StripFullLineComments(
		_DriverFuncBody("_ConfigResetTransitionTargets"))
	Assert(InStr(Helper,
		"ConfigTransitionPresentTarget(ConfigPath", true) > 0)
	Assert(InStr(Helper,
		"ConfigTransitionAbsentTarget(TapHoldPath)", true) > 0)
	Assert(InStr(Helper,
		"ConfigTransitionAbsentTarget(ApiEntriesPath)", true) > 0)
}
Test("config transition integration: reset is one three-target intention "
	. "(config-transition-integration-reset-specs)",
	_CTIM_ResetUsesThreeTargetIntention)





; ============================================
; ============================================
; ======= 3/ Transitive Critical Guard =======
; ============================================
; ============================================

_CTIM_RuntimeDropsCriticalAtEveryIoEntry() {
	Checked := 0
	for Name in [
		"ConfigTransitionAcquireLifecycleBundle",
		"ConfigTransitionRecoverOwned",
		"ConfigTransitionCommitOwned",
		"ConfigTransitionRollbackOwned",
		"ConfigTransitionRecoverAtBoot",
		"ConfigTransitionRecoverAtBootOrThrow",
		"ConfigTransitionLogFailure"
	] {
		Body := _StripFullLineComments(_DriverFuncBody(Name))
		Assert(Body != "", Name . " must remain source-visible")
		Assert(InStr(Body, 'PreviousCritical := Critical("Off")', true) > 0,
			Name . " must neutralize a caller's inherited Critical before I/O")
		Assert(InStr(Body, "finally Critical(PreviousCritical)", true) > 0,
			Name . " must restore the caller's exact Critical state")
		Checked += 1
	}
	AssertEqual(7, Checked,
		"the Critical guard must enumerate every public runtime I/O entry")
}
Test("config transition integration: no filesystem/logger I/O inherits Critical "
	. "(config-transition-integration-no-critical-io)",
	_CTIM_RuntimeDropsCriticalAtEveryIoEntry)
