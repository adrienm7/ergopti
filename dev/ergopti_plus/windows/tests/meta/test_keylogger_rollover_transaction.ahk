; tests/meta/test_keylogger_rollover_transaction.ahk

; ==============================================================================
; MODULE: Keylogger rollover transaction regression tests
; DESCRIPTION:
; Lock the two data-loss causes fixed by the transactional rollover protocol:
; (1) an ingest tick must never reset date/offset before the rollover owner
;     drains yesterday's log; and
; (2) rotation must not delete today.log until every bounded batch committed
;     SQL plus state and the reader reported EOF.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRTR_Body(Name) {
    Body := _DriverFuncBody(Name)
    Assert(Body != "", Name . "() must exist")
    return Body
}

_KLRTR_ReadDoesNotOwnEpoch() {
    Body := _KLRTR_Body("KL_ReadNewTodayLog")

    Assert(!RegExMatch(Body, "Keylogger\.today_log_date\s*:="),
        "KL_ReadNewTodayLog must not advance today_log_date — only KL_DayRollover owns the date transition")
    Assert(!RegExMatch(Body, "Keylogger\.today_log_offset\s*:="),
        "KL_ReadNewTodayLog must not reset/advance today_log_offset — its result must be committed by the ingest transaction")
    Assert(InStr(Body, '"ok"') > 0 && InStr(Body, '"eof"') > 0,
        "KL_ReadNewTodayLog must return explicit ok/eof evidence so rollover cannot confuse a read failure with an empty file")
}

Test("meta keylogger rollover: reader cannot steal date/offset ownership",
    _KLRTR_ReadDoesNotOwnEpoch)

_KLRTR_IngestRoutesMidnightToRollover() {
    Body := _KLRTR_Body("KL_IngestOnce")
    MismatchPos := InStr(Body, "today_log_date != KL_Today()")
    ReadPos := InStr(Body, "KL_ReadNewTodayLog()")
    RoutePos := InStr(Body, "return KL_DayRollover()")

    Assert(MismatchPos > 0 && RoutePos > MismatchPos,
        "KL_IngestOnce must route a date mismatch to KL_DayRollover instead of resetting its epoch inline")
    Assert(ReadPos > RoutePos,
        "KL_IngestOnce must hand midnight ownership to KL_DayRollover before reading today.log")
    Assert(InStr(Body, "rollover_owned := false") > 0,
        "KL_IngestOnce must expose an explicit rollover-owned path so KL_DayRollover can drain yesterday without recursion")
}

Test("meta keylogger rollover: ingest-before-midnight-timer starts one owned rollover",
    _KLRTR_IngestRoutesMidnightToRollover)

_KLRTR_DeleteRequiresCommittedEOF() {
    Body := _KLRTR_Body("KL_DayRollover")
    IngestPos := InStr(Body, "KL_IngestOnce(true, true)")
    OkPos := InStr(Body, 'if !ingest_result["ok"]')
    EofPos := InStr(Body, 'if ingest_result["eof"]')
    DeletePos := InStr(Body, "FileDelete(Keylogger.today_log_path)")

    Assert(IngestPos > 0 && OkPos > IngestPos && EofPos > OkPos,
        "KL_DayRollover must loop over forced batches and reject failed commits before accepting EOF")
    Assert(DeletePos > EofPos,
        "KL_DayRollover must reach FileDelete only after a successful ingest reported EOF")
    Assert(InStr(Body, "loop {") > 0,
        "KL_DayRollover must drain more than one INGEST_BATCH_LINES chunk before deletion")
    Assert(InStr(Body, "if !KL_SaveState()", false, DeletePos) > 0,
        "KL_DayRollover must durably publish the new date/offset after deletion and reject a failed state commit")
    Assert(InStr(Body, "rollover_in_progress") > 0,
        "KL_DayRollover must own a reentrancy latch while draining and rotating")
}

Test("meta keylogger rollover: no delete before complete durable ingest",
    _KLRTR_DeleteRequiresCommittedEOF)
