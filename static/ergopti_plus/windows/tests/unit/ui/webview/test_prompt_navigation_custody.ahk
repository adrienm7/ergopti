; tests/unit/ui/webview/test_prompt_navigation_custody.ahk

; ==============================================================================
; MODULE: Prompt Editor Navigation Custody Tests
; DESCRIPTION:
; Registered browser callbacks retain their exact native host. An old window
; cannot initialize a successor, while a reused host serves its current profile.
; ==============================================================================

#Requires AutoHotkey v2.0

_PNVT_ChildSource() {
	global _DriverDir
	Source := _PRST_ChildSource()
	Tail := "#Include " . _DriverDir . "\tests\fixtures\prompt_startup_owner_body.ahk`n"
	Offset := StrLen(Source) - StrLen(Tail) + 1
	AssertTrue(Offset > 0 && SubStr(Source, Offset) == Tail,
		"The canonical admitted child must expose its exact fixture footer.")
	Owners := ""
	for Symbol in ["WMPresentWindow", "WebView_SharedEnvironment", "Gui_Create"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "The exact public prompt host requires its genuine whole owner: " . Symbol)
		Owners .= "#Include " . Owner . "`n"
	}
	return SubStr(Source, 1, Offset - 1) . Owners
		. "#Include " . _DriverDir . "\vendor\ComVar.ahk`n"
		. "#Include " . _DriverDir . "\vendor\WebView2.ahk`n"
		. "#Include " . _DriverDir . "\tests\fixtures\prompt_navigation_custody_body.ahk`n"
}

_PNVT_Case(Mode) {
	global _DriverDir
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unsettled earlier prompt editor child must retire first")
	Directory := A_Temp . "\ergopti_prompt_navigation_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	FSCreateDirectoryExclusiveStrict(Directory)
	Script := Directory . "\subject.ahk"
	State := { Code: -1, Output: "", ErrorText: "", Calls: 0 }, Handle := 0, Primary := 0, Retired := false
	AtDeadline := 0, ExportFailure := 0
	PreviousCritical := Critical("Off")
	try {
		FSCreateDirectoryExclusiveStrict(Directory . "\64bit")
		; Availability uses the real shipped loader. SDK create and Promise await
		; remain genuine; the cached environment supplies passive COM effects.
		FileCopy(_DriverDir . "\vendor\64bit\WebView2Loader.dll", Directory . "\64bit\WebView2Loader.dll", false)
		AssertEqual(CryptoSha256Bytes(FSReadBytesStrict(_DriverDir . "\vendor\64bit\WebView2Loader.dll")),
			CryptoSha256Bytes(FSReadBytesStrict(Directory . "\64bit\WebView2Loader.dll")))
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _PNVT_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _PRST_Complete.Bind(State))
		AssertTrue(Handle.start(), "The genuine public prompt editor child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		; A forced terminal callback may populate captures during cleanup. Keep
		; the original deadline observation so termination can never turn it green.
		AtDeadline := { Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText }
		if State.Calls == 0
			Primary := Error("The exact prompt editor child did not settle within 15000 ms; calls at deadline: 0.")
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
			_TestPrint("# prompt-startup terminal calls=" . State.Calls . " code=" . State.Code
				. " deadline_calls=" . (IsObject(AtDeadline) ? AtDeadline.Calls : -1)
				. " capture_delivered=" . (State.Calls == 1))
			if State.Calls == 1 {
				for Line in StrSplit(State.Output, "`n", "`r")
					if Line != ""
						_TestPrint("# prompt-startup combined_native_capture " . Line)
				for Line in StrSplit(State.ErrorText, "`n", "`r")
					if Line != ""
						_TestPrint("# prompt-startup completion_error " . Line)
			} else
				_TestPrint("# prompt-startup combined_native_capture UNKNOWN")
		}
	} catch as Failure {
		ExportFailure := Failure
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The exact child must retire before its private source is removed")
	AssertEqual(1, AtDeadline.Calls, "The exact prompt editor child must settle once: " . State.ErrorText . State.Output)
	AssertEqual("", AtDeadline.ErrorText, "Parser/runtime diagnostics cannot qualify as cancellation: " . State.Output)
	AssertEqual(0, AtDeadline.Code, "The real prompt editor violated startup ownership: " . State.Output)
	AssertContains(AtDeadline.Output, "PASS prompt-navigation " . Mode)
	; A capture-export refusal cannot hide an earlier timeout/business failure,
	; nor can a successful child silently turn that refusal into a passing test.
	if IsObject(ExportFailure)
		throw ExportFailure
}


for _PNVT_Mode in ["current", "closed", "reopen", "repoint"]
	Test("Prompt navigation custody: " . _PNVT_Mode . " retains its exact native host (prompt-navigation-custody)",
		_PNVT_Case.Bind(_PNVT_Mode))
