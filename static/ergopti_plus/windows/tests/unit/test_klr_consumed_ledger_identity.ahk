; static/ergopti_plus/windows/tests/unit/test_klr_consumed_ledger_identity.ahk

; ==============================================================================
; MODULE: Consumed Ledger Identity Tests
; DESCRIPTION: Cache publication cannot certify a replacement ledger it never read.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRCI_RejectPoisonedLegacyImage() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Stored := 0
	try {
		Day := "2026-01-01"
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, Day . " 10:00:00.000", Day, "code.exe", ["a"]))
		Assert(_KLRDC_BuildAsWorker() != 0)
		Root := _KLRDC_Root()
		Ledger := Root . "by_device\dev-one\data.sql"
		FileMove(Ledger, Root . "original.sql")
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, Day . " 10:00:00.000", Day, "code.exe", ["b"]))
		Replacement := KLR_LedgerSnapshot(Ledger)
		KLR_ResetCache()
		Stored := SQLite_Open(KLR_CachePath(Root))
		Assert(Stored != 0)
		; Reproduce the old saver: aggregates from A certified as replacement B.
		AssertTrue(SQLite_Exec(Stored,
			"UPDATE klr_cache_meta SET value='2' WHERE key='format_version';"
			. "UPDATE klr_cache_ledger SET volume=" . Replacement["volume"]
			. ",index_high=" . Replacement["index_high"]
			. ",index_low=" . Replacement["index_low"]
			. ",size=" . Replacement["size"] . ",end_offset=" . Replacement["size"] . ";"))
		AssertEqual("a", SQLite_Query(Stored, "SELECT token FROM ngram_chars;")[1]["token"],
			"positive control: the legacy image must still contain the original aggregate")
		SQLite_Close(Stored)
		Stored := 0
		Db := _KLRDC_BuildAsWorker()
		Assert(Db != 0)
		Rows := SQLite_Query(Db, "SELECT token FROM ngram_chars;")
		AssertEqual(1, Rows.Length)
		AssertEqual("b", Rows[1]["token"], "legacy unproven cache provenance must force reconstruction")
	} finally {
		if Stored
			SQLite_Close(Stored)
		_KLRDC_Cleanup()
	}
}
Test("KLR cache: reject already poisoned legacy image (klr-legacy-provenance)",
	_KLRDC_CheckTeardown.Bind(_KLRCI_RejectPoisonedLegacyImage))

_KLRCI_RejectReplacementAtSave(WarmRefresh := false) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Day := "2026-01-01"
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, Day . " 10:00:00.000", Day, "code.exe", ["a"]))
		Db := _KLRDC_BuildAsWorker()
		Assert(Db != 0)
		Root := _KLRDC_Root()
		Ledger := Root . "by_device\dev-one\data.sql"
		Original := KLR_LedgerSnapshot(Ledger)
		AssertTrue(KLR_LedgerFileIsSame(Original, KLRCache.ledger_snapshots[Ledger]),
			"cold projection must publish the identity of the file it consumed")
		FileMove(Ledger, Root . "original.sql")
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, Day . " 10:00:00.000", Day, "code.exe", ["b"]))
		Replacement := KLR_LedgerSnapshot(Ledger)
		AssertFalse(KLR_LedgerFileIsSame(Original, Replacement),
			"positive control: the replacement must have a different native file identity")
		AssertEqual(Original["size"], Replacement["size"],
			"a size watermark alone must not distinguish this replacement")
		if WarmRefresh {
			Db := KLR_BuildDatabase(Root)
		} else {
			AssertEqual(0, KLR_CacheSave(Db, KLRCache.last_sizes, Root, Root . "probe.log", KLRCache.ledger_snapshots),
				"cache save must not certify replacement bytes that its projection never consumed")
			KLR_ResetCache()
			AssertEqual(0, KLRCache.ledger_snapshots.Count, "reset must retire consumed identities")
			Db := _KLRDC_BuildAsWorker()
		}
		Rows := SQLite_Query(Db, "SELECT token FROM ngram_chars ORDER BY token;")
		AssertEqual(1, Rows.Length)
		AssertEqual("b", Rows[1]["token"], "a fresh worker must rebuild from the replacement ledger")
		AssertTrue(KLR_LedgerFileIsSame(Replacement, KLRCache.ledger_snapshots[Ledger]))
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR cache: reject identity replaced after consumption (klr-consumed-ledger-identity)",
	_KLRDC_CheckTeardown.Bind(_KLRCI_RejectReplacementAtSave))
Test("KLR cache: warm same-size replacement rebuilds consumed identity (klr-consumed-ledger-identity)",
	_KLRDC_CheckTeardown.Bind(_KLRCI_RejectReplacementAtSave.Bind(true)))

_KLRCI_IncrementalAndRestoreIdentity() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Day := "2026-01-01"
		_KLRDC_WriteLedger(_KLRDC_Header()
			. _KLRDC_TypingBatch(1, Day . " 10:00:00.000", Day, "code.exe", ["a"]))
		_KLRDC_BuildAsWorker()
		Root := _KLRDC_Root()
		Ledger := Root . "by_device\dev-one\data.sql"
		Before := KLRCache.ledger_snapshots[Ledger].Clone()
		_KLRDC_AppendLedger(_KLRDC_TypingBatch(2, Day . " 10:00:01.000", Day, "code.exe", ["b"]))
		Assert(KLR_BuildDatabase(Root) != 0)
		Consumed := KLRCache.ledger_snapshots[Ledger]
		AssertTrue(KLR_LedgerFileIsSame(Before, Consumed))
		Assert(Consumed["size"] > Before["size"], "incremental publication must advance the consumed receipt")
		AssertEqual(KLRCache.last_sizes[Ledger], Consumed["size"])
		AssertEqual(1, KLR_CacheSave(KLRCache.db, KLRCache.last_sizes, Root,
			Root . "probe.log", KLRCache.ledger_snapshots))
		Offset := KLRCache.last_sizes[Ledger]
		KLR_ResetCache()
		KLRCache.disposable := true
		AssertEqual(1, KLR_CacheAttach(Root, Root . "probe.log"))
		AssertEqual(Offset, KLRCache.last_sizes[Ledger])
		AssertTrue(KLR_LedgerSnapshotIsSame(Consumed, KLRCache.ledger_snapshots[Ledger]),
			"cache restore must retain the consumed identity and modification receipt")
	} finally {
		_KLRDC_Cleanup()
	}
}
Test("KLR cache: incremental and restored identities track consumed offsets (klr-consumed-ledger-identity)",
	_KLRDC_CheckTeardown.Bind(_KLRCI_IncrementalAndRestoreIdentity))

_KLRCI_SameSizeRewrite(Mode) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Day := "2026-01-01"
		OriginalSql := _KLRDC_Header()
			. _KLRDC_TypingBatch(1, Day . " 10:00:00.000", Day, "code.exe", ["a"])
		ReplacementSql := _KLRDC_Header()
			. _KLRDC_TypingBatch(1, Day . " 10:00:00.000", Day, "code.exe", ["b"])
		_KLRDC_WriteLedger(OriginalSql)
		Ledger := _KLRDC_LedgerPath()
		FileSetTime("20260101000000", Ledger, "M")
		Db := _KLRDC_BuildAsWorker()
		Before := KLR_LedgerSnapshot(Ledger)
		AssertEqual("a", SQLite_Query(Db, "SELECT token FROM ngram_chars;")[1]["token"])
		AssertEqual(Db, KLR_BuildDatabase(_KLRDC_Root()), "unchanged input must retain the cached handle")
		; Rewrite the same native file; replacing its path exercises a different guard.
		Writer := FileOpen(Ledger, "rw", "UTF-8-RAW")
		try Writer.Write(ReplacementSql)
		finally Writer.Close()
		FileSetTime("20260101000002", Ledger, "M")
		After := KLR_LedgerSnapshot(Ledger)
		AssertTrue(KLR_LedgerFileIsSame(Before, After))
		AssertEqual(Before["size"], After["size"])
		AssertFalse(KLR_LedgerSnapshotIsSame(Before, After), "the rewrite must change the modification receipt")
		AssertEqual(ReplacementSql, FileRead(Ledger, "UTF-8-RAW"))
		Root := _KLRDC_Root()
		if Mode = "save" {
			AssertEqual(0, KLR_CacheSave(Db, KLRCache.last_sizes, Root,
				Root . "probe.log", KLRCache.ledger_snapshots), "a stale image must not certify rewritten bytes")
			return
		}
		Db := Mode = "restore" ? _KLRDC_BuildAsWorker() : KLR_BuildDatabase(Root)
		Assert(Db != 0)
		Rows := SQLite_Query(Db, "SELECT token FROM ngram_chars;")
		AssertEqual(1, Rows.Length)
		AssertEqual("b", Rows[1]["token"], "same-size rewritten input must replace the stale aggregate")
	} finally {
		_KLRDC_Cleanup()
	}
}
for Mode in ["warm", "restore", "save"]
	Test("KLR cache: same-file same-size rewrite " . Mode . " (klr-same-size-rewrite)",
		_KLRDC_CheckTeardown.Bind(_KLRCI_SameSizeRewrite.Bind(Mode)))
