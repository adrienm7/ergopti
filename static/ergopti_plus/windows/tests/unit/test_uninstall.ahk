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
