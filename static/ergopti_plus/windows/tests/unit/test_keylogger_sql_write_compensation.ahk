; tests/unit/test_keylogger_sql_write_compensation.ahk

; ==============================================================================
; MODULE: Keylogger SQL Write Compensation Tests
; DESCRIPTION:
; Native prefixes and rejected durable fences must retract unacknowledged SQL
; before a retry, including a new-file BOM. No keylogger hooks are installed.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../support/filesystem_write_lock.ahk
#Include ../../modules/keylogger/keylogger_sql_append.ahk

_KDSC_Prefix(State, Handle, Bytes, ByteCount, &Written) {
	Accepted := _FSNativeWrite(Handle, Bytes, State["prefix"], &Written)
	State["written"] := Written
	return Accepted
}

_KDSC_Flush(State, FileObject) {
	State["lengths"].Push(FileObject.Length)
	if State["fail_flush"] && State["lengths"].Length = 1
		return false
	return FSFlushFileBuffers(FileObject)
}

_KDSC_Retry(Existing, FailFlush) {
	Path := _FSWL_Path()
	Prefix := Existing ? "-- prior`n" : ""
	Body := "BEGIN; SELECT 'é😀'; COMMIT;`n"
	State := Map("prefix", Existing ? 9 : 1, "written", 0,
		"lengths", [], "fail_flush", FailFlush)
	WriteFn := FailFlush ? 0 : _KDSC_Prefix.Bind(State)
	try {
		if Existing
			FileAppend(Prefix, Path, "UTF-8")
		Failure := 0
		try KL_AppendDataSqlDurable(Path, Body, 0, _KDSC_Flush.Bind(State), WriteFn)
		catch as Err
			Failure := Err
		AssertTrue(Failure is Error)
		AssertContains(Failure.Message, FailFlush ? "stable-storage flush failed" : "append was incomplete")
		Boundary := Existing ? StrPut(Prefix, "UTF-8") + 2 : 0
		AssertEqual(Boundary, FileGetSize(Path))
		AssertEqual(Prefix, FileRead(Path, "UTF-8"))
		AssertEqual(FailFlush ? 2 : 1, State["lengths"].Length)
		AssertEqual(Boundary, State["lengths"][-1], "compensation must durably restore the exact initial boundary")
		if FailFlush
			AssertEqual(StrPut(Prefix . Body, "UTF-8") + 2, State["lengths"][1], "the refused fence must follow actual complete bytes")
		else
			AssertEqual(State["prefix"], State["written"], "the test must write a real native prefix")
		AssertTrue(KL_AppendDataSqlDurable(Path, Body))
		AssertEqual(Prefix . Body, FileRead(Path, "UTF-8"))
		AssertEqual(StrPut(Prefix . Body, "UTF-8") + 2, FileGetSize(Path))
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}

for Existing in [false, true] {
	for FailFlush in [false, true]
		Test("keylogger: SQL compensation existing=" . Existing . " flush=" . FailFlush
			. " (keylogger-sql-native-write)", _KDSC_Retry.Bind(Existing, FailFlush))
}

_KDSC_CompetingFlush(State, NestedPath, FileObject) {
	State.Calls += 1
	if State.Calls != 1
		return FSFlushFileBuffers(FileObject)
	try State.Accepted := KL_AppendDataSqlDurable(NestedPath, "nested")
	catch as Err
		State.Failure := Err
	State.During := FileRead(NestedPath, "UTF-8")
	return false
}

_KDSC_CompetingWriter(SameFile, UseAlias) {
	Path := _FSWL_Path()
	NestedPath := SameFile ? Path : _FSWL_Path()
	if UseAlias {
		SplitPath(Path, &LeafName, &ParentDir)
		NestedPath := ParentDir . "\.\" . LeafName
	}
	State := {Calls: 0, Accepted: false, Failure: 0, During: ""}
	try {
		FileAppend("prior", Path, "UTF-8-RAW")
		if !SameFile
			FileAppend("other", NestedPath, "UTF-8-RAW")
		Failure := 0
		try KL_AppendDataSqlDurable(Path, "outer", 0,
			_KDSC_CompetingFlush.Bind(State, NestedPath))
		catch as Err
			Failure := Err
		AssertTrue(Failure is Error)
		AssertContains(Failure.Message, "stable-storage flush failed")
		AssertEqual(2, State.Calls, "the refused append and compensation both cross a flush boundary")
		if State.Accepted
			AssertContains(FileRead(NestedPath, "UTF-8"), "nested",
				"SQL compensation must preserve a competing writer's accepted bytes")
		AssertEqual(!SameFile, State.Accepted)
		AssertEqual(SameFile, State.Failure is Error)
		AssertEqual(SameFile ? "priorouter" : "othernested", State.During,
			"readers must remain available while the outer SQL writer owns compensation")
		AssertEqual("prior", FileRead(Path, "UTF-8"))
		AssertTrue(KL_AppendDataSqlDurable(Path, "retry"))
		AssertEqual("priorretry", FileRead(Path, "UTF-8"))
	} finally {
		if FileExist(Path)
			FileDelete(Path)
		if !SameFile && FileExist(NestedPath)
			FileDelete(NestedPath)
	}
}

for Options in [[true, false], [true, true], [false, false]]
	Test("keylogger: SQL writer ownership same-file=" . Options[1] . " alias=" . Options[2]
		. " (keylogger-sql-writer-ownership)", _KDSC_CompetingWriter.Bind(Options*))
