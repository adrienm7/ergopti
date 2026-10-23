; tests/unit/modules/gestures/test_gesture_keywatcher_owner.ahk

; ==============================================================================
; MODULE: Gesture Keyboard Watcher Ownership Regression
; DESCRIPTION:
; A private child runs the actual click-hold owner with real InputHook objects.
; Only mouse transport is passive; Stop is observed and immediately delegated.
; Callback delivery is controlled and does not prove native message ordering.
; ==============================================================================

#Requires AutoHotkey v2.0

_GKO_Quote(Text) {
	return Chr(34) . StrReplace(StrReplace(Text, Chr(96), Chr(96) . Chr(96)), Chr(34), Chr(96) . Chr(34)) . Chr(34)
}

_GKO_Source(OwnerReceipt) {
	global _DriverDir
	Owner := _DriverProductionFileForSymbol("GestureOnKeyDown")
	AssertTrue(Owner != "", "the actual gesture callback must have one canonical owner")
	Original := FSReadStrict(Owner)
	for Name in ["GestureToggleLeftClick", "GestureReleaseLeftClick", "GestureStartKeyboardWatcher",
		"GestureStopKeyboardWatcher", "GestureOnKeyDown", "GestureToggleRightClick", "GestureReleaseRightClick"] {
		AssertEqual(Owner, _DriverProductionFileForSymbol(Name), "all subject bodies must come from the same actual owner")
		AssertTrue(_DriverExtractFunctionBody(&Original, Name) != "", "the actual subject must be nonempty: " . Name)
	}
	Code := _DriverMaskNonCode(&Original)
	RegExReplace(Code, "(?<![\w])Click\(", "", &ClickSites)
	AssertEqual(6, ClickSites, "bind exactly the six genuine native mouse sites")
	StrReplace(Code, "Hook.Stop()", "", true, &StopSites)
	AssertEqual(1, StopSites, "observe exactly the genuine native Stop site")
	Bound := RegExReplace(Original, "(?<![\w])Click\(", "_GKO_Click(", &ClickBindings)
	Bound := StrReplace(Bound, "Hook.Stop()", "_GKO_Stop(Hook)", true, &StopBindings)
	AssertEqual(ClickSites, ClickBindings, "no additional mouse site may be changed in comments or strings")
	AssertEqual(StopSites, StopBindings, "no additional Stop site may be changed in comments or strings")
	AssertTrue(InStr(Bound, 'InputHook("V L3")', true) > 0, "InputHook construction remains native")
	OwnerReceipt["click_owner"] := Owner
	OwnerReceipt["click_owner_sha256"] := CryptoSha256Bytes(FSReadBytesStrict(Owner))
	OwnerReceipt["click_bindings"] := ClickBindings
	OwnerReceipt["stop_observers"] := StopBindings
	Source := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn VarUnset, Off`n"
	Source .= "global _GKO_ActualOwnerHash := " . _GKO_Quote(OwnerReceipt["click_owner_sha256"]) . "`n"
	Seen := Map()
	Dispatcher := _DriverDir . "\infra\hook_dispatcher.ahk"
	AssertTrue(_DriverIsProductionSource(Dispatcher), "the real dispatcher owner must be authored production")
	AssertTrue(InStr(FSReadStrict(Dispatcher), "class HookDispatcher {", true) > 0, "the actual dispatcher class must exist")
	OwnerReceipt["dispatcher_sha256"] := CryptoSha256Bytes(FSReadBytesStrict(Dispatcher))
	; The encoder delegates string escaping to the separate canonical JSON owner.
	JsonOwner := _DriverProductionFileForSymbol("JsonStringLiteral")
	AssertTrue(JsonOwner != "" && _DriverFuncBody("JsonStringLiteral") != "", "the real encoder string dependency must be nonempty")
	OwnerReceipt["json_string_owner_sha256"] := CryptoSha256Bytes(FSReadBytesStrict(JsonOwner))
	for Path in [Dispatcher, _DriverProductionFileForSymbol("WallClockTimestamp"),
		_DriverProductionFileForSymbol("CryptoSha256Bytes"), _DriverProductionFileForSymbol("KL_JsonEncode"), JsonOwner] {
		AssertTrue(Path != "", "the real child dependency must have a complete canonical owner")
		if !Seen.Has(Path) {
			Source .= "#Include " . Path . "`n"
			Seen[Path] := true
		}
	}
	Body := FSReadStrict(_DriverDir . "\tests\fixtures\gesture_keywatcher_owner_body.ahk")
	AssertTrue(Body != "", "the isolated native ownership fixture must exist")
	OwnerReceipt["fixture_sha256"] := CryptoSha256Bytes(FSReadBytesStrict(_DriverDir . "\tests\fixtures\gesture_keywatcher_owner_body.ahk"))
	return Chr(0xFEFF) . Source . Bound . "`n" . Body
}

_GKO_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_GKO_Case(Mode) {
	static Serial := 0, RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "an unretired native watcher child forbids another launch")
	Root := A_Temp . "\ergopti_gesture_keywatcher_" . A_ScriptHwnd . "_" . ++Serial
	FSCreateDirectoryExclusiveStrict(Root)
	Script := Root . "\subject.ahk"
	Owners := Map()
	AssertTrue(FSWriteCreateDurable(Script, _GKO_Source(Owners)))
	Hash := CryptoSha256Bytes(FSReadBytesStrict(Script))
	RuntimeHash := CryptoSha256Bytes(FSReadBytesStrict(A_AhkPath))
	_TestPrint("# gesture-keywatcher-source-built " . KL_JsonEncode(Map("mode", Mode, "source_sha256", Hash,
		"runtime_sha256", RuntimeHash, "owners", Owners, "inputhook", "native", "callback_delivery", "controlled")))
	State := {Calls: 0, Code: -1, Output: "", ErrorText: ""}
	Handle := 0, Primary := 0, Retired := false
	PreviousCritical := Critical("Off")
	try {
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Owners["click_owner_sha256"], Hash, RuntimeHash], _GKO_Complete.Bind(State))
		AssertTrue(Handle.start(), "the exact gesture ownership child must start")
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
				_TestPrint("# gesture-keywatcher " . Line)
			else if InStr(Line, "RECEIPT ") == 1 {
				_TestPrint("# gesture-keywatcher " . Line)
				AssertFalse(IsObject(Receipt), "the child must emit one terminal receipt after native cleanup")
				Receipt := JsonParse(SubStr(Line, 9))
			}
		}
		AssertEqual(0, State.Code, "the actual gesture ownership path failed: " . State.ErrorText . State.Output)
		AssertEqual("", State.ErrorText, "native diagnostics may not be hidden")
		AssertTrue(Receipt is Map, "a successful owned native cleanup receipt is required")
		AssertEqual(Pid, Receipt["pid"])
		AssertEqual(Mode, Receipt["mode"])
		AssertEqual(Hash, Receipt["source_sha256"])
		AssertEqual(RuntimeHash, Receipt["runtime_sha256"])
		AssertEqual(Owners["click_owner_sha256"], Receipt["click_owner_sha256"])
		AssertEqual("controlled", Receipt["callback_delivery"])
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
			_TestPrint("# gesture-keywatcher-final-capture " . KL_JsonEncode(Map("mode", Mode, "retired", Retired,
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

for _GKO_Mode in ["retired-left-right", "retired-right-left", "current-left-right", "current-right-left",
	"paused-left-up-refusal", "paused-right-up-refusal"]
	Test("Gesture watcher ownership: " . _GKO_Mode . " (gesture-keywatcher-owner)", _GKO_Case.Bind(_GKO_Mode))
