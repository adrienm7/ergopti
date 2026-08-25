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
    Assert(Body != "", "ErgoptiGlobalErrorHandler must exist in infra/error_net.ahk")
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
    InputCleanupPos := InStr(Body, "_ErgoptiFatalInputCleanup()")
    Assert(FlushPos > Guard && FlushPos < ExitPos,
        "the fatal-before-ready branch must force a log flush (_LoggerFlush(true)) before ExitApp so the fatal line survives")
    Assert(InitPos > Guard && InitPos < ExitPos,
        "the branch must resolve a log path (LoggerInit) when none exists yet, before flushing")
    Assert(SurfacePos > Guard && SurfacePos < ExitPos,
        "a fatal boot exit must surface a user-visible message (MsgBox) so the driver never silently 'does nothing'")
    Assert(InputCleanupPos > Guard && InputCleanupPos < SurfacePos
        && InputCleanupPos < StopHook && InputCleanupPos < StopKeylogger,
        "fatal startup handling must release owned synthetic modifiers and resynchronise Caps state before any modal dialog or subsystem stop can strand the balancing key-up (fatal-startup-synthetic-modifier-latch)")

    CleanupBody := _DriverFuncBody("_ErgoptiFatalInputCleanup")
    Assert(CleanupBody != "" && InStr(CleanupBody, "TapHoldReleaseSyntheticKeys") > 0,
        "fatal input cleanup must delegate exact transient-key ownership to the synthetic ledger")
    Assert(InStr(CleanupBody, "UpdateCapsLockLED") > 0
        && InStr(CleanupBody, "SetCapsLockState") = 0,
        "fatal input cleanup must resynchronise through the single LED owner and never clear the user's hardware CapsLock intent directly")
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

; A personal hotkey is armed as soon as its generated include executes, while the
; auto-execute thread is still registering the built-in layout. A keypress in that
; window can therefore reach SendNewResult before later module-level assignments.
; The live 2026-08-25 crash was Shift+SC02E calling _EmitReachedScreen while its
; suppressive-hook registry was still unset. Pin the registry before the include
; that makes those user callbacks reachable.
_BEBFR_EmitRegistryPrecedesPersonalHotkeys() {
    SplitPath(A_ScriptDir, , &WindowsDir)
    Src := ""
    try Src := FileRead(WindowsDir . "\ErgoptiPlus.ahk")
    Assert(Src != "", "ErgoptiPlus.ahk must be readable for the personal-hotkey boot-order guard")
    Code := _StripFullLineComments(Src)

    RegistryPos := InStr(Code, "_EMIT_SUPPRESSING_HOOKS := [")
    PersonalIncludePos := InStr(Code, "#Include *i _generated/personal_shortcuts.ahk")
    Assert(RegistryPos > 0 && PersonalIncludePos > 0,
        "the emit-hook registry and generated personal-shortcuts include must both exist in the entry")
    Assert(RegistryPos < PersonalIncludePos,
        "the emit-hook registry must be assigned before personal hotkeys become reachable, or an early SendNewResult raises UnsetError and aborts boot (early-personal-emit-unset-registry)")
}
Test("boot input: personal SendNewResult sees an initialised emit registry (early-personal-emit-unset-registry)",
    _BEBFR_EmitRegistryPrecedesPersonalHotkeys)
