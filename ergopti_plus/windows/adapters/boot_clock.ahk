; adapters/boot_clock.ahk

; ==============================================================================
; MODULE: Boot Measurement Clock Adapter
; DESCRIPTION:
; Supplies precise wall-clock and process CPU samples for startup diagnosis.
; Native calls stay at this Windows boundary; samples are differences, never
; deadlines or input-path clocks. Process CPU includes every thread and nested
; stages overlap, so their totals must not be added together.
; ==============================================================================

#Requires AutoHotkey v2.0

/** Returns the monotonic performance counter in milliseconds. */
BootClockWallMs() {
	static Frequency := 0
	if !Frequency && !DllCall("QueryPerformanceFrequency", "Int64*", &Frequency)
		throw OSError(A_LastError, -1, "QueryPerformanceFrequency failed")
	if !DllCall("QueryPerformanceCounter", "Int64*", &Counter := 0)
		throw OSError(A_LastError, -1, "QueryPerformanceCounter failed")
	return Counter * 1000.0 / Frequency
}

/** Returns process CPU milliseconds, or -1 when the OS cannot supply them. */
BootClockCpuMs() {
	Creation := Buffer(8, 0)
	ExitTime := Buffer(8, 0)
	Kernel := Buffer(8, 0)
	User := Buffer(8, 0)
	if !DllCall("GetProcessTimes", "Ptr", DllCall("GetCurrentProcess", "Ptr"),
		"Ptr", Creation, "Ptr", ExitTime, "Ptr", Kernel, "Ptr", User)
		return -1
	return (NumGet(Kernel, 0, "Int64") + NumGet(User, 0, "Int64")) / 10000.0
}
