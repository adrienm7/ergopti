; tests/unit/test_keylogger_journal_native_write.ahk

; ==============================================================================
; MODULE: Keylogger Journal Native Receipt Tests
; DESCRIPTION:
; The real persistent writer must reject native write denial even when AHK's
; text buffer reports acceptance. Retry must leave each Unicode record once.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../support/filesystem_write_lock.ahk
#Include ../../modules/keylogger/keylogger_device.ahk
#Include ../../modules/keylogger/keylogger_journal_io.ahk

_KJNW_Receipt(Existing, Locked) {
	Saved := Map()
	for Name in ["today_log_path", "_today_fh", "_today_fh_date"] {
		if Keylogger.HasOwnProp(Name)
			Saved[Name] := Keylogger.%Name%
	}
	Path := _FSWL_Path()
	Lock := _FSWL_Lock()
	LockFile := 0
	Writer := 0
	Prefix := Existing ? "prior`n" : ""
	Line := '{"text":"é😀"}'
	try {
		Keylogger.today_log_path := Path
		Keylogger._today_fh := unset
		Keylogger._today_fh_date := ""
		if Existing
			FileAppend(Prefix, Path, "UTF-8")
		Writer := KL_OpenTodayFh()
		if Locked
			LockFile := Lock.Open(Path, "r", "UTF-8-RAW")
		Accepted := _KL_JournalAppendDefault(Writer, Line)
		AssertEqual(!Locked, Accepted, "journal acceptance must be an OS write receipt")
		if Locked {
			AssertTrue(Lock.Acquired)
			AssertEqual(Prefix, FileRead(Path, "UTF-8"))
			Lock.Release()
			AssertTrue(_KL_JournalAppendDefault(Writer, Line))
		}
		AssertTrue(KL_FlushTodayFh(Writer))
		AssertTrue(KL_CloseTodayFh())
		Writer := 0
		AssertEqual(Prefix . Line . "`n", FileRead(Path, "UTF-8"))
		AssertEqual(StrPut(Prefix . Line . "`n", "UTF-8") + 2, FileGetSize(Path),
			"one UTF-8 BOM and one complete newline-owned record must remain")
	} finally {
		; Flush any legacy AHK buffer while denial still holds, before unlocking.
		if IsObject(Writer)
			Writer.Close()
		Lock.Release()
		if IsObject(LockFile)
			LockFile.Close()
		for Name in ["today_log_path", "_today_fh", "_today_fh_date"] {
			if Saved.Has(Name)
				Keylogger.%Name% := Saved[Name]
			else
				Keylogger.%Name% := unset
		}
		if FileExist(Path)
			FileDelete(Path)
	}
}

for Existing in [false, true] {
	for Locked in [false, true]
		Test("keylogger: journal native receipt existing=" . Existing . " locked=" . Locked
			. " (keylogger-journal-native-write)", _KJNW_Receipt.Bind(Existing, Locked))
}

_KJNW_PersistentWriter(SameFile, UseAlias) {
	Saved := Map()
	for Name in ["today_log_path", "_today_fh", "_today_fh_date"] {
		if Keylogger.HasOwnProp(Name)
			Saved[Name] := Keylogger.%Name%
	}
	Path := _FSWL_Path()
	OtherPath := SameFile ? Path : _FSWL_Path()
	if UseAlias {
		SplitPath(Path, &LeafName, &ParentDir)
		OtherPath := ParentDir . "\.\" . LeafName
	}
	Writer := 0
	Other := 0
	Accepted := false
	OpenFailure := 0
	try {
		FileAppend("prior`n", Path, "UTF-8-RAW")
		if !SameFile
			FileAppend("other`n", OtherPath, "UTF-8-RAW")
		Keylogger.today_log_path := Path
		Keylogger._today_fh := unset
		Keylogger._today_fh_date := ""
		Writer := KL_OpenTodayFh()
		try Other := FileOpen(OtherPath, "a", "UTF-8-RAW")
		catch as Err
			OpenFailure := Err
		if IsObject(Other) {
			AssertTrue(_FSWriteUtf8Bytes(Other, "nested`n"))
			AssertTrue(FSFlushFileBuffers(Other))
			Accepted := true
			Other.Close()
			Other := 0
		}
		AssertTrue(_KL_JournalAppendDefault(Writer, "own"))
		AssertTrue(KL_FlushTodayFh(Writer))
		if Accepted
			AssertContains(FileRead(OtherPath, "UTF-8"), "nested`n",
				"a persistent journal position must not overwrite accepted competing bytes")
		AssertEqual(!SameFile, Accepted)
		AssertEqual(SameFile, OpenFailure is Error)
		AssertEqual("prior`nown`n", FileRead(Path, "UTF-8"),
			"readers must remain available while the journal handle stays open")
		AssertTrue(KL_CloseTodayFh())
		Writer := 0
		Other := FileOpen(Path, "a", "UTF-8-RAW")
		AssertTrue(_FSWriteUtf8Bytes(Other, "after-close`n"))
		AssertTrue(FSFlushFileBuffers(Other))
		Other.Close()
		Other := 0
		AssertEqual("prior`nown`nafter-close`n", FileRead(Path, "UTF-8"),
			"closing the persistent owner must release competing writers")
	} finally {
		if IsObject(Other)
			Other.Close()
		if IsObject(Writer)
			Writer.Close()
		for Name in ["today_log_path", "_today_fh", "_today_fh_date"] {
			if Saved.Has(Name)
				Keylogger.%Name% := Saved[Name]
			else
				Keylogger.%Name% := unset
		}
		if FileExist(Path)
			FileDelete(Path)
		if !SameFile && FileExist(OtherPath)
			FileDelete(OtherPath)
	}
}

for Options in [[true, false], [true, true], [false, false]]
	Test("keylogger: persistent writer ownership same-file=" . Options[1] . " alias=" . Options[2]
		. " (keylogger-journal-writer-ownership)", _KJNW_PersistentWriter.Bind(Options*))
