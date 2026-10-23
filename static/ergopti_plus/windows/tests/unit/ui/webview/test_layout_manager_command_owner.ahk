; tests/unit/ui/webview/test_layout_manager_command_owner.ahk

; ==============================================================================
; MODULE: Layout Manager Queued Command Tests
; DESCRIPTION:
; Real public layout, catalogue and resume owners run in a private native child.
; Only the browser and transparent timer observation boundaries are passive.
; ==============================================================================

#Requires AutoHotkey v2.0

_LMCT_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_LMCT_Quote(Text) {
	return Chr(34) . StrReplace(StrReplace(Text, Chr(96), Chr(96) . Chr(96)), Chr(34), Chr(96) . Chr(34)) . Chr(34)
}

_LMCT_GeneratedOwner(Symbol) {
	global _DriverDir
	Matches := [], Scanned := 0
	Loop Files, _DriverDir . "\_generated\*.ahk", "F" {
		Source := FSReadStrict(A_LoopFileFullPath)
		Masked := _DriverMaskNonCode(&Source)
		Scanned += 1
		Count := _DriverTopLevelDefinitionCount(&Masked, Symbol)
		Loop Count
			Matches.Push(A_LoopFileFullPath)
	}
	AssertTrue(Scanned > 0, "The real generated declaration census must not be empty")
	AssertEqual(1, Matches.Length, "The genuine generated data export must be unique: " . Symbol)
	return Matches[1]
}

_LMCT_OverlayTimerOwner(Source) {
	Masked := _DriverMaskNonCode(&Source)
	Offsets := [], Position := 1
	while RegExMatch(Masked, "i)(?<![A-Za-z0-9_.])SetTimer(?=\s*\()", &Token, Position) {
		Offsets.Push(Token.Pos)
		Position := Token.Pos + Token.Len
	}
	AssertTrue(Offsets.Length > 0, "The whole actual layout host must have a nonempty native timer census")
	Result := "", Position := 1, Replaced := 0
	for Offset in Offsets {
		Result .= SubStr(Source, Position, Offset - Position) . "_LMCS_SetTimer"
		Position := Offset + StrLen("SetTimer")
		Replaced += 1
	}
	Result .= SubStr(Source, Position)
	AssertEqual(Offsets.Length, Replaced, "Only every actual builtin timer token may be observed")
	return Result
}

_LMCT_ChildSource() {
	global _DriverDir
	Code := _LRDT_ChildSource()
	Tail := "#Include " . _DriverDir . "\tests\fixtures\layer_editor_ready_delivery_body.ahk`n"
	AssertTrue(SubStr(Code, -StrLen(Tail)) == Tail, "The delivered real resume graph must retain its exact fixture boundary")
	Code := SubStr(Code, 1, StrLen(Code) - StrLen(Tail))
	for Symbol in ["UpdateChannelRegistryData", "UpdateScheduleData"]
		Code .= "#Include " . _LMCT_GeneratedOwner(Symbol) . "`n"
	Seen := Map()
	for Symbol in ["UpdateChannels_Ids", "UpdateSchedule_Timing", "Updater_IsLocalSource",
		"ErgoptiLayout_BuiltinVariant", "LayoutCatalogue_WriteInstalled"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "The public catalogue path requires its genuine whole owner: " . Symbol)
		AssertFalse(Seen.Has(Owner), "Every additional layout data owner must be distinct")
		Seen[Owner] := true
		Code .= "#Include " . Owner . "`n"
	}
	AssertEqual(5, Seen.Count, "The real catalogue, built-in data and source-mode refresh owners must all be present")
	Owner := _DriverProductionFileForSymbol("LayoutManager_Open")
	Source := FSReadStrict(Owner)
	for Symbol in ["LayoutManager_Open", "_LayMgrWeb_OnWebMessage", "_LayMgrWeb_SessionCall", "LayoutManager_HandleMessage"]
		AssertTrue(IsObject(_DriverFindFunctionDefinition(&Source, Symbol)), "The complete real SDK-to-consumer route must exist: " . Symbol)
	return Code . _LMCT_OverlayTimerOwner(Source) . "`n#Include " . _DriverDir . "\tests\fixtures\layout_manager_command_body.ahk`n"
}

_LMCT_Case(Mode) {
	global _SharedDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unsettled earlier layout manager child must retire first")
	Directory := A_Temp . "\ergopti_layout_manager_command_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := { Code: -1, Output: "", ErrorText: "", Calls: 0 }, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		FSCreateDirectoryExclusiveStrict(Directory . "\64bit")
		; Availability must take its genuine filesystem branch. This inert marker
		; is never loaded: the browser factory is explicitly passive in the child.
		AssertTrue(FSWriteCreateDurable(Directory . "\64bit\WebView2Loader.dll", "private availability marker") != 0)
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _LMCT_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory, _SharedDir], _LMCT_Complete.Bind(State))
		AssertTrue(Handle.start(), "The genuine public layout manager child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		; A forced terminal callback may populate captures during cleanup. Keep
		; the original deadline observation so termination can never turn it green.
		AtDeadline := { Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText }
		if State.Calls == 0
			Primary := Error("The exact layout manager child did not settle within 15000 ms; calls at deadline: 0.")
	} catch as Failure {
		Primary := Failure
	} finally {
		try {
			if IsObject(Handle) && State.Calls == 0
				Handle.requestTerminate()
			Receipt := IsObject(Handle) ? Handle.terminate() : 1
			Retired := (Receipt is Integer) && Receipt == 1
			if Retired
				DirDelete(Directory, true)
		} catch as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally {
			if IsObject(Handle) && !Retired
				RetirementDebt := { Handle: Handle, Directory: Directory }
			Critical(PreviousCritical)
		}
	}
	; The native adapter merges its child's stdout/stderr into Output. ErrorText
	; is a completion diagnostic, not an independently measured stderr stream.
	try {
		if Retired {
			_TestPrint("# layout-manager-command terminal calls=" . State.Calls . " code=" . State.Code
				. " deadline_calls=" . (IsObject(AtDeadline) ? AtDeadline.Calls : -1)
				. " capture_delivered=" . (State.Calls == 1))
			if State.Calls == 1 {
				for Line in StrSplit(State.Output, "`n", "`r")
					if Line != ""
						_TestPrint("# layout-manager-command combined_native_capture " . Line)
				for Line in StrSplit(State.ErrorText, "`n", "`r")
					if Line != ""
						_TestPrint("# layout-manager-command completion_error " . Line)
			} else
				_TestPrint("# layout-manager-command combined_native_capture UNKNOWN")
		}
	} catch as Failure {
		ExportFailure := Failure
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The exact child must retire before its private source is removed")
	AssertEqual(1, AtDeadline.Calls, "The exact layout manager child must settle once: " . State.ErrorText . State.Output)
	AssertEqual("", AtDeadline.ErrorText, "Parser/runtime diagnostics cannot qualify as cancellation: " . State.Output)
	AssertEqual(0, AtDeadline.Code, "The real layout manager violated queued command ownership: " . State.Output)
	AssertContains(AtDeadline.Output, "PASS layout-manager-command " . Mode)
	; A capture-export refusal cannot hide an earlier timeout/business failure,
	; nor can a successful child silently turn that refusal into a passing test.
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _LMCT_Mode in ["current-uninstall", "queued-pause", "retired-epoch"]
	Test("Layout manager command: " . _LMCT_Mode . " preserves admitted ownership (layout-manager-paused-command-owner)",
		_LMCT_Case.Bind(_LMCT_Mode))
