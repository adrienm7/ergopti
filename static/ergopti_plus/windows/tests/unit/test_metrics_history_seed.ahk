; static/ergopti_plus/windows/tests/unit/test_metrics_history_seed.ahk

; ==============================================================================
; MODULE: Metrics History Seed Tests
; DESCRIPTION: Consumed ledger checkpoints admit only proven same-day changes.
; ==============================================================================

#Requires AutoHotkey v2.0

_MHS_ReceiptScenario(Mode) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Day := "2026-01-02"
		OldDay := "2026-01-01"
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, Day . " 10:00:00.000", Day, "code.exe", ["a"]))
		_KLRDC_BuildAsWorker()
		Root := _KLRDC_Root()
		Ledger := _KLRDC_LedgerPath()
		Seed := KLPF_CaptureHistorySeed(Root, Day)
		AssertTrue(KLPF_HistorySeedAllowsDelta(Seed, KLPF_CaptureHistorySeed(Root, Day)),
			"positive control: an unchanged consumed tuple must admit a delta")
		if Mode = "unchanged"
			return
		if Mode = "rollover" {
			AssertFalse(KLPF_HistorySeedAllowsDelta(Seed, KLPF_CaptureHistorySeed(Root, "2026-01-03")))
			return
		}
		if Mode = "replacement" {
			FileMove(Ledger, Root . "original.sql")
			_KLRDC_WriteLedger(_KLRDC_Header()
				. _KLRDC_TypingBatch(1, Day . " 10:00:00.000", Day, "code.exe", ["b"]))
		} else if Mode = "removed" {
			FileDelete(Ledger)
		} else if Mode = "unclassified" {
			_KLRDC_AppendLedger("BEGIN;COMMIT;`n")
		} else {
			AppendDay := Mode = "old-day" ? OldDay : Day
			_KLRDC_AppendLedger(_KLRDC_TypingBatch(2, AppendDay . " 10:00:01.000", AppendDay,
				"code.exe", ["b"]))
		}
		_KLRDC_BuildAsWorker()
		if Mode = "old-day" {
			; Another worker can persist the change before this window next refreshes.
			; Its full seed still predates the append, despite the reader having no tail.
			AssertEqual(1, KLR_CacheSave(KLRCache.db, KLRCache.last_sizes, Root,
				Root . "probe.log", KLRCache.ledger_snapshots))
			_KLRDC_BuildAsWorker()
		}
		Current := KLPF_CaptureHistorySeed(Root, Day)
		AssertEqual(Mode = "today", KLPF_HistorySeedAllowsDelta(Seed, Current),
			"only classified same-day appends may advance the delivered history checkpoint")
		if Mode = "today" {
			Checkpoint := Current
			_KLRDC_AppendLedger(_KLRDC_TypingBatch(3, Day . " 10:00:02.000", Day,
				"code.exe", ["c"]))
			_KLRDC_BuildAsWorker()
			AssertTrue(KLPF_HistorySeedAllowsDelta(Checkpoint, KLPF_CaptureHistorySeed(Root, Day)),
				"a successfully delivered delta can become the next incremental checkpoint")
		}
	} finally {
		_KLRDC_Cleanup()
	}
}
for Mode in ["unchanged", "today", "old-day", "replacement", "removed", "rollover", "unclassified"]
	Test("metrics history seed: " . Mode . " (metrics-history-seed)",
		_KLRDC_CheckTeardown.Bind(_MHS_ReceiptScenario.Bind(Mode)))

_MHS_InvalidAndOwnedReceipts() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Day := "2026-01-02"
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, Day . " 10:00:00.000", Day, "code.exe", ["a"]))
		_KLRDC_BuildAsWorker()
		Root := _KLRDC_Root()
		Ledger := _KLRDC_LedgerPath()
		Seed := KLPF_CaptureHistorySeed(Root, Day)
		for Invalid in [0, "", Map(), Map("version", 1, "store", Root, "day", Day, "ledgers", [])]
			AssertFalse(KLPF_HistorySeedAllowsDelta(Invalid, Seed))
		for Field, Value in Map("version", "1", "store", Root . "other\", "day", "2026-02-31") {
			Invalid := Seed.Clone()
			Invalid[Field] := Value
			AssertFalse(KLPF_HistorySeedAllowsDelta(Invalid, Seed))
		}
		OriginalIndex := KLRCache.ledger_snapshots[Ledger]["index_low"]
		Seed["ledgers"][Ledger]["snapshot"]["index_low"] := OriginalIndex + 1
		AssertEqual(OriginalIndex, KLRCache.ledger_snapshots[Ledger]["index_low"],
			"receipt mutation must not alter the reader's consumed snapshot")
		AssertFalse(KLPF_HistorySeedAllowsDelta(Seed, KLPF_CaptureHistorySeed(Root, Day)))
		Seed := KLPF_CaptureHistorySeed(Root, Day)
		Seed["ledgers"][Ledger]["offset"] := -1
		AssertFalse(KLPF_HistorySeedAllowsDelta(Seed, KLPF_CaptureHistorySeed(Root, Day)))
		for Device in [".", ".."] {
			Invalid := KLPF_CaptureHistorySeed(Root, Day)
			Receipt := Invalid["ledgers"].Delete(Ledger)
			Invalid["ledgers"][Root . "by_device\" . Device . "\data.sql"] := Receipt
			AssertFalse(KLPF_HistorySeedAllowsDelta(Invalid, Invalid),
				"malformed device paths must be rejected before any tail read")
		}
		KLRCache.ledger_snapshots.Delete(Ledger)
		AssertThrows(() => KLPF_CaptureHistorySeed(Root, Day),
			"capture must fail fast instead of inventing missing consumed provenance")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("metrics history seed: malformed metadata fails closed and clones ownership (metrics-history-seed)",
	_KLRDC_CheckTeardown.Bind(_MHS_InvalidAndOwnedReceipts))

_MHS_ProducerDeclinesChangedHistory(Mode) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Day := FormatTime(A_Now, "yyyy-MM-dd")
		OldDay := KLR_PrevDay(Day)
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, Day . " 10:00:00.000", Day, "code.exe", ["a"]))
		_KLRDC_BuildAsWorker()
		Root := _KLRDC_Root()
		Seed := KLPF_CaptureHistorySeed(Root, Day)
		_KLRDC_AppendLedger(_KLRDC_TypingBatch(2, OldDay . " 10:00:00.000", OldDay,
			"code.exe", ["b"]))
		_KLRDC_BuildAsWorker()
		Path := Root . "declined.json"
		AssertTrue(FSWriteDurable(Path, '{"previous":"complete"}'))
		AssertEqual("full_required", KLPF_BuildAndWriteToPath("typing", Root, Path,
			Root . "probe.log", Mode, Seed), "producer must request full history before encoding a delta")
		AssertEqual('{"previous":"complete"}', FileRead(Path, "UTF-8"),
			"declined delta must not publish partial data over its destination")
	} finally {
		_KLRDC_Cleanup()
	}
}
for Mode in ["live", "manifest"]
	Test("metrics history seed: producer declines " . Mode . " on historical append (metrics-seed-producer)",
		_KLRDC_CheckTeardown.Bind(_MHS_ProducerDeclinesChangedHistory.Bind(Mode)))
