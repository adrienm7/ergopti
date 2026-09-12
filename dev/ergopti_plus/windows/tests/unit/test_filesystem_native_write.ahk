; tests/unit/test_filesystem_native_write.ahk

; ==============================================================================
; MODULE: Filesystem Native Write Outcome Tests
; DESCRIPTION:
; Exercise real Windows write denial and healthy UTF-8 controls through every
; adapter writer. A successful text-buffer append is not a successful OS write.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../support/filesystem_write_lock.ahk

_FSNW_Outcome(Mode, Locked) {
	Path := _FSWL_Path()
	Lock := _FSWL_Lock()
	State := Map("flushes", 0)
	Content := "étoile😀`nline"
	OpenFn := Locked ? ObjBindMethod(Lock, "Open") : FileOpen
	FlushFn := (File) => (State["flushes"] += 1, FSFlushFileBuffers(File))
	try {
		if Mode = "append"
			FileAppend("prior:", Path, "UTF-8-RAW")
		switch Mode {
			case "write": Result := FSWrite(Path, Content, OpenFn)
			case "durable": Result := FSWriteDurable(Path, Content, OpenFn, 0, FlushFn)
			case "append": Result := _FSAppendComplete(Path, Content, OpenFn)
		}
		Lock.Release()
		AssertEqual(Locked, Lock.Acquired, "the denial must come from an acquired native lock")
		AssertEqual(!Locked, Result, "buffer acceptance must not report a successful native write")
		if Mode = "durable"
			AssertEqual(Locked ? 0 : 1, State["flushes"], "never flush a rejected write")
		if Locked && Mode != "append"
			AssertFalse(FileExist(Path), "an incomplete owned overwrite must be removed")
		else {
			Expected := (Mode = "append" ? "prior:" : "") . (Locked ? "" : Content)
			AssertEqual(Expected, FileRead(Path, "UTF-8-RAW"))
			AssertEqual(StrPut(Expected, "UTF-8") - 1, FileGetSize(Path), "no BOM or terminator may be added")
		}
	} finally {
		Lock.Release()
		if FileExist(Path)
			FileDelete(Path)
	}
}

for Mode in ["write", "durable", "append"] {
	Test("filesystem: native denial " . Mode . " (filesystem-native-write)", _FSNW_Outcome.Bind(Mode, true))
	Test("filesystem: native UTF-8 control " . Mode . " (filesystem-native-write)", _FSNW_Outcome.Bind(Mode, false))
}

_FSNW_AppendEncoding(Encoding) {
	Path := _FSWL_Path()
	try {
		FileAppend("prior:", Path, Encoding)
		Before := FileRead(Path, "RAW")
		Accepted := FSAppend(Path, "é😀")
		if Encoding = "UTF-16" {
			AssertFalse(Accepted, "an existing UTF-16 file must not receive UTF-8 bytes")
			After := FileRead(Path, "RAW")
			AssertEqual(Before.Size, After.Size)
			AssertEqual(Before.Size, DllCall("ntdll\RtlCompareMemory",
				"Ptr", Before, "Ptr", After, "UPtr", Before.Size, "UPtr"))
		} else {
			AssertTrue(Accepted)
			AssertEqual("prior:é😀", FileRead(Path, "UTF-8"))
			AssertEqual(Before.Size + StrPut("é😀", "UTF-8") - 1, FileGetSize(Path),
				"appending must not introduce a second BOM or a terminator")
		}
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}

for Encoding in ["UTF-16", "UTF-8", "UTF-8-RAW"]
	Test("filesystem: append encoding " . Encoding . " (filesystem-native-write)", _FSNW_AppendEncoding.Bind(Encoding))

_FSNW_Empty(Mode) {
	Path := _FSWL_Path()
	State := Map("flushes", 0)
	FlushFn := (File) => (State["flushes"] += 1, FSFlushFileBuffers(File))
	try {
		if Mode = "append"
			FileAppend("prior:", Path, "UTF-8-RAW")
		switch Mode {
			case "write": Accepted := FSWrite(Path, "")
			case "durable": Accepted := FSWriteDurable(Path, "", 0, 0, FlushFn)
			case "append": Accepted := FSAppend(Path, "")
		}
		AssertTrue(Accepted, "an empty UTF-8 artifact is a complete write")
		AssertEqual(Mode = "append" ? "prior:" : "", FileRead(Path, "UTF-8-RAW"))
		AssertEqual(Mode = "append" ? 6 : 0, FileGetSize(Path))
		AssertEqual(Mode = "durable" ? 1 : 0, State["flushes"])
	} finally {
		if FileExist(Path)
			FileDelete(Path)
	}
}

for Mode in ["write", "durable", "append"]
	Test("filesystem: empty native " . Mode . " (filesystem-native-write)", _FSNW_Empty.Bind(Mode))
