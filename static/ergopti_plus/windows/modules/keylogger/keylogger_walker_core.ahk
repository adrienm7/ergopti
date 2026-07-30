; modules/keylogger/keylogger_walker_core.ahk

; ==============================================================================
; MODULE: Keylogger Aggregation Walker — Core (constants, state, helpers)
; DESCRIPTION:
; Constants, timing loader, module-scoped state class, batch initialisation,
; per-keystroke helpers, and the burst/session finalizers. All of these must
; be in scope before keylogger_walker_events.ahk is parsed because AHK hoists
; functions but not global/class declarations.
;
; FEATURES & RATIONALE:
; 1. KLWConst: sentinel-initialised at parse time (timing values overwritten
;    at boot by KeyloggerWalkerLoadTimings so the registry is already loaded).
; 2. KLW class: static fields hold the per-app n-gram context (KLW.ctx) and
;    the per-tick batch accumulator (KLW.batch) — both shared across all walker
;    sub-modules via their global names.
; 3. KLW_ResetBatch / KLW_GC: batch lifecycle helpers used by the typing walker
;    and the flush stage.
; 4. KLW_AddNgramMetric / KLW_PushNgram / KLW_BumpAppDay: inner-loop helpers
;    called on every processed keystroke — kept tight and inline.
; ==============================================================================





; ============================
; ============================
; ======= 1/ Constants =======
; ============================
; ============================

; The six *_MS / *_GAP_MS timing thresholds below are sourced from the shared
; cross-driver registry (_shared/modules/timings/constants.toml [keylogger]) by
; KeyloggerWalkerLoadTimings(), called once at boot. They start at the sentinel
; 0 because AHK v2 runs static initializers BEFORE the auto-execute body, so the
; registry is not yet loaded here; reading one before the loader runs would be a
; boot-order bug, not a silent default. The non-timing fields (bucket arrays,
; counts, caps) are walker-specific and stay literal.
class KLWConst {
		static MAX_KEYSTROKE_DELAY_MS    := 0   ; <- keylogger.max_keystroke_delay_ms
		static THINK_PAUSE_MS            := 0   ; <- keylogger.think_pause_ms
		static UI_PAUSE_BUCKETS_MS       := [1000, 2000, 3000, 5000, 10000, 20000, 30000, 60000]
		static TRIGGER_LOOKBACK_LEN      := 50
		; Cap for ctx["hist"], the per-app backspace-attribution ring. Backspace
		; only ever pops the most recent entry, and the deepest n-gram read back is
		; the heptagram (7 chars), so 8 entries are always enough to attribute any
		; correction. Without this cap hist grows ~linearly with chars typed since
		; the last pause-break and is re-serialised into state.json every tick.
		static HIST_CAP                  := 8
		static BURST_GAP_MS              := 0   ; <- keylogger.burst_gap_ms
		static MIN_BURST_FOR_CPM         := 10
		static SESSION_GAP_MS            := 0   ; <- keylogger.session_gap_ms
		static BURST_LENGTH_BUCKETS      := [1, 5, 10, 20, 50, 100, 200, 500]
		static SESSION_DURATIONS_CAP     := 100
		static AUTO_REPEAT_MAX_DELAY_MS  := 0   ; <- keylogger.auto_repeat_max_delay_ms
		static CASCADE_MIN_BS            := 3
		static HOLD_THRESHOLD_MS         := 0   ; <- keylogger.hold_threshold_ms
		static TITLE_CAP_PER_APP_DAY     := 100
}

; Reassign the KLWConst timing thresholds from the shared registry. Called once
; from the auto-execute body at boot (after TimingsLoadShared(), before the
; keylogger hook is armed). Fail-fast: a missing key throws via TimingsGet.
KeyloggerWalkerLoadTimings() {
		KLWConst.MAX_KEYSTROKE_DELAY_MS   := TimingsGet("keylogger", "max_keystroke_delay_ms")
		KLWConst.THINK_PAUSE_MS           := TimingsGet("keylogger", "think_pause_ms")
		KLWConst.BURST_GAP_MS             := TimingsGet("keylogger", "burst_gap_ms")
		KLWConst.SESSION_GAP_MS           := TimingsGet("keylogger", "session_gap_ms")
		KLWConst.AUTO_REPEAT_MAX_DELAY_MS := TimingsGet("keylogger", "auto_repeat_max_delay_ms")
		KLWConst.HOLD_THRESHOLD_MS        := TimingsGet("keylogger", "hold_threshold_ms")
}

; QWERTY VK → finger column. Modifiers + thumb keys absent on purpose so
; they cannot break a streak when interleaved. Override via KLW_VK_FINGER
; before KL_Init() if your layout differs.
global KLW_VK_FINGER := Map(
		0x41, "l_pinky", 0x53, "l_ring", 0x44, "l_mid", 0x46, "l_idx", 0x47, "l_idx",   ; A S D F G
		0x48, "r_idx",   0x4A, "r_idx",  0x4B, "r_mid", 0x4C, "r_ring", 0xBA, "r_pinky", ; H J K L ;
		0x51, "l_pinky", 0x57, "l_ring", 0x45, "l_mid", 0x52, "l_idx", 0x54, "l_idx",   ; Q W E R T
		0x59, "r_idx",   0x55, "r_idx",  0x49, "r_mid", 0x4F, "r_ring", 0x50, "r_pinky", ; Y U I O P
		0x5A, "l_pinky", 0x58, "l_ring", 0x43, "l_mid", 0x56, "l_idx", 0x42, "l_idx",   ; Z X C V B
		0x4E, "r_idx",   0x4D, "r_idx",  0xBC, "r_mid", 0xBE, "r_ring", 0xBF, "r_pinky"  ; N M , . /
)





; ===============================
; ===============================
; ======= 2/ Module state =======
; ===============================
; ===============================

class KLW {
		; Per-app n-gram + burst + session walking context. Map(app => Map(...)).
		; Persisted in state.json under "ngram_ctx" key.
		static ctx := Map()

		; Per-tick batch dicts. Reset after KLW_BuildBatchSql() emits SQL.
		; Initialised to an empty Map so accessing it before the first
		; KLW_ResetBatch() does not throw — KLW_BuildBatchSql() short-circuits
		; when no sub-key is present.
		static batch := Map()
}





; ==========================================
; ==========================================
; ======= 3/ Batch reset / accessors =======
; ==========================================
; ==========================================

KLW_ResetBatch() {
		KLW.batch := Map(
				"app_day",     Map(),
				"app_time",    Map(),
				"app_buckets", Map(),
				"ngram",       Map(
						"ngram_chars",        Map(),
						"ngram_bigrams",      Map(),
						"ngram_trigrams",     Map(),
						"ngram_quadgrams",    Map(),
						"ngram_pentagrams",   Map(),
						"ngram_hexagrams",    Map(),
						"ngram_heptagrams",   Map(),
						"ngram_words",        Map(),
						"ngram_word_bigrams", Map()
				),
				"kc_ngram",    Map(),
				"sc_kb_ngram", Map(),
				"sc_ngram",    Map(
						"ngram_shortcuts",        Map(),
						"ngram_shortcut_bigrams", Map()
				),
				"kc_hold",     Map(),
				"titles",      Map(),
				"hourly",      Map(),
				"hourly_min5", Map(),
				"layouts",     Map(),
				"chars_class", Map(),
				"errors",      Map(),
				"ergo",        Map(),
				"bursts",      Map(),
				"sessions",    Map(),
				"switches_to", Map(),
				"system_day",  Map()
		)
}

; Get-or-create a sub-map at tbl[k], returning the populated default.
KLW_GC(tbl, k, default_map) {
		if !tbl.Has(k)
				tbl[k] := default_map
		return tbl[k]
}





; ==========================
; ==========================
; ======= 4/ Helpers =======
; ==========================
; ==========================

KLW_BucketAdd(target_map, delay, value) {
		for _, bucketMs in KLWConst.UI_PAUSE_BUCKETS_MS {
				if (delay <= bucketMs) {
						k := String(bucketMs)
						target_map[k] := (target_map.Has(k) ? target_map[k] : 0) + value
				}
		}
}

KLW_BurstLengthBucket(n) {
		for _, b in KLWConst.BURST_LENGTH_BUCKETS {
				if (n <= b)
						return String(b)
		}
		return "500+"
}

; UTF-8-aware character classifier — mirrors the Lua _char_class.
KLW_CharClass(c) {
		if (c = "" || StrLen(c) = 0)
				return "other"
		if (c = " " || c = "`t" || c = "`n"
						|| c = Chr(0xA0)         ; nbsp
						|| c = Chr(0x202F))      ; narrow nbsp
				return "space"
		code := Ord(c)
		if (code >= 48 && code <= 57)
				return "digit"
		if ((code >= 65 && code <= 90) || (code >= 97 && code <= 122))
				return "letter"
		; Latin Extended (BMP) — feeds the breakdown chart, accuracy non-critical.
		if (code >= 0xC0 && code <= 0x024F)
				return "letter"
		; Bracket markers like [BS], [TAB] from the keylogger pipeline.
		if (SubStr(c, 1, 1) = "[" && SubStr(c, -1) = "]")
				return "other"
		; Punctuation — coarse but matches the Lua %p pattern semantics.
		if RegExMatch(c, "^[[:punct:]<>=+*/\\|\-]$")
				return "punct"
		return "other"
}

; Pop the last UTF-16 code unit (AHK strings are UTF-16 internally).
KLW_PopLast(s) {
		if (s = "" || StrLen(s) = 0)
				return ""
		return SubStr(s, 1, StrLen(s) - 1)
}

; Get-or-create the per-app walking context.
KLW_GetAppCtx(app) {
		if !KLW.ctx.Has(app) {
				ctx := Map(
						"p1", "", "p2", "", "p3", "", "p4", "", "p5", "", "p6", "",
						"cur_word", "", "word_err", false, "hist", [],
						"prev_word", "", "prev_sc", "",
						"recent_typing", [],
						"bs_run_len", 0, "last_was_bs", false,
						"last_finger", "", "same_finger_run", 0, "same_hand_run", 0,
						"last_char", ""
				)
				; ``current_burst`` / ``current_session`` are added on demand below;
				; their *absence* from the Map signals "no burst / session in flight".
				KLW.ctx[app] := ctx
		}
		return KLW.ctx[app]
}

KLW_GetMap(m, k, default_val := "") {
		if (m is Map && m.Has(k))
				return m[k]
		return default_val
}

; Bump a metric in the n-gram batch dict. Mirrors `_add_ngram_metric` Lua.
KLW_AddNgramMetric(table_name, key, delay, is_error, synth_type) {
		if !KLW.batch["ngram"].Has(table_name)
				return
		tbl := KLW.batch["ngram"][table_name]
		if !tbl.Has(key)
				tbl[key] := Map("c", 0, "td", 0, "cd", 0, "e", 0, "esrc", Map())
		item := tbl[key]
		if is_error {
				item["e"] += 1
				if (synth_type != "" && synth_type != "none")
						item["esrc"][synth_type] := (item["esrc"].Has(synth_type) ? item["esrc"][synth_type] : 0) + 1
		} else {
				item["c"] += 1
				if (synth_type = "hotstring" || synth_type = "llm"
								|| (synth_type != "" && synth_type != "none"))
						item["esrc"][synth_type] := (item["esrc"].Has(synth_type) ? item["esrc"][synth_type] : 0) + 1
				else if (delay > 0) {
						item["td"] += delay
						item["cd"] += 1
				}
		}
}

KLW_PushNgram(table_name, date_str, app, token, delay, is_error, synth_type) {
		key := date_str . Chr(1) . app . Chr(1) . token
		KLW_AddNgramMetric(table_name, key, delay, is_error, synth_type)
}

; Bump a per-app-day numeric counter on KLW.batch["app_day"].
KLW_BumpAppDay(date_str, app, field, value) {
		key := date_str . Chr(1) . app
		if !KLW.batch["app_day"].Has(key)
				KLW.batch["app_day"][key] := Map("date", date_str, "app", app)
		row := KLW.batch["app_day"][key]
		row[field] := (row.Has(field) ? row[field] : 0) + value
}





; ==================================
; ==================================
; ======= 5/ Burst / Session =======
; ==================================
; ==================================

KLW_FinalizeBurst(date_str, app, b) {
		if !(b is Map) || b["char_count"] <= 0
				return
		key := date_str . Chr(1) . app
		if !KLW.batch["bursts"].Has(key) {
				KLW.batch["bursts"][key] := Map(
						"date", date_str, "app", app,
						"count_total", 0, "max_cpm", 0.0, "max_chars", 0,
						"length_buckets", Map(),
						"inter_count", 0, "inter_sum", 0, "inter_sumsq", 0
				)
		}
		r := KLW.batch["bursts"][key]
		r["count_total"] += 1
		if (b["char_count"] > r["max_chars"])
				r["max_chars"] := b["char_count"]
		if (b["char_count"] >= KLWConst.MIN_BURST_FOR_CPM && b["sum_delays"] > 0) {
				cpm := b["char_count"] * 60000 / b["sum_delays"]
				if (cpm > r["max_cpm"])
						r["max_cpm"] := cpm
		}
		bk := KLW_BurstLengthBucket(b["char_count"])
		r["length_buckets"][bk] := (r["length_buckets"].Has(bk) ? r["length_buckets"][bk] : 0) + 1
		delta := b["char_count"] - 1
		if (delta < 0)
				delta := 0
		r["inter_count"] += delta
		r["inter_sum"]   += b["sum_delays"]
		r["inter_sumsq"] += b["sum_delays_sq"]
}

KLW_FinalizeSession(date_str, app, s) {
		if !(s is Map) || s["char_count"] <= 0
				return
		key := date_str . Chr(1) . app
		if !KLW.batch["sessions"].Has(key) {
				KLW.batch["sessions"][key] := Map(
						"date", date_str, "app", app,
						"count_total", 0, "longest_ms", 0, "longest_chars", 0,
						"total_active_ms", 0, "durations", []
				)
		}
		r := KLW.batch["sessions"][key]
		r["count_total"] += 1
		if (s["total_ms"] > r["longest_ms"])
				r["longest_ms"] := s["total_ms"]
		if (s["char_count"] > r["longest_chars"])
				r["longest_chars"] := s["char_count"]
		r["total_active_ms"] += s["total_ms"]
		if (r["durations"].Length < KLWConst.SESSION_DURATIONS_CAP)
				r["durations"].Push(s["total_ms"])
}
