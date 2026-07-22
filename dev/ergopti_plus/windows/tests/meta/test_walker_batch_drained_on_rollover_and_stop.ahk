; tests/meta/test_walker_batch_drained_on_rollover_and_stop.ahk

; ==============================================================================
; MODULE: Walker Batch Drain on Rollover and Stop Meta Test
; DESCRIPTION:
; Regression guard ensuring the keylogger walker drains / resets its per-tick
; batch accumulator at the two critical lifecycle events: day rollover and
; ingest-tick end.
;
; Without a KLW_ResetBatch() call at the end of KLW_BuildBatchSql, batch data
; from one tick would bleed into the next (additive UPSERT values would be
; doubled on every restart). Without KLW_ResetBatch() in KLW_DayRolloverReset,
; metrics from the previous day would contaminate the first batch of the new day
; before they were flushed to disk.
;
; This test asserts:
;   1. KLW_BuildBatchSql calls KLW_ResetBatch() before it returns, so no stale
;      batch data persists into the next tick.
;   2. KLW_DayRolloverReset calls KLW_ResetBatch() to clear accumulated batch
;      data when rolling over to a new calendar day.
;   3. KLW_DayRolloverReset also resets KLW.ctx so per-app walking context
;      (n-gram position, burst state) does not carry over across the day boundary.
;
; SCOPE: source introspection of modules/keylogger/keylogger_walker.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ====================================================
; ====================================================
; ======= 1/ Source scan helpers =====================
; ====================================================
; ====================================================

_WBDR_ReadSource() {
	return _DriverDirConcat("modules/keylogger")
}


; ===================================================
; ===================================================
; ======= 2/ Test implementations ===================
; ===================================================
; ===================================================

_WBDR_BuildBatchSqlCallsResetBatch() {
	Src := _WBDR_ReadSource()
	Assert(Src != "", "modules/keylogger/ source must be readable")

	Body := _DriverFuncBody("KLW_BuildBatchSql")
	Assert(Body != "", "KLW_BuildBatchSql must be defined in keylogger_walker.ahk")

	Assert(InStr(Body, "KLW_ResetBatch()") > 0,
		"KLW_BuildBatchSql must call KLW_ResetBatch() before returning — batch data that is not reset after flushing bleeds into the next ingest tick and produces duplicated UPSERT values")
}

Test("walker: KLW_BuildBatchSql resets the batch after emitting SQL (walker-batch-drained-on-rollover-and-stop)",
	_WBDR_BuildBatchSqlCallsResetBatch)


_WBDR_DayRolloverCallsResetBatch() {
	Src := _WBDR_ReadSource()
	Assert(Src != "", "modules/keylogger/ source must be readable")

	Body := _DriverFuncBody("KLW_DayRolloverReset")
	Assert(Body != "", "KLW_DayRolloverReset must be defined in keylogger_walker.ahk")

	Assert(InStr(Body, "KLW_ResetBatch()") > 0,
		"KLW_DayRolloverReset must call KLW_ResetBatch() — accumulated batch deltas from the old day must not contaminate the first flush of the new day")
}

Test("walker: KLW_DayRolloverReset resets the batch (walker-batch-drained-on-rollover-and-stop)",
	_WBDR_DayRolloverCallsResetBatch)


_WBDR_DayRolloverResetsCtx() {
	Body := _DriverFuncBody("KLW_DayRolloverReset")
	Assert(Body != "", "KLW_DayRolloverReset must be defined — prerequisite for this test")

	Assert(InStr(Body, "KLW.ctx") > 0 and (InStr(Body, "Map()") > 0),
		"KLW_DayRolloverReset must reset KLW.ctx to an empty Map() — per-app walking context (n-gram position, burst/session state) is day-scoped and must not carry over to the next day")
}

Test("walker: KLW_DayRolloverReset resets per-app walking context (walker-batch-drained-on-rollover-and-stop)",
	_WBDR_DayRolloverResetsCtx)
