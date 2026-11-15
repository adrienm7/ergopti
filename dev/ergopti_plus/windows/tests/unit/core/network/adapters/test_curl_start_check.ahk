; tests/unit/core/network/adapters/test_curl_start_check.ahk

; ==============================================================================
; MODULE: System curl Start Check
; DESCRIPTION:
; The owned-runtimes decision (SYS): the driver keeps System32 curl.exe, checks it
; at start and names its absence or an unusable version in words, not with each
; local AI request's bare refusal. Only the AI needs it: the check runs at boot when
; the AI is on and when it gets turned on, and with the AI off no dialog ever opens.
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
	Entry := _DriverSourceConcat()
	AssertContains(Entry, "SetTimer(HTTP_CheckCurlAtStart, -1)", "a dialog must not freeze the boot")
	; Positional search: a dot-all regex over the whole driver exceeds PCRE's limit.
	ReadyPos := InStr(Entry, '_DriverBootPhase := "ready"')
	Assert(ReadyPos > 0 && RegExMatch(Entry, 'm)^HTTP_ScheduleCurlCheck\(_LLM_Menu\.Get\("enabled", false\)\)', , ReadyPos) > ReadyPos,
		"the entry schedules the check after ready, following the AI's own state")
}
Test("curl-start-check: the file reading and the entry's scheduling", _CSC_RealFileAndEntry)

; AI off: nothing is scheduled, so an unusable curl stays silent. AI on: the check runs
; and says so. The scheduled callback runs for real over a refused curl.
_CSC_FollowsTheAi() {
	Scheduled := []
	Record := (Check) => Scheduled.Push(Check)
	AssertFalse(HTTP_ScheduleCurlCheck(false, Record), "the AI off schedules nothing")
	AssertEqual(0, Scheduled.Length, "the AI off reaches no check, so no dialog")
	AssertTrue(HTTP_ScheduleCurlCheck(true, Record), "the AI on schedules the check")
	AssertEqual(1, Scheduled.Length, "one check")
	Notices := []
	AssertFalse(Scheduled[1].Call(_CSC_Value.Bind("7.55.1"), _CSC_Record.Bind(Notices)),
		"what the AI on scheduled is the check itself")
	AssertEqual(1, Notices.Length, "and it speaks about an unusable curl")
}
Test("curl-start-check: the check follows the AI, off shows nothing, on checks", _CSC_FollowsTheAi)
