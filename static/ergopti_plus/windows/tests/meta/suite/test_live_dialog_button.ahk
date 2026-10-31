; tests/meta/suite/test_live_dialog_button.ahk

; ==============================================================================
; MODULE: Live Dialog Button
; DESCRIPTION: A live check answers a dialog from a timer while the thread that
; opened the dialog sits on top of the command waiting for the answer. A posted
; mouse click (ControlClick) is cancelled when another program takes the
; foreground between press and release: the dialog stayed open, the driver was
; idle, and the command gave no answer for 180 s with nothing logged
; (live-dialog-click-lost). The harness presses with the button's own
; notification and closes and reports a dialog that stays open.
; ==============================================================================

#Requires AutoHotkey v2.0

_LDB_ChildSource() {
	global _DriverDir
	Source := _DriverDirConcat("tests/live")
	Code := "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#NoTrayIcon`n#Warn All, StdOut`n"
	for Name in ["LiveWaitFor", "LiveDriveWindow", "_LiveDriveTick", "LiveAwaitDrive", "LiveClickDialogButton", "_LiveCloseUnanswered"] {
		Definition := _DriverFindFunctionDefinition(&Source, Name)
		AssertTrue(IsObject(Definition), "The live fixture requires the genuine function: " . Name)
		Code .= _DriverExtractDefinedBody(&Source, Definition) . "`n"
	}
	return Code . FileRead(_DriverDir . "\tests\fixtures\live_dialog_button_body.ahk", "UTF-8")
}

_LDB_Case(Mode) {
	Directory := A_Temp . "\ergopti-live-button-" . DllCall("Kernel32\GetCurrentProcessId", "UInt") . "-" . A_TickCount
	DirCreate(Directory)
	Child := Directory . "\probe.ahk"
	Observation := {Calls: 0, Code: -1, Output: "", Errors: ""}
	Handle := 0
	Completed(Code, Output, Errors) {
		Observation.Calls += 1
		Observation.Code := Code
		Observation.Output := Output
		Observation.Errors := Errors
	}
	PreviousCritical := Critical("Off")
	try {
		AssertTrue(!!FSWriteCreateDurable(Child, Chr(0xFEFF) . _LDB_ChildSource()), "The private fixture must publish completely.")
		Handle := ShellRunner_SpawnTreeOwned(A_AhkPath, ["/ErrorStdOut=UTF-8", Child, Mode], Completed)
		AssertTrue(Handle.start(), "The genuine live button child must start.")
		Started := A_TickCount
		while !Observation.Calls && TickElapsed(Started) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, Observation.Calls, "The exact child must publish one completion.")
		AssertEqual("", Observation.Errors, "Parse and transport errors cannot qualify: " . Observation.Output)
		AssertEqual(0, Observation.Code, "The live button must satisfy its oracle: " . Observation.Output)
		AssertContains(Observation.Output, "PASS live-dialog-button " . Mode)
		AssertFalse(!!InStr(Observation.Output, "Warning:"), "The child must remain warning-free.")
	} finally {
		try {
			if IsObject(Handle)
				AssertTrue(Handle.terminate(), "The exact child must retire before its source is removed.")
			DirDelete(Directory, true)
		} finally Critical(PreviousCritical)
	}
}

for _LDB_Mode in ["pressed", "refused", "disabled"]
	Test("live dialog button: " . _LDB_Mode . " on a background dialog (live-dialog-click-lost)", _LDB_Case.Bind(_LDB_Mode))

_LDB_NoPostedMouseClick() {
	Source := _StripFullLineComments(_DriverDirConcat("tests/live"))
	AssertTrue(InStr(Source, "LiveClickDialogButton(") > 0, "The live harness must be readable for this test.")
	AssertFalse(!!InStr(Source, "ControlClick("),
		"A live dialog must not be answered by a posted mouse click: another program's window cancels it.")
}
Test("live dialog button: no posted mouse click in the live checks (live-dialog-click-lost)", _LDB_NoPostedMouseClick)
