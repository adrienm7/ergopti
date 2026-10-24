// tools/test/test-keystats-query-catalogue.cjs

/**
 * ==============================================================================
 * MODULE: Keystats Named-Query Catalogue Test
 * DESCRIPTION:
 * Proves the catalogue in `_shared/data/db/queries.sql` against a realistic
 * SQLite fixture and pins its compiler.
 *
 * FEATURES & RATIONALE:
 * 1. Results, not text. Every query runs on query_fixture.sql (two devices,
 *    three days, a NUL byte in an application name, identical JSON blobs on
 *    both devices) in both dialects and must return the rows in
 *    query_results.json, which were derived from the legacy driver SQL the
 *    catalogue replaced. A query that reads differently fails here first.
 * 2. Dialect equivalence. The json_quote dialect decoded must equal the
 *    in-process dialect except for the text an in-process engine cuts at NUL;
 *    a column forgotten in one spelling cannot pass.
 * 3. The compiled outputs are what the generator writes now, and the compiler
 *    refuses malformed catalogues instead of emitting a template that renders
 *    something else.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Codegen = require('../codegen/codegen-keystats-queries.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const FIXTURE = path.join(SHARED, 'tests', 'corpus', 'keystats', 'query_fixture.sql');
const EXPECTED = path.join(SHARED, 'tests', 'corpus', 'keystats', 'query_results.json');

// node:sqlite prints an experimental-feature warning on first use; it is not a
// test outcome, so the module is loaded with that one warning silenced.
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
const expected = JSON.parse(fs.readFileSync(EXPECTED, 'utf8'));

/** Opens a fresh fixture database with the canonical schema. */
function fixture() {
	const db = new DatabaseSync(':memory:');
	db.exec(fs.readFileSync(path.join(SHARED, 'data', 'db', 'schema.sql'), 'utf8'));
	db.exec(fs.readFileSync(path.join(SHARED, 'data', 'db', 'media_schema.sql'), 'utf8'));
	db.exec(fs.readFileSync(FIXTURE, 'utf8'));
	return db;
}

/** Sorts rows and their keys so result order and column order do not matter. */
function canonical(rows) {
	return rows
		.map((row) =>
			Object.fromEntries(
				Object.keys(row)
					.sort()
					.map((k) => [k, row[k]])
			)
		)
		.sort((a, b) => (JSON.stringify(a) < JSON.stringify(b) ? -1 : 1));
}

/** Decodes the `<name>_json` columns the CLI dialect projects for text. */
function decodeTexts(query, rows) {
	return rows.map((row) => {
		const out = { ...row };
		for (const column of query.texts) {
			const quoted = out[`${column}_json`];
			delete out[`${column}_json`];
			out[column] = quoted === null ? null : JSON.parse(quoted);
		}
		return out;
	});
}

/** Cuts text at NUL, as an in-process engine reading the column does. */
function cutAtNul(rows) {
	return JSON.parse(
		JSON.stringify(rows, (_k, v) => (typeof v === 'string' ? v.split('\u0000')[0] : v))
	);
}

const db = fixture();

check('every catalogue query has expected rows and nothing else is expected', () => {
	assert.deepEqual(Object.keys(expected.queries).sort(), queries.map((q) => q.name).sort());
});

for (const query of queries) {
	for (const [filter, where] of Object.entries(expected.filters)) {
		check(`${query.name} (${filter}) returns the legacy rows in both dialects`, () => {
			// The n-gram family table and the filter's connective are parameters too;
			// the fixture's n-gram rows live in ngram_chars.
			const available = {
				where,
				conjunction: where === '' ? ' WHERE ' : ' AND ',
				table: 'ngram_chars'
			};
			const params = Object.fromEntries(query.params.map((name) => [name, available[name]]));
			const native = canonical(
				db.prepare(Codegen.render(queries, query.name, 'native', params)).all()
			);
			const cli = canonical(
				decodeTexts(
					query,
					db.prepare(Codegen.render(queries, query.name, 'cli_json', params)).all()
				)
			);
			assert.deepEqual(
				JSON.parse(JSON.stringify(native)),
				expected.queries[query.name][filter].native
			);
			assert.deepEqual(
				JSON.parse(JSON.stringify(cli)),
				expected.queries[query.name][filter].cli_json
			);
			assert.deepEqual(canonical(cutAtNul(cli)), JSON.parse(JSON.stringify(native)));
		});
	}
}

check('the fixture exercises what the catalogue exists for', () => {
	const app = expected.queries['manifest.app_day'].all.cli_json.map((r) => r.app);
	assert.ok(
		app.some((name) => name.includes('\u0000')),
		'a NUL-bearing application name'
	);
	const burst = expected.queries['manifest.burst'].all.native;
	assert.ok(
		burst.some((r) => r.source_rows === 2),
		'identical blobs from two devices'
	);
	const tokens = expected.queries['ngram.tokens'].all.cli_json;
	assert.ok(
		tokens.some((r) => r.source_rows === 2),
		'an n-gram source map shared by two devices'
	);
	assert.ok(
		tokens.some((r) => r.c === '12oops'),
		'a malformed counter returned raw, not summed'
	);
	const system = expected.queries['manifest.system_day'].all.native.find(
		(r) => r.date === '2026-10-01'
	);
	assert.equal(system.battery_min, 22, 'a battery-less device must not lower the minimum');
});

check('the generated Lua and AHK outputs are current', () => {
	assert.equal(
		fs.readFileSync(path.join(ROOT, Codegen.LUA_OUTPUT), 'utf8'),
		Codegen.renderLua(queries)
	);
	assert.equal(
		fs.readFileSync(path.join(ROOT, Codegen.AHK_OUTPUT), 'utf8'),
		'﻿' + Codegen.renderAhk(queries)
	);
});

check('the compiler refuses malformed catalogues', () => {
	const ok = '-- name: a.b\nSELECT 1 FROM t{{where}};\n';
	assert.equal(Codegen.parse(ok).length, 1);
	const refusals = {
		duplicate: ok + ok,
		unknownPlaceholder: '-- name: a.b\nSELECT {{nope x}} FROM t;\n',
		commentInBody: '-- name: a.b\nSELECT 1\n-- stray\nFROM t;\n',
		twoStatements: '-- name: a.b\nSELECT 1; SELECT 2;\n',
		unterminated: '-- name: a.b\nSELECT 1\n',
		badName: '-- name: nodot\nSELECT 1;\n',
		conflictingText: '-- name: a.b\nSELECT {{text app}}, {{text MAX(app) AS app}} FROM t;\n',
		empty: '-- nothing\n'
	};
	for (const [label, text] of Object.entries(refusals))
		assert.throws(() => Codegen.parse(text), SyntaxError, label);
	assert.throws(() => Codegen.render(Codegen.parse(ok), 'a.b', 'native', {}), TypeError);
	assert.throws(
		() => Codegen.render(Codegen.parse(ok), 'a.b', 'native', { where: '', x: '' }),
		RangeError
	);
	assert.throws(
		() => Codegen.render(Codegen.parse(ok), 'a.b', 'sqlite', { where: '' }),
		RangeError
	);
});

check('collapsing whitespace keeps quoted literals byte for byte', () => {
	assert.equal(Codegen.collapse("SELECT  'a  b'\n\tFROM t"), "SELECT 'a  b' FROM t");
});

db.close();
if (failures > 0) {
	console.error(`\n${failures} keystats query catalogue check(s) failed.`);
	process.exit(1);
}
console.log('\nKeystats query catalogue checks passed.');
