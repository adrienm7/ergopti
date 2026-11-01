; tests/unit/platform/network/test_curl_start_check.ahk

; ==============================================================================
; MODULE: System curl Start Check
; DESCRIPTION:
; The owned-runtimes decision (SYS): the driver keeps System32 curl.exe, checks it
; at start and names its absence or an unusable version in words, not with each
; local AI request's bare refusal.
; ==============================================================================

#Requires AutoHotkey v2.0

_CSC_Value(Value, *) {
	return Value
}

_CSC_Missing(Path) {
	throw OSError("The system cannot find the file specified.", -1, Path)
}

_CSC_Record(Notices, Text) {
	Notices.Push(Text)
}

_CSC_Check() {
	global HTTP_CURL_RUNTIME_LIMIT_MIN_VERSION
	Notices := []
	Notice := _CSC_Record.Bind(Notices)
	for Version in [HTTP_CURL_RUNTIME_LIMIT_MIN_VERSION, "8.21.0", "10.0.0.1"]
		AssertTrue(HTTP_CheckCurlAtStart(_CSC_Value.Bind(Version), Notice), Version . " is usable")
	AssertEqual(0, Notices.Length, "a usable version says nothing")

	AssertFalse(HTTP_CheckCurlAtStart(_CSC_Value.Bind("7.55.1"), Notice), "7.55.1 is refused")
	AssertEqual(1, Notices.Length, "the refusal speaks")
	AssertContains(Notices[1], "7.55.1", "it names the version found")
	AssertContains(Notices[1], HTTP_CURL_RUNTIME_LIMIT_MIN_VERSION, "and the one needed")
	AssertContains(Notices[1], HTTP_SystemCurlPath(), "and the program")
	AssertFalse(InStr(Notices[1], "{"), "no placeholder is left")

	AssertFalse(HTTP_CheckCurlAtStart(_CSC_Missing, Notice), "a missing curl is refused")
	AssertEqual(2, Notices.Length, "that refusal speaks too")
	AssertContains(Notices[2], HTTP_SystemCurlPath(), "it names the program")
	AssertFalse(InStr(Notices[2], "{"), "no placeholder is left")
	Assert(StrCompare(Notices[1], Notices[2]) != 0, "a missing one is told apart from an old one")

	AssertFalse(HTTP_CheckCurlAtStart(_CSC_Value.Bind(""), Notice), "a file without a version is refused")
	AssertEqual(Notices[2], Notices[3], "and reads as missing or unreadable")
}
Test("curl-start-check: the start check refuses in words", _CSC_Check)

; The real file of a machine that runs this suite, and the entry's call.
_CSC_RealFileAndEntry() {
	Assert(RegExMatch(FileGetVersion(HTTP_SystemCurlPath()), "^\d+\.\d+\.\d+"),
		"this Windows reports its curl version from the file")
	AssertTrue(HTTP_CheckCurlAtStart(), "this machine is supported, so no dialog opens")
	Entry := FileRead(A_ScriptDir . "\..\ErgoptiPlus.ahk", "UTF-8")
	AssertContains(Entry, "SetTimer(HTTP_CheckCurlAtStart, -1)", "the entry runs the check after ready")
	Assert(InStr(Entry, "SetTimer(HTTP_CheckCurlAtStart") > InStr(Entry, '_DriverBootPhase := "ready"'),
		"a dialog must not freeze the boot")
}
Test("curl-start-check: the file reading and the entry's scheduling", _CSC_RealFileAndEntry)
