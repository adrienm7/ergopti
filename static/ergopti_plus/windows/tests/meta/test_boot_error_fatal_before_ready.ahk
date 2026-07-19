; tests/meta/test_boot_error_fatal_before_ready.ahk

; ==============================================================================
; MODULE: Fatal-before-ready boot error guard
; DESCRIPTION:
; An uncaught startup exception must not be swallowed by the generic error net.
; Doing so leaves a resident process with partial hook registration, a misleading
; tray icon, and no path to a coherent ready state. The error net remains
; recoverable after ready, but before ready it must clean up and ExitApp(1).
; ==============================================================================

#Requires AutoHotkey v2.0

_BEBFR_BootPhaseIsPublishedOnlyAtReady() {
    Root := _DriverSourceConcat()
    Starting := InStr(Root, 'global _DriverBootPhase := "starting"')
    Handler := InStr(Root, "OnError(ErgoptiGlobalErrorHandler)")
    Ready := InStr(Root, '_DriverBootPhase := "ready"')
    ReadyFlag := InStr(Root, "_DriverReady := true")
    Assert(Starting > 0 && Handler > Starting,
        "ErgoptiPlus must establish the starting boot phase before wiring the global error net")
    Assert(Ready > ReadyFlag && ReadyFlag > Handler,
        "ErgoptiPlus may publish boot phase ready only after _DriverReady is true")
}
Test("boot error net: boot phase becomes ready only after input registration", _BEBFR_BootPhaseIsPublishedOnlyAtReady)

_BEBFR_ErrorNetExitsBeforeReady() {
    Body := _DriverFuncBody("ErgoptiGlobalErrorHandler")
    Assert(Body != "", "ErgoptiGlobalErrorHandler must exist in lib/error_net.ahk")
    Guard := InStr(Body, '_DriverBootPhase != "ready"')
    ExitPos := InStr(Body, "ExitApp(1)")
    StopHook := InStr(Body, "HookDispatcher.Stop()")
    StopKeylogger := InStr(Body, "KL_Stop()")
    Benign := InStr(Body, "_IsBenignUiaOrphanedPatternError")
    Assert(Guard > 0 && ExitPos > Guard,
        "the global error net must ExitApp(1) for every uncaught failure before ready")
    Assert(StopHook > Guard && StopKeylogger > Guard && StopHook < ExitPos && StopKeylogger < ExitPos,
        "fatal boot handling must release any started hook/keylogger before ExitApp(1)")
    Assert(Benign > ExitPos,
        "the fatal-before-ready guard must run before recoverable UIA-error suppression")
}
Test("boot error net: startup faults clean up and exit instead of becoming half-driver", _BEBFR_ErrorNetExitsBeforeReady)
