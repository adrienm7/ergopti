; modules/keylogger/keylogger_trigger_roi.ahk

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
; KL_Roi_OnHotstring(trigger, net_saved, is_private) is called from
; KL_LogHotstring (modules/keylogger/keylogger_hotstring_log.ahk).
; KL_Roi_OnWord(word) is called from KL_Hook_OnChar when a word boundary
; (space, punctuation) is detected, passing the completed word.
; ==============================================================================

#Requires Autohotkey v2.0+





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

class KLRoiConst {
		; Minimum word length to consider as a trigger candidate
		static MIN_WORD_LEN         := 4

		; Number of times a word must appear in the session to emit a candidate
		static REPEAT_THRESHOLD     := 5

		; Maximum number of words tracked simultaneously (prevents memory growth)
		static MAX_TRACKED_WORDS    := 500

		; Target size the tracking map is shrunk to when it exceeds the cap. The
		; prune always brings the map strictly below MAX_TRACKED_WORDS down to this
		; target so a single saturated word cannot re-trigger a full scan on the
		; very next word boundary — the guard stays amortised-O(1), not O(n)/word.
		static PRUNE_TARGET_WORDS   := 250

		; Hard cap on the in-progress word buffer length. A delimiter-free run
		; (pasted JWT, long token) longer than this is discarded rather than
		; accumulated char-by-char, keeping KL_Roi_OnChar O(1) per keystroke and
		; avoiding holding a secret-like token in RAM until a boundary appears.
		static MAX_INPROGRESS_WORD_LEN := 64

		; Flush ROI snapshot every N fired hotstrings
		static ROI_SNAPSHOT_EVERY   := 10

		; Check trigger half-life every this many ms
		static HALFLIFE_CHECK_MS    := 3600000  ; 1 hour

		; Minimum days since last use to emit a halflife warning
		static HALFLIFE_WARN_DAYS   := 30
}





; ===============================
; ===============================
; ======= 2/ Module state =======
; ===============================
; ===============================

class KLRoi {
		; Running savings accumulator for the current session
		static session_saved_chars  := 0
		static session_fired_count  := 0
		static total_saved_snapshot := 0   ; as of last snapshot flush

		; Word frequency counter for candidate detection
		; Map(lower_word → count)
		static word_counts          := Map()
		static current_word         := ""   ; in-progress word buffer

		; Set true once the in-progress run exceeds MAX_INPROGRESS_WORD_LEN. The
		; whole run (not a 64-char fragment of it) is then discarded at the next
		; boundary so an over-long token never becomes a trigger candidate.
		static word_overflowed      := false

		; Triggers seen this session (for half-life tracking)
		; Map(trigger → last_use_tick)
		static trigger_last_use     := Map()

		; Timer
		static halflife_fn          := unset
}





; =====================================
; ===== 2.1) Initialization guard =====
; =====================================

; Returns false and logs an error if the keylogger has not been initialised yet.
; Every public function that writes to the log or reads live session data must
; call this first so pre-init calls fail loudly rather than silently doing nothing.
KL_Roi_RequireInit(func_name) {
	if !Keylogger.initialized {
		LoggerError("KLRoi", "'{1}' called before KL_Init() — keylogger not initialized.", func_name)
		return false
	}
	return true
}





; =======================================
; =======================================
; ======= 3/ Savings accumulation =======
; =======================================
; =======================================

; Called from KL_LogHotstring after the event is logged.
;
; ``is_private`` says that ``trigger`` has already been redacted by the caller —
; not that the saving should be dropped. The savings accumulate either way (the
; user saved those keystrokes), but the half-life map is skipped: its keys are
; triggers, and a redaction is not a trigger. Keying on it would merge every
; private mapping of the same length into a single entry whose "last use" is
; whichever of them fired most recently, and then emit that merged key in a
; trigger_halflife row.
; @param trigger {String} The fired trigger, redacted when is_private.
; @param net_saved {Integer} Characters saved by this expansion.
; @param is_private {Boolean} True when the mapping is the user's personal data.
KL_Roi_OnHotstring(trigger, net_saved, is_private := false) {
	if !KL_Roi_RequireInit("KL_Roi_OnHotstring")
		return
		if (net_saved <= 0)
				return
		KLRoi.session_saved_chars += net_saved
		KLRoi.session_fired_count += 1
		if !is_private
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





; ===========================================
; ===========================================
; ======= 4/ Candidate word detection =======
; ===========================================
; ===========================================

; Called from KL_Hook_OnChar on every character. Accumulates the current
; word and flushes it at word boundaries.
KL_Roi_OnChar(c) {
	if !KL_Roi_RequireInit("KL_Roi_OnChar")
		return
		; Word characters — accumulate
		if (c != " " and c != "`t" and c != "`n" and c != "`r"
						and c != "." and c != "," and c != "!" and c != "?") {
				; Once the run exceeds the buffer cap, stop accumulating and mark it
				; overflowed: such a delimiter-free run (pasted JWT, long token) is not
				; a real word candidate, and growing it char-by-char would turn this
				; O(1) hot-path append into an O(n) concat per key. The full run is
				; discarded at the boundary, not kept as a 64-char fragment.
				if (KLRoi.word_overflowed)
						return
				if (StrLen(KLRoi.current_word) >= KLRoiConst.MAX_INPROGRESS_WORD_LEN) {
						KLRoi.current_word := ""
						KLRoi.word_overflowed := true
						return
				}
				KLRoi.current_word .= c
				return
		}
		; Word boundary — flush current word, then reset the buffer + overflow flag
		word := KLRoi.current_word
		KLRoi.current_word := ""
		overflowed := KLRoi.word_overflowed
		KLRoi.word_overflowed := false
		; Discard an over-long run entirely so it never becomes a candidate
		if (overflowed)
				return
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

		; Prune the tracking map when it grows too large. The prune is GUARANTEED
		; to bring the map strictly below MAX_TRACKED_WORDS (down to
		; PRUNE_TARGET_WORDS) so a saturated map cannot re-trigger this full scan on
		; every subsequent word boundary — keeping the guard amortised, not O(n)
		; per word once the cap is reached.
		if (KLRoi.word_counts.Count > KLRoiConst.MAX_TRACKED_WORDS)
				KL_Roi_PruneWordCounts()
}



; ===========================================
; ===== 4.1) Bounded tracking-map prune =====
; ===========================================

; Shrinks word_counts to PRUNE_TARGET_WORDS, guaranteed to leave it strictly
; below MAX_TRACKED_WORDS. First drops count = 1 noise; if that is not enough,
; evicts the lowest-count entries until the target is reached. Bounded so the
; map always falls back under the cap and the next word cannot immediately
; re-trigger another full scan (keeps the saturation guard amortised).
KL_Roi_PruneWordCounts() {
		previous_critical := Critical("On")
		try {
		; Pass 1 — drop single-occurrence noise (the cheapest, most disposable words)
		prune := []
		for k, v in KLRoi.word_counts {
				if (v = 1)
						prune.Push(k)
		}
		for _, k in prune
				KLRoi.word_counts.Delete(k)

		; Pass 2 — if still over target (map saturated with count >= 2 entries),
		; evict the lowest-count entries until the map is down to the target. This
		; is what guarantees the map drops below the cap even when no count = 1
		; words exist, so the guard cannot degrade to O(n) on every word.
		if (KLRoi.word_counts.Count > KLRoiConst.PRUNE_TARGET_WORDS) {
				; Collect (key, count) pairs, then insertion-sort ascending by count so
				; the lowest-frequency (most disposable) words are evicted first. The
				; array is at most MAX_TRACKED_WORDS entries and this runs only on the
				; rare prune path, so a simple insertion sort is preferred over cleverness.
				keys := []
				counts := []
				for k, v in KLRoi.word_counts {
						keys.Push(k)
						counts.Push(v)
				}
				i := 2
				n := keys.Length
				while (i <= n) {
						cur_key := keys[i]
						cur_cnt := counts[i]
						j := i - 1
						while (j >= 1 && counts[j] > cur_cnt) {
								keys[j + 1] := keys[j]
								counts[j + 1] := counts[j]
								j -= 1
						}
						keys[j + 1] := cur_key
						counts[j + 1] := cur_cnt
						i += 1
				}
				excess := KLRoi.word_counts.Count - KLRoiConst.PRUNE_TARGET_WORDS
				i := 1
				while (i <= excess && i <= keys.Length) {
						KLRoi.word_counts.Delete(keys[i])
						i += 1
				}
		}
		} finally {
				Critical(previous_critical)
		}
}





; ==========================================
; ==========================================
; ======= 5/ Trigger half-life check =======
; ==========================================
; ==========================================

KL_Roi_HalflifeTick() {
	if !KL_Roi_RequireInit("KL_Roi_HalflifeTick")
		return
	; SetTimer bypasses Suspend — skip the iteration and KL_AppendLog call
	; while paused so the keylogger emits nothing to disk during a pause session.
	if A_IsSuspended
		return
		; We rely on the in-memory trigger_last_use map which only contains
		; triggers seen THIS session. A full historical analysis would require
		; querying data.sql; that is deferred to the dashboard SQL layer.
		; Here we only flag triggers that were used early in the session but
		; not in the last HALFLIFE_WARN_DAYS worth of ticks.
		now := A_TickCount
		threshold := KLRoiConst.HALFLIFE_WARN_DAYS * 86400000
		
		previous_critical := Critical("On")
		try {
				snapshot := Map()
				for trig, last_tick in KLRoi.trigger_last_use
						snapshot[trig] := last_tick
		} finally {
				Critical(previous_critical)
		}

		for trig, last_tick in snapshot {
				; Wrap-safe delta: A_TickCount overflows at ~49.7 days (~4,294,967,295 ms).
				; Clamp to 0 only when the wrap-corrected age exceeds 45 days — far enough
				; above the 30-day alert threshold so the half-life alert is reachable, yet
				; safely below the 49.7-day TickCount ceiling where a post-wrap reading
				; could produce a spurious multi-decade age.
				age := (now - last_tick + 0x100000000) & 0xFFFFFFFF
				static MAX_SANE_AGE_MS := 3888000000  ; 45 days in ms — sanity clamp
				if (age > MAX_SANE_AGE_MS)
						age := 0
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





; ============================
; ============================
; ======= 6/ Lifecycle =======
; ============================
; ============================

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
