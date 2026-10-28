; tests/fixtures/live_drive_failure_body.ahk

; ==============================================================================
; MODULE: Live Drive Failure Fixture
; DESCRIPTION: Receive real window-driving timers and their public await result.
; An exact Error observer records a matcher failure without granting it success.
; ==============================================================================

#Requires AutoHotkey v2.0

global LIVE_DEFAULT_TIMEOUT_MS := 1000

_LDF_Require(Condition, Detail) {
	if !Condition
		throw Error(Detail)
}

_LDF_Action(Observation, Mode, Hwnd) {
	Observation.Calls += 1
	Observation.Hwnd := Hwnd
	if Mode == "empty-error"
		throw Error("")
	if Mode == "message-error"
		throw Error("Owned live action refusal")
}

_LDF_Matcher(Observation, *) {
	Observation.Matches += 1
	throw Observation.Failure
}

_LDF_Unhandled(Observation, Failure, *) {
	if Failure != Observation.Failure
		return 0
	Observation.Unhandled += 1
	SetTimer(Observation.State.Tick, 0)
	return 1
}

_LDF_Run(Mode) {
	Window := Gui("-DPIScale", "Owned live drive failure fixture")
	Observation := {Calls: 0, Matches: 0, Hwnd: 0, Unhandled: 0,
		Failure: Error("Owned live matcher refusal"), State: 0}
	ErrorObserver := _LDF_Unhandled.Bind(Observation)
	Drive := 0
	Code := 1
	try {
		Window.Show("Hide w150 h100")
		Missing := Mode == "optional" || Mode == "required"
		Matcher := Mode == "matcher-error" ? _LDF_Matcher.Bind(Observation)
			: Missing ? (*) => 0 : (*) => Window.Hwnd
		OnError(ErrorObserver)
		Drive := LiveDriveWindow(Matcher, _LDF_Action.Bind(Observation, Mode), Missing ? 80 : 1000,
			Mode == "optional")
		Observation.State := Drive
		if Mode == "matcher-error" {
			Started := A_TickCount
			while !Drive.Done && !Observation.Unhandled && A_TickCount - Started < 1000
				Sleep(10)
			_LDF_Require(Drive.Done, "A matcher failure must publish terminal state instead of escaping its timer.")
		}
		Threw := false
		Diagnostic := ""
		try LiveAwaitDrive(Drive, "the owned live window")
		catch Error as Refusal {
			Threw := true
			Diagnostic := Refusal.Message
		}
		ExpectedFailure := Mode != "healthy" && Mode != "optional"
		_LDF_Require(Threw == ExpectedFailure, "The public await must preserve every action, matcher and timeout failure.")
		_LDF_Require(Drive.Done, "The real timer must acknowledge terminal state.")
		_LDF_Require(Observation.Unhandled == 0, "The live timer must contain and retain its own callback failure.")
		ExpectedCalls := Missing || Mode == "matcher-error" ? 0 : 1
		_LDF_Require(Observation.Calls == ExpectedCalls, "Only an admitted real window may reach its action once.")
		if ExpectedCalls
			_LDF_Require(Observation.Hwnd == Window.Hwnd, "The exact native window must reach the action.")
		if Mode == "message-error"
			_LDF_Require(InStr(Diagnostic, "Owned live action refusal", true), "The original action diagnosis must survive.")
		if Mode == "matcher-error" {
			_LDF_Require(Observation.Matches == 1, "The failed matcher must not remain a repeating timer.")
			_LDF_Require(InStr(Diagnostic, "Owned live matcher refusal", true), "The original matcher diagnosis must survive.")
		}
		if Mode == "empty-error"
			_LDF_Require(InStr(Diagnostic, "the owned live window", true), "An empty error must retain its live-check context.")
		Sleep(100)
		_LDF_Require(Observation.Calls == ExpectedCalls, "A retired timer must not replay its native action.")
		FileAppend("PASS live-drive-failure " . Mode . "`n", "*", "UTF-8-RAW")
		Code := 0
	} catch Error as Failure {
		FileAppend("FAIL live-drive-failure " . Mode . ": " . Failure.Message . "`n", "*", "UTF-8-RAW")
	} finally {
		OnError(ErrorObserver, 0)
		if IsObject(Drive)
			SetTimer(Drive.Tick, 0)
		Window.Destroy()
	}
	ExitApp(Code)
}

_LDF_Run(A_Args[1])
