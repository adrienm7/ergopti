; tests/unit/test_keylogger_reader_sql_fail_loud.ahk

; ==============================================================================
; MODULE: Keylogger Reader SQL Failure Tests
; DESCRIPTION:
; The metrics reader materialises append-only SQL into a cached in-memory DB.
; A prepare/step/read failure must invalidate only the unpublished candidate.
; The last-good DB and byte offset stay visible while bounded per-ledger metadata
; triggers an exact reread after the writer changes the incomplete source file.
; These tests exercise the real vendored SQLite DLL and the real loader.
; ==============================================================================

_KLRSQL_OpenMemory() {
	static ModuleHandle := 0
	if !ModuleHandle
		ModuleHandle := DllCall("kernel32\LoadLibraryW", "WStr", SQLiteConst.DLL, "Ptr")
	AssertTrue(ModuleHandle != 0,
		"the real SQLite DLL must stay loaded for the lifetime of its DB handle")
	db := SQLite_Open(":memory:")
	AssertTrue(db != 0, "the vendored SQLite DLL must open an in-memory database")
	return db
}

_KLRSQL_StepFailureReturnsFalse() {
	db := _KLRSQL_OpenMemory()
	try {
		AssertTrue(SQLite_Exec(db,
			"CREATE TABLE exec_guard (id INTEGER PRIMARY KEY);"),
			"the constraint fixture table must be created")
		AssertFalse(SQLite_Exec(db,
			"INSERT INTO exec_guard VALUES (1); INSERT INTO exec_guard VALUES (1);"),
			"a non-DONE sqlite3_step result must fail the whole exec call")
	} finally {
		try SQLite_Close(db)
	}
}
Test("SQLite exec: step errors return false (reader-sql-fail-loud)",
	_KLRSQL_StepFailureReturnsFalse)

_KLRSQL_CarryDistinguishesIncompleteFromInvalid() {
	db := _KLRSQL_OpenMemory()
	try {
		AssertTrue(SQLite_Exec(db,
			"CREATE TABLE carry_guard (id INTEGER PRIMARY KEY);"),
			"the carry fixture table must be created")
		Incomplete := SQLite_ExecReturnCarry(db,
			"INSERT INTO carry_guard VALUES (")
		AssertTrue(Incomplete is Map,
			"the chunk parser must return a typed result, not overload a String carry")
		AssertTrue(Incomplete.Get("ok", false),
			"a non-final incomplete statement is valid carry, not a hard error")
		AssertTrue(Incomplete.Get("carry", "") != "",
			"the incomplete bytes must be preserved for the next chunk")

		Invalid := SQLite_ExecReturnCarry(db, "BROKEN SQL;")
		AssertTrue(Invalid is Map, "a syntax failure must use the same typed result")
		AssertFalse(Invalid.Get("ok", true),
			"complete invalid SQL must fail now instead of masquerading as carry")
	} finally {
		try SQLite_Close(db)
	}
}
Test("SQLite chunks: incomplete and invalid tails differ (reader-sql-fail-loud)",
	_KLRSQL_CarryDistinguishesIncompleteFromInvalid)

global _KLRSQL_CloneStages := []
global _KLRSQL_CloneCloseCount := 0

_KLRSQL_ThrowDuringCloneStep(stage) {
	global _KLRSQL_CloneStages
	_KLRSQL_CloneStages.Push(stage)
	if (stage = "backup_step")
		throw Error("injected sqlite3_backup_step failure")
}

_KLRSQL_CloseFailedClone(db) {
	global _KLRSQL_CloneCloseCount
	_KLRSQL_CloneCloseCount += 1
	SQLite_Close(db)
}

_KLRSQL_CloneFailureReleasesEveryOwnedHandle() {
	global _KLRSQL_CloneStages, _KLRSQL_CloneCloseCount
	source := _KLRSQL_OpenMemory()
	_KLRSQL_CloneStages := []
	_KLRSQL_CloneCloseCount := 0
	try {
		AssertTrue(SQLite_Exec(source,
			"CREATE TABLE clone_guard (id INTEGER PRIMARY KEY); "
			. "INSERT INTO clone_guard VALUES (1);"),
			"the clone ownership fixture must populate its source database")
		clone := SQLite_CloneMemory(source,
			_KLRSQL_ThrowDuringCloneStep, _KLRSQL_CloseFailedClone)
		AssertEqual(0, clone,
			"a thrown backup call must fail closed instead of escaping the wrapper")
		AssertEqual(3, _KLRSQL_CloneStages.Length,
			"the exceptional path must reach backup cleanup after the injected throw")
		AssertEqual("backup_init", _KLRSQL_CloneStages[1])
		AssertEqual("backup_step", _KLRSQL_CloneStages[2])
		AssertEqual("cleanup_finish", _KLRSQL_CloneStages[3],
			"the owned sqlite3_backup object must be finished from finally")
		AssertEqual(1, _KLRSQL_CloneCloseCount,
			"the unpublished candidate handle must be closed exactly once")
		Rows := SQLite_Query(source, "SELECT id FROM clone_guard;")
		AssertEqual(1, Rows.Length,
			"exceptional clone cleanup must not close or mutate the source handle")
	} finally {
		try SQLite_Close(source)
	}
}
Test("SQLite clone: a thrown backup call releases every owned handle (reader-sql-fail-loud)",
	_KLRSQL_CloneFailureReleasesEveryOwnedHandle)

_KLRSQL_PublishCandidateSwapsCompleteTuple() {
	KLR_ResetCache()
	oldDb := _KLRSQL_OpenMemory()
	candidate := _KLRSQL_OpenMemory()
	KLRCache.db := oldDb
	KLRCache.last_sizes := Map("old-ledger", 17)
	KLRCache.pending_snapshots := Map("old-ledger",
		Map("snapshot", Map("ok", true), "end_offset", 24))
	nextSizes := Map("new-ledger", 42)
	published := false
	try {
		Critical(37)
		try {
			KLR_PublishCandidate(candidate, nextSizes)
			published := (KLRCache.db = candidate)
			AssertEqual(37, A_IsCritical,
				"publication must restore a caller's existing Critical interval")
		} finally {
			Critical("Off")
		}
		AssertEqual(candidate, KLRCache.db,
			"the complete tuple must expose the candidate handle")
		AssertFalse(KLRCache.last_sizes.Has("old-ledger"),
			"the complete tuple must not retain offsets from the old handle")
		AssertEqual(42, KLRCache.last_sizes["new-ledger"],
			"the complete tuple must expose the candidate's offsets")
		AssertEqual(0, KLRCache.pending_snapshots.Count,
			"the complete tuple must consume all unpublished carry")
		AssertEqual(0, A_IsCritical,
			"the test's non-critical caller state must remain restored")
	} finally {
		Critical("Off")
		; On success candidate is owned by KLRCache and oldDb was closed. If
		; publication threw, KLRCache still owns oldDb and candidate needs closing.
		KLR_ResetCache()
		if !published
			try SQLite_Close(candidate)
	}
}
Test("Keylogger reader: candidate publication swaps one complete tuple (reader-sql-fail-loud)",
	_KLRSQL_PublishCandidateSwapsCompleteTuple)

_KLRSQL_WriteFixture(path, sql) {
	try FileDelete(path)
	FileAppend(sql, path, "UTF-8")
	loop files, path, "F"
		return A_LoopFileFullPath
	throw Error("SQL fixture was not enumerable after creation: " . path)
}

_KLRSQL_CorruptColdLoadPublishesNothingAndRetries() {
	global _ConfigDir, _AhkSubDir
	root := A_Temp . "\ergopti_klr_sql_fail_loud_" . A_TickCount
	deviceDir := root . "\by_device\test-device"
	path := deviceDir . "\data.sql"
	HadSubDir := IsSet(_AhkSubDir)
	PreviousSubDir := HadSubDir ? _AhkSubDir : ""
	_AhkSubDir := ""
	KLR_ResetCache()
	try {
		DirCreate(deviceDir)
		path := _KLRSQL_WriteFixture(path,
			"CREATE TABLE audit_ingest (id INTEGER PRIMARY KEY); "
			. "INSERT INTO audit_ingest VALUES (1); "
			. "BROKEN SQL; "
			. "INSERT INTO audit_ingest VALUES (2);")

		FailedDb := KLR_BuildDatabase(root)
		AssertEqual(0, FailedDb,
			"a complete syntax error in data.sql must fail the cold materialisation")
		AssertEqual(0, KLRCache.db,
			"a partially mutated in-memory DB must never become the published cache")
		AssertEqual(0, KLRCache.last_sizes.Count,
			"a failed load must not record offsets that make a retry skip unread SQL")

		_KLRSQL_WriteFixture(path,
			"CREATE TABLE audit_ingest (id INTEGER PRIMARY KEY); "
			. "INSERT INTO audit_ingest VALUES (1); "
			. "INSERT INTO audit_ingest VALUES (2);")
		db := KLR_BuildDatabase(root)
		AssertTrue(db != 0, "repairing the tail must make the next cold retry succeed")
		Rows := SQLite_Query(db, "SELECT id FROM audit_ingest ORDER BY id;")
		AssertEqual(2, Rows.Length,
			"the successful retry must include both rows instead of skipping past the old failure")
		AssertEqual(1, Rows[1]["id"])
		AssertEqual(2, Rows[2]["id"])
		AssertTrue(KLRCache.last_sizes.Has(path),
			"only a fully successful load may publish the device offset")
		AssertEqual(FileGetSize(path), KLRCache.last_sizes[path])
	} finally {
		KLR_ResetCache()
		try DirDelete(root, true)
		_AhkSubDir := HadSubDir ? PreviousSubDir : ""
	}
}
Test("Keylogger reader: corrupt SQL publishes no cache or offset (reader-sql-fail-loud)",
	_KLRSQL_CorruptColdLoadPublishesNothingAndRetries)

_KLRSQL_BadDeltaPreservesLastGoodAndRetries() {
	global _AhkSubDir
	root := A_Temp . "\ergopti_klr_delta_invalid_" . A_TickCount
	deviceDir := root . "\by_device\test-device"
	path := deviceDir . "\data.sql"
	HadSubDir := IsSet(_AhkSubDir)
	PreviousSubDir := HadSubDir ? _AhkSubDir : ""
	_AhkSubDir := ""
	KLR_ResetCache()
	try {
		DirCreate(deviceDir)
		InitialSql := "CREATE TABLE audit_invalid_delta (id INTEGER PRIMARY KEY); "
			. "INSERT INTO audit_invalid_delta VALUES (1);"
		path := _KLRSQL_WriteFixture(path, InitialSql)
		db := KLR_BuildDatabase(root)
		AssertTrue(db != 0, "the initial invalid-delta fixture must build")
		PublishedDb := db
		LoadedSize := KLRCache.last_sizes[path]

		FileAppend(" BROKEN SQL;", path, "UTF-8")
		LastGoodDb := KLR_BuildDatabase(root)
		AssertEqual(PublishedDb, LastGoodDb,
			"hard-invalid warm SQL must return the last-good database")
		AssertEqual(PublishedDb, KLRCache.db,
			"hard-invalid SQL must not replace the live cache with its partial candidate")
		AssertEqual(LoadedSize, KLRCache.last_sizes[path],
			"hard-invalid SQL must not advance the published byte offset")
		Rows := SQLite_Query(KLRCache.db,
			"SELECT id FROM audit_invalid_delta ORDER BY id;")
		AssertEqual(1, Rows.Length,
			"the last-good row must remain queryable after a hard SQL failure")

		_KLRSQL_WriteFixture(path, InitialSql
			. " INSERT INTO audit_invalid_delta VALUES (2);")
		db := KLR_BuildDatabase(root)
		AssertTrue(db != 0 && db != PublishedDb,
			"repairing the invalid bytes must publish a fresh candidate")
		Rows := SQLite_Query(db, "SELECT id FROM audit_invalid_delta ORDER BY id;")
		AssertEqual(2, Rows.Length,
			"the repaired retry must expose both the old and new rows")
		AssertEqual(1, Rows[1]["id"])
		AssertEqual(2, Rows[2]["id"])
		AssertEqual(FileGetSize(path), KLRCache.last_sizes[path],
			"only the repaired tail may advance the published offset")
	} finally {
		KLR_ResetCache()
		try DirDelete(root, true)
		_AhkSubDir := HadSubDir ? PreviousSubDir : ""
	}
}
Test("Keylogger reader: invalid warm delta preserves last good state before repair (reader-sql-fail-loud)",
	_KLRSQL_BadDeltaPreservesLastGoodAndRetries)

_KLRSQL_BrokenDeltaPreservesLastGoodAndRetries() {
	global _AhkSubDir
	root := A_Temp . "\ergopti_klr_delta_fail_loud_" . A_TickCount
	deviceDir := root . "\by_device\test-device"
	path := deviceDir . "\data.sql"
	HadSubDir := IsSet(_AhkSubDir)
	PreviousSubDir := HadSubDir ? _AhkSubDir : ""
	_AhkSubDir := ""
	KLR_ResetCache()
	try {
		DirCreate(deviceDir)
		path := _KLRSQL_WriteFixture(path,
			"CREATE TABLE audit_delta (id INTEGER PRIMARY KEY); "
			. "INSERT INTO audit_delta VALUES (1);")
		db := KLR_BuildDatabase(root)
		AssertTrue(db != 0, "the initial cache build must succeed")
		PublishedDb := db
		LoadedSize := KLRCache.last_sizes[path]
		AssertEqual(PublishedDb, KLR_BuildDatabase(root),
			"an unchanged ledger must keep the same handle instead of cloning the full database")

		FileAppend(" BEGIN TRANSACTION; INSERT INTO audit_delta VALUES (", path, "UTF-8")
		AssertTrue(FileGetSize(path) > LoadedSize,
			"the fixture must append bytes beyond the published offset")
		LastGoodDb := KLR_BuildDatabase(root)
		AssertEqual(PublishedDb, LastGoodDb,
			"an incomplete warm delta must return the last-good published database")
		AssertEqual(PublishedDb, KLRCache.db,
			"a failed candidate must not replace or close the last-good cache")
		AssertTrue(KLRCache.last_sizes.Has(path),
			"the published offset must remain observable while the tail is incomplete")
		AssertEqual(LoadedSize, KLRCache.last_sizes[path],
			"the reader must not advance beyond bytes that were fully executed")
		Rows := SQLite_Query(KLRCache.db, "SELECT id FROM audit_delta ORDER BY id;")
		AssertEqual(1, Rows.Length,
			"the live projection must retain row A without exposing partial row B")
		AssertEqual(1, Rows[1]["id"])
		AssertTrue(KLRCache.pending_snapshots.Has(path),
			"the incomplete SQL must retain retry metadata under its ledger path")
		AssertFalse(KLRCache.pending_snapshots[path].Has("sql"),
			"an incomplete transaction must never retain its unbounded SQL text")
		AssertTrue(KLRCache.pending_snapshots[path].Get("snapshot", 0) is Map,
			"the bounded retry metadata must retain the ledger snapshot")

		FileAppend("2);", path, "UTF-8")
		StillLastGoodDb := KLR_BuildDatabase(root)
		AssertEqual(PublishedDb, StillLastGoodDb,
			"a complete statement without COMMIT is still an unpublished writer transaction")
		AssertEqual(LoadedSize, KLRCache.last_sizes[path],
			"the offset must remain pinned until SQLite returns to autocommit mode")
		Rows := SQLite_Query(KLRCache.db, "SELECT id FROM audit_delta ORDER BY id;")
		AssertEqual(1, Rows.Length,
			"row B must remain invisible while its source transaction is open")

		FileAppend(" COMMIT;", path, "UTF-8")
		db := KLR_BuildDatabase(root)
		AssertTrue(db != 0, "completing the interrupted append must let the retry succeed")
		AssertTrue(db != PublishedDb,
			"only the completed candidate may replace the last-good database")
		Rows := SQLite_Query(db, "SELECT id FROM audit_delta ORDER BY id;")
		AssertEqual(2, Rows.Length,
			"the retry must replay the formerly incomplete bytes and load the second row")
		AssertEqual(1, Rows[1]["id"])
		AssertEqual(2, Rows[2]["id"])
		AssertEqual(FileGetSize(path), KLRCache.last_sizes[path],
			"the byte offset may advance only with the successful candidate publication")
		AssertFalse(KLRCache.pending_snapshots.Has(path),
			"publishing the completed tail must consume its per-ledger carry")
	} finally {
		KLR_ResetCache()
		try DirDelete(root, true)
		_AhkSubDir := HadSubDir ? PreviousSubDir : ""
	}
}
Test("Keylogger reader: failed delta preserves last good state before retry (reader-sql-fail-loud)",
	_KLRSQL_BrokenDeltaPreservesLastGoodAndRetries)

_KLRSQL_MultiLedgerCarryReplaysEveryDiscardedTail() {
	global _AhkSubDir
	root := A_Temp . "\ergopti_klr_multi_ledger_" . A_TickCount
	deviceADir := root . "\by_device\device-a"
	deviceBDir := root . "\by_device\device-b"
	pathA := deviceADir . "\data.sql"
	pathB := deviceBDir . "\data.sql"
	HadSubDir := IsSet(_AhkSubDir)
	PreviousSubDir := HadSubDir ? _AhkSubDir : ""
	_AhkSubDir := ""
	KLR_ResetCache()
	try {
		DirCreate(deviceADir)
		DirCreate(deviceBDir)
		pathA := _KLRSQL_WriteFixture(pathA,
			"CREATE TABLE audit_multi_a (id INTEGER PRIMARY KEY); "
			. "INSERT INTO audit_multi_a VALUES (1);")
		pathB := _KLRSQL_WriteFixture(pathB,
			"CREATE TABLE audit_multi_b (id INTEGER PRIMARY KEY); "
			. "INSERT INTO audit_multi_b VALUES (10);")
		PublishedDb := KLR_BuildDatabase(root)
		AssertTrue(PublishedDb != 0, "the initial two-ledger fixture must build")
		LoadedSizeA := KLRCache.last_sizes[pathA]
		LoadedSizeB := KLRCache.last_sizes[pathB]

		; Ledger A is already complete, but its candidate mutation must remain
		; unpublished when ledger B is caught between BEGIN and COMMIT.
		FileAppend(" INSERT INTO audit_multi_a VALUES (2);", pathA, "UTF-8")
		FileAppend(" BEGIN TRANSACTION; INSERT INTO audit_multi_b VALUES (", pathB, "UTF-8")
		AssertEqual(PublishedDb, KLR_BuildDatabase(root),
			"one incomplete ledger must retain the complete last-good projection")
		AssertEqual(LoadedSizeA, KLRCache.last_sizes[pathA],
			"a complete sibling tail must not advance while another ledger is incomplete")
		AssertEqual(LoadedSizeB, KLRCache.last_sizes[pathB],
			"the incomplete ledger must retain its exact published offset")
		AssertTrue(KLRCache.pending_snapshots.Has(pathA)
				&& KLRCache.pending_snapshots.Has(pathB),
			"every participating ledger must retain its own retry snapshot")
		AssertEqual(2, KLRCache.pending_snapshots.Count,
			"per-path metadata must not collapse two ledgers into one ambiguous boundary")
		AssertFalse(KLRCache.pending_snapshots[pathA].Has("sql")
				|| KLRCache.pending_snapshots[pathB].Has("sql"),
			"discarding a multi-ledger candidate must release every SQL string")
		RowsA := SQLite_Query(KLRCache.db,
			"SELECT id FROM audit_multi_a ORDER BY id;")
		RowsB := SQLite_Query(KLRCache.db,
			"SELECT id FROM audit_multi_b ORDER BY id;")
		AssertEqual(1, RowsA.Length,
			"the completed sibling row must remain invisible on the discarded candidate")
		AssertEqual(1, RowsB.Length,
			"the incomplete transaction must remain invisible on the discarded candidate")

		FileAppend("20); COMMIT;", pathB, "UTF-8")
		PublishedAfterRetry := KLR_BuildDatabase(root)
		AssertTrue(PublishedAfterRetry != 0 && PublishedAfterRetry != PublishedDb,
			"completing ledger B must publish one fresh all-ledger candidate")
		RowsA := SQLite_Query(PublishedAfterRetry,
			"SELECT id FROM audit_multi_a ORDER BY id;")
		RowsB := SQLite_Query(PublishedAfterRetry,
			"SELECT id FROM audit_multi_b ORDER BY id;")
		AssertEqual(2, RowsA.Length,
			"retry must replay ledger A bytes executed only on the discarded candidate")
		AssertEqual(2, RowsA[2]["id"])
		AssertEqual(2, RowsB.Length,
			"retry must append and commit ledger B's path-specific carry")
		AssertEqual(20, RowsB[2]["id"])
		AssertEqual(FileGetSize(pathA), KLRCache.last_sizes[pathA],
			"ledger A may advance only with the joint successful publication")
		AssertEqual(FileGetSize(pathB), KLRCache.last_sizes[pathB],
			"ledger B may advance only with the joint successful publication")
		AssertEqual(0, KLRCache.pending_snapshots.Count,
			"joint publication must consume every per-ledger pending tail")
	} finally {
		KLR_ResetCache()
		try DirDelete(root, true)
		_AhkSubDir := HadSubDir ? PreviousSubDir : ""
	}
}
Test("Keylogger reader: multi-ledger retry replays every discarded tail (reader-sql-fail-loud)",
	_KLRSQL_MultiLedgerCarryReplaysEveryDiscardedTail)

_KLRSQL_SameLengthRepairInvalidatesPendingSnapshot() {
	global _AhkSubDir
	root := A_Temp . "\ergopti_klr_same_length_repair_" . A_TickCount
	deviceDir := root . "\by_device\test-device"
	path := deviceDir . "\data.sql"
	HadSubDir := IsSet(_AhkSubDir)
	PreviousSubDir := HadSubDir ? _AhkSubDir : ""
	_AhkSubDir := ""
	KLR_ResetCache()
	try {
		DirCreate(deviceDir)
		InitialSql := "CREATE TABLE audit_same_length (id INTEGER PRIMARY KEY); "
			. "INSERT INTO audit_same_length VALUES (1);"
		path := _KLRSQL_WriteFixture(path, InitialSql)
		PublishedDb := KLR_BuildDatabase(root)
		AssertTrue(PublishedDb != 0, "the same-length repair fixture must build")
		LoadedSize := KLRCache.last_sizes[path]

		IncompleteTail := " INSERT INTO audit_same_length VALUES ("
		ValidTail := " INSERT INTO audit_same_length VALUES (2);"
		TargetLength := Max(StrLen(IncompleteTail), StrLen(ValidTail))
		while (StrLen(IncompleteTail) < TargetLength)
				IncompleteTail .= " "
		while (StrLen(ValidTail) < TargetLength)
				ValidTail .= " "
		AssertEqual(StrLen(IncompleteTail), StrLen(ValidTail),
			"the broken and repaired tails must have identical byte length")

		FileAppend(IncompleteTail, path, "UTF-8")
		AssertEqual(PublishedDb, KLR_BuildDatabase(root),
			"the initial incomplete tail must retain the last-good database")
		AssertEqual(LoadedSize, KLRCache.last_sizes[path],
			"the incomplete tail must retain the exact published offset")
		AssertTrue(KLRCache.pending_snapshots.Has(path),
			"the incomplete bytes must be retained for a snapshot-aware retry")
		PendingSize := FileGetSize(path)
		PendingSnapshot := KLRCache.pending_snapshots[path].Get("snapshot", 0)
		AssertTrue(PendingSnapshot is Map && PendingSnapshot.Get("ok", false),
			"pending carry must retain the file identity and high-resolution mtime")

		; Rewrite through the same file object identity, with the same number of
		; bytes, then force a distinct mtime. A size-only fast path used to call
		; this snapshot stable forever and never retried the repaired SQL.
		fh := FileOpen(path, "w", "UTF-8")
		AssertTrue(IsObject(fh), "the repair fixture must reopen its ledger in place")
		try {
				fh.Write(InitialSql . ValidTail)
		} finally {
				try fh.Close()
		}
		FileSetTime("20301231235959", path, "M")
		AssertEqual(PendingSize, FileGetSize(path),
			"repair must not rely on file growth to become observable")
		RepairedSnapshot := KLR_LedgerSnapshot(path)
		AssertTrue(KLR_LedgerFileIsSame(PendingSnapshot, RepairedSnapshot),
			"the repro must exercise an in-place rewrite, not replacement-file recovery")
		AssertFalse(KLR_LedgerSnapshotIsSame(PendingSnapshot, RepairedSnapshot),
			"same identity and size with a changed mtime must be a new snapshot")

		RepairedDb := KLR_BuildDatabase(root)
		AssertTrue(RepairedDb != 0 && RepairedDb != PublishedDb,
			"a changed same-length snapshot must retry and publish immediately")
		Rows := SQLite_Query(RepairedDb,
			"SELECT id FROM audit_same_length ORDER BY id;")
		AssertEqual(2, Rows.Length,
			"the same-length repair must expose the formerly missing row")
		AssertEqual(2, Rows[2]["id"])
		AssertEqual(PendingSize, KLRCache.last_sizes[path],
			"successful repair may publish the already-observed end offset")
		AssertEqual(0, KLRCache.pending_snapshots.Count,
			"successful same-length repair must consume its pending snapshot")
	} finally {
		KLR_ResetCache()
		try DirDelete(root, true)
		_AhkSubDir := HadSubDir ? PreviousSubDir : ""
	}
}
Test("Keylogger reader: same-length repaired tail invalidates its pending snapshot (reader-sql-fail-loud)",
	_KLRSQL_SameLengthRepairInvalidatesPendingSnapshot)
