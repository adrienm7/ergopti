; modules/keylogger_trigger_roi.ahk

; ==============================================================================
; MODULE: Keylogger Trigger ROI & Candidate Detection
; DESCRIPTION:
; Tracks the cumulative character savings from hotstring expansions and
; auto-detects repeated manually-typed words that would be good trigger
; candidates. Together these feed the « automation savings » KPI and the
; « suggested new triggers » feature in the metrics dashboard.
;
; FEATURES & RATIONALE:
; 1. Cumulative savings accounting — every KL_LogHotstring call passes
;    net_saved_chars, but that data only lives in events_hotstring. This
;    module maintains an in-RAM accumulator (KLRoi.session_saved_chars)
;    that is flushed into a roi_snapshot JSONL entry at flush time. The
;    dashboard can then sum these to show « you've saved X keystrokes this
;    week » without a GROUP BY over the full hotstring table.
; 2. New trigger candidates — a sliding n-gram counter watches the
;    live typing buffer. When a word (≥ MIN_WORD_LEN chars, no spaces)
;    appears REPEAT_THRESHOLD times within the session, and is NOT already
;    a known trigger, it is logged as a new_trigger_candidate event. This
;    surfaces the exact phrases the user types most and forgets to automate.
; 3. Trigger half-life — each existing trigger is timestamped at first and
;    last use in keylogger.ahk's hotstring events. This module periodically
;    queries the in-RAM pending_entries to check if triggers that were used
;    in the past ROI_HALFLIFE_CHECK_MS have not been seen since — and emits
;    a trigger_halflife event noting the days since last use. Dashboard uses
;    this to suggest pruning stale triggers.
;
; INTEGRATION:
; KL_Roi_OnHotstring(trigger, net_saved) is called from KL_LogHotstring.
; KL_Roi_OnWord(word) is called from KL_Hook_OnChar when a word boundary
; (space, punctuation) is detected, passing the completed word.
; ==============================================================================

#Requires Autohotkey v2.0+





; ===================================
; ===================================
; ======= 1/ Constants =======
; ===================================
; ===================================

class KLRoiConst {
    ; Minimum word length to consider as a trigger candidate
    static MIN_WORD_LEN         := 4

    ; Number of times a word must appear in the session to emit a candidate
    static REPEAT_THRESHOLD     := 5

    ; Maximum number of words tracked simultaneously (prevents memory growth)
    static MAX_TRACKED_WORDS    := 500

    ; Flush ROI snapshot every N fired hotstrings
    static ROI_SNAPSHOT_EVERY   := 10

    ; Check trigger half-life every this many ms
    static HALFLIFE_CHECK_MS    := 3600000  ; 1 hour

    ; Minimum days since last use to emit a halflife warning
    static HALFLIFE_WARN_DAYS   := 30
}





; ===================================
; ===================================
; ======= 2/ Module state =======
; ===================================
; ===================================

class KLRoi {
    ; Running savings accumulator for the current session
    static session_saved_chars  := 0
    static session_fired_count  := 0
    static total_saved_snapshot := 0   ; as of last snapshot flush

    ; Word frequency counter for candidate detection
    ; Map(lower_word → count)
    static word_counts          := Map()
    static current_word         := ""   ; in-progress word buffer

    ; Triggers seen this session (for half-life tracking)
    ; Map(trigger → last_use_tick)
    static trigger_last_use     := Map()

    ; Timer
    static halflife_fn          := unset
}





; =========================================
; =========================================
; ======= 3/ Savings accumulation =======
; =========================================
; =========================================

; Called from KL_LogHotstring in keylogger.ahk after the event is logged.
KL_Roi_OnHotstring(trigger, net_saved) {
    if (net_saved <= 0)
        return
    KLRoi.session_saved_chars += net_saved
    KLRoi.session_fired_count += 1
    KLRoi.trigger_last_use[StrLower(trigger)] := A_TickCount

    ; Emit a periodic roi_snapshot so the dashboard can plot savings over time
    ; without aggregating over the entire hotstring table.
    if (Mod(KLRoi.session_fired_count, KLRoiConst.ROI_SNAPSHOT_EVERY) = 0) {
        KL_AppendLog(Map(
            "type",              "roi_snapshot",
            "app",               Keylogger.session_app,
            "session_saved",     KLRoi.session_saved_chars,
            "session_fired",     KLRoi.session_fired_count
        ))
    }
}





; =============================================
; =============================================
; ======= 4/ Candidate word detection =======
; =============================================
; =============================================

; Called from KL_Hook_OnChar on every character. Accumulates the current
; word and flushes it at word boundaries.
KL_Roi_OnChar(c) {
    ; Word characters — accumulate
    if (c != " " and c != "`t" and c != "`n" and c != "`r"
            and c != "." and c != "," and c != "!" and c != "?") {
        KLRoi.current_word .= c
        return
    }
    ; Word boundary — flush current word
    word := KLRoi.current_word
    KLRoi.current_word := ""
    KL_Roi_ProcessWord(word)
}

KL_Roi_ProcessWord(word) {
    global _TriggerSet
    if (StrLen(word) < KLRoiConst.MIN_WORD_LEN)
        return
    key := StrLower(word)

    ; Skip words that are already triggers
    if IsSet(_TriggerSet) && _TriggerSet.Has(key)
        return

    ; Bump count
    cnt := KLRoi.word_counts.Has(key) ? KLRoi.word_counts[key] : 0
    cnt += 1
    KLRoi.word_counts[key] := cnt

    ; Emit candidate event on threshold crossing
    if (cnt = KLRoiConst.REPEAT_THRESHOLD) {
        KL_AppendLog(Map(
            "type",        "new_trigger_candidate",
            "app",         Keylogger.session_app,
            "word",        word,
            "occurrences", cnt
        ))
    }

    ; Prune the tracking map when it grows too large
    if (KLRoi.word_counts.Count > KLRoiConst.MAX_TRACKED_WORDS) {
        ; Drop all words with count = 1 (noise)
        prune := []
        for k, v in KLRoi.word_counts {
            if (v = 1)
                prune.Push(k)
        }
        for k in prune
            KLRoi.word_counts.Delete(k)
    }
}





; ===================================================
; ===================================================
; ======= 5/ Trigger half-life check =======
; ===================================================
; ===================================================

KL_Roi_HalflifeTick() {
    if !Keylogger.initialized
        return
    ; We rely on the in-memory trigger_last_use map which only contains
    ; triggers seen THIS session. A full historical analysis would require
    ; querying data.sql; that is deferred to the dashboard SQL layer.
    ; Here we only flag triggers that were used early in the session but
    ; not in the last HALFLIFE_WARN_DAYS worth of ticks.
    now := A_TickCount
    threshold := KLRoiConst.HALFLIFE_WARN_DAYS * 86400000
    for trig, last_tick in KLRoi.trigger_last_use {
        age := now - last_tick
        if (age >= threshold) {
            KL_AppendLog(Map(
                "type",    "trigger_halflife",
                "app",     Keylogger.session_app,
                "trigger", trig,
                "days_since_use", Round(age / 86400000, 1)
            ))
        }
    }
}





; =====================================
; =====================================
; ======= 6/ Lifecycle =======
; =====================================
; =====================================

KL_Roi_Start() {
    if KLRoi.HasOwnProp("halflife_fn") && IsObject(KLRoi.halflife_fn)
        return
    KLRoi.halflife_fn := KL_Roi_HalflifeTick.Bind()
    SetTimer(KLRoi.halflife_fn, KLRoiConst.HALFLIFE_CHECK_MS)
}

KL_Roi_Stop() {
    if KLRoi.HasOwnProp("halflife_fn") && IsObject(KLRoi.halflife_fn) {
        try SetTimer(KLRoi.halflife_fn, 0)
        KLRoi.halflife_fn := unset
    }
    ; Final ROI snapshot on shutdown so the last session's savings are persisted
    if (KLRoi.session_fired_count > 0) {
        try KL_AppendLog(Map(
            "type",          "roi_snapshot",
            "app",           Keylogger.session_app,
            "session_saved", KLRoi.session_saved_chars,
            "session_fired", KLRoi.session_fired_count
        ))
    }
}
