; modules/keylogger/keylogger_ergonomics.ahk

; ==============================================================================
; MODULE: Keylogger Ergonomics
; DESCRIPTION:
; Emits discrete ergonomic events derived from the live keystroke stream:
; continuous typing blocks, burst-strain markers, pinky overload windows,
; and backspace-burst (error cascade) events. These events complement the
; aggregated ergo stats in the walker (same_finger_streak_max, etc.) with
; timestamped, app-attributed point events that can be surfaced as warnings
; in the metrics dashboard.
;
; FEATURES & RATIONALE:
; 1. Continuous typing block — emitted when the user types for longer than
;    BLOCK_WARN_MS without a pause exceeding BLOCK_BREAK_MS. This is the
;    primary repetitive strain indicator: unbroken typing sessions are
;    correlated with wrist fatigue and RSI onset. The event includes the
;    block duration, char count, and effective WPM so the dashboard can
;    colour-code blocks by intensity.
; 2. Backspace burst (error cascade) — when BS is pressed more than
;    BS_BURST_THRESHOLD times in a row the user is experiencing a typing
;    error cascade. This is a soft cognitive load signal: it spikes around
;    complex words, foreign-language switches, and fatigued typing. Emitted
;    on BS_BURST_THRESHOLD exceeded, with the run length at that point.
; 3. Pinky overload window — when the same-finger tracker in the walker
;    observes a PINKY_STREAK_THRESHOLD same-pinky-key run the hook posts
;    a pinky_overload event. Pinky is the weakest finger; sustained runs on
;    it (Q, A, Z on left; P, ;, / on right) are a leading ergonomic risk.
; 4. Flow detection — the inverse of fatigue: when the user maintains
;    WPM > FLOW_WPM_THRESHOLD continuously for FLOW_WINDOW_MS or more a
;    flow_window event is emitted. Flow windows are the most productive
;    typing segments; the dashboard can highlight and protect them.
; 5. Hesitation — when a single inter-key delay exceeds HESITATION_MS the
;    event is tagged. Hesitation clusters around unfamiliar words, typing
;    in a second language, or search for the right phrasing — a useful
;    cognitive signal for the hotstring suggestion engine.
;
; INTEGRATION:
; KL_Ergo_OnKeystroke(char, delay_ms, vk) is called from
; KL_Hook_OnChar / KL_Hook_OnKeyDown in keylogger_hook.ahk immediately
; after the event is pushed to the buffer. This adds a single O(1) call
; per keystroke with no allocations on the fast path.
; ==============================================================================

#Requires Autohotkey v2.0+





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

class KLErgoConst {
    ; Continuous-block detection
    ; Gap ≥ this (ms) resets the current block
    static BLOCK_BREAK_MS          := 10000
    ; Warn after typing this many ms in the same block
    static BLOCK_WARN_MS           := 1200000   ; 20 minutes

    ; Backspace burst threshold (consecutive BS presses)
    static BS_BURST_THRESHOLD      := 5

    ; Pinky overload — consecutive same-pinky keypresses
    static PINKY_STREAK_THRESHOLD  := 4

    ; Flow window — min duration (ms) at ≥ WPM threshold to qualify
    static FLOW_WINDOW_MS          := 300000    ; 5 minutes
    static FLOW_WPM_THRESHOLD      := 60        ; adjusted-WPM

    ; Hesitation — single inter-key delay above this value
    static HESITATION_MS           := 2000
    ; Upper bound on what counts as a hesitation. Pinned to the session timeout
    ; (KLWatchConst.SESSION_TIMEOUT_MS) rather than restated: past that gap the
    ; watchers already consider the session over, so by the driver's own
    ; definition the user was away rather than hesitating.
    static HESITATION_MAX_MS       := 300000
    ; Debounce: don't emit consecutive hesitations within this window
    static HESITATION_COOLDOWN_MS  := 10000

    ; Pinky VK codes (left and right)
    static PINKY_VKS := Map(
        0x51, true,   ; Q
        0x41, true,   ; A
        0x5A, true,   ; Z
        0x31, true,   ; 1
        0x50, true,   ; P
        0xBA, true,   ; ;
        0xBF, true,   ; /
        0x30, true    ; 0
    )
}





; ===============================
; ===============================
; ======= 2/ Module state =======
; ===============================
; ===============================

class KLErgo {
    ; ── Continuous block ────────────────────────────────────────────────
    static block_start      := 0       ; A_TickCount of first keystroke in block
    static block_chars      := 0       ; characters typed in current block
    static block_warned     := false   ; have we already warned for this block?
    static block_app        := ""

    ; ── Backspace burst ──────────────────────────────────────────────────
    static bs_run           := 0       ; consecutive BS presses
    static bs_burst_app     := ""

    ; ── Pinky streak ─────────────────────────────────────────────────────
    static pinky_run        := 0
    static pinky_vk         := 0       ; which pinky key
    static pinky_app        := ""

    ; ── Flow window ──────────────────────────────────────────────────────
    ; Track a rolling WPM over the last WPM_WINDOW_TICKS keystrokes
    static flow_chars       := 0
    static flow_start       := 0
    static flow_active      := false
    static flow_app         := ""

    ; ── Hesitation ───────────────────────────────────────────────────────
    static last_hesitation  := 0       ; tick of last hesitation event
}





; =======================================
; =======================================
; ======= 3/ Keystroke dispatcher =======
; =======================================
; =======================================

; Entry point called from KL_Hook_OnChar and KL_Hook_OnKeyDown.
; ``is_bs`` is true only for the backspace VK (0x08) so we can
; maintain the bs_run counter without disturbing the block tracker.
KL_Ergo_OnKeystroke(delay_ms, vk, is_bs := false) {
    if !Keylogger.initialized
        return
    now := A_TickCount
    app := Keylogger.session_app

    KL_Ergo_CheckHesitation(delay_ms, now, app)
    KL_Ergo_UpdateBlock(delay_ms, now, app, is_bs)
    KL_Ergo_UpdatePinky(vk, now, app)
    if is_bs {
        KLErgo.bs_run += 1
        KLErgo.bs_burst_app := app
        KL_Ergo_CheckBsBurst(now)
    } else {
        KLErgo.bs_run := 0
    }
}





; =======================================
; =======================================
; ======= 4/ Hesitation detection =======
; =======================================
; =======================================

KL_Ergo_CheckHesitation(delay_ms, now, app) {
    if (delay_ms < KLErgoConst.HESITATION_MS)
        return
    ; An away-gap is not a hesitation. Returning from lunch, a meeting or an
    ; overnight pause produces a delay of minutes or hours, and recording that
    ; as a "hesitation" put values three to five orders of magnitude above a real
    ; one into the distribution — a handful of them dominate every percentile
    ; the dashboard computes. A hesitation is someone pausing mid-thought at the
    ; keyboard, which is bounded by the same threshold that ends a typing
    ; session: past it the user was not hesitating, they were gone.
    if (delay_ms >= KLErgoConst.HESITATION_MAX_MS)
        return
    if (KLErgo.last_hesitation > 0
		and TickElapsed(KLErgo.last_hesitation, now) < KLErgoConst.HESITATION_COOLDOWN_MS)
        return
    KLErgo.last_hesitation := now
    KL_LogErgoEvent("hesitation", app, Map("delay_ms", delay_ms))
}





; ============================================
; ============================================
; ======= 5/ Continuous block tracking =======
; ============================================
; ============================================

KL_Ergo_UpdateBlock(delay_ms, now, app, is_bs) {
    ; A gap >= BLOCK_BREAK_MS resets the block
    if (KLErgo.block_start > 0 and delay_ms >= KLErgoConst.BLOCK_BREAK_MS) {
        if KLErgo.block_warned {
            block_ms := (now - delay_ms - KLErgo.block_start) & 0xFFFFFFFF
            KL_LogErgoEvent("continuous_typing_block_end", KLErgo.block_app, Map(
                "duration_ms",  block_ms,
                "chars",        KLErgo.block_chars
            ))
        }
        ; Close any open flow window before discarding the block — without this the
        ; JSONL log is left with a dangling open-flow event that has no matching end
        if KLErgo.flow_active {
            flow_dur := (now - delay_ms - KLErgo.flow_start) & 0xFFFFFFFF
            block_ms_flow := (now - delay_ms - KLErgo.block_start) & 0xFFFFFFFF
            wpm_flow := (block_ms_flow > 0)
                ? Round((KLErgo.block_chars / 5) / (block_ms_flow / 60000), 1)
                : 0
            KL_LogErgoEvent("flow_window_end", KLErgo.flow_app, Map(
                "duration_ms", flow_dur,
                "wpm",         wpm_flow
            ))
        }
        KLErgo.block_start   := 0
        KLErgo.block_chars   := 0
        KLErgo.block_warned  := false
        KLErgo.block_app     := ""
        KLErgo.flow_active   := false
    }

    if (KLErgo.block_start = 0) {
        KLErgo.block_start := now
        KLErgo.block_app   := app
    }
    if !is_bs
        KLErgo.block_chars += 1

    ; Warn once after BLOCK_WARN_MS in the same block
    if (!KLErgo.block_warned
            and ((now - KLErgo.block_start) & 0xFFFFFFFF) >= KLErgoConst.BLOCK_WARN_MS) {
        KLErgo.block_warned := true
        block_ms := (now - KLErgo.block_start) & 0xFFFFFFFF
        wpm := (block_ms > 0) ? Round((KLErgo.block_chars / 5) / (block_ms / 60000), 1) : 0
        KL_LogErgoEvent("continuous_typing_block", KLErgo.block_app, Map(
            "duration_ms", block_ms,
            "chars",       KLErgo.block_chars,
            "wpm",         wpm
        ))
    }

    ; Flow detection — sustained WPM within the current block (may emit flow_window_start via KL_Ergo_CheckFlow)
    KL_Ergo_CheckFlow(now, app)
}





; ========================================
; ========================================
; ======= 6/ Flow window detection =======
; ========================================
; ========================================

KL_Ergo_CheckFlow(now, app) {
    ; Reset flow tracking when the block resets
    if (KLErgo.block_start = 0) {
        KLErgo.flow_active := false
        KLErgo.flow_chars  := 0
        KLErgo.flow_start  := 0
        return
    }
    ; Count chars in the last FLOW_WINDOW_MS window
    ; Approximation: use the block's running WPM
    block_ms := (now - KLErgo.block_start) & 0xFFFFFFFF
    if (block_ms < KLErgoConst.FLOW_WINDOW_MS)
        return

    ; Rolling WPM over entire block duration (conservative)
    wpm := Round((KLErgo.block_chars / 5) / (block_ms / 60000), 1)
    if (wpm >= KLErgoConst.FLOW_WPM_THRESHOLD) {
        if !KLErgo.flow_active {
            KLErgo.flow_active := true
            KLErgo.flow_start  := now
            KLErgo.flow_app    := app
            KL_LogErgoEvent("flow_window_start", app, Map("wpm", wpm))
        }
    } else {
        if KLErgo.flow_active {
            KLErgo.flow_active := false
            dur := (now - KLErgo.flow_start) & 0xFFFFFFFF
            KL_LogErgoEvent("flow_window_end", KLErgo.flow_app, Map(
                "duration_ms", dur,
                "wpm",         wpm
            ))
        }
    }
}





; ============================================
; ============================================
; ======= 7/ Backspace burst detection =======
; ============================================
; ============================================

KL_Ergo_CheckBsBurst(now) {
    if (KLErgo.bs_run = KLErgoConst.BS_BURST_THRESHOLD) {
        KL_LogErgoEvent("backspace_burst", KLErgo.bs_burst_app,
            Map("run_length", KLErgo.bs_run))
    }
}





; ===========================================
; ===========================================
; ======= 8/ Pinky overload detection =======
; ===========================================
; ===========================================

KL_Ergo_UpdatePinky(vk, now, app) {
    ; Modifier keys don't break a physical pinky streak — skip them
    if (vk == 0x10 or vk == 0x11 or vk == 0x12   ; generic Shift/Ctrl/Alt
     or vk == 0xA0 or vk == 0xA1                  ; LShift, RShift
     or vk == 0xA2 or vk == 0xA3                  ; LCtrl, RCtrl
     or vk == 0xA4 or vk == 0xA5                  ; LAlt, RAlt
     or vk == 0x5B or vk == 0x5C)                 ; LWin, RWin
        return
    if !KLErgoConst.PINKY_VKS.Has(vk) {
        KLErgo.pinky_run := 0
        return
    }
    if (KLErgo.pinky_vk != vk) {
        KLErgo.pinky_run := 0
        KLErgo.pinky_vk  := vk
        KLErgo.pinky_app := app
    }
    KLErgo.pinky_run += 1
    if (KLErgo.pinky_run = KLErgoConst.PINKY_STREAK_THRESHOLD) {
        KL_LogErgoEvent("pinky_overload", app, Map(
            "vk",        vk,
            "run_length", KLErgo.pinky_run
        ))
    }
}





; =============================
; =============================
; ======= 9/ Log helper =======
; =============================
; =============================

KL_LogErgoEvent(kind, app, meta := unset) {
    if !Keylogger.initialized
        return
    e := Map("type", "ergo_event", "kind", kind, "app", app)
    if IsSet(meta) && (meta is Map) {
        for k, v in meta
            e[k] := v
    }
    KL_AppendLog(e)
}
