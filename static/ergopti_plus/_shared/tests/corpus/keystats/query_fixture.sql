-- _shared/tests/corpus/keystats/query_fixture.sql
--
-- Realistic keystats rows for the named-query catalogue proof
-- (tools/test/test-keystats-query-catalogue.cjs). Applied after schema.sql and
-- media_schema.sql. Two devices sync into one database over three days; one
-- application name carries a quote, an accent and a NUL byte so the CLI
-- transport (json_quote) is exercised; identical JSON blobs on both devices
-- check that grouping keeps their multiplicity; a device without a battery
-- stores zero extrema that must not become the day's minimum.

INSERT INTO agg_app_day VALUES
	('mac', '2026-10-01', 'Code', 1200, 4, 300000, 9000, 40, 12, 5, 2, 7, 3, 9, 4, 3600000, 'Development'),
	('pc', '2026-10-01', 'Code', 800, 2, 200000, 4000, 10, 0, 2, 0, 3, 0, 3, 0, 1800000, NULL),
	('mac', '2026-10-01', 'Wörd''s ' || char(0) || 'x', 50, 0, 9000, 0, 0, 0, 0, 0, 0, 0, 0, 0, 60000, 'Writing'),
	('pc', '2026-10-02', 'Code', 300, 1, 80000, 2500, 0, 0, 0, 0, 0, 0, 0, 0, 900000, 'Development'),
	('mac', '2026-10-03', 'Mail', 90, 0, 21000, 0, 0, 5, 0, 1, 0, 2, 0, 1, 120000, 'Communication');

INSERT INTO agg_app_day_buckets VALUES
	('mac', '2026-10-01', 'Code', 1000, 250000, 1100, 900, 9, 400, 4),
	('pc', '2026-10-01', 'Code', 1000, 150000, 700, 300, 3, 0, 0),
	('mac', '2026-10-01', 'Code', 2000, 290000, 1180, 900, 9, 400, 4),
	('pc', '2026-10-02', 'Code', 1000, 70000, 280, 0, 0, 0, 0),
	('mac', '2026-10-01', 'Wörd''s ' || char(0) || 'x', 1000, 9000, 50, 0, 0, 0, 0);

INSERT INTO agg_app_day_burst VALUES
	('mac', '2026-10-01', 'Code', 30, 420.5, 180, '{"10":20,"50":10}', 600, 90000, 15000000),
	('pc', '2026-10-01', 'Code', 12, 380.25, 90, '{"10":20,"50":10}', 300, 50000, 9000000),
	('mac', '2026-10-02', 'Code', 4, 300, 40, '{"5":4}', 60, 9000, 1500000),
	('mac', '2026-10-01', 'Wörd''s ' || char(0) || 'x', 2, 200, 20, '{"20":2}', 30, 4000, 600000);

INSERT INTO agg_app_day_session VALUES
	('mac', '2026-10-01', 'Code', 3, 1800000, 900, 2600000, '[600000,1800000,200000]'),
	('pc', '2026-10-01', 'Code', 2, 1200000, 700, 1500000, '[1200000,300000]'),
	('mac', '2026-10-03', 'Mail', 1, 60000, 90, 60000, '[60000]');

INSERT INTO agg_app_day_chars_class VALUES
	('mac', '2026-10-01', 'Code', 900, 120, 100, 70, 10, '08:05', '18:40'),
	('pc', '2026-10-01', 'Code', 600, 80, 60, 50, 10, '07:55', '17:10'),
	('pc', '2026-10-02', 'Code', 200, 50, 30, 20, 0, NULL, NULL),
	('mac', '2026-10-01', 'Wörd''s ' || char(0) || 'x', 40, 0, 5, 5, 0, '12:00', '12:05');

INSERT INTO agg_app_day_errors VALUES
	('mac', '2026-10-01', 'Code', 40, 3, 7, 12000, 30),
	('pc', '2026-10-01', 'Code', 25, 2, 9, 8000, 20),
	('mac', '2026-10-03', 'Mail', 2, 0, 0, 900, 2);

INSERT INTO agg_app_day_ergo VALUES
	('mac', '2026-10-01', 'Code', 5, 11, 3, 4200, 6),
	('pc', '2026-10-01', 'Code', 7, 9, 1, 0, 0),
	('mac', '2026-10-03', 'Mail', 2, 4, 0, 800, 1);

INSERT INTO agg_app_day_layouts VALUES
	('mac', '2026-10-01', 'Code', 'ergopti', 1100),
	('pc', '2026-10-01', 'Code', 'ergopti', 790),
	('pc', '2026-10-01', 'Code', 'azerty', 10),
	('mac', '2026-10-01', 'Wörd''s ' || char(0) || 'x', 'ergopti' || char(0) || 'plus', 50);

INSERT INTO agg_app_day_kc_hold VALUES
	('mac', '2026-10-01', 'Code', 56, 9000, 40, 900, 30, 10),
	('pc', '2026-10-01', 'Code', 56, 4000, 20, 1200, 18, 2),
	('mac', '2026-10-03', 'Mail', 58, 300, 2, 200, 2, 0);

INSERT INTO ngram_media_keys VALUES
	('mac', '2026-10-01', 'Code', 'media.play_pause', 3),
	('pc', '2026-10-01', 'Code', 'media.play_pause', 2),
	('mac', '2026-10-03', 'Mail', 'media.next_track', 1);

INSERT INTO agg_app_day_media_hold VALUES
	('mac', '2026-10-01', 'Code', 'media.play_pause', 600, 3, 300, 2, 1),
	('pc', '2026-10-01', 'Code', 'media.play_pause', 900, 2, 700, 1, 1);

INSERT INTO agg_app_day_titles VALUES
	('mac', '2026-10-01', 'Code', 'main.lua — ergopti', 400, 900000),
	('pc', '2026-10-01', 'Code', 'main.lua — ergopti', 100, 300000),
	('pc', '2026-10-01', 'Code', 'O''Brien' || char(0) || ' notes', 5, 1000),
	('mac', '2026-10-03', 'Mail', 'Inbox', 90, 120000);

INSERT INTO agg_app_day_hourly VALUES
	('mac', '2026-10-01', 'Code', '09', 500, 12, 10, 2, '{"1000":8,"2000":2}'),
	('pc', '2026-10-01', 'Code', '09', 300, 12, 10, 2, '{"1000":8,"2000":2}'),
	('pc', '2026-10-01', 'Code', '14', 200, 4, 4, 0, '{"1000":4}'),
	('mac', '2026-10-03', 'Mail', '11', 90, 2, 2, 0, '{}');

INSERT INTO agg_app_day_hourly_min5 VALUES
	('mac', '2026-10-01', 'Code', '09:05', 120, 3, 1, '{"1000":3}'),
	('pc', '2026-10-01', 'Code', '09:05', 80, 3, 1, '{"1000":3}'),
	('pc', '2026-10-01', 'Code', '14:30', 50, 1, 0, '{"2000":1}'),
	('mac', '2026-10-03', 'Mail', '11:00', 90, 2, 0, '{}');

INSERT INTO agg_app_day_switches_to VALUES
	('mac', '2026-10-01', 'Code', 'Mail', 12),
	('pc', '2026-10-01', 'Code', 'Mail', 3),
	('mac', '2026-10-01', 'Code', 'Wörd''s ' || char(0) || 'x', 2),
	('mac', '2026-10-03', 'Mail', 'Code', 1);

INSERT INTO agg_system_day VALUES
	('mac', '2026-10-01', 3, 7, 4200, 60, 22, 98, 600000, 3600000, 28800000, 50400000, 4, 1),
	('pc', '2026-10-01', 1, 0, 0, 0, 0, 0, 0, 0, 0, 43200000, 0, 0),
	('pc', '2026-10-02', 0, 2, NULL, NULL, NULL, NULL, 0, 600000, 0, 30000000, 1, 0),
	('mac', '2026-10-03', 2, 1, 900, 10, 80, 95, 0, 0, 3600000, 20000000, 0, 0);
