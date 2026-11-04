; tests/fixtures/live_dialog_button_body.ahk

; ==============================================================================
; MODULE: Live Dialog Button Fixture
; DESCRIPTION: Receive the genuine button press of the live harness on a dialog
; that does not hold the foreground, as when another program's window takes it.
; ==============================================================================

#Requires AutoHotkey v2.0

global LIVE_DEFAULT_TIMEOUT_MS := 1000
global LIVE_DIALOG_CLOSE_LIMIT_MS := 300
global _LiveUnclosedDialog := ""

LiveTrace(Line) {
	FileAppend("trace " . Line . "`n", "*", "UTF-8-RAW")
}

_LDB_Require(Condition, Detail) {
	if !Condition
		throw Error(Detail)
}

_LDB_Run(Mode) {
	Code := 1
	Dialog := Gui("-DPIScale", "Owned live dialog fixture")
	Other := Gui("-DPIScale", "Owned foreground fixture")
	Pressed := {Count: 0}
	try {
		Dialog.Add("Text", "w100", "Prompt")
		Button := Dialog.Add("Button", "w80", "OK")
		Button.OnEvent("Click", (*) => (Pressed.Count += 1, Mode == "refused" ? 0 : Dialog.Destroy()))
		if Mode == "disabled"
			Button.Enabled := false
		Hwnd := Dialog.Hwnd
		Dialog.Show("NoActivate w150 h100")
		Other.Show("w150 h100")
		Thrown := ""
		State := LiveDriveWindow(() => Hwnd, (Found) => LiveClickDialogButton("Button1", Found), 1000)
		try {
			LiveAwaitDrive(State, "the owned dialog")
			; A dialog that stays open is only known at the limit, as for a blocked opener.
			if Mode == "refused" {
				Started := A_TickCount
				while WinExist("ahk_id " . Hwnd) && A_TickCount - Started < 3000
					Sleep(10)
				LiveAwaitDrive(State, "the owned dialog")
			}
		} catch Error as Refusal
			Thrown := Refusal.Message
		Sleep(100)
		switch Mode {
			case "pressed":
				_LDB_Require(Thrown == "", "A press on a background dialog must succeed: " . Thrown)
				_LDB_Require(Pressed.Count == 1, "The button's own Click event must run once, got " . Pressed.Count)
				_LDB_Require(!WinExist("ahk_id " . Hwnd), "The event must have closed its dialog.")
			case "refused":
				_LDB_Require(Pressed.Count == 1, "The press must reach the button, got " . Pressed.Count)
				_LDB_Require(InStr(Thrown, "still open"), "An unclosed dialog must be reported, got: " . Thrown)
				_LDB_Require(!WinExist("ahk_id " . Hwnd), "An unclosed dialog must be closed to free its opener.")
			case "disabled":
				_LDB_Require(InStr(Thrown, "disabled"), "A greyed button cannot be pressed, got: " . Thrown)
				_LDB_Require(Pressed.Count == 0, "A greyed button must not run its event.")
			default:
				throw Error("Unknown mode " . Mode)
		}
		FileAppend("PASS live-dialog-button " . Mode . "`n", "*", "UTF-8-RAW")
		Code := 0
	} catch Error as Failure {
		FileAppend("FAIL live-dialog-button " . Mode . ": " . Failure.Message . "`n", "*", "UTF-8-RAW")
	}
	ExitApp(Code)
}

_LDB_Run(A_Args[1])
