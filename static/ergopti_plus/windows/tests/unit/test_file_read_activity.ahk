; tests/unit/test_file_read_activity.ahk

; ==============================================================================
; MODULE: Exact Reader and Configuration Writer Interlock
; DESCRIPTION:
; Exercises shared read activity, borrowed writes and deferred full-save owners.
; A Win32 exact reader denies deletion, so an interrupted writer must retain its
; obligation and resume only after the reader releases its native handle.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include %A_LineFile%\..\..\..\infra\file_read_activity.ahk

_FRAI_Metadata() {
	Path := A_ScriptDir . "\read-interlock-config.toml"
	A := FileReadActivityEnter(Path)
	B := FileReadActivityEnter(StrUpper(StrReplace(Path, "\", "/")))
	try {
		AssertTrue(FileReadActivityBusy(Path))
		Attempt := _ConfigWriteLeaseTryAcquire(Path)
		if Attempt is Object
			_ConfigWriteLeaseRelease(Attempt)
		AssertFalse(Attempt is Object, "A same-path writer defers during both reads.")
		Other := _ConfigWriteLeaseTryAcquire(Path . ".other")
		AssertTrue(Other is Object, "Independent paths still make progress.")
		_ConfigWriteLeaseRelease(Other)
		AssertTrue(FileReadActivityLeave(A))
		AssertTrue(FileReadActivityBusy(Path))
		AssertFalse(FileReadActivityLeave(A))
		AssertFalse(FileReadActivityLeave({}))
		AssertFalse(ConfigWriteLeaseBusy(), "A reader does not become a foreign writer.")
		AssertTrue(ConfigMutationBusy(), "Mutation command deferral sees the interrupted reader.")
	} finally {
		FileReadActivityLeave(A)
		FileReadActivityLeave(B)
	}
	AssertFalse(FileReadActivityBusy(Path))
}

_FRAI_Terminal() {
	Path := A_ScriptDir . "\read-interlock-config.toml"
	Bundle := _ConfigWriteTerminalTryAcquire(Path)
	AssertTrue(Bundle is Object)
	try {
		Read := FileReadActivityEnter(Path)
		try {
			AssertTrue(_ConfigWriteLeaseOwns(Bundle.tokens[1], Path))
			AssertFalse(_ConfigWriteTerminalAuthorize(Bundle))
		} finally FileReadActivityLeave(Read)
		AssertTrue(_ConfigWriteTerminalAuthorize(Bundle))
		Read := FileReadActivityEnter(Path)
		try AssertFalse(_ConfigWriteTerminalClaimShutdown(Bundle))
		finally FileReadActivityLeave(Read)
		AssertTrue(_ConfigWriteTerminalClaimShutdown(Bundle))
	} finally _ConfigWriteTerminalRelease(Bundle)
}

_FRAI_WithRuntime(Body) {
	Runtime := _CFGFS_CaptureRuntime()
	Coordinator := _ConfigFullSaveCoordinator().Clone()
	try {
		_CFGFS_Prepare(A_ScriptDir . "\read-interlock-config.toml")
		Body.Call()
	} finally {
		_CFGFS_RestoreRuntime(Runtime)
		_ConfigFullSaveCoordinator(Coordinator)
	}
}

_FRAI_BorrowedWritesBody() {
	global ConfigurationFile, _CFGFS_WriterCalls
	Owner := _ConfigWriteLeaseTryAcquire(ConfigurationFile)
	AssertTrue(Owner is Object)
	try {
		Read := FileReadActivityEnter(ConfigurationFile)
		try {
			AssertFalse(ConfigCommitBorrowedUpdates(Owner, ConfigurationFile,
				_CFGFS_Collect(), "read-interlock", _CFGFS_Writer, _CFGFS_Notify))
			AssertFalse(ConfigCommitBuilt(ConfigurationFile, "read-interlock",
				() => {updates: _CFGFS_Collect()}, _CFGFS_Writer, _CFGFS_Notify, Owner))
			AssertEqual(0, _CFGFS_WriterCalls)
			AssertTrue(_ConfigWriteLeaseOwns(Owner, ConfigurationFile), "Busy read keeps borrowed authority current.")
		} finally FileReadActivityLeave(Read)
		{
			AssertTrue(ConfigCommitBorrowedUpdates(Owner, ConfigurationFile,
				_CFGFS_Collect(), "read-interlock", _CFGFS_Writer, _CFGFS_Notify))
			AssertEqual(1, _CFGFS_WriterCalls)
		}
	} finally _ConfigWriteLeaseRelease(Owner)
}

_FRAI_BorrowedFullSaveBody() {
	global ConfigurationFile, _CFGFS_WriterCalls
	Owner := _ConfigWriteLeaseTryAcquire(ConfigurationFile)
	AssertTrue(Owner is Object)
	try {
		Read := FileReadActivityEnter(ConfigurationFile)
		try {
			AssertEqual(CONFIG_SAVE_DEFERRED, SaveFullConfig(_CFGFS_Writer,
				_CFGFS_Timer, true, Owner, _CFGFS_Collect))
			AssertTrue(_ConfigFullSaveHasPending())
			AssertEqual(0, _CFGFS_WriterCalls)
			AssertTrue(_ConfigWriteLeaseOwns(Owner, ConfigurationFile))
		} finally FileReadActivityLeave(Read)
		{
			AssertEqual(CONFIG_SAVE_OK, _ConfigDrainFullSave(_CFGFS_Writer,
				_CFGFS_Timer, Owner, _CFGFS_Collect))
			AssertFalse(_ConfigFullSaveHasPending())
			AssertEqual(1, _CFGFS_WriterCalls)
		}
	} finally _ConfigWriteLeaseRelease(Owner)
}

_FRAI_CollectLeavingRead(State) {
	global ConfigurationFile
	State.Token := FileReadActivityEnter(ConfigurationFile)
	return _CFGFS_Collect()
}

_FRAI_CollectorDebtBody() {
	global _CFGFS_WriterCalls
	State := {Token: 0}
	try {
		AssertEqual(CONFIG_SAVE_DEFERRED, SaveFullConfig(_CFGFS_Writer,
			_CFGFS_Timer, true, 0, _FRAI_CollectLeavingRead.Bind(State)))
		AssertEqual(0, _CFGFS_WriterCalls, "Collection cannot bypass late reader admission.")
		AssertTrue(_ConfigFullSaveHasPending())
	} finally FileReadActivityLeave(State.Token)
	AssertEqual(CONFIG_SAVE_OK, _ConfigDrainFullSave(_CFGFS_Writer,
		_CFGFS_Timer, 0, _CFGFS_Collect))
	AssertFalse(_ConfigFullSaveHasPending())
	AssertEqual(1, _CFGFS_WriterCalls)
}

_FRAI_EmptyTerminalReadBody() {
	global ConfigurationFile
	Bundle := _ConfigWriteTerminalTryAcquire(ConfigurationFile)
	AssertTrue(Bundle is Object)
	try {
		AssertFalse(_ConfigFullSaveHasPending())
		Read := FileReadActivityEnter(ConfigurationFile)
		try AssertFalse(_ConfigFullSaveSettleTerminal(Bundle,
			_CFGFS_Writer, _CFGFS_Timer, _CFGFS_Collect))
		finally FileReadActivityLeave(Read)
		AssertTrue(_ConfigFullSaveSettleTerminal(Bundle,
			_CFGFS_Writer, _CFGFS_Timer, _CFGFS_Collect))
	} finally _ConfigWriteTerminalRelease(Bundle)
}

Test("exact reader: nested aliases and independent writers (read-write-interlock)", _FRAI_Metadata)
Test("exact reader: retained terminal authorization and claim (read-write-interlock)", _FRAI_Terminal)
Test("exact reader: borrowed targeted and built delivery (read-write-interlock)", _FRAI_WithRuntime.Bind(_FRAI_BorrowedWritesBody))
Test("exact reader: borrowed full save keeps and drains its generation (read-write-interlock)", _FRAI_WithRuntime.Bind(_FRAI_BorrowedFullSaveBody))
Test("exact reader: collector debt cannot reach the full writer (read-write-interlock)", _FRAI_WithRuntime.Bind(_FRAI_CollectorDebtBody))
Test("exact reader: no-save retained bundle still refuses debt (read-write-interlock)", _FRAI_WithRuntime.Bind(_FRAI_EmptyTerminalReadBody))


; Copy the actual dependencies into an isolated child before instrumenting its
; read boundaries. Production files and the parent runner remain unchanged.
_FRAI_ReplaceOnce(Source, Needle, Replacement) {
	AssertEqual(2, StrSplit(Source, Needle).Length, "The native injection boundary must occur exactly once.")
	return StrReplace(Source, Needle, Replacement)
}

; Locate the whole production module by its genuine symbol, not its source path.
; The framework rejects absent bodies; the recursive census rejects ambiguity.
_FRAI_NativeModuleSource(Name) {
	Body := _DriverFuncBody(Name)
	AssertTrue(StrLen(Body) > 0, "A native source owner requires its genuine nonempty function body.")
	AssertTrue(InStr(_StripFullLineComments(_DriverSourceConcat()), Body) > 0,
		"The native source owner must belong to the canonical complete driver census.")
	SplitPath(A_ScriptDir, , &Root)
	Matches := 0, Owner := 0
	Loop Files, Root . "\*.ahk", "FR" {
		if !_DriverIsProductionSource(A_LoopFileFullPath)
			continue
		Candidate := FileRead(A_LoopFileFullPath, "UTF-8")
		if !InStr(_StripFullLineComments(Candidate), Body)
			continue
		Matches += 1
		Content := FSReadUtf8Exact(A_LoopFileFullPath)
		AssertTrue(Content is String, "The actual module requires readable exact UTF-8 source bytes.")
		AssertTrue(InStr(_StripFullLineComments(Content), Body) > 0,
			"The captured exact module must still contain the same genuine native source owner.")
		Owner := {Path: A_LoopFileFullPath, Content: Content}
	}
	AssertEqual(1, Matches, "Exactly one production file must own the complete native function body.")
	return Owner
}

; Destinations come from the unchanged child fixture's own real include layout.
; Only these three fixture aliases are admitted; they never select driver paths.
_FRAI_CopyNativeModules(Directory, Fixture) {
	Symbols := Map("file_system.ahk", "_FSReadUtf8ExactImpl",
		"config_write_lease.ahk", "_ConfigWriteLeaseTryAcquire",
		"file_read_activity.ahk", "FileReadActivityEnter")
	FixtureSource := FileRead(A_ScriptDir . "\support\" . Fixture, "UTF-8")
	Published := Map()
	for Line in StrSplit(FixtureSource, "`n", "`r") {
		if !RegExMatch(Line, "^#Include[ `t]+([^ `t]+)[ `t]*$", &Include)
			continue
		Relative := StrReplace(Include[1], "/", "\")
		Parts := StrSplit(Relative, "\")
		AssertTrue(Parts.Length == 2 && (Parts[1] == "infra" || Parts[1] == "adapters")
			&& Symbols.Has(Parts[2]), "Only the fixture's declared relative module aliases are admitted.")
		Name := Symbols[Parts[2]]
		AssertFalse(Published.Has(Name), "A fixture alias cannot copy the same source owner twice.")
		Owner := _FRAI_NativeModuleSource(Name)
		Destination := Directory . "\" . Relative
		FileCopy(Owner.Path, Destination)
		AssertTrue(FSUtf8ExactMatches(Destination, Owner.Content),
			"The native child receives the entire exact module, including its declarations and includes.")
		Published[Name] := Destination
	}
	AssertEqual(Symbols.Count, Published.Count, "Every required native source owner must be present before launch.")
	return Published
}

_FRAI_RunNative(Mode) {
	Directory := A_Temp . "\ergopti-read-interlock-" . A_TickCount . "-" . Random(100000, 999999)
	DirCreate(Directory)
	DirCreate(Directory . "\infra")
	DirCreate(Directory . "\adapters")
	Fixture := Mode == "boundaries" ? "read_write_native.ahk" : "read_write_close.ahk"
	Published := _FRAI_CopyNativeModules(Directory, Fixture)
	Path := Published["_FSReadUtf8ExactImpl"]
	Source := FileRead(Path, "UTF-8")
	Start := InStr(Source, "_FSReadUtf8ExactImpl(Path, MaxBytes, Bounded) {")
	End := InStr(Source, Chr(10) . "; Admit only the target", true, Start)
	AssertTrue(Start > 0 && End > Start, "The actual reader body must exist before native instrumentation.")
	Body := SubStr(Source, Start, End - Start)
	if Mode == "boundaries" {
		Needle := Chr(9) . Chr(9) . 'Handle := DllCall("kernel32\CreateFileW",'
		Body := _FRAI_ReplaceOnce(Body, Needle,
			Chr(9) . Chr(9) . '_RW_Boundary(Path, "opening")' . Chr(10) . Needle)
		Needle := Chr(9) . Chr(9) . Chr(9) . "FileReadActivityBind(ReadActivity, Handle)"
		if InStr(Body, Needle)
			Body := _FRAI_ReplaceOnce(Body, Needle,
				Needle . Chr(10) . Chr(9) . Chr(9) . Chr(9) . '_RW_Boundary(Path, "held", Handle)')
		else {
			Needle := Chr(9) . Chr(9) . "ByteCount := 0"
			Body := _FRAI_ReplaceOnce(Body, Needle,
				Chr(9) . Chr(9) . '_RW_Boundary(Path, "held", Handle)' . Chr(10) . Needle)
		}
	} else {
		Body := _FRAI_ReplaceOnce(Body,
			'DllCall("kernel32\CloseHandle", "Ptr", Handle, "Int")', "_FRC_RefuseClose(Handle)")
	}
	Source := SubStr(Source, 1, Start - 1) . Body . SubStr(Source, End)
	FileDelete(Path)
	FileAppend(Source, Path, "UTF-8")
	FileCopy(A_ScriptDir . "\support\" . Fixture, Directory . "\probe.ahk")
	Quote := Chr(34)
	Command := Quote . A_AhkPath . Quote . " /ErrorStdOut=UTF-8 " . Quote . Directory . "\probe.ahk" . Quote . " " . Mode
	ExitCode := RunWait(Command, Directory, "Hide")
	ReceiptPath := Directory . "\native-results.log"
	AssertTrue(FileExist(ReceiptPath) != "", "The actual native child must publish its complete result: " . Directory)
	Receipt := FileRead(ReceiptPath, "UTF-8")
	AssertEqual(0, ExitCode, "The native child must exit naturally without failures: " . Receipt . " Fixture: " . Directory)
	if Mode == "boundaries" {
		AssertContains(Receipt, "# 5 passed, 0 failed.")
		AssertContains(Receipt, "boundary=opening denied=1 native-error=0 writer-critical=0")
		AssertContains(Receipt, "boundary=held denied=1 native-error=0 writer-critical=0")
	} else {
		AssertContains(Receipt, "PASS real-handle-retained read-false writer-denied mode=" . Mode)
		AssertContains(Receipt, "PASS actual-close-ack-writer-admitted")
	}
	DirDelete(Directory, true)
}

Test("exact reader: actual opening and held native timer boundaries (read-write-interlock)", _FRAI_RunNative.Bind("boundaries"))
Test("exact reader: refused native close retains exact handle debt (read-write-interlock)", _FRAI_RunNative.Bind("false"))
Test("exact reader: throwing native close retains exact handle debt (read-write-interlock)", _FRAI_RunNative.Bind("throw"))


; A real reader may interrupt a model timer. Its unchanged source must stay
; current while only write acquisition and mutation dispatch are deferred.
_FRAI_CommandInvoke(State, *) {
	State.Calls += 1
}

_FRAI_CommandArm(State, Callback, Period) {
	global MENU_COMMAND_DEFERRAL_RETRY_MS
	AssertEqual(MENU_COMMAND_DEFERRAL_RETRY_MS, Period)
	AssertFalse(State.Retry is Object, "One pending mutation command has one scheduled retry.")
	State.Retry := Callback
}

_FRAI_ReadKeepsDiscoveryCurrent() {
	Fixture := _LSJ_Fixture()
	try {
		Source := Fixture.World.Owner.Capture()
		AssertTrue(Source is LLM_Menu_ApiPrivateSourceReceipt)
		Dispatch := {Calls: 0, Retry: 0}
		Path := Fixture.World.ConfigPath
		Token := FileReadActivityEnter(Path)
		Handle := -1, OpeningReturned := false
		try {
			Handle := DllCall("kernel32\CreateFileW", "Str", Path,
				"UInt", 0x80000000, "UInt", 1, "Ptr", 0, "UInt", 3, "UInt", 0x80, "Ptr", 0, "Ptr")
			OpeningReturned := true
			AssertTrue(Handle != -1, "The regression requires an actual retained native reader.")
			FileReadActivityBind(Token, Handle)
			AssertTrue(FSHandleSnapshot(Handle).Get("ok", false))
			AssertTrue(Fixture.World.Owner.Current(Source), "Unchanged source authority survives a synchronous reader.")
			Attempt := _ConfigWriteLeaseTryAcquire(Path)
			if Attempt is Object
				_ConfigWriteLeaseRelease(Attempt)
			AssertFalse(Attempt is Object, "A real reader still excludes its writer.")
			AssertTrue(ConfigMutationBusy())
			MenuCommandRun(_FRAI_CommandInvoke.Bind(Dispatch), [], 0, 0, _FRAI_CommandArm.Bind(Dispatch))
			AssertEqual(0, Dispatch.Calls, "The real dispatcher must defer over native read ownership.")
			AssertTrue(Dispatch.Retry is Object)
			AssertTrue(Fixture.Native.Rescan())
			AssertEqual(Fixture.Order.Length, Fixture.Requests.Length, "No sibling factory is canceled by reader activity.")
			Generation := Fixture.Native.Controller.Generation
			for Index, Id in Fixture.Order {
				Body := Id == "lmstudio" ? '{"data":[{"id":"independent-joined"}]}' : '{"data":[]}'
				Fixture.Complete(Index, 200, Body)
			}
			AssertEqual(Generation, Fixture.Native.Controller.Generation)
			AssertFalse(Fixture.Native.Controller.IsSweeping())
			AssertEqual(0, Fixture.Native.Jobs.Count)
			AssertEqual(1, Fixture.Publications.Length)
			AssertTrue(Fixture.World.Owner.Current(Source))
		} finally {
			if Handle != -1 {
				AssertTrue(DllCall("kernel32\CloseHandle", "Ptr", Handle, "Int"), "The fixture must acknowledge its exact native close.")
				AssertTrue(FileReadActivityLeave(Token))
			} else if OpeningReturned
				AssertTrue(FileReadActivityLeave(Token))
		}
		Dispatch.Retry.Call()
		AssertEqual(1, Dispatch.Calls, "The same mutation command runs once after acknowledged reader close.")
	} finally Fixture.Dispose()
}

Test("exact reader: source authority and joined discovery survive native read debt (read-write-interlock)", _FRAI_ReadKeepsDiscoveryCurrent)
