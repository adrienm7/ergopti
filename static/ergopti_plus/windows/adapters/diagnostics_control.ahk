; adapters/diagnostics_control.ahk

; ==============================================================================
; MODULE: Diagnostics Control Native Adapter
; DESCRIPTION:
; Owns the Win32 message, process lifetime and one-shot timer boundaries used
; by the existing Diagnostics window control. The UI never chooses a periodic
; native callback or implements its own direct OS access.
; ==============================================================================

/** Returns the session-local Win32 message for opening the diagnostics window. */
HealthCheck_ControlMessage() {
	static Message := DllCall("User32\RegisterWindowMessageW",
		"Str", "Ergopti.Diagnostics.Open.v1", "UInt")
	if !Message
		throw OSError(A_LastError, -1, "The diagnostics control message could not be registered.")
	return Message
}

/** Returns this process lifetime independently of any caller-owned window handle. */
HealthCheck_ControlCreationTime() {
	Times := Buffer(32, 0)
	if !DllCall("Kernel32\GetProcessTimes", "Ptr", DllCall("Kernel32\GetCurrentProcess", "Ptr"),
			"Ptr", Times, "Ptr", Times.Ptr + 8, "Ptr", Times.Ptr + 16, "Ptr", Times.Ptr + 24, "Int")
		throw OSError(A_LastError, -1, "The diagnostics control process lifetime could not be read.")
	return NumGet(Times, 0, "UInt64")
}

/** Cancels the exact callback or schedules one deferred execution. */
HealthCheck_ControlTimer(Callback, Period) {
	if !(Period is Integer) || Period > 0
		throw ValueError("Diagnostics control requires cancellation or a one-shot period.")
	if Period == 0
		return SetTimer(Callback, 0)
	return SetTimer(Callback, -Abs(Period))
}
