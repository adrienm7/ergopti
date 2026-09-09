; tests/meta/test_metrics_committed_ingest_signal.ahk

; ==============================================================================
; MODULE: Committed Metrics Ingest Signal Guard
; DESCRIPTION: The full logger's idle dispatch retains a cheap busy-input signal.
; ==============================================================================

#Requires AutoHotkey v2.0

_MCIS_BusyCommitRetainsRevision() {
	; The runtime harness exercises both dispatch endpoints. The full logger's
	; auto-execute owner is not loaded there, so guard their actual wiring here.
	Body := _StripFullLineComments(_DriverFuncBody("KL_IngestOnce"))
	AssertTrue(Body != "", "the real ingest owner must be discoverable")
	Append := InStr(Body, "KL_AppendDataSqlDurable(")
	Signal := InStr(Body, "KLWV_RecordCommittedIngest()")
	AssertTrue(Append > 0 && Signal > Append, "the signal must follow durable append processing")
	AssertTrue(RegExMatch(Body,
		"s)if\s+\(KLHook\.last_tick.*?INGEST_LIVE_PUSH_IDLE_MS\)\s*\{\s*"
		. "try\s+KLWV_NotifyIngest\(\)\s*\}\s*else\s*\{\s*try\s+KLWV_RecordCommittedIngest\(\)\s*\}") > 0,
		"keyboard activity may defer worker launch but must not discard the committed input revision")
}
Test("metrics retries: busy ingest retains a committed signal (metrics-full-retry-cadence)",
	_MCIS_BusyCommitRetainsRevision)
