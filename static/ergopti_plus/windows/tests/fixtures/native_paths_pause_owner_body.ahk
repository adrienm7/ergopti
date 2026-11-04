; tests/fixtures/native_paths_pause_owner_body.ahk

; ==============================================================================
; MODULE: Native Paths Editor Pause Admission Child
; DESCRIPTION:
; Genuine fallback GUI and its nested ConfirmPath callback receive native button
; events. The writer is an explicit refusal port; this test claims no persistence.
; ==============================================================================

#Requires AutoHotkey v2.0

_NPPA_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
t(Key) => Key
Gui_Create(Options := "", Title := "") {
	global _NPPA
	Window := Gui(Options, Title)
	_NPPA.Windows.Push({Gui: Window, Hwnd: Window.Hwnd})
	return Window
}
_NPPA_Write(Path) {
	global _NPPA
	_NPPA.Writes.Push({Path: Path, Paused: A_IsSuspended})
	return false
}
_NPPA_OnError(Failure, *) {
	global _NPPA
	if !IsObject(_NPPA.Failure)
		_NPPA.Failure := Failure
	return true
}
_NPPA_Pulse(*) {
	global _NPPA
	_NPPA.Pulses += 1
}
_NPPA_Observe() {
	global _NPPA
	Before := _NPPA.Pulses, Started := A_TickCount
	while _NPPA.Pulses - Before < 3 && TickElapsed(Started) < 1500
		Sleep(10)
	_NPPA_Require(_NPPA.Pulses - Before >= 3, "The native GUI event queue must be observed through fresh timer deliveries.")
	if IsObject(_NPPA.Failure)
		throw _NPPA.Failure
}
_NPPA_Click(Button, Expected) {
	global _NPPA
	DllCall("SendMessageW", "Ptr", Button.Hwnd, "UInt", 0xF5, "Ptr", 0, "Ptr", 0, "Ptr")
	Started := A_TickCount
	while _NPPA.Returned < Expected && !IsObject(_NPPA.Failure) && TickElapsed(Started) < 1500
		Sleep(10)
	_NPPA_Observe()
	_NPPA_Require(_NPPA.Entered == Expected && _NPPA.Returned == Expected,
		"The actual nested ConfirmPath closure must enter and return exactly once per native OK click.")
}
_NPPA_Exercise() {
	global _NPPA, _ConfigDir
	_NPPA_Require(!_PathsEdWeb_Available(), "The real unavailable browser branch must select the genuine native fallback.")
	FilePathsEditor()
	_NPPA_Require(_NPPA.Windows.Length == 1, "The actual public editor must create exactly one real native window.")
	Window := _NPPA.Windows[1].Gui
	Edit := 0, Button := 0
	for Control in Window {
		if Control.Type == "Edit"
			Edit := Control
		if Control.Type == "Button" && Control.Text == "button.ok"
			Button := Control
	}
	_NPPA_Require(IsObject(Edit) && IsObject(Button), "The original native edit and OK controls must resolve.")
	Candidate := A_Args[2] . "\changed\"
	Edit.Value := Candidate
	_NPPA_Require(Candidate != _ConfigDir, "The candidate must differ from the retained folder.")
	Suspend(true)
	try {
		_NPPA_Click(Button, 1)
		_NPPA_Require(_NPPA.Writes.Length == 0 && DllCall("IsWindowVisible", "Ptr", _NPPA.Windows[1].Hwnd, "Int")
			&& Edit.Value == Candidate, "A paused OK callback must not enter the writer or retire its exact native editor.")
	} finally Suspend(false)
	_NPPA_Observe()
	_NPPA_Require(_NPPA.Writes.Length == 0 && _NPPA.Returned == 1, "Resume alone must not replay a refused folder change.")
	_NPPA_Click(Button, 2)
	_NPPA_Require(_NPPA.Writes.Length == 1 && _NPPA.Writes[1].Path == Candidate && !_NPPA.Writes[1].Paused,
		"A fresh unpaused OK click must reach the writer admission once with the exact normalized candidate.")
	_NPPA_Require(DllCall("IsWindowVisible", "Ptr", _NPPA.Windows[1].Hwnd, "Int"),
		"The explicit writer refusal must keep the editor available for correction.")
}
_NPPA_Main() {
	global _NPPA, _VendorDir, _SharedDir, _ConfigDir, _DefaultConfigDir, _PathsFile
	if A_Args.Length != 2
		ExitApp(2)
	_NPPA := {Windows: [], Entered: 0, Returned: 0, Pulses: 0, Writes: [], Failure: 0}
	_VendorDir := A_Args[2], _SharedDir := A_Args[2] . "\shared"
	_ConfigDir := A_Args[2] . "\original\", _DefaultConfigDir := _ConfigDir, _PathsFile := A_Args[2] . "\paths.toml"
	Primary := 0
	OnError(_NPPA_OnError)
	try {
		SetTimer(_NPPA_Pulse, 10)
		_NPPA_Exercise()
	} catch Any as Failure
		Primary := IsObject(_NPPA.Failure) ? _NPPA.Failure : Failure
	finally {
		Suspend(false)
		SetTimer(_NPPA_Pulse, 0)
		for Window in _NPPA.Windows {
			try Window.Gui.Destroy()
			if DllCall("IsWindow", "Ptr", Window.Hwnd, "Int") && !IsObject(Primary)
				Primary := Error("The exact private native paths HWND failed to retire.")
		}
		OnError(_NPPA_OnError, 0)
	}
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8-RAW")
		ExitApp(1)
	}
	FileAppend("RECEIPT native-paths-pause entered=" . _NPPA.Entered . " returned=" . _NPPA.Returned
		. " writer_admissions=" . _NPPA.Writes.Length . "`nPASS native-paths-pause " . A_Args[1] . "`n", "*", "UTF-8-RAW")
	ExitApp(0)
}

_NPPA_Main()
