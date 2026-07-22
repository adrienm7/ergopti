; tests/meta/test_ingest_failure_requeues.ahk

; ==============================================================================
; MODULE: Keylogger Ingest Failure Re-queue Meta Test
; DESCRIPTION:
; Regression guard for HIGH-04 plus the durable-JSONL duplicate retry case.
;
; KL_IngestOnce atomically snapshots and clears _pending_entries under Critical
; (lines 1349-1352 of keylogger.ahk) before the heavy SQL conversion and
; data.sql FileAppend. If FileAppend fails, the catch block used to log and
; return without re-queuing pending_snapshot onto _pending_entries.
;
; The original recovery put the ENTIRE pending snapshot back in RAM. But the
; snapshot had already been appended to today.log before data.sql failed; the
; unchanged offset then read those JSONL lines AND the re-queued copy, doubling
; the next aggregate batch. The fix tracks the number of completed JSONL lines
; and re-queues only the unwritten tail. Today_log_offset remains unchanged so
; completed lines are retried exactly once from disk.
;
; This test asserts:
;   (a) The re-queue (InsertAt) appears inside the FileAppend catch block.
;   (b) It starts after pending_logged_count, not at the already logged head.
;   (c) The re-queue is wrapped in Critical("On") / Critical("Off").
;   (d) today_log_offset is NOT advanced inside the catch block.
;
; SCOPE: source introspection of modules/keylogger/keylogger.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================================
; =====================================================
; ======= 1/ Source scan helpers ======================
; =====================================================
; =====================================================

; Extracts the body of the FileAppend catch block inside KL_IngestOnce.
; Returns the substring from the catch opening brace to the matching close.
_IFR_ExtractCatchBody(Src) {
	; Locate the FileAppend line on data_sql_path.
	FAPos := InStr(Src, "FileAppend(body, Keylogger.data_sql_path")
	if (!FAPos)
		return ""
	; Find the catch keyword after the FileAppend.
	CatchPos := InStr(Src, "catch as err {", , FAPos)
	if (!CatchPos)
		return ""
	; Walk forward to find the matching closing brace.
	depth := 0
	i := CatchPos
	Len := StrLen(Src)
	while (i <= Len) {
		ch := SubStr(Src, i, 1)
		if (ch == "{")
			depth++
		else if (ch == "}") {
			depth--
			if (depth <= 0)
				return SubStr(Src, CatchPos, i - CatchPos + 1)
		}
		i++
	}
	return SubStr(Src, CatchPos)
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_IFR_CheckRequeueOnFailure() {
	Src := _DriverDirConcat("modules/keylogger")

	CatchBody := _IFR_ExtractCatchBody(Src)
	Assert(CatchBody != "",
		"FileAppend catch block on data_sql_path must be present in KL_IngestOnce")

	; (a) Re-queue via InsertAt must be present in the catch block.
	Assert(InStr(CatchBody, "InsertAt"),
		"FileAppend catch block must re-queue pending_snapshot via InsertAt (HIGH-04 fix-ingest-failure-requeues-pending)")

	; The re-queue must reference pending_snapshot entries.
	Assert(InStr(CatchBody, "pending_snapshot"),
		"FileAppend catch block must reference pending_snapshot to re-queue the consumed entries")
	Assert(InStr(CatchBody, "pending_logged_count"),
		"FileAppend catch must distinguish JSONL-backed entries from the unwritten pending tail")
	Assert(InStr(CatchBody, "snapshot_index := pending_logged_count + A_Index"),
		"FileAppend catch must re-queue only entries that never reached today.log")

	; (b) The re-queue must be wrapped in Critical to prevent a concurrent Push
	;     from the keystroke hook from interleaving with the InsertAt.
	Assert(InStr(CatchBody, 'Critical("On")'),
		'FileAppend catch block must wrap the re-queue in Critical("On")')
	Assert(InStr(CatchBody, "Critical(previous_critical)") > 0,
		"FileAppend catch block must restore the caller Critical state after re-queueing")

	; (c) today_log_offset must NOT be advanced in the catch block
	;     (the next tick must retry the same chunk).
	Assert(!InStr(CatchBody, "today_log_offset :="),
		"FileAppend catch block must NOT advance today_log_offset — next tick must retry the same chunk")
}


Test("meta fix-ingest-failure-requeues-pending: FileAppend catch re-queues only the pending tail not already durable in today.log",
	_IFR_CheckRequeueOnFailure)


; The same HIGH-04 transaction must cover the OTHER destructive-after-clear
; call: opening today.log. FileOpen throws OSError in AHK v2 — it never returns
; a falsy handle — so a bare `fh := KL_OpenTodayFh()` aborted the timer thread
; after _pending_entries had already been snapshot-and-cleared, discarding the
; local snapshot with no requeue and no offset rollback. Unlike the data.sql
; path there is no disk copy to fall back on: KL_AppendLog pushes to
; _pending_entries only, so the snapshot is the sole copy of those keystrokes.
;
; Scans the concatenated module source, matching the helper this file already
; uses, rather than resolving one function body.
_IFR_TodayLogOpenRequeues() {
	Src := _DriverDirConcat("modules/keylogger")

	OpenPos := InStr(Src, "fh := KL_OpenTodayFh()")
	Assert(OpenPos > 0, "KL_IngestOnce must still open today.log via KL_OpenTodayFh()")

	; Bounded windows on both sides: only the statements immediately around the
	; call can establish that it is inside a try with a recovering catch.
	HeadStart := (OpenPos > 120) ? OpenPos - 120 : 1
	Head := SubStr(Src, HeadStart, OpenPos - HeadStart)
	Assert(InStr(Head, "try {") > 0,
		"KL_IngestOnce must open today.log inside a try - FileOpen throws OSError in v2 and would otherwise abort the tick after _pending_entries was already cleared")

	CatchWindow := SubStr(Src, OpenPos, 1000)
	Assert(InStr(CatchWindow, "catch as err") > 0,
		"the today.log open must have an explicit catch")
	Assert(InStr(CatchWindow, "InsertAt") > 0,
		"the today.log open failure must re-queue the pending snapshot onto _pending_entries")
	Assert(InStr(CatchWindow, "pending_snapshot") > 0,
		"the re-queue must restore pending_snapshot, the only copy of those entries")
	Assert(InStr(CatchWindow, "today_log_open_failed") > 0,
		"the failure must return a distinct reason so the caller can tell it from a data.sql failure")
}
Test("meta ingest: a failed today.log open re-queues the whole pending snapshot",
	_IFR_TodayLogOpenRequeues)
