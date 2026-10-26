; tests/fixtures/system_actions_pid_registration.ahk
;
; ==============================================================================
; MODULE: Actual PID Domain Registration Observer
; DESCRIPTION:
; Includes the actual test owner and observes only its registered callback values.
; The process port below is a recorder, not a native DWORD behavior oracle.
; The main suite retains the original real-port PID-domain tests unchanged.
; ==============================================================================

#Requires AutoHotkey v2.0
#Warn All, StdOut
#NoTrayIcon
#SingleInstance Off

#Include %A_LineFile%\..\..\support\pid_registration_receipt.ahk

_PidRegistrationFailure(Err, Mode) {
	if A_Args.Length
		try _PidRegistrationPublish(Err.Message . "`n" . Err.Stack, A_Args[1] . ".error")
	ExitApp(1)
}
OnError(_PidRegistrationFailure)

global _PidRegistrationRows := []
global _PidRegistrationInputs := []

Test(Name, Callback) {
	global _PidRegistrationRows
	if InStr(Name, "system control: invalid process PID ", true) == 1
		_PidRegistrationRows.Push({Name: Name, Callback: Callback})
}

AssertTrue(Value, Message := "") {
	if !Value
		throw Error(Message)
}

AssertFalse(Value, Message := "") => AssertTrue(!Value, Message)

AssertEqual(Expected, Actual, Message := "") {
	if Expected != Actual
		throw Error(Message)
}

; Only class declarations need this base while the real file registers cases.
; Its gesture callbacks are never invoked by this registration-only observer.
class _SysActionsFake {
}

class _PidRegistrationPort {
	AcquireProcessTarget(Pid) {
		global _PidRegistrationInputs
		_PidRegistrationInputs.Push({Kind: Type(Pid), Value: String(Pid)})
		throw TypeError("Registration-only PID value observation.")
	}
}

SystemControl() => _PidRegistrationPort()

#Include %A_LineFile%\..\..\unit\modules\gestures\test_system_actions_process_lease.ahk

if A_Args.Length != 2
	throw Error("The owned registration observer requires a report and completion event.")
AssertEqual(6, _PidRegistrationRows.Length, "the actual owner registers all six invalid PID vectors")
NativePid := DllCall("kernel32\GetCurrentProcessId", "UInt")
Report := Type(NativePid) . "`t" . NativePid . "`n"
for Row in _PidRegistrationRows {
	_PidRegistrationInputs := []
	Row.Callback.Call()
	AssertEqual(1, _PidRegistrationInputs.Length, "each actual bound callback delivers one original typed value")
	Value := _PidRegistrationInputs[1]
	Report .= Row.Name . "`t" . Value.Kind . "`t" . Value.Value . "`n"
}
Done := DllCall("kernel32\OpenEventW", "UInt", 0x100000, "Int", false, "Str", A_Args[2], "Ptr")
AssertTrue(Done != 0, "the parent owns the observer completion capability")
try {
	_PidRegistrationPublish(Report, A_Args[1])
	Waited := DllCall("kernel32\WaitForSingleObject", "Ptr", Done, "UInt", 20000, "UInt")
} finally AssertTrue(DllCall("kernel32\CloseHandle", "Ptr", Done, "Int"), "the exact observer event reference must close")
ExitApp(Waited == 0 ? 0 : 1)
