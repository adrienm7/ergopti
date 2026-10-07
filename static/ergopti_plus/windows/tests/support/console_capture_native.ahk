; tests/support/console_capture_native.ahk

; ==============================================================================
; MODULE: Native Console Capture Boundary Probe
; DESCRIPTION:
; Reads the actual runtime Edit and records whole-acquisition native visibility
; and foreground events. Private sentinel text never leaves this child. The
; production console adapter supplies the real public ListVars/KeyHistory calls.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut
#ErrorStdOut
; _CNP_PRODUCTION_INCLUDE

global _CNPShowEvents := 0
global _CNPForegroundEvents := 0
global _CNPSentinel := "CNP_OLD_VALUE_8291"

try {
	if A_Args.Length != 2
		throw ValueError("The native capture probe requires kind and operation.")
	_CNP_Run(A_Args[1], A_Args[2])
	ExitApp(0)
} catch as Failure {
	FileAppend(Failure.Message, "*", "UTF-8-RAW")
	ExitApp(2)
}

/** Records events for the runtime HWND, including transitions later restored. */
_CNP_Event(Hook, Event, Hwnd, ObjectId, ChildId, ThreadId, Time) {
	global _CNPShowEvents, _CNPForegroundEvents
	if Hwnd != A_ScriptHwnd
		return
	if Event == 0x8002 && ObjectId == 0 && ChildId == 0
		_CNPShowEvents += 1
	if Event == 3
		_CNPForegroundEvents += 1
}

/** Fails with a fixed, public assertion instead of disclosing native debug text. */
_CNP_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

/** Identifies only the owned variable line or foreground header, never a copy. */
_CNP_HasMarker(Text, Kind, Marker) {
	Pattern := Kind == "list_vars" ? "m)^_CNPSentinel\[\d+ of \d+\]: " . Marker . "\r?$"
		: "m)^" . Marker . "\r?$"
	return !!RegExMatch(Text, Pattern)
}

/** Requires the exact owned witness foreground, thread, process and child focus. */
_CNP_RequireWitness(Witness, WitnessEdit, Pid, MainThread) {
	Thread := DllCall("GetWindowThreadProcessId", "Ptr", Witness.Hwnd, "UInt*", &OwnerPid := 0, "UInt")
	_CNP_Require(OwnerPid == Pid && Thread == MainThread
		&& DllCall("GetParent", "Ptr", WitnessEdit.Hwnd, "Ptr") == Witness.Hwnd
		&& DllCall("GetForegroundWindow", "Ptr") == Witness.Hwnd
		&& DllCall("GetFocus", "Ptr") == WitnessEdit.Hwnd,
		"Acquisition requires the exact owned witness foreground and child focus.")
}

/** Exercises one real public acquisition against independently owned sentinels. */
_CNP_Run(Kind, Operation) {
	global _CNPSentinel, _CNPShowEvents, _CNPForegroundEvents
	_CNP_Require(Kind == "list_vars" || Kind == "key_history", "Unknown native view.")
	_CNP_Require(Operation == "cached" || Operation == "public" || Operation == "restore"
		|| (Operation == "capacity" && Kind == "key_history"), "Unknown native operation.")
	DetectHiddenWindows(true)
	Main := A_ScriptHwnd
	Title := WinGetTitle("ahk_id " . Main)
	Pid := DllCall("GetCurrentProcessId", "UInt")
	_CNP_Require(!DllCall("IsWindowVisible", "Ptr", Main), "The source runtime must start hidden.")
	_CNP_Require(WinGetClass("ahk_id " . Main) == "AutoHotkey", "The source must be the native runtime.")
	Edit := DllCall("GetDlgItem", "Ptr", Main, "Int", 1, "Ptr")
	_CNP_Require(Edit && DllCall("GetParent", "Ptr", Edit, "Ptr") == Main,
		"The Edit must belong to this exact runtime.")
	_CNP_Require(WinGetClass("ahk_id " . Edit) == "Edit", "The source must be the native Edit.")
	EditThread := DllCall("GetWindowThreadProcessId", "Ptr", Edit, "UInt*", &EditPid := 0, "UInt")
	MainThread := DllCall("GetWindowThreadProcessId", "Ptr", Main, "UInt*", &MainPid := 0, "UInt")
	_CNP_Require(EditPid == Pid && MainPid == Pid && EditThread == MainThread,
		"Native capture must retain process and thread ownership.")
	ReadOnly := !!(WinGetStyle("ahk_id " . Edit) & 0x800)
	_CNP_Require(ReadOnly, "The runtime Edit must retain its native read-only style.")
	Witness := Gui(, "CNP_OLD_FOREGROUND_7263")
	WitnessEdit := Witness.AddEdit("w280", "Private focus witness")
	Callback := 0, ShowHook := 0, ForegroundHook := 0
	Receipt := ""
	try {
		Witness.Show("w320 h100")
		WitnessEdit.Focus()
		_CNP_Require(WinWaitActive("ahk_id " . Witness.Hwnd, , 3), "The native focus witness must activate.")
		_CNP_RequireWitness(Witness, WitnessEdit, Pid, MainThread)
		_CNP_Require(ConsoleWindowNative.Open(Kind) == true, "The production native adapter must acknowledge priming.")
		Cached := ControlGetText(Edit)
		OldMarker := Kind == "list_vars" ? "CNP_OLD_VALUE_8291" : "Window: CNP_OLD_FOREGROUND_7263"
		NewMarker := Kind == "list_vars" ? "CNP_FRESH_VALUE_9472" : "Window: CNP_FRESH_FOREGROUND_3186"
		_CNP_Require(_CNP_HasMarker(Cached, Kind, OldMarker), "Priming must capture the independently owned old sentinel.")
		WinHide("ahk_id " . Main)
		Witness.Title := "CNP_FRESH_FOREGROUND_3186"
		Witness.Show()
		WitnessEdit.Focus()
		_CNP_Require(WinWaitActive("ahk_id " . Witness.Hwnd, , 3), "The changed foreground witness must activate.")
		_CNPSentinel := "CNP_FRESH_VALUE_9472"
		_CNP_Require(!_CNP_HasMarker(ControlGetText(Edit), Kind, NewMarker), "Cached text must precede the new sentinel.")
		_CNP_Require(!DllCall("IsWindowVisible", "Ptr", Main), "Acquisition must start with a hidden runtime.")
		_CNP_Require(DllCall("GetFocus", "Ptr") == WitnessEdit.Hwnd, "Acquisition must start with exact child focus.")
		; Drain priming events before installing either whole-acquisition witness.
		Sleep(80)
		_CNP_RequireWitness(Witness, WitnessEdit, Pid, MainThread)
		Callback := CallbackCreate(_CNP_Event, , 7)
		ShowHook := DllCall("SetWinEventHook", "UInt", 0x8002, "UInt", 0x8002,
			"Ptr", 0, "Ptr", Callback, "UInt", Pid, "UInt", 0, "UInt", 0, "Ptr")
		ForegroundHook := DllCall("SetWinEventHook", "UInt", 3, "UInt", 3,
			"Ptr", 0, "Ptr", Callback, "UInt", Pid, "UInt", 0, "UInt", 0, "Ptr")
		_CNP_Require(ShowHook && ForegroundHook, "Both native transition witnesses must be acquired.")
		_CNP_RequireWitness(Witness, WitnessEdit, Pid, MainThread)
		_CNP_Require(!DllCall("IsWindowVisible", "Ptr", Main), "The source must remain hidden immediately before acquisition.")
		if Operation == "public" || Operation == "restore"
			_CNP_Require(ConsoleWindowNative.Open(Kind) == true, "The real public acquisition must acknowledge.")
		if Operation == "capacity"
			KeyHistory(41)
		if Operation == "restore" {
			WinHide("ahk_id " . Main)
			Witness.Show()
			WitnessEdit.Focus()
			_CNP_Require(WinWaitActive("ahk_id " . Witness.Hwnd, , 3), "Final-state restoration must complete.")
		}
		; Out-of-context WinEvents are queued on this thread, even after restoration.
		Sleep(80)
		Fresh := _CNP_HasMarker(ControlGetText(Edit), Kind, NewMarker)
		Visible := !!DllCall("IsWindowVisible", "Ptr", Main)
		Foreground := DllCall("GetForegroundWindow", "Ptr") == Main
		FinalMainThread := DllCall("GetWindowThreadProcessId", "Ptr", Main, "UInt*", &FinalMainPid := 0, "UInt")
		FinalEditThread := DllCall("GetWindowThreadProcessId", "Ptr", Edit, "UInt*", &FinalEditPid := 0, "UInt")
		Identity := Main == A_ScriptHwnd && Title == WinGetTitle("ahk_id " . Main)
			&& Edit == DllCall("GetDlgItem", "Ptr", Main, "Int", 1, "Ptr")
			&& DllCall("GetParent", "Ptr", Edit, "Ptr") == Main
			&& WinGetClass("ahk_id " . Main) == "AutoHotkey" && WinGetClass("ahk_id " . Edit) == "Edit"
			&& FinalMainPid == Pid && FinalEditPid == Pid
			&& FinalMainThread == MainThread && FinalEditThread == EditThread
		ReadOnly := !!(WinGetStyle("ahk_id " . Edit) & 0x800)
		WitnessFocused := DllCall("GetForegroundWindow", "Ptr") == Witness.Hwnd
			&& DllCall("GetFocus", "Ptr") == WitnessEdit.Hwnd
		Receipt := Format("{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}", Fresh, Visible, Foreground,
			_CNPShowEvents, _CNPForegroundEvents, Identity, ReadOnly, WitnessFocused)
	} finally {
		; Keep the callback alive until both exact native hook retirements succeed.
		ForegroundRetired := false, ShowRetired := false
		try ForegroundRetired := !ForegroundHook || DllCall("UnhookWinEvent", "Ptr", ForegroundHook)
		finally {
			try ShowRetired := !ShowHook || DllCall("UnhookWinEvent", "Ptr", ShowHook)
			finally {
				if ForegroundRetired && ShowRetired && Callback
					CallbackFree(Callback)
				Witness.Destroy()
			}
		}
		_CNP_Require(ForegroundRetired && ShowRetired, "Both native transition witnesses must retire.")
	}
	FileAppend(Receipt, "*", "UTF-8-RAW")
}
