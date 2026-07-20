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

    ; F05: a fatal fault before LoggerInit would ExitApp with the queued ERROR line
    ; still in RAM (no log, no crash report, no dialog). The pre-ready branch must
    ; force the log to disk AND tell the user, both AFTER the guard and BEFORE ExitApp.
    FlushPos := InStr(Body, "_LoggerFlush(true)")
    InitPos := InStr(Body, "LoggerInit()")
    SurfacePos := InStr(Body, "MsgBox")
    Assert(FlushPos > Guard && FlushPos < ExitPos,
        "the fatal-before-ready branch must force a log flush (_LoggerFlush(true)) before ExitApp so the fatal line survives")
    Assert(InitPos > Guard && InitPos < ExitPos,
        "the branch must resolve a log path (LoggerInit) when none exists yet, before flushing")
    Assert(SurfacePos > Guard && SurfacePos < ExitPos,
        "a fatal boot exit must surface a user-visible message (MsgBox) so the driver never silently 'does nothing'")
}
Test("boot error net: startup faults clean up and exit instead of becoming half-driver", _BEBFR_ErrorNetExitsBeforeReady)

; F14 (audit 2026-07-20): Bundle_Init() shells out through RunWait, which PUMPS
; MESSAGES — a key pressed during the extraction can evaluate a parse-time #HotIf and
; throw. OnError was armed ~45 lines BELOW that call, leaving the only early-boot
; message pump completely unprotected; and _ALTGR_KANA_FIXUP (read in FIRST position
; by the AltGr tap-hold #HotIf) was initialised at hotstring_engine.ahk's include
; position, far below the pump. Both must precede Bundle_Init(). Read the entry file
; directly and strip comments — several comments legitimately mention Bundle_Init().
_BEBFR_ErrorNetArmedBeforeFirstPump() {
    SplitPath(A_ScriptDir, , &WindowsDir)
    Src := ""
    try Src := FileRead(WindowsDir . "\ErgoptiPlus.ahk")
    Assert(Src != "", "ErgoptiPlus.ahk must be readable for the first-pump meta-test")
    Code := _StripFullLineComments(Src)

    OnErrPos := InStr(Code, "OnError(ErgoptiGlobalErrorHandler)")
    BundlePos := InStr(Code, "Bundle_Init()")
    KanaPos := InStr(Code, "_ALTGR_KANA_FIXUP := False")
    Assert(OnErrPos > 0 && BundlePos > 0, "ErgoptiPlus.ahk must arm OnError and call Bundle_Init()")
    Assert(OnErrPos < BundlePos,
        "the global error net must be armed BEFORE Bundle_Init's message-pumping RunWait, or a keypress during the extraction throws with no net at all")
    Assert(KanaPos > 0 && KanaPos < BundlePos,
        "_ALTGR_KANA_FIXUP must be seeded in the pre-pump block: a parse-time #HotIf reads it in first position and would throw during Bundle_Init's pump")
}
Test("boot error net: armed before the first message pump, with #HotIf globals seeded",
    _BEBFR_ErrorNetArmedBeforeFirstPump)
