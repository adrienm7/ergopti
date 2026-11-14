// tools/test/test-ahk-parallel.cjs
'use strict';

/** Pins the parallel runner's reading of results: a wrong mapping would mark the wrong test green. */
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const {
	parseTap,
	foldResults,
	takeChunk,
	guidedChunkSeconds,
	splitPhases,
	defaultWorkers,
	formatReport,
	parseArguments
} = require('./ahk-parallel.cjs');
const {
	sessionUses,
	readFixtures,
	exclusiveReasons,
	exclusiveTests,
	unreachedSessionFixtures
} = require('./ahk-session-resources.cjs');

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

// Much work left spends the full budget; the tail shrinks to the floor, so workers end together.
const sizing = { chunkSeconds: 300, minChunkSeconds: 60, unknownTestMs: 1000 };
assert.equal(guidedChunkSeconds(['a'], { a: 3600000 }, 2, sizing), 300);
assert.equal(guidedChunkSeconds(['a'], { a: 800000 }, 2, sizing), 200);
assert.equal(guidedChunkSeconds(['a'], { a: 1000 }, 2, sizing), 60);
assert.equal(guidedChunkSeconds(['a', 'b'], {}, 1, sizing), 60);
assert.equal(guidedChunkSeconds(['a'], { a: 1000 }, 2, { ...sizing, chunkSeconds: 30 }), 30);

// The default follows the CPUs until free memory is what limits it, and never reaches zero.
const GB = 1024 * 1024 * 1024;
assert.equal(defaultWorkers(8, 32 * GB), 4);
assert.equal(defaultWorkers(8, 2 * GB), 2);
assert.equal(defaultWorkers(8, 0.5 * GB), 1);
assert.equal(defaultWorkers(1, 32 * GB), 1);

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

// Whatever is selected, the two phases partition it: exclusive tests never join the workers.
assert.deepEqual(splitPhases(['a', 'b', 'c'], new Set(['b', 'z'])), {
	shared: ['a', 'c'],
	exclusive: ['b']
});

// Real use counts; a quoted name, a comment, an HTTP request and a fake transport do not.
assert.deepEqual(sessionUses('A_Clipboard := "x"'), ['A_Clipboard']);
assert.deepEqual(sessionUses('DllCall("user32\\OpenClipboard", "Ptr", 0)'), ['OpenClipboard']);
assert.deepEqual(sessionUses('DllCall("SetForegroundWindow", "Ptr", Hwnd)'), [
	'SetForegroundWindow'
]);
assert.deepEqual(sessionUses('\tSendInput("x")\n\tEdit.Focus()'), ['.Focus', 'SendInput']);
assert.deepEqual(sessionUses('CB_OpenClipboardWithin(A_ScriptHwnd)'), ['CB_OpenClipboardWithin']);
assert.deepEqual(sessionUses('Assert(InStr(Src, "SendInput("))'), []);
assert.deepEqual(sessionUses('; SendInput("x")\n/* WinActivate(x) */'), []);
assert.deepEqual(sessionUses('Request.Send(Body)'), []);
assert.deepEqual(sessionUses('class Fake {\n\tSend(Body) {\n\t}\n}\nSend(1)'), []);

// A fixture counts for the test naming it, through a wrapper too, and a marker adds a file.
function withTests(files, check) {
	const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-session-'));
	try {
		for (const [file, source] of Object.entries(files)) {
			fs.mkdirSync(path.dirname(path.join(directory, file)), { recursive: true });
			fs.writeFileSync(path.join(directory, file), source);
		}
		check(directory);
	} finally {
		fs.rmSync(directory, { recursive: true, force: true });
	}
}
withTests(
	{
		'fixtures/owner_wrapper.ahk': '#Include owner_body.ahk\n',
		'fixtures/owner_body.ahk': 'A_Clipboard := "x"\n',
		'fixtures/calm_body.ahk': 'x := 1\n',
		'fixtures/orphan_body.ahk': 'SendInput("x")\n',
		'fixtures/manual_body.ahk': '; ahk-parallel: operator-only run by hand\nSendInput("x")\n',
		'unit/wrapped.ahk': 'Run("owner_wrapper.ahk")\n',
		'unit/calm.ahk': 'Run("calm_body.ahk")\n',
		'unit/declared.ahk': '; ahk-parallel: session-exclusive production pastes\n',
		'unit/bare_marker.ahk': '; ahk-parallel: session-exclusive\n'
	},
	(directory) => {
		const plan = ['wrapped', 'calm', 'declared', 'bare_marker'].map((name) => ({
			name,
			file: `unit/${name}.ahk`
		}));
		plan.push({ name: 'calm', file: 'unit/declared.ahk' });
		assert.deepEqual([...exclusiveTests(plan, directory)].sort(), ['calm', 'declared', 'wrapped']);
		// A session fixture nothing names has a test that would run among neighbours.
		assert.deepEqual(unreachedSessionFixtures(directory), ['orphan_body']);
	}
);

// The gate on the real suite: every session fixture is reached, and each test
// file that failed among neighbours on 2026-11-01 stays exclusive.
const TESTS_DIR = path.resolve(__dirname, '../../static/ergopti_plus/windows/tests');
assert.deepEqual(unreachedSessionFixtures(TESTS_DIR), []);
const fixtures = readFixtures(TESTS_DIR);
for (const file of [
	'unit/adapters/input/test_clipboard_restore_debt_cas.ahk',
	'unit/adapters/input/test_suppressive_capture_settlement.ahk',
	'unit/adapters/input/test_plain_native_cas_owner.ahk',
	'unit/adapters/input/test_clipboardall_external_lock.ahk',
	'unit/infra/input_probe/test_input_probe_rival_owner.ahk',
	'unit/infra/input_probe/test_input_probe_entry_owner.ahk',
	'unit/core/ui/tooltip/test_hostile_native64.ahk',
	'unit/modules/hotstrings/engine/test_sendinstant_clipboard_owner.ahk',
	'unit/modules/gestures/test_gesture_plain_clipboard_owner.ahk'
]) {
	const source = fs.readFileSync(path.join(TESTS_DIR, file), 'utf8');
	assert.notDeepEqual(exclusiveReasons(source, fixtures), [], file);
}

// The machine lock: a second runner is refused with the holder's name, a waiter
// gets in when the holder leaves, and a killed holder leaves nothing behind.
const { spawn } = require('node:child_process');
const { acquireMachineLock } = require('./ahk-machine-lock.cjs');

async function lockControls() {
	const name = `ergopti-ahk-parallel-selftest-${process.pid}`;
	const holder = { pid: 1, checkout: 'D:/one', commit: 'abc', started: 'now', only: 'filter' };
	const held = await acquireMachineLock(holder, { name });
	await assert.rejects(
		acquireMachineLock({ pid: 2 }, { name }),
		/holds this machine: PID 1 in D:\/one at abc, since now, --only="filter"/
	);
	await assert.rejects(
		acquireMachineLock({ pid: 2 }, { name, waitMinutes: 0.0001, pollMs: 5, log: () => {} }),
		/Gave up after/
	);
	const log = [];
	const waiter = acquireMachineLock(
		{ pid: 2 },
		{ name, waitMinutes: 1, pollMs: 20, log: (line) => log.push(line) }
	);
	await new Promise((resolve) => setTimeout(resolve, 100));
	await new Promise((resolve) => held.close(resolve));
	const next = await waiter;
	assert.match(log[0], /Waiting for the machine lock, held by PID 1/);
	await new Promise((resolve) => next.close(resolve));

	// Only a real process death proves the kernel frees the name. Unix sockets leave
	// their file behind, and the runner itself is Windows only.
	if (process.platform === 'win32') {
		const script = `require(${JSON.stringify(require.resolve('./ahk-machine-lock.cjs'))}).acquireMachineLock({pid:process.pid},{name:${JSON.stringify(name)}}).then(()=>console.log('held'))`;
		const child = spawn(process.execPath, ['-e', script], {
			stdio: ['ignore', 'pipe', 'inherit']
		});
		await new Promise((resolve) => child.stdout.once('data', resolve));
		await assert.rejects(acquireMachineLock({ pid: 2 }, { name }), /holds this machine/);
		const ended = new Promise((resolve) => child.once('close', resolve));
		child.kill('SIGKILL');
		await ended;
		const reclaimed = await acquireMachineLock({ pid: 2 }, { name });
		await new Promise((resolve) => reclaimed.close(resolve));
	}
}

assert.equal(parseArguments(['--wait=5']).waitMinutes, 5);
assert.equal(parseArguments(['--wait']).waitMinutes, 180);
assert.equal(parseArguments([]).waitMinutes, 0);
assert.throws(() => parseArguments(['--wait=soon']), /--wait/);

lockControls().then(
	() => console.log('ahk-parallel: ok'),
	(error) => {
		console.error(error);
		process.exit(1);
	}
);
