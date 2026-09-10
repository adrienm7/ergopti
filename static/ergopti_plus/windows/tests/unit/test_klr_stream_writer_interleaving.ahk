; tests/unit/test_klr_stream_writer_interleaving.ahk

; ==============================================================================
; MODULE: Streaming Ledger Writer Interleaving Tests
; DESCRIPTION: Real SQL callbacks exercise ownership between full reader chunks.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRSW_OnFirstInsert(State, Context, Action, Argument, Other, Database, Trigger) {
	; SQLITE_INSERT is 18. Run after the first chunk was copied, during prepare.
	if State.Fired || Action != 18 || !Argument || StrGet(Argument, "UTF-8") != "ledger"
		return 0
	State.Fired := true
	try {
		if State.Mode = "append" {
			State.Accepted := KL_AppendDataSqlDurable(State.Path, _KLRCB_Batch(3))
		} else if State.Mode = "hold" {
			State.Writer := FileOpen(State.Path, "a-w", "UTF-8-RAW")
			State.Writer.Write(_KLRCB_Batch(3))
			State.Accepted := FSFlushFileBuffers(State.Writer)
		} else if State.Mode = "rewrite" || State.Mode = "truncate" {
			Before := KLR_LedgerSnapshot(State.Path)
			Writer := FileOpen(State.Path, "rw", "UTF-8-RAW")
			try {
				Writer.Write(_KLRCB_Batch(3))
				if State.Mode = "truncate"
					Writer.Length := Before["size"] - StrLen(_KLRCB_Batch(2))
				State.Accepted := FSFlushFileBuffers(Writer)
			} finally Writer.Close()
			FileSetTime("20000101000000", State.Path, "M")
			After := KLR_LedgerSnapshot(State.Path)
			AssertTrue(KLR_LedgerFileIsSame(Before, After))
			if State.Mode = "truncate"
				AssertTrue(After["size"] < Before["size"])
			else
				AssertEqual(Before["size"], After["size"])
			AssertFalse(KLR_LedgerWriteTimeIsSame(Before, After))
		} else {
			FileMove(State.Path, State.Path . ".previous")
			State.Accepted := KL_AppendDataSqlDurable(State.Path, _KLRCB_Batch(3))
		}
	} catch Error as Failure {
		State.Failure := Failure
		return 1
	}
	return 0
}

_KLRSW_Stream(Mode, ReadFn) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Db := 0
	Callback := 0
	State := {Mode: Mode, Path: _KLRDC_LedgerPath(), Fired: false,
		Accepted: false, Writer: 0, Failure: 0}
	try {
		; Cross the production 4 Mi-character boundary inside a comment. Row 2
		; cannot be copied before SQLite prepares row 1 and invokes the writer.
		Padding := Format("{:4194304}", "")
		_KLRDC_WriteLedger(_KLRCB_Batch(1) . "--" . Padding . "`n" . _KLRCB_Batch(2))
		Padding := ""
		Db := _KLRCB_OpenFixture()
		Callback := CallbackCreate(_KLRSW_OnFirstInsert.Bind(State), "C", 6)
		AssertEqual(0, DllCall(SQLiteConst.DLL . "\sqlite3_set_authorizer",
			"Ptr", Db, "Ptr", Callback, "Ptr", 0, "Cdecl Int"))
		Loaded := -1
		Result := ReadFn.Call(Db, State.Path, &Loaded, &Snapshot)
		AssertEqual(0, DllCall(SQLiteConst.DLL . "\sqlite3_set_authorizer",
			"Ptr", Db, "Ptr", 0, "Ptr", 0, "Cdecl Int"))
		AssertTrue(State.Fired, "the native prepare callback must intervene after the first copy")
		if IsObject(State.Failure)
			throw State.Failure
		AssertTrue(State.Accepted, "the reader must release write exclusion before SQL processing")
		Ids := _KLRCB_Ids(Db)
		if Mode = "append" {
			AssertTrue(Result, "a completed append between chunks must join the reconstruction")
			AssertEqual(3, Ids.Length)
			AssertEqual(1, Ids[1])
			AssertEqual(2, Ids[2])
			AssertEqual(3, Ids[3])
			AssertEqual(FileGetSize(State.Path), Loaded, "the published offset must cover the actual appended bytes")
			AssertTrue(KLR_LedgerSnapshotIsSame(Snapshot, KLR_LedgerSnapshot(State.Path)))
		} else {
			AssertFalse(Result, "an active writer or changed consumed source must reject the next chunk")
			AssertEqual(0, Loaded, "an incomplete reconstruction must not publish a consumed offset")
			AssertEqual(1, Ids.Length, "only the already copied first chunk may have been applied")
			AssertEqual(1, Ids[1])
			if IsObject(State.Writer) {
				State.Writer.Close()
				State.Writer := 0
			}
			SQLite_Close(Db)
			Db := _KLRCB_OpenFixture()
			AssertTrue(ReadFn.Call(Db, State.Path, &Loaded, &Snapshot),
				"a fresh candidate must recover after the writer releases ownership")
			Ids := _KLRCB_Ids(Db)
			AssertEqual(Mode = "hold" ? 3 : Mode = "rewrite" ? 2 : 1, Ids.Length)
			if Mode = "rewrite"
				AssertEqual(2, Ids[1], "recovery must not retain the overwritten first row")
			AssertEqual(3, Ids[Ids.Length])
			AssertEqual(FileGetSize(State.Path), Loaded)
		}
	} finally {
		if IsObject(State.Writer)
			State.Writer.Close()
		if Db {
			DllCall(SQLiteConst.DLL . "\sqlite3_set_authorizer",
				"Ptr", Db, "Ptr", 0, "Ptr", 0, "Cdecl Int")
			SQLite_Close(Db)
		}
		if Callback
			CallbackFree(Callback)
		_KLRDC_Cleanup()
	}
}
Test("KLR stream: completed append joins the next chunk (klr-stream-writer-interleaving)",
	_KLRDC_CheckTeardown.Bind(_KLRSW_Stream.Bind("append", KLR_ExecLargeFile)))
Test("KLR stream: active writer rejects the next chunk then retries (klr-stream-writer-interleaving)",
	_KLRDC_CheckTeardown.Bind(_KLRSW_Stream.Bind("hold", KLR_ExecLargeFile)))
Test("KLR stream: path replacement rejects the next chunk then retries (klr-stream-writer-interleaving)",
	_KLRDC_CheckTeardown.Bind(_KLRSW_Stream.Bind("replace", KLR_ExecLargeFile)))
Test("KLR stream: same-size rewrite rejects mixed chunks then retries (klr-stream-rewrite)",
	_KLRDC_CheckTeardown.Bind(_KLRSW_Stream.Bind("rewrite", KLR_ExecLargeFile)))
Test("KLR stream: truncated rewrite rejects mixed chunks then retries (klr-stream-rewrite)",
	_KLRDC_CheckTeardown.Bind(_KLRSW_Stream.Bind("truncate", KLR_ExecLargeFile)))
