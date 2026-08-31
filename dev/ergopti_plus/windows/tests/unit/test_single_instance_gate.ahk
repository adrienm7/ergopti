; tests/unit/test_single_instance_gate.ahk

; ==============================================================================
; MODULE: Single-Instance Gate Decision Tests
; DESCRIPTION:
; Exercises the pure decision boundary between native mutex acquisition and
; startup ownership. Only an acquired or abandoned mutex may let the driver
; continue; null handles, wait failures, unknown states, and live contention
; must all terminate before input ownership begins.
; ==============================================================================

_SIG_DecisionMatrixFailsClosed() {
	DecisionName := "DriverMutex_Decide"
	AssertTrue(IsSet(%DecisionName%),
		"the single-instance gate must expose a testable native-result decision")
	if !IsSet(%DecisionName%)
		return
	Decide := %DecisionName%

	AssertEqual("fatal", Decide(0),
		"CreateMutexW returning a null handle must terminate startup")
	AssertEqual("fatal", Decide(1),
		"a handle without a completed wait result must not establish ownership")
	AssertEqual("acquired", Decide(1, 0),
		"WAIT_OBJECT_0 owns the mutex and may continue")
	AssertEqual("acquired", Decide(1, 0x80),
		"WAIT_ABANDONED transfers ownership and may continue")
	AssertEqual("yield", Decide(1, 0x102),
		"WAIT_TIMEOUT must yield to the live owner")
	AssertEqual("fatal", Decide(1, 0xFFFFFFFF),
		"WAIT_FAILED must never be interpreted as absence of an owner")
	AssertEqual("fatal", Decide(1, 0x17),
		"an unknown wait result must fail closed")
}

Test("boot: mutex native-result matrix fails closed (audit-ahk-005)",
	_SIG_DecisionMatrixFailsClosed)

_SIG_IncompatibleKernelObjectCannotBypassGate() {
	Name := "Local\ErgoptiAuditAhk005_"
		. DllCall("kernel32\GetCurrentProcessId", "UInt") . "_" . A_TickCount
	EventHandle := DllCall("kernel32\CreateEventW", "Ptr", 0, "Int", 0,
		"Int", 0, "Str", Name, "Ptr")
	AssertTrue(EventHandle != 0,
		"the native collision fixture must own its same-named Event")
	MutexHandle := 0
	NativeError := 0
	try {
		DllCall("kernel32\SetLastError", "UInt", 0)
		MutexHandle := DllCall("kernel32\CreateMutexW", "Ptr", 0, "Int", 0,
			"Str", Name, "Ptr")
		NativeError := DllCall("kernel32\GetLastError", "UInt")
		AssertEqual(0, MutexHandle,
			"CreateMutexW must return null when the namespace name belongs to an Event")
		AssertEqual(6, NativeError,
			"the incompatible object collision must report ERROR_INVALID_HANDLE")
		AssertEqual("fatal", DriverMutex_Decide(MutexHandle),
			"the real null-handle collision must terminate before input ownership")
	} finally {
		if MutexHandle
			DllCall("kernel32\CloseHandle", "Ptr", MutexHandle)
		if EventHandle
			DllCall("kernel32\CloseHandle", "Ptr", EventHandle)
	}
}

Test("boot: incompatible named kernel object fails closed (audit-ahk-005-native)",
	_SIG_IncompatibleKernelObjectCannotBypassGate)
