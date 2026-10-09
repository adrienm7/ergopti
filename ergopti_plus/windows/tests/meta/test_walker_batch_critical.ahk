; tests/meta/test_walker_batch_critical.ahk

; ==============================================================================
; MODULE: KLW.batch Torn-Accumulator Meta-Test
; DESCRIPTION:
; Structural regression for the torn-batch fix in the keylogger walker paths.
;
; Before the fix, the walker loop that accumulates into KLW.batch ran without
; any preemption guard. The live-push debounce timer fires on its own AHK
; thread and calls KLW_ResetBatch(), which replaces the entire KLW.batch Map
; with a fresh empty one mid-walk. Any entries already accumulated by the
; for-loop up to that point were silently lost, producing incomplete UPSERT
; data for n-gram, burst, and session aggregates.
;
; GUARANTEE (what this file actually protects):
; KLW.batch must never be mutated while another thread can swap it out from
; under the mutation. The ORIGINAL assertions pinned the one mechanism that
; delivered that guarantee at the time — a Critical("On") / finally
; { Critical(_crit_walk) } transaction around a walk loop inside KL_IngestOnce.
; KL_IngestOnce no longer walks at all (KLW.batch has no consumer in the
; foreground process; the projection runs in the detached prefetch worker), so
; a mechanism-shaped assertion would now pin a call site that must not come
; back rather than the property that matters. The assertions below therefore
; state the guarantee itself: IF the ingest tick walks, every walker call must
; sit strictly inside a Critical save/restore transaction. Nothing was removed
; or relaxed — a re-added unguarded walk still fails here exactly as before.
;
; The unconditional half of the guarantee moved with the work: the surviving
; site that swaps KLW.batch is KLR_RebuildWalkerAggregates, and section 3
; pins its save/restore.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===========================================================
; ===========================================================
; ======= 1/ Source-inspection helpers ======================
; ===========================================================
; ===========================================================

; Symbol-keyed source lookup keeps this guard coupled to the actual ingest
; function rather than a nearby implementation detail whose position can move.
_WBCR_ReadSource() {
	return _DriverFuncBody("KL_IngestOnce")
}


; Derive the walker entry points from the driver source instead of naming
; today's four. A future KLW_WalkSomethingNew is then covered the day it is
; written, which is this repo's dominant failure mode (invariant fixed at one
; site, one sibling forgotten).
_WBCR_WalkerEntryPoints() {
	Src := _DriverSourceNoComments()
	Names := []
	Pos := 1
	while (Pos := RegExMatch(Src, "m)^(KLW_Walk\w+)\(", &m, Pos)) {
		Names.Push(m[1])
		Pos += m.Len
	}
	return Names
}




; ===========================================================
; ===========================================================
; ======= 2/ Assertions =====================================
; ===========================================================
; ===========================================================

_WBCR_CriticalOnPresent() {
	Body := _WBCR_ReadSource()
	Assert(Body != "", "KL_IngestOnce must exist in the driver source")
	Walkers := _WBCR_WalkerEntryPoints()
	Assert(Walkers.Length > 0,
		"prerequisite: the KLW_Walk* entry points must still exist — with none found this guard would silently check nothing")
	for _, Name in Walkers {
		if (InStr(Body, Name . "(") = 0)
			continue
		Assert(InStr(Body, '_crit_walk := Critical("On")') > 0,
			"keylogger.ahk: KL_IngestOnce calls " . Name . ", so it mutates KLW.batch on the ingest thread and must open a Critical('On') transaction first — the live-push debounce timer runs on its own AHK thread and calls KLW_ResetBatch(), replacing the whole Map mid-walk")
	}
}
Test("KLW.batch walk: Critical('On') guard present in ingest block (walker-batch-critical)", _WBCR_CriticalOnPresent)


_WBCR_FinallyWithCriticalRestore() {
	Body := _WBCR_ReadSource()
	Assert(Body != "", "KL_IngestOnce must exist in the driver source")
	for _, Name in _WBCR_WalkerEntryPoints() {
		if (InStr(Body, Name . "(") = 0)
			continue
		Assert(InStr(Body, "finally") > 0,
			"keylogger.ahk: the walk-loop Critical guard must use a finally block for safe restore")
		Assert(InStr(Body, "Critical(_crit_walk)") > 0,
			"keylogger.ahk: finally block must restore prior Critical state via Critical(_crit_walk)")
	}
}
Test("KLW.batch walk: finally { Critical(_crit_walk) } restore present (walker-batch-critical)", _WBCR_FinallyWithCriticalRestore)


_WBCR_CriticalBeforeForLoop() {
	Body := _WBCR_ReadSource()
	Assert(Body != "", "KL_IngestOnce must exist in the driver source")
	for _, Name in _WBCR_WalkerEntryPoints() {
		CallPos := InStr(Body, Name . "(")
		if (CallPos = 0)
			continue
		CritPos    := InStr(Body, '_crit_walk := Critical("On")')
		RestorePos := InStr(Body, "Critical(_crit_walk)")
		Assert(CritPos > 0 and CritPos < CallPos,
			"keylogger.ahk: the Critical guard must be opened before " . Name . " — a walk that starts outside the transaction can be torn by KLW_ResetBatch on the live-push timer thread")
		Assert(RestorePos > CallPos,
			"keylogger.ahk: " . Name . " must sit strictly inside the _crit_walk transaction, before Critical(_crit_walk) restores the caller's state")
	}
}
Test("KLW.batch walk: Critical guard precedes for-loop over entries (walker-batch-critical)", _WBCR_CriticalBeforeForLoop)




; ===========================================================
; ===========================================================
; ======= 3/ The surviving KLW.batch swap ===================
; ===========================================================
; ===========================================================

; KLR_RebuildWalkerAggregates replaces KLW.batch wholesale so the cold replay
; gets a fresh accumulator, then restores the live one. If that restore is not
; in a finally, an SQL failure mid-replay leaves the process running on the
; replay's accumulator — the same torn-batch class of bug, one file over.
_WBCR_ReplayRestoresBatchInFinally() {
	Body := _DriverFuncBody("KLR_RebuildWalkerAggregates")
	Assert(Body != "", "KLR_RebuildWalkerAggregates must exist in the driver source")
	SavePos    := InStr(Body, "saved_batch := KLW.batch")
	FinallyPos := InStr(Body, "finally")
	RestorePos := InStr(Body, "KLW.batch := saved_batch")
	Assert(SavePos > 0,
		"KLR_RebuildWalkerAggregates must snapshot the live KLW.batch before replaying with a fresh one")
	Assert(FinallyPos > SavePos and RestorePos > FinallyPos,
		"KLR_RebuildWalkerAggregates must restore KLW.batch from a finally — a throw or an SQL failure mid-replay would otherwise leave the process accumulating into the replay's throwaway batch")
}
Test("KLW.batch: the cold replay restores the live accumulator in a finally (walker-batch-critical)",
	_WBCR_ReplayRestoresBatchInFinally)
