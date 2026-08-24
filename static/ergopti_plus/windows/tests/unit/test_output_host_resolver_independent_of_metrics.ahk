; tests/unit/test_output_host_resolver_independent_of_metrics.ahk

; ==============================================================================
; MODULE: Output Host Resolver Regression Tests
; DESCRIPTION:
; AHK-002: functional sender selection owns a fresh, bounded foreground receipt
; and never depends on optional metrics observations.
; ==============================================================================

#Requires AutoHotkey v2.0

global _OHR_Identity := Map("Hwnd", 1001, "Pid", 2001)
global _OHR_Metadata := Map("Exe", "Code.exe", "Class", "fixture")
global _OHR_Title := Map("Ok", true, "Title", "Editor", "TimedOut", false)
global _OHR_IdentityReads := 0
global _OHR_MetadataReads := 0
global _OHR_TitleReads := 0
global _OHR_IdentityAfterTitle := 0
global _OHR_MetadataThrows := false

_OHR_ReadIdentity() {
	global _OHR_Identity, _OHR_IdentityReads
	_OHR_IdentityReads += 1
	return _OHR_Identity.Clone()
}

_OHR_ReadMetadata(Hwnd, Pid) {
	global _OHR_Metadata, _OHR_MetadataReads, _OHR_MetadataThrows
	_OHR_MetadataReads += 1
	if _OHR_MetadataThrows
		throw Error("fixture metadata failure")
	return _OHR_Metadata.Clone()
}

_OHR_ReadTitle(Hwnd, Pid) {
	global _OHR_Title, _OHR_TitleReads
	global _OHR_Identity, _OHR_IdentityAfterTitle
	_OHR_TitleReads += 1
	if (_OHR_IdentityAfterTitle is Map)
		_OHR_Identity := _OHR_IdentityAfterTitle.Clone()
	return _OHR_Title.Clone()
}

_OHR_Reset(Exe := "Code.exe", Hwnd := 1001, Pid := 2001,
		Title := "Editor", ClassName := "fixture") {
	global _OHR_Identity, _OHR_Metadata, _OHR_Title
	global _OHR_IdentityReads, _OHR_MetadataReads, _OHR_TitleReads
	global _OHR_IdentityAfterTitle, _OHR_MetadataThrows
	_OHR_Identity := Map("Hwnd", Hwnd, "Pid", Pid)
	_OHR_Metadata := Map("Exe", Exe, "Class", ClassName)
	_OHR_Title := Map("Ok", true, "Title", Title, "TimedOut", false)
	_OHR_IdentityReads := 0
	_OHR_MetadataReads := 0
	_OHR_TitleReads := 0
	_OHR_IdentityAfterTitle := 0
	_OHR_MetadataThrows := false
	OutputHostResolverConfigure(_OHR_ReadIdentity, _OHR_ReadMetadata, _OHR_ReadTitle)
}

_OHR_AssertValid(Receipt, Exe, Title := "") {
	AssertTrue(Receipt is Map, "resolver result must be a typed receipt Map")
	AssertTrue(Receipt.Has("Valid"), "receipt must expose an explicit validity bit")
	AssertTrue(Receipt["Valid"], "receipt must be valid")
	AssertEqual(Exe, Receipt["Exe"])
	AssertEqual(Title, Receipt["Title"])
}

_OHR_StableIdentityCachesMetadataButRefreshesTitle() {
	global _OHR_Title, _OHR_IdentityReads, _OHR_MetadataReads, _OHR_TitleReads
	_OHR_Reset("Code.exe", 1001, 2001, "Editor")
	First := OutputHostResolve(true)
	_OHR_AssertValid(First, "Code.exe", "Editor")
	AssertFalse(_HSE_IsTerminalInputHost(First["Exe"], First["Title"]))

	_OHR_Title := Map("Ok", true, "Title", "Codebuff", "TimedOut", false)
	Second := OutputHostResolve(true)
	_OHR_AssertValid(Second, "Code.exe", "Codebuff")
	AssertTrue(_HSE_IsTerminalInputHost(Second["Exe"], Second["Title"]),
		"a title change on the same HWND/PID must immediately change routing")
	loop 98
		OutputHostResolve(true)
	AssertEqual(1, _OHR_MetadataReads,
		"process/class metadata must be cached for an exact stable identity")
	AssertEqual(100, _OHR_TitleReads,
		"title-sensitive routing must acquire a fresh bounded title every time")
	AssertEqual(200, _OHR_IdentityReads,
		"each receipt must bind both sides of title acquisition")
}
Test("output host: stable identity refreshes title (ahk-002)",
	_OHR_StableIdentityCachesMetadataButRefreshesTitle)

_OHR_FocusChangeDuringTitleProbeFailsClosed() {
	global _OHR_IdentityAfterTitle, _OHR_Metadata, _OHR_Title
	_OHR_Reset("a.exe", 1101, 2101, "A")
	_OHR_IdentityAfterTitle := Map("Hwnd", 1102, "Pid", 2102)
	Stale := OutputHostResolve(true)
	AssertFalse(Stale["Valid"],
		"an A-metadata/B-focus receipt must never be published")
	AssertEqual("focus_changed", Stale["Failure"])

	_OHR_IdentityAfterTitle := 0
	_OHR_Metadata := Map("Exe", "b.exe", "Class", "fixture-b")
	_OHR_Title := Map("Ok", true, "Title", "B", "TimedOut", false)
	Fresh := OutputHostResolve(true)
	_OHR_AssertValid(Fresh, "b.exe", "B")
	AssertEqual(1102, Fresh["Hwnd"])
	AssertEqual(2102, Fresh["Pid"])
}
Test("output host: focus change during title probe fails closed (ahk-002)",
	_OHR_FocusChangeDuringTitleProbeFailsClosed)

_OHR_TitleTimeoutAndMetadataFailureAreInvalid() {
	global _OHR_Title, _OHR_MetadataThrows
	_OHR_Reset("WindowsTerminal.exe", 1201, 2201, "Terminal")
	_OHR_Title := Map("Ok", false, "Title", "", "TimedOut", true)
	TimedOut := OutputHostResolve(true)
	AssertFalse(TimedOut["Valid"])
	AssertEqual("title_timeout", TimedOut["Failure"])
	AssertTrue(TimedOut["TimedOut"])
	AssertEqual("", TimedOut["Exe"],
		"a rejected receipt must not expose plausible routing metadata")

	_OHR_Reset("WindowsTerminal.exe", 1202, 2202, "Terminal")
	_OHR_MetadataThrows := true
	Failed := OutputHostResolve(true)
	AssertFalse(Failed["Valid"])
	AssertEqual("metadata_error", Failed["Failure"])
	AssertEqual("", Failed["Exe"])
}
Test("output host: probe failures are explicit and fail closed (ahk-002)",
	_OHR_TitleTimeoutAndMetadataFailureAreInvalid)

_OHR_TitlelessReadersDoNotPayForTitle() {
	global _OHR_TitleReads, _OHR_MetadataReads
	_OHR_Reset("notepad.exe", 1301, 2301, "Unused")
	Receipt := OutputHostResolve(false)
	_OHR_AssertValid(Receipt, "notepad.exe", "")
	AssertEqual(0, _OHR_TitleReads)
	AssertEqual(1, _OHR_MetadataReads)
}
Test("output host: titleless readers share cached identity (ahk-002)",
	_OHR_TitlelessReadersDoNotPayForTitle)

OutputHostResolverConfigure()
