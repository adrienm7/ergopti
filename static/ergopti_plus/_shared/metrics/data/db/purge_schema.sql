-- _shared/metrics/data/db/purge_schema.sql
--
-- ============================================================================
-- ERGOPTI METRICS — PURGE TOMBSTONES
--
-- The dashboard's Purge removes the metrics on every device (maintainer
-- decision 2026-11-06). The owning writer appends one dated tombstone, an
-- events_system row whose action is 'metrics_purge', to its append-only
-- ledger. Every store applies it here, in SQLite, so the local writer, the
-- local replay and every foreign-ledger importer share one rule:
--   * inserting a tombstone deletes every raw row up to its instant, on every
--     device, and every derived row up to its date;
--   * a raw row not later than the newest tombstone is ignored, so a sibling
--     device's ledger replayed afterwards never brings a purged row back.
-- The tombstone carries its instant in UTC under metadata_json.utc. A row in
-- UTC (one with utc_offset_min, every row since the maintainer decision KMD-1
-- of 2026-11-11, or an older row of a device registered as 'linux') is
-- compared with that one; an older macOS or Windows row held local time and is
-- compared with the tombstone's local time (its ts, plus its own offset when
-- it has one). Each driver runs this file after schema.sql and
-- media_schema.sql on every open; every statement is idempotent. Derived rows
-- of the purge day that a later flush adds back stay.
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_events_system_action_ts ON events_system(action, ts);

CREATE TRIGGER IF NOT EXISTS metrics_purge_apply AFTER INSERT ON events_system
WHEN NEW.action = 'metrics_purge'
BEGIN
	DELETE FROM events_typing WHERE ts <= CASE WHEN utc_offset_min IS NOT NULL OR device_id IN (SELECT device_id FROM devices WHERE os = 'linux') THEN json_extract(NEW.metadata_json, '$.utc') ELSE CASE WHEN NEW.utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', NEW.ts, printf('%+d minutes', NEW.utc_offset_min)) ELSE NEW.ts END END;
	DELETE FROM events_app_switch WHERE ts <= CASE WHEN utc_offset_min IS NOT NULL OR device_id IN (SELECT device_id FROM devices WHERE os = 'linux') THEN json_extract(NEW.metadata_json, '$.utc') ELSE CASE WHEN NEW.utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', NEW.ts, printf('%+d minutes', NEW.utc_offset_min)) ELSE NEW.ts END END;
	DELETE FROM events_window_switch WHERE ts <= CASE WHEN utc_offset_min IS NOT NULL OR device_id IN (SELECT device_id FROM devices WHERE os = 'linux') THEN json_extract(NEW.metadata_json, '$.utc') ELSE CASE WHEN NEW.utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', NEW.ts, printf('%+d minutes', NEW.utc_offset_min)) ELSE NEW.ts END END;
	DELETE FROM events_shortcut WHERE ts <= CASE WHEN utc_offset_min IS NOT NULL OR device_id IN (SELECT device_id FROM devices WHERE os = 'linux') THEN json_extract(NEW.metadata_json, '$.utc') ELSE CASE WHEN NEW.utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', NEW.ts, printf('%+d minutes', NEW.utc_offset_min)) ELSE NEW.ts END END;
	DELETE FROM events_system WHERE ts <= CASE WHEN utc_offset_min IS NOT NULL OR device_id IN (SELECT device_id FROM devices WHERE os = 'linux') THEN json_extract(NEW.metadata_json, '$.utc') ELSE CASE WHEN NEW.utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', NEW.ts, printf('%+d minutes', NEW.utc_offset_min)) ELSE NEW.ts END END AND action <> 'metrics_purge';
	DELETE FROM events_hotstring WHERE ts <= CASE WHEN utc_offset_min IS NOT NULL OR device_id IN (SELECT device_id FROM devices WHERE os = 'linux') THEN json_extract(NEW.metadata_json, '$.utc') ELSE CASE WHEN NEW.utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', NEW.ts, printf('%+d minutes', NEW.utc_offset_min)) ELSE NEW.ts END END;
	DELETE FROM events_llm WHERE ts <= CASE WHEN utc_offset_min IS NOT NULL OR device_id IN (SELECT device_id FROM devices WHERE os = 'linux') THEN json_extract(NEW.metadata_json, '$.utc') ELSE CASE WHEN NEW.utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', NEW.ts, printf('%+d minutes', NEW.utc_offset_min)) ELSE NEW.ts END END;
	DELETE FROM events_session WHERE ts <= CASE WHEN utc_offset_min IS NOT NULL OR device_id IN (SELECT device_id FROM devices WHERE os = 'linux') THEN json_extract(NEW.metadata_json, '$.utc') ELSE CASE WHEN NEW.utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', NEW.ts, printf('%+d minutes', NEW.utc_offset_min)) ELSE NEW.ts END END;
	DELETE FROM events_mouse WHERE ts <= CASE WHEN utc_offset_min IS NOT NULL OR device_id IN (SELECT device_id FROM devices WHERE os = 'linux') THEN json_extract(NEW.metadata_json, '$.utc') ELSE CASE WHEN NEW.utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', NEW.ts, printf('%+d minutes', NEW.utc_offset_min)) ELSE NEW.ts END END;
	DELETE FROM events_ergo WHERE ts <= CASE WHEN utc_offset_min IS NOT NULL OR device_id IN (SELECT device_id FROM devices WHERE os = 'linux') THEN json_extract(NEW.metadata_json, '$.utc') ELSE CASE WHEN NEW.utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', NEW.ts, printf('%+d minutes', NEW.utc_offset_min)) ELSE NEW.ts END END;
	DELETE FROM events_window_topo WHERE ts <= CASE WHEN utc_offset_min IS NOT NULL OR device_id IN (SELECT device_id FROM devices WHERE os = 'linux') THEN json_extract(NEW.metadata_json, '$.utc') ELSE CASE WHEN NEW.utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', NEW.ts, printf('%+d minutes', NEW.utc_offset_min)) ELSE NEW.ts END END;
	DELETE FROM events_av WHERE ts <= CASE WHEN utc_offset_min IS NOT NULL OR device_id IN (SELECT device_id FROM devices WHERE os = 'linux') THEN json_extract(NEW.metadata_json, '$.utc') ELSE CASE WHEN NEW.utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', NEW.ts, printf('%+d minutes', NEW.utc_offset_min)) ELSE NEW.ts END END;
	DELETE FROM events_network WHERE ts <= CASE WHEN utc_offset_min IS NOT NULL OR device_id IN (SELECT device_id FROM devices WHERE os = 'linux') THEN json_extract(NEW.metadata_json, '$.utc') ELSE CASE WHEN NEW.utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', NEW.ts, printf('%+d minutes', NEW.utc_offset_min)) ELSE NEW.ts END END;
	DELETE FROM events_clipboard WHERE ts <= CASE WHEN utc_offset_min IS NOT NULL OR device_id IN (SELECT device_id FROM devices WHERE os = 'linux') THEN json_extract(NEW.metadata_json, '$.utc') ELSE CASE WHEN NEW.utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', NEW.ts, printf('%+d minutes', NEW.utc_offset_min)) ELSE NEW.ts END END;
	DELETE FROM events_roi WHERE ts <= CASE WHEN utc_offset_min IS NOT NULL OR device_id IN (SELECT device_id FROM devices WHERE os = 'linux') THEN json_extract(NEW.metadata_json, '$.utc') ELSE CASE WHEN NEW.utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', NEW.ts, printf('%+d minutes', NEW.utc_offset_min)) ELSE NEW.ts END END;
	DELETE FROM agg_app_day WHERE date <= NEW.date;
	DELETE FROM agg_app_day_buckets WHERE date <= NEW.date;
	DELETE FROM agg_app_day_burst WHERE date <= NEW.date;
	DELETE FROM agg_app_day_session WHERE date <= NEW.date;
	DELETE FROM agg_app_day_chars_class WHERE date <= NEW.date;
	DELETE FROM agg_app_day_errors WHERE date <= NEW.date;
	DELETE FROM agg_app_day_ergo WHERE date <= NEW.date;
	DELETE FROM agg_app_day_layouts WHERE date <= NEW.date;
	DELETE FROM agg_app_day_kc_hold WHERE date <= NEW.date;
	DELETE FROM agg_app_day_titles WHERE date <= NEW.date;
	DELETE FROM agg_app_day_hourly WHERE date <= NEW.date;
	DELETE FROM agg_app_day_hourly_min5 WHERE date <= NEW.date;
	DELETE FROM agg_app_day_switches_to WHERE date <= NEW.date;
	DELETE FROM agg_system_day WHERE date <= NEW.date;
	DELETE FROM ngram_chars WHERE date <= NEW.date;
	DELETE FROM ngram_bigrams WHERE date <= NEW.date;
	DELETE FROM ngram_trigrams WHERE date <= NEW.date;
	DELETE FROM ngram_quadgrams WHERE date <= NEW.date;
	DELETE FROM ngram_pentagrams WHERE date <= NEW.date;
	DELETE FROM ngram_hexagrams WHERE date <= NEW.date;
	DELETE FROM ngram_heptagrams WHERE date <= NEW.date;
	DELETE FROM ngram_words WHERE date <= NEW.date;
	DELETE FROM ngram_word_bigrams WHERE date <= NEW.date;
	DELETE FROM ngram_shortcuts WHERE date <= NEW.date;
	DELETE FROM ngram_shortcut_bigrams WHERE date <= NEW.date;
	DELETE FROM ngram_keycodes WHERE date <= NEW.date;
	DELETE FROM ngram_scancodes WHERE date <= NEW.date;
	DELETE FROM ngram_media_keys WHERE date <= NEW.date;
	DELETE FROM agg_app_day_media_hold WHERE date <= NEW.date;
	DELETE FROM view_cache;
END;

CREATE TRIGGER IF NOT EXISTS metrics_purge_guard_typing BEFORE INSERT ON events_typing
WHEN NEW.ts <= (SELECT max(CASE WHEN NEW.utc_offset_min IS NOT NULL OR (SELECT os FROM devices WHERE device_id = NEW.device_id) = 'linux' THEN json_extract(metadata_json, '$.utc') ELSE CASE WHEN utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', ts, printf('%+d minutes', utc_offset_min)) ELSE ts END END) FROM events_system WHERE action = 'metrics_purge')
BEGIN SELECT RAISE(IGNORE); END;

CREATE TRIGGER IF NOT EXISTS metrics_purge_guard_app_switch BEFORE INSERT ON events_app_switch
WHEN NEW.ts <= (SELECT max(CASE WHEN NEW.utc_offset_min IS NOT NULL OR (SELECT os FROM devices WHERE device_id = NEW.device_id) = 'linux' THEN json_extract(metadata_json, '$.utc') ELSE CASE WHEN utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', ts, printf('%+d minutes', utc_offset_min)) ELSE ts END END) FROM events_system WHERE action = 'metrics_purge')
BEGIN SELECT RAISE(IGNORE); END;

CREATE TRIGGER IF NOT EXISTS metrics_purge_guard_window_switch BEFORE INSERT ON events_window_switch
WHEN NEW.ts <= (SELECT max(CASE WHEN NEW.utc_offset_min IS NOT NULL OR (SELECT os FROM devices WHERE device_id = NEW.device_id) = 'linux' THEN json_extract(metadata_json, '$.utc') ELSE CASE WHEN utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', ts, printf('%+d minutes', utc_offset_min)) ELSE ts END END) FROM events_system WHERE action = 'metrics_purge')
BEGIN SELECT RAISE(IGNORE); END;

CREATE TRIGGER IF NOT EXISTS metrics_purge_guard_shortcut BEFORE INSERT ON events_shortcut
WHEN NEW.ts <= (SELECT max(CASE WHEN NEW.utc_offset_min IS NOT NULL OR (SELECT os FROM devices WHERE device_id = NEW.device_id) = 'linux' THEN json_extract(metadata_json, '$.utc') ELSE CASE WHEN utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', ts, printf('%+d minutes', utc_offset_min)) ELSE ts END END) FROM events_system WHERE action = 'metrics_purge')
BEGIN SELECT RAISE(IGNORE); END;

CREATE TRIGGER IF NOT EXISTS metrics_purge_guard_system BEFORE INSERT ON events_system
WHEN NEW.action <> 'metrics_purge' AND NEW.ts <= (SELECT max(CASE WHEN NEW.utc_offset_min IS NOT NULL OR (SELECT os FROM devices WHERE device_id = NEW.device_id) = 'linux' THEN json_extract(metadata_json, '$.utc') ELSE CASE WHEN utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', ts, printf('%+d minutes', utc_offset_min)) ELSE ts END END) FROM events_system WHERE action = 'metrics_purge')
BEGIN SELECT RAISE(IGNORE); END;

CREATE TRIGGER IF NOT EXISTS metrics_purge_guard_hotstring BEFORE INSERT ON events_hotstring
WHEN NEW.ts <= (SELECT max(CASE WHEN NEW.utc_offset_min IS NOT NULL OR (SELECT os FROM devices WHERE device_id = NEW.device_id) = 'linux' THEN json_extract(metadata_json, '$.utc') ELSE CASE WHEN utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', ts, printf('%+d minutes', utc_offset_min)) ELSE ts END END) FROM events_system WHERE action = 'metrics_purge')
BEGIN SELECT RAISE(IGNORE); END;

CREATE TRIGGER IF NOT EXISTS metrics_purge_guard_llm BEFORE INSERT ON events_llm
WHEN NEW.ts <= (SELECT max(CASE WHEN NEW.utc_offset_min IS NOT NULL OR (SELECT os FROM devices WHERE device_id = NEW.device_id) = 'linux' THEN json_extract(metadata_json, '$.utc') ELSE CASE WHEN utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', ts, printf('%+d minutes', utc_offset_min)) ELSE ts END END) FROM events_system WHERE action = 'metrics_purge')
BEGIN SELECT RAISE(IGNORE); END;

CREATE TRIGGER IF NOT EXISTS metrics_purge_guard_session BEFORE INSERT ON events_session
WHEN NEW.ts <= (SELECT max(CASE WHEN NEW.utc_offset_min IS NOT NULL OR (SELECT os FROM devices WHERE device_id = NEW.device_id) = 'linux' THEN json_extract(metadata_json, '$.utc') ELSE CASE WHEN utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', ts, printf('%+d minutes', utc_offset_min)) ELSE ts END END) FROM events_system WHERE action = 'metrics_purge')
BEGIN SELECT RAISE(IGNORE); END;

CREATE TRIGGER IF NOT EXISTS metrics_purge_guard_mouse BEFORE INSERT ON events_mouse
WHEN NEW.ts <= (SELECT max(CASE WHEN NEW.utc_offset_min IS NOT NULL OR (SELECT os FROM devices WHERE device_id = NEW.device_id) = 'linux' THEN json_extract(metadata_json, '$.utc') ELSE CASE WHEN utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', ts, printf('%+d minutes', utc_offset_min)) ELSE ts END END) FROM events_system WHERE action = 'metrics_purge')
BEGIN SELECT RAISE(IGNORE); END;

CREATE TRIGGER IF NOT EXISTS metrics_purge_guard_ergo BEFORE INSERT ON events_ergo
WHEN NEW.ts <= (SELECT max(CASE WHEN NEW.utc_offset_min IS NOT NULL OR (SELECT os FROM devices WHERE device_id = NEW.device_id) = 'linux' THEN json_extract(metadata_json, '$.utc') ELSE CASE WHEN utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', ts, printf('%+d minutes', utc_offset_min)) ELSE ts END END) FROM events_system WHERE action = 'metrics_purge')
BEGIN SELECT RAISE(IGNORE); END;

CREATE TRIGGER IF NOT EXISTS metrics_purge_guard_window_topo BEFORE INSERT ON events_window_topo
WHEN NEW.ts <= (SELECT max(CASE WHEN NEW.utc_offset_min IS NOT NULL OR (SELECT os FROM devices WHERE device_id = NEW.device_id) = 'linux' THEN json_extract(metadata_json, '$.utc') ELSE CASE WHEN utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', ts, printf('%+d minutes', utc_offset_min)) ELSE ts END END) FROM events_system WHERE action = 'metrics_purge')
BEGIN SELECT RAISE(IGNORE); END;

CREATE TRIGGER IF NOT EXISTS metrics_purge_guard_av BEFORE INSERT ON events_av
WHEN NEW.ts <= (SELECT max(CASE WHEN NEW.utc_offset_min IS NOT NULL OR (SELECT os FROM devices WHERE device_id = NEW.device_id) = 'linux' THEN json_extract(metadata_json, '$.utc') ELSE CASE WHEN utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', ts, printf('%+d minutes', utc_offset_min)) ELSE ts END END) FROM events_system WHERE action = 'metrics_purge')
BEGIN SELECT RAISE(IGNORE); END;

CREATE TRIGGER IF NOT EXISTS metrics_purge_guard_network BEFORE INSERT ON events_network
WHEN NEW.ts <= (SELECT max(CASE WHEN NEW.utc_offset_min IS NOT NULL OR (SELECT os FROM devices WHERE device_id = NEW.device_id) = 'linux' THEN json_extract(metadata_json, '$.utc') ELSE CASE WHEN utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', ts, printf('%+d minutes', utc_offset_min)) ELSE ts END END) FROM events_system WHERE action = 'metrics_purge')
BEGIN SELECT RAISE(IGNORE); END;

CREATE TRIGGER IF NOT EXISTS metrics_purge_guard_clipboard BEFORE INSERT ON events_clipboard
WHEN NEW.ts <= (SELECT max(CASE WHEN NEW.utc_offset_min IS NOT NULL OR (SELECT os FROM devices WHERE device_id = NEW.device_id) = 'linux' THEN json_extract(metadata_json, '$.utc') ELSE CASE WHEN utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', ts, printf('%+d minutes', utc_offset_min)) ELSE ts END END) FROM events_system WHERE action = 'metrics_purge')
BEGIN SELECT RAISE(IGNORE); END;

CREATE TRIGGER IF NOT EXISTS metrics_purge_guard_roi BEFORE INSERT ON events_roi
WHEN NEW.ts <= (SELECT max(CASE WHEN NEW.utc_offset_min IS NOT NULL OR (SELECT os FROM devices WHERE device_id = NEW.device_id) = 'linux' THEN json_extract(metadata_json, '$.utc') ELSE CASE WHEN utc_offset_min IS NOT NULL THEN strftime('%Y-%m-%d %H:%M:%f', ts, printf('%+d minutes', utc_offset_min)) ELSE ts END END) FROM events_system WHERE action = 'metrics_purge')
BEGIN SELECT RAISE(IGNORE); END;
