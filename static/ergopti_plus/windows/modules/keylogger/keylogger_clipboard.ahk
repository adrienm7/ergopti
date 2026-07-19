; modules/keylogger/keylogger_clipboard.ahk

_KL_Clip_CharCountFromByteSize(bytes) {
    if (bytes <= 2)
        return 0
    chars := (bytes // 2) - 1
    return Min(chars, KLClipConst.MAX_CHAR_COUNT)
}

; ==============================================================================
; MODULE: Keylogger Clipboard
; DESCRIPTION:
; Monitors clipboard activity to surface copy/paste patterns and detect
; paste-heavy typing sessions (research/collage) vs. original composition.
;
; FEATURES & RATIONALE:
; 1. Clipboard copy — registered via OnClipboardChange which fires whenever
;    any application writes to the clipboard. Records the content type
;    (text/image/other), the text length in characters (never the raw text
;    — only the count), and the source app. This lets the dashboard show
;    "copy rate" alongside keystrokes without ever storing clipboard content.
; 2. Clipboard paste detection — when the user presses Ctrl+V (or
;    Shift+Insert) we emit a clipboard_paste event. Pairing it with the
;    last clipboard_copy gives the copy→paste interval and reveals whether
;    the user is collage-typing (copy, immediately paste elsewhere) or has
;    the clipboard as a staging buffer.
; 3. Paste burst — if more than PASTE_BURST_THRESHOLD paste events occur
;    within PASTE_BURST_WINDOW_MS a paste_burst event is emitted. Paste
;    bursts indicate research-heavy or template-assembly work patterns that
;    are qualitatively different from original composition.
; 4. Privacy — only the character count (StrLen) and content type are
;    stored; the raw clipboard text is never written to any log. Image
;    clipboards are logged as type "image" with size 0.
;
; INTEGRATION:
; KL_Clip_Start() must be called after KL_Init(). It installs an
; OnClipboardChange callback and two pass-through hotkeys (Ctrl+V and
; Shift+Insert) that forward the event before passing through to the app.
; ==============================================================================

#Requires Autohotkey v2.0+





; ===================================
; ============================
; ======= 1/ Constants =======
; ============================
; ===================================

class KLClipConst {
    ; Number of paste events within the window that triggers a paste_burst
    static PASTE_BURST_THRESHOLD   := 5
    ; Time window (ms) for the burst count
    static PASTE_BURST_WINDOW_MS   := 10000
    ; Max character count to store (cap to avoid storing huge clipboard counts
    ; that would reveal document length)
    static MAX_CHAR_COUNT          := 100000
}





; ===================================
; ===============================
; ======= 2/ Module state =======
; ===============================
; ===================================

class KLClip {
    ; Last copy snapshot
    static last_copy_tick   := 0
    static last_copy_len    := 0
    static last_copy_app    := ""

    ; Paste burst accumulator
    static paste_ticks      := []   ; ring of recent paste A_TickCounts

    ; OnClipboardChange reference
    static clip_handler     := unset
}





; =========================================
; ===========================================
; ======= 3/ Clipboard change handler =======
; ===========================================
; =========================================

KL_Clip_OnChange(data_type) {
    if !Keylogger.initialized
        return
    if A_IsSuspended
        return
    filtered := false
    try filtered := MF_ShouldFilter()
    if filtered
        return

    ; data_type: 1 = text, 2 = image, 0 = clipboard cleared
    if (data_type = 0)
        return

    content_type := (data_type = 1) ? "text" : "other"
    char_count   := 0
    if (data_type = 1) {
        try {
            if DllCall("OpenClipboard", "Ptr", 0) {
                if hData := DllCall("GetClipboardData", "UInt", 13, "Ptr") { ; CF_UNICODETEXT
                    ptr := DllCall("GlobalLock", "Ptr", hData, "Ptr")
                    if ptr {
                        bytes := DllCall("GlobalSize", "Ptr", hData, "UPtr")
                        DllCall("GlobalUnlock", "Ptr", hData)
                        ; char_count = bytes / 2 - 1 (UTF-16 with null terminator)
                        char_count := _KL_Clip_CharCountFromByteSize(bytes)
                    }
                }
                DllCall("CloseClipboard")
            }
        }
    }

    KLClip.last_copy_tick := A_TickCount
    KLClip.last_copy_len  := char_count
    KLClip.last_copy_app  := Keylogger.session_app

    KL_AppendLog(Map(
        "type",         "clipboard_copy",
        "app",          Keylogger.session_app,
        "content_type", content_type,
        "char_count",   char_count
    ))
}





; ==========================================
; ========================================
; ======= 4/ Paste hotkey handlers =======
; ========================================
; ==========================================

KL_Clip_OnPaste() {
    if !Keylogger.initialized
        return
    if A_IsSuspended
        return
    filtered := false
    try filtered := MF_ShouldFilter()
    if filtered
        return

    now := A_TickCount
    copy_lag := (KLClip.last_copy_tick > 0) ? ((now - KLClip.last_copy_tick) & 0xFFFFFFFF) : -1

    KL_AppendLog(Map(
        "type",         "clipboard_paste",
        "app",          Keylogger.session_app,
        "char_count",   KLClip.last_copy_len,
        "copy_lag_ms",  copy_lag,
        "source_app",   KLClip.last_copy_app
    ))

    ; Burst detection
    KLClip.paste_ticks.Push(now)
    ; Prune ticks outside the window
    fresh := []
    for _, PasteTick in KLClip.paste_ticks {
        if (((now - PasteTick) & 0xFFFFFFFF) <= KLClipConst.PASTE_BURST_WINDOW_MS)
            fresh.Push(PasteTick)
    }
    KLClip.paste_ticks := fresh

    if (fresh.Length >= KLClipConst.PASTE_BURST_THRESHOLD) {
        KL_AppendLog(Map(
            "type",   "paste_burst",
            "app",    Keylogger.session_app,
            "count",  fresh.Length,
            "window_ms", KLClipConst.PASTE_BURST_WINDOW_MS
        ))
        ; Reset so we don't emit a burst event on every subsequent paste
        KLClip.paste_ticks := []
    }
}





; =====================================
; ============================
; ======= 5/ Lifecycle =======
; ============================
; =====================================

KL_Clip_Start() {
    if KLClip.HasOwnProp("clip_handler") && IsObject(KLClip.clip_handler)
        return true

    ; Register the clipboard observer and both pass-through paste hotkeys as
    ; one transaction.  A rejection after the first Hotkey used to leave a
    ; half-live observer/hotkey set and an unhandled boot exception.
    Handler := KL_Clip_OnChange
    ClipboardRegistered := false
    try {
        OnClipboardChange(Handler)
        ClipboardRegistered := true
        ; ``~`` ensures the paste still reaches the active application unchanged.
        Hotkey("~^v",      KL_Clip_OnPasteHK, "On")
        Hotkey("~+Insert", KL_Clip_OnPasteHK, "On")
        KLClip.clip_handler := Handler
        return true
    } catch as Err {
        try Hotkey("~^v",      KL_Clip_OnPasteHK, "Off")
        try Hotkey("~+Insert", KL_Clip_OnPasteHK, "Off")
        if ClipboardRegistered
            try OnClipboardChange(Handler, 0)
        LoggerError("Keylogger", "Clipboard observer registration failed: {1}", Err.Message)
        return false
    }
}

KL_Clip_OnPasteHK(*) {
    try KL_Clip_OnPaste()
}

KL_Clip_Stop() {
    if KLClip.HasOwnProp("clip_handler") && IsObject(KLClip.clip_handler) {
        try OnClipboardChange(KLClip.clip_handler, 0)
        KLClip.clip_handler := unset
    }
    try Hotkey("~^v",      KL_Clip_OnPasteHK, "Off")
    try Hotkey("~+Insert", KL_Clip_OnPasteHK, "Off")
}
