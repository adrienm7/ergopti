-- _shared/schema/schema.sql
--
-- ============================================================================
-- ERGOPTI METRICS — CANONICAL SQLITE SCHEMA
--
-- Single source of truth for the keylogger database structure. The Hammerspoon
-- driver (lib/keylogger/log_manager.lua) and the AHK driver (lib/keylogger/)
-- both load this file at startup to ensure the on-disk shape stays bit-
-- identical between operating systems.
--
-- Versioning: each breaking change bumps `meta.schema_version`. Migrations live
-- under `migrations/` and are applied in order from the version stored in the
-- existing database to the version declared by this file.
--
-- Source-of-truth model: the user-visible artefact is `data.sql` (append-only
-- text). The `db.sqlite` produced from this schema lives in `<tmpdir>/` and is
-- transparently rebuilt from `data.sql` on demand. See KEYLOGGER_SPEC.md §1.
-- ============================================================================

PRAGMA foreign_keys = OFF;
PRAGMA journal_mode = DELETE;
PRAGMA synchronous = FULL;
PRAGMA encoding = "UTF-8";


-- ============================================================================
-- 1. METADATA AND DEVICE REGISTRY
-- ============================================================================

CREATE TABLE IF NOT EXISTS meta (
	key   TEXT PRIMARY KEY,
	value TEXT NOT NULL
);
-- Bootstrapped keys (managed by the keylogger ingest path):
--   schema_version            → current schema version (integer as text).
--   last_applied_data_sql_off → byte offset up to which the LOCAL device's
--                               data.sql has been ingested into db.sqlite.
--   rev                       → monotonic counter bumped on every successful
--                               ingest batch. Used by view_cache to detect
--                               staleness.

CREATE TABLE IF NOT EXISTS devices (
	device_id                  TEXT PRIMARY KEY,
	name                       TEXT NOT NULL,
	os                         TEXT NOT NULL CHECK (os IN ('darwin','windows')),
	os_version                 TEXT,
	host_signature             TEXT NOT NULL,
	created_at                 TEXT NOT NULL,
	updated_at                 TEXT NOT NULL,
	-- Watermark of the data.sql file under by_device/<device_id>/ that the
	-- LOCAL db.sqlite has already ingested. Tracked per device because the
	-- local sqlite cumulates events from every device's data.sql.
	imported_data_sql_size     INTEGER NOT NULL DEFAULT 0,
	imported_data_sql_sha256   TEXT
);


-- ============================================================================
-- 2. RAW EVENTS
--
-- One row per event recorded in today.log on the originating device. After
-- ingest, every row is also serialized as an INSERT statement in that
-- device's data.sql. Replaying data.sql on another machine reconstructs the
-- exact same rows on that machine's local db.sqlite.
--
-- Per-device autoincrement: the `id` column is unique per `device_id`. The
-- ingest pipeline assigns IDs sequentially while reading today.log so the
-- generated INSERTs are deterministic.
-- ============================================================================

CREATE TABLE IF NOT EXISTS events_typing (
	device_id          TEXT NOT NULL,
	id                 INTEGER NOT NULL,
	ts                 TEXT NOT NULL,                 -- "YYYY-MM-DD HH:MM:SS.mmm"
	date               TEXT NOT NULL,                 -- "YYYY-MM-DD" (denormalized for fast filtering)
	app                TEXT NOT NULL,
	title              TEXT,
	url                TEXT,
	field_role         TEXT,
	layout             TEXT,
	document_path      TEXT,
	is_fullscreen      INTEGER NOT NULL,
	in_meeting         INTEGER NOT NULL,
	mouse_clicks       INTEGER NOT NULL,
	mouse_scrolls      INTEGER NOT NULL,
	mouse_distance_px  INTEGER NOT NULL,
	pause_before_ms    INTEGER,
	battery_level      INTEGER,
	audio_volume       REAL,
	wpm                REAL,
	text               TEXT NOT NULL,
	rich_text          TEXT,
	events_json        TEXT NOT NULL,                 -- compact JSON of the per-keystroke array
	PRIMARY KEY (device_id, id)
);
CREATE INDEX IF NOT EXISTS idx_events_typing_date_app    ON events_typing(date, app);
CREATE INDEX IF NOT EXISTS idx_events_typing_device_date ON events_typing(device_id, date);

CREATE TABLE IF NOT EXISTS events_app_switch (
	device_id   TEXT NOT NULL,
	id          INTEGER NOT NULL,
	ts          TEXT NOT NULL,
	date        TEXT NOT NULL,
	prev_app    TEXT,
	next_app    TEXT,
	duration_ms INTEGER NOT NULL,
	PRIMARY KEY (device_id, id)
);
CREATE INDEX IF NOT EXISTS idx_events_app_switch_date ON events_app_switch(date);

CREATE TABLE IF NOT EXISTS events_window_switch (
	device_id   TEXT NOT NULL,
	id          INTEGER NOT NULL,
	ts          TEXT NOT NULL,
	date        TEXT NOT NULL,
	app         TEXT NOT NULL,
	prev_title  TEXT,
	next_title  TEXT,
	duration_ms INTEGER NOT NULL,
	PRIMARY KEY (device_id, id)
);

CREATE TABLE IF NOT EXISTS events_shortcut (
	device_id TEXT NOT NULL,
	id        INTEGER NOT NULL,
	ts        TEXT NOT NULL,
	date      TEXT NOT NULL,
	app       TEXT NOT NULL,
	key       TEXT NOT NULL,
	PRIMARY KEY (device_id, id)
);
CREATE INDEX IF NOT EXISTS idx_events_shortcut_date_app ON events_shortcut(date, app);

CREATE TABLE IF NOT EXISTS events_system (
	device_id     TEXT NOT NULL,
	id            INTEGER NOT NULL,
	ts            TEXT NOT NULL,
	date          TEXT NOT NULL,
	action        TEXT NOT NULL,                     -- sleep|wake|lock|unlock|wifi_change|power_change|audio_change|space_change|system_load
	metadata_json TEXT,
	PRIMARY KEY (device_id, id)
);
CREATE INDEX IF NOT EXISTS idx_events_system_date_action ON events_system(date, action);

CREATE TABLE IF NOT EXISTS events_hotstring (
	device_id        TEXT NOT NULL,
	id               INTEGER NOT NULL,
	ts               TEXT NOT NULL,
	date             TEXT NOT NULL,
	app              TEXT NOT NULL,
	kind             TEXT NOT NULL CHECK (kind IN ('fired','suggested','dismissed')),
	trigger          TEXT NOT NULL,
	replacement      TEXT NOT NULL,
	h_type           TEXT,
	net_saved_chars  INTEGER,
	PRIMARY KEY (device_id, id)
);
CREATE INDEX IF NOT EXISTS idx_events_hotstring_date_kind ON events_hotstring(date, kind);

CREATE TABLE IF NOT EXISTS events_llm (
	device_id            TEXT NOT NULL,
	id                   INTEGER NOT NULL,
	ts                   TEXT NOT NULL,
	date                 TEXT NOT NULL,
	app                  TEXT NOT NULL,
	kind                 TEXT NOT NULL CHECK (kind IN ('generation','suggested','dismissed','accepted')),
	context              TEXT,
	predictions_json     TEXT,
	prediction           TEXT,
	all_predictions_json TEXT,
	chosen_index         INTEGER,
	deletes              INTEGER,
	deleted_text         TEXT,
	net_saved_chars      INTEGER,
	count                INTEGER,
	PRIMARY KEY (device_id, id)
);
CREATE INDEX IF NOT EXISTS idx_events_llm_date_kind ON events_llm(date, kind);

CREATE TABLE IF NOT EXISTS events_session (
	device_id   TEXT NOT NULL,
	id          INTEGER NOT NULL,
	ts          TEXT NOT NULL,
	date        TEXT NOT NULL,
	kind        TEXT NOT NULL CHECK (kind IN ('session_start','session_end','idle_start','idle_end')),
	duration_ms INTEGER,
	PRIMARY KEY (device_id, id)
);

CREATE TABLE IF NOT EXISTS events_mouse (
	device_id   TEXT NOT NULL,
	id          INTEGER NOT NULL,
	ts          TEXT NOT NULL,
	date        TEXT NOT NULL,
	kind        TEXT NOT NULL,
	app         TEXT NOT NULL,
	meta_json   TEXT,
	PRIMARY KEY (device_id, id)
);
CREATE INDEX IF NOT EXISTS idx_events_mouse_date ON events_mouse(date);

CREATE TABLE IF NOT EXISTS events_ergo (
	device_id   TEXT NOT NULL,
	id          INTEGER NOT NULL,
	ts          TEXT NOT NULL,
	date        TEXT NOT NULL,
	kind        TEXT NOT NULL,
	app         TEXT NOT NULL,
	meta_json   TEXT,
	PRIMARY KEY (device_id, id)
);
CREATE INDEX IF NOT EXISTS idx_events_ergo_date ON events_ergo(date);

CREATE TABLE IF NOT EXISTS events_window_topo (
	device_id   TEXT NOT NULL,
	id          INTEGER NOT NULL,
	ts          TEXT NOT NULL,
	date        TEXT NOT NULL,
	kind        TEXT NOT NULL,
	app         TEXT NOT NULL,
	meta_json   TEXT,
	PRIMARY KEY (device_id, id)
);
CREATE INDEX IF NOT EXISTS idx_events_window_topo_date ON events_window_topo(date);


-- ============================================================================
-- 3. PRECOMPUTED AGGREGATES
--
-- One row per (device_id, date, app) (or finer) — UPSERTed on each ingest.
-- The dashboard queries these tables directly, never the raw events_*.
-- ============================================================================

CREATE TABLE IF NOT EXISTS agg_app_day (
	device_id      TEXT NOT NULL,
	date           TEXT NOT NULL,
	app            TEXT NOT NULL,
	chars          INTEGER NOT NULL DEFAULT 0,
	pauses         INTEGER NOT NULL DEFAULT 0,
	time_ms        INTEGER NOT NULL DEFAULT 0,
	think_time_ms  INTEGER NOT NULL DEFAULT 0,
	hs_chars       INTEGER NOT NULL DEFAULT 0,
	llm_chars      INTEGER NOT NULL DEFAULT 0,
	hs_triggers    INTEGER NOT NULL DEFAULT 0,
	llm_triggers   INTEGER NOT NULL DEFAULT 0,
	hs_suggested   INTEGER NOT NULL DEFAULT 0,
	llm_suggested  INTEGER NOT NULL DEFAULT 0,
	hs_input_chars INTEGER NOT NULL DEFAULT 0,
	llm_input_chars INTEGER NOT NULL DEFAULT 0,
	app_time_ms    INTEGER NOT NULL DEFAULT 0,
	category       TEXT,
	PRIMARY KEY (device_id, date, app)
);
CREATE INDEX IF NOT EXISTS idx_agg_app_day_date ON agg_app_day(date);
CREATE INDEX IF NOT EXISTS idx_agg_app_day_app  ON agg_app_day(app);

CREATE TABLE IF NOT EXISTS agg_app_day_buckets (
	device_id          TEXT NOT NULL,
	date               TEXT NOT NULL,
	app                TEXT NOT NULL,
	bucket_ms          INTEGER NOT NULL,             -- 1000 / 2000 / 3000 / 5000 / 10000 / 20000 / 30000 / 60000
	time_sum           INTEGER NOT NULL DEFAULT 0,
	credited           INTEGER NOT NULL DEFAULT 0,
	hs_input_time_sum  INTEGER NOT NULL DEFAULT 0,
	hs_input_credited  INTEGER NOT NULL DEFAULT 0,
	llm_input_time_sum INTEGER NOT NULL DEFAULT 0,
	llm_input_credited INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (device_id, date, app, bucket_ms)
);

CREATE TABLE IF NOT EXISTS agg_app_day_burst (
	device_id              TEXT NOT NULL,
	date                   TEXT NOT NULL,
	app                    TEXT NOT NULL,
	count_total            INTEGER NOT NULL DEFAULT 0,
	max_cpm                REAL NOT NULL DEFAULT 0,
	max_chars              INTEGER NOT NULL DEFAULT 0,
	length_buckets_json    TEXT NOT NULL DEFAULT '{}',
	inter_delay_count      INTEGER NOT NULL DEFAULT 0,
	inter_delay_sum        INTEGER NOT NULL DEFAULT 0,
	inter_delay_sumsq      INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (device_id, date, app)
);

CREATE TABLE IF NOT EXISTS agg_app_day_session (
	device_id        TEXT NOT NULL,
	date             TEXT NOT NULL,
	app              TEXT NOT NULL,
	count_total      INTEGER NOT NULL DEFAULT 0,
	longest_ms       INTEGER NOT NULL DEFAULT 0,
	longest_chars    INTEGER NOT NULL DEFAULT 0,
	total_active_ms  INTEGER NOT NULL DEFAULT 0,
	durations_json   TEXT NOT NULL DEFAULT '[]',     -- last 100 sessions
	PRIMARY KEY (device_id, date, app)
);

CREATE TABLE IF NOT EXISTS agg_app_day_chars_class (
	device_id       TEXT NOT NULL,
	date            TEXT NOT NULL,
	app             TEXT NOT NULL,
	letter          INTEGER NOT NULL DEFAULT 0,
	digit           INTEGER NOT NULL DEFAULT 0,
	punct           INTEGER NOT NULL DEFAULT 0,
	space           INTEGER NOT NULL DEFAULT 0,
	other           INTEGER NOT NULL DEFAULT 0,
	first_typed_min TEXT,                            -- "HH:MM"
	last_typed_min  TEXT,
	PRIMARY KEY (device_id, date, app)
);

CREATE TABLE IF NOT EXISTS agg_app_day_errors (
	device_id           TEXT NOT NULL,
	date                TEXT NOT NULL,
	app                 TEXT NOT NULL,
	bs_total            INTEGER NOT NULL DEFAULT 0,
	cascade_count       INTEGER NOT NULL DEFAULT 0,
	cascade_max_len     INTEGER NOT NULL DEFAULT 0,
	recovery_sum_ms     INTEGER NOT NULL DEFAULT 0,
	recovery_count      INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (device_id, date, app)
);

CREATE TABLE IF NOT EXISTS agg_app_day_ergo (
	device_id                 TEXT NOT NULL,
	date                      TEXT NOT NULL,
	app                       TEXT NOT NULL,
	same_finger_streak_max    INTEGER NOT NULL DEFAULT 0,
	same_hand_streak_max      INTEGER NOT NULL DEFAULT 0,
	auto_repeat_count         INTEGER NOT NULL DEFAULT 0,
	focus_to_first_key_sum_ms INTEGER NOT NULL DEFAULT 0,
	focus_to_first_key_count  INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (device_id, date, app)
);

CREATE TABLE IF NOT EXISTS agg_app_day_layouts (
	device_id TEXT NOT NULL,
	date      TEXT NOT NULL,
	app       TEXT NOT NULL,
	layout    TEXT NOT NULL,
	count     INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (device_id, date, app, layout)
);

CREATE TABLE IF NOT EXISTS agg_app_day_kc_hold (
	device_id  TEXT NOT NULL,
	date       TEXT NOT NULL,
	app        TEXT NOT NULL,
	keycode    INTEGER NOT NULL,
	sum_ms     INTEGER NOT NULL DEFAULT 0,
	count      INTEGER NOT NULL DEFAULT 0,
	max_ms     INTEGER NOT NULL DEFAULT 0,
	tap_count  INTEGER NOT NULL DEFAULT 0,
	hold_count INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (device_id, date, app, keycode)
);
CREATE INDEX IF NOT EXISTS idx_agg_app_day_kc_hold_keycode ON agg_app_day_kc_hold(keycode);

CREATE TABLE IF NOT EXISTS agg_app_day_titles (
	device_id TEXT NOT NULL,
	date      TEXT NOT NULL,
	app       TEXT NOT NULL,
	title     TEXT NOT NULL,
	c         INTEGER NOT NULL DEFAULT 0,
	ms        INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (device_id, date, app, title)
);
-- After each insert: if the (device_id, date, app) group has more than 100
-- rows, drop the lowest-(c+ms) entries to stay within cap. Logic lives in
-- the ingest pipeline.

CREATE TABLE IF NOT EXISTS agg_app_day_hourly (
	device_id      TEXT NOT NULL,
	date           TEXT NOT NULL,
	app            TEXT NOT NULL,
	hour           TEXT NOT NULL,                    -- "00".."23"
	c              INTEGER NOT NULL DEFAULT 0,
	e              INTEGER NOT NULL DEFAULT 0,
	em             INTEGER NOT NULL DEFAULT 0,
	es             INTEGER NOT NULL DEFAULT 0,
	e_buckets_json TEXT NOT NULL DEFAULT '{}',
	PRIMARY KEY (device_id, date, app, hour)
);

CREATE TABLE IF NOT EXISTS agg_app_day_hourly_min5 (
	device_id      TEXT NOT NULL,
	date           TEXT NOT NULL,
	app            TEXT NOT NULL,
	slot           TEXT NOT NULL,                    -- "HH:MM" 5-min step
	c              INTEGER NOT NULL DEFAULT 0,
	e              INTEGER NOT NULL DEFAULT 0,
	es             INTEGER NOT NULL DEFAULT 0,
	e_buckets_json TEXT NOT NULL DEFAULT '{}',
	PRIMARY KEY (device_id, date, app, slot)
);

CREATE TABLE IF NOT EXISTS agg_app_day_switches_to (
	device_id TEXT NOT NULL,
	date      TEXT NOT NULL,
	app_from  TEXT NOT NULL,
	app_to    TEXT NOT NULL,
	count     INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (device_id, date, app_from, app_to)
);

CREATE TABLE IF NOT EXISTS agg_system_day (
	device_id        TEXT NOT NULL,
	date             TEXT NOT NULL,
	wifi_changes     INTEGER NOT NULL DEFAULT 0,
	space_switches  INTEGER NOT NULL DEFAULT 0,
	battery_sum      INTEGER,
	battery_count    INTEGER,
	battery_min      INTEGER,
	battery_max      INTEGER,
	audio_muted_ms   INTEGER NOT NULL DEFAULT 0,
	locked_ms        INTEGER NOT NULL DEFAULT 0,
	sleep_ms         INTEGER NOT NULL DEFAULT 0,
	awake_ms         INTEGER NOT NULL DEFAULT 0,
	passive_count    INTEGER NOT NULL DEFAULT 0,
	night_wake_count INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (device_id, date)
);


-- ============================================================================
-- 4. N-GRAMS — split by token size for compact indexes and fast top-N queries
-- ============================================================================

CREATE TABLE IF NOT EXISTS ngram_chars (
	device_id TEXT NOT NULL,
	date      TEXT NOT NULL,
	app       TEXT NOT NULL,
	token     TEXT NOT NULL,
	c         INTEGER NOT NULL DEFAULT 0,
	td        INTEGER NOT NULL DEFAULT 0,
	cd        INTEGER NOT NULL DEFAULT 0,
	e         INTEGER NOT NULL DEFAULT 0,
	esrc_json TEXT NOT NULL DEFAULT '{}',
	PRIMARY KEY (device_id, date, app, token)
);
CREATE INDEX IF NOT EXISTS idx_ngram_chars_date_count ON ngram_chars(date, c DESC);

CREATE TABLE IF NOT EXISTS ngram_bigrams (
	device_id TEXT NOT NULL, date TEXT NOT NULL, app TEXT NOT NULL,
	token TEXT NOT NULL,
	c INTEGER NOT NULL DEFAULT 0,
	td INTEGER NOT NULL DEFAULT 0,
	cd INTEGER NOT NULL DEFAULT 0,
	e INTEGER NOT NULL DEFAULT 0,
	esrc_json TEXT NOT NULL DEFAULT '{}',
	PRIMARY KEY (device_id, date, app, token)
);
CREATE INDEX IF NOT EXISTS idx_ngram_bigrams_date_count ON ngram_bigrams(date, c DESC);

CREATE TABLE IF NOT EXISTS ngram_trigrams (
	device_id TEXT NOT NULL, date TEXT NOT NULL, app TEXT NOT NULL,
	token TEXT NOT NULL,
	c INTEGER NOT NULL DEFAULT 0,
	td INTEGER NOT NULL DEFAULT 0,
	cd INTEGER NOT NULL DEFAULT 0,
	e INTEGER NOT NULL DEFAULT 0,
	esrc_json TEXT NOT NULL DEFAULT '{}',
	PRIMARY KEY (device_id, date, app, token)
);
CREATE INDEX IF NOT EXISTS idx_ngram_trigrams_date_count ON ngram_trigrams(date, c DESC);

CREATE TABLE IF NOT EXISTS ngram_quadgrams (
	device_id TEXT NOT NULL, date TEXT NOT NULL, app TEXT NOT NULL,
	token TEXT NOT NULL,
	c INTEGER NOT NULL DEFAULT 0,
	td INTEGER NOT NULL DEFAULT 0,
	cd INTEGER NOT NULL DEFAULT 0,
	e INTEGER NOT NULL DEFAULT 0,
	esrc_json TEXT NOT NULL DEFAULT '{}',
	PRIMARY KEY (device_id, date, app, token)
);
CREATE INDEX IF NOT EXISTS idx_ngram_quadgrams_date_count ON ngram_quadgrams(date, c DESC);

CREATE TABLE IF NOT EXISTS ngram_pentagrams (
	device_id TEXT NOT NULL, date TEXT NOT NULL, app TEXT NOT NULL,
	token TEXT NOT NULL,
	c INTEGER NOT NULL DEFAULT 0,
	td INTEGER NOT NULL DEFAULT 0,
	cd INTEGER NOT NULL DEFAULT 0,
	e INTEGER NOT NULL DEFAULT 0,
	esrc_json TEXT NOT NULL DEFAULT '{}',
	PRIMARY KEY (device_id, date, app, token)
);
CREATE INDEX IF NOT EXISTS idx_ngram_pentagrams_date_count ON ngram_pentagrams(date, c DESC);

CREATE TABLE IF NOT EXISTS ngram_hexagrams (
	device_id TEXT NOT NULL, date TEXT NOT NULL, app TEXT NOT NULL,
	token TEXT NOT NULL,
	c INTEGER NOT NULL DEFAULT 0,
	td INTEGER NOT NULL DEFAULT 0,
	cd INTEGER NOT NULL DEFAULT 0,
	e INTEGER NOT NULL DEFAULT 0,
	esrc_json TEXT NOT NULL DEFAULT '{}',
	PRIMARY KEY (device_id, date, app, token)
);
CREATE INDEX IF NOT EXISTS idx_ngram_hexagrams_date_count ON ngram_hexagrams(date, c DESC);

CREATE TABLE IF NOT EXISTS ngram_heptagrams (
	device_id TEXT NOT NULL, date TEXT NOT NULL, app TEXT NOT NULL,
	token TEXT NOT NULL,
	c INTEGER NOT NULL DEFAULT 0,
	td INTEGER NOT NULL DEFAULT 0,
	cd INTEGER NOT NULL DEFAULT 0,
	e INTEGER NOT NULL DEFAULT 0,
	esrc_json TEXT NOT NULL DEFAULT '{}',
	PRIMARY KEY (device_id, date, app, token)
);
CREATE INDEX IF NOT EXISTS idx_ngram_heptagrams_date_count ON ngram_heptagrams(date, c DESC);

CREATE TABLE IF NOT EXISTS ngram_words (
	device_id TEXT NOT NULL, date TEXT NOT NULL, app TEXT NOT NULL,
	token TEXT NOT NULL,
	c INTEGER NOT NULL DEFAULT 0,
	td INTEGER NOT NULL DEFAULT 0,
	cd INTEGER NOT NULL DEFAULT 0,
	e INTEGER NOT NULL DEFAULT 0,
	esrc_json TEXT NOT NULL DEFAULT '{}',
	PRIMARY KEY (device_id, date, app, token)
);
CREATE INDEX IF NOT EXISTS idx_ngram_words_date_count ON ngram_words(date, c DESC);

CREATE TABLE IF NOT EXISTS ngram_word_bigrams (
	device_id TEXT NOT NULL, date TEXT NOT NULL, app TEXT NOT NULL,
	token TEXT NOT NULL,
	c INTEGER NOT NULL DEFAULT 0,
	td INTEGER NOT NULL DEFAULT 0,
	cd INTEGER NOT NULL DEFAULT 0,
	e INTEGER NOT NULL DEFAULT 0,
	esrc_json TEXT NOT NULL DEFAULT '{}',
	PRIMARY KEY (device_id, date, app, token)
);
CREATE INDEX IF NOT EXISTS idx_ngram_word_bigrams_date_count ON ngram_word_bigrams(date, c DESC);

CREATE TABLE IF NOT EXISTS ngram_shortcuts (
	device_id TEXT NOT NULL,
	date      TEXT NOT NULL,
	app       TEXT NOT NULL,
	token     TEXT NOT NULL,
	c         INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (device_id, date, app, token)
);

CREATE TABLE IF NOT EXISTS ngram_shortcut_bigrams (
	device_id TEXT NOT NULL,
	date      TEXT NOT NULL,
	app       TEXT NOT NULL,
	token     TEXT NOT NULL,
	c         INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (device_id, date, app, token)
);

CREATE TABLE IF NOT EXISTS ngram_keycodes (
	device_id TEXT NOT NULL,
	date      TEXT NOT NULL,
	app       TEXT NOT NULL,
	keycode   INTEGER NOT NULL,
	c         INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (device_id, date, app, keycode)
);

-- Hardware scancodes — populated by the Windows/AHK driver. Layout-
-- independent (a given physical key always reports the same scancode
-- regardless of the active keyboard layout), which is what the heatmap
-- needs to colour the correct physical position.
CREATE TABLE IF NOT EXISTS ngram_scancodes (
	device_id TEXT NOT NULL,
	date      TEXT NOT NULL,
	app       TEXT NOT NULL,
	scancode  INTEGER NOT NULL,
	c         INTEGER NOT NULL DEFAULT 0,
	PRIMARY KEY (device_id, date, app, scancode)
);


-- ============================================================================
-- 5. VIEW CACHE
--
-- Precomputed JSON projections for the dashboard. Invalidated on each ingest
-- batch (entries depending on today) or at day rollover (everything).
-- See KEYLOGGER_SPEC.md §18.
-- ============================================================================

CREATE TABLE IF NOT EXISTS view_cache (
	cache_key        TEXT PRIMARY KEY,
	computed_at      TEXT NOT NULL,
	data_json        TEXT NOT NULL,
	depends_on_today INTEGER NOT NULL DEFAULT 0,
	size_bytes       INTEGER NOT NULL,
	rev              INTEGER NOT NULL                -- snapshot of meta.rev at compute time
);
CREATE INDEX IF NOT EXISTS idx_view_cache_today ON view_cache(depends_on_today);
CREATE INDEX IF NOT EXISTS idx_view_cache_size  ON view_cache(size_bytes DESC);


-- ============================================================================
-- Initial bootstrap of the meta table. The keylogger updates these values
-- after applying migrations and on each ingest batch.
-- ============================================================================

INSERT OR IGNORE INTO meta (key, value) VALUES ('schema_version',            '1');
INSERT OR IGNORE INTO meta (key, value) VALUES ('last_applied_data_sql_off', '0');
INSERT OR IGNORE INTO meta (key, value) VALUES ('rev',                       '0');
