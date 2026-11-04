; tests/unit/ui/webview/test_personal_toml_startup_owner.ahk

; ==============================================================================
; MODULE: Personal TOML Browser Startup Cancellation Tests
; DESCRIPTION:
; Three public editor controls exercise the real successful-constructor return
; after native Close/reopen. Browser surfaces and presentation remain passive;
; no page data/init/save or native fallback control is qualified by these cases.
; ==============================================================================

#Requires AutoHotkey v2.0

_PTST_Complete(State, Code, Output, ErrorText) {
	State.Code := Code, State.Output := Output, State.ErrorText := ErrorText
	State.Calls += 1
}

_PTST_ChildSource() {
	global _DriverDir
	Includes := "", Owners := Map()
	for Symbol in ["JsonStringLiteral", "OpenPersonalEditor", "_HsEdWeb_TryOpen", "FSReadBytesStrict", "CryptoSha256Bytes"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "The personal editor child requires its complete genuine owner: " . Symbol)
		if !Owners.Has(Owner) {
			Owners[Owner] := true
			Includes .= "#Include " . Owner . "`n"
		}
	}
	AssertEqual(5, Owners.Count, "The public/path/lifecycle/codec owners must all be genuine whole files")
	PromiseOwner := _DriverDir . "\vendor\Promise.ahk"
	Fixture := _DriverDir . "\tests\fixtures\personal_toml_startup_owner_body.ahk"
	AssertTrue(FileExist(PromiseOwner) && FileExist(Fixture))
	return "#Requires AutoHotkey v2.0`n#NoTrayIcon`n#SingleInstance Off`n#Warn All, StdOut`n#Warn VarUnset, Off`n"
		. "#Include " . PromiseOwner . "`n" . Includes . "#Include " . Fixture . "`n"
}

_PTST_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unsettled earlier personal editor child must retire first")
	Directory := A_Temp . "\ergopti_personal_toml_startup_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
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
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _PTST_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _PTST_Complete.Bind(State))
		AssertTrue(Handle.start(), "The genuine public personal editor child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		; A forced terminal callback may populate captures during cleanup. Keep
		; the original deadline observation so termination can never turn it green.
		AtDeadline := { Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText }
		if State.Calls == 0
			Primary := Error("The exact personal editor child did not settle within 15000 ms; calls at deadline: 0.")
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
			_TestPrint("# personal-toml-startup terminal calls=" . State.Calls . " code=" . State.Code
				. " deadline_calls=" . (IsObject(AtDeadline) ? AtDeadline.Calls : -1)
				. " capture_delivered=" . (State.Calls == 1))
			if State.Calls == 1 {
				for Line in StrSplit(State.Output, "`n", "`r")
					if Line != ""
						_TestPrint("# personal-toml-startup combined_native_capture " . Line)
				for Line in StrSplit(State.ErrorText, "`n", "`r")
					if Line != ""
						_TestPrint("# personal-toml-startup completion_error " . Line)
			} else
				_TestPrint("# personal-toml-startup combined_native_capture UNKNOWN")
		}
	} catch as Failure {
		ExportFailure := Failure
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The exact child must retire before its private source is removed")
	AssertEqual(1, AtDeadline.Calls, "The exact personal editor child must settle once: " . State.ErrorText . State.Output)
	AssertEqual("", AtDeadline.ErrorText, "Parser/runtime diagnostics cannot qualify as cancellation: " . State.Output)
	AssertEqual(0, AtDeadline.Code, "The real personal editor violated startup ownership: " . State.Output)
	AssertContains(AtDeadline.Output, "PASS personal-toml-startup " . Mode)
	; A capture-export refusal cannot hide an earlier timeout/business failure,
	; nor can a successful child silently turn that refusal into a passing test.
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _PTST_Mode in ["current", "close-create", "reopen-create"]
	Test("Personal TOML browser startup: " . _PTST_Mode . " retains only its current owner (personal-toml-startup-owner)",
		_PTST_Case.Bind(_PTST_Mode))
