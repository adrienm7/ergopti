; static/ergopti_plus/windows/tests/unit/test_uninstall.ahk
;
; ==============================================================================
; MODULE: Uninstall Authorization Tests
; DESCRIPTION:
; Exercises cancellation and terminal authorization through real kernel events.
; No worker is launched and no executable or personal file is removed.
; ==============================================================================

_TestUninstallSuperseded() {
	State := UninstallState()
	State["Owner"] := Map("Phase", "Ready")
	AssertFalse(UninstallCommit("Reload"))
	AssertFalse(State.Has("Owner"), "a reload permanently revokes removal")
	UninstallCancel()
	AssertTrue(UninstallCommit("Exit"), "an ordinary exit has no pending removal")
}
Test("Uninstall: reload revokes the pending removal (menu-uninstall)", _TestUninstallSuperseded)

_TestUninstallBinaryIdentity() {
	Bytes := Buffer(3)
	NumPut("UChar", 0, "UChar", 255, "UChar", 97, Bytes)
	AssertEqual("da8509555ad27dac0593c6952d947eff96058cb6e81376f852f54ef9caf7e652",
		CryptoSha256Bytes(Bytes), "binary identity retains NUL and non-UTF8 bytes")
}
Test("Uninstall: executable identity hashes raw bytes (menu-uninstall)", _TestUninstallBinaryIdentity)

_TestUninstallCommitEvent() {
	Name := "Local\ErgoptiPlus.Uninstall.Test." . PLC_CurrentProcessId() . "." . A_TickCount
	Event := PLC_CreateNamedManualResetEvent(Name)
	Observer := DllCall("Kernel32\OpenEventW", "UInt", 0x100000, "Int", false, "Str", Name, "Ptr")
	AssertTrue(Observer != 0)
	; SYNCHRONIZE grants observation only; even a cancellation defect cannot
	; terminate this test process through the handle placed in the owner.
	Info := Buffer(A_PtrSize * 2 + 8, 0)
	NumPut("Ptr", PLC_OpenCurrentProcessHandle(0x100000), Info, 0)
	State := UninstallState()
	State["Owner"] := Map("Phase", "Ready", "Commit", Event, "ProcessInfo", Info)
	try {
		AssertEqual(0x102, PLC_WaitHandle(Observer, 0), "preparation is not authorization")
		AssertTrue(UninstallCommit("Exit"))
		AssertEqual(0, PLC_WaitHandle(Observer, 0), "terminal exit signals COMMIT")
		AssertFalse(State.Has("Owner"), "authorization is consumed once")
	} finally {
		UninstallCancel()
		PLC_CloseNativeHandle(Observer)
	}
}
Test("Uninstall: terminal exit signals its native capability once (menu-uninstall)", _TestUninstallCommitEvent)

/** Fake capabilities exercise READY timing without launching or removing anything. */
_TestUninstallClock(Started, Scenario, FirstElapsed := 0) {
	Info := Buffer(A_PtrSize * 2 + 8, 0)
	NumPut("Ptr", 22, Info, 0)
	Owner := Map("Ready", 11, "ProcessInfo", Info)
	Waited := []
	Sleeps := []
	ClockCalls := 0
	Ready := Scenario == "immediate"
	Revoked := false
	Clock() {
		ClockCalls += 1
		Elapsed := ClockCalls == 1 ? 0 : Sleeps.Length == 0 ? FirstElapsed : 10001
		if Scenario == "revoked" && Sleeps.Length > 0
			Elapsed := 10000
		return Mod(Started + Elapsed, 0x100000000)
	}
	Wait(Handle, Milliseconds) {
		AssertEqual(0, Milliseconds)
		Waited.Push(Handle)
		if Revoked
			AssertEqual(0, Handle, "every poll must reread the revoked native capability")
		if Handle == 11
			return Ready ? 0 : 0x102
		if Handle == 22
			return Scenario == "process-exit" ? 0 : 0x102
		AssertEqual(0, Handle, "no unrelated native handle may be observed")
		return 0xFFFFFFFF
	}
	Nap(Milliseconds) {
		AssertEqual(20, Milliseconds, "the original polling cadence remains intact")
		Sleeps.Push(Milliseconds)
		if Sleeps.Length > 2
			throw Error("Independent iteration guard: the deadline did not stop polling")
		if Scenario == "late-ready"
			Ready := true
		if Scenario == "revoked" {
			Owner["Ready"] := 0
			NumPut("Ptr", 0, Info, 0)
			Revoked := true
		}
	}
	Caught := 0
	Result := false
	try Result := _UninstallAwaitReady(Owner, Info, Clock, Wait, Nap)
	catch as Err
		Caught := Err
	if Scenario == "immediate" || Scenario == "late-ready" {
		AssertEqual(0, Caught, "READY wins before the timeout check")
		AssertTrue(Result)
		AssertEqual(Scenario == "immediate" ? 1 : 2, ClockCalls,
			"READY admission must not sample the deadline after the signal")
		AssertEqual(Scenario == "immediate" ? 1 : 3, Waited.Length,
			"READY admission must not inspect the worker after the signal")
		AssertEqual(Scenario == "immediate" ? 0 : 1, Sleeps.Length)
	} else {
		AssertTrue(IsObject(Caught), "pending or revoked capabilities must refuse readiness")
		AssertTrue(InStr(Caught.Message, "The removal worker did not become ready"),
			"the real deadline or exact worker state must refuse, rather than the iteration guard")
		if FirstElapsed > 10000
			AssertEqual(1, Waited.Length, "timeout must short-circuit the worker poll")
		ExpectedSleeps := Scenario == "process-exit" || FirstElapsed > 10000 ? 0 : 1
		AssertEqual(ExpectedSleeps, Sleeps.Length, "strict expiry preserves the exact-boundary poll")
		if Scenario == "revoked" {
			AssertEqual(0, Waited[-1], "the process handle is reread after cancellation")
			AssertEqual(0, Waited[-2], "the READY handle is reread after cancellation")
		}
	}
}
Test("Uninstall ready-clock-wrap: ordinary immediate READY", (*) => _TestUninstallClock(100, "immediate"))
Test("Uninstall ready-clock-wrap: wrapped immediate READY", (*) => _TestUninstallClock(0xFFFFFFF0, "immediate"))
Test("Uninstall ready-clock-wrap: ordinary overdue READY wins", (*) => _TestUninstallClock(100, "late-ready", 10000))
Test("Uninstall ready-clock-wrap: wrapped overdue READY wins", (*) => _TestUninstallClock(0xFFFFFFF0, "late-ready", 10000))
Test("Uninstall ready-clock-wrap: ordinary deadline minus one", (*) => _TestUninstallClock(100, "pending", 9999))
Test("Uninstall ready-clock-wrap: wrapped deadline minus one", (*) => _TestUninstallClock(0xFFFFFFF0, "pending", 9999))
Test("Uninstall ready-clock-wrap: ordinary exact deadline", (*) => _TestUninstallClock(100, "pending", 10000))
Test("Uninstall ready-clock-wrap: wrapped exact deadline", (*) => _TestUninstallClock(0xFFFFFFF0, "pending", 10000))
Test("Uninstall ready-clock-wrap: ordinary deadline plus one", (*) => _TestUninstallClock(100, "pending", 10001))
Test("Uninstall ready-clock-wrap: wrapped deadline plus one", (*) => _TestUninstallClock(0xFFFFFFF0, "pending", 10001))
Test("Uninstall ready-clock-wrap: ordinary process exit", (*) => _TestUninstallClock(100, "process-exit", 100))
Test("Uninstall ready-clock-wrap: wrapped process exit", (*) => _TestUninstallClock(0xFFFFFFF0, "process-exit", 100))
Test("Uninstall ready-clock-wrap: ordinary cancellation revokes both handles", (*) => _TestUninstallClock(100, "revoked", 100))
Test("Uninstall ready-clock-wrap: wrapped cancellation revokes both handles", (*) => _TestUninstallClock(0xFFFFFFF0, "revoked", 100))
