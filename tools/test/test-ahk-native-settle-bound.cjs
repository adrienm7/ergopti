// tools/test/test-ahk-native-settle-bound.cjs

/**
 * Keep the Windows tests that wait on a real child process or a native signal
 * on the suite's single TEST_NATIVE_SETTLE_TIMEOUT_MS. A stalled hosted runner
 * (CI run 45247903986) ran 10 to 50 times slower for minutes, so per-file
 * literals of 2 to 7 s failed healthy code. Child fixtures do not load the test
 * framework: their parent passes the bound as an argument or writes it into
 * the generated child source, so no child keeps a copy of the value.
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const TESTS = path.join(ROOT, 'static/ergopti_plus/windows/tests');
const BOUND = 'TEST_NATIVE_SETTLE_TIMEOUT_MS';

function read(relative) {
	return fs.readFileSync(path.join(TESTS, relative), 'utf8').replace(/^﻿/, '');
}

function count(text, needle) {
	return text.split(needle).length - 1;
}

const framework = read('test_framework.ahk');
const definitions = framework.match(new RegExp(`^global ${BOUND} := (\\d+)$`, 'gm')) || [];
assert.equal(definitions.length, 1, `the test framework defines ${BOUND} exactly once`);
assert.ok(Number(definitions[0].split(':= ')[1]) > 0, `${BOUND} is a positive bound`);

// Per-file limits that the shared bound replaced. Each name is retired, and the
// file must read the shared bound at least as often as it waited on its own.
const RETIRED_LIMITS = [
	{
		file: 'unit/core/process/shell_runner/test_tree_owned.ahk',
		names: [
			'SRTOW_PID_WAIT_MS',
			'SRTOW_EXIT_SIGNAL_SETTLE_MS',
			'SRTOW_NATURAL_WAIT_MS',
			'SRTOW_POLLER_RACE_WAIT_MS'
		],
		waits: 9
	},
	{
		file: 'unit/platform/focus/uia/test_worker_exit_reentry.ahk',
		names: ['_UER_NATIVE_WAIT_MS'],
		waits: 3
	},
	{
		file: 'unit/diagnostics/engine/control/test_driver_control.ahk',
		names: ['_TDCR_NATIVE_WAIT_MS'],
		waits: 1
	},
	{
		file: 'unit/platform/input/test_selection_capture_receiving.ahk',
		names: ['PWRS_CAPTURE_TIMEOUT_MS'],
		waits: 1
	},
	{
		file: 'fixtures/clipboardall_lock_observer.ahk',
		names: ['CALO_READER_WAIT_MS'],
		waits: 2
	},
	{ file: 'fixtures/clipboard_reader_hold.ahk', names: ['CRH_OPEN_WAIT_MS'], waits: 0 }
];
for (const { file, names, waits } of RETIRED_LIMITS) {
	const source = read(file);
	for (const name of names)
		assert.equal(count(source, name), 0, `${file}: ${name} is replaced by ${BOUND}`);
	const reads = (source.match(new RegExp(`(?:<|>=|, )\\s*(?:2 \\* )?${BOUND}\\b`, 'g')) || [])
		.length;
	assert.ok(reads >= waits, `${file}: ${waits} waits read ${BOUND}, found ${reads}`);
}

// Argument-fed children: the parent passes its bound, the child refuses to run
// without it and keeps no literal of its own.
const ARGUMENT_CHILDREN = [
	{
		parent: 'unit/platform/input/test_clipboardall_external_lock.ahk',
		child: 'fixtures/clipboardall_lock_observer.ahk',
		arity: 4,
		bound: BOUND
	},
	{
		parent: 'unit/platform/input/test_clipboard_reader_wait.ahk',
		child: 'fixtures/clipboard_reader_hold.ahk',
		arity: 3,
		bound: 'SettleMs'
	}
];
for (const { parent, child, arity, bound } of ARGUMENT_CHILDREN) {
	const parentSource = read(parent);
	const childSource = read(child);
	const fixture = path.basename(child);
	assert.ok(parentSource.includes(fixture), `${parent} spawns ${fixture}`);
	assert.ok(
		parentSource.includes(`String(${BOUND})]`),
		`${parent} passes ${BOUND} as the last argument of ${fixture}`
	);
	assert.ok(
		new RegExp(`${bound} := Integer\\(A_Args\\[${arity}\\]\\)`).test(childSource),
		`${child} reads its settle bound from argument ${arity}`
	);
	assert.ok(
		new RegExp(`A_Args\\.Length (?:==|!=) ${arity}\\b`).test(childSource),
		`${child} refuses a launch without its settle bound`
	);
	assert.ok(
		new RegExp(`A_TickCount - Started >= ${bound}\\b`).test(childSource),
		`${child} bounds its clipboard open wait by the passed bound`
	);
}

// Generated-source children: the parent writes its bound into the child source
// before the fixture body, and the named waits of the body read it.
const GENERATED_CHILDREN = [
	{
		parent: 'unit/gestures/engine/test_user_command_lifecycle_owner.ahk',
		child: 'fixtures/user_command_lifecycle_owner_body.ahk',
		waits: [
			`while !FileExist(Ready) && TickElapsed64(Begin) < ${BOUND} {`,
			`while _UserCommandEntries.Has("gesture__tap_3") && TickElapsed64(Begin) < ${BOUND} {`
		]
	},
	{
		parent: 'unit/modules/keystats/metrics/test_metrics_apps_dom_native.ahk',
		child: 'fixtures/worker_live_foreground_body.ahk',
		waits: [
			`while !State.Calls && TickElapsed64(Started) < ${BOUND} {`,
			`while _KLWF.Calls == 0 && TickElapsed64(Started) < ${BOUND} {`
		]
	}
];
for (const { parent, child, waits } of GENERATED_CHILDREN) {
	const parentSource = read(parent);
	const childSource = read(child);
	assert.ok(
		parentSource.includes(`"global ${BOUND} := " . ${BOUND} . "\`n"`),
		`${parent} writes ${BOUND} into the generated child source`
	);
	assert.ok(
		parentSource.indexOf(`"global ${BOUND} := "`) < parentSource.lastIndexOf(path.basename(child)),
		`${parent} defines the bound before it appends ${path.basename(child)}`
	);
	assert.ok(
		!new RegExp(`^global ${BOUND} :=`, 'm').test(childSource),
		`${child} keeps no copy of the bound`
	);
	for (const wait of waits) assert.equal(count(childSource, wait), 1, `${child}: ${wait}`);
	assert.ok(
		new RegExp(`TickElapsed64\\(Start(?:ed)?\\) < 2 \\* ${BOUND} \\{`).test(parentSource),
		`${parent} gives the whole child run room for the child's own bounded waits`
	);
}

console.log('ok - Windows native waits read the shared TEST_NATIVE_SETTLE_TIMEOUT_MS');
