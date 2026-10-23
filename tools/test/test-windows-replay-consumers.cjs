// tools/test/test-windows-replay-consumers.cjs

/**
 * ==============================================================================
 * MODULE: Windows Replay Edge Consumer Gate
 * DESCRIPTION:
 * Terminal capture replays physical keyboard edges with SendInput, so every
 * AutoHotkey consumer sees them as injected. This gate
 *   1. runs replay_marker_consumers.ahk with the real hook and pins what a
 *      hotkey at each InputLevel, a physical-state read and the physical idle
 *      timer make of a replayed edge, against AutoHotkey Send controls, and
 *   2. checks that every native test case named by the lifecycle table of
 *      docs/todo-agents/windows-input-hooks-items-49-50.md still exists, so the
 *      audit's claims about down, repeat, up, owner change, pause and reload
 *      cannot be orphaned by a rename.
 * Step 1 sends F13 to F16 and a Shift tap through the real input stream: it
 * needs an interactive Windows desktop with AutoHotkey 2.0.26 x64 and is
 * skipped elsewhere. Step 2 runs on every OS.
 *
 * ROOT CAUSE ENCODED:
 * The audit read "a replayed edge reaches every hotkey and is never physical"
 * from AutoHotkey's documentation. The measurement turns it into a pinned fact.
 * Run: node tools/test/test-windows-replay-consumers.cjs
 * ==============================================================================
 */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const WINDOWS = path.join(ROOT, 'static', 'ergopti_plus', 'windows');
const NATIVE = path.join(WINDOWS, 'native', 'nav_event_owner');
const PROBE = path.join(WINDOWS, 'tests', 'hardware', 'replay_marker_consumers.ahk');
const DOC = path.join(ROOT, 'docs', 'todo-agents', 'windows-input-hooks-items-49-50.md');
const AHK = process.env.ERGOPTI_AHK_EXE || 'C:\\Program Files\\AutoHotkey\\v2\\AutoHotkey64.exe';
const LIFECYCLE = ['down and up', 'repeat', 'owner change while held', 'pause', 'reload and stop'];

/**
 * Pins the measured table.
 * @param {Map<string, object>} cases Probe records by case name.
 */
function checkMeasured(cases) {
	const replay = cases.get('replay_marker_edges');
	const unmarked = cases.get('unmarked_injected_edges');
	const level0 = cases.get('ahk_send_level0');
	const level3 = cases.get('ahk_send_level3');
	assert(replay && unmarked && level0 && level3, 'The probe must report every send case.');
	assert.equal(
		replay.fired_levels,
		'0,1,2,3',
		'A replayed edge must reach hotkeys of every InputLevel.'
	);
	assert.equal(
		unmarked.fired_levels,
		'0,1,2,3',
		'An unmarked injected edge must reach every InputLevel.'
	);
	assert.equal(
		level0.fired_levels,
		'',
		'AutoHotkey Send at level 0 must trigger no hotkey (control).'
	);
	assert.equal(
		level3.fired_levels,
		'0,1,2',
		'AutoHotkey Send at level 3 must trigger levels 0 to 2 (control).'
	);
	for (const record of [replay, unmarked, level0, level3]) {
		assert.equal(
			record.physical_reads_true,
			0,
			`${record.case}: an injected edge must never read as physical.`
		);
	}
	const shift = cases.get('injected_shift_state');
	assert(shift, 'The probe must report the injected Shift state.');
	assert.equal(shift.logical_down, 1, 'An injected Shift must be logically down.');
	assert.equal(shift.physical_down, 0, 'An injected Shift must not be physically down.');
	const idle = cases.get('physical_idle');
	assert(idle && idle.kept === 1, 'An injected edge must not restart the physical idle timer.');
}

/**
 * Returns the backtick-quoted case names of the lifecycle table.
 * @param {string} doc Audit document text.
 * @returns {Map<string, string[]>} Case names per lifecycle event.
 */
function lifecycleCases(doc) {
	const section = doc.split('### Lifecycle claims and the native tests that pin them')[1];
	assert(section, 'The audit document must keep its lifecycle table.');
	const table = section.split('\n## ')[0];
	const rows = new Map();
	for (const line of table.split('\n')) {
		const cells = line.split('|').map((cell) => cell.trim());
		if (cells.length < 5 || !LIFECYCLE.includes(cells[1])) continue;
		rows.set(
			cells[1],
			[...cells[3].matchAll(/`([^`]+)`/g)].map((match) => match[1])
		);
	}
	return rows;
}

/**
 * Checks the lifecycle table against the native test sources.
 */
function checkLifecycle() {
	const sources = fs
		.readdirSync(NATIVE)
		.filter((name) => name.endsWith('_test.c'))
		.map((name) => fs.readFileSync(path.join(NATIVE, name), 'utf8'))
		.join('\n');
	const rows = lifecycleCases(fs.readFileSync(DOC, 'utf8'));
	for (const event of LIFECYCLE) {
		const names = rows.get(event);
		assert(
			names && names.length > 0,
			`The lifecycle table must pin "${event}" with at least one case.`
		);
		for (const name of names) {
			assert(
				sources.includes(`{"${name}"`),
				`Lifecycle case "${name}" (${event}) is not registered in the native suites.`
			);
		}
	}
}

/**
 * Proves the checks can fail: wrong measurements and a missing case are refused.
 */
function checkNegativeControls() {
	const good = new Map([
		[
			'replay_marker_edges',
			{ case: 'replay_marker_edges', fired_levels: '0,1,2,3', physical_reads_true: 0 }
		],
		[
			'unmarked_injected_edges',
			{ case: 'unmarked_injected_edges', fired_levels: '0,1,2,3', physical_reads_true: 0 }
		],
		['ahk_send_level0', { case: 'ahk_send_level0', fired_levels: '', physical_reads_true: 0 }],
		['ahk_send_level3', { case: 'ahk_send_level3', fired_levels: '0,1,2', physical_reads_true: 0 }],
		['injected_shift_state', { case: 'injected_shift_state', logical_down: 1, physical_down: 0 }],
		['physical_idle', { case: 'physical_idle', kept: 1 }]
	]);
	checkMeasured(good);
	const mutate = (name, field, value) => {
		const copy = new Map([...good].map(([key, record]) => [key, { ...record }]));
		copy.get(name)[field] = value;
		return copy;
	};
	assert.throws(
		() => checkMeasured(mutate('replay_marker_edges', 'fired_levels', '0,1')),
		/every InputLevel/
	);
	assert.throws(() => checkMeasured(mutate('ahk_send_level0', 'fired_levels', '0')), /no hotkey/);
	assert.throws(
		() => checkMeasured(mutate('ahk_send_level3', 'physical_reads_true', 1)),
		/never read as physical/
	);
	assert.throws(
		() => checkMeasured(mutate('injected_shift_state', 'physical_down', 1)),
		/not be physically down/
	);
	const doc = fs.readFileSync(DOC, 'utf8');
	const orphaned = doc.replace('`suspend is fail-open`', '`suspend is renamed away`');
	assert.notEqual(orphaned, doc, 'The negative control needs a case to rename.');
	const rows = lifecycleCases(orphaned);
	assert(rows.get('pause').includes('suspend is renamed away'));
}

checkNegativeControls();
checkLifecycle();
if (process.platform !== 'win32') {
	console.log(
		'Windows replay consumers: lifecycle table checked; the hook measurement is Windows-only.'
	);
	process.exit(0);
}
assert(fs.existsSync(AHK), `AutoHotkey 2.0.26 x64 is required: ${AHK}`);
const run = spawnSync(AHK, ['/ErrorStdOut', PROBE], {
	encoding: 'utf8',
	timeout: 30000,
	windowsHide: true
});
assert.equal(run.error, undefined, `The probe could not run: ${run.error && run.error.message}`);
assert.equal(run.status, 0, `The probe failed (exit ${run.status}): ${run.stdout}${run.stderr}`);
const cases = new Map();
for (const line of run.stdout.split(/\r?\n/)) {
	if (line.trim() === '') continue;
	const record = JSON.parse(line);
	assert.equal(cases.has(record.case), false, `Case ${record.case} was reported twice.`);
	cases.set(record.case, record);
}
checkMeasured(cases);
console.log('Windows replay consumers: measured table and lifecycle cases verified (passed).');
