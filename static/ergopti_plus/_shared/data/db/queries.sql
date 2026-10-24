-- _shared/data/db/queries.sql
--
-- ============================================================================
-- ERGOPTI METRICS — NAMED KEYSTATS QUERIES
--
-- Single source of truth for the keystats SQL that more than one driver runs.
-- tools/codegen/codegen-keystats-queries.cjs compiles this file into
-- `_shared/lua/keystats/queries.lua` (macOS and Linux) and
-- `windows/_generated/keystats_queries.ahk` (Windows); a driver renders a query
-- by name and never retypes its text.
--
-- Format: each query opens with `-- name: <family>.<query>` followed by
-- optional `-- doc:` lines and ends with the first line ending in `;`.
-- Placeholders:
--   {{where}}           the driver's filter clause, empty or " WHERE …";
--                       each driver keeps its own literal quoting.
--   {{text <expr>}}     a TEXT column. In-process engines (Hammerspoon, the
--                       AHK sqlite3.dll) read `<expr>` as is; the Linux CLI's
--                       JSON mode cuts raw TEXT at NUL, so its dialect selects
--                       `json_quote(<expr>) AS <name>_json` and decodes it.
--                       `<expr>` is a column, or `EXPR AS name`.
-- Census and parity findings: docs/audits/2026-10-24-keystats-sql-census.md.
-- ============================================================================


-- ============================================================================
-- 1. MANIFEST PROJECTION (one row per date and application, all devices)
-- ============================================================================

-- name: manifest.app_day
-- doc: Typing totals and the latest saved category of each application day.
SELECT date, {{text app}},
       SUM(chars) AS chars, SUM(pauses) AS pauses,
       SUM(time_ms) AS time_ms, SUM(think_time_ms) AS think_time_ms,
       SUM(hs_chars) AS hs_chars, SUM(llm_chars) AS llm_chars,
       SUM(hs_triggers) AS hs_triggers, SUM(llm_triggers) AS llm_triggers,
       SUM(hs_suggested) AS hs_suggested, SUM(llm_suggested) AS llm_suggested,
       SUM(hs_input_chars) AS hs_input_chars, SUM(llm_input_chars) AS llm_input_chars,
       SUM(app_time_ms) AS app_time_ms, {{text MAX(category) AS category}}
FROM agg_app_day{{where}}
GROUP BY date, app;

-- name: manifest.buckets
-- doc: Cumulative pause buckets behind the "ignore pauses longer than" control.
SELECT date, {{text app}}, bucket_ms,
       SUM(time_sum) AS time_sum, SUM(credited) AS credited,
       SUM(hs_input_time_sum) AS hs_in_t, SUM(hs_input_credited) AS hs_in_c,
       SUM(llm_input_time_sum) AS llm_in_t, SUM(llm_input_credited) AS llm_in_c
FROM agg_app_day_buckets{{where}}
GROUP BY date, app, bucket_ms;

-- name: manifest.burst
-- doc: Burst records. Grouped by the histogram blob as well, so each device's
-- doc: distinct blob is merged by the reader and identical blobs keep their
-- doc: multiplicity through source_rows.
SELECT date, {{text app}},
       SUM(count_total) AS count_total, MAX(max_cpm) AS max_cpm, MAX(max_chars) AS max_chars,
       SUM(inter_delay_count) AS inter_count, SUM(inter_delay_sum) AS inter_sum,
       SUM(inter_delay_sumsq) AS inter_sumsq, length_buckets_json, COUNT(*) AS source_rows
FROM agg_app_day_burst{{where}}
GROUP BY date, app, length_buckets_json;

-- name: manifest.session
-- doc: Session rows, one per device; the reader merges records and durations.
SELECT date, {{text app}}, count_total, longest_ms, longest_chars, total_active_ms, durations_json
FROM agg_app_day_session{{where}};

-- name: manifest.chars_class
-- doc: Character classes and the first and last minute typed, across devices.
SELECT date, {{text app}},
       SUM(letter) AS letter, SUM(digit) AS digit, SUM(punct) AS punct,
       SUM(space) AS space, SUM(other) AS other,
       MIN(first_typed_min) AS first_min, MAX(last_typed_min) AS last_min
FROM agg_app_day_chars_class{{where}}
GROUP BY date, app;

-- name: manifest.errors
-- doc: Corrections, cascades and recovery time.
SELECT date, {{text app}},
       SUM(bs_total) AS bs_total, SUM(cascade_count) AS cascade_count,
       MAX(cascade_max_len) AS cascade_max_len, SUM(recovery_sum_ms) AS recovery_sum,
       SUM(recovery_count) AS recovery_count
FROM agg_app_day_errors{{where}}
GROUP BY date, app;

-- name: manifest.ergo
-- doc: Streak records (MAX across devices), auto-repeat and focus latency.
SELECT date, {{text app}},
       MAX(same_finger_streak_max) AS f_max,
       MAX(same_hand_streak_max) AS h_max,
       SUM(auto_repeat_count) AS ar_count,
       SUM(focus_to_first_key_sum_ms) AS focus_sum,
       SUM(focus_to_first_key_count) AS focus_count
FROM agg_app_day_ergo{{where}}
GROUP BY date, app;

-- name: manifest.layouts
-- doc: Keystrokes per layout.
SELECT date, {{text app}}, {{text layout}}, SUM(count) AS count
FROM agg_app_day_layouts{{where}}
GROUP BY date, app, layout;

-- name: manifest.kc_hold
-- doc: Key hold durations per keycode; the longest hold is a MAX record.
SELECT date, {{text app}}, keycode,
       SUM(sum_ms) AS s, SUM(count) AS c, MAX(max_ms) AS mx,
       SUM(tap_count) AS t, SUM(hold_count) AS h
FROM agg_app_day_kc_hold{{where}}
GROUP BY date, app, keycode;

-- name: manifest.media_keys
-- doc: Semantic media key presses, labelled rather than given a position.
SELECT date, {{text app}}, media_id, SUM(c) AS c
FROM ngram_media_keys{{where}}
GROUP BY date, app, media_id;

-- name: manifest.media_hold
-- doc: Semantic media key holds.
SELECT date, {{text app}}, media_id, SUM(sum_ms) AS sum_ms, SUM(count) AS count,
       MAX(max_ms) AS max_ms, SUM(tap_count) AS tap_count, SUM(hold_count) AS hold_count
FROM agg_app_day_media_hold{{where}}
GROUP BY date, app, media_id;

-- name: manifest.titles
-- doc: Window titles with their keystroke count and focused time.
SELECT date, {{text app}}, {{text title}}, SUM(c) AS c, SUM(ms) AS ms
FROM agg_app_day_titles{{where}}
GROUP BY date, app, title;

-- name: manifest.hourly
-- doc: Hour-of-day activity; grouped by the error-bucket blob like bursts.
SELECT date, {{text app}}, hour,
       SUM(c) AS c, SUM(e) AS e, SUM(em) AS em, SUM(es) AS es,
       e_buckets_json, COUNT(*) AS source_rows
FROM agg_app_day_hourly{{where}}
GROUP BY date, app, hour, e_buckets_json;

-- name: manifest.hourly_min5
-- doc: Five-minute activity slots; grouped by the error-bucket blob.
SELECT date, {{text app}}, slot,
       SUM(c) AS c, SUM(e) AS e, SUM(es) AS es,
       e_buckets_json, COUNT(*) AS source_rows
FROM agg_app_day_hourly_min5{{where}}
GROUP BY date, app, slot, e_buckets_json;

-- name: manifest.switches_to
-- doc: Directed application switches under the source application. The source
-- doc: is aliased to `app` inside a subquery so the shared date and application
-- doc: filter applies to this differently keyed table too.
SELECT date, {{text app}}, {{text app_to}}, SUM(count) AS count
FROM (SELECT date, app_from AS app, app_to, count FROM agg_app_day_switches_to){{where}}
GROUP BY date, app, app_to;

-- name: manifest.system_day
-- doc: The machine's own day (no application). Battery extrema count only the
-- doc: rows that sampled the battery, so a device without one invents nothing.
SELECT date,
       COALESCE(SUM(wifi_changes), 0) AS wifi_changes,
       COALESCE(SUM(space_switches), 0) AS space_switches,
       COALESCE(SUM(battery_sum), 0) AS battery_sum,
       COALESCE(SUM(battery_count), 0) AS battery_count,
       COALESCE(SUM(audio_muted_ms), 0) AS audio_muted_ms,
       COALESCE(SUM(locked_ms), 0) AS locked_ms,
       COALESCE(SUM(sleep_ms), 0) AS sleep_ms,
       COALESCE(SUM(awake_ms), 0) AS awake_ms,
       COALESCE(SUM(passive_count), 0) AS passive_count,
       COALESCE(SUM(night_wake_count), 0) AS night_wake_count,
       MIN(CASE WHEN battery_count > 0 THEN battery_min END) AS battery_min,
       MAX(CASE WHEN battery_count > 0 THEN battery_max END) AS battery_max
FROM agg_system_day{{where}}
GROUP BY date;


-- ============================================================================
-- 2. N-GRAM PROJECTION (one row per token and source map, all devices)
-- ============================================================================

-- name: ngram.tokens
-- doc: Tokens of one n-gram family. {{table}} is a family table name from the
-- doc: reader's fixed map; {{conjunction}} is " WHERE " after an empty filter
-- doc: and " AND " after a non-empty one. TOTAL accumulates as a float, so a
-- doc: large count cannot overflow; a row whose counters are not numbers is
-- doc: returned raw, once, for the reader to read as zero instead of SQLite
-- doc: summing "12oops" as 12. Identical source maps keep their multiplicity.
SELECT {{text token}}, TOTAL(c) AS c, TOTAL(td) AS td, TOTAL(e) AS e, esrc_json, COUNT(*) AS source_rows
FROM {{table}}{{where}}{{conjunction}}(typeof(c) IN ('integer','real') AND typeof(td) IN ('integer','real') AND typeof(e) IN ('integer','real'))
GROUP BY token, esrc_json
UNION ALL SELECT {{text token}}, c, td, e, esrc_json, 1 AS source_rows
FROM {{table}}{{where}}{{conjunction}}NOT (typeof(c) IN ('integer','real') AND typeof(td) IN ('integer','real') AND typeof(e) IN ('integer','real'));

-- name: ngram.tokens_by_app
-- doc: The same projection split by application, for today's live slice.
SELECT {{text app}}, {{text token}}, TOTAL(c) AS c, TOTAL(td) AS td, TOTAL(e) AS e, esrc_json, COUNT(*) AS source_rows
FROM {{table}}{{where}}{{conjunction}}(typeof(c) IN ('integer','real') AND typeof(td) IN ('integer','real') AND typeof(e) IN ('integer','real'))
GROUP BY app, token, esrc_json
UNION ALL SELECT {{text app}}, {{text token}}, c, td, e, esrc_json, 1 AS source_rows
FROM {{table}}{{where}}{{conjunction}}NOT (typeof(c) IN ('integer','real') AND typeof(td) IN ('integer','real') AND typeof(e) IN ('integer','real'));
