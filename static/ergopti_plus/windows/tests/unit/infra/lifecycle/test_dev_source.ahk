; tests/unit/infra/lifecycle/test_dev_source.ahk

; ==============================================================================
; MODULE: Developer Source Mode Tests (Windows)
; DESCRIPTION:
; A developer run (tools/dev/run-windows-dev.ps1) names the clone root and
; reloads the driver once a saved .ahk settles. These tests pin the exact-root
; resolution, that a compiled build ignores the variable, that test and
; generated files never reload, and that a change reloads once, after a quiet
; poll.
; ==============================================================================

#Requires AutoHotkey v2.0

global _DST_Reloads := 0
global _DST_Arms := []
global _DST_Driver := "C:\clone\static\ergopti_plus\windows"

; A scratch driver tree with one source, one test and one generated file.
_DST_Tree() {
	Root := A_Temp . "\ergopti_dev_source_" . A_TickCount . "_" . Random(1, 1000000)
	for Folder in ["\infra", "\tests\unit", "\_generated"]
		DirCreate(Root . Folder)
	for File in ["\infra\a.ahk", "\tests\unit\b.ahk", "\_generated\c.ahk", "\ErgoptiPlus.ahk"]
		FileAppend("; source`n", Root . File, "UTF-8")
	return Root
}

_DST_Touch(Path) {
	FileSetTime("20300101000000", Path, "M")
}

_DST_Arm(Callback, Period) {
	global _DST_Arms
	_DST_Arms.Push(Period)
}

_DST_Reload() {
	global _DST_Reloads
	_DST_Reloads += 1
}

_DST_SharedVariable() {
	AssertEqual("ERGOPTI_DEV_SOURCE_ROOT", DevSource_EnvironmentName(_SharedDir))
}
Test("dev source: the developer variable is the shared one (windows-dev-mode)", _DST_SharedVariable)

_DST_Inactive() {
	AssertEqual("", DevSource_ResolveRoot("", _DST_Driver, 0))
	AssertEqual("", DevSource_ResolveRoot("C:\clone", _DST_Driver, 1), "a compiled build ignores the root")
}
Test("dev source: inactive without a root or in a compiled build (windows-dev-mode)", _DST_Inactive)

_DST_ExactRoot() {
	AssertEqual("C:\clone", DevSource_ResolveRoot("C:/clone", "c:\CLONE\static\ergopti_plus\windows", 0))
	AssertThrows(() => DevSource_ResolveRoot("clone", _DST_Driver, 0), "a relative root")
	AssertThrows(() => DevSource_ResolveRoot("C:\clone\", _DST_Driver, 0), "a trailing separator")
	AssertThrows(() => DevSource_ResolveRoot("C:\other", _DST_Driver, 0), "another clone")
}
Test("dev source: accepts only the clone the script runs from (windows-dev-mode)", _DST_ExactRoot)

_DST_SnapshotScope() {
	Root := _DST_Tree()
	try {
		Snapshot := DevSource_Snapshot(Root)
		AssertEqual(2, Snapshot.Count)
		AssertTrue(Snapshot.Has(Root . "\infra\a.ahk"))
		AssertFalse(Snapshot.Has(Root . "\tests\unit\b.ahk"))
		AssertFalse(Snapshot.Has(Root . "\_generated\c.ahk"))
	} finally DirDelete(Root, true)
}
Test("dev source: the snapshot skips tests and generated files (windows-dev-mode)", _DST_SnapshotScope)

_DST_ReloadsOnce() {
	global _DevSourceWatcher, _DST_Reloads, _DST_Arms
	_DST_Reloads := 0
	_DST_Arms := []
	Root := _DST_Tree()
	try {
		DevSourceWatcher_Start(Root, _DST_Reload, _DST_Arm)
		AssertThrows(() => DevSourceWatcher_Start(Root, _DST_Reload, _DST_Arm), "a second start is refused")
		_DevSourceWatcherTick()
		AssertEqual(0, _DST_Reloads, "nothing changed")
		_DST_Touch(Root . "\tests\unit\b.ahk")
		_DevSourceWatcherTick()
		_DevSourceWatcherTick()
		AssertEqual(0, _DST_Reloads, "a test edit does not reload")
		_DST_Touch(Root . "\infra\a.ahk")
		_DevSourceWatcherTick()
		AssertEqual(0, _DST_Reloads, "the save has not settled yet")
		_DevSourceWatcherTick()
		AssertEqual(1, _DST_Reloads, "the settled save reloads")
		_DevSourceWatcherTick()
		AssertEqual(1, _DST_Reloads, "once")
	} finally {
		DevSourceWatcher_Stop()
		DirDelete(Root, true)
	}
	AssertEqual(0, _DevSourceWatcher)
	AssertEqual(DEV_SOURCE_POLL_MS, _DST_Arms[1])
	AssertEqual(0, _DST_Arms[_DST_Arms.Length])
}
Test("dev source: a saved .ahk reloads once, after a quiet poll (windows-dev-mode)", _DST_ReloadsOnce)

_DST_SharedPaths() {
	Source := FileRead(A_ScriptDir . "\..\infra\boot.ahk", "UTF-8")
	Start := InStr(Source, "global _PathsFile :=")
	Assert(Start > 0, "boot.ahk declares _PathsFile")
	Declaration := SubStr(Source, Start, 300)
	AssertContains(Declaration, '(A_IsCompiled || DevSource_Root() != "")',
		"a developer run reads the installed build's paths.toml")
	Entry := FileRead(A_ScriptDir . "\..\ErgoptiPlus.ahk", "UTF-8")
	Assert(InStr(Entry, "#Include infra/dev_source.ahk") < InStr(Entry, "#Include infra/boot.ahk"),
		"dev_source.ahk is included before boot.ahk reads it")
	Assert(InStr(Entry, "DevSourceWatcher_Start(_DriverDir, ReloadPreservingSuspend)") > 0,
		"the driver arms the watcher on the tray's Reload path")
}
Test("dev source: a developer run uses the installed paths.toml and the Reload path (windows-dev-mode)",
	_DST_SharedPaths)
