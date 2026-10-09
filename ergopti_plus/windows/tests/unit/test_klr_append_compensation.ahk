; tests/unit/test_klr_append_compensation.ahk

; ==============================================================================
; MODULE: Reader And Append Compensation Integration Tests
; DESCRIPTION: Failed durable appends must not survive in a reader image.
; ==============================================================================

#Requires AutoHotkey v2.0

_KLRAC_ReadBeforeFailedFlush(State, Fh) {
	State.Calls += 1
	if State.Calls > 1
		return FSFlushFileBuffers(Fh)
	State.Observed := KLR_LedgerSnapshot(_KLRDC_LedgerPath())
	KLR_ResetCache()
	KLRCache.disposable := true
	State.Reader := KLR_BuildDatabase(_KLRDC_Root())
	if State.Reader
		State.UnsafeRows := SQLite_Query(State.Reader,
			"SELECT COUNT(*) AS n FROM ngram_chars WHERE token='a';")[1]["n"]
	return false
}

_KLRAC_CompensatedAppendDoesNotSurvive(Warm) {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Header := _KLRDC_Header()
		if Warm
			Header .= _KLRDC_TypingBatch(1, "2026-01-01 09:00:00.000",
				"2026-01-01", "fixture.exe", ["x"])
		_KLRDC_WriteLedger(Header)
		if Warm
			_KLRDC_BuildAsWorker()
		Path := _KLRDC_LedgerPath()
		Rejected := _KLRDC_TypingBatch(2, "2026-01-01 10:00:00.000",
			"2026-01-01", "fixture.exe", ["a"])
		Accepted := _KLRDC_TypingBatch(2, "2026-01-01 10:00:00.000",
			"2026-01-01", "fixture.exe", ["b"])
		State := {Calls: 0, Reader: 0, Observed: 0, UnsafeRows: 0}
		Failure := 0
		try KL_AppendDataSqlDurable(Path, Rejected, 0,
			_KLRAC_ReadBeforeFailedFlush.Bind(State))
		catch Error as Err
			Failure := Err
		AssertTrue(IsObject(Failure), "the injected storage flush must reject the append")
		AssertTrue(InStr(Failure.Message, "stable-storage flush failed") > 0,
			"the intended storage failure must drive compensation")
		AssertEqual(2, State.Calls, "the real writer must flush its rollback")
		AssertEqual(Header, FileRead(Path, "UTF-8"), "compensation must restore the exact prefix")
		AssertTrue(KL_AppendDataSqlDurable(Path, Accepted))
		Current := KLR_LedgerSnapshot(Path)
		AssertTrue(KLR_LedgerFileIsSame(State.Observed, Current))
		AssertEqual(State.Observed["size"], Current["size"],
			"the accepted retry must reach the same byte boundary on the same file")
		Db := _KLRDC_BuildAsWorker()
		Rows := SQLite_Query(Db, "SELECT token FROM ngram_chars ORDER BY token;")
		AssertEqual(Warm ? 2 : 1, Rows.Length)
		AssertEqual("b", Rows[1]["token"],
			"a cached read during a compensated append must not replace accepted metrics")
		AssertEqual(0, State.UnsafeRows, "no projection may expose the still-compensable append")
	} finally _KLRDC_Cleanup()
}
Test("KLR reader: compensated append cannot poison an equal-size retry (klr-append-compensation)",
	_KLRDC_CheckTeardown.Bind(_KLRAC_CompensatedAppendDoesNotSurvive.Bind(false)))
Test("KLR reader: warm refresh cannot expose an unconfirmed append (klr-append-compensation)",
	_KLRDC_CheckTeardown.Bind(_KLRAC_CompensatedAppendDoesNotSurvive.Bind(true)))

_KLRAC_StableChunkOwnership() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Reader := 0
	Writer := 0
	try {
		_KLRDC_WriteLedger("abcd")
		Path := _KLRDC_LedgerPath()
		Reader := FileOpen(Path, "r", "UTF-8")
		Writer := FileOpen(Path, "a-w", "UTF-8-RAW")
		AssertFalse(KLR_ReadStableLedgerChunk(Reader, Path, 2)["ok"],
			"a live writable handle must prevent copying even a complete SQL boundary")
		AssertEqual(0, Reader.Pos, "refusal must not consume any byte")
		Writer.Close()
		Writer := 0
		First := KLR_ReadStableLedgerChunk(Reader, Path, 2)
		AssertTrue(First["ok"])
		AssertEqual("ab", First["text"])
		; SQL work happens between chunk calls. The writer must be free here.
		AssertTrue(KL_AppendDataSqlDurable(Path, "ef"))
		Second := KLR_ReadStableLedgerChunk(Reader, Path)
		AssertTrue(Second["ok"])
		AssertEqual("cdef", Second["text"])
		AssertEqual(6, Second["snapshot"]["size"])
		AssertTrue(KLR_ReadStableLedgerChunk(Reader, Path)["ok"],
			"EOF must preserve a stable consumed snapshot")
		AssertTrue(KL_AppendDataSqlDurable(Path, "gh"), "EOF must release the guard too")
	} finally {
		if IsObject(Writer)
			Writer.Close()
		if IsObject(Reader)
			Reader.Close()
		_KLRDC_Cleanup()
	}
}
Test("KLR reader: stable chunk guard excludes writers only during copying (klr-append-compensation)",
	_KLRDC_CheckTeardown.Bind(_KLRAC_StableChunkOwnership))

_KLRAC_RejectLegacyUnsafeCache() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	try {
		Prefix := _KLRDC_Header()
		Old := _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000",
			"2026-01-01", "fixture.exe", ["a"])
		New := _KLRDC_TypingBatch(1, "2026-01-01 10:00:00.000",
			"2026-01-01", "fixture.exe", ["b"])
		_KLRDC_WriteLedger(Prefix . Old)
		_KLRDC_BuildAsWorker()
		KLR_ResetCache()
		Stored := SQLite_Open(KLR_CachePath(_KLRDC_Root()))
		AssertTrue(Stored != 0)
		try {
			AssertTrue(SQLite_Exec(Stored,
				"UPDATE klr_cache_meta SET value='4' WHERE key='format_version';"))
			AssertEqual("a", SQLite_Query(Stored, "SELECT token FROM ngram_chars;")[1]["token"])
		} finally SQLite_Close(Stored)
		; Model a cache already poisoned by the old reader before it was upgraded.
		Writer := FileOpen(_KLRDC_LedgerPath(), "w", "UTF-8-RAW")
		try Writer.Write(Prefix . New)
		finally Writer.Close()
		Db := _KLRDC_BuildAsWorker()
		AssertEqual("b", SQLite_Query(Db, "SELECT token FROM ngram_chars;")[1]["token"],
			"a pre-guard image cannot establish durable provenance and must rebuild")
	} finally _KLRDC_Cleanup()
}
Test("KLR reader: pre-guard images cannot certify compensated bytes (klr-append-compensation)",
	_KLRDC_CheckTeardown.Bind(_KLRAC_RejectLegacyUnsafeCache))

_KLRAC_DiscardUnguardedReadAhead() {
	_KLRDC_EnsureSharedDir()
	_KLRDC_Reset()
	Reader := 0
	Control := 0
	try {
		_KLRDC_WriteLedger("abcd")
		Path := _KLRDC_LedgerPath()
		Reader := FileOpen(Path, "r", "UTF-8")
		Control := FileOpen(Path, "r", "UTF-8")
		Writer := FileOpen(Path, "w", "UTF-8-RAW")
		try Writer.Write("wxyz")
		finally Writer.Close()
		AssertEqual("abcd", Control.Read(), "positive control: FileOpen must have prefetched the old bytes")
		Result := KLR_ReadStableLedgerChunk(Reader, Path)
		AssertTrue(Result["ok"])
		AssertEqual("wxyz", Result["text"], "bytes buffered before the guard must be reread under it")
		Other := _KLRDC_Root() . "other.sql"
		FileAppend("other", Other, "UTF-8-RAW")
		AssertFalse(KLR_ReadStableLedgerChunk(Reader, Other)["ok"],
			"locking another file cannot certify this reader")
		AssertEqual(4, Reader.Pos, "identity refusal must not move the reader")
		AssertTrue(KL_AppendDataSqlDurable(Other, " released"),
			"identity refusal must release the guard")
	} finally {
		if IsObject(Control)
			Control.Close()
		if IsObject(Reader)
			Reader.Close()
		_KLRDC_Cleanup()
	}
}
Test("KLR reader: guarded copies discard earlier read-ahead and reject another file (klr-append-compensation)",
	_KLRDC_CheckTeardown.Bind(_KLRAC_DiscardUnguardedReadAhead))
