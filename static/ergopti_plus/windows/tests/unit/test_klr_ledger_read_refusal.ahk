; tests/unit/test_klr_ledger_read_refusal.ahk

; ==============================================================================
; MODULE: Ledger Read Refusal Tests
; DESCRIPTION: A native byte-lock refusal must not publish a truncated cold image.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRLR_ColdReadRefusal(Cold) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Probe := Map("file", 0, "locked", false, "page_size", 1, "overlap", Buffer(32, 0))
	Candidate := 0
	try {
		_KLRDC_WriteLedger(_KLRDC_Header() . _KLRDC_TypingBatch(1,
			"2026-01-01 10:00:00.000", "2026-01-01", "fixture.exe", ["a"]))
		Path := _KLRDC_LedgerPath()
		Before := KLR_LedgerSnapshot(Path)
		Probe["file"] := FileOpen(Path, "r")
		Probe["locked"] := DllCall("Kernel32\LockFileEx", "Ptr", Probe["file"].Handle,
			"UInt", 3, "UInt", 0, "UInt", 1, "UInt", 0, "Ptr", Probe["overlap"], "Int")
		AssertTrue(Probe["locked"], "the fixture must refuse native reads of the first byte")
		try {
			Result := Cold ? KLR_BuildColdCandidate(_KLRDC_Root(), "") : KLR_ReadLedgerTail(Path, 0)
			Candidate := Result.Get("db", 0)
			AssertFalse(Result["ok"], "a refused ledger read must not become a successful empty result")
		} finally _KLRCC_ReleaseLock(Probe)
		AssertTrue(KLR_LedgerSnapshotIsSame(Before, KLR_LedgerSnapshot(Path)))
		Result := KLR_BuildColdCandidate(_KLRDC_Root(), "")
		Candidate := Result.Get("db", 0)
		AssertTrue(Result["ok"], "the same journal must recover after the native lock is released")
		AssertEqual(1, SQLite_Query(Candidate, "SELECT SUM(chars) AS n FROM agg_app_day;")[1]["n"])
	} finally {
		SQLite_Close(Candidate)
		_KLRCC_ReleaseLock(Probe)
		_KLRDC_Cleanup()
	}
}
for Cold in [true, false]
	Test("KLR reader: native byte-lock refusal cannot become EOF cold=" . Cold . " (klr-ledger-read-refusal)",
		_KLRDC_CheckTeardown.Bind(_KLRLR_ColdReadRefusal.Bind(Cold)))
