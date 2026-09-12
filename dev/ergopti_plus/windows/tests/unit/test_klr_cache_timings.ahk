; tests/unit/test_klr_cache_timings.ahk

; ==============================================================================
; MODULE: Reader Cache Timing Configuration Tests
; DESCRIPTION: Cached metrics must use the same timing thresholds as cold replay.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRTC_ChangedPauseThreshold() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	SavedThink := KLWConst.THINK_PAUSE_MS
	SavedMaximum := KLWConst.MAX_KEYSTROKE_DELAY_MS
	try {
		KLWConst.MAX_KEYSTROKE_DELAY_MS := 1000
		KLWConst.THINK_PAUSE_MS := 200
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a", "b"]))
		Initial := _KLRDC_BuildAsWorker()
		AssertEqual(240, SQLite_Query(Initial, "SELECT time_ms FROM agg_app_day;")[1]["time_ms"])
		KLWConst.THINK_PAUSE_MS := 100
		Warm := SQLite_Query(_KLRDC_BuildAsWorker(), "SELECT time_ms FROM agg_app_day;")[1]["time_ms"]
		KLR_ResetCache()
		FileDelete(KLR_CachePath(_KLRDC_Root()))
		Cold := SQLite_Query(_KLRDC_BuildAsWorker(), "SELECT time_ms FROM agg_app_day;")[1]["time_ms"]
		AssertEqual(0, Cold, "the lower threshold must exclude the two 120 ms delays from active typing time")
		AssertEqual(Cold, Warm, "a changed timing configuration must not reuse aggregates from the old threshold")
	} finally {
		try _KLRDC_Cleanup()
		finally {
			KLWConst.THINK_PAUSE_MS := SavedThink
			KLWConst.MAX_KEYSTROKE_DELAY_MS := SavedMaximum
		}
	}
}
Test("KLR cache: changed pause threshold matches cold replay (klr-cache-timings)",
	_KLRDC_CheckTeardown.Bind(_KLRTC_ChangedPauseThreshold))

_KLRTC_ThresholdAdmission(Field) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Saved := KLWConst.%Field%
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a", "b"]))
		_KLRDC_BuildAsWorker()
		_KLRDC_BuildAsWorker()
		AssertTrue(KLRCache.readonly, "unchanged timing values must reuse the image")
		KLWConst.%Field% := Saved + 1
		_KLRDC_BuildAsWorker()
		AssertFalse(KLRCache.readonly, "a change to " . Field . " must invalidate the old aggregates")
		_KLRDC_BuildAsWorker()
		AssertTrue(KLRCache.readonly, "the rebuilt image must record " . Field . " for the next worker")
	} finally {
		try _KLRDC_Cleanup()
		finally KLWConst.%Field% := Saved
	}
}
for Field in ["MAX_KEYSTROKE_DELAY_MS", "THINK_PAUSE_MS", "BURST_GAP_MS",
	"SESSION_GAP_MS", "AUTO_REPEAT_MAX_DELAY_MS", "HOLD_THRESHOLD_MS"]
	Test("KLR cache: invalidate changed " . Field . " (klr-cache-timings)",
		_KLRDC_CheckTeardown.Bind(_KLRTC_ThresholdAdmission.Bind(Field)))

_KLRTC_UnverifiableMetadata(Missing) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a", "b"]))
		Expected := _KLRDC_DerivedFingerprint(_KLRDC_BuildAsWorker())
		KLR_ResetCache()
		Stored := SQLite_Open(KLR_CachePath(_KLRDC_Root()))
		AssertTrue(Stored != 0)
		try AssertTrue(SQLite_Exec(Stored, Missing
			? "DELETE FROM klr_cache_meta WHERE key='walker_timings';"
			: "UPDATE klr_cache_meta SET value='unverifiable' WHERE key='walker_timings';"))
		finally SQLite_Close(Stored)
		Actual := _KLRDC_DerivedFingerprint(_KLRDC_BuildAsWorker())
		AssertFalse(KLRCache.readonly, "unverifiable settings must force a rebuild")
		AssertEqual(Expected, Actual, "rebuilding metadata must preserve the complete derived metrics")
		_KLRDC_BuildAsWorker()
		AssertTrue(KLRCache.readonly, "the repaired image must be reusable")
	} finally _KLRDC_Cleanup()
}
Test("KLR cache: images without timing metadata rebuild (klr-cache-timings)",
	_KLRDC_CheckTeardown.Bind(_KLRTC_UnverifiableMetadata.Bind(true)))
Test("KLR cache: malformed timing metadata rebuilds (klr-cache-timings)",
	_KLRDC_CheckTeardown.Bind(_KLRTC_UnverifiableMetadata.Bind(false)))
