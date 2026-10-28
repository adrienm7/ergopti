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

/** A JSON object stored as text compares by its content: key order is not data. */
function canonicalJson(value) {
	if (typeof value !== 'string' || !value.startsWith('{')) return value;
	try {
		const parsed = JSON.parse(value);
		return JSON.stringify(
			Object.fromEntries(Object.entries(parsed).sort(([a], [b]) => (a < b ? -1 : 1)))
		);
	} catch {
		return value;
	}
}

/** Every row of the given tables, in a stable order, as plain JSON. */
function dump(db, tables) {
	return Object.fromEntries(
		tables.map((table) => [
			table,
			JSON.parse(JSON.stringify(db.prepare(`SELECT * FROM ${table}`).all()))
				.map((row) =>
					Object.fromEntries(Object.entries(row).map(([k, v]) => [k, canonicalJson(v)]))
				)
				.sort((a, b) => (JSON.stringify(a) < JSON.stringify(b) ? -1 : 1))
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

// ---------------------------------------------------------------------------
// Family: number-map aggregates (hourly, burst, session, n-grams, titles)
// ---------------------------------------------------------------------------

const MAP_TABLES = [
	'agg_app_day_hourly',
	'agg_app_day_hourly_min5',
	'agg_app_day_burst',
	'agg_app_day_session',
	'ngram_chars',
	'agg_app_day_titles'
];
const CAP = 3;
const jsonOf = (value) => JSON.stringify(value);
const KEYED = { device_id: KEY.device_id, date: KEY.date, app: KEY.app };

/** macOS number_map_merge_expr: it only touches the keys of the incoming delta. */
function macMerge(column, delta) {
	if (Object.keys(delta).length === 0) return `COALESCE(${column},'{}')`;
	let out = `json_set(COALESCE(${column},'{}')`;
	for (const key of Object.keys(delta)) {
		const path = `$.${key}`.replaceAll("'", "''");
		out += `,'${path}',COALESCE(json_extract(${column},'${path}'),0)+COALESCE(json_extract(excluded.${column},'${path}'),0)`;
	}
	return out + ')';
}

/** Linux number_map_merge_sql: the full key-by-key sum of both maps. */
const linuxMerge = (column) =>
	`${column} = (SELECT COALESCE('{' || group_concat(json_quote(k) || ':' || v, ',') || '}', '{}') FROM (SELECT key AS k, SUM(value) AS v FROM (SELECT key, value FROM json_each(${column}) UNION ALL SELECT key, value FROM json_each(excluded.${column})) GROUP BY key))`;

const legacyMapMac = {
	hourly: (r) =>
		`INSERT INTO agg_app_day_hourly (device_id, date, app, hour, c, e, em, es, e_buckets_json) VALUES (${sq(KEY.device_id)},${sq(KEY.date)},${sq(KEY.app)},${sq(r.hour)},${iv(r.c)},${iv(r.e)},${iv(r.em)},${iv(r.es)},${sq(jsonOf(r.e_buckets))}) ON CONFLICT(device_id, date, app, hour) DO UPDATE SET c=c+excluded.c, e=e+excluded.e, em=em+excluded.em, es=es+excluded.es, e_buckets_json=${macMerge('e_buckets_json', r.e_buckets)}`,
	hourly_min5: (r) =>
		`INSERT INTO agg_app_day_hourly_min5 (device_id, date, app, slot, c, e, es, e_buckets_json) VALUES (${sq(KEY.device_id)},${sq(KEY.date)},${sq(KEY.app)},${sq(r.slot)},${iv(r.c)},${iv(r.e)},${iv(r.es)},${sq(jsonOf(r.e_buckets))}) ON CONFLICT(device_id, date, app, slot) DO UPDATE SET c=c+excluded.c, e=e+excluded.e, es=es+excluded.es, e_buckets_json=${macMerge('e_buckets_json', r.e_buckets)}`,
	burst: (r) =>
		`INSERT INTO agg_app_day_burst (device_id, date, app, count_total, max_cpm, max_chars, length_buckets_json, inter_delay_count, inter_delay_sum, inter_delay_sumsq) VALUES (${sq(KEY.device_id)},${sq(KEY.date)},${sq(KEY.app)},${iv(r.count_total)},${r.max_cpm.toFixed(6)},${iv(r.max_chars)},${sq(jsonOf(r.length_buckets))},${iv(r.inter_delay_count)},${iv(r.inter_delay_sum)},${iv(r.inter_delay_sumsq)}) ON CONFLICT(device_id, date, app) DO UPDATE SET count_total=count_total+excluded.count_total,max_cpm=MAX(max_cpm, excluded.max_cpm),max_chars=MAX(max_chars, excluded.max_chars),length_buckets_json=${macMerge('length_buckets_json', r.length_buckets)},inter_delay_count=inter_delay_count+excluded.inter_delay_count,inter_delay_sum=inter_delay_sum+excluded.inter_delay_sum,inter_delay_sumsq=inter_delay_sumsq+excluded.inter_delay_sumsq`,
	session: (r) =>
		`INSERT INTO agg_app_day_session (device_id, date, app, count_total, longest_ms, longest_chars, total_active_ms, durations_json) VALUES (${sq(KEY.device_id)},${sq(KEY.date)},${sq(KEY.app)},${iv(r.count_total)},${iv(r.longest_ms)},${iv(r.longest_chars)},${iv(r.total_active_ms)},${sq(jsonOf(r.durations))}) ON CONFLICT(device_id, date, app) DO UPDATE SET count_total=count_total+excluded.count_total,longest_ms=MAX(longest_ms, excluded.longest_ms),longest_chars=MAX(longest_chars, excluded.longest_chars),total_active_ms=total_active_ms+excluded.total_active_ms,durations_json=(SELECT json_group_array(duration) FROM (SELECT value AS duration FROM json_each(COALESCE(durations_json,'[]')) UNION ALL SELECT value FROM json_each(COALESCE(excluded.durations_json,'[]')) LIMIT ${CAP}))`,
	ngram: (r) =>
		`INSERT INTO ngram_chars (device_id, date, app, token, c, td, cd, e, esrc_json) VALUES (${sq(KEY.device_id)},${sq(KEY.date)},${sq(KEY.app)},${sq(r.token)},${iv(r.c)},${iv(r.td)},${iv(r.cd)},${iv(r.e)},${sq(jsonOf(r.esrc))}) ON CONFLICT(device_id, date, app, token) DO UPDATE SET c=c+excluded.c, td=td+excluded.td, cd=cd+excluded.cd, e=e+excluded.e, esrc_json=${macMerge('esrc_json', r.esrc)}`,
	title: (r) =>
		`INSERT INTO agg_app_day_titles (device_id, date, app, title, c, ms) VALUES (${sq(KEY.device_id)},${sq(KEY.date)},${sq(KEY.app)},${sq(r.title)},${iv(r.c)},${iv(r.ms)}) ON CONFLICT(device_id, date, app, title) DO UPDATE SET c=c+excluded.c, ms=ms+excluded.ms`,
	titlePrune: () =>
		`DELETE FROM agg_app_day_titles WHERE device_id=${sq(KEY.device_id)} AND date=${sq(KEY.date)} AND app=${sq(KEY.app)} AND title NOT IN (SELECT title FROM agg_app_day_titles WHERE device_id=${sq(KEY.device_id)} AND date=${sq(KEY.date)} AND app=${sq(KEY.app)} ORDER BY (c + ms) DESC LIMIT 2)`
};

const legacyMapLinux = {
	hourly: (r) =>
		`INSERT INTO agg_app_day_hourly (device_id, date, app, hour, c, e, em, es, e_buckets_json) VALUES (${sq(KEY.device_id)},${sq(KEY.date)},${sq(KEY.app)},${sq(r.hour)},${iv(r.c)},${iv(r.e)},${iv(r.em)},${iv(r.es)},${sq(jsonOf(r.e_buckets))}) ON CONFLICT(device_id, date, app, hour) DO UPDATE SET c = c + excluded.c, e = e + excluded.e, em = em + excluded.em, es = es + excluded.es, ${linuxMerge('e_buckets_json')};`,
	burst: (r) =>
		`INSERT INTO agg_app_day_burst (device_id, date, app, count_total, max_cpm, max_chars, length_buckets_json, inter_delay_count, inter_delay_sum, inter_delay_sumsq) VALUES (${sq(KEY.device_id)},${sq(KEY.date)},${sq(KEY.app)},${iv(r.count_total)},${r.max_cpm.toFixed(6)},${iv(r.max_chars)},${sq(jsonOf(r.length_buckets))},${iv(r.inter_delay_count)},${iv(r.inter_delay_sum)},${iv(r.inter_delay_sumsq)}) ON CONFLICT(device_id, date, app) DO UPDATE SET count_total = count_total + excluded.count_total, max_cpm = MAX(max_cpm, excluded.max_cpm), max_chars = MAX(max_chars, excluded.max_chars), ${linuxMerge('length_buckets_json')}, inter_delay_count = inter_delay_count + excluded.inter_delay_count, inter_delay_sum = inter_delay_sum + excluded.inter_delay_sum, inter_delay_sumsq = inter_delay_sumsq + excluded.inter_delay_sumsq;`,
	session: (r) =>
		`INSERT INTO agg_app_day_session (device_id, date, app, count_total, longest_ms, longest_chars, total_active_ms, durations_json) VALUES (${sq(KEY.device_id)},${sq(KEY.date)},${sq(KEY.app)},${iv(r.count_total)},${iv(r.longest_ms)},${iv(r.longest_chars)},${iv(r.total_active_ms)},${sq(jsonOf(r.durations))}) ON CONFLICT(device_id, date, app) DO UPDATE SET count_total = count_total + excluded.count_total, longest_ms = MAX(longest_ms, excluded.longest_ms), longest_chars = MAX(longest_chars, excluded.longest_chars), total_active_ms = total_active_ms + excluded.total_active_ms, durations_json = (SELECT json_group_array(d) FROM (SELECT value AS d FROM json_each(durations_json) UNION ALL SELECT value FROM json_each(excluded.durations_json) LIMIT ${CAP}));`,
	/** Linux batched all tokens of a flush into one multi-row INSERT. */
	ngrams: (rows) =>
		`INSERT INTO ngram_chars (device_id, date, app, token, c, td, cd, e, esrc_json) VALUES ${rows.map((r) => `(${sq(KEY.device_id)},${sq(KEY.date)},${sq(KEY.app)},${sq(r.token)},${iv(r.c)},${iv(r.td)},${iv(r.cd)},${iv(r.e)},${sq(jsonOf(r.esrc))})`).join(',')} ON CONFLICT(device_id, date, app, token) DO UPDATE SET c = c + excluded.c, td = td + excluded.td, cd = cd + excluded.cd, e = e + excluded.e, ${linuxMerge('esrc_json')};`,
	title: (r) =>
		`INSERT INTO agg_app_day_titles (device_id, date, app, title, c, ms) VALUES (${sq(KEY.device_id)},${sq(KEY.date)},${sq(KEY.app)},${sq(r.title)},${iv(r.c)},${iv(r.ms)}) ON CONFLICT(device_id, date, app, title) DO UPDATE SET c = c + excluded.c, ms = ms + excluded.ms; DELETE FROM agg_app_day_titles WHERE device_id = ${sq(KEY.device_id)} AND date = ${sq(KEY.date)} AND app = ${sq(KEY.app)} AND title NOT IN (SELECT title FROM agg_app_day_titles WHERE device_id = ${sq(KEY.device_id)} AND date = ${sq(KEY.date)} AND app = ${sq(KEY.app)} ORDER BY (c + ms) DESC LIMIT 2);`
};

const MAP_FLUSHES = [
	{
		hourly: { hour: '09', c: 10, e: 2, em: 1, es: 1, e_buckets: { backspace: 2, other: 1 } },
		hourly_min5: { slot: '09:05', c: 4, e: 1, es: 0, e_buckets: { backspace: 1 } },
		burst: {
			count_total: 3,
			max_cpm: 312.5,
			max_chars: 40,
			length_buckets: { '5-9': 2, '10+': 1 },
			inter_delay_count: 4,
			inter_delay_sum: 400,
			inter_delay_sumsq: 50000
		},
		session: {
			count_total: 1,
			longest_ms: 1200,
			longest_chars: 80,
			total_active_ms: 1200,
			durations: [1200]
		},
		tokens: [
			{ token: 'ab', c: 3, td: 90, cd: 3, e: 1, esrc: { hotstring: 1, other: 2 } },
			{ token: "it's", c: 1, td: 10, cd: 1, e: 0, esrc: {} }
		],
		titles: [
			{ title: 'one', c: 1, ms: 10 },
			{ title: 'two', c: 5, ms: 50 }
		]
	},
	{
		hourly: { hour: '09', c: 5, e: 0, em: 0, es: 0, e_buckets: { other: 4, delete: 1 } },
		hourly_min5: { slot: '09:05', c: 1, e: 0, es: 0, e_buckets: {} },
		burst: {
			count_total: 1,
			max_cpm: 280.25,
			max_chars: 55,
			length_buckets: { '10+': 3 },
			inter_delay_count: 1,
			inter_delay_sum: 100,
			inter_delay_sumsq: 10000
		},
		session: {
			count_total: 2,
			longest_ms: 900,
			longest_chars: 120,
			total_active_ms: 1000,
			durations: [500, 500, 700]
		},
		tokens: [{ token: 'ab', c: 2, td: 20, cd: 2, e: 1, esrc: { hotstring: 3, llm: 1 } }],
		titles: [
			{ title: 'three', c: 9, ms: 90 },
			{ title: 'one', c: 1, ms: 10 }
		]
	}
];

/** Strips undefined fields, which the renderer rejects as undeclared parameters. */
function withoutUndefined(values) {
	return Object.fromEntries(Object.entries(values).filter(([, v]) => v !== undefined));
}

check('maps: the catalogue leaves the rows of the macOS flush', () => {
	const rows = equivalent(
		MAP_TABLES,
		(db) => {
			for (const flush of MAP_FLUSHES) {
				db.exec(legacyMapMac.hourly(flush.hourly));
				db.exec(legacyMapMac.hourly_min5(flush.hourly_min5));
				db.exec(legacyMapMac.burst(flush.burst));
				db.exec(legacyMapMac.session(flush.session));
				for (const t of flush.tokens) db.exec(legacyMapMac.ngram(t));
				for (const t of flush.titles) db.exec(legacyMapMac.title(t));
				db.exec(legacyMapMac.titlePrune());
			}
		},
		(db) => {
			for (const flush of MAP_FLUSHES) applyMapFlush(db, flush);
		}
	);
	assert.deepEqual(JSON.parse(rows.agg_app_day_hourly[0].e_buckets_json), {
		backspace: 2,
		other: 5,
		delete: 1
	});
	assert.deepEqual(JSON.parse(rows.agg_app_day_session[0].durations_json), [1200, 500, 500]);
});

check(
	'maps: the catalogue leaves the rows of the Linux flush, with its batched n-gram insert',
	() => {
		equivalent(
			MAP_TABLES.filter((t) => t !== 'agg_app_day_hourly_min5'),
			(db) => {
				for (const flush of MAP_FLUSHES) {
					db.exec(legacyMapLinux.hourly(flush.hourly));
					db.exec(legacyMapLinux.burst(flush.burst));
					db.exec(legacyMapLinux.session(flush.session));
					db.exec(legacyMapLinux.ngrams(flush.tokens));
					for (const t of flush.titles) db.exec(legacyMapLinux.title(t));
				}
			},
			(db) => {
				for (const flush of MAP_FLUSHES) {
					const first = withoutUndefined({
						...KEYED,
						...flush.hourly,
						e_buckets_json: jsonOf(flush.hourly.e_buckets),
						e_buckets: undefined
					});
					db.exec(catalogue('agg.hourly', first));
					db.exec(
						catalogue(
							'agg.burst',
							withoutUndefined({
								...KEYED,
								...flush.burst,
								length_buckets_json: jsonOf(flush.burst.length_buckets),
								length_buckets: undefined
							})
						)
					);
					db.exec(
						catalogue(
							'agg.session',
							withoutUndefined({
								...KEYED,
								...flush.session,
								durations_json: jsonOf(flush.session.durations),
								durations: undefined,
								duration_cap: CAP
							})
						)
					);
					// One statement per token instead of one multi-row INSERT: the same rows.
					for (const t of flush.tokens)
						db.exec(
							catalogue(
								'agg.ngram',
								withoutUndefined({
									table: 'ngram_chars',
									...KEYED,
									...t,
									esrc_json: jsonOf(t.esrc),
									esrc: undefined
								})
							)
						);
					for (const t of flush.titles) {
						db.exec(catalogue('agg.title', { ...KEYED, ...t }));
						db.exec(catalogue('agg.title_prune', { ...KEYED, cap: 2 }));
					}
				}
			}
		);
	}
);

/** Applies a flush through the catalogue (macOS order: prune after every title). */
function applyMapFlush(db, flush) {
	db.exec(
		catalogue(
			'agg.hourly',
			withoutUndefined({
				...KEYED,
				...flush.hourly,
				e_buckets_json: jsonOf(flush.hourly.e_buckets),
				e_buckets: undefined
			})
		)
	);
	db.exec(
		catalogue(
			'agg.hourly_min5',
			withoutUndefined({
				...KEYED,
				...flush.hourly_min5,
				e_buckets_json: jsonOf(flush.hourly_min5.e_buckets),
				e_buckets: undefined
			})
		)
	);
	db.exec(
		catalogue(
			'agg.burst',
			withoutUndefined({
				...KEYED,
				...flush.burst,
				length_buckets_json: jsonOf(flush.burst.length_buckets),
				length_buckets: undefined
			})
		)
	);
	db.exec(
		catalogue(
			'agg.session',
			withoutUndefined({
				...KEYED,
				...flush.session,
				durations_json: jsonOf(flush.session.durations),
				durations: undefined,
				duration_cap: CAP
			})
		)
	);
	for (const t of flush.tokens)
		db.exec(
			catalogue(
				'agg.ngram',
				withoutUndefined({
					table: 'ngram_chars',
					...KEYED,
					...t,
					esrc_json: jsonOf(t.esrc),
					esrc: undefined
				})
			)
		);
	for (const t of flush.titles) db.exec(catalogue('agg.title', { ...KEYED, ...t }));
	db.exec(catalogue('agg.title_prune', { ...KEYED, cap: 2 }));
}

check('maps: a key with a dot or a quote no longer merges into a nested path', () => {
	// Intentional change on macOS: its merge built a JSON path from the key, so
	// "a.b" was read as the nested path $.a.b and a key with a quote broke the
	// statement. The merge reads both maps with json_each and quotes every key.
	const db = freshDb();
	const first = {
		...KEYED,
		token: 't',
		c: 1,
		td: 0,
		cd: 0,
		e: 0,
		esrc_json: jsonOf({ 'a.b': 1, 'we"ird': 2 })
	};
	db.exec(catalogue('agg.ngram', { table: 'ngram_chars', ...first }));
	db.exec(
		catalogue('agg.ngram', {
			table: 'ngram_chars',
			...first,
			esrc_json: jsonOf({ 'a.b': 4, 'we"ird': 1, plain: 3 })
		})
	);
	assert.deepEqual(JSON.parse(db.prepare('SELECT esrc_json FROM ngram_chars').get().esrc_json), {
		'a.b': 5,
		'we"ird': 3,
		plain: 3
	});
	const legacy = freshDb();
	legacy.exec(legacyMapMac.ngram({ token: 't', c: 1, td: 0, cd: 0, e: 0, esrc: { 'a.b': 1 } }));
	legacy.exec(legacyMapMac.ngram({ token: 't', c: 1, td: 0, cd: 0, e: 0, esrc: { 'a.b': 4 } }));
	assert.notDeepEqual(
		JSON.parse(legacy.prepare('SELECT esrc_json FROM ngram_chars').get().esrc_json),
		{ 'a.b': 5 }
	);
	legacy.close();
	db.close();
});

// ---------------------------------------------------------------------------
// Family: event inserts
// ---------------------------------------------------------------------------

const EVENT_TABLES = [
	'events_app_switch',
	'events_window_switch',
	'events_shortcut',
	'events_system',
	'events_hotstring',
	'events_session'
];
/** macOS _sql_str / _sql_num: a missing value is NULL, a number its Lua text. */
const msStr = (v) => (v === undefined || v === null ? 'NULL' : legacyQuote(v));
const msNum = (v) => (v === undefined || v === null ? 'NULL' : String(v));
const STAMP = { ts: '2026-10-01 10:00:00', date: '2026-10-01' };

const EVENTS = {
	app_switch: [
		{ id: 1, prev_app: 'Mail', next_app: "Code's", duration_ms: 1500 },
		{ id: 2, prev_app: null, next_app: null, duration_ms: 0 }
	],
	window_switch: [
		{ id: 3, app: 'Code', prev_title: 'a\r\n', next_title: null, duration_ms: 40 },
		{ id: 4, app: 'Unknown', prev_title: null, next_title: 'b', duration_ms: 7 }
	],
	shortcut: [
		{ id: 5, app: 'Unknown', key: 'Cmd+K' },
		{ id: 6, app: 'Code', key: '' }
	],
	system: [
		{ id: 7, action: 'sleep', metadata_json: '{"asleep_ms":5}' },
		{ id: 8, action: 'unknown', metadata_json: null }
	],
	hotstring: [
		{
			id: 9,
			app: 'Code',
			kind: 'fired',
			trigger: 'btw',
			replacement: 'by the way',
			h_type: 'text',
			net_saved_chars: 7
		},
		{
			id: 10,
			app: 'Code',
			kind: 'suggested',
			trigger: '',
			replacement: '',
			h_type: null,
			net_saved_chars: null
		}
	],
	session: [
		{ id: 11, kind: 'session_start', duration_ms: null },
		{ id: 12, kind: 'session_end', duration_ms: 90000 }
	]
};

/** Legacy macOS builders (sqlite_writer.lua section 6). */
const legacyEventMac = {
	app_switch: (e) =>
		`INSERT OR IGNORE INTO events_app_switch (device_id, id, ts, date, prev_app, next_app, duration_ms) VALUES (${legacyQuote('dev')}, ${e.id}, ${msStr(STAMP.ts)}, ${msStr(STAMP.date)}, ${msStr(e.prev_app)}, ${msStr(e.next_app)}, ${msNum(e.duration_ms)});`,
	window_switch: (e) =>
		`INSERT OR IGNORE INTO events_window_switch (device_id, id, ts, date, app, prev_title, next_title, duration_ms) VALUES (${legacyQuote('dev')}, ${e.id}, ${msStr(STAMP.ts)}, ${msStr(STAMP.date)}, ${msStr(e.app)}, ${msStr(e.prev_title)}, ${msStr(e.next_title)}, ${msNum(e.duration_ms)});`,
	shortcut: (e) =>
		`INSERT OR IGNORE INTO events_shortcut (device_id, id, ts, date, app, key) VALUES (${legacyQuote('dev')}, ${e.id}, ${msStr(STAMP.ts)}, ${msStr(STAMP.date)}, ${msStr(e.app)}, ${msStr(e.key)});`,
	system: (e) =>
		`INSERT OR IGNORE INTO events_system (device_id, id, ts, date, action, metadata_json) VALUES (${legacyQuote('dev')}, ${e.id}, ${msStr(STAMP.ts)}, ${msStr(STAMP.date)}, ${msStr(e.action)}, ${msStr(e.metadata_json ?? '{}')});`,
	hotstring: (e) =>
		`INSERT OR IGNORE INTO events_hotstring (device_id, id, ts, date, app, kind, trigger, replacement, h_type, net_saved_chars) VALUES (${legacyQuote('dev')}, ${e.id}, ${msStr(STAMP.ts)}, ${msStr(STAMP.date)}, ${msStr(e.app)}, ${msStr(e.kind)}, ${msStr(e.trigger)}, ${msStr(e.replacement)}, ${msStr(e.h_type)}, ${msNum(e.net_saved_chars)});`,
	session: (e) =>
		`INSERT OR IGNORE INTO events_session (device_id, id, ts, date, kind, duration_ms) VALUES (${legacyQuote('dev')}, ${e.id}, ${msStr(STAMP.ts)}, ${msStr(STAMP.date)}, ${msStr(e.kind)}, ${msNum(e.duration_ms)});`
};

/** Legacy Linux builders: one multi-row INSERT per kind, defaults applied. */
const linuxRows = {
	app_switch: (e) =>
		`('dev',${e.id},'${STAMP.ts}','${STAMP.date}',${legacyQuote(e.prev_app ?? '')},${legacyQuote(e.next_app ?? '')},${e.duration_ms})`,
	window_switch: (e) =>
		`('dev',${e.id},'${STAMP.ts}','${STAMP.date}',${legacyQuote(e.app)},${legacyQuote(e.prev_title ?? '')},${legacyQuote(e.next_title ?? '')},${e.duration_ms})`,
	shortcut: (e) =>
		`('dev',${e.id},'${STAMP.ts}','${STAMP.date}',${legacyQuote(e.app)},${legacyQuote(e.key)})`,
	system: (e) =>
		`('dev',${e.id},'${STAMP.ts}','${STAMP.date}',${legacyQuote(e.action)},${e.metadata_json ? legacyQuote(e.metadata_json) : 'NULL'})`,
	hotstring: (e) =>
		`('dev',${e.id},'${STAMP.ts}','${STAMP.date}',${legacyQuote(e.app)},${legacyQuote(e.kind)},${legacyQuote(e.trigger)},${legacyQuote(e.replacement)},${legacyQuote(e.h_type ?? 'unknown')},${e.net_saved_chars ?? 0})`,
	session: (e) =>
		`('dev',${e.id},'${STAMP.ts}','${STAMP.date}','${e.kind}',${e.duration_ms === null ? 'NULL' : e.duration_ms})`
};
const LINUX_COLUMNS = {
	app_switch: ['events_app_switch', 'device_id,id,ts,date,prev_app,next_app,duration_ms'],
	window_switch: [
		'events_window_switch',
		'device_id,id,ts,date,app,prev_title,next_title,duration_ms'
	],
	shortcut: ['events_shortcut', 'device_id,id,ts,date,app,key'],
	system: ['events_system', 'device_id,id,ts,date,action,metadata_json'],
	hotstring: [
		'events_hotstring',
		'device_id,id,ts,date,app,kind,trigger,replacement,h_type,net_saved_chars'
	],
	session: ['events_session', 'device_id,id,ts,date,kind,duration_ms']
};

/** The catalogue call of an event: the stamp and device added, missing values left out. */
const eventValues = (event) =>
	withoutUndefined(
		Object.fromEntries(
			Object.entries({ device_id: 'dev', ...STAMP, ...event }).map(([k, v]) => [
				k,
				v === null ? undefined : v
			])
		)
	);

check('events: the catalogue stores the rows of the macOS builders', () => {
	const rows = equivalent(
		EVENT_TABLES,
		(db) => {
			for (const [kind, events] of Object.entries(EVENTS))
				for (const event of events) db.exec(legacyEventMac[kind](event));
		},
		(db) => {
			for (const [kind, events] of Object.entries(EVENTS))
				for (const event of events) {
					const values = eventValues(event);
					// macOS stores a system event without metadata as '{}'.
					if (kind === 'system' && values.metadata_json === undefined) values.metadata_json = '{}';
					db.exec(catalogue(`events.${kind}`, values));
				}
		}
	);
	assert.equal(
		rows.events_app_switch.find((r) => r.id === 2).prev_app,
		null,
		'a missing app is NULL'
	);
	assert.equal(rows.events_session.find((r) => r.id === 11).duration_ms, null);
});

check('events: the catalogue stores the rows of the Linux batches, one statement per event', () => {
	equivalent(
		EVENT_TABLES,
		(db) => {
			for (const [kind, events] of Object.entries(EVENTS)) {
				const [table, columns] = LINUX_COLUMNS[kind];
				db.exec(
					`INSERT OR IGNORE INTO ${table} (${columns}) VALUES ${events.map(linuxRows[kind]).join(',')};`
				);
			}
		},
		(db) => {
			for (const [kind, events] of Object.entries(EVENTS))
				for (const event of events) {
					// Linux applies its defaults before the statement: '' for a missing app or
					// title, 'unknown' for a missing hotstring type, 0 for missing counts.
					const values = eventValues(event);
					for (const [key, fallback] of Object.entries({
						prev_app: '',
						next_app: '',
						prev_title: '',
						next_title: '',
						h_type: 'unknown'
					}))
						if (key in event && values[key] === undefined) values[key] = fallback;
					if (kind === 'hotstring' && values.net_saved_chars === undefined)
						values.net_saved_chars = 0;
					db.exec(catalogue(`events.${kind}`, values));
				}
		}
	);
});

check('events: a replayed event keeps the row it already has', () => {
	const db = freshDb();
	db.exec(
		catalogue('events.shortcut', { device_id: 'dev', id: 1, ...STAMP, app: 'A', key: 'one' })
	);
	db.exec(
		catalogue('events.shortcut', { device_id: 'dev', id: 1, ...STAMP, app: 'B', key: 'two' })
	);
	assert.equal(db.prepare('SELECT key FROM events_shortcut').get().key, 'one');
	db.close();
});

check('events: a NOT NULL column refuses a missing value instead of losing the whole event', () => {
	assert.throws(
		() => catalogue('events.shortcut', { device_id: 'dev', id: 1, ...STAMP, app: 'A' }),
		TypeError
	);
	assert.throws(
		() => catalogue('events.window_switch', { device_id: 'dev', id: 1, ...STAMP, duration_ms: 1 }),
		TypeError
	);
});

if (failures > 0) {
	console.error(`\n${failures} keystats write catalogue check(s) failed.`);
	process.exit(1);
}
console.log('\nKeystats write catalogue checks passed.');
