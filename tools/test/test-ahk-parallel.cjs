// tools/test/test-ahk-parallel.cjs
'use strict';

/** Pins the parallel runner's reading of results: a wrong mapping would mark the wrong test green. */
const assert = require('node:assert/strict');
const {
	parseTap,
	foldResults,
	takeChunk,
	formatReport,
	parseArguments
} = require('./ahk-parallel.cjs');

// --list runs in registry order: an index maps to its RUNNING line, not to the list file.
const tap = [
	'﻿# [boot] loading',
	'1..3',
	'RUNNING 1/3 - zeta',
	'ok 1 - zeta',
	'# duration_ms 1 12.500',
	'RUNNING 2/3 - alpha',
	'not ok 2 - alpha — it broke [a.ahk:3]',
	'# duration_ms 2 40.000',
	'#   replay: & x',
	'RUNNING 3/3 - gamma',
	'ok 3 - gamma # SKIP NOT EXECUTED on this host',
	'# duration_ms 3 1.000',
	'RUNNING 4/4 - died here'
].join('\r\n');
const parsed = parseTap(tap);
assert.equal(parsed.plan, 3);
assert.deepEqual(
	parsed.results.map((result) => [result.name, result.status, result.ms]),
	[
		['zeta', 'ok', 12.5],
		['alpha', 'not ok', 40],
		['gamma', 'skip', 1]
	]
);
assert.match(parsed.results[1].detail, /it broke/);

// A result without its RUNNING line belongs to no known test.
assert.equal(parseTap('ok 1 - stray').results.length, 0);

// Same-named tests run together: a failure of either one holds, durations add up.
const entries = {};
const seen = foldResults(entries, [
	{ name: 'twin', status: 'not ok', detail: 'first', ms: 5 },
	{ name: 'twin', status: 'ok', detail: '', ms: 7 }
]);
assert.deepEqual([...seen], ['twin']);
assert.deepEqual(entries.twin, { status: 'not ok', detail: 'first', ms: 12 });

// A chunk stops at its time budget, always takes one test, and spends the unknown default.
const limits = { chunkSeconds: 1, chunkMaxTests: 3, unknownTestMs: 400 };
const names = ['a', 'b', 'c', 'd', 'e'];
assert.deepEqual(takeChunk(names, { a: 900, b: 900 }, limits), ['a']);
assert.deepEqual(takeChunk(names, { b: 5000 }, limits), ['b']);
assert.deepEqual(takeChunk(names, {}, limits), ['c', 'd']);
assert.deepEqual(names, ['e']);
assert.deepEqual(takeChunk(['p', 'q', 'r', 's'], { p: 1, q: 1, r: 1, s: 1 }, limits), [
	'p',
	'q',
	'r'
]);

const report = formatReport(
	{
		plan: { slow: 'unit/a.ahk' },
		entries: { slow: { ms: 4000 }, fast: { ms: 2 }, none: { ms: 0 } }
	},
	1
);
assert.match(report, /2 timed tests/);
assert.match(report, /4\.0 {2}slow/);
assert.doesNotMatch(report, /fast/);
assert.match(report, /unit\/a\.ahk/);

assert.throws(() => parseArguments(['--nope']), /Unknown option/);
assert.throws(() => parseArguments(['--workers=0']), /positive integer/);
assert.throws(() => parseArguments(['--fresh', '--rerun-failures']), /forgets/);
assert.equal(parseArguments(['--only=a=b']).only, 'a=b');
assert.equal(parseArguments(['--report']).report, 30);

console.log('ahk-parallel: ok');
