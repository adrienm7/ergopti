; tests/fixtures/core/native_editor_cross_process_receiver.ahk

; ==============================================================================
; MODULE: Native Editor Cross-Process Receiver
; DESCRIPTION:
; Owns one real Edit and observes its actual replacement through a native subclass.
; Delay waits at the receiver boundary, then delegates once to DefSubclassProc.
; No keyboard input, clipboard, production DLL or replacement result is simulated.
; ==============================================================================

#Requires AutoHotkey v2.0
#SingleInstance Off
#NoTrayIcon
#Warn All, StdOut

global NECR := {Window: 0, Edit: 0, Callback: 0, Subclassed: false,
	Events: [], Parent: 0, Calls: 0, Completed: false, Published: false}

_NECR_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_NECR_Publish(Name, Value) {
	global NECR
	Path := NECR.Root . "\" . Name
	FileAppend(Value, Path . ".pending", "UTF-8-RAW")
	FileMove(Path . ".pending", Path)
}

_NECR_Subclass(Hwnd, Message, Word, Pointer, Id, Reference) {
	; Default non-Fast CallbackCreate owns a fresh AHK thread. Keep its Critical
	; context until callback return: Watch must not free a live native thunk.
	; Do not restore Critical here; callback-thread return restores the caller.
	Critical("On")
	global NECR
	if Message != 0xC2
		return DllCall("Comctl32\DefSubclassProc", "Ptr", Hwnd, "UInt", Message,
			"UPtr", Word, "Ptr", Pointer, "Ptr")
	try {
		NECR.Calls += 1
		_NECR_Require(DllCall("Kernel32\SetEvent", "Ptr", NECR.Events[1], "Int"),
			"receiver entry event refused")
		if NECR.Delay {
			Waits := Buffer(2 * A_PtrSize)
			NumPut("Ptr", NECR.Events[2], "Ptr", NECR.Parent, Waits)
			_NECR_Require(DllCall("Kernel32\WaitForMultipleObjects", "UInt", 2,
				"Ptr", Waits, "Int", false, "UInt", 0xFFFFFFFF, "UInt") == 0,
				"the parent exited before releasing its exact delayed receiver")
		}
		Result := DllCall("Comctl32\DefSubclassProc", "Ptr", Hwnd, "UInt", Message,
			"UPtr", Word, "Ptr", Pointer, "Ptr")
		; Snapshot native storage in RAM before returning. File I/O stays outside
		; the window procedure so positive output cannot time out on disk latency.
		NECR.Text := ControlGetText(Hwnd)
		Selection := Buffer(8, 0)
		DllCall("User32\SendMessageW", "Ptr", Hwnd, "UInt", 0xB0,
			"Ptr", Selection, "Ptr", Selection.Ptr + 4, "Ptr")
		NECR.Start := NumGet(Selection, 0, "UInt")
		NECR.End := NumGet(Selection, 4, "UInt")
		NECR.Completed := true
		return Result
	} catch as Err {
		NECR.Failure := Err.Message
		return 0
	}
}

_NECR_Watch() {
	global NECR
	if NECR.HasOwnProp("Failure")
		throw Error(NECR.Failure)
	if NECR.Completed && !NECR.Published {
		NECR.Published := true
		_NECR_Publish("text", NECR.Text)
		_NECR_Publish("settled", NECR.Calls . "|" . NECR.Start . "|" . NECR.End)
	}
	if DllCall("Kernel32\WaitForSingleObject", "Ptr", NECR.Events[3], "UInt", 0, "UInt") == 0
			|| DllCall("Kernel32\WaitForSingleObject", "Ptr", NECR.Parent, "UInt", 0, "UInt") == 0 {
		_NECR_Close()
		FileAppend("PASS native editor receiver", "*", "UTF-8-RAW")
		ExitApp(0)
	}
}

_NECR_Close(*) {
	global NECR
	SetTimer(_NECR_Watch, 0)
	if NECR.Subclassed {
		_NECR_Require(DllCall("Comctl32\RemoveWindowSubclass", "Ptr", NECR.Edit.Hwnd,
			"Ptr", NECR.Callback, "UPtr", 1, "Int"), "receiver subclass retirement refused")
		NECR.Subclassed := false
	}
	if NECR.Window is Gui
		NECR.Window.Destroy()
	if NECR.Callback {
		CallbackFree(NECR.Callback)
		NECR.Callback := 0
	}
	for Handle in NECR.Events
		_NECR_Require(DllCall("Kernel32\CloseHandle", "Ptr", Handle, "Int"), "receiver event close refused")
	NECR.Events := []
	if NECR.Parent {
		_NECR_Require(DllCall("Kernel32\CloseHandle", "Ptr", NECR.Parent, "Int"), "receiver parent close refused")
		NECR.Parent := 0
	}
}

_NECR_Error(Err, *) {
	FileAppend(Err.Message . "`n" . Err.Stack, "**", "UTF-8-RAW")
	ExitApp(1)
	return true
}

try {
	OnError(_NECR_Error)
	NECR.Root := A_Args[1], NECR.Delay := A_Args[2] == "delay"
	BaseName := A_Args[3]
	for Suffix in ["entered", "release", "stop"] {
		EntryEventHandle := DllCall("Kernel32\OpenEventW", "UInt", 0x100002, "Int", false,
			"Str", BaseName . "_" . Suffix, "Ptr")
		_NECR_Require(EntryEventHandle != 0, "receiver event open refused")
		NECR.Events.Push(EntryEventHandle)
	}
	NECR.Parent := DllCall("Kernel32\OpenProcess", "UInt", 0x100000, "Int", false,
		"UInt", Integer(A_Args[4]), "Ptr")
	_NECR_Require(NECR.Parent != 0, "receiver parent identity open refused")
	NECR.Window := Gui(, "Ergopti owned native editor receiver")
	NECR.Edit := NECR.Window.AddEdit("w400 h80 Multi -Wrap", "left " . Chr(0x1F600) . " tail")
	NECR.Window.Show()
	NECR.Edit.Focus()
	DllCall("User32\SendMessageW", "Ptr", NECR.Edit.Hwnd, "UInt", 0xB1, "UPtr", 7, "Ptr", 7, "Ptr")
	NECR.Callback := CallbackCreate(_NECR_Subclass, , 6)
	_NECR_Require(DllCall("Comctl32\SetWindowSubclass", "Ptr", NECR.Edit.Hwnd,
		"Ptr", NECR.Callback, "UPtr", 1, "UPtr", 0, "Int"), "receiver subclass setup refused")
	NECR.Subclassed := true
	_NECR_Publish("ready", ProcessExist() . "|" . NECR.Window.Hwnd . "|" . NECR.Edit.Hwnd)
	SetTimer(_NECR_Watch, 10)
} catch as EntryFailure {
	_NECR_Error(EntryFailure)
}
