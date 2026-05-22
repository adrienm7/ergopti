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
; 1. Passive observation: ``InputHook("V L0")`` runs visible (events
;    keep flowing to apps) and accepts every key (``L0`` = no length
;    cutoff). We deliberately do NOT pass ``I0`` because the layout's
;    remap hotkeys (``*X::Send "y"``) consume the raw key — InputHook
;    only sees the resolved ``Send`` output. ``I0`` would filter that
;    out and we would capture nothing at all.
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
; ============================
; ======= 1/ Constants =======
; ============================
; ===================================

class KLHookConst {
    ; Hot path → today.log. 500 ms keeps the live dashboard reactive
    ; (the user sees their own keystrokes within ~half a second) while
    ; still bounding typing entries to ~25-30 events at peak rate.
    static FLUSH_PERIOD_MS := 200

    ; Window context (active app + title) is cheap to refresh but the
    ; per-keystroke cost adds up — cache for this many ms.
    static CONTEXT_TTL_MS := 500
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
; ===============================
; ======= 2/ Module state =======
; ===============================
; ===================================

class KLHook {
    static ih := unset   ; the live InputHook object
    static flush_timer := unset   ; bound function reference for SetTimer
    static last_tick := 0       ; A_TickCount of the last captured event

    ; Last (vk, sc) seen by OnKeyDown — paired with OnChar so each
    ; printable char carries both the virtual keycode AND the hardware
    ; scancode. The scancode is layout-independent and is what the
    ; Windows heatmap renders against.
    static last_vk := 0
    static last_sc := 0

    ; Active-window context cache. Avoids hammering Win32 on every
    ; keystroke; refreshed at most every CONTEXT_TTL_MS.
    static context_at := 0

    ; Previous (app, title) values + their entry tick — used to emit
    ; ``app_switch`` / ``window_switch`` events when the focused app or
    ; title changes. Mirrors HS init.lua:862 / context_tracker.lua:230.
    ; ``"" / 0`` signals « no observation yet », so the first refresh
    ; only seeds the values without emitting a spurious switch from
    ; the static "Unknown" defaults.
    static prev_app := ""
    static prev_title := ""
    static app_entered_at := 0
    static title_entered_at := 0
}





; ====================================
; ==================================
; ======= 3/ Context refresh =======
; ==================================
; ====================================

KL_Hook_RefreshContext() {
    if (A_TickCount - KLHook.context_at) < KLHookConst.CONTEXT_TTL_MS
        return
    NewTitle := ""
    NewApp := ""
    try {
        NewTitle := WinGetTitle("A")
    }
    try {
        NewApp := WinGetProcessName("A")
    }
    Now := A_TickCount

    ; Emit app_switch / window_switch the first time we observe a change.
    ; HS tracks app and title separately because a window-title-only change
    ; (e.g. switching tabs in a browser) is interesting on its own — it
    ; surfaces in the metrics dashboard as a per-app context shift without
    ; double-counting as an app switch.
    if (NewApp != "" and NewApp != KLHook.prev_app) {
        if (KLHook.prev_app != "") {
            duration := Now - KLHook.app_entered_at
            ; Flush before logging so the typing buffer is attributed to the
            ; previous app, not the new one. Mirrors HS log_manager flush_buffer
            ; calls on app_switch.
            try KL_FlushBuffer()
            try KL_LogAppSwitch(KLHook.prev_app, NewApp, duration)
        }
        KLHook.prev_app := NewApp
        KLHook.app_entered_at := Now
    }
    if (NewTitle != KLHook.prev_title) {
        if (KLHook.prev_title != "" and KLHook.prev_app != "") {
            duration := Now - KLHook.title_entered_at
            try KL_LogWindowSwitch(KLHook.prev_app, KLHook.prev_title, NewTitle, duration)
        }
        KLHook.prev_title := NewTitle
        KLHook.title_entered_at := Now
    }

    Keylogger.session_title := NewTitle
    Keylogger.session_app := NewApp
    KLHook.context_at := Now
}





; =========================================
; ======================================
; ======= 4/ InputHook callbacks =======
; ======================================
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

    ; Drive the session / idle state machine BEFORE last_tick is updated,
    ; so the watcher reads the gap from the previous keystroke.
    try KL_Watchers_OnKeystroke()

    now := A_TickCount
    delay := (KLHook.last_tick > 0) ? (now - KLHook.last_tick) : 0
    KLHook.last_tick := now

    ; Per-keystroke metadata. The walker reads ``kc`` for ergonomic
    ; streaks and writes it to ngram_keycodes; ``sc`` is the hardware
    ; scancode used by the Windows heatmap.
    meta := Map()
    try {
        if (KLHook.last_vk > 0)
            meta["kc"] := KLHook.last_vk
        ; ``sk`` (scan-key) — hardware scancode. Distinct from ``sc``
        ; which the walker reserves for "shortcut key" identifiers.
        if (KLHook.last_sc > 0)
            meta["sk"] := KLHook.last_sc
    }

    Keylogger.buffer_events.Push([c, delay, meta])
    Keylogger.buffer_text .= c
    try KL_Ergo_OnKeystroke(delay, KLHook.last_vk)
    try KL_Roi_OnChar(c)
    ; Feed the real-time WPM widget with each accepted manual keystroke.
    try WPMWidget_Push(false, false)
}

KL_Hook_OnKeyDown(ih, vk, sc) {
    ; Always stash (vk, sc) for the next OnChar callback — printable
    ; characters reach OnChar after this fires, and we need the sc to
    ; populate the heatmap. Wrap defensively: an uncaught error inside
    ; an InputHook callback silently disables the hook.
    try {
        if IsNumber(vk)
            KLHook.last_vk := vk
        if IsNumber(sc)
            KLHook.last_sc := sc
    }

    ; Shortcut detection runs BEFORE the special-keys early return so
    ; chords on letter / digit / function keys are caught — those VKs
    ; are not in KLHOOK_SPECIAL because OnChar handles their printable
    ; output, but with modifiers held they are shortcuts to log.
    if Keylogger.initialized {
        sk := ""
        try sk := KL_Watchers_DetectShortcut(vk)
        if (sk != "") {
            try KL_LogShortcut(sk, Keylogger.session_app)
            ; A shortcut counts as user activity. Drive the session/idle
            ; machine and bump last_tick so a stream of Ctrl+S / Ctrl+C
            ; presses (which most apps consume before OnChar can fire)
            ; doesn't fall back to the SESSION_TIMEOUT_MS clock and have
            ; its own session_start re-fire on every chord.
            try KL_Watchers_OnKeystroke()
            KLHook.last_tick := A_TickCount
        }
    }

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

    ; Drive the session / idle state machine BEFORE last_tick is updated.
    try KL_Watchers_OnKeystroke()

    now := A_TickCount
    delay := (KLHook.last_tick > 0) ? (now - KLHook.last_tick) : 0
    KLHook.last_tick := now

    bracket := KLHOOK_SPECIAL[vk]
    meta := Map("kc", vk, "sk", sc)

    Keylogger.buffer_events.Push([bracket, delay, meta])
    try KL_Ergo_OnKeystroke(delay, vk, vk = 0x08)

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
; =================================
; ======= 5/ Periodic flush =======
; =================================
; =====================================

KL_Hook_Tick() {
    ; Fire only when the buffer has something to commit. We then flush
    ; AND chain straight into KL_IngestOnce so the dashboard’s live
    ; channel sees the new keystrokes within ~500 ms instead of waiting
    ; for the slower 5 s ingest cadence. The cached SQLite DB makes
    ; this near-free (only the new INSERTs are exec'd).
    if (Keylogger.buffer_events.Length = 0
        && Keylogger.session_clicks = 0
        && Keylogger.session_scrolls = 0)
        return
    try KL_FlushBuffer()
    try KL_IngestOnce()
}





; =====================================
; ============================
; ======= 6/ Lifecycle =======
; ============================
; =====================================

KL_Hook_Start() {
    ; Idempotent — multiple Start calls are no-ops once the hook is alive.
    if KLHook.HasOwnProp("ih") && IsObject(KLHook.ih)
        return

    ih := InputHook("V L0")
    ; Notify on every key (no end-key needed). Without this, OnKeyDown
    ; only fires for the keys passed to KeyOpt with the "+N" option.
    ih.KeyOpt("{All}", "+N")
    ; Make sure non-text keys (arrows, F-keys, Esc, BS, Enter, Tab)
    ; still raise OnKeyDown — without this they would be silently
    ; absorbed by the ``Input`` wrapper.
    ih.NotifyNonText := true
    ih.OnChar := KL_Hook_OnChar
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
