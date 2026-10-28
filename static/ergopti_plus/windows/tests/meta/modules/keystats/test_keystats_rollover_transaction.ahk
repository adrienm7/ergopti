; tests/meta/modules/keystats/test_keystats_rollover_transaction.ahk

; ==============================================================================
; MODULE: Keystats rollover transaction regression tests
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
	AdmissionBody := _KLRTR_Body("_KL_ReadJournalEvents")
	JournalBody := _KLRTR_Body("_KL_JournalReadLines")

	for ReaderBody in [Body, AdmissionBody, JournalBody] {
		Assert(!RegExMatch(ReaderBody, "Keystats\.today_log_date\s*:="),
			"only KL_DayRollover owns the date transition, including through reader delegates")
		Assert(!RegExMatch(ReaderBody, "Keystats\.today_log_offset\s*:="),
			"the ingest transaction owns the committed offset, including through reader delegates")
	}
	Assert(InStr(Body, "_KL_ReadJournalEvents(") > 0
		&& InStr(AdmissionBody, "_KL_JournalReadLines(") > 0
		&& InStr(AdmissionBody, "return Read") > 0
		&& InStr(JournalBody, '"ok"') > 0 && InStr(JournalBody, '"eof"') > 0,
		"the actual admission and framing owners must retain explicit ok/eof evidence")
}

Test("meta keystats rollover: reader cannot steal date/offset ownership",
    _KLRTR_ReadDoesNotOwnEpoch)

_KLRTR_IngestRoutesMidnightToRollover() {
    Body := _KLRTR_Body("KL_IngestOnce")
    MismatchPos := InStr(Body, "today_log_date != KL_Today()")
    ReadPos := InStr(Body, "KL_ReadNewTodayLog(Scope.Token)")
    RoutePos := InStr(Body, "return KL_DayRollover(Scope.Token)")

    Assert(MismatchPos > 0 && RoutePos > MismatchPos,
        "KL_IngestOnce must route a date mismatch to KL_DayRollover instead of resetting its epoch inline")
    Assert(ReadPos > RoutePos,
        "KL_IngestOnce must hand midnight ownership to KL_DayRollover before reading today.log")
    Assert(InStr(Body, "rollover_owned := false") > 0,
        "KL_IngestOnce must expose an explicit rollover-owned path so KL_DayRollover can drain yesterday without recursion")
}

Test("meta keystats rollover: ingest-before-midnight-timer starts one owned rollover",
    _KLRTR_IngestRoutesMidnightToRollover)

_KLRTR_DeleteRequiresCommittedEOF() {
    Body := _KLRTR_Body("KL_DayRollover")
    IngestPos := InStr(Body, "KL_IngestOnce(true, true, Scope.Token)")
    OkPos := InStr(Body, 'if !ingest_result["ok"]')
    EofPos := InStr(Body, 'if ingest_result["eof"]')
    Prepare := _KLRTR_Body("_KL_RolloverPrepare")
    Resume := _KLRTR_Body("_KL_RolloverResume")
    PreparePos := InStr(Body, "_KL_RolloverPrepare(Scope.Token, new_date)")
    ResumePos := InStr(Body, "_KL_RolloverResume(Scope.Token)")
    DeletePos := InStr(Resume, "FileDelete(Keystats.today_log_path)")

    Assert(IngestPos > 0 && OkPos > IngestPos && EofPos > OkPos,
        "KL_DayRollover must loop over forced batches and reject failed commits before accepting EOF")
    Assert(PreparePos > EofPos && ResumePos > PreparePos,
        "rotation must durably prepare consumed EOF before entering the deletion helper")
    Assert(InStr(Prepare, "Keystats.rollover_pending := Receipt") > 0
        && InStr(Prepare, "if !KL_SaveState()") > InStr(Prepare, "Keystats.rollover_pending := Receipt"),
        "the pending consumed-file proof must be durably saved before preparation succeeds")
    Assert(InStr(Resume, "_KL_RolloverReceiptValid(") > 0
        && DeletePos > InStr(Resume, "_KL_RolloverReceiptValid("),
        "resumed deletion must validate the persisted consumed-file proof")
    Assert(InStr(Body, "loop {") > 0,
        "KL_DayRollover must drain more than one INGEST_BATCH_LINES chunk before deletion")
    Assert(DeletePos > 0 && InStr(Resume, "Published := KL_SaveState()") > DeletePos
        && InStr(Resume, "if !Published") > InStr(Resume, "Published := KL_SaveState()"),
        "the final date/offset must be saved after deletion and refusal must retain recovery state")
    Assert(InStr(Body, "rollover_in_progress") > 0,
        "KL_DayRollover must own a reentrancy latch while draining and rotating")
}

Test("meta keystats rollover: no delete before complete durable ingest",
    _KLRTR_DeleteRequiresCommittedEOF)


_KLRTR_ReaderEvidence(Spec) {
	Path := _FSWL_Path()
	Owned := false
	HadDate := Keystats.HasOwnProp("today_log_date")
	HadOffset := Keystats.HasOwnProp("today_log_offset")
	SavedDate := HadDate ? Keystats.today_log_date : ""
	SavedOffset := HadOffset ? Keystats.today_log_offset : 0
	try {
		AssertFalse(FileExist(Path))
		AssertTrue(FSWriteCreateDurable(Path, Spec.Source))
		Owned := true
		Keystats.today_log_date := "rollover-owned-date"
		Keystats.today_log_offset := 37
		Result := _KL_ReadJournalEvents(Path, 0, 10)
		AssertEqual(Spec.Ok, Result["ok"])
		AssertEqual(Spec.Eof, Result["eof"], "a refused record must never authorize rollover EOF")
		AssertEqual(Spec.Entries, Result["entries"].Length)
		AssertEqual(Spec.Ok ? FileGetSize(Path) : 0, Result["offset"])
		AssertEqual("rollover-owned-date", Keystats.today_log_date)
		AssertEqual(37, Keystats.today_log_offset)
		AssertEqual(Spec.Source, FSReadUtf8Exact(Path))
	} finally {
		if HadDate
			Keystats.today_log_date := SavedDate
		else if Keystats.HasOwnProp("today_log_date")
			Keystats.DeleteProp("today_log_date")
		if HadOffset
			Keystats.today_log_offset := SavedOffset
		else if Keystats.HasOwnProp("today_log_offset")
			Keystats.DeleteProp("today_log_offset")
		if Owned && FileExist(Path)
			FileDelete(Path)
	}
}

for _KLRTR_ReaderSpec in [
	{Name: "empty", Source: "", Ok: true, Eof: true, Entries: 0},
	{Name: "numeric", Source: '{"type":"mouse_click","_event_id":2}' . "`n", Ok: true, Eof: true, Entries: 1},
	{Name: "refused", Source: '{"type":"mouse_click","_event_id":true}' . "`n", Ok: false, Eof: false, Entries: 0}
]
	Test("meta keystats rollover: actual " . _KLRTR_ReaderSpec.Name . " reader evidence preserves epoch (rollover-reader-evidence)",
		_KLRTR_ReaderEvidence.Bind(_KLRTR_ReaderSpec))
