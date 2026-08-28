; tests/meta/test_gesture_restart_nonblocking.ahk

; ============================================================================== 
; MODULE: Gesture touchpad restart nonblocking regression test
; DESCRIPTION:
; Restarting the PnP device may wait on UAC and device re-enumeration. The
; keyboard driver must launch that elevated process and return to its message
; pump instead of waiting on the sole AHK execution thread.
; ============================================================================== 

#Requires AutoHotkey v2.0

_GRN_GestureRestartDoesNotBlockDriverThread() {
    Body := _DriverFuncBody("GestureRestartTouchpadDevice")
    Poll := _DriverFuncBody("_GestureRestartPoll")
    Builder := _DriverFuncBody("_GestureRestartBuildPsScript")

    Assert(Body != "" && Poll != "" && Builder != "", "touchpad restart worker helpers must exist")
    Assert(InStr(Body, "RunWait(") = 0,
        "GestureRestartTouchpadDevice must never RunWait for an elevated PnP restart on the driver thread")
    Assert(InStr(Body, "Run(") > 0 && InStr(Body, "&RestartPid") > 0,
        "GestureRestartTouchpadDevice must launch the restart asynchronously and retain its PID for diagnostics")
	Assert(InStr(Body, "SetTimer(_GestureRestartPoll.Bind(Epoch)") > 0 && InStr(Body, "result") > 0,
		"the launch must retain a worker-owned result and poll it asynchronously")
	StartReceiptPos := InStr(Body, "FileExist(_GestureRestartJob")
	StartPidPos := InStr(Body, "ProcessExist(_GestureRestartJob")
	Assert(StartReceiptPos > 0 && StartPidPos > StartReceiptPos,
		"a second restart must consume the prior receipt before consulting its recyclable PID")
    Assert(InStr(Body, "*RunAs powershell.exe") > 0,
        "GestureRestartTouchpadDevice must preserve elevation for the PnP operation")
	Assert(InStr(Poll, "A_IsSuspended") > 0 && InStr(Poll, "_GestureRestartReadResult") > 0,
		"completion must wait across Suspend and consume only the worker-authored result")
	ReceiptPos := InStr(Poll, "FileExist(_GestureRestartJob")
	PidPos := InStr(Poll, "ProcessExist(_GestureRestartJob")
	Assert(ReceiptPos > 0 && PidPos > ReceiptPos,
		"a complete result receipt must win before a potentially recycled diagnostic PID (AHK-084)")
    Assert(InStr(Poll, "_SR_GetExitCode") = 0,
        "a vanished process handle must fail closed rather than being reported as a successful restart")
	Assert(InStr(Builder, "$ErgoptiExitCode = 1") > 0 && InStr(Builder, "WriteAllText($ResultStage") > 0
		&& InStr(Builder, "[System.IO.File]::Move($ResultStage, $ResultPath)") > 0
		&& InStr(Builder, "exit $ErgoptiExitCode") > 0,
		"the elevated restart worker must atomically publish its final success/failure before exiting")
    Assert(InStr(Builder, "$disabled = @()") > 0 && InStr(Builder, "finally") > 0 && InStr(Builder, "Enable-PnpDevice") > 0,
        "a failed PnP cycle must always re-enable every device that was already disabled")
}

Test("gestures: elevated restart receipt precedes recyclable PID liveness (AHK-084)",
	_GRN_GestureRestartDoesNotBlockDriverThread)
