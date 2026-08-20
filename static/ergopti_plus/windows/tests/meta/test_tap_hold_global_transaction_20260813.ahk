; tests/meta/test_tap_hold_global_transaction_20260813.ahk

; ==============================================================================
; MODULE: Tap-Hold Transaction Class Structural Guard
; DESCRIPTION:
; Enumerates every user-reachable tap-hold writer plus reset. The invariant is
; transitive: all entry points must converge on the global config admission
; gate, a unique durable same-directory stage, post-stage owner/path
; authorization, atomic replacement, and one short live publication window.
;
; FEATURES & RATIONALE:
; 1. A new sibling writer joins one explicit class-wide assertion list.
; 2. The test guards transaction ordering rather than one implementation site.
; 3. Reset is held to the same terminal-admission and refusal contract.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Writer entry class =======
; =====================================
; =====================================

_THGTM_EveryWriterDefusesAndConverges() {
	for Name in ["WriteTapHoldTap", "WriteTapHoldHold",
			"WriteTapHoldNative", "_TH_WriteTapHoldDisabled"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must remain source-visible")
		Assert(InStr(Body, "A_IsCritical") > 0
			&& InStr(Body, 'Critical("Off")') > 0,
			Name . " must defuse inherited Critical for the complete public action")
		Assert(InStr(Body, "_TH_CommitTapHoldMutation(") > 0,
			Name . " must converge on the single global transaction gateway")
	}

	ResetBody := _DriverFuncBody("_TH_ResetAllToDefaults")
	Assert(ResetBody != "", "_TH_ResetAllToDefaults must remain source-visible")
	Assert(InStr(ResetBody, "A_IsCritical") > 0
		&& InStr(ResetBody, 'Critical("Off")') > 0
		&& InStr(ResetBody, "_TH_ResetTapHoldConfig(") > 0,
		"reset must defuse inherited Critical and delegate to the admitted reset transaction")
}
Test("tap-hold transaction meta: every writer and reset converges on admission "
	. "(tap-hold-global-transaction-meta)",
	_THGTM_EveryWriterDefusesAndConverges)





; ===========================================
; ===========================================
; ======= 2/ Commit protocol ordering =======
; ===========================================
; ===========================================

_THGTM_CommitOwnsBeforeSnapshot() {
	Body := _DriverFuncBody("_TH_CommitTapHoldMutation")
	Assert(Body != "", "_TH_CommitTapHoldMutation must remain source-visible")
	BoundPos := InStr(Body, "BoundPath := _TH_TapHoldConfigPath()")
	LeasePos := InStr(Body, "_ConfigWriteLeaseTryAcquire(BoundPath")
	SnapshotPos := InStr(Body, "StartState := TapHold")
	ClonePos := InStr(Body, "Candidate := _TH_CloneData(StartState)")
	WritePos := InStr(Body, "_TH_WriteTapHoldToml(Candidate")
	ReleasePos := InStr(Body, "_ConfigWriteLeaseRelease(OwnerToken)")
	Assert(BoundPos > 0 && LeasePos > BoundPos
		&& SnapshotPos > LeasePos && ClonePos > SnapshotPos
		&& WritePos > ClonePos && ReleasePos > WritePos,
		"the exact path must be captured and globally owned before the detached snapshot, then held through commit")
}
Test("tap-hold transaction meta: global owner precedes detached snapshot "
	. "(tap-hold-global-transaction-meta)",
	_THGTM_CommitOwnsBeforeSnapshot)

_THGTM_DurableWriterIsUniqueAuthorizedAndAtomic() {
	Body := _DriverFuncBody("_TH_WriteTapHoldToml")
	Assert(Body != "", "_TH_WriteTapHoldToml must remain source-visible")
	StagePos := InStr(Body, "FSWriteDurable(StagePath, Content)")
	AuthorizePos := InStr(Body, "_TH_AuthorizeTapHoldCommit(OwnerToken")
	ReplacePos := InStr(Body, "FSAtomicMoveReplace(StagePath, BoundPath)")
	PublishPos := InStr(Body, "_TH_PublishTapHoldCandidate(Data, OwnerToken")
	Assert(StagePos > 0 && AuthorizePos > StagePos
		&& ReplacePos > AuthorizePos && PublishPos > ReplacePos,
		"a complete durable stage must be re-authorized, atomically replaced, then published live in order")
	Assert(InStr(Body, "A_ScriptHwnd") > 0
		&& InStr(Body, "LocalSequence") > 0,
		"the same-directory stage must be unique to the process and transaction")
	Assert(InStr(Body, 'BoundPath . ".tmp"') == 0,
		"the writer must not reuse a process-independent fixed .tmp path")
	Assert(InStr(Body, "FileAppend(") == 0
		&& InStr(Body, "FileMove(") == 0
		&& InStr(Body, "FileDelete(") == 0,
		"tap-hold persistence must use the durable filesystem adapters exclusively")
	for ResultName in ["Written", "Replaced", "Published"] {
		Assert(InStr(Body, "(" . ResultName . " is Integer)") > 0
			&& InStr(Body, ResultName . " == 1") > 0,
			ResultName . " must accept only the strict Integer 1 success token")
	}

	Publisher := _DriverFuncBody("_TH_PublishTapHoldCandidate")
	Assert(Publisher != "", "_TH_PublishTapHoldCandidate must remain source-visible")
	Assert(InStr(Publisher, "TapHold := Candidate") > 0,
		"the one live publisher must swap the detached candidate by reference")
	Assert(InStr(Publisher, "FS") == 0 && InStr(Publisher, "File") == 0,
		"the live publication callback must remain memory-only inside Critical")
}
Test("tap-hold transaction meta: durable stage, authorization and publication stay ordered "
	. "(tap-hold-global-transaction-meta)",
	_THGTM_DurableWriterIsUniqueAuthorizedAndAtomic)





; ====================================
; ====================================
; ======= 3/ Reset and callers =======
; ====================================
; ====================================

_THGTM_ResetSharesBarrierAndGatesReload() {
	Body := _DriverFuncBody("_TH_ResetTapHoldConfig")
	Assert(Body != "", "_TH_ResetTapHoldConfig must remain source-visible")
	BoundPos := InStr(Body, "BoundPath := _TH_TapHoldConfigPath()")
	LeasePos := InStr(Body, "_ConfigWriteLeaseTryAcquire(BoundPath")
	AuthorizePos := InStr(Body, "_TH_AuthorizeTapHoldCommit(OwnerToken")
	DeletePos := InStr(Body, "FSDeleteStrict(BoundPath)")
	ReleasePos := InStr(Body, "_ConfigWriteLeaseRelease(OwnerToken)")
	ReloadPos := InStr(Body, "_TH_ReloadTapHoldMenu(")
	Assert(BoundPos > 0 && LeasePos > BoundPos
		&& AuthorizePos > LeasePos && DeletePos > AuthorizePos
		&& ReleasePos > DeletePos && ReloadPos > ReleasePos,
		"reset must own and authorize the exact path through strict delete, release it, then Reload")
	Assert(InStr(Body, "(Deleted is Integer)") > 0
		&& InStr(Body, "Deleted == 1") > 0,
		"reset must accept only the strict Integer 1 delete result")
	Assert(InStr(Body, "FileDelete(") == 0,
		"reset must not bypass the strict filesystem adapter")

	DisableAll := _DriverFuncBody("_TH_DisableAll")
	ApplyTap := _DriverFuncBody("_TH_ApplyTap")
	Assert(DisableAll != "" && ApplyTap != "",
		"tap-hold menu mutation entry points must remain source-visible")
	Assert(InStr(DisableAll, "if !_TH_WriteTapHoldDisabled()") > 0,
		"disable-all must not Reload after a refused writer")
	Assert(InStr(ApplyTap, "if !WriteTapHoldTap(KeyId, ActionId)") > 0,
		"tap selection must not Reload after a refused writer")
	ReloadBody := _DriverFuncBody("_TH_ReloadTapHoldMenu")
	Assert(ReloadBody != "" && InStr(ReloadBody, "A_IsCritical") > 0
		&& InStr(ReloadBody, 'Critical("Off")') > 0,
		"the post-commit Reload boundary must also defuse inherited Critical")
}
Test("tap-hold transaction meta: reset and menu callers gate destructive effects "
	. "(tap-hold-global-transaction-meta)",
	_THGTM_ResetSharesBarrierAndGatesReload)
