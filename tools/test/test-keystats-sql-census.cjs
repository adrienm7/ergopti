// tools/test/test-keystats-sql-census.cjs

/**
 * ==============================================================================
 * MODULE: Keystats SQL Census Test
 * DESCRIPTION:
 * Pins the extractor behind tools/audit/keystats-sql-census.cjs: a statement
 * split across concatenated lines is one statement, a spliced filter becomes
 * `?`, the code after a chain is never swallowed into it, and the in-process
 * and CLI spellings of one projection share a shape. Without these the census
 * silently miscounts, and a parity finding hides behind a parser artefact.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const Census = require('../audit/keystats-sql-census.cjs');

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

const statementsOf = (source, ext) =>
	Census.chains(Census.tokenize(source, ext)).flatMap((c) => Census.splitStatements(c.text));

check('an AHK chain continued by leading operators is one statement', () => {
	const source = [
		'KLR__SumLayouts(db, manifest, where) {',
		'\tsql := "SELECT date, app, layout, SUM(count) AS count"',
		'\t\t. " FROM agg_app_day_layouts" . where . " GROUP BY date, app, layout"',
		'\tfor r in KLR_ProjectionQuery(db, sql, "manifest", "layouts") {',
		'\t}',
		'}'
	].join('\n');
	assert.deepEqual(statementsOf(source, '.ahk'), [
		'SELECT date, app, layout, SUM(count) AS count FROM agg_app_day_layouts ?  GROUP BY date, app, layout'
	]);
});

check('a chain ending in a spliced operand does not swallow the next line', () => {
	const source = [
		'\tsql := "SELECT date, app FROM agg_app_day_session" . where',
		'\tfor r in KLR_ProjectionQuery(db, sql, "manifest", "session") {'
	].join('\n');
	assert.deepEqual(statementsOf(source, '.ahk'), ['SELECT date, app FROM agg_app_day_session ?']);
});

check('a Lua string.format template replaces its slots and stops at the argument list', () => {
	const source =
		'for r in _rows(db, string.format([[\n\tSELECT token FROM %s %s\n]], tbl, where), pacer) do end';
	assert.deepEqual(statementsOf(source, '.lua'), ['SELECT token FROM ? ?']);
});

check('commented SQL is not counted', () => {
	assert.deepEqual(statementsOf('-- "SELECT 1"\nlocal x = 1', '.lua'), []);
	assert.deepEqual(statementsOf('; "SELECT 1"\nx := 1', '.ahk'), []);
});

check('the CLI json_quote spelling and the in-process spelling share one shape', () => {
	const cli =
		'SELECT date, json_quote(app) AS app_json, SUM(c) AS c FROM agg_app_day_titles? GROUP BY date, app';
	const native = 'SELECT date, app, SUM(c) AS c FROM agg_app_day_titles ? GROUP BY date, app';
	assert.equal(Census.shape(cli), Census.shape(native));
	assert.notEqual(Census.normalize(cli), Census.normalize(native));
});

check('the live census finds the manifest projection in all three drivers', () => {
	const rows = Census.census();
	for (const family of ['select agg_app_day_chars_class', 'select agg_app_day_hourly_min5']) {
		const drivers = new Set(rows.filter((r) => r.family === family).map((r) => r.driver));
		const catalogued = rows.some((r) => r.family.startsWith('catalogue manifest.'));
		// Once a driver renders the query by name it is counted as a catalogue site.
		for (const driver of ['windows', 'macos', 'linux'])
			assert.ok(
				drivers.has(driver) ||
					(catalogued &&
						rows.some((r) => r.driver === driver && r.family.startsWith('catalogue '))),
				`${driver} must contribute ${family}`
			);
	}
});

if (failures > 0) {
	console.error(`\n${failures} keystats SQL census check(s) failed.`);
	process.exit(1);
}
console.log('\nKeystats SQL census checks passed.');
