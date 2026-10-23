; tests/unit/ui/webview/test_action_picker_startup_owner.ahk

; ==============================================================================
; MODULE: Action Picker Startup Cancellation Tests
; DESCRIPTION:
; The public picker runs unchanged in an owned child with real GUI/WM_CLOSE.
; Only browser construction and unrelated display/discovery data are passive;
; the shipped Promise pumps the real deferred Close before returning a browser.
; ==============================================================================

#Requires AutoHotkey v2.0

_APST_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_APST_ChildSource() {
	global _DriverDir, _SharedDir
	Owners := Map(), Includes := ""
	for Symbol in ["JsonStringLiteral", "ProgramProviderCatalogue", "_ActPickWeb_TryOpen", "ShowActionPicker"] {
		Root := Symbol == "ProgramProviderCatalogue" ? _SharedDir : _DriverDir
		Owner := _DriverProductionFileForSymbol(Symbol, Root)
		AssertTrue(Owner != "", "The child requires the unique genuine owner: " . Symbol)
		if !Owners.Has(Owner) {
			Owners[Owner] := true
			Includes .= "#Include " . Owner . "`n"
		}
	}
	AssertEqual(4, Owners.Count, "Each selected public/lifecycle/codec/policy owner is independently included")
	PromiseOwner := _DriverDir . "\vendor\Promise.ahk"
	Fixture := _DriverDir . "\tests\fixtures\action_picker_startup_owner_body.ahk"
	AssertTrue(FileExist(PromiseOwner) && FileExist(Fixture))
	return "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
		. "#Include " . PromiseOwner . "`n" . Includes . "#Include " . Fixture . "`n"
}

_APST_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unsettled earlier picker child must retire first")
	Directory := A_Temp . "\ergopti_picker_startup_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := { Code: -1, Output: "", ErrorText: "", Calls: 0 }, Handle := 0, Primary := 0, Retired := false
	PreviousCritical := Critical("Off")
	try {
		FSCreateDirectoryExclusiveStrict(Directory . "\64bit")
		; Availability must take its genuine filesystem branch. This inert marker
		; is never loaded: the browser factory is explicitly passive in the child.
		AssertTrue(FSWriteCreateDurable(Directory . "\64bit\WebView2Loader.dll", "private availability marker") != 0)
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _APST_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _APST_Complete.Bind(State))
		AssertTrue(Handle.start(), "The genuine public picker child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		for Line in StrSplit(State.Output, "`n", "`r")
			if InStr(Line, "RECEIPT action-picker-startup ") == 1
				_TestPrint("# " . Line)
		AssertEqual(1, State.Calls, "The exact picker child must settle once: " . State.ErrorText . State.Output)
		AssertEqual("", State.ErrorText, "Parser/runtime diagnostics cannot qualify as cancellation: " . State.Output)
		AssertEqual(0, State.Code, "The real picker violated startup ownership: " . State.Output)
		AssertContains(State.Output, "PASS action-picker-startup " . Mode)
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
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The exact child must retire before its private source is removed")
}

for _APST_Mode in ["current", "close-create", "close-create-reject", "reopen-create", "reopen-create-reject"]
	Test("Action picker startup: " . _APST_Mode . " retains only its current owner (action-picker-startup-owner)",
		_APST_Case.Bind(_APST_Mode))
