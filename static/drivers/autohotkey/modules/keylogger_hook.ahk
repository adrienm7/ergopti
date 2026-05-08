; modules/keylogger_hook.ahk

; ==============================================================================
; MODULE: Keylogger Input Hook
; DESCRIPTION:
; Wires keystroke capture to the keylogger pipeline using AHK v2's
; ``InputHook``. Observes every key the user types — including the
; OUTPUT of the layout's remaps and hotstring expansions — without
; intercepting. The result feeds into Keylogger.buffer_events and the
; existing flush / ingest tick handles persistence.
;
; FEATURES & RATIONALE:
; 1. Passive observation: ``InputHook("V I0 L0")`` runs visible (events
;    keep flowing to apps), ignores Send* injected by the script
;    itself (``I0`` = SendLevel 0 stays invisible to us, prevents
;    double-logging), and accepts every key (``L0`` = no length
;    cutoff).
; 2. Two complementary callbacks:
;    - OnChar(ih, c)            — printable characters AFTER the layout
;                                  has resolved deadkeys / remaps. This
;                                  is what the user actually typed.
;    - OnKeyDown(ih, vk, sc)    — non-character keys: BS, Enter, Tab,
;                                  arrows, F-keys. Mapped to bracket
;                                  markers ``[BS]``, ``[ENTER]``, …
;                                  matching the Hammerspoon side's
;                                  shape (cf. n-gram walker).
; 3. Privacy filters honoured: every event runs through MF_ShouldFilter()
;    BEFORE landing in the buffer. Disabled apps, private browsing,
;    system-auth dialogs and password fields are short-circuited at
;    the source. The cache inside MF_ShouldFilter keeps the per-keystroke
;    cost negligible (≤ 250 ms TTL).
; 4. Per-keystroke metadata: each event carries a ``kc`` (virtual
;    keycode) entry inside its meta Map so the walker's same-finger /
;    same-hand streak detection has the input it needs. The QWERTY
;    finger map in keylogger_walker.ahk consumes this directly.
; 5. Buffered flush: nothing hits disk on the keystroke path. The
;    buffer accumulates in RAM and a SetTimer (default 2 s) calls
;    KL_FlushBuffer to compose a typing entry and append it to
;    today.log. The ingest tick then drains today.log into data.sql
;    on its own 5 s cadence.
;
; LIFECYCLE:
; - KL_Hook_Start() is called from ErgoptiPlus.ahk right after
;   KL_Init() when the keylogger feature is on.
; - KL_Hook_Stop() releases the hook + cancels the flush timer.
;   Called by KL_Stop() and by the explicit metrics OFF toggle.
; ==============================================================================

#Requires Autohotkey v2.0+




; ===================================
; ===================================
; ======= 1/ Constants =======
; ===================================
; ===================================

class KLHookConst {
    ; Hot path → today.log. Keeping this short means the dashboard sees
    ; new data within ~2 s of the last keystroke, while still bounding
    ; the typing entry size (~50-100 events at typical wpm).
    static FLUSH_PERIOD_MS := 2000

    ; Window context (active app + title) is cheap to refresh but the
    ; per-keystroke cost adds up — cache for this many ms.
    static CONTEXT_TTL_MS  := 500
}

; Special-key VK → bracket marker. Mirrors the macOS hs.eventtap codepath
; in modules/keylogger/log_manager.lua so the n-gram tables share the
; same token shape regardless of OS.
global KLHOOK_SPECIAL := Map(
    0x08, "[BS]",
    0x09, "[TAB]",
    0x0D, "[ENTER]",
    0x1B, "[ESC]",
    0x25, "[LEFT]",
    0x26, "[UP]",
    0x27, "[RIGHT]",
    0x28, "[DOWN]",
    0x2E, "[DEL]",
    0x24, "[HOME]",
    0x23, "[END]",
    0x21, "[PGUP]",
    0x22, "[PGDN]"
)




; ===================================
; ===================================
; ======= 2/ Module state =======
; ===================================
; ===================================

class KLHook {
    static ih           := unset   ; the live InputHook object
    static flush_timer  := unset   ; bound function reference for SetTimer
    static last_tick    := 0       ; A_TickCount of the last captured event

    ; Active-window context cache. Avoids hammering Win32 on every
    ; keystroke; refreshed at most every CONTEXT_TTL_MS.
    static context_at   := 0
}




; ====================================
; ====================================
; ======= 3/ Context refresh =======
; ====================================
; ====================================

KL_Hook_RefreshContext() {
    if (A_TickCount - KLHook.context_at) < KLHookConst.CONTEXT_TTL_MS
        return
    try {
        Keylogger.session_title := WinGetTitle("A")
    }
    try {
        Keylogger.session_app := WinGetProcessName("A")
    }
    KLHook.context_at := A_TickCount
}




; =========================================
; =========================================
; ======= 4/ InputHook callbacks =======
; =========================================
; =========================================

KL_Hook_OnChar(ih, c) {
    ; Privacy filters short-circuit before any allocation.
    filtered := false
    try filtered := MF_ShouldFilter()
    if filtered
        return
    if !Keylogger.initialized
        return

    KL_Hook_RefreshContext()

    now := A_TickCount
    delay := (KLHook.last_tick > 0) ? (now - KLHook.last_tick) : 0
    KLHook.last_tick := now

    ; Per-keystroke metadata. The walker reads ``kc`` for ergonomic
    ; streaks and writes it to ngram_keycodes.
    meta := Map()
    try {
        ih_vk := ih.EndKey  ; populated when the key ended the input
        if IsNumber(ih_vk)
            meta["kc"] := ih_vk
    }

    Keylogger.buffer_events.Push([c, delay, meta])
    Keylogger.buffer_text .= c
}

KL_Hook_OnKeyDown(ih, vk, sc) {
    ; Special keys only — printable chars are handled by OnChar above.
    if !KLHOOK_SPECIAL.Has(vk)
        return

    filtered := false
    try filtered := MF_ShouldFilter()
    if filtered
        return
    if !Keylogger.initialized
        return

    KL_Hook_RefreshContext()

    now := A_TickCount
    delay := (KLHook.last_tick > 0) ? (now - KLHook.last_tick) : 0
    KLHook.last_tick := now

    bracket := KLHOOK_SPECIAL[vk]
    meta := Map("kc", vk)

    Keylogger.buffer_events.Push([bracket, delay, meta])

    ; Mirror text-buffer mutations the user just performed so the
    ; flush's ``buffer_text`` stays meaningful for downstream display.
    switch vk {
        case 0x08:  ; BS — drop the last UTF-16 unit if any.
            n := StrLen(Keylogger.buffer_text)
            if (n > 0)
                Keylogger.buffer_text := SubStr(Keylogger.buffer_text, 1, n - 1)
        case 0x0D:
            Keylogger.buffer_text .= "`n"
        case 0x09:
            Keylogger.buffer_text .= "`t"
        ; Arrow keys, Esc, F-keys etc. do not insert any character so
        ; we leave buffer_text untouched.
    }
}




; =====================================
; =====================================
; ======= 5/ Periodic flush =======
; =====================================
; =====================================

KL_Hook_Tick() {
    ; The flush itself is no-op when the buffer is empty (KL_FlushBuffer
    ; checks). Still fast enough to fire every 2 s without breaking a
    ; sweat — the typical buffer is a few dozen events tops.
    try KL_FlushBuffer()
}




; =====================================
; =====================================
; ======= 6/ Lifecycle =======
; =====================================
; =====================================

KL_Hook_Start() {
    ; Idempotent — multiple Start calls are no-ops once the hook is alive.
    if KLHook.HasOwnProp("ih") && IsObject(KLHook.ih)
        return

    ih := InputHook("V I0 L0")
    ; Notify on every key (no end-key needed). Without this, OnKeyDown
    ; only fires for the keys passed to KeyOpt with the "+N" option.
    ih.KeyOpt("{All}", "+N")
    ; Make sure non-text keys (arrows, F-keys, Esc, BS, Enter, Tab)
    ; still raise OnKeyDown — without this they would be silently
    ; absorbed by the ``Input`` wrapper.
    ih.NotifyNonText := true
    ih.OnChar    := KL_Hook_OnChar
    ih.OnKeyDown := KL_Hook_OnKeyDown
    ih.Start()
    KLHook.ih := ih
    KLHook.last_tick := A_TickCount

    ; Bind the flush callback once and keep the reference around so
    ; SetTimer(…, 0) can stop it cleanly later.
    KLHook.flush_timer := KL_Hook_Tick.Bind()
    SetTimer(KLHook.flush_timer, KLHookConst.FLUSH_PERIOD_MS)
}

KL_Hook_Stop() {
    if KLHook.HasOwnProp("flush_timer") {
        try SetTimer(KLHook.flush_timer, 0)
    }
    if KLHook.HasOwnProp("ih") && IsObject(KLHook.ih) {
        try KLHook.ih.Stop()
        KLHook.ih := unset
    }
    ; Final flush so the in-RAM buffer hits today.log before we leave.
    try KL_FlushBuffer()
}
