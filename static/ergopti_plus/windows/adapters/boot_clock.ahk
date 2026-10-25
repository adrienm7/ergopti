; adapters/boot_clock.ahk

; ==============================================================================
; MODULE: Measurement Clock Adapter
; DESCRIPTION:
; Also supplies the raw performance-counter ticks and the process resource
; counters the hot-path profiler reads, so that profiler holds no native call.
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

/** Returns the raw performance-counter ticks; 0 when the OS refuses. */
PerfClockTicks() {
	Counter := 0
	DllCall("QueryPerformanceCounter", "Int64*", &Counter)
	return Counter
}

/** Returns the performance-counter ticks per second; 0 when the OS refuses. */
PerfClockFrequency() {
	Frequency := 0
	DllCall("QueryPerformanceFrequency", "Int64*", &Frequency)
	return Frequency
}

/**
 * Fills the fields of State with this process's memory and kernel-object counts.
 * A field whose native call fails keeps the value the caller seeded.
 * @param {Object} State - WorkingSetMb, PeakWorkingSetMb, PrivateMb, Handles, GdiObjects, UserObjects.
 */
ProcessResourceState(State) {
	Process := DllCall("GetCurrentProcess", "Ptr")
	Counters := Buffer(80, 0)
	NumPut("UInt", 80, Counters, 0)
	if DllCall("psapi\GetProcessMemoryInfo", "Ptr", Process, "Ptr", Counters, "UInt", 80) {
		State.PeakWorkingSetMb := Round(NumGet(Counters, 8, "UPtr") / 1048576, 1)
		State.WorkingSetMb := Round(NumGet(Counters, 16, "UPtr") / 1048576, 1)
		State.PrivateMb := Round(NumGet(Counters, 72, "UPtr") / 1048576, 1)
	}
	Handles := 0
	if DllCall("GetProcessHandleCount", "Ptr", Process, "UInt*", &Handles)
		State.Handles := Handles
	; GR_GDIOBJECTS = 0, GR_USEROBJECTS = 1: leaks show here before the 10000 cap.
	State.GdiObjects := DllCall("GetGuiResources", "Ptr", Process, "UInt", 0, "UInt")
	State.UserObjects := DllCall("GetGuiResources", "Ptr", Process, "UInt", 1, "UInt")
}
