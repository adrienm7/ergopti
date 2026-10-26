// tools/test/test-keystats-sql-shared-spelling.cjs

/**
 * ==============================================================================
 * MODULE: Keystats Shared SQL Spelling Gate
 * DESCRIPTION:
 * Fails when the macOS and Linux keystats drivers spell the same SQL statement
 * by hand. A statement both Lua drivers run belongs in the named catalogue
 * (_shared/data/db/queries.sql) and is rendered by name, so one edit changes
 * both and the query-results corpus proves it. The census of
 * tools/audit/keystats-sql-census.cjs counts catalogue call sites by name and
 * every other statement by its normalized text.
 *
 * FEATURES & RATIONALE:
 * 1. Identical text in both drivers is a finding. The only texts both drivers
 *    may keep spelling are the transaction verbs, which are not queries.
 * 2. Every catalogue call site of the two drivers names a query that exists, so
 *    a rename cannot leave a driver rendering a name nobody defines.
 * 3. The catalogue is not shrinking silently: the names the two drivers render
 *    are pinned, and a name no driver renders is reported as unused.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Census = require('../audit/keystats-sql-census.cjs');
const Codegen = require('../codegen/codegen-keystats-queries.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const TRANSACTION_VERBS = new Set(['begin', 'commit', 'rollback']);

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

const rows = Census.census();
const queries = Codegen.parse(fs.readFileSync(path.join(ROOT, Codegen.SOURCE), 'utf8'));
const names = new Set(queries.map((query) => query.name));
const luaDrivers = new Set(['macos', 'linux']);

check('no statement is spelled by hand in both Lua drivers', () => {
	const byText = new Map();
	for (const row of rows) {
		if (!luaDrivers.has(row.driver) || row.exact.startsWith('catalogue:')) continue;
		if (TRANSACTION_VERBS.has(row.exact)) continue;
		const entry = byText.get(row.exact) ?? new Map();
		entry.set(row.driver, `${row.file}:${row.line}`);
		byText.set(row.exact, entry);
	}
	const shared = [...byText.entries()].filter(([, drivers]) => drivers.size === luaDrivers.size);
	assert.deepEqual(
		shared.map(([text, drivers]) => `${text} <- ${[...drivers.values()].join(', ')}`),
		[],
		'move these statements into _shared/data/db/queries.sql and render them by name'
	);
});

check('every catalogue name a driver renders is defined', () => {
	const used = rows.filter(
		(row) => luaDrivers.has(row.driver) && row.exact.startsWith('catalogue:')
	);
	assert.ok(used.length > 0, 'the census sees the catalogue call sites');
	for (const row of used) {
		const name = row.exact.slice('catalogue:'.length);
		assert.ok(names.has(name), `${row.file}:${row.line} renders an undefined query ${name}`);
	}
});

check('every catalogue query is rendered by at least one Lua driver', () => {
	const used = new Set(
		rows
			.filter((row) => luaDrivers.has(row.driver) && row.exact.startsWith('catalogue:'))
			.map((row) => row.exact.slice('catalogue:'.length))
	);
	assert.deepEqual(
		[...names].filter((name) => !used.has(name)),
		[],
		'a catalogue query no Lua driver renders'
	);
});

check('the revision read is one catalogue query rendered by both drivers', () => {
	const sites = rows.filter((row) => row.exact === 'catalogue:meta.rev');
	assert.deepEqual(sites.map((row) => row.driver).sort(), ['linux', 'macos']);
});

if (failures > 0) {
	console.error(`\n${failures} keystats shared SQL spelling check(s) failed.`);
	process.exit(1);
}
console.log('\nKeystats shared SQL spelling checks passed.');
