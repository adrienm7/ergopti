; modules/keylogger/keylogger_hook.ahk

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
;    cost negligible (≤ 50 ms TTL).
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





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

class KLHookConst {
    ; Hot path → today.log. 500 ms keeps the live dashboard reactive
    ; (the user sees their own keystrokes within ~half a second) while
    ; still bounding typing entries to ~25-30 events at peak rate.
    static FLUSH_PERIOD_MS := 200

    ; Window context (active app + title) is cheap to refresh but the
    ; per-keystroke cost adds up — cache for this many ms. 1000 ms avoids
    ; double Win32 calls (WinGetTitle + WinGetProcessName) at high typing
    ; speed while still detecting app switches within 1 s.
    static CONTEXT_TTL_MS := 1000

    ; Context refresh now runs on its own SetTimer rather than lazily from
    ; the keystroke callbacks. WinGetTitle / WinGetProcessName send messages
    ; to the foreground window's thread (WM_GETTEXT etc.) and can BLOCK when
    ; that thread is busy or Not Responding (a common Electron/Office cold-
    ; start state). Running them on the cooperative keyboard-hook thread would
    ; stall the in-flight keystroke past LowLevelHooksTimeout and drop it —
    ; precisely at an app switch, when the user is starting to type. A 250 ms
    ; timer detects app/title switches promptly while keeping the hook path
    ; free of any blocking Win32 call.
    static CONTEXT_REFRESH_MS := 250

    ; Debounce window for the live dashboard push after a flush. Coalesces
    ; rapid typing bursts into a single KLWV_NotifyIngest call so the
    ; prefetch rebuild (150-300 ms) is not re-triggered on every keystroke
    ; while keeping the dashboard latency under ~2 s during normal use.
    static LIVE_PUSH_DEBOUNCE_MS := 1500
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





; ===============================
; ===============================
; ======= 2/ Module state =======
; ===============================
; ===============================

class KLHook {
    static ih := unset           ; the live InputHook object
    static flush_timer := unset  ; bound function reference for SetTimer
    static context_timer := unset  ; bound ref for the off-thread context refresh
    static live_push_timer := unset  ; one-shot debounce for KLWV_NotifyIngest
    static last_tick := 0        ; A_TickCount of the last captured event

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
    ; "" / 0 signals « no observation yet », so the first refresh
    ; only seeds the values without emitting a spurious switch from
    ; the static "Unknown" defaults.
    static prev_app := ""
    static prev_title := ""
    static app_entered_at := 0
    static title_entered_at := 0
    ; A_TickCount of the last SUSPENDED context tick, 0 while running. SetTimer
    ; keeps firing under native Suspend, so the two watermarks above must be
    ; advanced on every paused tick — otherwise the first refresh after resume
    ; bills the ENTIRE pause to whichever app was focused when the user paused
    ; (KLW_WalkAppSwitch adds duration_ms verbatim to app_time, with no clamp).
    static suspend_tick := 0
}





; ==================================
; ==================================
; ======= 3/ Context refresh =======
; ==================================
; ==================================

; Advance the context watermarks by Elapsed WITHOUT letting them overshoot the
; present.
;
; Two independent compensations exist for the same wall-clock span: this timer's
; suspend branch, and the keystroke-gap branch in KL_Watchers_OnKeystroke. After
; a pause longer than the session timeout BOTH fire and both describe the same
; missing time, so applied one after the other they push app_entered_at PAST
; A_TickCount. The next app_switch then computes `Now - app_entered_at` as a
; NEGATIVE duration, and the walker adds that verbatim to app_time — silently
; subtracting screen time from whichever app was focused.
;
; Clamping here rather than at the consumer keeps the watermark itself honest:
; it can never claim the app was entered in the future.
KL_Hook_AdvanceContextWatermarks(Elapsed) {
    Now := A_TickCount
    KLHook.app_entered_at   := Min(KLHook.app_entered_at + Elapsed, Now)
    KLHook.title_entered_at := Min(KLHook.title_entered_at + Elapsed, Now)
}

KL_Hook_RefreshContext(force := false) {
    ; Driven by SetTimer, which bypasses native Suspend — stay silent while
    ; the driver is paused so no app/title switch is observed or flushed.
    ;
    ; A bare return is not enough: the watermarks would freeze while wall-clock
    ; keeps running, so the first refresh after resume emits an app_switch whose
    ; duration spans the whole pause. KLW_WalkAppSwitch adds that value verbatim
    ; to app_time with no upper clamp, so an overnight pause credited hours of
    ; screen time to whichever app happened to be focused — landing on the RESUME
    ; day. The gap compensation in KL_Watchers_OnKeystroke cannot help: it is
    ; driven by the first post-resume KEYSTROKE, and this 250 ms timer always
    ; fires first whenever the focused app changed during the pause.
    if A_IsSuspended {
        PausedNow := A_TickCount
        if (KLHook.suspend_tick != 0) {
            Elapsed := (PausedNow - KLHook.suspend_tick) & 0xFFFFFFFF
            KL_Hook_AdvanceContextWatermarks(Elapsed)
        }
        KLHook.suspend_tick := PausedNow
        return
    }
    KLHook.suspend_tick := 0
    ; Guard against the timer firing before KL_Init() has completed — the
    ; KL_LogAppSwitch / KL_LogWindowSwitch calls below require an initialized
    ; keylogger instance; without this guard a fast startup race could crash
    ; or write a corrupted switch event (H-16 fix).
    if !Keylogger.initialized
        return
    if !force and (A_TickCount - (KLHook.context_at) & 0xFFFFFFFF) < KLHookConst.CONTEXT_TTL_MS
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

    ; Snapshot the outgoing app BEFORE any mutation below. The app-switch
    ; block updates KLHook.prev_app in place the instant the app itself
    ; changes, so by the time the title-change block runs (same refresh
    ; tick, e.g. Alt-Tab to a different app with a different title)
    ; KLHook.prev_app would already read the NEW app. KL_LogWindowSwitch
    ; must be attributed to the app that actually owned prev_title, not
    ; the one the user switched into (F9 fix).
    outgoing_app := KLHook.prev_app

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
        if (KLHook.prev_title != "" and outgoing_app != "") {
            duration := Now - KLHook.title_entered_at
            ; Flush before logging so the typing buffer is attributed to
            ; the previous window context, not the new one. Mirrors the
            ; flush that already precedes KL_LogAppSwitch above (M-01 fix).
            try KL_FlushBuffer()
            try KL_LogWindowSwitch(outgoing_app, KLHook.prev_title, NewTitle, duration)
        }
        KLHook.prev_title := NewTitle
        KLHook.title_entered_at := Now
    }

    Keylogger.session_title := NewTitle
    Keylogger.session_app := NewApp
    KLHook.context_at := Now
}



; ===================================
; ===== 3.1) Activity watermark =====
; ===================================

; Advances the last_tick watermark and drives the session / idle state machine
; for one physical keypress, returning the inter-keystroke delay in ms relative
; to the PREVIOUS captured key (0 if this is the first).
;
; This must run for EVERY physical key the user presses — including ones whose
; content is privacy-filtered. The key WAS pressed; only its content must be
; dropped, not the timing watermark. If we skipped the watermark on filtered
; keys, the next unfiltered key would compute a giant delay (now - the tick
; before the whole filtered interlude), fabricating a think-pause, breaking the
; walker's burst, and emitting a spurious retroactive idle / session_end.
;
; KL_Watchers_OnKeystroke is driven BEFORE the watermark advances so the watcher
; still reads the gap from the previous keystroke.
;
; @param already_called bool  When true, KL_Watchers_OnKeystroke was already
;                             invoked in the shortcut branch; skip it here to
;                             guarantee exactly one call per physical keydown.
KL_Hook_NoteActivity(already_called := false) {
    ; Do NOT drive the session/idle watcher for SYNTHETIC (auto-typed) keystrokes.
    ; Hotstring expansion and LLM inline-autotype flow through this same InputHook
    ; tagged s=1; without this guard the first synthetic char of a burst reaches
    ; KL_Watchers_OnKeystroke with the real pre-idle last_tick and fabricates an
    ; idle_end / session_start from pure machine output, corrupting the
    ; active-time and idle/session aggregates. Mirrors the ergo/ROI/WPM synth
    ; guard in KL_Hook_OnChar (session-watcher-fed-synthetic). The watermark still
    ; advances below; OnChar/OnKeyDown zero it for synthetic so the next real key
    ; restarts the typing clock.
    ;
    ; Skip when already_called is true — the shortcut branch already fired the
    ; watcher for this same physical keydown; a second call here would duplicate
    ; session/idle accounting for chords that are also special keys (H-01 fix).
    if !Keylogger.synth_active and !already_called
        try KL_Watchers_OnKeystroke()
    now := A_TickCount
    delay := (KLHook.last_tick > 0) ? ((now - KLHook.last_tick) & 0xFFFFFFFF) : 0
    KLHook.last_tick := now
    return delay
}





; ======================================
; ======================================
; ======= 4/ InputHook callbacks =======
; ======================================
; ======================================

KL_Hook_OnChar(ih, c) {
    ; The keylogger records nothing while the script is paused — its InputHook is
    ; separate from HookDispatcher, so it needs its own guard.
    if A_IsSuspended
        return
    if !Keylogger.initialized
        return

    ; An uncaught exception inside an InputHook callback silently disables the
    ; hook permanently. Wrap the entire body so any runtime error is logged and
    ; swallowed — subsequent keystrokes must continue to reach the callback
    ; (keylogger-hook-global-try fix).
    try {
        ; Advance the activity watermark + drive the session/idle machine BEFORE the
        ; privacy filter. A filtered key (password field, private browsing, …) is
        ; still a physical keypress: only its content is dropped, not the timing —
        ; otherwise the next unfiltered key computes a giant delay across the whole
        ; filtered interlude and poisons the burst / think-pause / session metrics.
        delay := KL_Hook_NoteActivity()

        ; Privacy filters short-circuit before any allocation, but AFTER the
        ; watermark has already advanced above.
        filtered := false
        try filtered := MF_ShouldFilter()
        if filtered
            return

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

        ; Stamp the synthetic source while the script is auto-typing (hotstring
        ; expansion / LLM acceptance) so this keystroke is kept out of the manual
        ; `chars` count and attributed correctly in the n-gram source histogram.
        if Keylogger.synth_active {
            meta["s"] := 1
            meta["st"] := Keylogger.synth_type
        }

        Keylogger.buffer_events.Push([c, delay, meta])
        Keylogger.buffer_text .= c
        if !Keylogger.synth_active {
            try KL_Ergo_OnKeystroke(delay, KLHook.last_vk)
            try KL_Roi_OnChar(c)
            ; Feed the real-time WPM widget with each accepted manual keystroke.
            try WPMWidget_Push(false, false)
        } else {
            KLHook.last_tick := 0
        }
    } catch as kl_err {
        try LoggerError("keylogger_hook", "KL_Hook_OnChar unhandled exception — hook kept alive: {1}", kl_err.Message)
    }
}

KL_Hook_OnKeyDown(ih, vk, sc) {
    if A_IsSuspended
        return

    ; An uncaught exception inside an InputHook callback silently disables the
    ; hook permanently. Wrap the entire body so any runtime error is logged and
    ; swallowed — subsequent keystrokes must continue to reach the callback
    ; (keylogger-hook-global-try fix).
    try {
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
        ;
        ; activity_already_noted tracks whether KL_Watchers_OnKeystroke was
        ; already called in the shortcut branch so KL_Hook_NoteActivity can
        ; skip it and avoid a double invocation for chords that are also
        ; special keys (e.g. Ctrl+Left, Ctrl+BS) (H-01 fix).
        activity_already_noted := false
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
                ; Guard: skip entirely during synthetic auto-type so hotstring
                ; expansions never corrupt the session/idle aggregates (H-02 fix).
                if !Keylogger.synth_active {
                    try KL_Watchers_OnKeystroke()
                    KLHook.last_tick := A_TickCount
                    activity_already_noted := true
                }
            }
        }

        ; Special keys only — printable chars are handled by OnChar above.
        if !KLHOOK_SPECIAL.Has(vk)
            return

        if !Keylogger.initialized
            return

        ; Advance the activity watermark + drive the session/idle machine BEFORE the
        ; privacy filter, for the same reason as OnChar: a filtered special key was
        ; still physically pressed, so the timing watermark must not lag behind it.
        ; Pass the flag so KL_Hook_NoteActivity skips the watcher when the shortcut
        ; branch already called it for this same physical keydown (H-01 fix).
        delay := KL_Hook_NoteActivity(activity_already_noted)

        filtered := false
        try filtered := MF_ShouldFilter()
        if filtered
            return

        bracket := KLHOOK_SPECIAL[vk]
        meta := Map("kc", vk, "sk", sc)
        ; Synthetic backspaces emitted by an expansion correcting its own output
        ; carry the source too, so the walker can net them out of hs/llm chars.
        if Keylogger.synth_active {
            meta["s"] := 1
            meta["st"] := Keylogger.synth_type
        }

        Keylogger.buffer_events.Push([bracket, delay, meta])
        if !Keylogger.synth_active {
            try KL_Ergo_OnKeystroke(delay, vk, vk = 0x08)
        } else {
            KLHook.last_tick := 0
        }

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
    } catch as kl_err {
        try LoggerError("keylogger_hook", "KL_Hook_OnKeyDown unhandled exception — hook kept alive: {1}", kl_err.Message)
    }
}





; =================================
; =================================
; ======= 5/ Periodic flush =======
; =================================
; =================================

KL_Hook_Tick() {
    if A_IsSuspended
        return
    ; Fire only when the buffer has something to commit. KL_IngestOnce is
    ; NOT called here — it carries a FileAppend to data.sql that runs on
    ; the same AHK thread and would block incoming keystroke callbacks,
    ; causing perceptible input lag at high typing speed. The 5 s ingest
    ; timer in keylogger.ahk handles persistence asynchronously.
    if (Keylogger.buffer_events.Length = 0
        && Keylogger.session_clicks = 0
        && Keylogger.session_scrolls = 0)
        return
    try KL_FlushBuffer()
    ; Re-arm the debounce timer so the dashboard sees the flush within
    ; LIVE_PUSH_DEBOUNCE_MS after the last keystroke in the burst.
    ; Using a negative period turns SetTimer into a one-shot; re-calling
    ; it before it fires resets the countdown, coalescing burst activity.
    if !KLHook.HasOwnProp("live_push_timer") || !IsObject(KLHook.live_push_timer)
        KLHook.live_push_timer := KL_Hook_LivePush.Bind()
    SetTimer(KLHook.live_push_timer, -KLHookConst.LIVE_PUSH_DEBOUNCE_MS)
}

KL_Hook_LivePush() {
    if A_IsSuspended
        return
    ; Manifest-only rebuild — fast (~20 ms with the manifest cache warm)
    ; and enough for the KPI bar and WPM widget to update in near-real time.
    ; The full "live" rebuild (heatmaps + top-500 n-grams, ~150-300 ms) is
    ; left to the 5 s ingest cycle so it never runs on the flush thread.
    try KLWV_NotifyIngest("manifest")
}





; ============================
; ============================
; ======= 6/ Lifecycle =======
; ============================
; ============================

KL_Hook_Start() {
    ; Idempotent — multiple Start calls are no-ops once subscribed.
    if KLHook.HasOwnProp("registered") && KLHook.registered
        return

    ; Subscribe the keylogger's keyboard handlers to the shared HookDispatcher
    ; instead of opening a second InputHook. The dispatcher already owns the
    ; process-wide InputHook (identical "V L0" + KeyOpt {All} +N + NotifyNonText
    ; options) and already carries the keylogger's mouse subscribers, so this
    ; collapses one per-keystroke hook callback into the shared fan-out.
    ; Dispatch gates on A_IsSuspended, so the handlers stay silent under pause
    ; exactly as the standalone hook's own guard did.
    KLHook.cb_char := KL_Hook_OnChar.Bind()
    KLHook.cb_down := KL_Hook_OnKeyDown.Bind()
    HookDispatcher.Register(HookDispatcherConst.EVT_KB_CHAR, KLHook.cb_char)
    HookDispatcher.Register(HookDispatcherConst.EVT_KB_DOWN, KLHook.cb_down)
    KLHook.registered := true
    KLHook.last_tick := A_TickCount

    ; Bind the flush callback once and keep the reference around so
    ; SetTimer(…, 0) can stop it cleanly later.
    KLHook.flush_timer := KL_Hook_Tick.Bind()
    SetTimer(KLHook.flush_timer, KLHookConst.FLUSH_PERIOD_MS)

    ; Window-context refresh runs on its OWN timer, NOT lazily from the
    ; keystroke callbacks. WinGetTitle / WinGetProcessName can block on a busy
    ; or Not-Responding foreground window; doing that on the keyboard-hook
    ; thread would stall the in-flight keystroke past LowLevelHooksTimeout and
    ; drop it. Off-thread, the hook path reads the cached session_app / title
    ; with zero Win32 cost. Seed once immediately so the first keystroke has a
    ; valid context before the timer's first tick.
    KL_Hook_RefreshContext()
    KLHook.context_timer := KL_Hook_RefreshContext.Bind()
    SetTimer(KLHook.context_timer, KLHookConst.CONTEXT_REFRESH_MS)
}

KL_Hook_Stop() {
    if KLHook.HasOwnProp("flush_timer") && IsObject(KLHook.flush_timer) {
        try SetTimer(KLHook.flush_timer, 0)
    }
    if KLHook.HasOwnProp("context_timer") && IsObject(KLHook.context_timer) {
        try SetTimer(KLHook.context_timer, 0)
    }
    if KLHook.HasOwnProp("live_push_timer") && IsObject(KLHook.live_push_timer) {
        try SetTimer(KLHook.live_push_timer, 0)
    }
    if KLHook.HasOwnProp("cb_char") {
        try HookDispatcher.Unregister(HookDispatcherConst.EVT_KB_CHAR, KLHook.cb_char)
        try HookDispatcher.Unregister(HookDispatcherConst.EVT_KB_DOWN, KLHook.cb_down)
    }
    KLHook.registered := false
    ; Final flush so the in-RAM buffer hits today.log before we leave.
    try KL_FlushBuffer()
}
