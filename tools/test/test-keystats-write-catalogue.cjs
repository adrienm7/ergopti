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

if (failures > 0) {
	console.error(`\n${failures} keystats write catalogue check(s) failed.`);
	process.exit(1);
}
console.log('\nKeystats write catalogue checks passed.');
