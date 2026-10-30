; modules/keystats/keystats_walker_sql.ahk

; ==============================================================================
; MODULE: Keystats Aggregation Walker — SQL emission and context persistence
; DESCRIPTION:
; SQL escaping helpers, batch flush (KLW_BuildBatchSql), and the walking
; context persistence helpers (serialise / restore / day-rollover reset).
; Extracted from keystats_walker.ahk so the SQL layer can be read and maintained
; independently from the inner-loop walking code.
;
; FEATURES & RATIONALE:
; 1. KLW_SplitKey: helper of KLW_BuildBatchSql. A statement the
;    three drivers share is rendered from the catalogue
;    (_shared/data/db/queries.sql) by name; the Windows-only tables stay spelled here.
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

; Renders one catalogue statement of the batch, one per line of data.sql.
_KLW_Statement(Name, Row, Fields, DeviceId, Extra := unset) {
		Slots := IsSet(Extra) ? Extra : Map()
		Slots["device_id"] := DeviceId
		Slots["date"] := String(Row["date"])
		Slots["app"] := String(Row["app"])
		for Slot, Field in Fields
				Slots[Slot] := Row[Field]
		return KeystatsQuery(Name, Slots) . "`n"
}

; A batch row holds the columns the walker owns. The catalogue statement names
; the others too; 0 adds nothing to what KLR_RebuildAggregates owns.
_KLW_Zeros(Names) {
		Slots := Map()
		for Name in Names
				Slots[Name] := 0
		return Slots
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
; `DeviceId` is optional for the live writer, which always uses the
; current Keystats device.  The cold-cache reader supplies the source device
; explicitly while replaying shared raw events, so cross-device aggregates can
; never be attributed to the Windows host that happened to open the dashboard.
KLW_BuildBatchSql(DeviceId := "", TrimTitles := true) {
		if !KLW.batch.Has("app_day")
				return ""
		Device := (DeviceId != "") ? DeviceId : Keystats.device_id
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
				Slots := _KLW_Zeros(["chars", "pauses", "think_time_ms", "hs_chars", "hs_triggers", "hs_suggested",
						"llm_suggested", "hs_input_chars", "app_time_ms"])
				if (row.Has("category") && row["category"] != "")
						Slots["category"] := String(row["category"])
				Slots["time_ms"] := KLW_GetMap(row, "time_ms", 0)
				Slots["llm_chars"] := KLW_GetMap(row, "llm_chars", 0)
				Slots["llm_triggers"] := KLW_GetMap(row, "llm_triggers", 0)
				Slots["llm_input_chars"] := KLW_GetMap(row, "llm_input_chars", 0)
				out .= _KLW_Statement("agg.app_day", row, Map(), Device, Slots)
		}

		; agg_app_day_ms (app_time_ms) is intentionally NOT written by the walker
		; — KLR_RebuildAggregates owns it from events_app_switch.duration_ms so
		; the foreground-time figure is single-sourced and all-time.

		; agg_app_day_buckets.
		for _, row in KLW.batch["app_buckets"] {
				out .= _KLW_Statement("agg.buckets", row, Map("bucket_ms", "bucket_ms", "time_sum", "time_sum",
						"credited", "credited", "hs_input_time_sum", "hs_in_t", "hs_input_credited", "hs_in_c",
						"llm_input_time_sum", "llm_in_t", "llm_input_credited", "llm_in_c"), Device)
		}

		; n-gram tables.
		for tbl_name, tbl in KLW.batch["ngram"] {
				for key, item in tbl {
						parts := KLW_SplitKey(key, 3)
						out .= KeystatsQuery("agg.ngram", Map("table", tbl_name, "device_id", Device,
								"date", parts[1], "app", parts[2], "token", parts[3],
								"c", item["c"], "td", item["td"], "cd", item["cd"], "e", item["e"],
								"esrc_json", KL_JsonEncode(item["esrc"]))) . "`n"
				}
		}

		; ngram_keycodes.
		for _, row in KLW.batch["kc_ngram"] {
				out .= _KLW_Statement("agg.ngram_keycode", row, Map("keycode", "keycode", "c", "count"), Device)
		}

		; ngram_scancodes (Windows hardware scancodes — independent of layout).
		for _, row in KLW.batch["sc_kb_ngram"] {
				out .= _KLW_Statement("agg.ngram_scancode", row, Map("scancode", "scancode", "c", "count"), Device)
		}

		; ngram_shortcuts / ngram_shortcut_bigrams.
		for tbl_name, tbl in KLW.batch["sc_ngram"] {
				for _, row in tbl {
						out .= _KLW_Statement("agg.ngram_shortcut", row, Map("c", "count"), Device,
								Map("table", tbl_name, "token", String(row["token"])))
				}
		}

		; agg_app_day_kc_hold.
		for _, row in KLW.batch["kc_hold"] {
				out .= _KLW_Statement("agg.kc_hold", row, Map("keycode", "keycode", "sum_ms", "sum_ms", "count", "count",
						"max_ms", "max_ms", "tap_count", "tap_count", "hold_count", "hold_count"), Device)
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
				out .= _KLW_Statement("agg.title", row, Map("ms", "ms"), Device,
						Map("c", 0, "title", String(row["title"])))
				; Private replay ranks complete totals after every batch has landed.
				if TrimTitles
						title_app_days[row["date"] . Chr(1) . row["app"]] := row
		}
		; Ranked by (c + ms) like the macOS twin: a title matters either because it
		; was seen often or because it held focus for a long time.
		for _, ad in title_app_days {
				out .= _KLW_Statement("agg.title_prune", ad, Map(), Device,
						Map("cap", KLWConst.TITLE_CAP_PER_APP_DAY))
		}

		; agg_app_day_hourly — walker owns the per-hour error columns
		; (e/em/es/e_buckets_json); the keystroke count `c` is owned by
		; KLR_RebuildAggregates so it is not written here (avoids double-count).
		for _, row in KLW.batch["hourly"] {
				out .= _KLW_Statement("agg.hourly", row, Map("e", "e", "em", "em", "es", "es"), Device,
						Map("c", 0, "hour", String(row["hour"]), "e_buckets_json", KL_JsonEncode(row["e_buckets"])))
		}

		; agg_app_day_hourly_min5 — walker owns e/es/e_buckets_json; the keystroke
		; count `c` is owned by KLR_RebuildAggregates so it is not written here.
		for _, row in KLW.batch["hourly_min5"] {
				out .= _KLW_Statement("agg.hourly_min5", row, Map("e", "e", "es", "es"), Device,
						Map("c", 0, "slot", String(row["slot"]), "e_buckets_json", KL_JsonEncode(row["e_buckets"])))
		}

		; agg_app_day_layouts.
		for _, row in KLW.batch["layouts"] {
				out .= _KLW_Statement("agg.layouts", row, Map("count", "count"), Device,
						Map("layout", String(row["layout"])))
		}

		; agg_app_day_chars_class.
		for _, row in KLW.batch["chars_class"] {
				Slots := Map()
				if row.Has("first_typed_min")
						Slots["first_typed_min"] := String(row["first_typed_min"])
				if row.Has("last_typed_min")
						Slots["last_typed_min"] := String(row["last_typed_min"])
				out .= _KLW_Statement("agg.chars_class", row, Map("letter", "letter", "digit", "digit",
						"punct", "punct", "space", "space", "other", "other"), Device, Slots)
		}

		; agg_app_day_errors.
		for _, row in KLW.batch["errors"] {
				out .= _KLW_Statement("agg.errors", row, Map("bs_total", "bs_total", "cascade_count", "cascade_count",
						"cascade_max_len", "cascade_max_len", "recovery_sum_ms", "recovery_sum_ms",
						"recovery_count", "recovery_count"), Device)
		}

		; agg_app_day_ergo. The focus latency is not measured on Windows.
		for _, row in KLW.batch["ergo"] {
				out .= _KLW_Statement("agg.ergo", row, Map("same_finger_streak_max", "same_finger_streak_max",
						"same_hand_streak_max", "same_hand_streak_max", "auto_repeat_count", "auto_repeat_count"), Device,
						_KLW_Zeros(["focus_to_first_key_sum_ms", "focus_to_first_key_count"]))
		}

		; agg_app_day_burst.
		for _, row in KLW.batch["bursts"] {
				out .= _KLW_Statement("agg.burst", row, Map("count_total", "count_total", "max_cpm", "max_cpm",
						"max_chars", "max_chars", "inter_delay_count", "inter_count", "inter_delay_sum", "inter_sum",
						"inter_delay_sumsq", "inter_sumsq"), Device,
						Map("length_buckets_json", KL_JsonEncode(row["length_buckets"])))
		}

		; agg_app_day_session. The cap matches FinalizeSession's earliest samples
		; across the whole day, not per flush.
		for _, row in KLW.batch["sessions"] {
				out .= _KLW_Statement("agg.session", row, Map("count_total", "count_total", "longest_ms", "longest_ms",
						"longest_chars", "longest_chars", "total_active_ms", "total_active_ms"), Device,
						Map("duration_cap", KLWConst.SESSION_DURATIONS_CAP, "durations_json", KL_JsonEncode(row["durations"])))
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
				Slots := _KLW_Zeros(["wifi_changes", "locked_ms", "sleep_ms", "awake_ms"])
				Slots["device_id"] := Device
				Slots["date"] := String(row["date"])
				Slots["space_switches"] := row["space_switches"]
				Slots["audio_muted_ms"] := row["audio_muted_ms"]
				Slots["passive_count"] := row["passive_count"]
				Slots["night_wake_count"] := row["night_wake_count"]
				out .= KeystatsQuery("agg.system_day", Slots) . "`n"
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
