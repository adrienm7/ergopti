; lib/error_net.ahk

; ==============================================================================
; MODULE: Global Error Net
; DESCRIPTION:
; The process-wide uncaught-error handler armed via OnError() in the entry.
; Without it, any uncaught error pops a blocking AHK dialog mid-keystroke and
; can leave modifiers stuck down; this handler releases only genuinely-stuck
; modifiers, logs the failure, offers an opt-in crash report, and surfaces a
; non-blocking tray toast — so one bad callback never locks the keyboard.
; ==============================================================================





; ==================================
; ==================================
; ======= 1/ Error handler =========
; ==================================
; ==================================

; Decides whether the error handler should force-release a modifier. A modifier
; is only RELEASED when it is LOGICALLY down (held by the driver / a failed
; callback) but the user is NOT physically holding it — i.e. genuinely stuck.
; Returning false when the user is physically holding the key prevents the old
; bug where the handler sent a Shift-Up for a Shift the user was legitimately
; holding (e.g. an error fires mid-chord while typing a capital), which desynced
; the modifier state and broke capitalisation for the rest of the word.
_ShouldReleaseModifier(ModKey) {
    ; "P" = physical key state; the default state is the logical state AHK reports.
    return GetKeyState(ModKey) and !GetKeyState(ModKey, "P")
}
ErgoptiGlobalErrorHandler(Exc, Mode) {
    ; Release ONLY modifiers that are logically stuck (not physically held) after
    ; the failed callback — never yank a key the user is still pressing.
    for _, ModKey in ["LControl", "RControl", "LShift", "RShift", "LAlt", "RAlt", "LWin", "RWin"] {
        if _ShouldReleaseModifier(ModKey) {
            SendEvent("{" ModKey " Up}")
        }
    }
    ; Best-effort logging — guarded because the logger may not be initialised
    ; yet when an early-boot error fires the handler.
    try LoggerError("ErgoptiPlus", "Uncaught error: {1}",
        Exc.Message . (Exc.HasProp("Stack") ? " | " . Exc.Stack : ""))
    ; Offer the user an opt-in crash report before surfacing the generic alert.
    ; CrashReport_PromptUser is guarded internally so a failure here cannot
    ; re-enter the error handler.
    try {
        Report := CrashReport_Build(Exc)
        CrashReport_PromptUser(Report)
    }
    ; Surface the error via a NON-BLOCKING tray notification, not a modal MsgBox.
    ; A modal dialog on the input thread starves the keyboard hook — every key
    ; pressed while it is up is dropped or queued, turning an uncaught error into
    ; a lost-keystroke window. The tray toast informs the user without blocking.
    try NotifierSend(t("ergopti.error_caught") . "`n`n" . Exc.Message,
        Map("title", "ErgoptiPlus", "level", "error"))
    return true
}
