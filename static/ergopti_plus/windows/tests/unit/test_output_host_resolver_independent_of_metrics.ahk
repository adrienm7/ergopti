; tests/unit/test_output_host_resolver_independent_of_metrics.ahk

; ==============================================================================
; MODULE: Output Host Resolver Tests
; DESCRIPTION:
; Functional sender routing follows the exact active HWND/PID and remains
; independent of the optional keylogger/metrics observation cache.
; ==============================================================================

#Requires AutoHotkey v2.0

global _OHR_Identity := Map("Hwnd", 101, "Pid", 1001)
global _OHR_Metadata := Map("Exe", "WindowsTerminal.exe", "Class", "CASCADIA_HOSTING_WINDOW_CLASS", "Title", "Terminal")
global _OHR_MetadataReads := 0

_OHR_ReadIdentity() {
	global _OHR_Identity
	return _OHR_Identity.Clone()
}

_OHR_ReadMetadata(Hwnd, Pid) {
	global _OHR_Metadata, _OHR_MetadataReads
	_OHR_MetadataReads += 1
	return _OHR_Metadata.Clone()
}

_OHR_Reset(Exe, Hwnd := 101, Pid := 1001, Title := "") {
	global _OHR_Identity, _OHR_Metadata, _OHR_MetadataReads
	_OHR_Identity := Map("Hwnd", Hwnd, "Pid", Pid)
	_OHR_Metadata := Map("Exe", Exe, "Class", "fixture", "Title", Title)
	_OHR_MetadataReads := 0
	OutputHostResolverConfigure(_OHR_ReadIdentity, _OHR_ReadMetadata)
}

_OHR_MetricsOffStillRoutesTerminalAndNotepad() {
	global _OHR_Identity, _OHR_Metadata
	KLHook.prev_app := ""
	_OHR_Reset("WindowsTerminal.exe")
	Host := OutputHostResolve()
	AssertTrue(_HSE_IsTerminalInputHost(Host["Exe"], Host["Title"]),
		"an empty metrics cache must not hide the active terminal")
	_OHR_Metadata := Map("Exe", "notepad.exe", "Class", "fixture", "Title", "Untitled")
	; A foreground identity change is the only valid cache invalidator.
	_OHR_Identity := Map("Hwnd", 102, "Pid", 1002)
	AssertEqual("notepad.exe", StrLower(OutputHostResolve()["Exe"]),
		"an empty metrics cache must not hide active Notepad")
}
Test("output host: functional routing is independent of metrics", _OHR_MetricsOffStillRoutesTerminalAndNotepad)

_OHR_StaleIdentityRefreshesAndStableIdentityCaches() {
	global _OHR_Identity, _OHR_Metadata, _OHR_MetadataReads
	_OHR_Reset("test.exe")
	AssertEqual("test.exe", OutputHostResolve()["Exe"])
	_OHR_Identity := Map("Hwnd", 202, "Pid", 2002)
	_OHR_Metadata := Map("Exe", "WindowsTerminal.exe", "Class", "fixture", "Title", "Terminal")
	AssertEqual("WindowsTerminal.exe", OutputHostResolve()["Exe"],
		"a different HWND/PID must refresh stale metadata")
	loop 100
		OutputHostResolve()
	AssertEqual(2, _OHR_MetadataReads,
		"one metadata acquisition per distinct stable foreground identity is sufficient")
}
Test("output host: stale identities refresh and stable identities cache", _OHR_StaleIdentityRefreshesAndStableIdentityCaches)

_OHR_InvalidIdentityFailsClosed() {
	global _OHR_Identity
	_OHR_Reset("WindowsTerminal.exe")
	_OHR_Identity := Map("Hwnd", 0, "Pid", 0)
	Host := OutputHostResolve()
	AssertEqual("", Host["Exe"])
	AssertFalse(_HSE_IsTerminalInputHost(Host["Exe"], Host["Title"]),
		"unresolved identity must not reuse a stale sender route")
}
Test("output host: an invalid foreground identity fails closed", _OHR_InvalidIdentityFailsClosed)

; Do not leak injected probes into later tests in the shared process.
OutputHostResolverConfigure()
