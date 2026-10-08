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

; Native rename failures report their immediate Win32 receipt without retrying.
_FSNW_AtomicMoveReceipt(Mode) {
	RootPath := _FSWL_Path() . ".dir"
	FSCreateDirectoryExclusiveStrict(RootPath)
	SourcePath := RootPath . "\source.tmp"
	TargetPath := RootPath . "\target.toml"
	try {
		FileAppend("old destination", TargetPath, "UTF-8-RAW")
		if Mode != "missing-source"
			FileAppend("é😀 new bytes", SourcePath, "UTF-8-RAW")
		NativeError := 1234
		DllCall("kernel32\SetLastError", "UInt", 1234)
		switch Mode {
			case "missing-parent":
				Accepted := FSAtomicMoveReplace(SourcePath, RootPath . "\absent\target.toml", &NativeError)
				AssertFalse(Accepted)
				AssertEqual(3, NativeError, "missing destination parent reports ERROR_PATH_NOT_FOUND")
			case "missing-source":
				Accepted := FSAtomicMoveReplace(SourcePath, TargetPath, &NativeError)
				AssertFalse(Accepted)
				AssertEqual(2, NativeError, "missing source reports ERROR_FILE_NOT_FOUND")
			case "success":
				Accepted := FSAtomicMoveReplace(SourcePath, TargetPath, &NativeError)
				AssertTrue(Accepted)
				AssertEqual(0, NativeError, "a successful rename resets an unrelated prior error")
				AssertFalse(FileExist(SourcePath), "the successfully published stage is consumed")
				AssertEqual("é😀 new bytes", FileRead(TargetPath, "UTF-8-RAW"))
				AssertEqual(StrPut("é😀 new bytes", "UTF-8") - 1, FileGetSize(TargetPath))
				FileAppend("two-argument control", SourcePath, "UTF-8-RAW")
				AssertTrue(FSAtomicMoveReplace(SourcePath, TargetPath), "existing two-argument callers remain valid")
				AssertEqual("two-argument control", FileRead(TargetPath, "UTF-8-RAW"))
			case "invalid":
				for InvalidPath in ["", 0, Map()] {
					NativeError := 1234
					AssertFalse(FSAtomicMoveReplace(InvalidPath, TargetPath, &NativeError))
					AssertEqual(0, NativeError, "invalid source has no native error receipt")
					NativeError := 1234
					AssertFalse(FSAtomicMoveReplace(SourcePath, InvalidPath, &NativeError))
					AssertEqual(0, NativeError, "invalid destination has no native error receipt")
				}
		}
		if Mode != "success" {
			AssertEqual("old destination", FileRead(TargetPath, "UTF-8-RAW"), "refusal preserves the independent destination")
			if Mode != "missing-source"
				AssertEqual("é😀 new bytes", FileRead(SourcePath, "UTF-8-RAW"), "refusal preserves the source stage")
		}
	} finally {
		if FileExist(SourcePath)
			FileDelete(SourcePath)
		if FileExist(TargetPath)
			FileDelete(TargetPath)
		DirDelete(RootPath)
	}
}

for Mode in ["missing-parent", "missing-source", "success", "invalid"]
	Test("filesystem: atomic move receipt " . Mode . " (filesystem-native-write)", _FSNW_AtomicMoveReceipt.Bind(Mode))


_FSNativeGuardRetainsActualStage(Status) {
	Root := A_Temp . "\ergopti-final-admission-" . A_TickCount . "-" . Random(1, 999999)
	DirCreate(Root)
	Stage := Root . "\stage.tmp", Target := Root . "\target.toml"
	try {
		AssertTrue(FSWriteDurable(Stage, "candidate`n"))
		AssertTrue(FSWriteDurable(Target, "original`n"))
		PreviousCritical := A_IsCritical
		AssertFalse(FSAtomicMoveReplace(Stage, Target, &NativeError, () => Status))
		AssertEqual(995, NativeError, "strict native admission refuses before MoveFileExW")
		AssertEqual(PreviousCritical, A_IsCritical)
		AssertTrue(FSUtf8ExactMatches(Stage, "candidate`n"), "native refusal retains the actual owned stage")
		AssertTrue(FSUtf8ExactMatches(Target, "original`n"), "native refusal retains complete actual target bytes")
		AssertFalse(FSNativeAcknowledge(() => Status))
		AssertEqual(PreviousCritical, A_IsCritical)
	} finally DirDelete(Root, true)
}
Test("filesystem native guard: integer zero refuses actual rename and noop", _FSNativeGuardRetainsActualStage.Bind(0))
Test("filesystem native guard: integer two refuses actual rename and noop", _FSNativeGuardRetainsActualStage.Bind(2))
Test("filesystem native guard: string one refuses actual rename and noop", _FSNativeGuardRetainsActualStage.Bind("1"))

_FSNativeGuardExceptionRestoresInterruption() {
	OriginalCritical := A_IsCritical
	Throwing() {
		throw Error("independent native admission refusal")
	}
	try {
		Critical(17)
		AssertFalse(FSNativeAcknowledge(Throwing))
		AssertEqual(17, A_IsCritical, "the actual noop span restores inherited interruption state")
	} finally Critical(OriginalCritical)
}
Test("filesystem native guard: exceptions refuse and restore native interruption state", _FSNativeGuardExceptionRestoresInterruption)

_FSNativeGuardActuallyPublishes() {
	Root := A_Temp . "\ergopti-final-admission-positive-" . A_TickCount . "-" . Random(1, 999999)
	DirCreate(Root)
	Stage := Root . "\stage.tmp", Target := Root . "\target.toml"
	Checks := 0, GuardCritical := 0
	Guard() {
		Checks += 1
		GuardCritical := A_IsCritical
		return 1
	}
	try {
		AssertTrue(FSWriteDurable(Stage, "candidate`n"))
		AssertTrue(FSWriteDurable(Target, "original`n"))
		OriginalCritical := A_IsCritical
		AssertTrue(FSAtomicMoveReplace(Stage, Target, &NativeError, Guard))
		AssertEqual(1, Checks)
		AssertTrue(GuardCritical > 0, "the accepted guard runs in the same actual native rename span")
		AssertEqual(OriginalCritical, A_IsCritical)
		AssertFalse(FileExist(Stage))
		AssertTrue(FSUtf8ExactMatches(Target, "candidate`n"))
		AssertTrue(FSNativeAcknowledge(Guard))
		AssertEqual(2, Checks)
	} finally DirDelete(Root, true)
}
Test("filesystem native guard: actual acknowledged rename consumes the verified stage", _FSNativeGuardActuallyPublishes)
