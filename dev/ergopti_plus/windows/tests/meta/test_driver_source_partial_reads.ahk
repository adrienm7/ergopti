; tests/meta/test_driver_source_partial_reads.ahk

; ==============================================================================
; MODULE: Driver Source Partial Read Tests
; DESCRIPTION: Isolated native locks must not produce or cache incomplete source.
; ==============================================================================

#Requires AutoHotkey v2.0

_DSPR_Child(Mode, Receipt) {
	SplitPath(A_ScriptDir, , &Root)
	Handle := -1
	try {
		Handle := DllCall("kernel32\CreateFileW", "Str", Root . "\sample\locked.ahk",
			"UInt", 0x80000000, "UInt", 0, "Ptr", 0, "UInt", 3, "UInt", 0, "Ptr", 0, "Ptr")
		AssertTrue(Handle != -1, "the child must hold the source's exclusive native lock")
		ReadSource := Mode = "directory" ? _DriverDirConcat.Bind("sample") : _DriverSourceConcat
		Failure := 0
		try ReadSource.Call()
		catch OSError as Err
			Failure := Err
		DllCall("kernel32\CloseHandle", "Ptr", Handle)
		Handle := -1
		Complete := ReadSource.Call()
		AssertContains(Complete, "ReadableSourceMarker", "the control source must be present")
		AssertContains(Complete, "LockedSourceMarker", "retry must not reuse a partially populated source cache")
		AssertTrue(Failure is OSError, "a locked source must fail the initial scan even when siblings are readable")
		FileAppend("complete", Receipt, "UTF-8-RAW")
	} catch Error as Err {
		FileAppend(Err.Message . "`n" . Err.Stack, Receipt, "UTF-8-RAW")
		ExitApp(1)
	} finally {
		if Handle != -1
			DllCall("kernel32\CloseHandle", "Ptr", Handle)
	}
	ExitApp(0)
}

_DSPR_IsolatedRead(Mode) {
	Root := A_Temp . "\ergopti_source_" . A_ScriptHwnd . "_" . A_TickCount
	AssertTrue(DllCall("kernel32\CreateDirectoryW", "Str", Root, "Ptr", 0, "Int"),
		"the parent must exclusively acquire the fixture root")
	try {
		DirCreate(Root . "\sample")
		DirCreate(Root . "\tests")
		FileAppend("ReadableSourceMarker() {`nreturn 1`n}`n", Root . "\sample\readable.ahk", "UTF-8")
		FileAppend("LockedSourceMarker() {`nreturn 2`n}`n", Root . "\sample\locked.ahk", "UTF-8")
		Launcher := Root . "\tests\probe.ahk"
		Receipt := Root . "\result.txt"
		; The real framework runs with an isolated A_ScriptDir and a fresh cache.
		; Include this fixture's definitions without running its registered tests.
		FileAppend("#Requires AutoHotkey v2.0`n#SingleInstance Off`n"
			. "#Include " . A_ScriptDir . "\test_framework.ahk`n"
			. "#Include " . A_LineFile . "`n"
			. "_DSPR_Child(A_Args[1], A_Args[2])`n", Launcher, "UTF-8")
		Code := RunWait('"' . A_AhkPath . '" /ErrorStdOut "' . Launcher . '" "'
			. Mode . '" "' . Receipt . '"', , "Hide")
		AssertTrue(FileExist(Receipt), "the child must report its outcome; exit=" . Code)
		Result := FileRead(Receipt, "UTF-8")
		AssertEqual(0, Code, Result)
		AssertEqual("complete", Result)
	} finally DirDelete(Root, true)
}
Test("source readers: full scan rejects partial reads and retries without stale cache (source-reader-partial)",
	_DSPR_IsolatedRead.Bind("whole"))
Test("source readers: directory scan rejects a locked sibling (source-reader-partial)",
	_DSPR_IsolatedRead.Bind("directory"))
