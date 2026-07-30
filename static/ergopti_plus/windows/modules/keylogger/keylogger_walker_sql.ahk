; modules/keylogger/keylogger_walker_sql.ahk

; ==============================================================================
; MODULE: Keylogger Aggregation Walker — SQL emission and context persistence
; DESCRIPTION:
; SQL escaping helpers, batch flush (KLW_BuildBatchSql), and the walking
; context persistence helpers (serialise / restore / day-rollover reset).
; Extracted from keylogger_walker.ahk so the SQL layer can be read and maintained
; independently from the inner-loop walking code.
;
; FEATURES & RATIONALE:
; 1. KLW_SqlEscape / KLW_JsonEscape / KLW_EsrcMergeExpr / KLW_SplitKey:
;    SQL-formatting helpers used exclusively by KLW_BuildBatchSql.
; 2. KLW_BuildBatchSql: drains KLW.batch into one SQL string (all tables in one
;    pass) and returns it to the caller so it can be appended to data.sql in
;    the same write as the raw event INSERTs — a single fsync.
; 3. KLW_SerializeCtx / KLW_RestoreCtx / KLW_DayRolloverReset: context
;    lifecycle helpers called by the log manager at startup, on successful
;    flush, and at day rollover respectively.
; ==============================================================================





; =======================================
; =======================================
; ======= 1/ SQL emission helpers =======
; =======================================
; =======================================

KLW_SqlEscape(s) {
		return "'" . StrReplace(String(s), "'", "''") . "'"
}

KLW_JsonEscape(m) {
		return KLW_SqlEscape(KL_JsonEncode(m))
}

; Build a SQLite expression that merges the incoming esrc_json INTO the stored
; esrc_json by summing each key present in the batch item.  A plain column
; assignment would clobber all prior counts accumulated across flush cycles;
; this instead keeps a running sum per source type.
KLW_EsrcMergeExpr(EsrcMap) {
		if (!IsObject(EsrcMap) || EsrcMap.Count == 0)
				return "COALESCE(esrc_json,'{}') "
		Expr := "json_set(COALESCE(esrc_json,'{}') "
		for k, _ in EsrcMap {
				SafeKey := StrReplace(StrReplace(k, "\", "\\"), "'", "''")
				Expr .= ",'" . "$." . SafeKey . "',COALESCE(json_extract(esrc_json,'$." . SafeKey . "'),0)+COALESCE(json_extract(excluded.esrc_json,'$." . SafeKey . "'),0) "
		}
		Expr .= ")"
		return Expr
}

; Split a Chr(1)-delimited composite key into N parts.
KLW_SplitKey(k, n) {
		parts := []
		rest := k
		Loop n - 1 {
				pos := InStr(rest, Chr(1))
				if !pos {
						parts.Push(rest)
						rest := ""
						break
				}
				parts.Push(SubStr(rest, 1, pos - 1))
				rest := SubStr(rest, pos + 1)
		}
		parts.Push(rest)
		return parts
}





; ==============================
; ==============================
; ======= 2/ Batch flush =======
; ==============================
; ==============================

; Returns the SQL text accumulated this tick (or "" when nothing to emit).
; Caller appends it to data.sql in the same write that contains the raw
; INSERT statements.
; `device_id_lit` is optional for the live writer, which always uses the
; current Keylogger device.  The cold-cache reader supplies the source device
; explicitly while replaying shared raw events, so cross-device aggregates can
; never be attributed to the Windows host that happened to open the dashboard.
KLW_BuildBatchSql(device_id_lit := "") {
		if !KLW.batch.Has("app_day")
				return ""
		d := (device_id_lit != "") ? device_id_lit : Keylogger._device_id_lit
		out := ""

		; agg_app_day — walker-owned columns ONLY. `time_ms` stays here because
		; the walker's capped inter-key accounting is more accurate than a naive
		; json_each delta sum. `llm_chars`/`llm_triggers`/`llm_input_chars` still
		; have no SQL-rebuild source (they need per-keystroke context that
		; KLR_RebuildAggregates doesn't have) — but `llm_suggested` IS now owned
		; by KLR_RebuildAggregates from events_llm (F19 fix), mirroring
		; hs_suggested. Every other column — chars, pauses, think_time_ms,
		; hs_chars, hs_triggers, hs_input_chars and app_time_ms — is owned by
		; KLR_RebuildAggregates, which computes it once all-time from events_*;
		; writing it here too would double-count it.
		for _, row in KLW.batch["app_day"] {
				out .= Format(
						"INSERT INTO agg_app_day (device_id, date, app, time_ms, llm_chars, llm_triggers, llm_input_chars) VALUES ({1},{2},{3},{4},{5},{6},{7}) ON CONFLICT(device_id, date, app) DO UPDATE SET time_ms=time_ms+excluded.time_ms,llm_chars=llm_chars+excluded.llm_chars,llm_triggers=llm_triggers+excluded.llm_triggers,llm_input_chars=llm_input_chars+excluded.llm_input_chars;`n",
						d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
						KLW_GetMap(row, "time_ms", 0), KLW_GetMap(row, "llm_chars", 0),
						KLW_GetMap(row, "llm_triggers", 0), KLW_GetMap(row, "llm_input_chars", 0))
		}

		; agg_app_day_ms (app_time_ms) is intentionally NOT written by the walker
		; — KLR_RebuildAggregates owns it from events_app_switch.duration_ms so
		; the foreground-time figure is single-sourced and all-time.

		; agg_app_day_buckets.
		for _, row in KLW.batch["app_buckets"] {
				out .= Format(
						"INSERT INTO agg_app_day_buckets (device_id, date, app, bucket_ms, time_sum, credited, hs_input_time_sum, hs_input_credited, llm_input_time_sum, llm_input_credited) VALUES ({1},{2},{3},{4},{5},{6},{7},{8},{9},{10}) ON CONFLICT(device_id, date, app, bucket_ms) DO UPDATE SET time_sum=time_sum+excluded.time_sum,credited=credited+excluded.credited,hs_input_time_sum=hs_input_time_sum+excluded.hs_input_time_sum,hs_input_credited=hs_input_credited+excluded.hs_input_credited,llm_input_time_sum=llm_input_time_sum+excluded.llm_input_time_sum,llm_input_credited=llm_input_credited+excluded.llm_input_credited;`n",
						d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
						row["bucket_ms"], row["time_sum"], row["credited"],
						row["hs_in_t"], row["hs_in_c"], row["llm_in_t"], row["llm_in_c"])
		}

		; n-gram tables.
		for tbl_name, tbl in KLW.batch["ngram"] {
				for key, item in tbl {
						parts := KLW_SplitKey(key, 3)
						out .= Format(
								"INSERT INTO {1} (device_id, date, app, token, c, td, cd, e, esrc_json) VALUES ({2},{3},{4},{5},{6},{7},{8},{9},{10}) ON CONFLICT(device_id, date, app, token) DO UPDATE SET c=c+excluded.c,td=td+excluded.td,cd=cd+excluded.cd,e=e+excluded.e,esrc_json={11};`n",
								tbl_name, d,
								KLW_SqlEscape(parts[1]), KLW_SqlEscape(parts[2]), KLW_SqlEscape(parts[3]),
								item["c"], item["td"], item["cd"], item["e"],
								KLW_JsonEscape(item["esrc"]),
								KLW_EsrcMergeExpr(item["esrc"]))
				}
		}

		; ngram_keycodes.
		for _, row in KLW.batch["kc_ngram"] {
				out .= Format(
						"INSERT INTO ngram_keycodes (device_id, date, app, keycode, c) VALUES ({1},{2},{3},{4},{5}) ON CONFLICT(device_id, date, app, keycode) DO UPDATE SET c=c+excluded.c;`n",
						d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
						row["keycode"], row["count"])
		}

		; ngram_scancodes (Windows hardware scancodes — independent of layout).
		for _, row in KLW.batch["sc_kb_ngram"] {
				out .= Format(
						"INSERT INTO ngram_scancodes (device_id, date, app, scancode, c) VALUES ({1},{2},{3},{4},{5}) ON CONFLICT(device_id, date, app, scancode) DO UPDATE SET c=c+excluded.c;`n",
						d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
						row["scancode"], row["count"])
		}

		; ngram_shortcuts / ngram_shortcut_bigrams.
		for tbl_name, tbl in KLW.batch["sc_ngram"] {
				for _, row in tbl {
						out .= Format(
								"INSERT INTO {1} (device_id, date, app, token, c) VALUES ({2},{3},{4},{5},{6}) ON CONFLICT(device_id, date, app, token) DO UPDATE SET c=c+excluded.c;`n",
								tbl_name, d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
								KLW_SqlEscape(row["token"]), row["count"])
				}
		}

		; agg_app_day_kc_hold.
		for _, row in KLW.batch["kc_hold"] {
				out .= Format(
						"INSERT INTO agg_app_day_kc_hold (device_id, date, app, keycode, sum_ms, count, max_ms, tap_count, hold_count) VALUES ({1},{2},{3},{4},{5},{6},{7},{8},{9}) ON CONFLICT(device_id, date, app, keycode) DO UPDATE SET sum_ms=sum_ms+excluded.sum_ms,count=count+excluded.count,max_ms=MAX(max_ms, excluded.max_ms),tap_count=tap_count+excluded.tap_count,hold_count=hold_count+excluded.hold_count;`n",
						d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
						row["keycode"], row["sum_ms"], row["count"],
						row["max_ms"], row["tap_count"], row["hold_count"])
		}

		; agg_app_day_titles — walker owns `ms` (focus time per title); the
		; occurrence count `c` is owned by KLR_RebuildAggregates (from
		; events_window_switch), so it is not written here.
		;
		; Every app-day touched by this batch is collected while inserting so the
		; per-app-day cap can be enforced once per group afterwards. Any app whose
		; window title carries variable content — browser tabs, chat unread counts,
		; editor "file:line" captions, terminal progress spinners — otherwise adds a
		; permanent row per distinct title, and each one is projected into
		; win_titles inside the prefetch blob the dashboard downloads. The macOS
		; twin (aggregator/sql.lua) has always run this cleanup; the Windows port
		; copied KLWConst.TITLE_CAP_PER_APP_DAY across but not the DELETE that gives
		; it meaning, leaving the table unbounded by construction.
		title_app_days := Map()
		for _, row in KLW.batch["titles"] {
				out .= Format(
						"INSERT INTO agg_app_day_titles (device_id, date, app, title, ms) VALUES ({1},{2},{3},{4},{5}) ON CONFLICT(device_id, date, app, title) DO UPDATE SET ms=ms+excluded.ms;`n",
						d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
						KLW_SqlEscape(row["title"]), row["ms"])
				title_app_days[row["date"] . Chr(1) . row["app"]] := row
		}
		; Ranked by (c + ms) like the macOS twin: a title matters either because it
		; was seen often or because it held focus for a long time.
		for _, ad in title_app_days {
				out .= Format(
						"DELETE FROM agg_app_day_titles WHERE device_id={1} AND date={2} AND app={3} AND title NOT IN (SELECT title FROM agg_app_day_titles WHERE device_id={1} AND date={2} AND app={3} ORDER BY (c + ms) DESC LIMIT {4});`n",
						d, KLW_SqlEscape(ad["date"]), KLW_SqlEscape(ad["app"]),
						KLWConst.TITLE_CAP_PER_APP_DAY)
		}

		; agg_app_day_hourly — walker owns the per-hour error columns
		; (e/em/es/e_buckets_json); the keystroke count `c` is owned by
		; KLR_RebuildAggregates so it is not written here (avoids double-count).
		for _, row in KLW.batch["hourly"] {
				out .= Format(
						"INSERT INTO agg_app_day_hourly (device_id, date, app, hour, e, em, es, e_buckets_json) VALUES ({1},{2},{3},{4},{5},{6},{7},{8}) ON CONFLICT(device_id, date, app, hour) DO UPDATE SET e=e+excluded.e,em=em+excluded.em,es=es+excluded.es,e_buckets_json=excluded.e_buckets_json;`n",
						d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
						KLW_SqlEscape(row["hour"]), row["e"], row["em"], row["es"],
						KLW_JsonEscape(row["e_buckets"]))
		}

		; agg_app_day_hourly_min5 — walker owns e/es/e_buckets_json; the keystroke
		; count `c` is owned by KLR_RebuildAggregates so it is not written here.
		for _, row in KLW.batch["hourly_min5"] {
				out .= Format(
						"INSERT INTO agg_app_day_hourly_min5 (device_id, date, app, slot, e, es, e_buckets_json) VALUES ({1},{2},{3},{4},{5},{6},{7}) ON CONFLICT(device_id, date, app, slot) DO UPDATE SET e=e+excluded.e,es=es+excluded.es,e_buckets_json=excluded.e_buckets_json;`n",
						d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
						KLW_SqlEscape(row["slot"]), row["e"], row["es"],
						KLW_JsonEscape(row["e_buckets"]))
		}

		; agg_app_day_layouts.
		for _, row in KLW.batch["layouts"] {
				out .= Format(
						"INSERT INTO agg_app_day_layouts (device_id, date, app, layout, count) VALUES ({1},{2},{3},{4},{5}) ON CONFLICT(device_id, date, app, layout) DO UPDATE SET count=count+excluded.count;`n",
						d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
						KLW_SqlEscape(row["layout"]), row["count"])
		}

		; agg_app_day_chars_class.
		for _, row in KLW.batch["chars_class"] {
				first_lit := row.Has("first_typed_min") ? KLW_SqlEscape(row["first_typed_min"]) : "NULL"
				last_lit  := row.Has("last_typed_min")  ? KLW_SqlEscape(row["last_typed_min"])  : "NULL"
				out .= Format(
						"INSERT INTO agg_app_day_chars_class (device_id, date, app, letter, digit, punct, space, other, first_typed_min, last_typed_min) VALUES ({1},{2},{3},{4},{5},{6},{7},{8},{9},{10}) ON CONFLICT(device_id, date, app) DO UPDATE SET letter=letter+excluded.letter,digit=digit+excluded.digit,punct=punct+excluded.punct,space=space+excluded.space,other=other+excluded.other,first_typed_min=COALESCE(agg_app_day_chars_class.first_typed_min, excluded.first_typed_min),last_typed_min=COALESCE(excluded.last_typed_min, agg_app_day_chars_class.last_typed_min);`n",
						d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
						row["letter"], row["digit"], row["punct"], row["space"], row["other"],
						first_lit, last_lit)
		}

		; agg_app_day_errors.
		for _, row in KLW.batch["errors"] {
				out .= Format(
						"INSERT INTO agg_app_day_errors (device_id, date, app, bs_total, cascade_count, cascade_max_len, recovery_sum_ms, recovery_count) VALUES ({1},{2},{3},{4},{5},{6},{7},{8}) ON CONFLICT(device_id, date, app) DO UPDATE SET bs_total=bs_total+excluded.bs_total,cascade_count=cascade_count+excluded.cascade_count,cascade_max_len=MAX(cascade_max_len, excluded.cascade_max_len),recovery_sum_ms=recovery_sum_ms+excluded.recovery_sum_ms,recovery_count=recovery_count+excluded.recovery_count;`n",
						d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
						row["bs_total"], row["cascade_count"], row["cascade_max_len"],
						row["recovery_sum_ms"], row["recovery_count"])
		}

		; agg_app_day_ergo.
		for _, row in KLW.batch["ergo"] {
				out .= Format(
						"INSERT INTO agg_app_day_ergo (device_id, date, app, same_finger_streak_max, same_hand_streak_max, auto_repeat_count) VALUES ({1},{2},{3},{4},{5},{6}) ON CONFLICT(device_id, date, app) DO UPDATE SET same_finger_streak_max=MAX(same_finger_streak_max, excluded.same_finger_streak_max),same_hand_streak_max=MAX(same_hand_streak_max, excluded.same_hand_streak_max),auto_repeat_count=auto_repeat_count+excluded.auto_repeat_count;`n",
						d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
						row["same_finger_streak_max"], row["same_hand_streak_max"],
						row["auto_repeat_count"])
		}

		; agg_app_day_burst.
		for _, row in KLW.batch["bursts"] {
				out .= Format(
						"INSERT INTO agg_app_day_burst (device_id, date, app, count_total, max_cpm, max_chars, length_buckets_json, inter_delay_count, inter_delay_sum, inter_delay_sumsq) VALUES ({1},{2},{3},{4},{5},{6},{7},{8},{9},{10}) ON CONFLICT(device_id, date, app) DO UPDATE SET count_total=count_total+excluded.count_total,max_cpm=MAX(max_cpm, excluded.max_cpm),max_chars=MAX(max_chars, excluded.max_chars),length_buckets_json=excluded.length_buckets_json,inter_delay_count=inter_delay_count+excluded.inter_delay_count,inter_delay_sum=inter_delay_sum+excluded.inter_delay_sum,inter_delay_sumsq=inter_delay_sumsq+excluded.inter_delay_sumsq;`n",
						d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
						row["count_total"], row["max_cpm"], row["max_chars"],
						KLW_JsonEscape(row["length_buckets"]),
						row["inter_count"], row["inter_sum"], row["inter_sumsq"])
		}

		; agg_app_day_session.
		for _, row in KLW.batch["sessions"] {
				out .= Format(
						"INSERT INTO agg_app_day_session (device_id, date, app, count_total, longest_ms, longest_chars, total_active_ms, durations_json) VALUES ({1},{2},{3},{4},{5},{6},{7},{8}) ON CONFLICT(device_id, date, app) DO UPDATE SET count_total=count_total+excluded.count_total,longest_ms=MAX(longest_ms, excluded.longest_ms),longest_chars=MAX(longest_chars, excluded.longest_chars),total_active_ms=total_active_ms+excluded.total_active_ms,durations_json=excluded.durations_json;`n",
						d, KLW_SqlEscape(row["date"]), KLW_SqlEscape(row["app"]),
						row["count_total"], row["longest_ms"], row["longest_chars"],
						row["total_active_ms"],
						KLW_JsonEscape(row["durations"]))
		}

		; agg_app_day_switches_to is intentionally NOT written by the walker —
		; KLR_RebuildAggregates now owns it (all-time, from events_app_switch).
		; The walker batch still accumulates KLW.batch["switches_to"] harmlessly;
		; it simply is not flushed here, so the table is single-sourced.

		; agg_system_day — walker owns the columns KLR_RebuildAggregates does not
		; compute (space_switches, audio_muted_ms, passive_count, night_wake_count).
		; wifi_changes / locked_ms / sleep_ms / awake_ms are owned by the SQL
		; rebuild from events_system, so they are not written here.
		for _, row in KLW.batch["system_day"] {
				out .= Format(
						"INSERT INTO agg_system_day (device_id, date, space_switches, audio_muted_ms, passive_count, night_wake_count) VALUES ({1},{2},{3},{4},{5},{6}) ON CONFLICT(device_id, date) DO UPDATE SET space_switches=space_switches+excluded.space_switches,audio_muted_ms=audio_muted_ms+excluded.audio_muted_ms,passive_count=passive_count+excluded.passive_count,night_wake_count=night_wake_count+excluded.night_wake_count;`n",
						d, KLW_SqlEscape(row["date"]),
						row["space_switches"], row["audio_muted_ms"],
						row["passive_count"], row["night_wake_count"])
		}

		KLW_ResetBatch()
		return out
}





; ======================================
; ======================================
; ======= 3/ Context persistence =======
; ======================================
; ======================================

; Serialise KLW.ctx into a Map suitable for state.json.
KLW_SerializeCtx() {
		return KLW.ctx
}

KLW_RestoreCtx(loaded) {
		if (loaded is Map)
				KLW.ctx := loaded
		else
				KLW.ctx := Map()
}

KLW_DayRolloverReset() {
		KLW.ctx := Map()
		KLW_ResetBatch()
}
