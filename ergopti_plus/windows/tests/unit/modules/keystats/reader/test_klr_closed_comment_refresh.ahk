; tests/unit/modules/keystats/reader/test_klr_closed_comment_refresh.ahk

; ==============================================================================
; MODULE: Closed Comment Refresh Regression Tests
; DESCRIPTION: A complete raw event before closed trivia remains observable.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRTC_MouseBatch(Id, Detail) {
	Entry := Map("type", "mouse_click", "timestamp", "2026-03-04 11:00:00.000",
		"app", "fixture.exe", "detail", Detail)
	return KLRRebuildConst.BATCH_MARKER . "2026-03-04 11:00:00.000 (offset 0 -> 0, 1 entry(ies)) ===`n"
		. "BEGIN TRANSACTION;`n" . KL_BuildInsertMouseEvent(Entry, Id) . "`nCOMMIT;`n"
}

_KLRTC_ClosedCommentRefresh(WithComment) {
	PreviousDevice := Keystats.device_id
	PreviousLiteral := Keystats._device_id_lit
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Keystats.device_id := "dev-one"
		Keystats._device_id_lit := KL_SqlStr("dev-one")
		Root := _KLRDC_Root()
		_KLRDC_WriteLedger(_KLRDC_Header() . _KLRTC_MouseBatch(1, "previous-snapshot"))
		KLRCache.disposable := true
		Db := KLR_BuildDatabase(Root)
		AssertTrue(Db != 0, "the initial source must publish a real durable cache")
		AssertEqual(1, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_mouse;")[1]["n"])
		Suffix := WithComment ? "-- === day rollover 2026-03-04 -> 2026-03-05 ===`n" : ""
		_KLRDC_AppendLedger(_KLRTC_MouseBatch(2, "new-complete-event") . Suffix)
		SourceBefore := FileRead(_KLRDC_LedgerPath(), "UTF-8")
		KLR_ResetCache()
		KLRCache.disposable := true
		Db := KLR_BuildDatabase(Root)
		AssertTrue(Db != 0, "closed producer trivia cannot discard the newly completed native worker projection")
		AssertEqual(2, SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_mouse;")[1]["n"],
			"the complete event preceding a closed day-rollover comment must reach the refreshed image")
		AssertEqual(SourceBefore, FileRead(_KLRDC_LedgerPath(), "UTF-8"))
	} finally {
		_KLRDC_Cleanup()
		Keystats.device_id := PreviousDevice
		Keystats._device_id_lit := PreviousLiteral
	}
}
for _KLRTC_WithComment in [false, true]
	Test("KLR refresh: complete event with closed comment=" . _KLRTC_WithComment . " remains visible (klr-closed-comment-refresh)",
		_KLRDC_CheckTeardown.Bind(_KLRTC_ClosedCommentRefresh.Bind(_KLRTC_WithComment)))

_KLRTC_CommentCarry(Name, Suffix, Closed, Completion) {
	Db := _KLRCB_OpenFixture()
	try {
		Result := SQLite_ExecReturnCarry(Db, _KLRCB_Batch(11) . Suffix)
		AssertTrue(Result.Get("ok", false), "the real parser must accept the complete batch and its trivia")
		AssertEqual(1, _KLRCB_Ids(Db).Length, "the first native transaction must execute once")
		if Closed
			AssertEqual("", Result["carry"], "closed native-parser trivia cannot masquerade as an interrupted statement: " . Name)
		else {
			AssertContains(Result["carry"], Suffix, "an unfinished comment must retain its exact original head")
			Next := SQLite_ExecReturnCarry(Db, Result["carry"] . Completion . _KLRCB_Batch(12))
			AssertTrue(Next.Get("ok", false), "joining the genuine next chunk must preserve SQL comment semantics")
			AssertEqual("", Next["carry"], "the joined complete transaction has no remaining partial input")
			AssertEqual(2, _KLRCB_Ids(Db).Length, "the next native transaction must execute once after its comment closes")
		}
	} finally SQLite_Close(Db)
}
for _KLRTC_Vector in [
	["line-lf", "-- complete`n", true, ""],
	["line-crlf", "-- complete`r`n", true, ""],
	["block", "/* complete */", true, ""],
	["mixed", "-- first`n /* complete */`n", true, ""],
	["empty-statements", Chr(59) . "  " . Chr(59), true, ""],
	["open-line", "-- unfinished", false, "`n"],
	["cr-only", "-- unfinished`r", false, "`n"],
	["open-block", "/* unfinished", false, "*/"],
	["line-with-block-token", "-- /* complete`n", true, ""],
	["block-with-open-token", "/* /* complete */", true, ""],
	["closed-then-open", "/* complete */ -- unfinished", false, "`n"]
]
	Test("SQLite trivia: " . _KLRTC_Vector[1] . " preserves native chunk boundaries (klr-closed-comment-carry)",
		_KLRTC_CommentCarry.Bind(_KLRTC_Vector*))
