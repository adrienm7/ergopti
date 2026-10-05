; adapters/user_hotstrings_native.ahk

; ==============================================================================
; MODULE: Programmable Hotstring Native Calls
; DESCRIPTION:
; Keeps Windows acquisition and foreground probes behind the adapter boundary.
; Return values and cancellation ownership remain with the existing worker.
; ==============================================================================

/** Open the editor using the existing explicit Notepad command line. */
UHN_OpenSource(Path) {
	Run('notepad.exe "' . Path . '"')
}

/** Preserve the native thread result and separately return its process id. */
UHN_WindowProcessId(Hwnd, &ProcessId) {
	return DllCall("GetWindowThreadProcessId", "Ptr", Hwnd, "UInt*", &ProcessId)
}

/** Preserve the active-window query used by publication admission. */
UHN_ForegroundHwnd() {
	return WinExist("A")
}

/** Return the native process id used by the worker's nonce. */
UHN_CurrentProcessId() {
	return DllCall("GetCurrentProcessId")
}

/** Capture LastError before returning a create-or-open event capability. */
UHN_CreateCancellationEvent(Name, &EventError) {
	Handle := DllCall("CreateEventW", "Ptr", 0, "Int", true, "Int", false, "Str", Name, "Ptr")
	EventError := A_LastError
	return Handle
}

/** Return the native signal result without retiring the handle. */
UHN_SignalEvent(Handle) {
	return DllCall("SetEvent", "Ptr", Handle)
}

/** Return the native close result; this adapter adds no retry authority. */
UHN_CloseEvent(Handle) {
	return DllCall("CloseHandle", "Ptr", Handle)
}
