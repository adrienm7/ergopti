; core/events/boot_clock.ahk

; ==============================================================================
; MODULE: Measurement Clock Adapter
; DESCRIPTION:
; Also supplies the raw performance-counter ticks and the process resource
; counters the hot-path profiler reads, so that profiler holds no native call,
; and the thread, module and process counters of the deferred menu build probe.
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
	; Resolved once: this runs twice per hot-path segment, and DllCall searches the
	; loaded system libraries for a name on every call.
	static Address := DllCall("GetProcAddress", "Ptr",
		DllCall("GetModuleHandle", "Str", "kernel32", "Ptr"), "AStr", "QueryPerformanceCounter", "Ptr")
	Counter := 0
	DllCall(Address, "Int64*", &Counter)
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

/**
 * The CPU cycles the calling thread has run so far. Unlike the wall clock, it
 * does not count the time the thread waited on the scheduler or on a file.
 * @returns {Integer} Cycles since the thread started.
 */
ProcessThreadCycles() {
	if !DllCall("QueryThreadCycleTime", "Ptr", DllCall("GetCurrentThread", "Ptr"), "Int64*", &Cycles := 0)
		throw OSError(A_LastError, -1, "QueryThreadCycleTime")
	return Cycles
}

/**
 * Samples the calling thread's cycles and times and the process's page faults
 * and I/O operations. Native entry points are resolved once: the deferred menu
 * build probe samples twice per renderer row. The caller holds Critical when
 * the sample must not be split by another AutoHotkey thread.
 * @returns {Array} Cycles, kernel and user 100 ns units, page faults, read
 *     operations, read bytes, other I/O operations.
 */
ProcessProbeCounters() {
	static Kernel32 := DllCall("GetModuleHandle", "Str", "kernel32", "Ptr")
	static CycleTime := DllCall("GetProcAddress", "Ptr", Kernel32, "AStr", "QueryThreadCycleTime", "Ptr")
	static ThreadTimes := DllCall("GetProcAddress", "Ptr", Kernel32, "AStr", "GetThreadTimes", "Ptr")
	static MemoryInfo := DllCall("GetProcAddress", "Ptr", Kernel32, "AStr", "K32GetProcessMemoryInfo", "Ptr")
	static IoCounters := DllCall("GetProcAddress", "Ptr", Kernel32, "AStr", "GetProcessIoCounters", "Ptr")
	static Thread := DllCall("GetCurrentThread", "Ptr"), Process := DllCall("GetCurrentProcess", "Ptr")
	static Times := Buffer(32, 0), Memory := Buffer(80, 0), Io := Buffer(48, 0)
	if !DllCall(CycleTime, "Ptr", Thread, "Int64*", &Cycles := 0)
		throw OSError(A_LastError, -1, "QueryThreadCycleTime")
	if !DllCall(ThreadTimes, "Ptr", Thread, "Ptr", Times, "Ptr", Times.Ptr + 8, "Ptr", Times.Ptr + 16, "Ptr", Times.Ptr + 24)
		throw OSError(A_LastError, -1, "GetThreadTimes")
	NumPut("UInt", 80, Memory, 0)
	if !DllCall(MemoryInfo, "Ptr", Process, "Ptr", Memory, "UInt", 80)
		throw OSError(A_LastError, -1, "K32GetProcessMemoryInfo")
	if !DllCall(IoCounters, "Ptr", Process, "Ptr", Io)
		throw OSError(A_LastError, -1, "GetProcessIoCounters")
	; FILETIME kernel and user at 16 and 24; PageFaultCount follows cb; IO_COUNTERS
	; holds ReadOperationCount at 0, OtherOperationCount at 16, ReadTransferCount at 24.
	return [Cycles, NumGet(Times, 16, "Int64"), NumGet(Times, 24, "Int64"), NumGet(Memory, 4, "UInt"),
		NumGet(Io, 0, "Int64"), NumGet(Io, 24, "Int64"), NumGet(Io, 16, "Int64")]
}

/**
 * The modules this process has loaded, by base address.
 * @returns {Map} Module handle to true.
 */
ProcessLoadedModules() {
	Process := DllCall("GetCurrentProcess", "Ptr")
	Handles := Buffer(512 * A_PtrSize, 0)
	loop {
		if !DllCall("K32EnumProcessModules", "Ptr", Process, "Ptr", Handles, "UInt", Handles.Size, "UInt*", &Needed := 0)
			throw OSError(A_LastError, -1, "K32EnumProcessModules")
		if Needed <= Handles.Size
			break
		Handles := Buffer(Needed, 0)
	}
	Modules := Map()
	loop Needed // A_PtrSize
		Modules[NumGet(Handles, (A_Index - 1) * A_PtrSize, "Ptr")] := true
	return Modules
}

/**
 * The base name of one module this process has loaded.
 * @param {Integer} Module A handle from ProcessLoadedModules.
 * @returns {String}
 */
ProcessModuleBaseName(Module) {
	Name := Buffer(520, 0)
	if !DllCall("K32GetModuleBaseNameW", "Ptr", DllCall("GetCurrentProcess", "Ptr"), "Ptr", Module, "Ptr", Name, "UInt", 260)
		throw OSError(A_LastError, -1, "K32GetModuleBaseNameW")
	return StrGet(Name, "UTF-16")
}

/**
 * This process's GDI and USER object counts.
 * @returns {Array} GDI, then USER.
 */
ProcessGuiObjects() {
	State := {}
	ProcessResourceState(State)
	return [State.GdiObjects, State.UserObjects]
}

/**
 * Milliseconds since this process was created, so a measurement is placed
 * against the readiness line of the same log whatever the logger's precision.
 * @returns {Integer}
 */
ProcessAgeMs() {
	Creation := Buffer(8, 0), Unused := Buffer(8, 0), Now := Buffer(8, 0)
	if !DllCall("GetProcessTimes", "Ptr", DllCall("GetCurrentProcess", "Ptr"), "Ptr", Creation, "Ptr", Unused, "Ptr", Unused, "Ptr", Unused)
		throw OSError(A_LastError, -1, "GetProcessTimes")
	DllCall("GetSystemTimePreciseAsFileTime", "Ptr", Now)
	return (NumGet(Now, 0, "Int64") - NumGet(Creation, 0, "Int64")) // 10000
}
