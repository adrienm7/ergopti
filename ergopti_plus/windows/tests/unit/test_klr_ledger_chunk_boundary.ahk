; tests/unit/test_klr_ledger_chunk_boundary.ahk

; ==============================================================================
; MODULE: Ledger Chunk Boundary Tests (klr-ledger-chunk-comment-carry)
; DESCRIPTION:
; KLR_ExecLargeFile streams a device ledger into the dashboard's in-memory
; database in 4 MB chunks and hands whatever SQLite could not parse to the next
; chunk as a carry. Two boundary shapes broke that contract on a real 815 MB
; ledger and left every typing-metrics projection permanently unable to build:
;
; 1. Comment boundary. Each ingest batch is preceded by a
;    "-- === ingest batch ... ===" header. When a chunk ended inside one,
;    sqlite3_prepare_v2 consumed the partial comment as a no-op — OK, a null
;    statement, and a tail at the end of input — so the loop exited with an
;    empty carry and the comment's head was dropped. The next chunk then began
;    mid-word ("try(ies)) ===") and SQLite was handed prose as SQL. Nothing
;    failed at that point: sqlite3_complete reports unterminated input as
;    incomplete, so the garbage was carried, 4 MB was appended to it per chunk,
;    and the reader spent ~30 s and 1.7 GB before dying on "near \"try\"".
;
; 2. NUL hole. An append interrupted between the metadata and data flush leaves
;    a zero-filled gap between two complete transactions. prepare_v2 is called
;    with nByte=-1, so it reads the hole as end of input and stops advancing.
;
; Both are exercised here against the real vendored SQLite DLL, at statement
; granularity, so a regression fails on the parser contract rather than on a
; multi-minute projection of production data.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===========================================
; ===========================================
; ======= 1/ Shared in-memory fixture =======
; ===========================================
; ===========================================

_KLRCB_OpenFixture() {
	static ModuleHandle := 0
	if !ModuleHandle
		ModuleHandle := DllCall("kernel32\LoadLibraryW", "WStr", SQLiteConst.DLL, "Ptr")
	AssertTrue(ModuleHandle != 0,
		"the real SQLite DLL must stay loaded for the lifetime of its DB handle")
	db := SQLite_Open(":memory:")
	AssertTrue(db != 0, "the vendored SQLite DLL must open an in-memory database")
	AssertTrue(SQLite_Exec(db, "CREATE TABLE ledger (id INTEGER PRIMARY KEY);"),
		"the ledger fixture table must be created")
	return db
}

_KLRCB_Ids(db) {
	Ids := []
	for Row in SQLite_Query(db, "SELECT id FROM ledger ORDER BY id")
		Ids.Push(Row["id"])
	return Ids
}

; One ingest batch exactly as the writer emits it: a blank line, the header
; comment, the transaction, and the COMMIT that closes it.
_KLRCB_Batch(Id, Entries := 1) {
	return "`n-- === ingest batch 2026-09-06 18:20:57.662 (offset 0 -> 155550, "
		. Entries . " entry(ies)) ===`nBEGIN TRANSACTION;`n"
		. "INSERT OR IGNORE INTO ledger (id) VALUES (" . Id . ");`nCOMMIT;`n"
}





; ===================================================
; ===================================================
; ======= 2/ A boundary inside a line comment =======
; ===================================================
; ===================================================

_KLRCB_PartialCommentIsCarried() {
	db := _KLRCB_OpenFixture()
	try {
		Batch := _KLRCB_Batch(1)
		; Cut the batch inside the word "entry(ies)" of its header comment, the
		; way a 4 MB read boundary does.
		CutAt := InStr(Batch, "entry(ies)") + 2
		Head := SubStr(Batch, 1, CutAt - 1)
		Tail := SubStr(Batch, CutAt)
		AssertTrue(InStr(Head, "--") > 0 && !InStr(Head, "BEGIN TRANSACTION"),
			"the fixture must cut inside the header comment, before any statement")

		First := SQLite_ExecReturnCarry(db, Head)
		AssertTrue(First.Get("ok", false),
			"a chunk that ends inside a comment is incomplete input, not invalid SQL")
		AssertTrue(InStr(First.Get("carry", ""), "-- === ingest batch") > 0,
			"the partial comment must be carried to the next chunk: dropping it "
			. "splices the comment's remainder onto the next chunk as SQL "
			. "(klr-ledger-chunk-comment-carry)")

		Second := SQLite_ExecReturnCarry(db, First["carry"] . Tail)
		AssertTrue(Second.Get("ok", false),
			"rejoining the carry with the next chunk must parse as valid SQL")
		AssertTrue(Second.Get("carry", "") = "",
			"a chunk that ends on a closed transaction leaves nothing to carry")

		Ids := _KLRCB_Ids(db)
		AssertTrue(Ids.Length = 1 && Ids[1] = 1,
			"the batch split across the comment boundary must land exactly once; got "
			. Ids.Length . " row(s)")
	} finally {
		try SQLite_Close(db)
	}
}
Test("KLR ledger chunks: a boundary inside a header comment carries it (klr-ledger-chunk-comment-carry)",
	_KLRCB_PartialCommentIsCarried)

; The failure mode the dropped comment produced downstream: prose in front of
; otherwise valid SQL must be refused, not accepted and silently carried.
_KLRCB_SplicedCommentTailIsInvalid() {
	db := _KLRCB_OpenFixture()
	try {
		Spliced := SQLite_ExecReturnCarry(db,
			"try(ies)) ===`nBEGIN TRANSACTION;`n"
			. "INSERT OR IGNORE INTO ledger (id) VALUES (7);`nCOMMIT;`n")
		AssertFalse(Spliced.Get("ok", true),
			"a chunk whose head is a comment remainder is corrupt input and must "
			. "fail loudly instead of being carried forward for ever")
		AssertTrue(_KLRCB_Ids(db).Length = 0,
			"a refused chunk must not have executed any of its statements")
	} finally {
		try SQLite_Close(db)
	}
}
Test("KLR ledger chunks: a spliced comment remainder is refused (klr-ledger-chunk-comment-carry)",
	_KLRCB_SplicedCommentTailIsInvalid)

; KLR_ApplyIncremental treats any carry as an interrupted writer boundary and
; discards the candidate. Trailing whitespace after a COMMIT is the normal shape
; of a ledger tail, so it must never be reported as carry.
_KLRCB_TrailingWhitespaceIsNotCarry() {
	db := _KLRCB_OpenFixture()
	try {
		Result := SQLite_ExecReturnCarry(db, _KLRCB_Batch(2) . "`n`n  `n")
		AssertTrue(Result.Get("ok", false), "a closed batch must execute")
		AssertTrue(Result.Get("carry", "") = "",
			"trailing whitespace is not an incomplete statement: reporting it as "
			. "carry would make every incremental refresh look like a torn append")
		AssertTrue(_KLRCB_Ids(db).Length = 1, "the closed batch must have landed")
	} finally {
		try SQLite_Close(db)
	}
}
Test("KLR ledger chunks: trailing whitespace is not carry (klr-ledger-chunk-comment-carry)",
	_KLRCB_TrailingWhitespaceIsNotCarry)





; ========================================
; ========================================
; ======= 3/ An interrupted append =======
; ========================================
; ========================================

_KLRCB_NulHoleIsSkippedAndCounted() {
	db := _KLRCB_OpenFixture()
	try {
		; A crash between the length update and the data flush leaves NUL padding
		; between two complete transactions.
		Hole := Chr(0) . Chr(0) . Chr(0) . Chr(0) . Chr(0)
		Result := SQLite_ExecReturnCarry(db,
			_KLRCB_Batch(3) . Hole . _KLRCB_Batch(4))
		AssertTrue(Result.Get("ok", false),
			"a NUL hole between two complete transactions must not fail the load: "
			. "prepare_v2 reads it as end of input and stops advancing")
		AssertTrue(Result.Get("nul_bytes", 0) = 5,
			"the skipped hole must be counted so the ledger damage is reported, "
			. "not silently repaired; got " . Result.Get("nul_bytes", 0))

		Ids := _KLRCB_Ids(db)
		AssertTrue(Ids.Length = 2,
			"both transactions around the hole must be replayed; got "
			. Ids.Length . " row(s)")
	} finally {
		try SQLite_Close(db)
	}
}
Test("KLR ledger chunks: a NUL hole is skipped and counted (klr-ledger-nul-hole)",
	_KLRCB_NulHoleIsSkippedAndCounted)

_KLRCB_CleanChunkReportsNoNulBytes() {
	db := _KLRCB_OpenFixture()
	try {
		Result := SQLite_ExecReturnCarry(db, _KLRCB_Batch(5))
		AssertTrue(Result.Get("nul_bytes", -1) = 0,
			"an intact chunk must report zero skipped bytes, so the warning it "
			. "drives cannot fire on healthy ledgers")
	} finally {
		try SQLite_Close(db)
	}
}
Test("KLR ledger chunks: an intact chunk reports no NUL bytes (klr-ledger-nul-hole)",
	_KLRCB_CleanChunkReportsNoNulBytes)
