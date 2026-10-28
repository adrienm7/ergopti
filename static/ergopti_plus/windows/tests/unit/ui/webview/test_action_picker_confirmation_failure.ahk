; tests/unit/ui/webview/test_action_picker_confirmation_failure.ahk

; ==============================================================================
; MODULE: Action Picker Confirmation Failure Tests
; DESCRIPTION:
; Real public opening, native close and the central logger run unchanged.
; Failed caller callbacks must reach the actual ERROR ring and pending queue;
; browser effects are passive and healthy confirmation remains successful.
; ==============================================================================

#Requires AutoHotkey v2.0

_APCF_ChildSource() {
	global _DriverDir
	Source := _APST_ChildSource()
	Footer := "#Include " . _DriverDir . "\tests\fixtures\action_picker_startup_owner_body.ahk`n"
	Offset := StrLen(Source) - StrLen(Footer) + 1
	AssertTrue(Offset > 0 && SubStr(Source, Offset) == Footer,
		"The genuine public picker child must retain its exact fixture footer.")
	Includes := ""
	for Symbol in ["LoggerRingBufferSnapshot", "WallClockTimestamp", "TickElapsed"] {
		Owner := _DriverProductionFileForSymbol(Symbol)
		AssertTrue(Owner != "", "The central error delivery child requires its genuine whole owner: " . Symbol)
		Includes .= "#Include " . Owner . "`n"
	}
	return SubStr(Source, 1, Offset - 1) . Includes
		. "#Include " . _DriverDir . "\tests\fixtures\action_picker_confirmation_failure_body.ahk`n"
}

_APCF_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unsettled earlier picker child must retire first")
	Directory := A_Temp . "\ergopti_picker_confirm_error_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
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
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _APCF_ChildSource()) != 0)
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
			["/ErrorStdOut=UTF-8", Script, Mode, Directory], _APST_Complete.Bind(State))
		AssertTrue(Handle.start(), "The genuine public picker child must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		; A forced terminal callback may populate captures during cleanup. Keep
		; the original deadline observation so termination can never turn it green.
		AtDeadline := { Calls: State.Calls, Code: State.Code, Output: State.Output, ErrorText: State.ErrorText }
		if State.Calls == 0
			Primary := Error("The exact picker child did not settle within 15000 ms; calls at deadline: 0.")
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
			_TestPrint("# action-picker-confirmation-failure terminal calls=" . State.Calls . " code=" . State.Code
				. " deadline_calls=" . (IsObject(AtDeadline) ? AtDeadline.Calls : -1)
				. " capture_delivered=" . (State.Calls == 1))
			if State.Calls == 1 {
				for Line in StrSplit(State.Output, "`n", "`r")
					if Line != ""
						_TestPrint("# action-picker-confirmation-failure combined_native_capture " . Line)
				for Line in StrSplit(State.ErrorText, "`n", "`r")
					if Line != ""
						_TestPrint("# action-picker-confirmation-failure completion_error " . Line)
			} else
				_TestPrint("# action-picker-confirmation-failure combined_native_capture UNKNOWN")
		}
	} catch as Failure {
		ExportFailure := Failure
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The exact child must retire before its private source is removed")
	AssertEqual(1, AtDeadline.Calls, "The exact picker child must settle once: " . State.ErrorText . State.Output)
	AssertEqual("", AtDeadline.ErrorText, "Parser/runtime diagnostics cannot qualify as cancellation: " . State.Output)
	AssertEqual(0, InStr(AtDeadline.Output, "Warning:"), "The genuine composed owners must pass #Warn All without warnings: " . AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, "The real picker violated confirmation ownership: " . State.Output)
	AssertContains(AtDeadline.Output, "PASS action-picker-confirmation-failure " . Mode)
	; A capture-export refusal cannot hide an earlier timeout/business failure,
	; nor can a successful child silently turn that refusal into a passing test.
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _APCF_Mode in ["current", "error", "empty-error", "string-error", "map-error"]
	Test("Action picker confirmation: " . _APCF_Mode . " reaches the real logger (action-picker-confirmation-failure)",
		_APCF_Case.Bind(_APCF_Mode))
