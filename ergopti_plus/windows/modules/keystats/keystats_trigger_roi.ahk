; modules/keystats/keystats_trigger_roi.ahk

; ==============================================================================
; MODULE: Keystats Trigger ROI & Candidate Detection
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
;    last use in keystats.ahk's hotstring events. This module periodically
;    queries the in-RAM pending_entries to check if triggers that were used
;    in the past ROI_HALFLIFE_CHECK_MS have not been seen since — and emits
;    a trigger_halflife event noting the days since last use. Dashboard uses
;    this to suggest pruning stale triggers.
;
; INTEGRATION:
; KL_Roi_OnHotstring(trigger, net_saved, is_private) is called from
; KL_LogHotstring (modules/keystats/keystats_hotstring_log.ahk).
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
		; Advanced by every live-map mutation. A prune publishes its precomputed
		; survivor Map only when this still matches the snapshot generation.
		static word_counts_generation := 0
		static current_word         := ""   ; in-progress word buffer
		static word_context         := false ; immutable canonical focus identity

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

; Returns false and logs an error if the keystats has not been initialised yet.
; Every public function that writes to the log or reads live session data must
; call this first so pre-init calls fail loudly rather than silently doing nothing.
KL_Roi_RequireInit(func_name) {
	if !Keystats.initialized {
		LoggerError("KLRoi", "'{1}' called before KL_Init() — keystats not initialized.", func_name)
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
	InputEpoch := KLRoiPrivacy.epoch
	; Deferred fire callbacks outlive native Suspend unless their generation is
	; retired. Keep the sink itself fail-closed too: no stale caller may mutate
	; session savings or half-life state while the driver is paused.
	if A_IsSuspended
		return
	if !KL_Roi_RequireInit("KL_Roi_OnHotstring")
		return
	; Require-init may log and therefore yield. Recheck pause inside the same short
	; transaction as every ROI mutation; the periodic append stays outside so no
	; privacy lookup or logger call can starve the keyboard hook under Critical.
	RoiCritical := Critical("On")
	try {
		if A_IsSuspended
			return
		KLRoi.session_saved_chars += Max(0, net_saved)
		KLRoi.session_fired_count += 1
		TextAllowed := KL_Roi_TextAllowed() && InputEpoch == KLRoiPrivacy.epoch
		if !is_private && TextAllowed
			KLRoi.trigger_last_use[StrLower(trigger)] := A_TickCount
		EmitSnapshot := (Mod(KLRoi.session_fired_count,
			KLRoiConst.ROI_SNAPSHOT_EVERY) = 0)
		SnapshotSaved := KLRoi.session_saved_chars
		SnapshotFired := KLRoi.session_fired_count
		SnapshotApp := Keystats.session_app
	} finally {
		Critical(RoiCritical)
	}

	; Emit a periodic roi_snapshot so the dashboard can plot savings over time
	; without aggregating over the entire hotstring table.
	if EmitSnapshot {
		KL_AppendLog(Map(
			"type",          "roi_snapshot",
			"app",           SnapshotApp,
			"session_saved", SnapshotSaved,
			"session_fired", SnapshotFired
		))
	}
}





; ===========================================
; ===========================================
; ======= 4/ Candidate word detection =======
; ===========================================
; ===========================================

; A discontinuity discards a fragment; it never promotes it to a candidate.
; RAM-only so privacy, pointer and lifecycle barriers can use it without I/O.
KL_Roi_DiscardWord() {
	PreviousCritical := Critical("On")
	try {
		KLRoi.current_word := ""
		KLRoi.word_overflowed := false
		KLRoi.word_context := false
	} finally Critical(PreviousCritical)
}

; Read the already published immutable focus value, without a new OS query.
; Its generation changes on ordinary polls; only app/title/HWND ownership breaks
; the word. RefreshContext also calls this for A→B→A gaps containing no chars.
KL_Roi_AdmitWordContext(Snapshot := unset) {
	PreviousCritical := Critical("On")
	try {
		if !IsSet(Snapshot)
			Snapshot := MetricsFocusCache.state
		if KL_CaptureHeld() || !IsObject(Snapshot) || !Snapshot.HasOwnProp("valid") || !Snapshot.valid {
			KL_Roi_DiscardWord()
			return false
		}
		Previous := KLRoi.word_context
		if IsObject(Previous) && (Previous.hwnd != Snapshot.hwnd
				|| Previous.process_name !== Snapshot.process_name || Previous.title !== Snapshot.title)
			KL_Roi_DiscardWord()
		KLRoi.word_context := Snapshot
		return true
	} finally Critical(PreviousCritical)
}

; Called from KL_Hook_OnChar on every character. Accumulates the current
; word and flushes it at word boundaries.
KL_Roi_OnChar(Text, InputEpoch := unset) {
	InputEpoch := IsSet(InputEpoch) ? InputEpoch : KLRoiPrivacy.epoch
	if !KL_Roi_TextAllowed()
		return
	if !KL_Roi_RequireInit("KL_Roi_OnChar") || !KL_Roi_AdmitWordContext()
		return
	; A failed dead-key composition can deliver several characters in one callback.
	Position := 1, Units := StrLen(Text)
	while Position <= Units {
		Width := _TextCodepointWidth(Text, Position, Units)
		c := SubStr(Text, Position, Width)
		Position += Width
		CaptureCritical := Critical("On")
		try {
			if !KL_Roi_TextAllowed() || InputEpoch != KLRoiPrivacy.epoch
				return
			if (c != " " and c != "`t" and c != "`n" and c != "`r"
					and c != "." and c != "," and c != "!" and c != "?") {
				if KLRoi.word_overflowed
					continue
				; Bound UTF-16 storage before appending the entire codepoint.
				if StrLen(KLRoi.current_word) + Width > KLRoiConst.MAX_INPROGRESS_WORD_LEN {
					KLRoi.current_word := ""
					KLRoi.word_overflowed := true
					continue
				}
				KLRoi.current_word .= c
				continue
			}
			word := KLRoi.current_word
			KLRoi.current_word := ""
			overflowed := KLRoi.word_overflowed
			KLRoi.word_overflowed := false
		} finally Critical(CaptureCritical)
		if (overflowed)
			continue
		KL_Roi_ProcessWord(word, InputEpoch)
	}
}

; Special keys arrive through OnKeyDown rather than the character callback.
KL_Roi_OnKey(vk) {
	InputEpoch := KLRoiPrivacy.epoch
	if !KL_Roi_TextAllowed()
		return
	if !KL_Roi_RequireInit("KL_Roi_OnKey") || !KL_Roi_AdmitWordContext()
		return
	switch vk {
		case 0x08:
			; An overflow lost its prefix; backspacing cannot reconstruct it.
			CaptureCritical := Critical("On")
			try {
				if KL_Roi_TextAllowed() && InputEpoch == KLRoiPrivacy.epoch && !KLRoi.word_overflowed
					KLRoi.current_word := KLW_PopLast(KLRoi.current_word)
			} finally Critical(CaptureCritical)
		case 0x0D: KL_Roi_OnChar("`n", InputEpoch)
		case 0x09: KL_Roi_OnChar("`t", InputEpoch)
		case 0x1B, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x2E:
			CaptureCritical := Critical("On")
			try {
				if InputEpoch == KLRoiPrivacy.epoch
					KL_Roi_DiscardWord()
			} finally Critical(CaptureCritical)
	}
}

KL_Roi_ProcessWord(word, InputEpoch := unset) {
	InputEpoch := IsSet(InputEpoch) ? InputEpoch : KLRoiPrivacy.epoch
	if !KL_Roi_TextAllowed()
		return
		global _TriggerSet
		if (StrLen(word) < KLRoiConst.MIN_WORD_LEN)
				return
		key := StrLower(word)

		; Skip words that are already triggers
		if IsSet(_TriggerSet) && _TriggerSet.Has(key)
				return

		; Bump count in a short transaction so snapshot generations cannot observe
		; half of the read/modify/write pair.
		cnt := 0
		CaptureCritical := Critical("On")
		try {
			if !KL_Roi_TextAllowed() || InputEpoch != KLRoiPrivacy.epoch
				return
			map_size := KL_Roi_IncrementWordCount(KLRoi, key, &cnt)
		} finally Critical(CaptureCritical)

		; Emit candidate event on threshold crossing
		if (cnt = KLRoiConst.REPEAT_THRESHOLD) {
				KL_AppendLog(KL_Roi_CapturedEntry(Map(
						"type",        "new_trigger_candidate",
						"app",         Keystats.session_app,
						"word",        word,
						"occurrences", cnt
				), InputEpoch))
		}

		; Prune the tracking map when it grows too large. The prune is GUARANTEED
		; to bring the map strictly below MAX_TRACKED_WORDS (down to
		; PRUNE_TARGET_WORDS) so a saturated map cannot re-trigger this full scan on
		; every subsequent word boundary — keeping the guard amortised, not O(n)
		; per word once the cap is reached.
		if (map_size > KLRoiConst.MAX_TRACKED_WORDS)
				KL_Roi_PruneWordCounts()
}



; ===========================================
; ===== 4.1) Bounded tracking-map prune =====
; ===========================================

; Shrinks word_counts to PRUNE_TARGET_WORDS. Snapshot and publication are short
; Critical transactions; bounded frequency selection runs outside Critical so the
; keystroke thread stays serviceable. A generation mismatch retains the live Map
; and the next word boundary retries instead of overwriting a concurrent word.
KL_Roi_PruneWordCounts() {
		Started := HotPath_Now()
		Generation := 0
		Snapshot := KL_Roi_SnapshotWordCounts(KLRoi, &Generation)
		Operations := 0
		Published := true
		if (Snapshot.Count > KLRoiConst.PRUNE_TARGET_WORDS) {
				NextCounts := KL_Roi_SelectWordCountSurvivors(
						Snapshot, KLRoiConst.PRUNE_TARGET_WORDS, &Operations)
				Published := KL_Roi_TryPublishPrunedCounts(KLRoi, Generation, NextCounts)
		}
		Detail := Snapshot.Count . " entries, " . Operations . " bounded selection step(s), "
				. (Published ? "published" : "stale snapshot retained")
		HotPath_LogIfSlow("KL.RoiPrune", Started, Detail)
		return Published
}





; ==========================================
; ==========================================
; ======= 5/ Trigger half-life check =======
; ==========================================
; ==========================================

KL_Roi_HalflifeTick() {
	InputEpoch := KLRoiPrivacy.epoch
	if !KL_Roi_TextAllowed()
		return
	if !KL_Roi_RequireInit("KL_Roi_HalflifeTick")
		return
	; SetTimer bypasses Suspend — skip the iteration and KL_AppendLog call
	; while paused so the keystats emits nothing to disk during a pause session.
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
				if !KL_Roi_TextAllowed() || InputEpoch != KLRoiPrivacy.epoch
						return
				snapshot := Map()
				for trig, last_tick in KLRoi.trigger_last_use
						snapshot[trig] := last_tick
		} finally {
				Critical(previous_critical)
		}

		for trig, last_tick in snapshot {
				if InputEpoch != KLRoiPrivacy.epoch || !KL_Roi_TextAllowed()
						return
				; A_TickCount and retained fire ticks share the native64 domain.
				; A fire may arrive after this frame sampled now but before its map
				; snapshot: leave that newer observation for a subsequent timer.
				if !(last_tick is Integer) || last_tick < 0 || last_tick > now
						continue
				age := TickElapsed64(last_tick, now)
				if (age >= threshold) {
						KL_AppendLog(KL_Roi_CapturedEntry(Map(
								"type",    "trigger_halflife",
								"app",     Keystats.session_app,
								"trigger", trig,
								"days_since_use", Round(age / 86400000, 1)
						), InputEpoch))
				}
		}
}





; ============================
; ============================
; ======= 6/ Lifecycle =======
; ============================
; ============================

KL_Roi_Start(TimerFn := SetTimer) {
		return KL_TimerGroupStart(KLRoi, [
				Map("property", "halflife_fn",
						"callback", KL_Roi_HalflifeTick.Bind(),
						"period", KLRoiConst.HALFLIFE_CHECK_MS)
		], TimerFn, "trigger ROI")
}

KL_Roi_Stop(TimerFn := SetTimer) {
		TimersStopped := KL_TimerGroupStop(KLRoi,
				["halflife_fn"], TimerFn, "trigger ROI")
		; Final ROI snapshot on shutdown so the last session's savings are persisted
		if (KLRoi.session_fired_count > 0) {
				try KL_AppendLog(Map(
						"type",          "roi_snapshot",
						"app",           Keystats.session_app,
						"session_saved", KLRoi.session_saved_chars,
						"session_fired", KLRoi.session_fired_count
				))
		}
		return TimersStopped
}
