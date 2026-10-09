; tests/meta/test_personal_shortcuts_atomic_bootstrap.ahk

; ==============================================================================
; MODULE: Personal Shortcuts Atomic Bootstrap Regression
; DESCRIPTION:
; A failed/truncated first-use write was swallowed, and both runtime entry points
; opened Notepad anyway. The generator also deleted the live forwarding stub
; before appending its replacement, exposing a missing or partial #Include to a
; concurrent Reload. A first hardening pass still omitted the process-wide
; configuration lease, so a path relocation could begin while that verified
; stage was pending. Pin the whole cause: global admission, exact-owner
; revalidation, verified atomic publication, explicit status at every caller,
; and fail-fast boot when the include chain is unsafe. Compiled first-use boot
; must also keep its resident process: its includes are build-time artifacts,
; so source-mode Reload cannot admit a newly written chain into that executable.
; ==============================================================================

#Requires AutoHotkey v2.0

_PSAB_GeneratorPublishesVerifiedStages() {
	Ensure := _StripFullLineComments(_DriverFuncBody("EnsurePersonalShortcutsFile"))
	Publish := _StripFullLineComments(_DriverFuncBody("_PersonalShortcutsPublishFile"))
	Assert(Ensure != "" and Publish != "",
		"personal-shortcuts generator and publication helper must remain source-visible")
	Assert(InStr(Ensure, 'Critical("Off")') > 0,
		"the generator must defuse inherited Critical before directory and file I/O")
	Assert(InStr(Ensure, "_PersonalShortcutsPublishFile(Path,") > 0
		and InStr(Ensure, "WriterFn, ReplaceFn, ReadFn, true") > 0,
		"the user-owned source must use create-only atomic publication")
	Assert(InStr(Ensure, "_PersonalShortcutsPublishFile(StubPath,") > 0,
		"the forwarding stub must use the same verified publication primitive")
	Assert(InStr(Ensure, "FileAppend(") == 0 and InStr(Ensure, "FileDelete(") == 0,
		"the generator must never delete/truncate a live AHK source before replacement")

	Write := InStr(Publish, "FSWriteDurable(StagePath, Content)")
	Read := InStr(Publish, "FSUtf8ExactMatches(StagePath, Content)", true, Write)
	Verify := InStr(Publish, "if !StageMatches", true, Read)
	Create := InStr(Publish, "FSAtomicMoveCreate(StagePath, Path)", true, Verify)
	Replace := InStr(Publish, "FSAtomicMoveReplace(StagePath, Path)", true, Verify)
	Assert(Write > 0 and Read > Write and Verify > Read
		and Create > Verify and Replace > Verify,
		"the full stage must be durable and byte-verified before an atomic create/replace")
	Assert(InStr(Publish, "A_ScriptHwnd") > 0
		and InStr(Publish, "StageSequence") > 0,
		"concurrent processes/calls must not share one clobberable .stage pathname")
}
Test("personal shortcuts: generated AHK files publish atomically "
	. "(personal-shortcuts-delete-append-and-silent-failure)",
	_PSAB_GeneratorPublishesVerifiedStages)

_PSAB_PublicationOwnsTheConfigBoundary() {
	Publish := _StripFullLineComments(
		_DriverFuncBody("_PersonalShortcutsPublishFile"))
	Assert(Publish != "",
		"the personal-shortcuts publication helper must remain source-visible")
	Acquire := InStr(Publish, "_ConfigWriteLeaseTryAcquire(")
	Write := InStr(Publish, "FSWriteDurable(StagePath, Content)", true, Acquire)
	Verify := InStr(Publish, "if !StageMatches", true, Write)
	Authorize := InStr(Publish,
		"_ConfigWriteLeaseOwns(OwnerToken, Path)", true, Verify)
	Replace := InStr(Publish,
		"FSAtomicMoveReplace(StagePath, Path)", true, Authorize)
	Release := InStr(Publish,
		"_ConfigWriteLeaseRelease(OwnerToken)", true, Replace)
	Assert(Acquire > 0 and Write > Acquire and Verify > Write
		and Authorize > Verify and Replace > Authorize and Release > Replace,
		"every generated AHK writer must retain one exact config owner from before staging through final replacement and release it afterward")
	Assert(InStr(Publish, "finally", true, Replace) > Replace,
		"exceptions and early refusals must release the exact personal-shortcuts owner")
	Assert(InStr(Publish, 'Critical("On")') == 0,
		"the lease, never Critical, must span personal-shortcuts filesystem I/O")
}
Test("personal shortcuts: atomic publisher participates in the global config barrier "
	. "(personal-shortcuts-global-barrier-sibling-omission)",
	_PSAB_PublicationOwnsTheConfigBoundary)

_PSAB_EveryCallerConsumesFailure() {
	Menu := _StripFullLineComments(_DriverFuncBody("OpenPersonalShortcuts"))
	Gesture := _StripFullLineComments(_DriverFuncBody("GestureEditPersonalShortcuts"))
	for Spec in [
		{ body: Menu, name: "OpenPersonalShortcuts" },
		{ body: Gesture, name: "GestureEditPersonalShortcuts" }
	] {
		Gate := InStr(Spec.body, "if !EnsurePersonalShortcutsFile(Path, false)")
		RunPos := InStr(Spec.body, "Run(", true, Gate)
		Assert(Gate > 0 and RunPos > Gate,
			Spec.name . " must refuse the editor launch when bootstrap failed")
		Assert(InStr(Spec.body, "ConfigReportPersistenceFailure(", true, Gate) > Gate,
			Spec.name . " must surface the refused output instead of returning silently")
	}

	Src := _DriverSourceNoComments()
	BootGate := InStr(Src,
		'if !EnsurePersonalShortcutsFile(ScriptInformation["PersonalAhkPath"],', true)
	BootAbort := InStr(Src, "ExitApp(1)", true, BootGate)
	PersonalInclude := InStr(Src,
		"#Include *i _generated/personal_shortcuts.ahk", true, BootGate)
	Assert(BootGate > 0 and BootAbort > BootGate
		and PersonalInclude > BootAbort,
		"boot must abort before reaching the personal #Include when its safe chain is unavailable")
}
Test("personal shortcuts: boot/menu/gesture consume generator failure "
	. "(personal-shortcuts-delete-append-and-silent-failure)",
	_PSAB_EveryCallerConsumesFailure)

_PSAB_TempPath(Suffix) {
	return A_Temp . "\ergopti_personal_shortcuts_" . DllCall("GetCurrentProcessId")
		. "_" . A_TickCount . "_" . Suffix . ".ahk"
}

_PSAB_ExactBomPublicationRoundTrips() {
	Path := _PSAB_TempPath("bom")
	Content := Chr(0xFEFF) . '; generated`nSendText("é")`n'
	try {
		AssertTrue(FSWriteDurable(Path, Content))
		AssertTrue(FSUtf8ExactMatches(Path, Content))
	} finally {
		try FSDelete(Path)
	}
}
Test("personal shortcuts: durable publication verifies physical BOM bytes "
	. "(personal-shortcuts-exact-bom-roundtrip)",
	_PSAB_ExactBomPublicationRoundTrips)

_PSAB_NoBomPublicationRoundTrips() {
	Path := _PSAB_TempPath("raw")
	Content := "; raw utf8`n"
	try {
		AssertTrue(FSWriteDurable(Path, Content))
		AssertTrue(FSUtf8ExactMatches(Path, Content))
	} finally {
		try FSDelete(Path)
	}
}
Test("personal shortcuts: exact verification accepts intentional no-BOM payloads "
	. "(personal-shortcuts-exact-raw-roundtrip)",
	_PSAB_NoBomPublicationRoundTrips)

_PSAB_MismatchedStageNeverPublishes() {
	Path := _PSAB_TempPath("mismatch")
	try {
		AssertTrue(FSWriteDurable(Path, "corrupted"))
		AssertFalse(FSUtf8ExactMatches(Path, "expected"))
	} finally {
		try FSDelete(Path)
	}
}
Test("personal shortcuts: a mismatched stage cannot reach the destination "
	. "(personal-shortcuts-stage-mismatch-refused)",
	_PSAB_MismatchedStageNeverPublishes)

_PSAB_CreateOnlyPreservesExistingBytes() {
	Path := _PSAB_TempPath("create_only")
	Stage := Path . ".stage"
	try {
		AssertTrue(FSWriteDurable(Path, "user-owned"))
		AssertTrue(FSWriteDurable(Stage, "replacement"))
		AssertFalse(FSAtomicMoveCreate(Stage, Path))
		AssertEqual("user-owned", FSReadUtf8Exact(Path))
	} finally {
		try FSDelete(Stage)
		try FSDelete(Path)
	}
}
Test("personal shortcuts: create-only collision preserves the user-owned file "
	. "(personal-shortcuts-create-only-preserves-existing)",
	_PSAB_CreateOnlyPreservesExistingBytes)


/** The real boot caller consumes native capability, never a guessed executable name. */
_PSAB_BootReloadCapabilityIsExplicit() {
	Source := _DriverSourceNoComments()
	Policy := _DriverFuncBody("_PersonalShortcutsBootAllowsReload")
	Assert(Policy != "", "the actual bootstrap policy must be source-visible")
	Assert(RegExMatch(Source,
		'if !EnsurePersonalShortcutsFile\(ScriptInformation\["PersonalAhkPath"\],\s*'
			. '_PersonalShortcutsBootAllowsReload\(A_IsCompiled,\s*'
			. '_DriverStartupSmokeDir != "" and EnvGet\("ERGOPTI_STARTUP_SMOKE_BOOTSTRAP"\) != "1"\)\)'),
		"boot keeps compiled ownership while the explicit cold-source observer may follow Reload")
	Assert(InStr(Policy, "return !IsCompiled && !IsStartupSmoke") > 0,
		"only an ordinary source-mode boot can reload a newly generated include")
}
Test("personal shortcuts: compiled bootstrap keeps the current process before readiness "
	. "(compiled-personal-bootstrap)", _PSAB_BootReloadCapabilityIsExplicit)

/** Resolves actual definition-only filesystem/lease owners without a source-path pin. */
_PSAB_NativeOwner(Symbol) {
	global _StaticDir
	Owners := []
	Loop Files, _StaticDir . "\ergopti_plus\windows\*.ahk", "R" {
		if !_DriverIsProductionSource(A_LoopFileFullPath)
			continue
		Source := FileRead(A_LoopFileFullPath, "UTF-8")
		if IsObject(_DriverFindFunctionDefinition(&Source, Symbol))
			Owners.Push(A_LoopFileFullPath)
	}
	AssertEqual(1, Owners.Length, "the private child must include the sole real owner of " . Symbol)
	return Owners[1]
}

/** Captures effects, then asserts outside the subprocess completion callback. */
_PSAB_RunChild(Harness, Arguments, Ownership) {
	Receipt := {Calls: 0, Code: -1, Output: "", Errors: ""}
	OnDone(Code, Output, Errors) {
		Receipt.Calls += 1
		Receipt.Code := Code
		Receipt.Output := Output
		Receipt.Errors := Errors
	}
	Args := ["/ErrorStdOut", Harness]
	Args.Push(Arguments*)
	Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, Args, OnDone)
	try {
		AssertTrue(Handle.start(), "the exact bootstrap child starts")
		Started := A_TickCount
		while !Receipt.Calls && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Receipt.Calls, "the exact bootstrap child completes once")
		AssertEqual(0, Receipt.Code, "the actual bootstrap owners run: " . Receipt.Output . Receipt.Errors)
		AssertEqual("", Receipt.Errors, "bootstrap observations contain no hidden native error")
		return Receipt.Output
	} finally {
		Settled := Handle.terminate()
		if !Settled
			Ownership.CanRetire := false
		AssertTrue(Settled, "the exact bootstrap process tree settles before fixture deletion")
	}
}

/** Independent expected forwarding bytes, including the physical UTF-8 BOM. */
_PSAB_ExpectedForwardingBytes(Path) {
	return Chr(0xFEFF) . "; Auto-generated forwarding stub — do not edit.`n"
		. "; Forwards to the user's personal shortcuts file located at:`n"
		. ";     " . Path . "`n"
		. "; Edit that file (e.g. via the tray menu) rather than this stub.`n"
		. "#Include *i " . Path . "`n"
}

/**
 * Executes exact production bodies with only the two terminal native effects
 * observed. The child remains a source interpreter: compiled policy inputs do
 * not claim qualification of the compiled executable's native stub directory.
 * Filesystem durability, atomic moves, readback and configuration leases are real.
 */
_PSAB_ChildSource(FileOwner, LeaseOwner) {
	Ensure := _DriverFuncBody("EnsurePersonalShortcutsFile")
	Publish := _DriverFuncBody("_PersonalShortcutsPublishFile")
	Template := _DriverFuncBody("PersonalShortcutsTemplate")
	Policy := _DriverFuncBody("_PersonalShortcutsBootAllowsReload")
	Assert(Ensure != "" && Publish != "" && Template != "" && Policy != "",
		"the child must execute all actual bootstrap definitions")
	Ensure := RegExReplace(Ensure, "m)^[ 	]*Reload[ 	]*$", "_PSABChildReload()", &ReloadEffects)
	Ensure := StrReplace(Ensure, "ExitApp(0)", "_PSABChildExit(0)", , &ExitEffects)
	AssertEqual(1, ReloadEffects, "only the real terminal Reload effect is observed")
	AssertEqual(1, ExitEffects, "only the matching real ExitApp effect is observed")
	Lines := [
		"#Requires AutoHotkey v2.0", "#SingleInstance Off", "#Warn VarUnset, Off",
		'OnError(_PSABChildError)',
		'_PSABChildPolicyContract()',
		'global _PSABState := {Writes: 0, Moves: 0, Reloads: 0, Exits: 0, Continued: 0, Ack: 0, Failure: A_Args[3]}',
		'global _PSABPersonal := A_ScriptDir . "\personal.ahk"',
		'global _PSABStub := A_ScriptDir . "\_generated\personal_shortcuts.ahk"',
		'Held := _PSABState.Failure == "held" ? _ConfigWriteLeaseTryAcquire(_PSABStub, "fixture-held") : 0',
		'Ok := false',
		'try {',
		'Ok := EnsurePersonalShortcutsFile(_PSABPersonal, _PersonalShortcutsBootAllowsReload(Integer(A_Args[1]), Integer(A_Args[2])), _PSABChildWrite, _PSABChildMove, _PSABChildRead)',
		'if Ok',
		'_PSABState.Continued += 1',
		'} catch as Refusal {',
		'if Refusal.Message != "observed-source-terminal"',
		'throw Refusal',
		'} finally {',
		'if Held is Object',
		'_ConfigWriteLeaseRelease(Held)',
		'}',
		'FileAppend(Ok . "|" . _PSABState.Writes . "|" . _PSABState.Moves . "|" . _PSABState.Reloads . "|" . _PSABState.Exits . "|" . _PSABState.Continued . "|" . _PSABState.Ack, "*", "UTF-8-RAW")',
		'ExitApp(0)',
		'_PSABChildWrite(Path, Content) {',
		'global _PSABState',
		'_PSABState.Writes += 1',
		'if _PSABState.Failure == "write0"',
		'return false',
		'if _PSABState.Failure == "write2"',
		'return 2',
		'return FSWriteDurable(Path, Content)',
		'}',
		'_PSABChildRead(Path) {',
		'global _PSABState, _PSABStub',
		'if InStr(Path, ".stage") {',
		'if _PSABState.Failure == "read"',
		'return "independent mismatched stage"',
		'if _PSABState.Failure == "lost"',
		'_ConfigWriteLeaseRelease(_ConfigWriteLeaseCurrent(_PSABStub))',
		'}',
		'return FSReadUtf8Exact(Path)',
		'}',
		'_PSABChildMove(Stage, Path, CreateOnly) {',
		'global _PSABState',
		'_PSABState.Moves += 1',
		'if _PSABState.Failure == "move"',
		'return false',
		'return CreateOnly ? FSAtomicMoveCreate(Stage, Path) : FSAtomicMoveReplace(Stage, Path)',
		'}',
		'_PSABChildReload() {',
		'global _PSABState, _PSABPersonal, _PSABStub',
		'_PSABState.Reloads += 1',
		'_PSABState.Ack := FileExist(_PSABPersonal) && FileExist(_PSABStub) && SubStr(FSReadUtf8Exact(_PSABStub), 1, 1) == Chr(0xFEFF) && _ConfigWriteLeaseOwners().Count == 0',
		'}',
		'_PSABChildExit(Code) {',
		'global _PSABState',
		'if Code != 0',
		'throw Error("unexpected bootstrap exit code")',
		'_PSABState.Exits += 1',
		'throw Error("observed-source-terminal")',
		'}',
		'_PSABChildPolicyContract() {',
		'if !_PersonalShortcutsBootAllowsReload(false, false) || _PersonalShortcutsBootAllowsReload(true, false) || _PersonalShortcutsBootAllowsReload(false, true) || _PersonalShortcutsBootAllowsReload(true, true)',
		'throw Error("unexpected native bootstrap capability policy")',
		'for Bad in ["0", 2, Map()] {',
		'for Inputs in [[Bad, false], [false, Bad]] {',
		'Refused := false',
		'try _PersonalShortcutsBootAllowsReload(Inputs*)',
		'catch TypeError {',
		'Refused := true',
		'}',
		'if !Refused',
		'throw Error("invalid bootstrap capability was admitted")',
		'}',
		'}',
		'}',
		'_PSABChildError(Refusal, *) {',
		'FileAppend(Refusal.Message, "*", "UTF-8-RAW")',
		'ExitApp(2)',
		'}',
		Policy, Ensure, Publish, Template,
		"#Include " . FileOwner, "#Include " . LeaseOwner
	]
	return ArrayJoin(Lines, "`n") . "`n"
}

/** Each case owns its source directory, real source/stub bytes and exact child tree. */
_PSAB_CheckBootstrapCase(Compiled, Smoke, Kind, Failure, ExpectedReceipt) {
	Root := A_Temp . "\ergopti_bootstrap_" . A_ScriptHwnd . "_" . A_TickCount
	AssertFalse(DirExist(Root), "the bootstrap fixture directory is exclusively owned")
	DirCreate(Root)
	Ownership := {CanRetire: true}
	try {
		; A_Temp may use an 8.3 alias while the native child's A_ScriptDir
		; resolves its long spelling. Expected forwarding bytes must use that
		; same native identity, independently of the generated stub's contents.
		CanonicalBuffer := Buffer(65536, 0)
		CanonicalLength := DllCall("GetLongPathNameW", "Str", Root,
			"Ptr", CanonicalBuffer, "UInt", 32768, "UInt")
		Assert(CanonicalLength > 0 && CanonicalLength < 32768,
			"the created private bootstrap directory must resolve to its native long spelling")
		Root := StrGet(CanonicalBuffer, CanonicalLength, "UTF-16")
		Personal := Root . "\personal.ahk"
		Stub := Root . "\_generated\personal_shortcuts.ahk"
		ExpectedSource := Kind == "missing" ? Chr(0xFEFF) . PersonalShortcutsTemplate()
			: Chr(0xFEFF) . "; existing user-owned personal shortcut bytes`n"
		if Kind != "missing" {
			AssertTrue(FSWriteDurable(Personal, ExpectedSource))
			DirCreate(Root . "\_generated")
			AssertTrue(FSWriteDurable(Stub, Kind == "matched"
				? _PSAB_ExpectedForwardingBytes(Personal) : Chr(0xFEFF) . "; old user forwarding bytes`n"))
		}
		Harness := Root . "\bootstrap.ahk"
		FileAppend(_PSAB_ChildSource(_PSAB_NativeOwner("FSWriteDurable"),
			_PSAB_NativeOwner("_ConfigWriteLeaseTryAcquire")), Harness, "UTF-8")
		Observed := _PSAB_RunChild(Harness, [String(Compiled), String(Smoke), Failure], Ownership)
		AssertEqual(ExpectedReceipt, Observed, "actual generator effect receipt for " . Kind . "/" . Failure)
		if Kind == "missing" && Failure != "none" {
			AssertFalse(FileExist(Personal), "a refused initial stage cannot create a user source")
			AssertFalse(FileExist(Stub), "a refused initial source cannot create its forwarding stub")
		} else {
			AssertEqual(ExpectedSource, FSReadUtf8Exact(Personal), "the template or prior user-owned source stays byte-exact")
			AssertEqual(Failure == "none" ? _PSAB_ExpectedForwardingBytes(Personal)
				: Chr(0xFEFF) . "; old user forwarding bytes`n", FSReadUtf8Exact(Stub),
				"only an acknowledged durable stage can replace the exact forwarding bytes")
		}
	} finally {
		if Ownership.CanRetire
			DirDelete(Root, true)
	}
}

/** Both changed and missing compiled chains must remain resident after durability. */
_PSAB_CompiledAndSmokeContinue() {
	_PSAB_CheckBootstrapCase(true, false, "missing", "none", "1|2|2|0|0|1|0")
	_PSAB_CheckBootstrapCase(true, false, "changed", "none", "1|1|1|0|0|1|0")
	_PSAB_CheckBootstrapCase(true, false, "matched", "none", "1|0|0|0|0|1|0")
	_PSAB_CheckBootstrapCase(false, true, "missing", "none", "1|2|2|0|0|1|0")
}
Test("personal shortcuts: compiled capability and owned smoke continue only after real durable acknowledgement "
	. "(compiled-personal-bootstrap)", _PSAB_CompiledAndSmokeContinue)

/** Source mode still retires before any successor hook registration can continue. */
_PSAB_SourceTerminalHandoffRemains() {
	_PSAB_CheckBootstrapCase(false, false, "missing", "none", "0|2|2|1|1|0|1")
	_PSAB_CheckBootstrapCase(false, false, "changed", "none", "0|1|1|1|1|0|1")
	_PSAB_CheckBootstrapCase(false, false, "matched", "none", "1|0|0|0|0|1|0")
}
Test("personal shortcuts: real source generator still performs the terminal reload after publication "
	. "(compiled-personal-bootstrap)", _PSAB_SourceTerminalHandoffRemains)

/** Refused stages or ownership cannot authorize continuation or terminal effects. */
_PSAB_RefusedPublicationCannotContinue() {
	for Spec in [
		["write0", "0|1|0|0|0|0|0"], ["write2", "0|1|0|0|0|0|0"],
		["read", "0|1|0|0|0|0|0"], ["lost", "0|1|0|0|0|0|0"],
		["move", "0|1|1|0|0|0|0"], ["held", "0|0|0|0|0|0|0"]
	]
		_PSAB_CheckBootstrapCase(true, false, "changed", Spec[1], Spec[2])
	for Spec in [["write0", "0|1|0|0|0|0|0"], ["read", "0|1|0|0|0|0|0"], ["move", "0|1|1|0|0|0|0"]]
		_PSAB_CheckBootstrapCase(true, false, "missing", Spec[1], Spec[2])
	_PSAB_CheckBootstrapCase(false, false, "changed", "held", "0|0|0|0|0|0|0")
}
Test("personal shortcuts: compiled no-reload admission never forgives refused durable publication "
	. "(compiled-personal-bootstrap)", _PSAB_RefusedPublicationCannotContinue)
