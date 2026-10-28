; tests/unit/infra/lifecycle/test_dev_source.ahk

; ==============================================================================
; MODULE: Developer Source Mode Tests (Windows)
; DESCRIPTION:
; A developer run (tools/dev/run-windows-dev.ps1) names the clone root, a
; double-clicked ErgoptiPlus.ahk in a clone derives it, and either reloads the
; driver once a saved .ahk settles. These tests pin the exact-root resolution,
; the derived root of a Git checkout only, that the variable wins, that a
; compiled build ignores both, that test and generated files never reload, and
; that a change reloads once, after a quiet poll.
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
	AssertEqual("", DevSource_ResolveRoot("", _DST_Driver, 1))
	AssertEqual("", DevSource_ResolveRoot("C:\clone", _DST_Driver, 0), "an installed build ignores the root")
}
Test("dev source: inactive without a root or in an installed build (windows-dev-mode)", _DST_Inactive)

_DST_ExactRoot() {
	AssertEqual("C:\clone", DevSource_ResolveRoot("C:/clone", "c:\CLONE\static\ergopti_plus\windows", 1))
	AssertThrows(() => DevSource_ResolveRoot("clone", _DST_Driver, 1), "a relative root")
	AssertThrows(() => DevSource_ResolveRoot("C:\clone\", _DST_Driver, 1), "a trailing separator")
	AssertThrows(() => DevSource_ResolveRoot("C:\other", _DST_Driver, 1), "another clone")
}
Test("dev source: accepts only the clone the script runs from (windows-dev-mode)", _DST_ExactRoot)

; A scratch clone layout: the shared identifiers, the driver folder and, unless
; told otherwise, a .git folder ("file" makes it a linked worktree's .git file).
_DST_Clone(GitKind := "dir") {
	Root := A_Temp . "\ergopti_dev_clone_" . A_TickCount . "_" . Random(1, 1000000)
	DirCreate(Root . "\static\ergopti_plus\_shared\data")
	DirCreate(Root . "\static\ergopti_plus\windows")
	FileAppend("{}", Root . "\static\ergopti_plus\_shared\data\identifiers.json", "UTF-8")
	if (GitKind == "dir")
		DirCreate(Root . "\.git")
	else if (GitKind == "file")
		FileAppend("gitdir: C:\elsewhere`n", Root . "\.git", "UTF-8")
	return Root
}

_DST_DerivedRoot() {
	Root := _DST_Clone()
	Worktree := _DST_Clone("file")
	try {
		Driver := Root . "\static\ergopti_plus\windows"
		AssertEqual(Root, DevSource_ResolveRoot("", Driver, 1), "a double-click in a clone")
		AssertEqual(Root, DevSource_ResolveRoot("", StrReplace(Driver, "\", "/"), 1), "forward slashes")
		AssertEqual(Worktree, DevSource_ResolveRoot("", Worktree . "\static\ergopti_plus\windows", 1),
			"a linked worktree's .git file")
		AssertEqual("the script location", DevSource_RootOrigin(Root, ""))
		AssertEqual("the developer variable", DevSource_RootOrigin(Root, Root))
		AssertEqual("", DevSource_RootOrigin("", ""))
	} finally {
		DirDelete(Root, true)
		DirDelete(Worktree, true)
	}
}
Test("dev source: a source run in a Git clone derives the root (windows-dev-mode)", _DST_DerivedRoot)

_DST_DerivedRefused() {
	NoGit := _DST_Clone("none")
	NoTree := _DST_Clone()
	try {
		AssertEqual("", DevSource_ResolveRoot("", NoGit . "\static\ergopti_plus\windows", 1),
			"a source tree without .git is a plain source run")
		FileDelete(NoTree . "\static\ergopti_plus\_shared\data\identifiers.json")
		AssertEqual("", DevSource_ResolveRoot("", NoTree . "\static\ergopti_plus\windows", 1),
			"a checkout without this repository's tree")
		AssertEqual("", DevSource_ResolveRoot("", NoTree . "\static\ergopti_plus", 1),
			"a folder that is not the Windows driver")
	} finally {
		DirDelete(NoGit, true)
		DirDelete(NoTree, true)
	}
}
Test("dev source: no derived root outside a Git clone of this repository (windows-dev-mode)",
	_DST_DerivedRefused)

_DST_VariableWins() {
	Clone := _DST_Clone()
	NoGit := _DST_Clone("none")
	try {
		AssertThrows(() => DevSource_ResolveRoot("C:\other", Clone . "\static\ergopti_plus\windows", 1),
			"a variable naming another clone still raises inside a clone")
		AssertEqual(NoGit, DevSource_ResolveRoot(NoGit, NoGit . "\static\ergopti_plus\windows", 1),
			"the launcher's variable needs no .git")
	} finally {
		DirDelete(Clone, true)
		DirDelete(NoGit, true)
	}
}
Test("dev source: the developer variable wins over the derived root (windows-dev-mode)", _DST_VariableWins)

_DST_DerivedCompiled() {
	Clone := _DST_Clone()
	try AssertEqual("", DevSource_ResolveRoot("", Clone . "\static\ergopti_plus\windows", 0),
		"a compiled build never derives a root")
	finally DirDelete(Clone, true)
	Body := _DriverFuncBody("DevSource_Resolution")
	AssertContains(Body, "Updater_IsLocalSource()", "the source-run owner decides")
	AssertFalse(InStr(Body, "A_IsCompiled"), "no second source-run owner")
	AssertContains(_DriverSourceConcat(), 'DevSource_Resolution()["origin"]',
		"the startup line names where the root came from")
}
Test("dev source: a compiled build derives no root (windows-dev-mode)", _DST_DerivedCompiled)

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
	; This runner is a source run without the developer variable: the clone's copy.
	AssertEqual("", DevSource_Root())
	AssertFalse(DevSource_UsesInstalledPaths(), "a plain source run keeps the clone's paths.toml")
	Body := _DriverFuncBody("DevSource_UsesInstalledPaths")
	AssertContains(Body, 'DevSource_Root() != ""', "a developer run reads the installed build's paths.toml")
	Source := _DriverSourceConcat()
	AssertContains(Source, "DevSourceWatcher_Start(_DriverDir, ReloadPreservingSuspend)",
		"the driver arms the watcher on the tray's Reload path")
	AssertContains(Source, ": (DevSource_UsesInstalledPaths()", "boot.ahk asks the paths owner")
}
Test("dev source: a developer run uses the installed paths.toml and the Reload path (windows-dev-mode)",
	_DST_SharedPaths)
