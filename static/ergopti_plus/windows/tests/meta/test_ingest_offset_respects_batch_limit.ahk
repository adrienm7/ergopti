; tests/meta/test_ingest_offset_respects_batch_limit.ahk

; ==============================================================================
; MODULE: Ingest Batch-Limit Regression (ingest-offset-ignores-batch-limit)
; DESCRIPTION:
; new_offset carried two different meanings inside KL_IngestOnce. Out of
; KL_ReadNewTodayLog it means "how far the READER got", deliberately bounded by
; INGEST_BATCH_LINES so a large backlog drains over several ticks. The
; pending-entries drain then reused the same variable for "where the WRITER
; ended up", which is always EOF, and assigned it unconditionally. Whenever the
; reader had stopped short, every line between the batch cut and the old EOF
; ended up behind the committed offset and was never read again -- and if that
; happened inside KL_DayRollover's drain loop, the rollover then FileDelete()d
; today.log and destroyed them. KL_IngestOnce returned ok:true throughout, so
; the hole was indistinguishable from a clean drain.
;
; ROOT CAUSE ENCODED: the RAM queue may only be drained -- and the writer's
; position may only become the commit point -- once the reader has reached EOF.
; Publishing the reader's bookmark instead would have been just as wrong: the
; lines just appended would be read back on a later tick and inserted a second
; time under a freshly allocated event id.
;
; Meta-static because the headless harness does not load
; modules/keylogger/keylogger.ahk (it registers live hooks at load time), so
; KL_IngestOnce cannot be driven against a synthetic today.log from here.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================================
; ====================================================
; ======= 1/ The reader is bounded and says so =======
; ====================================================
; ====================================================

; Prerequisite half: if the reader ever stopped capping its passes, or stopped
; reporting whether it reached the end, the gate below would be vacuous.
_IOBL_ReaderIsBoundedAndReportsEof() {
	Body := _DriverFuncBody("KL_ReadNewTodayLog")
	Assert(Body != "", "KL_ReadNewTodayLog must exist")
	Assert(InStr(Body, "KeylogConst.INGEST_BATCH_LINES") > 0,
		"prerequisite: the reader still caps each pass at INGEST_BATCH_LINES, which is what "
		. "makes its returned offset a MID-FILE bookmark rather than EOF")
	Assert(InStr(Body, "fh.AtEOF") > 0,
		"prerequisite: the reader still reports whether it reached the end of today.log -- "
		. "that flag is the only signal the ingest tick can gate on")
}

Test("keylogger: the today.log reader is batch-bounded and reports EOF (ingest-offset-ignores-batch-limit)",
	_IOBL_ReaderIsBoundedAndReportsEof)





; ========================================================
; ========================================================
; ======= 2/ The commit point is gated on that EOF =======
; ========================================================
; ========================================================

_IOBL_DrainAndCommitAreGatedOnReaderEof() {
	Body := _DriverFuncBody("KL_IngestOnce")
	Assert(Body != "", "KL_IngestOnce must exist")

	DrainPos := InStr(Body, "_pending_entries := []")
	Assert(DrainPos > 0,
		"prerequisite: KL_IngestOnce still snapshots and clears the RAM queue")
	PosPos := InStr(Body, "new_offset := fh.Pos")
	Assert(PosPos > 0,
		"prerequisite: KL_IngestOnce still publishes the append handle's position")

	GatePos := InStr(Body, "if source_eof")
	Assert(GatePos > 0,
		"KL_IngestOnce must consult source_eof -- KL_ReadNewTodayLog hands it back precisely "
		. "so the tick can tell a mid-file bookmark from a caught-up one, and it was captured "
		. "and then never read")
	Assert(GatePos < DrainPos,
		"the pending-entries drain must sit INSIDE the source_eof gate. Draining while a "
		. "backlog remains forces a choice between two silent corruptions: commit the writer's "
		. "position and every unread line is skipped for good (KL_DayRollover then deletes "
		. "today.log), or commit the reader's bookmark and the lines just appended are read "
		. "back and inserted twice under a new event id")
	Assert(GatePos < PosPos,
		"and 'new_offset := fh.Pos' must be reachable only from inside that gate -- the "
		. "writer's position is a valid commit point only when the reader agrees it is EOF")
}

Test("keylogger: the ingest drain and offset commit are gated on the reader reaching EOF (ingest-offset-ignores-batch-limit)",
	_IOBL_DrainAndCommitAreGatedOnReaderEof)





; =========================================================
; =========================================================
; ======= 3/ Skipped lines would still be destroyed =======
; =========================================================
; =========================================================

; The consequence that turns a skip into permanent loss must stay visible: the
; rollover drains to EOF and then deletes the file. If that ever stopped being
; true the gate above would still be right, but the reason recorded here would
; have rotted -- so pin it.
_IOBL_RolloverStillDeletesAfterDraining() {
	Body := _DriverFuncBody("KL_DayRollover")
	Assert(Body != "", "KL_DayRollover must exist")
	Assert(InStr(Body, "KL_IngestOnce(true, true)") > 0,
		"prerequisite: the rollover still forces the ingest to drain today.log to EOF")
	Assert(InStr(Body, "FileDelete(Keylogger.today_log_path)") > 0,
		"prerequisite: the rollover still deletes today.log afterwards -- that is what turns "
		. "a skipped batch into unrecoverable loss rather than a delayed read")
}

Test("keylogger: the rollover still deletes today.log after draining it (ingest-offset-ignores-batch-limit)",
	_IOBL_RolloverStillDeletesAfterDraining)
