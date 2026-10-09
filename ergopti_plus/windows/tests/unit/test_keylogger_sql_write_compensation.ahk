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

_KDSC_MapPartialWrite(State, Path, Handle, Bytes, ByteCount, &Written) {
	Accepted := _FSNativeWrite(Handle, Bytes, 7, &Written)
	AssertEqual(7, Written, "the fixture must publish an actual incomplete SQL prefix")
	State.Reader := FileOpen(Path, "r", "UTF-8-RAW")
	State.Mapping := DllCall("CreateFileMappingW", "Ptr", State.Reader.Handle, "Ptr", 0,
		"UInt", 2, "UInt", 0, "UInt", 0, "Ptr", 0, "Ptr")
	AssertTrue(State.Mapping != 0)
	State.View := DllCall("MapViewOfFile", "Ptr", State.Mapping, "UInt", 4,
		"UInt", 0, "UInt", 0, "UPtr", 0, "Ptr")
	AssertTrue(State.View != 0)
	return Accepted
}

_KDSC_ReleaseMapping(State) {
	if State.View {
		AssertTrue(DllCall("UnmapViewOfFile", "Ptr", State.View, "Int") != 0)
		State.View := 0
	}
	if State.Mapping {
		AssertTrue(DllCall("CloseHandle", "Ptr", State.Mapping, "Int") != 0)
		State.Mapping := 0
	}
	if IsObject(State.Reader) {
		State.Reader.Close()
		State.Reader := 0
	}
}

_KDSC_RefusedTruncationRecovers(RetryWhileMapped) {
	Path := _FSWL_Path()
	Prefix := "-- prior`n"
	Body := "BEGIN; SELECT 'valid'; COMMIT;`n"
	State := {Reader: 0, Mapping: 0, View: 0}
	try {
		FileAppend(Prefix, Path, "UTF-8-RAW")
		Failure := 0
		try KL_AppendDataSqlDurable(Path, Body, 0, 0,
			_KDSC_MapPartialWrite.Bind(State, Path))
		catch as Err
			Failure := Err
		AssertTrue(Failure is Error)
		AssertContains(Failure.Message, "append rollback failed")
		AssertEqual(Prefix . SubStr(Body, 1, 7), FileRead(Path, "UTF-8"),
			"the native refusal must leave real bytes, not merely a failed flush receipt")
		if RetryWhileMapped {
			AssertThrows(() => KL_AppendDataSqlDurable(Path, Body),
				"an unresolved compensation must fence every successor append")
			AssertEqual(Prefix . SubStr(Body, 1, 7), FileRead(Path, "UTF-8"))
		}
		_KDSC_ReleaseMapping(State)
		AssertTrue(KL_AppendDataSqlDurable(Path, Body))
		AssertEqual(Prefix . Body, FileRead(Path, "UTF-8"),
			"retry must repair the old prefix before acknowledging exactly one complete batch")
	} finally {
		_KDSC_ReleaseMapping(State)
		_KDSC_ReleaseOwnedDebt(Path)
		if FileExist(Path)
			FileDelete(Path)
	}
}

for RetryWhileMapped in [false, true]
	Test("keylogger: SQL recovers native truncate refusal mapped-retry=" . RetryWhileMapped
		. " (keylogger-sql-repair-debt)", _KDSC_RefusedTruncationRecovers.Bind(RetryWhileMapped))

_KDSC_ReleaseOwnedDebt(Path) {
	global _KL_SQL_APPEND_DEBTS
	Key := StrLower(Path)
	if _KL_SQL_APPEND_DEBTS.Has(Key) {
		_KL_SQL_APPEND_DEBTS[Key].File.Close()
		_KL_SQL_APPEND_DEBTS.Delete(Key)
	}
}

_KDSC_ShutdownRepairsDebt() {
	Path := _FSWL_Path()
	State := {Reader: 0, Mapping: 0, View: 0}
	SavedPending := Keylogger._pending_entries
	SavedFlush := Keylogger._flush_in_progress
	try {
		Keylogger._pending_entries := []
		Keylogger._flush_in_progress := false
		FileAppend("prior", Path, "UTF-8-RAW")
		AssertThrows(() => KL_AppendDataSqlDurable(Path, "incomplete", 0, 0,
			_KDSC_MapPartialWrite.Bind(State, Path)))
		AssertFalse(KL_FlushShutdownReady(0, (*) => true),
			"an empty journal must not hide unrepaired SQL bytes")
		AssertEqual("priorincompl", FileRead(Path, "UTF-8"))
		_KDSC_ReleaseMapping(State)
		AssertTrue(KL_FlushShutdownReady(0, (*) => true))
		AssertEqual("prior", FileRead(Path, "UTF-8"),
			"quiet shutdown must repair without appending a replacement transaction")
		AssertTrue(KL_AppendDataSqlDurable(Path, "next"))
		AssertEqual("priornext", FileRead(Path, "UTF-8"))
	} finally {
		Keylogger._pending_entries := SavedPending
		Keylogger._flush_in_progress := SavedFlush
		_KDSC_ReleaseMapping(State)
		_KDSC_ReleaseOwnedDebt(Path)
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("keylogger: empty shutdown repairs SQL compensation (keylogger-sql-repair-debt)",
	_KDSC_ShutdownRepairsDebt)

_KDSC_ReentrantWrite(State, Handle, Bytes, ByteCount, &Written) {
	State.Shutdown := KL_DataSqlShutdownReady()
	return _FSNativeWrite(Handle, Bytes, ByteCount, &Written)
}

_KDSC_ActiveAppendRefusesShutdown() {
	global _KL_SQL_ACTIVE_APPENDS
	Path := _FSWL_Path()
	State := {Shutdown: true}
	try {
		AssertTrue(KL_AppendDataSqlDurable(Path, "complete", 0, 0,
			_KDSC_ReentrantWrite.Bind(State)))
		AssertFalse(State.Shutdown, "shutdown must refuse before the active write has a receipt")
		AssertEqual("complete", FileRead(Path, "UTF-8"))
		AssertEqual(0, _KL_SQL_ACTIVE_APPENDS)
		AssertTrue(KL_DataSqlShutdownReady())
	} finally {
		_KDSC_ReleaseOwnedDebt(Path)
		if FileExist(Path)
			FileDelete(Path)
	}
}
Test("keylogger: active SQL append refuses shutdown (keylogger-sql-repair-debt)",
	_KDSC_ActiveAppendRefusesShutdown)

_KDSC_RepairFlush(State, Path, Fh) {
	State.Calls += 1
	State.Critical := A_IsCritical
	State.Shutdown := KL_DataSqlShutdownReady()
	AssertThrows(() => KL_AppendDataSqlDurable(Path, "nested"),
		"a nested writer must not steal the active repair claim")
	return false
}

_KDSC_RepairFlushRefusalRetainsOwnership(InheritCritical) {
	global _KL_SQL_ACTIVE_APPENDS
	Path := _FSWL_Path()
	Mapping := {Reader: 0, Mapping: 0, View: 0}
	State := {Calls: 0, Shutdown: true, Critical: -1}
	try {
		FileAppend("prior", Path, "UTF-8-RAW")
		AssertThrows(() => KL_AppendDataSqlDurable(Path, "incomplete", 0, 0,
			_KDSC_MapPartialWrite.Bind(Mapping, Path)))
		_KDSC_ReleaseMapping(Mapping)
		PreviousCritical := Critical(InheritCritical ? "On" : "Off")
		try {
			CallerCritical := A_IsCritical
			AssertThrows(() => KL_AppendDataSqlDurable(Path, "next", 0,
				_KDSC_RepairFlush.Bind(State, Path)))
			AssertEqual(CallerCritical, A_IsCritical, "repair must restore its caller's Critical mode")
		} finally {
			Critical(PreviousCritical)
		}
		AssertEqual(1, State.Calls, "no replacement batch may flush after an unproved repair")
		AssertEqual(0, State.Critical, "repair must perform native I/O outside inherited Critical")
		AssertFalse(State.Shutdown)
		AssertEqual(0, _KL_SQL_ACTIVE_APPENDS, "nested refusal must release both active scopes")
		AssertEqual("prior", FileRead(Path, "UTF-8"))
		AssertTrue(KL_AppendDataSqlDurable(Path, "next"))
		AssertEqual("priornext", FileRead(Path, "UTF-8"))
	} finally {
		_KDSC_ReleaseMapping(Mapping)
		_KDSC_ReleaseOwnedDebt(Path)
		if FileExist(Path)
			FileDelete(Path)
	}
}
for InheritCritical in [false, true]
	Test("keylogger: refused repair flush retains SQL owner critical=" . InheritCritical
		. " (keylogger-sql-repair-debt sql-repair-critical)",
		_KDSC_RepairFlushRefusalRetainsOwnership.Bind(InheritCritical))

_KDSC_RepairPreservesReplacement() {
	Path := _FSWL_Path()
	MovedPath := Path . ".displaced"
	Mapping := {Reader: 0, Mapping: 0, View: 0}
	try {
		FileAppend("prior", Path, "UTF-8-RAW")
		AssertThrows(() => KL_AppendDataSqlDurable(Path, "incomplete", 0, 0,
			_KDSC_MapPartialWrite.Bind(Mapping, Path)))
		_KDSC_ReleaseMapping(Mapping)
		FileMove(Path, MovedPath)
		FileAppend("replacement", Path, "UTF-8-RAW")
		AssertTrue(KL_AppendDataSqlDurable(Path, "next"))
		AssertEqual("prior", FileRead(MovedPath, "UTF-8"),
			"repair must truncate the displaced native owner")
		AssertEqual("replacementnext", FileRead(Path, "UTF-8"),
			"a replacement pathname must not inherit another file's repair boundary")
	} finally {
		_KDSC_ReleaseMapping(Mapping)
		_KDSC_ReleaseOwnedDebt(Path)
		for OwnedPath in [Path, MovedPath] {
			if FileExist(OwnedPath)
				FileDelete(OwnedPath)
		}
	}
}
Test("keylogger: SQL repair preserves replacement file (keylogger-sql-repair-debt)",
	_KDSC_RepairPreservesReplacement)

_KDSC_ReplaceDuringWrite(State, Path, MovedPath, Handle, Bytes, ByteCount, &Written) {
	FileMove(Path, MovedPath)
	FileAppend("replacement", Path, "UTF-8-RAW")
	try KL_AppendDataSqlDurable(Path, "nested-incomplete", 0, 0,
		_KDSC_MapPartialWrite.Bind(State.Nested, Path))
	catch as Err
		State.NestedFailure := Err
	return _KDSC_MapPartialWrite(State.Outer, MovedPath, Handle, Bytes, ByteCount, &Written)
}

_KDSC_ReplacementCannotStealDebt() {
	Path := _FSWL_Path()
	MovedPath := Path . ".displaced"
	State := {Outer: {Reader: 0, Mapping: 0, View: 0},
		Nested: {Reader: 0, Mapping: 0, View: 0}, NestedFailure: 0}
	try {
		FileAppend("prior", Path, "UTF-8-RAW")
		AssertThrows(() => KL_AppendDataSqlDurable(Path, "incomplete", 0, 0,
			_KDSC_ReplaceDuringWrite.Bind(State, Path, MovedPath)))
		AssertTrue(State.NestedFailure is Error)
		AssertContains(State.NestedFailure.Message, "active owner")
		AssertEqual("replacement", FileRead(Path, "UTF-8"),
			"replacement writes must wait for the original logical path owner")
		AssertEqual("priorincompl", FileRead(MovedPath, "UTF-8"))
		_KDSC_ReleaseMapping(State.Outer)
		AssertTrue(KL_DataSqlShutdownReady())
		AssertEqual("prior", FileRead(MovedPath, "UTF-8"))
		AssertEqual("replacement", FileRead(Path, "UTF-8"))
	} finally {
		_KDSC_ReleaseMapping(State.Outer)
		_KDSC_ReleaseMapping(State.Nested)
		_KDSC_ReleaseOwnedDebt(Path)
		for OwnedPath in [Path, MovedPath] {
			if FileExist(OwnedPath)
				FileDelete(OwnedPath)
		}
	}
}
Test("keylogger: SQL replacement cannot steal repair ownership (keylogger-sql-repair-debt)",
	_KDSC_ReplacementCannotStealDebt)
