; tests/unit/adapters/test_filesystem_nul_paths.ahk

; ==============================================================================
; MODULE: FileSystem NUL Path Refusal Tests
; DESCRIPTION:
; Windows path APIs read a caller String only up to its first NUL code unit,
; so "prefix.txt" NUL "suffix" names prefix.txt. Measured on AutoHotkey 2.0:
; FileDelete removed the prefix file, FileOpen returned its bytes and FileExist
; reported it present. Every FileSystem adapter entry that hands a caller path
; to Windows must refuse such a path before any native call, leaving the prefix
; file, the prefix directory and the destination untouched.
; ==============================================================================

#Requires AutoHotkey v2.0

_FSNUL_Root() {
	Root := A_Temp . "\ergopti_fs_nul_" . DllCall("GetCurrentProcessId") . "_" . A_TickCount
	AssertFalse(DirExist(Root), "the NUL path fixture must own a new private directory")
	DirCreate(Root)
	return Root
}

_FSNUL_Seed(Root) {
	for Name in ["prefix.txt", "source.txt"] {
		Path := Root . "\" . Name
		if FileExist(Path)
			FileDelete(Path)
		FileAppend(Name == "prefix.txt" ? "prefix-bytes" : "source-bytes", Path, "UTF-8-RAW")
	}
	for Name in ["created.txt", "created.txt.ergopti-restore.tmp"]
		if FileExist(Root . "\" . Name)
			FileDelete(Root . "\" . Name)
	if DirExist(Root . "\made")
		DirDelete(Root . "\made", true)
}

; Runs one adapter call and returns its value, or the sentinel "<thrown>".
; A File object or guard handle obtained by an unguarded build is released here
; so a red run cannot leak a handle into the following cases.
_FSNUL_Invoke(Call) {
	try Result := Call.Call()
	catch
		return "<thrown>"
	if IsObject(Result) && HasMethod(Result, "Close")
		Result.Close()
	return Result
}

_FSNUL_Case(Root, Name, Call, Expected) {
	_FSNUL_Seed(Root)
	Result := _FSNUL_Invoke(Call)
	if IsObject(Expected) {
		AssertTrue(Result is Map && Result.Get("ok", true) == false, Name . " must refuse a NUL path")
	} else {
		if Expected == "<thrown>" && Result is Integer && Result > 0 && Name == "FSOpenExclusiveGuard"
			FSCloseExclusiveGuard(Result)
		AssertEqual(Expected, Result is String || Result is Integer ? Result : Type(Result),
			Name . " must refuse a NUL path before any native call")
	}
	AssertEqual("prefix-bytes", FileRead(Root . "\prefix.txt", "UTF-8-RAW"),
		Name . " must leave the prefix file byte-identical")
	AssertEqual("source-bytes", FileRead(Root . "\source.txt", "UTF-8-RAW"),
		Name . " must leave a valid source file in place")
	AssertFalse(FileExist(Root . "\created.txt"), Name . " must not create the prefix destination")
	AssertFalse(DirExist(Root . "\made"), Name . " must not create the prefix directory")
}

_FSNUL_EveryEntryRefuses() {
	Root := _FSNUL_Root()
	try {
		Nul := Root . "\prefix.txt" . Chr(0) . ".suffix"
		Source := Root . "\source.txt"
		AbsentNul := Root . "\created.txt" . Chr(0) . ".suffix"
		DirNul := Root . "\made" . Chr(0) . "suffix"
		RootNul := Root . Chr(0) . "suffix"
		Refused := Map()
		Cases := [
			["FSRead", FSRead.Bind(Nul), false],
			["FSWrite", FSWrite.Bind(Nul, "replacement"), false],
			["FSAppend", FSAppend.Bind(Nul, "appended"), false],
			["FSExists", FSExists.Bind(Nul), false],
			["FSDelete", FSDelete.Bind(Nul), false],
			["FSWriteDurable", FSWriteDurable.Bind(Nul, "replacement"), false],
			["FSWriteCreateDurable", FSWriteCreateDurable.Bind(AbsentNul, "created"), 0],
			["FSStrictExists", FSStrictExists.Bind(Nul), "<thrown>"],
			["FSDeleteStrict", FSDeleteStrict.Bind(Nul), "<thrown>"],
			["FSDeleteVerified", FSDeleteVerified.Bind(Nul, (*) => true), false],
			["FSReadBounded", FSReadBounded.Bind(Nul, 64), false],
			["FSReadUtf8Exact", FSReadUtf8Exact.Bind(Nul), false],
			["FSReadUtf8ExactBounded", FSReadUtf8ExactBounded.Bind(Nul, 64), false],
			["FSConfigReadUtf8Exact", FSConfigReadUtf8Exact.Bind(Nul), false],
			["FSSize", FSSize.Bind(Nul), -1],
			["FSOpenRead", FSOpenRead.Bind(Nul), ""],
			["FSOpenWrite", FSOpenWrite.Bind(Nul), ""],
			["FSMove source", FSMove.Bind(Nul, Root . "\created.txt"), false],
			["FSMove destination", FSMove.Bind(Source, AbsentNul), false],
			["FSAtomicMoveReplace", FSAtomicMoveReplace.Bind(Source, Nul), false],
			["FSAtomicMoveCreate", FSAtomicMoveCreate.Bind(Source, AbsentNul), 0],
			["FSCopyCreateVerified", FSCopyCreateVerified.Bind(Nul, Root . "\created.txt"), false],
			["FSCopyReplaceAtomic", FSCopyReplaceAtomic.Bind(Source, Nul), false],
			["FSSameBytes", FSSameBytes.Bind(Nul, Root . "\prefix.txt"), false],
			["FSReadStrict", FSReadStrict.Bind(Nul), "<thrown>"],
			["FSReadBytesStrict", FSReadBytesStrict.Bind(Nul), "<thrown>"],
			["FSOpenStrict", FSOpenStrict.Bind(Nul, "r"), "<thrown>"],
			["FSOpenReadStrict", FSOpenReadStrict.Bind(Nul), "<thrown>"],
			["FSOpenExclusiveGuard", FSOpenExclusiveGuard.Bind(Nul), "<thrown>"],
			["FSCreateDirectoryExclusiveStrict", FSCreateDirectoryExclusiveStrict.Bind(DirNul), "<thrown>"],
			["FSEnsureDirectoryStrict", FSEnsureDirectoryStrict.Bind(DirNul), "<thrown>"],
			["FSListDirectoryStrict", FSListDirectoryStrict.Bind(RootNul), "<thrown>"],
			["FSResolveDirectoryPath", FSResolveDirectoryPath.Bind(RootNul), "<thrown>"],
			["FSReadRange", FSReadRange.Bind(Nul, 0, 6), Map("ok", false)]
		]
		; Run every entry before failing so one red run names the complete class.
		Failures := []
		for Entry in Cases {
			AssertFalse(Refused.Has(Entry[1]), "each adapter entry is listed once: " . Entry[1])
			Refused[Entry[1]] := true
			try _FSNUL_Case(Root, Entry[1], Entry[2], Entry[3])
			catch as Err
				Failures.Push(Err.Message)
		}
		AssertEqual(34, Refused.Count, "every path-taking FileSystem adapter entry must be exercised")
		Report := ""
		for Message in Failures
			Report .= (Report == "" ? "" : " | ") . Message
		AssertEqual(0, Failures.Length, Failures.Length . " of 34 entries accepted a NUL path: " . Report)
	} finally DirDelete(Root, true)
}
Test("FileSystem: every adapter entry refuses a NUL path without touching its prefix (fs-nul-path)",
	_FSNUL_EveryEntryRefuses)

; Healthy control: the guard is about NUL only, so literal Unicode, spaces and
; punctuation that Windows accepts in a file name keep working end to end.
_FSNUL_LiteralNamesStillWork() {
	Root := _FSNUL_Root()
	try {
		Path := Root . "\é ü (1) [x] {y} ~ +.txt"
		AssertTrue(FSWrite(Path, "first"), "a NUL-free Unicode path must be writable")
		AssertTrue(FSAppend(Path, "+second"), "a NUL-free Unicode path must be appendable")
		AssertTrue(FSExists(Path), "a NUL-free Unicode path must exist after writing")
		AssertEqual("first+second", FSRead(Path), "a NUL-free Unicode path must read back exactly")
		AssertEqual(12, FSSize(Path), "a NUL-free Unicode path must report its byte length")
		AssertTrue(FSDelete(Path), "a NUL-free Unicode path must be deletable")
		AssertFalse(FileExist(Path), "the deleted control file must be gone")
	} finally DirDelete(Root, true)
}
Test("FileSystem: literal Unicode and punctuation paths still round-trip (fs-nul-path)",
	_FSNUL_LiteralNamesStillWork)
