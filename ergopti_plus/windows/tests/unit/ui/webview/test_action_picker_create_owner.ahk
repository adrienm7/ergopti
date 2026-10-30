; tests/unit/ui/webview/test_action_picker_create_owner.ahk

; ==============================================================================
; MODULE: Action Picker Native Construction Tests
; DESCRIPTION:
; Genuine native WM_CREATE opens a real public replacement before the older
; Gui constructor returns. The older opening must destroy only its private
; native window and preserve the successor's complete session and callback.
; ==============================================================================

#Requires AutoHotkey v2.0

_APCO_ChildSource() {
	global _DriverDir
	Source := _APST_ChildSource()
	Footer := "#Include " . _DriverDir . "\tests\fixtures\action_picker_startup_owner_body.ahk`n"
	Offset := StrLen(Source) - StrLen(Footer) + 1
	AssertTrue(Offset > 0 && SubStr(Source, Offset) == Footer,
		"The genuine public picker child must retain its exact fixture footer.")
	return SubStr(Source, 1, Offset - 1)
		. "#Include " . _DriverDir . "\tests\fixtures\action_picker_create_owner_body.ahk`n"
}

_APCO_Case(Mode) {
	static RetirementDebt := 0
	AssertFalse(IsObject(RetirementDebt), "An unsettled earlier picker child must retire first")
	Directory := A_Temp . "\ergopti_picker_create_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
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
		AssertTrue(FSWriteCreateDurable(Script, Chr(0xFEFF) . _APCO_ChildSource()) != 0)
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
			_TestPrint("# picker-create-owner terminal calls=" . State.Calls . " code=" . State.Code
				. " deadline_calls=" . (IsObject(AtDeadline) ? AtDeadline.Calls : -1)
				. " capture_delivered=" . (State.Calls == 1))
			if State.Calls == 1 {
				for Line in StrSplit(State.Output, "`n", "`r")
					if Line != ""
						_TestPrint("# picker-create-owner combined_native_capture " . Line)
				for Line in StrSplit(State.ErrorText, "`n", "`r")
					if Line != ""
						_TestPrint("# picker-create-owner completion_error " . Line)
			} else
				_TestPrint("# picker-create-owner combined_native_capture UNKNOWN")
		}
	} catch as Failure {
		ExportFailure := Failure
	}
	if IsObject(Primary)
		throw Primary
	AssertTrue(Retired, "The exact child must retire before its private source is removed")
	AssertEqual(1, AtDeadline.Calls, "The exact picker child must settle once: " . State.ErrorText . State.Output)
	AssertEqual("", AtDeadline.ErrorText, "Parser/runtime diagnostics cannot qualify as cancellation: " . State.Output)
	AssertEqual(0, InStr(AtDeadline.Output, "Warning:"), "The genuine child owners must pass #Warn All: " . AtDeadline.Output)
	AssertEqual(0, AtDeadline.Code, "The real picker violated native construction ownership: " . State.Output)
	AssertContains(AtDeadline.Output, "PASS picker-create-owner " . Mode)
	; A capture-export refusal cannot hide an earlier timeout/business failure,
	; nor can a successful child silently turn that refusal into a passing test.
	if IsObject(ExportFailure)
		throw ExportFailure
}

for _APCO_Mode in ["current", "reopen-create", "replace-during-close"]
	Test("Action picker native construction: " . _APCO_Mode . " retains the current owner (picker-create-owner)",
		_APCO_Case.Bind(_APCO_Mode))
