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
--   {{s name}} {{i name}} {{r name}}
--                       a typed value slot of a write or keyed statement: a TEXT
--                       literal, an integer or a real, quoted by the generated renderer
--                       (sqlite.literal) from the raw value the driver passes.
--                       `{{s? name}}` and `{{i? name}}` render NULL for a missing
--                       value; every other slot refuses one. A real keeps 17
--                       significant digits.
--   {{merge <column>}}  at generation time, the expression that sums the stored
--                       JSON number map of <column> with the incoming one key by
--                       key (esrc_json, e_buckets_json, length_buckets_json).
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


-- ============================================================================
-- 3. METADATA
-- ============================================================================

-- name: meta.rev
-- doc: The revision counter every writer bumps on a successful commit; readers
-- doc: compare it to know whether anything changed. A numeric string, so no
-- doc: dialect has to protect it.
SELECT value FROM meta WHERE key='rev';

-- name: meta.get
-- doc: One metadata value by key. The CLI dialect quotes the value so a NUL or
-- doc: a line break survives the one-line scalar framing.
SELECT {{text value}} FROM meta WHERE key={{s key}};

-- name: meta.set
-- doc: Writes one metadata value, replacing any earlier one.
INSERT OR REPLACE INTO meta (key, value) VALUES ({{s key}}, {{s value}});

-- name: meta.upsert
-- doc: Writes one metadata value inside a flush transaction, keeping the row.
INSERT INTO meta(key,value) VALUES ({{s key}},{{s value}}) ON CONFLICT(key) DO UPDATE SET value = excluded.value;

-- name: meta.seed
-- doc: Creates a metadata key with its first value when it does not exist yet.
INSERT OR IGNORE INTO meta (key, value) VALUES ({{s key}}, {{s value}});

-- name: meta.rev_bump
-- doc: Advances the revision counter. The value is stored as text, which is the
-- doc: column's own affinity, so every driver reads back the same string.
UPDATE meta SET value=CAST(CAST(value AS INTEGER)+1 AS TEXT) WHERE key='rev';


-- ============================================================================
-- 4. DEVICES
-- ============================================================================

-- name: devices.upsert
-- doc: Registers or refreshes this machine's row. The conflict clause leaves
-- doc: created_at and the imported data.sql watermark alone, which a REPLACE
-- doc: would delete and so make the ledger import start over.
INSERT INTO devices (device_id, name, os, os_version, host_signature, created_at, updated_at)
VALUES ({{s device_id}}, {{s name}}, {{s os}}, {{s os_version}}, {{s host_signature}}, {{s created_at}}, {{s updated_at}})
ON CONFLICT(device_id) DO UPDATE SET
  name = excluded.name, os = excluded.os, os_version = excluded.os_version,
  host_signature = excluded.host_signature, updated_at = excluded.updated_at;


-- ============================================================================
-- 5. AGGREGATE UPSERTS (one row per application and day, per device)
-- ============================================================================
-- Every statement adds a flush's delta to the stored row. Sums add, records
-- take a MAX, the first and last typed minute take a MIN and a MAX, and the
-- number maps and the duration list merge key by key in SQL, because each
-- flush only knows what happened since the previous one.

-- name: agg.app_day
-- doc: Typing totals of an application day. A caller that knows only some of the
-- doc: counters passes 0 for the others, which adds nothing; the category is
-- doc: kept once set.
INSERT INTO agg_app_day (device_id, date, app, chars, pauses, time_ms, think_time_ms, hs_chars, llm_chars, hs_triggers, llm_triggers, hs_suggested, llm_suggested, hs_input_chars, llm_input_chars, app_time_ms, category)
VALUES ({{s device_id}},{{s date}},{{s app}},{{i chars}},{{i pauses}},{{i time_ms}},{{i think_time_ms}},{{i hs_chars}},{{i llm_chars}},{{i hs_triggers}},{{i llm_triggers}},{{i hs_suggested}},{{i llm_suggested}},{{i hs_input_chars}},{{i llm_input_chars}},{{i app_time_ms}},{{s? category}})
ON CONFLICT(device_id, date, app) DO UPDATE SET
  chars = chars + excluded.chars, pauses = pauses + excluded.pauses,
  time_ms = time_ms + excluded.time_ms, think_time_ms = think_time_ms + excluded.think_time_ms,
  hs_chars = hs_chars + excluded.hs_chars, llm_chars = llm_chars + excluded.llm_chars,
  hs_triggers = hs_triggers + excluded.hs_triggers, llm_triggers = llm_triggers + excluded.llm_triggers,
  hs_suggested = hs_suggested + excluded.hs_suggested, llm_suggested = llm_suggested + excluded.llm_suggested,
  hs_input_chars = hs_input_chars + excluded.hs_input_chars, llm_input_chars = llm_input_chars + excluded.llm_input_chars,
  app_time_ms = app_time_ms + excluded.app_time_ms,
  category = COALESCE(agg_app_day.category, excluded.category);

-- name: agg.buckets
-- doc: Cumulative pause buckets of an application day.
INSERT INTO agg_app_day_buckets (device_id, date, app, bucket_ms, time_sum, credited, hs_input_time_sum, hs_input_credited, llm_input_time_sum, llm_input_credited)
VALUES ({{s device_id}},{{s date}},{{s app}},{{i bucket_ms}},{{i time_sum}},{{i credited}},{{i hs_input_time_sum}},{{i hs_input_credited}},{{i llm_input_time_sum}},{{i llm_input_credited}})
ON CONFLICT(device_id, date, app, bucket_ms) DO UPDATE SET
  time_sum = time_sum + excluded.time_sum, credited = credited + excluded.credited,
  hs_input_time_sum = hs_input_time_sum + excluded.hs_input_time_sum,
  hs_input_credited = hs_input_credited + excluded.hs_input_credited,
  llm_input_time_sum = llm_input_time_sum + excluded.llm_input_time_sum,
  llm_input_credited = llm_input_credited + excluded.llm_input_credited;

-- name: agg.kc_hold
-- doc: Hold durations of one key code. The longest hold is a record, not a sum.
INSERT INTO agg_app_day_kc_hold (device_id, date, app, keycode, sum_ms, count, max_ms, tap_count, hold_count)
VALUES ({{s device_id}},{{s date}},{{s app}},{{i keycode}},{{i sum_ms}},{{i count}},{{i max_ms}},{{i tap_count}},{{i hold_count}})
ON CONFLICT(device_id, date, app, keycode) DO UPDATE SET
  sum_ms = sum_ms + excluded.sum_ms, count = count + excluded.count,
  max_ms = MAX(max_ms, excluded.max_ms),
  tap_count = tap_count + excluded.tap_count, hold_count = hold_count + excluded.hold_count;

-- name: agg.layouts
-- doc: Keystrokes typed under one keyboard layout.
INSERT INTO agg_app_day_layouts (device_id, date, app, layout, count)
VALUES ({{s device_id}},{{s date}},{{s app}},{{s layout}},{{i count}})
ON CONFLICT(device_id, date, app, layout) DO UPDATE SET count = count + excluded.count;

-- name: agg.switches_to
-- doc: Switches from one application to another.
INSERT INTO agg_app_day_switches_to (device_id, date, app_from, app_to, count)
VALUES ({{s device_id}},{{s date}},{{s app_from}},{{s app_to}},{{i count}})
ON CONFLICT(device_id, date, app_from, app_to) DO UPDATE SET count = count + excluded.count;

-- name: agg.errors
-- doc: Backspace and correction analysis. The longest cascade is a record.
INSERT INTO agg_app_day_errors (device_id, date, app, bs_total, cascade_count, cascade_max_len, recovery_sum_ms, recovery_count)
VALUES ({{s device_id}},{{s date}},{{s app}},{{i bs_total}},{{i cascade_count}},{{i cascade_max_len}},{{i recovery_sum_ms}},{{i recovery_count}})
ON CONFLICT(device_id, date, app) DO UPDATE SET
  bs_total = bs_total + excluded.bs_total, cascade_count = cascade_count + excluded.cascade_count,
  cascade_max_len = MAX(cascade_max_len, excluded.cascade_max_len),
  recovery_sum_ms = recovery_sum_ms + excluded.recovery_sum_ms,
  recovery_count = recovery_count + excluded.recovery_count;

-- name: agg.ergo
-- doc: Streak records and focus latency. Streaks are records, the rest sums.
INSERT INTO agg_app_day_ergo (device_id, date, app, same_finger_streak_max, same_hand_streak_max, auto_repeat_count, focus_to_first_key_sum_ms, focus_to_first_key_count)
VALUES ({{s device_id}},{{s date}},{{s app}},{{i same_finger_streak_max}},{{i same_hand_streak_max}},{{i auto_repeat_count}},{{i focus_to_first_key_sum_ms}},{{i focus_to_first_key_count}})
ON CONFLICT(device_id, date, app) DO UPDATE SET
  same_finger_streak_max = MAX(same_finger_streak_max, excluded.same_finger_streak_max),
  same_hand_streak_max = MAX(same_hand_streak_max, excluded.same_hand_streak_max),
  auto_repeat_count = auto_repeat_count + excluded.auto_repeat_count,
  focus_to_first_key_sum_ms = focus_to_first_key_sum_ms + excluded.focus_to_first_key_sum_ms,
  focus_to_first_key_count = focus_to_first_key_count + excluded.focus_to_first_key_count;

-- name: agg.chars_class
-- doc: Character classes of an application day. The five counts add; the first
-- doc: and last typed minute are a MIN and a MAX, so a late flush cannot move
-- doc: the first keystroke of the morning forward.
INSERT INTO agg_app_day_chars_class (device_id, date, app, letter, digit, punct, space, other, first_typed_min, last_typed_min)
VALUES ({{s device_id}},{{s date}},{{s app}},{{i letter}},{{i digit}},{{i punct}},{{i space}},{{i other}},{{s? first_typed_min}},{{s? last_typed_min}})
ON CONFLICT(device_id, date, app) DO UPDATE SET
  letter = letter + excluded.letter, digit = digit + excluded.digit,
  punct = punct + excluded.punct, space = space + excluded.space, other = other + excluded.other,
  first_typed_min = MIN(COALESCE(first_typed_min, excluded.first_typed_min), COALESCE(excluded.first_typed_min, first_typed_min)),
  last_typed_min = MAX(COALESCE(last_typed_min, excluded.last_typed_min), COALESCE(excluded.last_typed_min, last_typed_min));

-- name: agg.hourly
-- doc: Typing and error counts of one hour. The error histogram merges key by key.
INSERT INTO agg_app_day_hourly (device_id, date, app, hour, c, e, em, es, e_buckets_json)
VALUES ({{s device_id}},{{s date}},{{s app}},{{s hour}},{{i c}},{{i e}},{{i em}},{{i es}},{{s e_buckets_json}})
ON CONFLICT(device_id, date, app, hour) DO UPDATE SET
  c = c + excluded.c, e = e + excluded.e, em = em + excluded.em, es = es + excluded.es,
  e_buckets_json = {{merge e_buckets_json}};

-- name: agg.hourly_min5
-- doc: The same counts for one five-minute slot.
INSERT INTO agg_app_day_hourly_min5 (device_id, date, app, slot, c, e, es, e_buckets_json)
VALUES ({{s device_id}},{{s date}},{{s app}},{{s slot}},{{i c}},{{i e}},{{i es}},{{s e_buckets_json}})
ON CONFLICT(device_id, date, app, slot) DO UPDATE SET
  c = c + excluded.c, e = e + excluded.e, es = es + excluded.es,
  e_buckets_json = {{merge e_buckets_json}};

-- name: agg.burst
-- doc: Burst records. The peaks are records, the counts and moments add, and the
-- doc: length histogram merges key by key, since a flush only sees its own bursts.
INSERT INTO agg_app_day_burst (device_id, date, app, count_total, max_cpm, max_chars, length_buckets_json, inter_delay_count, inter_delay_sum, inter_delay_sumsq)
VALUES ({{s device_id}},{{s date}},{{s app}},{{i count_total}},{{r max_cpm}},{{i max_chars}},{{s length_buckets_json}},{{i inter_delay_count}},{{i inter_delay_sum}},{{i inter_delay_sumsq}})
ON CONFLICT(device_id, date, app) DO UPDATE SET
  count_total = count_total + excluded.count_total,
  max_cpm = MAX(max_cpm, excluded.max_cpm), max_chars = MAX(max_chars, excluded.max_chars),
  length_buckets_json = {{merge length_buckets_json}},
  inter_delay_count = inter_delay_count + excluded.inter_delay_count,
  inter_delay_sum = inter_delay_sum + excluded.inter_delay_sum,
  inter_delay_sumsq = inter_delay_sumsq + excluded.inter_delay_sumsq;

-- name: agg.session
-- doc: Typing sessions. The longest are records; the duration samples append
-- doc: stored first and stop at the cap, so a later flush cannot displace an
-- doc: earlier sample and every driver observes the same bound.
INSERT INTO agg_app_day_session (device_id, date, app, count_total, longest_ms, longest_chars, total_active_ms, durations_json)
VALUES ({{s device_id}},{{s date}},{{s app}},{{i count_total}},{{i longest_ms}},{{i longest_chars}},{{i total_active_ms}},{{s durations_json}})
ON CONFLICT(device_id, date, app) DO UPDATE SET
  count_total = count_total + excluded.count_total,
  longest_ms = MAX(longest_ms, excluded.longest_ms), longest_chars = MAX(longest_chars, excluded.longest_chars),
  total_active_ms = total_active_ms + excluded.total_active_ms,
  durations_json = (SELECT json_group_array(duration) FROM (SELECT value AS duration FROM json_each(COALESCE(durations_json, '[]')) UNION ALL SELECT value FROM json_each(COALESCE(excluded.durations_json, '[]')) LIMIT {{i duration_cap}}));

-- name: agg.ngram
-- doc: One token of an n-gram family. {{table}} is a family table name the driver
-- doc: takes from its fixed list; the source map merges key by key.
INSERT INTO {{table}} (device_id, date, app, token, c, td, cd, e, esrc_json)
VALUES ({{s device_id}},{{s date}},{{s app}},{{s token}},{{i c}},{{i td}},{{i cd}},{{i e}},{{s esrc_json}})
ON CONFLICT(device_id, date, app, token) DO UPDATE SET
  c = c + excluded.c, td = td + excluded.td, cd = cd + excluded.cd, e = e + excluded.e,
  esrc_json = {{merge esrc_json}};

-- name: agg.title
-- doc: One window title's counters for an application day.
INSERT INTO agg_app_day_titles (device_id, date, app, title, c, ms)
VALUES ({{s device_id}},{{s date}},{{s app}},{{s title}},{{i c}},{{i ms}})
ON CONFLICT(device_id, date, app, title) DO UPDATE SET c = c + excluded.c, ms = ms + excluded.ms;

-- name: agg.title_prune
-- doc: Keeps the cap titles of an application day with the most activity, so a
-- doc: window the user glanced at loses to one they worked in.
DELETE FROM agg_app_day_titles WHERE device_id = {{s device_id}} AND date = {{s date}} AND app = {{s app}}
AND title NOT IN (SELECT title FROM agg_app_day_titles WHERE device_id = {{s device_id}} AND date = {{s date}} AND app = {{s app}} ORDER BY (c + ms) DESC LIMIT {{i cap}});
