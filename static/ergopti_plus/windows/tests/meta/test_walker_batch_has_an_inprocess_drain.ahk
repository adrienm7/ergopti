; tests/meta/test_walker_batch_has_an_inprocess_drain.ahk

; ==============================================================================
; MODULE: KLW.batch In-Process Drain Guard (walker-batch-write-only)
; DESCRIPTION:
; Regression for a write-only accumulator: the foreground driver walked every
; ingested entry into KLW.batch, but nothing in that process ever read it back.
;
; ROOT CAUSE ENCODED: an accumulator must have a consumer in the SAME process.
; KLW.batch has exactly one reader, KLW_BuildBatchSql. That function is called
; only from KLR_ReplayFlush and KLR_InjectKlwBatch, both reachable only through
; KLR_BuildDatabase, which in turn is only ever entered from KLPF_WorkerMain —
; the detached `--keylogger-prefetch-worker` instance spawned by
; KLPF_RequestBuild. That worker starts with an empty KLW.batch, so the batch
; the foreground built was never the batch anyone drained.
;
; The cost was not theoretical: KLW_WalkTypingEntry pushes seven n-gram maps per
; keystroke, and quadgrams and longer are near-unique, so roughly four new Map
; entries per keystroke accumulated. Only KLW_ResetBatch at init and
; KLW_DayRolloverReset at midnight ever cleared it — tens of MB retained for a
; whole day and then discarded unread, with the walk itself paid under
; Critical on every ingest tick.
;
; SCOPE: source introspection. KL_IngestOnce reads Keylogger state and touches
; disk, so it is not callable from the headless harness; the reachability chain
; this encodes is a source property anyway.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================================================
; =====================================================================
; ======= 1/ The drain exists, and it lives in the worker =============
; =====================================================================
; =====================================================================

; Both halves of the premise are asserted before the conclusion, so this guard
; fails loudly if the architecture is rearranged rather than passing vacuously.
_WBID_DrainRunsInTheDetachedWorker() {
	Src := _DriverSourceNoComments()
	Assert(InStr(Src, "KLW_BuildBatchSql") > 0,
		"prerequisite: KLW.batch's only drain, KLW_BuildBatchSql, must still exist")

	Worker := _DriverFuncBody("KLPF_WorkerMain")
	Assert(Worker != "", "prerequisite: KLPF_WorkerMain must exist")
	Assert(InStr(Worker, "KLPF_BuildAndWriteToPath") > 0 or InStr(Worker, "KLR_BuildDatabase") > 0,
		"prerequisite: the aggregate projection must still run inside the detached prefetch worker")

	Inject := _DriverFuncBody("KLR_InjectKlwBatch")
	Assert(Inject != "" and InStr(Inject, "KLW_BuildBatchSql") > 0,
		"prerequisite: KLR_InjectKlwBatch must still be the drain's call site")
}
Test("walker batch: the KLW.batch drain runs in the detached prefetch worker (walker-batch-write-only)",
	_WBID_DrainRunsInTheDetachedWorker)





; =====================================================================
; =====================================================================
; ======= 2/ No producer without a consumer in the same process =======
; =====================================================================
; =====================================================================

; Derived from source rather than from today's four walker names, so a future
; KLW_WalkSomethingNew is covered the day it is written.
_WBID_WalkerEntryPoints() {
	Src := _DriverSourceNoComments()
	Names := []
	Pos := 1
	while (Pos := RegExMatch(Src, "m)^(KLW_Walk\w+)\(", &m, Pos)) {
		Names.Push(m[1])
		Pos += m.Len
	}
	return Names
}

_WBID_IngestDoesNotFeedAnOrphanBatch() {
	Body := _DriverFuncBody("KL_IngestOnce")
	Assert(Body != "", "KL_IngestOnce must exist in the driver source")
	Walkers := _WBID_WalkerEntryPoints()
	Assert(Walkers.Length > 0,
		"prerequisite: the KLW_Walk* entry points must still exist — with none found this guard would check nothing")

	Drains := (InStr(Body, "KLW_BuildBatchSql") > 0 or InStr(Body, "KLR_InjectKlwBatch") > 0)
	for _, Name in Walkers {
		Assert(InStr(Body, Name . "(") = 0 or Drains,
			"KL_IngestOnce must not populate KLW.batch via " . Name . " unless the same process also drains it. KLW_BuildBatchSql is reachable only from KLPF_WorkerMain — a detached /force process whose KLW.batch is always empty — so every n-gram Map the foreground walker builds is retained until midnight and then discarded unread (walker-batch-write-only)")
	}
}
Test("walker batch: the ingest tick never feeds an accumulator it cannot drain (walker-batch-write-only)",
	_WBID_IngestDoesNotFeedAnOrphanBatch)





; ======================================================================
; ======================================================================
; ======= 3/ The out-of-process rebuild is still the replacement =======
; ======================================================================
; ======================================================================

; Dropping the foreground walk is only safe because the worker replays every
; walker-owned aggregate from the durable events_* rows. If that replay ever
; disappeared, the dashboard would lose WPM, n-grams, corrections and ergonomic
; details with no in-process fallback left to notice it.
_WBID_WorkerRebuildsWalkerAggregates() {
	Body := _DriverFuncBody("KLR_RebuildWalkerAggregates")
	Assert(Body != "", "KLR_RebuildWalkerAggregates must exist — it is the sole producer of the walker-owned aggregates now that the ingest tick no longer walks")
	Assert(InStr(Body, "FROM events_typing") > 0,
		"the cold replay must still select every durable typing row")
	Assert(InStr(Body, "KLR_ReplayLogicalRow") > 0,
		"KLR_RebuildWalkerAggregates must route the merged typing/accepted stream through its logical-order dispatcher")
	LogicalReplay := _DriverFuncBody("KLR_ReplayLogicalRow")
	Assert(LogicalReplay != "" and InStr(LogicalReplay, "KLR_ReplayTypingRow") > 0,
		"the logical-order dispatcher must still route ordinary events_typing rows to the typing replay")
	Replay := _DriverFuncBody("KLR_ReplayTypingRow")
	Assert(Replay != "" and InStr(Replay, "KLW_WalkTypingEntry") > 0,
		"the replay must still feed KLW_WalkTypingEntry, otherwise no process produces the n-gram aggregates at all")
}
Test("walker batch: the detached worker still rebuilds the walker aggregates (walker-batch-write-only)",
	_WBID_WorkerRebuildsWalkerAggregates)
