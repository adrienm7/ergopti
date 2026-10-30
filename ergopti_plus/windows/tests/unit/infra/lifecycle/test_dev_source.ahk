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


; The common JS lane cannot qualify the unmodified Windows-only entry. Its
; native success receipt requires all real PowerShell 5.1 entry controls.
_DST_NativeInterpreterPolicy() {
	global _DriverDir, _SR_TreeOwnedTasks, _SR_TreeCaptureDebts
	Repo := FSResolveDirectoryPath(_DriverDir . "\..\..\..")
	Script := Repo . "\tools\test\test-windows-dev-script.cjs"
	AssertTrue(FileExist(Script), "the registered actual developer launcher CLI must exist")
	Observed := {Calls: 0, Code: -1, Output: ""}
	Construction := Map()
	Handle := 0
	Completed(Code, Output, Errors) {
		Observed.Calls += 1
		Observed.Code := Code
		Observed.Output := Output . Errors
	}
	Capture(Owner, Native) {
		Construction["owner"] := Owner
	}
	try {
		Handle := ShellRunner_SpawnTreeOwned("node.exe", [Script], Completed, , Capture, 32768)
		AssertTrue(Handle.start(), "the actual native policy process must start")
		Started := A_TickCount
		loop {
			_SR_TreePoll()
			if Observed.Calls == 1 && Construction.Has("owner") {
				Claim := Construction["owner"].Get("TerminalClaim", 0)
				if Claim is Map && Claim["TreeQuiesced"]
					&& !FileExist(Claim["TmpFile"]) && !DirExist(Claim["CaptureDir"])
					break
			}
			if TickExpired64(Started, 45000)
				break
			Sleep(10)
		}
		AssertEqual(1, Observed.Calls, "the exact native process must produce one bounded completion")
		if Observed.Code != 0
			NativeCliPrintFailureOutput("native developer interpreter policy", Observed.Output)
		AssertEqual(0, Observed.Code, "native developer interpreter policy: " . NativeCliFailureHeadline(Observed.Output))
		Markers := 0
		for Line in StrSplit(StrReplace(Observed.Output, "`r`n", "`n"), "`n")
			if InStr(Line, "[OK] Windows developer driver runner (") == 1
				&& InStr(Line, "native_entry_cases=8; host_entry_body_cases=0).")
				Markers += 1
		AssertEqual(1, Markers, "host-only checks cannot certify the eight actual Windows entry cases")
		AssertTrue(Construction.Has("owner"), "native construction must retain the exact retirement owner")
		Owner := Construction["owner"], Claim := Owner["TerminalClaim"]
		AssertTrue(Claim["TreeQuiesced"] && !Owner["FinalizationPending"], "the actual Node and PowerShell tree must physically retire")
		AssertEqual(0, Claim["NativeErrors"].Length, "every native retirement receipt must be acknowledged")
		AssertFalse(_SR_TreeOwnedTasks.Has(Owner["TaskId"]), "completed policy cannot retain a native task registry owner")
		AssertFalse(_SR_TreeCaptureDebts.Has(ObjPtr(Claim)), "completed policy cannot retain a private capture debt")
		for Key in ["ProcessHandle", "ThreadHandle", "JobHandle"] {
			AssertEqual(0, Owner[Key], "construction must release its original " . Key)
			AssertEqual(0, Claim[Key], "terminal completion must release its original " . Key)
		}
	} finally {
		if IsObject(Handle) && !Handle.terminate() {
			AssertTrue(Construction.Has("owner"), "a retained retirement must keep its exact owner")
			Owner := Construction["owner"]
			AssertTrue(Owner["TreeQuiesced"] && !Owner["FinalizationPending"],
				"an already completed native policy must retain physical retirement proof")
		}
	}
}
Test("dev source: native Windows interpreter choices refuse fallback before process effects (windows-dev-interpreter-native)",
	_DST_NativeInterpreterPolicy)
