; modules/keylogger/keylogger_walker_events.ahk

; ==============================================================================
; MODULE: Keylogger Aggregation Walker — Event walkers
; DESCRIPTION:
; The two event-walking sections: the typing entry walker (the hot inner loop
; that processes per-keystroke events and populates every n-gram and metric
; bucket) and the non-typing event aggregators (app switch, window switch,
; system events). Extracted from keylogger_walker.ahk so the hot path can be
; read and maintained independently from infrastructure (core/sql sub-modules).
;
; FEATURES & RATIONALE:
; 1. KLW_WalkTypingEntry: mirrors Lua _walk_typing_entry byte-for-byte.
;    Called for every events_typing JSON row; accumulates into KLW.batch via
;    helpers from keylogger_walker_core.ahk (all globals, hoisted by AHK).
; 2. KLW_BumpInputBuckets: helper for hotstring/LLM backspace attribution,
;    kept in this file because it is only called from KLW_WalkTypingEntry.
; 3. KLW_WalkAppSwitch / KLW_WalkWindowSwitch / KLW_WalkSystemEvent: non-typing
;    event handlers; much simpler than the typing walker but same batch pattern.
; ==============================================================================





; ================================
; ================================
; ======= 1/ Typing walker =======
; ================================
; ================================

; Add one canonical shortcut event to the same n-gram state used by legacy
; typing payloads that carry meta.sc. Dedicated events_shortcut rows bypass the
; typing buffer, so both live callers and cold replay enter through this helper.
KLW_WalkShortcut(entry) {
		if !(entry is Map)
				return false
		shortcut_key := KLW_GetMap(entry, "key", "")
		if (Type(shortcut_key) != "String" || shortcut_key = "")
				return false
		app := KLW_GetMap(entry, "app", "Unknown")
		ts := KLW_GetMap(entry, "timestamp", "")
		date_str := (ts != "") ? SubStr(ts, 1, 10) : KL_Today()
		app_day_key := date_str . Chr(1) . app
		ctx := KLW_GetAppCtx(app)
		prev_sc := ctx["prev_sc"]
		sc_tbl := KLW.batch["sc_ngram"]["ngram_shortcuts"]
		scbg_tbl := KLW.batch["sc_ngram"]["ngram_shortcut_bigrams"]
		sk := app_day_key . Chr(1) . shortcut_key
		if !sc_tbl.Has(sk)
				sc_tbl[sk] := Map("date", date_str, "app", app,
						"token", shortcut_key, "count", 0)
		sc_tbl[sk]["count"] += 1
		if (prev_sc != "") {
				bgt := prev_sc . "→" . shortcut_key
				bk := app_day_key . Chr(1) . bgt
				if !scbg_tbl.Has(bk)
						scbg_tbl[bk] := Map("date", date_str, "app", app,
								"token", bgt, "count", 0)
				scbg_tbl[bk]["count"] += 1
		}
		ctx["prev_sc"] := shortcut_key
		return true
}

; Replays a typing entry and pushes every metric into KLW.batch.
; Mirrors the Lua _walk_typing_entry() byte-for-byte.
_KLW_ResolveTypingTime(Timestamp, NowInstant := unset) {
		TimestampText := Type(Timestamp) == "String" ? Timestamp : ""
		Instant := IsSet(NowInstant) ? NowInstant : A_Now
		HasTimestamp := TimestampText != ""
		DateStr := HasTimestamp ? SubStr(TimestampText, 1, 10)
				: FormatTime(Instant, "yyyy-MM-dd")
		Hour := HasTimestamp ? SubStr(TimestampText, 12, 2)
				: FormatTime(Instant, "HH")
		MinuteText := HasTimestamp ? SubStr(TimestampText, 15, 2)
				: FormatTime(Instant, "mm")
		if (Hour == "")
				Hour := FormatTime(Instant, "HH")
		if (MinuteText == "")
				MinuteText := FormatTime(Instant, "mm")

		; Match the cross-driver replay policy: malformed minutes use slot zero.
		Minute := 0
		try Minute := Integer(MinuteText)
		Minute5 := Floor(Minute / 5) * 5
		return Map(
				"date", DateStr,
				"hour", Hour,
				"min5", Hour . ":" . Format("{:02d}", Minute5))
}

KLW_WalkTypingEntry(entry) {
		if !(entry is Map)
				return
		app      := KLW_GetMap(entry, "app", "Unknown")
		ts       := KLW_GetMap(entry, "timestamp", "")
		TimeBucket := _KLW_ResolveTypingTime(ts)
		date_str := TimeBucket["date"]
		events   := KLW_GetMap(entry, "events", "")
		if !(events is Array)
				return

		ctx := KLW_GetAppCtx(app)
		p1 := ctx["p1"], p2 := ctx["p2"], p3 := ctx["p3"]
		p4 := ctx["p4"], p5 := ctx["p5"], p6 := ctx["p6"]
		cur_word  := ctx["cur_word"]
		word_err  := ctx["word_err"]
		backtrack := ctx["hist"]
		prev_word := ctx["prev_word"]
		prev_sc   := ctx["prev_sc"]
		prev_synth_type := "none"

		; Hour / 5-min slot from the same resolved instant as the date.
		current_hour := TimeBucket["hour"]
		current_min5 := TimeBucket["min5"]

		app_day_key := date_str . Chr(1) . app
		hourly_key  := app_day_key . Chr(1) . current_hour
		min5_key    := app_day_key . Chr(1) . current_min5
		app_category := KLW_GetMap(entry, "app_category", "")
		if (app_category != "") {
				if !KLW.batch["app_day"].Has(app_day_key)
						KLW.batch["app_day"][app_day_key] := Map(
								"date", date_str, "app", app)
				KLW.batch["app_day"][app_day_key]["category"] := app_category
		}

		if !KLW.batch["hourly"].Has(hourly_key) {
				KLW.batch["hourly"][hourly_key] := Map(
						"date", date_str, "app", app, "hour", current_hour,
						"c", 0, "e", 0, "em", 0, "es", 0, "e_buckets", Map()
				)
		}
		hr := KLW.batch["hourly"][hourly_key]

		if !KLW.batch["hourly_min5"].Has(min5_key) {
				KLW.batch["hourly_min5"][min5_key] := Map(
						"date", date_str, "app", app, "slot", current_min5,
						"c", 0, "e", 0, "es", 0, "e_buckets", Map()
				)
		}
		m5 := KLW.batch["hourly_min5"][min5_key]

		if !KLW.batch["chars_class"].Has(app_day_key) {
				KLW.batch["chars_class"][app_day_key] := Map(
						"date", date_str, "app", app,
						"letter", 0, "digit", 0, "punct", 0, "space", 0, "other", 0
				)
		}
		cc := KLW.batch["chars_class"][app_day_key]

		if !KLW.batch["errors"].Has(app_day_key) {
				KLW.batch["errors"][app_day_key] := Map(
						"date", date_str, "app", app,
						"bs_total", 0, "cascade_count", 0, "cascade_max_len", 0,
						"recovery_sum_ms", 0, "recovery_count", 0
				)
		}
		er := KLW.batch["errors"][app_day_key]

		if !KLW.batch["ergo"].Has(app_day_key) {
				KLW.batch["ergo"][app_day_key] := Map(
						"date", date_str, "app", app,
						"same_finger_streak_max", 0, "same_hand_streak_max", 0,
						"auto_repeat_count", 0
				)
		}
		eg := KLW.batch["ergo"][app_day_key]

		; Layout tag.
		layout := KLW_GetMap(entry, "layout", "")
		if (layout != "") {
				lk := app_day_key . Chr(1) . layout
				if !KLW.batch["layouts"].Has(lk)
						KLW.batch["layouts"][lk] := Map("date", date_str, "app", app,
								"layout", layout, "count", 0)
				KLW.batch["layouts"][lk]["count"] += 1
		}

		; Window-title tag (count bump; ms credited via window_switch).
		title := KLW_GetMap(entry, "title", "")
		if (title != "") {
				tk := app_day_key . Chr(1) . title
				if !KLW.batch["titles"].Has(tk)
						KLW.batch["titles"][tk] := Map("date", date_str, "app", app,
								"title", title, "c", 0, "ms", 0)
				KLW.batch["titles"][tk]["c"] += 1
		}

		for _, ev in events {
				; ev = [char, delay_ms, meta?]
				if !(ev is Array) || ev.Length < 2
						continue
				char     := ev[1]
				delay    := ev[2]
				meta     := (ev.Length >= 3 && ev[3] is Map) ? ev[3] : Map()
				shortcut_key := KLW_GetMap(meta, "sc", "")
				is_backspace := (char = "[BS]")
				synth_type   := KLW_GetMap(meta, "st", "none")
				is_synthetic := KLW_GetMap(meta, "s", false) ? true : false

				if (shortcut_key != "") {
						; Shortcuts: indexed separately, no n-gram chain participation.
						sc_tbl   := KLW.batch["sc_ngram"]["ngram_shortcuts"]
						scbg_tbl := KLW.batch["sc_ngram"]["ngram_shortcut_bigrams"]
						sk := app_day_key . Chr(1) . shortcut_key
						if !sc_tbl.Has(sk)
								sc_tbl[sk] := Map("date", date_str, "app", app,
										"token", shortcut_key, "count", 0)
						sc_tbl[sk]["count"] += 1
						if (prev_sc != "") {
								bgt := prev_sc . "→" . shortcut_key
								bk := app_day_key . Chr(1) . bgt
								if !scbg_tbl.Has(bk)
										scbg_tbl[bk] := Map("date", date_str, "app", app,
												"token", bgt, "count", 0)
								scbg_tbl[bk]["count"] += 1
						}
						prev_sc := shortcut_key
				} else {
						; Long pause breaks N-gram continuity.
						if (delay >= KLWConst.MAX_KEYSTROKE_DELAY_MS && !is_synthetic) {
								p1 := "", p2 := "", p3 := "", p4 := "", p5 := "", p6 := ""
								backtrack := []
								if (StrLen(cur_word) > 0) {
										if (prev_word != "")
												KLW_PushNgram("ngram_word_bigrams", date_str, app,
														prev_word . " " . cur_word, 0, word_err, "none")
										KLW_PushNgram("ngram_words", date_str, app,
												cur_word, 0, word_err, "none")
								}
								cur_word := "", word_err := false, prev_word := "", prev_sc := ""
						}

						; Count synth triggers once per burst.
						if (is_synthetic && synth_type != "none" && synth_type != prev_synth_type) {
								if (synth_type = "hotstring")
										KLW_BumpAppDay(date_str, app, "hs_triggers", 1)
								else if (synth_type = "llm")
										KLW_BumpAppDay(date_str, app, "llm_triggers", 1)
						}
						prev_synth_type := is_synthetic ? synth_type : "none"

						if is_backspace {
								if (backtrack.Length > 0) {
										last_entry := backtrack.Pop()
										if (KLW_GetMap(last_entry, "c", "") != "[BS]") {
												if last_entry.Has("c")  && last_entry["c"]  != ""
														KLW_PushNgram("ngram_chars",      date_str, app, last_entry["c"],  0, true, synth_type)
												if last_entry.Has("bg") && last_entry["bg"] != ""
														KLW_PushNgram("ngram_bigrams",    date_str, app, last_entry["bg"], 0, true, synth_type)
												if last_entry.Has("tg") && last_entry["tg"] != ""
														KLW_PushNgram("ngram_trigrams", date_str, app, last_entry["tg"], 0, true, synth_type)
												if last_entry.Has("qg") && last_entry["qg"] != ""
														KLW_PushNgram("ngram_quadgrams", date_str, app, last_entry["qg"], 0, true, synth_type)
												if last_entry.Has("pg") && last_entry["pg"] != ""
														KLW_PushNgram("ngram_pentagrams", date_str, app, last_entry["pg"], 0, true, synth_type)
												if last_entry.Has("hx") && last_entry["hx"] != ""
														KLW_PushNgram("ngram_hexagrams", date_str, app, last_entry["hx"], 0, true, synth_type)
												if last_entry.Has("hp") && last_entry["hp"] != ""
														KLW_PushNgram("ngram_heptagrams", date_str, app, last_entry["hp"], 0, true, synth_type)
										}
								}
								cur_word := KLW_PopLast(cur_word)
								word_err := true

								if is_synthetic {
										hr["es"] += 1
										m5["es"] += 1
										trigger_evt := ""
										if (ctx["recent_typing"].Length > 0)
												trigger_evt := ctx["recent_typing"].Pop()
										if (synth_type = "hotstring") {
												; hs_chars is gross generated output. The UI subtracts
												; hs_input_chars once, so decreasing both double-counts
												; each deleted trigger character in live projections.
												KLW_BumpAppDay(date_str, app, "hs_input_chars", 1)
												if (trigger_evt is Map)
														KLW_BumpInputBuckets(date_str, app, trigger_evt["delay"], "hs", app_day_key)
										} else if (synth_type = "llm") {
												; Keep the gross-output contract aligned with macOS,
												; Linux and the Windows events_* database rebuild.
												KLW_BumpAppDay(date_str, app, "llm_input_chars", 1)
												if (trigger_evt is Map)
														KLW_BumpInputBuckets(date_str, app, trigger_evt["delay"], "llm", app_day_key)
										}
								} else {
										hr["e"] += 1
										hr["em"] += 1
										m5["e"] += 1
										KLW_BumpAppDay(date_str, app, "chars", 1)
										if (delay > KLWConst.THINK_PAUSE_MS) {
												KLW_BumpAppDay(date_str, app, "think_time_ms", delay)
												KLW_BumpAppDay(date_str, app, "pauses", 1)
										} else {
												KLW_BumpAppDay(date_str, app, "time_ms", delay)
										}
										KLW_BucketAdd(hr["e_buckets"], delay, 1)
										KLW_BucketAdd(m5["e_buckets"], delay, 1)
										if (ctx["recent_typing"].Length > 0)
												ctx["recent_typing"].Pop()
										ctx["bs_run_len"] += 1
										ctx["last_was_bs"] := true
										er["bs_total"] += 1
										ctx["last_finger"] := ""
										ctx["same_finger_run"] := 0
										ctx["same_hand_run"] := 0
										ctx["last_char"] := ""
								}

								bs_entry := Map()
								KLW_PushNgram("ngram_chars", date_str, app, "[BS]", delay, false, synth_type)
								bs_entry["c"] := "[BS]"
								if (p1 != "") {
										KLW_PushNgram("ngram_bigrams",  date_str, app, p1 . "[BS]", delay, false, synth_type)
										bs_entry["bg"] := p1 . "[BS]"
								}
								if (p2 != "") {
										KLW_PushNgram("ngram_trigrams", date_str, app, p2 . p1 . "[BS]", delay, false, synth_type)
										bs_entry["tg"] := p2 . p1 . "[BS]"
								}
								backtrack.Push(bs_entry)
								if (backtrack.Length > KLWConst.HIST_CAP)
										backtrack.RemoveAt(1)
								p6 := p5, p5 := p4, p4 := p3, p3 := p2, p2 := p1, p1 := "[BS]"
						} else {
								k_c  := char
								k_bg := (p1 != "") ? p1 . k_c : ""
								k_tg := (p2 != "") ? p2 . p1 . k_c : ""
								k_qg := (p3 != "") ? p3 . p2 . p1 . k_c : ""
								k_pg := (p4 != "") ? p4 . p3 . p2 . p1 . k_c : ""
								k_hx := (p5 != "") ? p5 . p4 . p3 . p2 . p1 . k_c : ""
								k_hp := (p6 != "") ? p6 . p5 . p4 . p3 . p2 . p1 . k_c : ""

								ngram_delay := (delay < KLWConst.MAX_KEYSTROKE_DELAY_MS) ? delay : 0

								entry_marks := Map()
								; A long pause breaks n-gram continuity, but it never erases the
								; physical character or its raw timing from the other aggregates.
								KLW_PushNgram("ngram_chars", date_str, app, k_c, ngram_delay, false, synth_type)
								entry_marks["c"] := k_c
								if (k_bg != "") {
										KLW_PushNgram("ngram_bigrams",    date_str, app, k_bg, ngram_delay, false, synth_type)
										entry_marks["bg"] := k_bg
								}
								if (k_tg != "") {
										KLW_PushNgram("ngram_trigrams",   date_str, app, k_tg, ngram_delay, false, synth_type)
										entry_marks["tg"] := k_tg
								}
								if (k_qg != "") {
										KLW_PushNgram("ngram_quadgrams",  date_str, app, k_qg, ngram_delay, false, synth_type)
										entry_marks["qg"] := k_qg
								}
								if (k_pg != "") {
										KLW_PushNgram("ngram_pentagrams", date_str, app, k_pg, ngram_delay, false, synth_type)
										entry_marks["pg"] := k_pg
								}
								if (k_hx != "") {
										KLW_PushNgram("ngram_hexagrams",  date_str, app, k_hx, ngram_delay, false, synth_type)
										entry_marks["hx"] := k_hx
								}
								if (k_hp != "") {
										KLW_PushNgram("ngram_heptagrams", date_str, app, k_hp, ngram_delay, false, synth_type)
										entry_marks["hp"] := k_hp
								}

								if !is_synthetic {
										KLW_BumpAppDay(date_str, app, "chars", 1)
										hr["c"] += 1
										m5["c"] += 1
										if (delay > KLWConst.THINK_PAUSE_MS) {
												KLW_BumpAppDay(date_str, app, "think_time_ms", delay)
												KLW_BumpAppDay(date_str, app, "pauses", 1)
										} else {
												KLW_BumpAppDay(date_str, app, "time_ms", delay)
										}
										; time / credited buckets.
										for _, bucketMs in KLWConst.UI_PAUSE_BUCKETS_MS {
												if (delay <= bucketMs) {
														bkey := app_day_key . Chr(1) . String(bucketMs)
														if !KLW.batch["app_buckets"].Has(bkey) {
																KLW.batch["app_buckets"][bkey] := Map(
																		"date", date_str, "app", app, "bucket_ms", bucketMs,
																		"time_sum", 0, "credited", 0,
																		"hs_in_t", 0, "hs_in_c", 0,
																		"llm_in_t", 0, "llm_in_c", 0
																)
														}
														row := KLW.batch["app_buckets"][bkey]
														row["time_sum"] += delay
														row["credited"] += 1
												}
										}
										ctx["recent_typing"].Push(Map("delay", delay))
										if (ctx["recent_typing"].Length > KLWConst.TRIGGER_LOOKBACK_LEN)
												ctx["recent_typing"].RemoveAt(1)

										; Burst tracking.
										if !ctx.Has("current_burst") || delay > KLWConst.BURST_GAP_MS {
												if ctx.Has("current_burst")
														KLW_FinalizeBurst(date_str, app, ctx["current_burst"])
												ctx["current_burst"] := Map(
														"char_count", 1, "sum_delays", 0,
														"sum_delays_sq", 0, "max_delay", 0)
										} else {
												b := ctx["current_burst"]
												b["char_count"]    += 1
												b["sum_delays"]    += delay
												b["sum_delays_sq"] += delay * delay
												if (delay > b["max_delay"])
														b["max_delay"] := delay
										}

										; Session tracking.
										if !ctx.Has("current_session") || delay > KLWConst.SESSION_GAP_MS {
												if ctx.Has("current_session")
														KLW_FinalizeSession(date_str, app, ctx["current_session"])
												ctx["current_session"] := Map("char_count", 1, "total_ms", 0)
										} else {
												s := ctx["current_session"]
												s["char_count"] += 1
												s["total_ms"]   += delay
										}

										; Cascade close + recovery.
										if ctx["last_was_bs"] {
												if (ctx["bs_run_len"] >= KLWConst.CASCADE_MIN_BS) {
														er["cascade_count"] += 1
														if (ctx["bs_run_len"] > er["cascade_max_len"])
																er["cascade_max_len"] := ctx["bs_run_len"]
												}
												if (delay <= KLWConst.MAX_KEYSTROKE_DELAY_MS) {
														er["recovery_sum_ms"] += delay
														er["recovery_count"]  += 1
												}
												ctx["bs_run_len"] := 0
												ctx["last_was_bs"] := false
										}

										; Same-finger / same-hand streaks.
										kc_num := KLW_GetMap(meta, "kc", "")
										cur_finger := ""
										if (kc_num != "" && IsNumber(kc_num) && KLW_VK_FINGER.Has(kc_num))
												cur_finger := KLW_VK_FINGER[kc_num]
										if (cur_finger != "") {
												if (ctx["last_finger"] = cur_finger)
														ctx["same_finger_run"] += 1
												else
														ctx["same_finger_run"] := 1
												if (ctx["same_finger_run"] > eg["same_finger_streak_max"])
														eg["same_finger_streak_max"] := ctx["same_finger_run"]
												cur_hand  := SubStr(cur_finger, 1, 1)
												last_hand := (ctx["last_finger"] != "") ? SubStr(ctx["last_finger"], 1, 1) : ""
												if (last_hand = cur_hand)
														ctx["same_hand_run"] += 1
												else
														ctx["same_hand_run"] := 1
												if (ctx["same_hand_run"] > eg["same_hand_streak_max"])
														eg["same_hand_streak_max"] := ctx["same_hand_run"]
												ctx["last_finger"] := cur_finger
										} else {
												ctx["last_finger"] := ""
												ctx["same_finger_run"] := 0
												ctx["same_hand_run"] := 0
										}

										; Auto-repeat.
										if (ctx["last_char"] = k_c && delay > 0
														&& delay <= KLWConst.AUTO_REPEAT_MAX_DELAY_MS)
												eg["auto_repeat_count"] += 1
										ctx["last_char"] := k_c

										; Char class.
										cls := KLW_CharClass(k_c)
										if (cls = "letter") {
												cc["letter"] += 1
										} else if (cls = "digit") {
												cc["digit"] += 1
										} else if (cls = "punct") {
												cc["punct"] += 1
										} else if (cls = "space") {
												cc["space"] += 1
										} else {
												cc["other"] += 1
										}

										if !cc.Has("first_typed_min") || cc["first_typed_min"] = ""
												cc["first_typed_min"] := current_min5
										cc["last_typed_min"] := current_min5
								} else {
										if (synth_type = "hotstring")
												KLW_BumpAppDay(date_str, app, "hs_chars", 1)
										else if (synth_type = "llm")
												KLW_BumpAppDay(date_str, app, "llm_chars", 1)
								}

								; Word boundary detection.
								is_separator := false
								if (StrLen(k_c) > 0) {
										if RegExMatch(k_c, '[\s.,!?;:"' . "'" . '()%{}\[\]<>=+*/\\|\-]')
												is_separator := true
										else if (k_c = "`n" || k_c = Chr(0xA0) || k_c = Chr(0x202F))
												is_separator := true
								}
								if is_separator {
										if (StrLen(cur_word) > 0) {
												if (prev_word != "")
														KLW_PushNgram("ngram_word_bigrams", date_str, app,
																prev_word . " " . cur_word, 0, word_err, "none")
												KLW_PushNgram("ngram_words", date_str, app,
														cur_word, 0, word_err, "none")
												prev_word := cur_word
												cur_word := ""
												word_err := false
										}
								} else {
										cur_word .= k_c
								}
								backtrack.Push(entry_marks)
								if (backtrack.Length > KLWConst.HIST_CAP)
										backtrack.RemoveAt(1)
								p6 := p5, p5 := p4, p4 := p3, p3 := p2, p2 := p1, p1 := k_c
						}
				}

				; Physical keycode + scancode tally (non-synthetic only).
				if !is_synthetic {
						kc := KLW_GetMap(meta, "kc", "")
						if (kc != "" && IsNumber(kc)) {
								kk := app_day_key . Chr(1) . String(kc)
								if !KLW.batch["kc_ngram"].Has(kk)
										KLW.batch["kc_ngram"][kk] := Map("date", date_str, "app", app,
												"keycode", Integer(kc), "count", 0)
								KLW.batch["kc_ngram"][kk]["count"] += 1
						}
						; ``sk`` is the hardware scancode (set by the AHK input hook).
						; The walker's ``sc`` meta slot is already taken by shortcut keys,
						; so we use a distinct identifier here.
						sk_code := KLW_GetMap(meta, "sk", "")
						if (sk_code != "" && IsNumber(sk_code)) {
								skey := app_day_key . Chr(1) . String(sk_code)
								if !KLW.batch["sc_kb_ngram"].Has(skey)
										KLW.batch["sc_kb_ngram"][skey] := Map("date", date_str, "app", app,
												"scancode", Integer(sk_code), "count", 0)
								KLW.batch["sc_kb_ngram"][skey]["count"] += 1
						}
				}
		}

		; Persist context for next tick.
		ctx["p1"] := p1, ctx["p2"] := p2, ctx["p3"] := p3
		ctx["p4"] := p4, ctx["p5"] := p5, ctx["p6"] := p6
		ctx["cur_word"]  := cur_word
		ctx["word_err"]  := word_err
		ctx["hist"]      := backtrack
		ctx["prev_word"] := prev_word
		ctx["prev_sc"]   := prev_sc
}

KLW_BumpInputBuckets(date_str, app, trigger_delay, kind, app_day_key) {
		for _, bucketMs in KLWConst.UI_PAUSE_BUCKETS_MS {
				if (trigger_delay <= bucketMs) {
						bkey := app_day_key . Chr(1) . String(bucketMs)
						if !KLW.batch["app_buckets"].Has(bkey) {
								KLW.batch["app_buckets"][bkey] := Map(
										"date", date_str, "app", app, "bucket_ms", bucketMs,
										"time_sum", 0, "credited", 0,
										"hs_in_t", 0, "hs_in_c", 0,
										"llm_in_t", 0, "llm_in_c", 0
								)
						}
						row := KLW.batch["app_buckets"][bkey]
						if (kind = "hs") {
								row["hs_in_t"] += trigger_delay
								row["hs_in_c"] += 1
						} else {
								row["llm_in_t"] += trigger_delay
								row["llm_in_c"] += 1
						}
				}
		}
}





; ===========================================
; ===== 2/ Non-typing event aggregation =====
; ===========================================

KLW_WalkAppSwitch(entry) {
		prev_app := KLW_GetMap(entry, "prev_app", "")
		if (prev_app = "")
				return
		ts := KLW_GetMap(entry, "timestamp", "")
		date_str := (ts != "") ? SubStr(ts, 1, 10) : KL_Today()
		duration := KLW_GetMap(entry, "duration_ms", 0)

		key := date_str . Chr(1) . prev_app
		if !KLW.batch["app_time"].Has(key)
				KLW.batch["app_time"][key] := Map("date", date_str, "app", prev_app, "ms", 0)
		KLW.batch["app_time"][key]["ms"] += duration

		next_app := KLW_GetMap(entry, "next_app", "")
		if (next_app != "") {
				sk := date_str . Chr(1) . prev_app . Chr(1) . next_app
				if !KLW.batch["switches_to"].Has(sk)
						KLW.batch["switches_to"][sk] := Map("date", date_str,
								"app_from", prev_app, "app_to", next_app, "count", 0)
				KLW.batch["switches_to"][sk]["count"] += 1
		}
}

KLW_WalkWindowSwitch(entry) {
		prev_title := KLW_GetMap(entry, "prev_title", "")
		if (prev_title = "")
				return
		ts := KLW_GetMap(entry, "timestamp", "")
		date_str := (ts != "") ? SubStr(ts, 1, 10) : KL_Today()
		app := KLW_GetMap(entry, "app", "Unknown")
		duration := KLW_GetMap(entry, "duration_ms", 0)
		tk := date_str . Chr(1) . app . Chr(1) . prev_title
		if !KLW.batch["titles"].Has(tk)
				KLW.batch["titles"][tk] := Map("date", date_str, "app", app,
						"title", prev_title, "c", 0, "ms", 0)
		KLW.batch["titles"][tk]["ms"] += duration
}

KLW_WalkSystemEvent(entry) {
		ts := KLW_GetMap(entry, "timestamp", "")
		date_str := (ts != "") ? SubStr(ts, 1, 10) : KL_Today()
		action := KLW_GetMap(entry, "action", "")

		if (action = "modifier_hold" || action = "karabiner_release") {
				kc := KLW_GetMap(entry, "keycode", "")
				if (kc != "" && IsNumber(kc)) {
						app := KLW_GetMap(entry, "app", "Unknown")
						hold := KLW_GetMap(entry, "hold_ms", 0)
						key := date_str . Chr(1) . app . Chr(1) . String(kc)
						if !KLW.batch["kc_hold"].Has(key)
								KLW.batch["kc_hold"][key] := Map(
										"date", date_str, "app", app, "keycode", Integer(kc),
										"sum_ms", 0, "count", 0, "max_ms", 0,
										"tap_count", 0, "hold_count", 0
								)
						r := KLW.batch["kc_hold"][key]
						r["sum_ms"] += hold
						r["count"]  += 1
						if (hold > r["max_ms"])
								r["max_ms"] := hold
						if (hold <= KLWConst.HOLD_THRESHOLD_MS)
								r["tap_count"] += 1
						else
								r["hold_count"] += 1
				}
		}

		if !KLW.batch["system_day"].Has(date_str) {
				KLW.batch["system_day"][date_str] := Map(
						"date", date_str, "wifi_changes", 0, "space_switches", 0,
						"audio_muted_ms", 0, "locked_ms", 0, "sleep_ms", 0, "awake_ms", 0,
						"passive_count", 0, "night_wake_count", 0
				)
		}
		s := KLW.batch["system_day"][date_str]
		if (action = "wifi_change") {
				s["wifi_changes"] += 1
		} else if (action = "space_change") {
				s["space_switches"] += 1
		} else if (action = "passive_period") {
				s["passive_count"] += 1
		} else if (action = "unlock") {
				s["locked_ms"] += KLW_GetMap(entry, "duration_ms", 0)
		} else if (action = "wake") {
				s["sleep_ms"] += KLW_GetMap(entry, "duration_ms", 0)
		}
}
