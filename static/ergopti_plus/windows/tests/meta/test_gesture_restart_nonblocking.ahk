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

    Assert(Body != "", "GestureRestartTouchpadDevice() must exist")
    Assert(InStr(Body, "RunWait(") = 0,
        "GestureRestartTouchpadDevice must never RunWait for an elevated PnP restart on the driver thread")
    Assert(InStr(Body, "Run(") > 0 && InStr(Body, "&RestartPid") > 0,
        "GestureRestartTouchpadDevice must launch the restart asynchronously and retain its PID for diagnostics")
    Assert(InStr(Body, "*RunAs powershell.exe") > 0,
        "GestureRestartTouchpadDevice must preserve elevation for the PnP operation")
}

Test("gestures: touchpad restart launches without blocking the AHK message pump",
    _GRN_GestureRestartDoesNotBlockDriverThread)
