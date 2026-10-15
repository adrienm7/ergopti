-- _shared/data/db/media_schema.sql
-- Additive projections for admitted semantic media events. Numeric keyboard
-- tables and their historical virtual keycodes/scancodes remain unchanged.
-- This closed set is an independent persistence boundary, checked against the
-- reviewed catalogue by behavioral controls; mapping grants no native authority.
CREATE TABLE IF NOT EXISTS ngram_media_keys (
    device_id TEXT NOT NULL,
    date TEXT NOT NULL,
    app TEXT NOT NULL,
    media_id TEXT NOT NULL CHECK (media_id IN (
        'media.play_pause', 'media.next_track', 'media.previous_track',
        'media.brightness_up', 'media.brightness_down')),
    c INTEGER NOT NULL CHECK (typeof(c) = 'integer' AND c BETWEEN 1 AND 9007199254740991),
    PRIMARY KEY (device_id, date, app, media_id)
);
CREATE TABLE IF NOT EXISTS agg_app_day_media_hold (
    device_id TEXT NOT NULL,
    date TEXT NOT NULL,
    app TEXT NOT NULL,
    media_id TEXT NOT NULL CHECK (media_id IN (
        'media.play_pause', 'media.next_track', 'media.previous_track',
        'media.brightness_up', 'media.brightness_down')),
    sum_ms INTEGER NOT NULL CHECK (typeof(sum_ms) = 'integer' AND sum_ms BETWEEN 0 AND 9007199254740991),
    count INTEGER NOT NULL CHECK (typeof(count) = 'integer' AND count BETWEEN 1 AND 9007199254740991),
    max_ms INTEGER NOT NULL CHECK (typeof(max_ms) = 'integer' AND max_ms BETWEEN 0 AND 9223372036854),
    tap_count INTEGER NOT NULL CHECK (typeof(tap_count) = 'integer' AND tap_count BETWEEN 0 AND 9007199254740991),
    hold_count INTEGER NOT NULL CHECK (typeof(hold_count) = 'integer' AND hold_count BETWEEN 0 AND 9007199254740991),
    CHECK (tap_count + hold_count = count AND sum_ms >= max_ms),
    PRIMARY KEY (device_id, date, app, media_id)
);
