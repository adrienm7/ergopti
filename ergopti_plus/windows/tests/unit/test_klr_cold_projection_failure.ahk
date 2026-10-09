; tests/unit/test_klr_cold_projection_failure.ahk

; ==============================================================================
; MODULE: Cold Typing Projection Failure Tests
; DESCRIPTION: Cold build failures preserve precise causes and recover without a partial image.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRCP_Failure(SqlFailure) {
	global _LOGGER_TEST_SINK, _LOGGER_ERROR_ENABLED
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Base := _KLRDC_Header() . _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000",
			"2026-01-01", "fixture.exe", ["a"])
		Fault := SqlFailure
			? "CREATE TABLE klr_reader_typing_counts (device_id TEXT NOT NULL, event_id INTEGER NOT NULL,"
				. "chars INTEGER NOT NULL, PRIMARY KEY(device_id,event_id)) WITHOUT ROWID;"
				. "CREATE TRIGGER cold_count_refusal BEFORE INSERT ON klr_reader_typing_counts "
				. "BEGIN SELECT RAISE(ABORT,'synthetic cold count refusal');END;"
			: "UPDATE events_typing SET events_json='ergopti-enc-v1:invalid';"
		_KLRDC_WriteLedger(Base . Fault)
		KLRCache.disposable := true
		Captured := []
		SavedSink := _LOGGER_TEST_SINK
		SavedErrors := _LOGGER_ERROR_ENABLED
		try {
			_LOGGER_ERROR_ENABLED := true
			LoggerSetTestSink((Line) => Captured.Push(Line))
			AssertEqual(0, KLR_BuildDatabase(_KLRDC_Root()),
				"a cold preparation failure must reject the candidate")
		} finally {
			LoggerSetTestSink(SavedSink)
			_LOGGER_ERROR_ENABLED := SavedErrors
		}
		SawSummary := false
		SawCause := false
		ExpectedCause := SqlFailure ? "Typing projection cache write failed" : "Encrypted typing projection decrypt failed"
		for Line in Captured {
			if !InStr(Line, "[KLReader]")
				continue
			if SqlFailure
				AssertFalse(InStr(Line, "while decrypting"),
					"a plaintext SQL refusal must not be attributed to decryption")
			if InStr(Line, "Metrics DB build failed while preparing typing projections.")
				SawSummary := true
			if InStr(Line, ExpectedCause)
				SawCause := true
		}
		AssertTrue(SawCause, "the actual SQL or decode failure must retain its specific diagnostic")
		AssertTrue(SawSummary, "the cold reader must report preparation failure without inventing its cause")
		AssertEqual(0, KLRCache.db, "a failed cold candidate must not become resident state")
		AssertFalse(FSExists(KLR_CachePath(_KLRDC_Root())), "a failed cold candidate must not create a disk image")
		AssertEqual(Base . Fault, FileRead(_KLRDC_LedgerPath(), "UTF-8"),
			"the reader must preserve its source during failure")
		_KLRDC_WriteLedger(Base)
		Recovered := _KLRDC_BuildAsWorker()
		AssertEqual(1, SQLite_Query(Recovered, "SELECT SUM(chars) AS n FROM agg_app_day;")[1]["n"],
			"a repaired source must recover its projection on the next build")
	} finally _KLRDC_Cleanup()
}
Test("KLR cold projection: SQL refusal keeps its actual cause (klr-cold-projection-failure)",
	_KLRDC_CheckTeardown.Bind(_KLRCP_Failure.Bind(true)))
Test("KLR cold projection: decode refusal keeps its actual cause (klr-cold-projection-failure)",
	_KLRDC_CheckTeardown.Bind(_KLRCP_Failure.Bind(false)))

