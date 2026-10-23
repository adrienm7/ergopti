// tools/test/test-windows-native-hook-front.cjs

/**
 * ==============================================================================
 * MODULE: Windows Native Owner Hook Front Gate
 * DESCRIPTION:
 * Runs the real tracked ergopti_nav_owner.dll in a standalone AutoHotkey process
 * with a real foreign low-level hook installed after it (the position
 * AutoHotkey's own hook takes after every SendInput) and proves, through the
 * owner's hook-order counters, that
 *   1. the foreign hook first makes the owner blind to a key it swallows,
 *   2. one AutoHotkey-stamped Send burst makes the owner reinstall itself
 *      twice (the first pass and the settle pass) with no failure, and
 *   3. afterwards the owner sees the key first, before the foreign hook.
 * It sends F23 and F24 through the real input stream, so it needs an
 * interactive Windows desktop with AutoHotkey 2.0.26 x64; it is skipped on
 * every other OS (the owner is Windows-only) and never edits any file.
 *
 * ROOT CAUSE ENCODED:
 * AutoHotkey removes and reinstalls its keyboard hook around every SendInput and
 * Windows calls the newest hook first, so after the driver typed anything its
 * hotkeys decided before the owner (project-ahk-sendinput-puts-its-hook-first).
 * Run: node tools/test/test-windows-native-hook-front.cjs
 * ==============================================================================
 */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const WINDOWS = path.join(ROOT, 'static', 'ergopti_plus', 'windows');
const PROBE = path.join(WINDOWS, 'tests', 'hardware', 'hook_front_reassert.ahk');
const DLL = path.join(WINDOWS, 'vendor', 'ergopti_nav_owner.dll');
const AHK = process.env.ERGOPTI_AHK_EXE || 'C:\\Program Files\\AutoHotkey\\v2\\AutoHotkey64.exe';
const TIMEOUT_MS = 30000;

/**
 * Parses the probe's one-JSON-object-per-line output.
 * @param {string} stdout Probe standard output.
 * @returns {Map<string, object>} Phase records by name.
 */
function parsePhases(stdout) {
	const phases = new Map();
	for (const line of stdout.split(/\r?\n/)) {
		if (line.trim() === '') continue;
		const record = JSON.parse(line);
		assert.equal(phases.has(record.phase), false, `Phase ${record.phase} was reported twice.`);
		phases.set(record.phase, record);
	}
	return phases;
}

/**
 * Asserts the three phases against the mechanism's contract.
 * @param {Map<string, object>} phases Parsed probe output.
 */
function checkPhases(phases) {
	const first = phases.get('foreign_first');
	const burst = phases.get('burst');
	const ownerFirst = phases.get('owner_first');
	assert(
		first && burst && ownerFirst,
		'The probe must report foreign_first, burst and owner_first.'
	);
	// The foreign hook swallowed both edges before the owner could count them.
	assert.equal(first.foreign_seen, 1, 'The foreign hook must see the first probe key.');
	assert.equal(
		first.native_keys_delta,
		0,
		'A hook installed after the owner must hide the key from it.'
	);
	// One stamped burst arms the reassertion and the owner reinstalls twice.
	assert(burst.armed_delta >= 1, 'An AutoHotkey-stamped burst must arm the reassertion.');
	assert(burst.reinstalls_delta >= 2, 'The owner must run its first and its settle reinstall.');
	assert.equal(burst.failures, 0, 'No reinstall may fail.');
	assert.equal(burst.error, 0, 'No reinstall may leave an error code.');
	// Owner first now: it counts both edges of the probe key, the foreign hook still gets it.
	assert.equal(ownerFirst.native_keys_delta, 2, 'The owner must see both edges of the key again.');
	assert.equal(
		ownerFirst.foreign_seen,
		2,
		'The foreign hook must still receive the key from the owner.'
	);
	assert.equal(ownerFirst.failures, 0);
	const stop = phases.get('stop');
	assert(stop && stop.status === 0, 'The owner must stop cleanly.');
}

/**
 * Runs the pure rule check against deliberately wrong phase records.
 */
function checkNegativeControls() {
	const good = new Map([
		['foreign_first', { phase: 'foreign_first', native_keys_delta: 0, foreign_seen: 1 }],
		['burst', { phase: 'burst', armed_delta: 2, reinstalls_delta: 2, failures: 0, error: 0 }],
		['owner_first', { phase: 'owner_first', native_keys_delta: 2, foreign_seen: 2, failures: 0 }],
		['stop', { phase: 'stop', status: 0 }]
	]);
	checkPhases(good);
	const mutate = (phase, field, value) => {
		const copy = new Map([...good].map(([key, record]) => [key, { ...record }]));
		copy.get(phase)[field] = value;
		return copy;
	};
	assert.throws(() => checkPhases(mutate('foreign_first', 'native_keys_delta', 2)), /hide the key/);
	assert.throws(() => checkPhases(mutate('burst', 'reinstalls_delta', 1)), /settle reinstall/);
	assert.throws(() => checkPhases(mutate('owner_first', 'native_keys_delta', 0)), /see both edges/);
	assert.throws(() => checkPhases(mutate('burst', 'failures', 1)), /No reinstall may fail/);
}

checkNegativeControls();
if (process.platform !== 'win32') {
	console.log('Windows native hook front: skipped (the owner DLL is Windows-only).');
	process.exit(0);
}
assert(fs.existsSync(AHK), `AutoHotkey 2.0.26 x64 is required: ${AHK}`);
assert(fs.existsSync(DLL), `The tracked owner DLL is missing: ${DLL}`);
const run = spawnSync(AHK, ['/ErrorStdOut', PROBE, DLL], {
	encoding: 'utf8',
	timeout: TIMEOUT_MS,
	windowsHide: true
});
assert.equal(run.error, undefined, `The probe could not run: ${run.error && run.error.message}`);
assert.equal(run.status, 0, `The probe failed (exit ${run.status}): ${run.stdout}${run.stderr}`);
checkPhases(parsePhases(run.stdout));
console.log(
	'Windows native hook front: owner reinstalls in front after an AutoHotkey Send burst (passed).'
);
