; tests/unit/modules/gestures/test_gesture_pause_admission.ahk

; ==============================================================================
; MODULE: Gesture Pre-Critical Pause Admission Regression
; DESCRIPTION:
; A real logger sink models a pause only before the real acquisition's Critical.
; Genuine dispatch, catalogue, invocation and native watcher remain intact.
; This controlled timing model does not prove native hotkey delivery or the
; complete suspend reactor. Mouse output alone is passive and explicitly bound.
; ==============================================================================

#Requires AutoHotkey v2.0

_GPO_Quote(Text) {
	return Chr(34) . StrReplace(StrReplace(Text, Chr(96), Chr(96) . Chr(96)), Chr(34), Chr(96) . Chr(34)) . Chr(34)
}

_GPO_CatalogueBlock(&Source) {
	Code := _DriverMaskNonCode(&Source)
	Pattern := "m)^global GESTURE_ACTIONS := Map\("
	AssertTrue(RegExMatch(Code, Pattern, &Header) > 0, "the actual registry must have one initial Map declaration")
	AssertFalse(RegExMatch(Code, Pattern, , Header.Pos + Header.Len), "the original registry declaration must be unique")
	Open := Header.Pos + Header.Len - 1
	Depth := 0, Finish := 0
	loop StrLen(Code) - Open + 1 {
		Position := Open + A_Index - 1
		Char := SubStr(Code, Position, 1)
		if Char == "("
			Depth += 1
		else if Char == ")" {
			Depth -= 1
			if !Depth {
				Finish := Position
				break
			}
		}
	}
	AssertTrue(Finish > Open, "the complete actual initial registry expression must close")
	return SubStr(Source, Header.Pos, Finish - Header.Pos + 1)
}

_GPO_MetadataOwner() {
	global _DriverDir
	Runner := FSReadStrict(A_ScriptFullPath)
	Code := _DriverMaskNonCode(&Runner)
	Owners := Map()
	Owners.CaseSense := "Off"
	for Line in StrSplit(Code, "`n", "`r") {
		if !RegExMatch(Line, "i)^\s*#Include\s+(\.\.[\\/]_generated[\\/][A-Za-z0-9_.-]+\.ahk)\s*$", &Include)
			continue
		Path := _DriverDir . "\" . SubStr(StrReplace(Include[1], "/", "\"), 4)
		Data := FSReadStrict(Path)
		Masked := _DriverMaskNonCode(&Data)
		Count := _DriverTopLevelDefinitionCount(&Masked, "GestureActionCatalogueData")
		if Count {
			AssertEqual(1, Count, "the actual generated metadata definition must be unique")
			AssertFalse(_DriverIsProductionSource(Path), "generated metadata must stay outside the authored resolver")
			Owners[Path] := true
		}
	}
	AssertEqual(1, Owners.Count, "the delivered suite must include the complete action metadata owner")
	for Path in Owners
		return Path
}

_GPO_Source(Owners) {
	global _DriverDir
	ClickOwner := _DriverProductionFileForSymbol("GestureOnKeyDown")
	AssertTrue(ClickOwner != "", "the actual click-hold owner must resolve uniquely")
	Original := FSReadStrict(ClickOwner)
	Code := _DriverMaskNonCode(&Original)
	RegExReplace(Code, "(?<![\w])Click\(", "", &MouseSites)
	StrReplace(Code, "Hook.Stop()", "", true, &StopSites)
	AssertEqual(6, MouseSites, "bind only the actual six mouse transport sites")
	AssertEqual(1, StopSites, "observe only the actual native Stop site")
	Bound := RegExReplace(Original, "(?<![\w])Click\(", "_GPO_Click(", &MouseBindings)
	Bound := StrReplace(Bound, "Hook.Stop()", "_GPO_Stop(Hook)", true, &StopBindings)
	AssertEqual(MouseSites, MouseBindings, "no comment or string may introduce a mouse substitution")
	AssertEqual(StopSites, StopBindings, "no comment or string may introduce a Stop substitution")
	AssertTrue(InStr(Bound, 'InputHook("V L3")', true) > 0, "native construction remains intact")
	Owners["click_owner_sha256"] := CryptoSha256Bytes(FSReadBytesStrict(ClickOwner))
	Owners["click_bindings"] := MouseBindings
	Owners["stop_observers"] := StopBindings
	Source := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn VarUnset, Off`n"
	Source .= "global _GPO_ActualOwnerHash := " . _GPO_Quote(Owners["click_owner_sha256"]) . "`n"
	Source .= "global _GPO_SourceShared := " . _GPO_Quote(_DriverDir . "\..\_shared") . "`n"
	Seen := Map()
	Imports := []
	Dispatcher := _GKO_DispatcherOwner()
	AssertTrue(_DriverIsProductionSource(Dispatcher) && InStr(FSReadStrict(Dispatcher), "class HookDispatcher {", true), "the complete real dispatcher must exist")
	Imports.Push(Dispatcher, _GPO_MetadataOwner())
	for Symbol in ["WallClockTimestamp", "CryptoSha256Bytes", "KL_JsonEncode", "JsonStringLiteral", "HotPath_Now", "GestureInvokeAction"] {
		Path := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Path != "" && _DriverFuncBody(Symbol) != "", "the genuine child dependency must be nonempty: " . Symbol)
		Imports.Push(Path)
	}
	ImportReceipts := []
	for Path in Imports {
		if !Seen.Has(Path) {
			Source .= "#Include " . Path . "`n"
			Seen[Path] := true
			ImportReceipts.Push(Map("path", Path, "sha256", CryptoSha256Bytes(FSReadBytesStrict(Path))))
		}
	}
	Owners["imports"] := ImportReceipts
	RouteReceipts := []
	for Symbol in ["GestureDispatch", "GestureReleaseOwnedCarrierModifiers"] {
		Body := _DriverFuncBody(Symbol)
		Path := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Body != "" && Path != "", "the actual route body must resolve: " . Symbol)
		RouteReceipts.Push(Map("symbol", Symbol, "owner_sha256", CryptoSha256Bytes(FSReadBytesStrict(Path)), "body_sha256", CryptoSha256(Body)))
		Source .= Body . "`n"
	}
	Owners["routes"] := RouteReceipts
	RegistryOwner := _DriverProductionFileForSymbol("GestureTranslateContext")
	AssertTrue(RegistryOwner != "", "the initial action registry owner must resolve")
	Registry := FSReadStrict(RegistryOwner)
	Block := _GPO_CatalogueBlock(&Registry)
	BlockCode := _DriverMaskNonCode(&Block)
	Position := 1, BareFunctions := []
	while RegExMatch(BlockCode, "\bFn\s*:\s*([A-Za-z_][A-Za-z0-9_]*)\s*[,}]", &Bare, Position) {
		Body := _DriverFuncBody(Bare[1])
		AssertTrue(Body != "", "a direct registry function reference must resolve genuinely")
		Source .= Body . "`n"
		BareFunctions.Push(Bare[1])
		Position := Bare.Pos + Bare.Len
	}
	AssertEqual(1, BareFunctions.Length, "the actual initial registry has one direct function dependency")
	AssertEqual("GestureTranslateContext", BareFunctions[1], "do not substitute an unrelated bare registry function")
	Owners["registry_sha256"] := CryptoSha256Bytes(FSReadBytesStrict(RegistryOwner))
	Owners["registry_block_sha256"] := CryptoSha256(Block)
	Owners["registry_bare_functions"] := BareFunctions
	Source .= Block . "`n" . Bound . "`n"
	Fixture := _DriverDir . "\tests\fixtures\gesture_pause_admission_body.ahk"
	Owners["fixture_sha256"] := CryptoSha256Bytes(FSReadBytesStrict(Fixture))
	return Chr(0xFEFF) . Source . FSReadStrict(Fixture)
}

_GPO_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_GPO_Case(Mode) {
	static Serial := 0, RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "an unretired native watcher child forbids another launch")
	Root := A_Temp . "\ergopti_gesture_pause_" . A_ScriptHwnd . "_" . ++Serial
	FSCreateDirectoryExclusiveStrict(Root)
	Script := Root . "\subject.ahk"
	Owners := Map()
	AssertTrue(FSWriteCreateDurable(Script, _GPO_Source(Owners)))
	Hash := CryptoSha256Bytes(FSReadBytesStrict(Script))
	RuntimeHash := CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
	_TestPrint("# gesture-pause-source-built " . KL_JsonEncode(Map("mode", Mode, "source_sha256", Hash,
		"runtime_sha256", RuntimeHash, "owners", Owners, "inputhook", "native", "callback_delivery", "controlled")))
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	Handle := 0, Primary := 0, Retired := false
	PreviousCritical := Critical("Off")
	try {
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Owners["click_owner_sha256"], Hash, RuntimeHash], _GPO_Complete.Bind(State))
		AssertTrue(Handle.start(), "the exact gesture pause admission child must start")
		Pid := Handle.processId()
		Started := A_TickCount
		while !State.Calls && TickElapsed(Started) < 10000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, State.Calls, "the native ownership child did not settle; native Start failure is a prerequisite: " . State.ErrorText . State.Output)
		Receipt := 0
		for Line in StrSplit(State.Output, "`n", "`r") {
			if InStr(Line, "OBSERVATION ") == 1
				_TestPrint("# gesture-pause " . Line)
			else if InStr(Line, "RECEIPT ") == 1 {
				_TestPrint("# gesture-pause " . Line)
				AssertFalse(IsObject(Receipt), "the child must emit one terminal receipt after native cleanup")
				Receipt := JsonParse(SubStr(Line, 9))
			}
		}
		AssertEqual(0, State.Code, "the actual gesture pause admission path failed: " . State.ErrorText . State.Output)
		AssertEqual("", State.ErrorText, "native diagnostics may not be hidden")
		AssertTrue(Receipt is Map, "a successful owned native cleanup receipt is required")
		AssertEqual(Pid, Receipt["pid"])
		AssertEqual(Mode, Receipt["mode"])
		AssertEqual(Hash, Receipt["source_sha256"])
		AssertEqual(RuntimeHash, Receipt["runtime_sha256"])
		AssertEqual(Owners["click_owner_sha256"], Receipt["click_owner_sha256"])
		AssertEqual("controlled", Receipt["callback_delivery"])
		AssertEqual(Mode == "admin-paused-quit", Receipt["administrative_native_exit"])
		AssertEqual(InStr(Mode, "paused-", true) == 1 ? 1 : 0, Receipt["pause_hits"])
		AssertTrue(Receipt["catalogue_genuine"])
		AssertTrue(Receipt["hooks_retired"])
		AssertTrue(Receipt["subscriptions_retired"])
		AssertFalse(Receipt["mouse_injected"])
		AssertFalse(Receipt["suspended"])
	} catch as Failure {
		Primary := Failure
	}
	try {
		if !IsObject(Handle)
			Retired := true
		else {
			Started := A_TickCount
			loop {
				Accepted := Handle.terminate()
				Retired := Accepted is Integer && Accepted == 1
				if Retired || TickElapsed(Started) >= 5000
					break
				_SR_TreePoll()
				Sleep(10)
			}
		}
	} catch as Failure {
		if !IsObject(Primary)
			Primary := Failure
	}
	try {
		if IsObject(Primary) {
			; A blocked native Start can settle only during physical retirement.
			; Preserve that late capture without replacing the watchdog failure.
			_TestPrint("# gesture-pause-final-capture " . KL_JsonEncode(Map("mode", Mode, "retired", Retired,
				"calls", State.Calls, "exit_code", State.Code, "stdout", SubStr(State.Output, 1, 16000),
				"stderr", SubStr(State.ErrorText, 1, 8000), "stdout_truncated", StrLen(State.Output) > 16000,
				"stderr_truncated", StrLen(State.ErrorText) > 8000)))
		}
	} catch as Failure {
		if !IsObject(Primary)
			Primary := Failure
	}
	try {
		if !Retired
			RetirementDebt := Handle
		else if !IsObject(Primary)
			DirDelete(Root, true)
	} finally Critical(PreviousCritical)
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "the exact child and its real native hooks must physically retire")
}

for _GPO_Mode in ["paused-left", "paused-right", "current-both", "admin-paused-quit"]
	Test("Gesture pause admission: " . _GPO_Mode . " (gesture-click-pause-admission)", _GPO_Case.Bind(_GPO_Mode))

#Include test_gesture_cycle_pause_owner.ahk
