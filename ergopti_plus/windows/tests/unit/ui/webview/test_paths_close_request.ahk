; tests/unit/ui/webview/test_paths_close_request_owner.ahk

; ==============================================================================
; MODULE: Paths Editor Request During Retirement Tests
; DESCRIPTION:
; The actual Close callback supplied by the subject is delegated exactly once
; through the real Gui.OnEvent registration. Native WM_DESTROY admits a public
; request, and a separate continuation observes the real handler's return.
; Browser and presentation data ports are passive; no OS browser is launched.
; ==============================================================================

#Requires AutoHotkey v2.0

_PCRT_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_PCRT_Quote(Text) {
	return Chr(34) . StrReplace(StrReplace(Text, Chr(96), Chr(96) . Chr(96)), Chr(34), Chr(96) . Chr(34)) . Chr(34)
}

; All lifecycle/public/window-manager declarations remain their whole owners.
; The child observes native event registration instead of copying or renaming a
; production Close handler or providing a second public request producer.
_PCRT_ChildSource() {
	global _DriverDir
	Code := "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
	Owners := Map()
	for Symbol in ["JsonStringLiteral", "FilePathsEditor", "_PathsEdWeb_TryOpen", "WMPresentWindow", "TickElapsed"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "The paths retirement child requires its whole genuine owner: " . Symbol)
		if !Owners.Has(Owner) {
			Owners[Owner] := true
			Code .= "#Include " . Owner . "`n"
		}
	}
	AssertEqual(5, Owners.Count, "The codec/public/host/native presentation/clock owners must be present")
	Fixture := _DriverDir . "\tests\fixtures\paths_close_request_body.ahk"
	AssertTrue(FileExist(Fixture))
	return Code . "#Include " . Fixture . "`n"
}

_PCRT_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unsettled earlier paths editor child must retire first")
	Directory := A_Temp . "\ergopti_paths_close_request_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
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
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _PCRT_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _PCRT_Complete.Bind(State))
		AssertTrue(Handle.start(), "The genuine public paths editor child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		; A forced terminal callback may populate captures during cleanup. Keep
		; the original deadline observation so termination can never turn it green.
		AtDeadline := { Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText }
		if State.Calls == 0
			Primary := Error("The exact paths editor child did not settle within 15000 ms; calls at deadline: 0.")
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
			_TestPrint("# paths-close-request terminal calls=" . State.Calls . " code=" . State.Code
				. " deadline_calls=" . (IsObject(AtDeadline) ? AtDeadline.Calls : -1)
				. " capture_delivered=" . (State.Calls == 1))
			if State.Calls == 1 {
				for Line in StrSplit(State.Output, "`n", "`r")
					if Line != ""
						_TestPrint("# paths-close-request combined_native_capture " . Line)
				for Line in StrSplit(State.ErrorText, "`n", "`r")
					if Line != ""
						_TestPrint("# paths-close-request completion_error " . Line)
			} else
				_TestPrint("# paths-close-request combined_native_capture UNKNOWN")
		}
	} catch as Failure {
		ExportFailure := Failure
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The exact child must retire before its private source is removed")
	AssertEqual(1, AtDeadline.Calls, "The exact paths editor child must settle once: " . State.ErrorText . State.Output)
	AssertEqual("", AtDeadline.ErrorText, "Parser/runtime diagnostics cannot qualify as cancellation: " . State.Output)
	AssertEqual(0, AtDeadline.Code, "The real paths editor violated startup ownership: " . State.Output)
	AssertContains(AtDeadline.Output, "PASS paths-close-request " . Mode)
	; A capture-export refusal cannot hide an earlier timeout/business failure,
	; nor can a successful child silently turn that refusal into a passing test.
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _PCRT_Mode in ["after-close", "during-close"]
	Test("Paths retirement request: " . _PCRT_Mode . " is retained after the actual Close returns (paths-close-request-owner)",
		_PCRT_Case.Bind(_PCRT_Mode))
