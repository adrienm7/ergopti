// tools/test/test-logger-lifecycle-pairing.cjs

/**
 * ==============================================================================
 * MODULE: Logger Lifecycle Pairing Gate
 * DESCRIPTION:
 * Holds every driver to the pairing rule only Windows used to check
 * (windows/tests/meta/core/logger/test_pairing.ahk): per production file, a
 * START needs a SUCCESS and TRACE operations may not outnumber DONE terminals.
 * The census lives in tools/lib/logger-lifecycle-pairing.cjs and runs over the
 * Windows AHK sources, the macOS and Linux Lua sources and the shared Lua
 * engines.
 *
 * ROOT CAUSE ENCODED (logger parity audit LOG-06):
 * Fifteen macOS and Linux files opened a lifecycle they never closed, for
 * example `modules/keystats/text_cipher.lua` on both drivers, whose « Deriving
 * the at-rest key… » START had no SUCCESS, and macOS `infra/phase_stats.lua`,
 * whose two STARTs were closed by DONE, across the two axes. Nothing checked
 * the Lua sources, so a silent failure and a silent success read the same.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const Pairing = require('../lib/logger-lifecycle-pairing.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS = path.join(ROOT, 'static', 'ergopti_plus');

/** Counts of one snippet, as "start/success/trace/done". */
function counts(text, extension) {
	const c = Pairing.lifecycleCounts(text, extension);
	return `${c.start}/${c.success}/${c.trace}/${c.done}`;
}

// ── Lua call shapes ─────────────────────────────────────────────────────────

assert.equal(counts('Logger.start(LOG, "a")\nLogger.success(LOG, "b")', '.lua'), '1/1/0/0');
assert.equal(counts('Logger.trace (LOG, "a")\nlog:done(LOG, "b")', '.lua'), '0/0/1/1');
assert.equal(counts('ports.logger.start(tag, "a")\nlogger.success(tag, "b")', '.lua'), '1/1/0/0');
// A protected call is still a call.
assert.equal(
	counts('pcall(Logger.start, LOG, "a")\nxpcall(Logger.done, h, LOG)', '.lua'),
	'1/0/0/1'
);
// Comments, strings, other receivers and the API's own declaration are not calls.
assert.equal(
	counts(
		[
			'-- Logger.success(LOG, "commented")',
			'--[[ Logger.done(LOG, "long comment") ]]',
			'local s = "Logger.success(LOG)"',
			'timer:start()',
			'M.success(x)',
			'function Logger.start(module, msg) end',
			'function M.logger.done() end',
			'local f = Logger.success',
			'Logger.start(LOG, "real")'
		].join('\n'),
		'.lua'
	),
	'1/0/0/0'
);

// ── AHK call shapes ─────────────────────────────────────────────────────────

assert.equal(
	counts('Probe() {\n LoggerStart("A", "x")\n LoggerSuccess("A", "y")\n}\n', '.ahk'),
	'1/1/0/0'
);
// AHK names are case-insensitive, as on the Windows gate.
assert.equal(counts('Bad() {\n lOgGeRtRaCe("A", "x")\n}\n', '.ahk'), '0/0/1/0');
assert.equal(
	counts(
		'LoggerStart(Tag, Msg, Args*) {\n}\n; LoggerSuccess("A")\nX := "LoggerSuccess(noise)"\n LoggerStart("A", "x")\n',
		'.ahk'
	),
	'1/0/0/0'
);

// ── The Windows rule ────────────────────────────────────────────────────────

assert.deepEqual(Pairing.pairingViolations({ start: 1, success: 0, trace: 0, done: 0 }), [
	'1 START but no SUCCESS'
]);
// Two TRACE operations with one DONE fail even though both tokens exist.
assert.deepEqual(Pairing.pairingViolations({ start: 0, success: 0, trace: 2, done: 1 }), [
	'2 TRACE but 1 DONE'
]);
// A START closed by DONE crosses the axes: both pairs are broken.
assert.deepEqual(Pairing.pairingViolations({ start: 2, success: 0, trace: 0, done: 2 }), [
	'2 START but no SUCCESS'
]);
assert.deepEqual(Pairing.pairingViolations({ start: 3, success: 1, trace: 2, done: 2 }), []);

// ── The census on a private tree ────────────────────────────────────────────

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-lifecycle-pairing-'));
try {
	const write = (rel, text) => {
		fs.mkdirSync(path.dirname(path.join(scratch, rel)), { recursive: true });
		fs.writeFileSync(path.join(scratch, rel), text);
	};
	write('modules/keystats/text_cipher.lua', 'Logger.start(LOG, "Deriving…")\nreturn key\n');
	write('infra/good.lua', 'Logger.trace(LOG, "a")\nLogger.done(LOG, "b")\n');
	write('async/opener.lua', 'Logger.start(LOG, "a")\nLogger.trace(LOG, "b")\n');
	// Non-production trees are never read.
	write('tests/unit/bad.lua', 'Logger.start(LOG, "a")\n');
	write('_generated/bad.lua', 'Logger.start(LOG, "a")\n');
	const exempt = new Map([['probe/async/opener.lua', 'closes in another file']]);
	const result = Pairing.censusTree(scratch, '.lua', 'probe', exempt);
	assert.equal(result.files, 3);
	assert.deepEqual(result.exemptUsed, ['probe/async/opener.lua']);
	// The exemption covers the START only; the exempt file's TRACE still counts.
	assert.deepEqual(result.violations, [
		'probe/async/opener.lua: 1 TRACE but 0 DONE',
		'probe/modules/keystats/text_cipher.lua: 1 START but no SUCCESS'
	]);
	assert.throws(
		() => Pairing.censusTree(path.join(scratch, 'missing'), '.lua', 'probe'),
		/existing directory/
	);
	// A tree whose only sources are tests cannot certify a clean census.
	write('empty/tests/only.lua', 'Logger.start(LOG, "a")\n');
	assert.throws(
		() => Pairing.censusTree(path.join(scratch, 'empty'), '.lua', 'probe'),
		/found no \.lua file/
	);
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}

// ── The real drivers ────────────────────────────────────────────────────────

const TREES = [
	['windows', '.ahk'],
	['macos', '.lua'],
	['linux', '.lua'],
	['_shared', '.lua']
];
const violations = [];
const exemptUsed = new Set();
for (const [tree, extension] of TREES) {
	const result = Pairing.censusTree(path.join(DRIVERS, tree), extension, tree);
	assert.ok(result.producers > 0, `${tree}: the census must inspect actual lifecycle producers`);
	violations.push(...result.violations);
	for (const key of result.exemptUsed) exemptUsed.add(key);
}
for (const key of Pairing.EXEMPT.keys())
	assert.ok(exemptUsed.has(key), `stale lifecycle exemption, no such production file: ${key}`);
assert.deepEqual(violations, [], `unpaired lifecycle logs:\n  ${violations.join('\n  ')}`);

console.log(
	`[OK] logger lifecycle pairing: every START has a SUCCESS and no TRACE outnumbers its DONE ` +
		`(${TREES.map(([t]) => t).join(', ')}).`
);
