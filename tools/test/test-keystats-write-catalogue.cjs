// tools/test/test-keystats-write-catalogue.cjs

/**
 * ==============================================================================
 * MODULE: Keystats Write-Catalogue Equivalence Test
 * DESCRIPTION:
 * Proves the typed-slot and keyed statements of `_shared/data/db/queries.sql`
 * against the SQL the macOS and Linux drivers used to build by hand. Each
 * migrated family is executed twice on a fresh database made from the canonical
 * schema, once through the legacy statements (kept below as reference text) and
 * once through the catalogue, and the rows they leave behind must be equal.
 *
 * FEATURES & RATIONALE:
 * 1. Results, not text. A spelling difference that stores the same rows is not a
 *    regression; a missing column, a NULL turned into an empty string or a
 *    merged map that drops a key is, and only the rows show it.
 * 2. One vector file for every renderer. The exact rendered text of each write
 *    statement, in both dialects, lives in write_query_vectors.json; this test
 *    pins the JS reference renderer to it and the Lua contract pins both
 *    drivers' generated renderer to it, so a Windows renderer can replay it.
 * 3. Coverage. Every catalogue statement that is not a filter-driven read must
 *    have a vector in each dialect, and every migrated family has an
 *    equivalence case.
 * 4. Intentional behaviour changes are listed in the case that proves them, so
 *    a reviewer reads the difference next to the evidence.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Codegen = require('../codegen/codegen-keystats-queries.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const VECTORS = path.join(SHARED, 'tests', 'corpus', 'keystats', 'write_query_vectors.json');

const silenced = process.emitWarning;
process.emitWarning = (warning, ...rest) =>
	String(warning).includes('SQLite is an experimental feature')
		? undefined
		: silenced(warning, ...rest);
const { DatabaseSync } = require('node:sqlite');
process.emitWarning = silenced;

let failures = 0;
function check(name, fn) {
	try {
		fn();
		console.log(`  ok  ${name}`);
	} catch (error) {
		failures++;
		console.error(`  FAIL  ${name}\n${error.stack}`);
	}
}

const queries = Codegen.parse(fs.readFileSync(path.join(ROOT, Codegen.SOURCE), 'utf8'));
const vectors = JSON.parse(fs.readFileSync(VECTORS, 'utf8')).vectors;

/** A fresh database made from the canonical schema. */
function freshDb() {
	const db = new DatabaseSync(':memory:');
	db.exec(fs.readFileSync(path.join(SHARED, 'data', 'db', 'schema.sql'), 'utf8'));
	db.exec(fs.readFileSync(path.join(SHARED, 'data', 'db', 'media_schema.sql'), 'utf8'));
	return db;
}

/** The legacy driver literal: a quoted value with the shared control-byte spelling. */
function legacyQuote(value) {
	return `'${String(value).replaceAll("'", "''").replaceAll('\r', "'||char(13)||'").replaceAll('\0', "'||char(0)||'")}'`;
}

/** Renders a catalogue statement the way the generated Lua renderer does. */
function catalogue(name, values = {}, dialect = 'native') {
	return Codegen.render(queries, name, dialect, values);
}

/** Every row of the given tables, in a stable order, as plain JSON. */
function dump(db, tables) {
	return Object.fromEntries(
		tables.map((table) => [
			table,
			JSON.parse(JSON.stringify(db.prepare(`SELECT * FROM ${table}`).all())).sort((a, b) =>
				JSON.stringify(a) < JSON.stringify(b) ? -1 : 1
			)
		])
	);
}

/**
 * Runs the same scenario through the legacy statements and the catalogue and
 * compares the rows they leave.
 * @param {string[]} tables - Tables to compare.
 * @param {(db: DatabaseSync) => void} legacy - Applies the legacy statements.
 * @param {(db: DatabaseSync) => void} current - Applies the catalogue statements.
 * @returns {object} The rows both produced.
 */
function equivalent(tables, legacy, current) {
	const before = freshDb();
	const after = freshDb();
	legacy(before);
	current(after);
	const old = dump(before, tables);
	assert.deepEqual(dump(after, tables), old);
	before.close();
	after.close();
	return old;
}

const WRITES = queries.filter(
	(query) => query.slots.size > 0 || !query.segments[0].literal.startsWith('SELECT')
);

check('the vectors render to the exact SQL the JS reference renderer produces', () => {
	for (const vector of vectors)
		assert.equal(catalogue(vector.name, vector.values, vector.dialect), vector.sql, vector.name);
});

check('every write and keyed statement has a vector in both dialects', () => {
	const seen = new Set(vectors.map((vector) => `${vector.name}/${vector.dialect}`));
	const missing = [];
	for (const query of WRITES)
		for (const dialect of Codegen.DIALECTS)
			if (!seen.has(`${query.name}/${dialect}`)) missing.push(`${query.name}/${dialect}`);
	assert.deepEqual(missing, []);
	for (const vector of vectors)
		assert.ok(
			WRITES.some((query) => query.name === vector.name),
			`${vector.name} is a write or keyed statement`
		);
});

check(
	'a slot refuses a missing, mistyped or non-finite value and accepts NULL where declared',
	() => {
		assert.throws(() => catalogue('meta.set', { key: 'k' }), TypeError);
		assert.throws(() => catalogue('meta.set', { key: 'k', value: 7 }), TypeError);
		const nullable = Codegen.parse('-- name: a.b\nSELECT {{s? v}}, {{i? n}} FROM t;\n');
		assert.equal(Codegen.render(nullable, 'a.b', 'native', {}), 'SELECT NULL, NULL FROM t;');
		assert.equal(
			Codegen.render(nullable, 'a.b', 'native', { v: 'x', n: 4.9 }),
			"SELECT 'x', 4 FROM t;"
		);
		const strict = Codegen.parse('-- name: a.b\nSELECT {{i n}} FROM t;\n');
		assert.throws(() => Codegen.render(strict, 'a.b', 'native', { n: Number.NaN }), TypeError);
		assert.throws(() => Codegen.render(strict, 'a.b', 'native', { n: '3' }), TypeError);
	}
);

check('the JSON number-map merge adds key by key and keeps keys of only one side', () => {
	const db = freshDb();
	db.exec('CREATE TABLE m (id INTEGER PRIMARY KEY, esrc_json TEXT)');
	const merged = Codegen.parse(
		'-- name: a.b\nINSERT INTO m (id, esrc_json) VALUES ({{i id}}, {{s doc}}) ON CONFLICT(id) DO UPDATE SET esrc_json = {{merge esrc_json}};\n'
	);
	const run = (id, doc) => db.exec(Codegen.render(merged, 'a.b', 'native', { id, doc }));
	run(1, '{"a":1,"b":2}');
	run(1, '{"b":3,"c":4,"we.ird\\"key":5}');
	run(1, '{}');
	const stored = JSON.parse(db.prepare('SELECT esrc_json FROM m WHERE id = 1').get().esrc_json);
	assert.deepEqual(stored, { a: 1, b: 5, c: 4, 'we.ird"key': 5 });
	db.exec('INSERT INTO m (id, esrc_json) VALUES (2, NULL)');
	run(2, '{"z":1}');
	assert.deepEqual(JSON.parse(db.prepare('SELECT esrc_json FROM m WHERE id = 2').get().esrc_json), {
		z: 1
	});
	db.close();
});

// ---------------------------------------------------------------------------
// Family: meta
// ---------------------------------------------------------------------------

check('meta: seed, set, upsert, get and the revision bump store the legacy rows', () => {
	const rows = equivalent(
		['meta'],
		(db) => {
			// macOS startup seed, set_meta (both drivers), Linux open-walk upsert and both
			// historical revision bumps (macOS TEXT cast, Linux integer cast).
			db.exec("INSERT OR IGNORE INTO meta (key, value) VALUES ('next_event_id', '1');");
			db.exec("INSERT OR IGNORE INTO meta (key, value) VALUES ('rev', '99');");
			db.exec(
				`INSERT OR REPLACE INTO meta (key, value) VALUES (${legacyQuote("k'1")}, ${legacyQuote('a\r\0b')});`
			);
			db.exec(
				`INSERT INTO meta(key,value) VALUES (${legacyQuote('open_walk:d')},${legacyQuote('[1]')}) ON CONFLICT(key) DO UPDATE SET value = excluded.value;`
			);
			db.exec(
				`INSERT INTO meta(key,value) VALUES (${legacyQuote('open_walk:d')},${legacyQuote('[2]')}) ON CONFLICT(key) DO UPDATE SET value = excluded.value;`
			);
			db.exec("UPDATE meta SET value=CAST(CAST(value AS INTEGER)+1 AS TEXT) WHERE key='rev';");
			db.exec("UPDATE meta SET value=CAST(value AS INTEGER)+1 WHERE key='rev';");
		},
		(db) => {
			db.exec(catalogue('meta.seed', { key: 'next_event_id', value: '1' }));
			db.exec(catalogue('meta.seed', { key: 'rev', value: '99' }));
			db.exec(catalogue('meta.set', { key: "k'1", value: 'a\r\0b' }));
			db.exec(catalogue('meta.upsert', { key: 'open_walk:d', value: '[1]' }));
			db.exec(catalogue('meta.upsert', { key: 'open_walk:d', value: '[2]' }));
			db.exec(catalogue('meta.rev_bump'));
			db.exec(catalogue('meta.rev_bump'));
		}
	);
	const rev = rows.meta.find((row) => row.key === 'rev');
	assert.equal(rev.value, '2', 'the seed kept the schema default and both bumps counted');
	const db = freshDb();
	db.exec(catalogue('meta.set', { key: 'k', value: 'v\0w' }));
	for (const dialect of Codegen.DIALECTS) {
		const row = db.prepare(catalogue('meta.get', { key: 'k' }, dialect)).get();
		// An in-process engine reads TEXT up to a NUL; the CLI dialect carries all of it.
		assert.equal(
			dialect === 'native' ? row.value : JSON.parse(row.value_json),
			dialect === 'native' ? 'v' : 'v\0w'
		);
	}
	db.close();
});

// ---------------------------------------------------------------------------
// Family: devices
// ---------------------------------------------------------------------------

const deviceValues = (updated, name = 'Mac') => ({
	device_id: "dev'1",
	name,
	os: 'darwin',
	os_version: '',
	host_signature: 'sig',
	created_at: '2026-10-01T00:00:00Z',
	updated_at: updated
});

/** The legacy Linux registration: upsert in one transaction. */
function legacyLinuxDevice(db, values) {
	const q = (v) => legacyQuote(v);
	db.exec(
		`INSERT INTO devices (device_id, name, os, os_version, host_signature, created_at, updated_at)
VALUES (${q(values.device_id)}, ${q(values.name)}, ${q(values.os)}, ${q(values.os_version)}, ${q(values.host_signature)}, ${q(values.created_at)}, ${q(values.updated_at)})
ON CONFLICT(device_id) DO UPDATE SET
  name = excluded.name,
  os = excluded.os,
  os_version = excluded.os_version,
  host_signature = excluded.host_signature,
  updated_at = excluded.updated_at;`
	);
}

check('devices: the catalogue upsert stores the rows the Linux registration stored', () => {
	const rows = equivalent(
		['devices'],
		(db) => {
			legacyLinuxDevice(db, deviceValues('2026-10-02T00:00:00Z'));
			db.exec(
				"UPDATE devices SET imported_data_sql_size = 4096, imported_data_sql_sha256 = 'abc' WHERE device_id = 'dev''1'"
			);
			legacyLinuxDevice(db, deviceValues('2026-10-03T00:00:00Z', 'Renamed\r'));
		},
		(db) => {
			db.exec(catalogue('devices.upsert', deviceValues('2026-10-02T00:00:00Z')));
			db.exec(
				"UPDATE devices SET imported_data_sql_size = 4096, imported_data_sql_sha256 = 'abc' WHERE device_id = 'dev''1'"
			);
			db.exec(catalogue('devices.upsert', deviceValues('2026-10-03T00:00:00Z', 'Renamed\r')));
		}
	);
	assert.equal(rows.devices[0].imported_data_sql_size, 4096, 'the ledger watermark survives');
	assert.equal(rows.devices[0].created_at, '2026-10-01T00:00:00Z', 'created_at survives');
});

check(
	'devices: macOS no longer replaces the row, so its ledger watermark survives a restart',
	() => {
		// Intentional change: the macOS startup used INSERT OR REPLACE, which deleted
		// imported_data_sql_size/sha256 at every start and made the foreign import begin
		// again. The catalogue upsert is what the Linux driver already ran.
		const legacy = freshDb();
		const current = freshDb();
		const replace = (db, updated) =>
			db.exec(
				`INSERT OR REPLACE INTO devices (device_id, name, os, os_version, host_signature, created_at, updated_at) VALUES ('d', 'Mac', 'darwin', '', 'sig', '2026-10-01T00:00:00Z', '${updated}')`
			);
		replace(legacy, '2026-10-02T00:00:00Z');
		current.exec(
			catalogue('devices.upsert', { ...deviceValues('2026-10-02T00:00:00Z'), device_id: 'd' })
		);
		for (const db of [legacy, current])
			db.exec("UPDATE devices SET imported_data_sql_size = 4096 WHERE device_id = 'd'");
		replace(legacy, '2026-10-03T00:00:00Z');
		current.exec(
			catalogue('devices.upsert', { ...deviceValues('2026-10-03T00:00:00Z'), device_id: 'd' })
		);
		assert.equal(legacy.prepare('SELECT imported_data_sql_size AS n FROM devices').get().n, 0);
		assert.equal(current.prepare('SELECT imported_data_sql_size AS n FROM devices').get().n, 4096);
		legacy.close();
		current.close();
	}
);

// ---------------------------------------------------------------------------
// Family: aggregate counters
// ---------------------------------------------------------------------------

/** The macOS literal helpers of aggregator/sql.lua: a quoted text and a floored integer. */
const sq = (value) => legacyQuote(value);
const iv = (value) => Math.floor(Number(value) || 0);
const KEY = { device_id: 'dev-1', date: '2026-10-01', app: "Code's\r" };

/** Legacy macOS statements, one builder per table (aggregator/sql.lua). */
const legacyMac = {
	app_day: (r) =>
		`INSERT INTO agg_app_day (device_id, date, app, chars, pauses, time_ms, think_time_ms, hs_chars, llm_chars, hs_triggers, llm_triggers, hs_suggested, llm_suggested, hs_input_chars, llm_input_chars, category) VALUES (${sq(KEY.device_id)},${sq(KEY.date)},${sq(KEY.app)},${iv(r.chars)},${iv(r.pauses)},${iv(r.time_ms)},${iv(r.think_time_ms)},${iv(r.hs_chars)},${iv(r.llm_chars)},${iv(r.hs_triggers)},${iv(r.llm_triggers)},${iv(r.hs_suggested)},${iv(r.llm_suggested)},${iv(r.hs_input_chars)},${iv(r.llm_input_chars)},${sq(r.category)}) ON CONFLICT(device_id, date, app) DO UPDATE SET chars=chars+excluded.chars,pauses=pauses+excluded.pauses,time_ms=time_ms+excluded.time_ms,think_time_ms=think_time_ms+excluded.think_time_ms,hs_chars=hs_chars+excluded.hs_chars,llm_chars=llm_chars+excluded.llm_chars,hs_triggers=hs_triggers+excluded.hs_triggers,llm_triggers=llm_triggers+excluded.llm_triggers,hs_suggested=hs_suggested+excluded.hs_suggested,llm_suggested=llm_suggested+excluded.llm_suggested,hs_input_chars=hs_input_chars+excluded.hs_input_chars,llm_input_chars=llm_input_chars+excluded.llm_input_chars,category=COALESCE(agg_app_day.category, excluded.category)`,
	app_time: (r) =>
		`INSERT INTO agg_app_day (device_id, date, app, app_time_ms, category) VALUES (${sq(KEY.device_id)},${sq(KEY.date)},${sq(KEY.app)},${iv(r.app_time_ms)},${sq(r.category)}) ON CONFLICT(device_id, date, app) DO UPDATE SET app_time_ms=app_time_ms+excluded.app_time_ms,category=COALESCE(agg_app_day.category, excluded.category)`,
	buckets: (r) =>
		`INSERT INTO agg_app_day_buckets (device_id, date, app, bucket_ms, time_sum, credited, hs_input_time_sum, hs_input_credited, llm_input_time_sum, llm_input_credited) VALUES (${sq(KEY.device_id)},${sq(KEY.date)},${sq(KEY.app)},${iv(r.bucket_ms)},${iv(r.time_sum)},${iv(r.credited)},${iv(r.hs_input_time_sum)},${iv(r.hs_input_credited)},${iv(r.llm_input_time_sum)},${iv(r.llm_input_credited)}) ON CONFLICT(device_id, date, app, bucket_ms) DO UPDATE SET time_sum=time_sum+excluded.time_sum,credited=credited+excluded.credited,hs_input_time_sum=hs_input_time_sum+excluded.hs_input_time_sum,hs_input_credited=hs_input_credited+excluded.hs_input_credited,llm_input_time_sum=llm_input_time_sum+excluded.llm_input_time_sum,llm_input_credited=llm_input_credited+excluded.llm_input_credited`,
	kc_hold: (r) =>
		`INSERT INTO agg_app_day_kc_hold (device_id, date, app, keycode, sum_ms, count, max_ms, tap_count, hold_count) VALUES (${sq(KEY.device_id)},${sq(KEY.date)},${sq(KEY.app)},${iv(r.keycode)},${iv(r.sum_ms)},${iv(r.count)},${iv(r.max_ms)},${iv(r.tap_count)},${iv(r.hold_count)}) ON CONFLICT(device_id, date, app, keycode) DO UPDATE SET sum_ms=sum_ms+excluded.sum_ms,count=count+excluded.count,max_ms=MAX(max_ms, excluded.max_ms),tap_count=tap_count+excluded.tap_count,hold_count=hold_count+excluded.hold_count`,
	layouts: (r) =>
		`INSERT INTO agg_app_day_layouts (device_id, date, app, layout, count) VALUES (${sq(KEY.device_id)},${sq(KEY.date)},${sq(KEY.app)},${sq(r.layout)},${iv(r.count)}) ON CONFLICT(device_id, date, app, layout) DO UPDATE SET count=count+excluded.count`,
	switches_to: (r) =>
		`INSERT INTO agg_app_day_switches_to (device_id, date, app_from, app_to, count) VALUES (${sq(KEY.device_id)},${sq(KEY.date)},${sq(r.app_from)},${sq(r.app_to)},${iv(r.count)}) ON CONFLICT(device_id, date, app_from, app_to) DO UPDATE SET count=count+excluded.count`,
	errors: (r) =>
		`INSERT INTO agg_app_day_errors (device_id, date, app, bs_total, cascade_count, cascade_max_len, recovery_sum_ms, recovery_count) VALUES (${sq(KEY.device_id)},${sq(KEY.date)},${sq(KEY.app)},${iv(r.bs_total)},${iv(r.cascade_count)},${iv(r.cascade_max_len)},${iv(r.recovery_sum_ms)},${iv(r.recovery_count)}) ON CONFLICT(device_id, date, app) DO UPDATE SET bs_total=bs_total+excluded.bs_total,cascade_count=cascade_count+excluded.cascade_count,cascade_max_len=MAX(cascade_max_len, excluded.cascade_max_len),recovery_sum_ms=recovery_sum_ms+excluded.recovery_sum_ms,recovery_count=recovery_count+excluded.recovery_count`,
	ergo: (r) =>
		`INSERT INTO agg_app_day_ergo (device_id, date, app, same_finger_streak_max, same_hand_streak_max, auto_repeat_count, focus_to_first_key_sum_ms, focus_to_first_key_count) VALUES (${sq(KEY.device_id)},${sq(KEY.date)},${sq(KEY.app)},${iv(r.same_finger_streak_max)},${iv(r.same_hand_streak_max)},${iv(r.auto_repeat_count)},${iv(r.focus_to_first_key_sum_ms)},${iv(r.focus_to_first_key_count)}) ON CONFLICT(device_id, date, app) DO UPDATE SET same_finger_streak_max=MAX(same_finger_streak_max, excluded.same_finger_streak_max),same_hand_streak_max=MAX(same_hand_streak_max, excluded.same_hand_streak_max),auto_repeat_count=auto_repeat_count+excluded.auto_repeat_count,focus_to_first_key_sum_ms=focus_to_first_key_sum_ms+excluded.focus_to_first_key_sum_ms,focus_to_first_key_count=focus_to_first_key_count+excluded.focus_to_first_key_count`,
	chars_class: (r) =>
		`INSERT INTO agg_app_day_chars_class (device_id, date, app, letter, digit, punct, space, other, first_typed_min, last_typed_min) VALUES (${sq(KEY.device_id)},${sq(KEY.date)},${sq(KEY.app)},${iv(r.letter)},${iv(r.digit)},${iv(r.punct)},${iv(r.space)},${iv(r.other)},${r.first_typed_min ? sq(r.first_typed_min) : 'NULL'},${r.last_typed_min ? sq(r.last_typed_min) : 'NULL'}) ON CONFLICT(device_id, date, app) DO UPDATE SET letter=letter+excluded.letter,digit=digit+excluded.digit,punct=punct+excluded.punct,space=space+excluded.space,other=other+excluded.other,first_typed_min=COALESCE(agg_app_day_chars_class.first_typed_min, excluded.first_typed_min),last_typed_min=COALESCE(excluded.last_typed_min, agg_app_day_chars_class.last_typed_min)`
};

/** Legacy Linux statements for the tables whose text differs from macOS. */
const legacyLinux = {
	app_day: (r) => {
		const allowed = [
			'chars',
			'time_ms',
			'app_time_ms',
			'hs_chars',
			'hs_triggers',
			'hs_input_chars',
			'llm_chars',
			'llm_triggers',
			'llm_input_chars',
			'hs_suggested',
			'llm_suggested'
		];
		const sets = allowed.filter((k) => r[k] > 0).map((k) => `${k} = ${k} + ${r[k]}`);
		return `INSERT INTO agg_app_day (device_id, date, app, chars, time_ms, app_time_ms, hs_chars, hs_triggers, hs_input_chars, llm_chars, llm_triggers, llm_input_chars, hs_suggested, llm_suggested) VALUES (${sq(KEY.device_id)},${sq(KEY.date)},${sq(KEY.app)},${allowed.map((k) => r[k] ?? 0).join(',')}) ON CONFLICT(device_id, date, app) DO UPDATE SET ${sets.join(', ')};`;
	},
	chars_class: (r) =>
		`INSERT INTO agg_app_day_chars_class (device_id, date, app, letter, digit, punct, space, other, first_typed_min, last_typed_min) VALUES (${sq(KEY.device_id)},${sq(KEY.date)},${sq(KEY.app)},${iv(r.letter)},${iv(r.digit)},${iv(r.punct)},${iv(r.space)},${iv(r.other)},${r.first_typed_min ? sq(r.first_typed_min) : 'NULL'},${r.last_typed_min ? sq(r.last_typed_min) : 'NULL'}) ON CONFLICT(device_id, date, app) DO UPDATE SET letter = letter + excluded.letter, digit = digit + excluded.digit, punct = punct + excluded.punct, space = space + excluded.space, other = other + excluded.other, first_typed_min = MIN(COALESCE(first_typed_min, excluded.first_typed_min), COALESCE(excluded.first_typed_min, first_typed_min)), last_typed_min = MAX(COALESCE(last_typed_min, excluded.last_typed_min), COALESCE(excluded.last_typed_min, last_typed_min));`
};

const COUNTER_TABLES = [
	'agg_app_day',
	'agg_app_day_buckets',
	'agg_app_day_kc_hold',
	'agg_app_day_layouts',
	'agg_app_day_switches_to',
	'agg_app_day_errors',
	'agg_app_day_ergo',
	'agg_app_day_chars_class'
];

/** Two flushes of every counter family; the second flush carries earlier extremes. */
const FLUSHES = [
	{
		app_day: {
			chars: 10,
			pauses: 2,
			time_ms: 900,
			think_time_ms: 300,
			hs_chars: 3,
			llm_chars: 1,
			hs_triggers: 1,
			llm_triggers: 0,
			hs_suggested: 2,
			llm_suggested: 1,
			hs_input_chars: 4,
			llm_input_chars: 2,
			app_time_ms: 1200,
			category: 'editor'
		},
		buckets: {
			bucket_ms: 5000,
			time_sum: 800,
			credited: 6,
			hs_input_time_sum: 30,
			hs_input_credited: 1,
			llm_input_time_sum: 20,
			llm_input_credited: 1
		},
		kc_hold: { keycode: 38, sum_ms: 400, count: 4, max_ms: 150, tap_count: 3, hold_count: 1 },
		layouts: { layout: 'ergopti', count: 9 },
		switches_to: { app_from: "Mail'x", app_to: 'Code', count: 2 },
		errors: {
			bs_total: 3,
			cascade_count: 1,
			cascade_max_len: 4,
			recovery_sum_ms: 700,
			recovery_count: 2
		},
		ergo: {
			same_finger_streak_max: 3,
			same_hand_streak_max: 5,
			auto_repeat_count: 2,
			focus_to_first_key_sum_ms: 900,
			focus_to_first_key_count: 3
		},
		chars_class: {
			letter: 7,
			digit: 1,
			punct: 1,
			space: 1,
			other: 0,
			first_typed_min: '09:30',
			last_typed_min: '09:45'
		}
	},
	{
		app_day: {
			chars: 5,
			pauses: 1,
			time_ms: 400,
			think_time_ms: 100,
			hs_chars: 0,
			llm_chars: 2,
			hs_triggers: 0,
			llm_triggers: 1,
			hs_suggested: 0,
			llm_suggested: 1,
			hs_input_chars: 0,
			llm_input_chars: 1,
			app_time_ms: 600,
			category: 'other'
		},
		buckets: {
			bucket_ms: 5000,
			time_sum: 100,
			credited: 1,
			hs_input_time_sum: 0,
			hs_input_credited: 0,
			llm_input_time_sum: 0,
			llm_input_credited: 0
		},
		kc_hold: { keycode: 38, sum_ms: 100, count: 1, max_ms: 90, tap_count: 1, hold_count: 0 },
		layouts: { layout: 'ergopti', count: 1 },
		switches_to: { app_from: "Mail'x", app_to: 'Code', count: 1 },
		errors: {
			bs_total: 1,
			cascade_count: 0,
			cascade_max_len: 9,
			recovery_sum_ms: 10,
			recovery_count: 1
		},
		ergo: {
			same_finger_streak_max: 2,
			same_hand_streak_max: 8,
			auto_repeat_count: 0,
			focus_to_first_key_sum_ms: 100,
			focus_to_first_key_count: 1
		},
		chars_class: {
			letter: 2,
			digit: 0,
			punct: 0,
			space: 0,
			other: 1,
			first_typed_min: '08:15',
			last_typed_min: '09:10'
		}
	}
];

/** The catalogue call of each counter family, with the key columns added. */
function counterValues(family, row) {
	const base = { device_id: KEY.device_id, date: KEY.date, app: KEY.app };
	if (family === 'switches_to') return { device_id: KEY.device_id, date: KEY.date, ...row };
	return { ...base, ...row };
}

check('counters: the catalogue leaves the rows of the macOS flush', () => {
	const rows = equivalent(
		COUNTER_TABLES.filter((t) => t !== 'agg_app_day_chars_class'),
		(db) => {
			for (const flush of FLUSHES) {
				db.exec(legacyMac.app_day({ ...flush.app_day, app_time_ms: 0 }));
				db.exec(
					legacyMac.app_time({
						app_time_ms: flush.app_day.app_time_ms,
						category: flush.app_day.category
					})
				);
				for (const family of ['buckets', 'kc_hold', 'layouts', 'switches_to', 'errors', 'ergo'])
					db.exec(legacyMac[family](flush[family]));
			}
		},
		(db) => {
			for (const flush of FLUSHES) {
				db.exec(
					catalogue('agg.app_day', counterValues('app_day', { ...zeroAppDay(), ...flush.app_day }))
				);
				for (const family of ['buckets', 'kc_hold', 'layouts', 'switches_to', 'errors', 'ergo'])
					db.exec(catalogue(`agg.${family}`, counterValues(family, flush[family])));
			}
		}
	);
	const day = rows.agg_app_day[0];
	assert.equal(day.chars, 15);
	assert.equal(day.app_time_ms, 1800);
	assert.equal(day.category, 'editor', 'the first category stays');
});

/** An agg.app_day value set with every counter at zero. */
function zeroAppDay() {
	return Object.fromEntries(
		[
			'chars',
			'pauses',
			'time_ms',
			'think_time_ms',
			'hs_chars',
			'llm_chars',
			'hs_triggers',
			'llm_triggers',
			'hs_suggested',
			'llm_suggested',
			'hs_input_chars',
			'llm_input_chars',
			'app_time_ms'
		].map((k) => [k, 0])
	);
}

check(
	'counters: the catalogue leaves the rows of the Linux flush, including the sparse app day',
	() => {
		equivalent(
			['agg_app_day', 'agg_app_day_chars_class'],
			(db) => {
				for (const flush of FLUSHES) {
					db.exec(legacyLinux.app_day(flush.app_day));
					db.exec(legacyLinux.chars_class(flush.chars_class));
				}
			},
			(db) => {
				for (const flush of FLUSHES) {
					// Linux passes the counters it does not track as 0 and no category.
					const sparse = Object.fromEntries(
						Object.keys(zeroAppDay()).map((k) => [
							k,
							['pauses', 'think_time_ms'].includes(k) ? 0 : (flush.app_day[k] ?? 0)
						])
					);
					db.exec(catalogue('agg.app_day', counterValues('app_day', sparse)));
					db.exec(catalogue('agg.chars_class', counterValues('chars_class', flush.chars_class)));
				}
			}
		);
	}
);

check('counters: first and last typed minute take MIN and MAX, whatever the flush order', () => {
	// Intentional change on macOS: its COALESCE kept the first value it saw as the
	// day's first minute and let the latest flush decide the last, so a flush that
	// arrived out of order moved the day's extremes. Linux already used MIN and MAX.
	const apply = (statement) => {
		const db = freshDb();
		for (const flush of FLUSHES) db.exec(statement(flush.chars_class));
		const row = db
			.prepare(
				'SELECT first_typed_min AS first, last_typed_min AS last FROM agg_app_day_chars_class'
			)
			.get();
		db.close();
		return { ...row };
	};
	assert.deepEqual(
		apply((r) => legacyMac.chars_class(r)),
		{ first: '09:30', last: '09:10' }
	);
	assert.deepEqual(
		apply((r) => catalogue('agg.chars_class', counterValues('chars_class', r))),
		{
			first: '08:15',
			last: '09:45'
		}
	);
});

if (failures > 0) {
	console.error(`\n${failures} keystats write catalogue check(s) failed.`);
	process.exit(1);
}
console.log('\nKeystats write catalogue checks passed.');
