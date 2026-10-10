// tools/test/test-linux-start-at-login.cjs

/**
 * ==============================================================================
 * MODULE: Linux Login Startup Regression
 * DESCRIPTION:
 * Exercises real startup helper files in a temporary installation with an inert
 * systemctl. No desktop setting or service outside the sandbox is changed.
 * ==============================================================================
 */

'use strict';

const assert = require('assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');

const root = path.resolve(__dirname, '../..');
const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-login-startup-'));
const posix = (value) =>
	value.replaceAll('\\', '/').replace(/^([A-Za-z]):/, (_, drive) => `/${drive.toLowerCase()}`);
try {
	const installed = path.join(sandbox, 'a space', 'lib/ergopti/linux/install');
	const stubs = path.join(sandbox, 'stubs');
	const config = path.join(sandbox, 'config');
	const calls = path.join(sandbox, 'calls');
	fs.mkdirSync(installed, { recursive: true });
	fs.mkdirSync(stubs);
	const script = path.join(installed, 'start_at_login.sh');
	fs.copyFileSync(path.join(root, 'static/ergopti_plus/linux/install/start_at_login.sh'), script);
	fs.copyFileSync(
		path.join(root, 'static/ergopti_plus/linux/install/desktop_entry.sh'),
		path.join(installed, 'desktop_entry.sh')
	);
	// Git Bash cannot reliably chmod NTFS directories; permission semantics are
	// exercised by the unchanged helper on Linux CI.
	if (process.platform === 'win32') {
		fs.writeFileSync(
			path.join(stubs, 'install'),
			'#!/bin/bash\n[ "$1" = -d ] && [ "$2" = -m ] || exit 1\nshift 3\nmkdir -p -- "$@"\n',
			{ mode: 0o755 }
		);
	}
	fs.writeFileSync(
		path.join(stubs, 'systemctl'),
		'#!/bin/bash\nprintf "%s\\n" "$*" >> "$CALL_LOG"\nif [ "$2" = is-enabled ]; then exit 1; fi\nif [ "$4" = list-unit-files ]; then [ "${NO_UNIT:-0}" = 1 ] || echo "ergopti-hotstrings.service disabled enabled"; exit 0; fi\n[ "${NO_UNIT:-0}" != 1 ] && [ "${REFUSE:-0}" != 1 ]\n',
		{ mode: 0o755 }
	);
	const env = {
		...process.env,
		HOME: posix(sandbox),
		XDG_CONFIG_HOME: posix(config),
		CALL_LOG: posix(calls),
		TEST_STUBS: posix(stubs)
	};
	const run = (action, extra = {}) =>
		spawnSync(
			bashExecutable(),
			[
				'-c',
				'export PATH="$TEST_STUBS:/usr/bin:/bin"; exec bash "$1" "$2"',
				'startup-test',
				posix(script),
				action
			],
			{ encoding: 'utf8', timeout: 10000, env: { ...env, ...extra } }
		);
	let result = run('status');
	assert.equal(result.status, 0, result.stderr);
	assert.equal(result.stdout.trim(), 'disabled');
	assert.ok(!fs.existsSync(config), 'reading state creates no startup files');
	result = run('enable');
	assert.equal(result.status, 0, result.stderr);
	const desktop = path.join(config, 'autostart/ergopti-hotstrings.desktop');
	assert.match(
		fs.readFileSync(desktop, 'utf8'),
		/^Exec=\/bin\/bash ".*a space.*" --session-start --tray$/m
	);
	assert.equal(run('status').stdout.trim(), 'enabled');
	assert.equal(run('disable').status, 0);
	assert.equal(run('status').stdout.trim(), 'disabled');
	assert.match(fs.readFileSync(desktop, 'utf8'), /^Hidden=true$/m);
	assert.doesNotMatch(
		fs.readFileSync(calls, 'utf8'),
		/--now|restart|stop|start\b/,
		'future sessions only'
	);
	const disabled = fs.readFileSync(desktop, 'utf8');
	assert.notEqual(run('enable', { REFUSE: '1' }).status, 0);
	assert.equal(
		fs.readFileSync(desktop, 'utf8'),
		disabled,
		'failed service mutation cannot publish a false enabled state'
	);
	assert.equal(
		run('enable', { NO_UNIT: '1' }).status,
		0,
		'an installation without a service can use XDG startup'
	);
	assert.equal(run('status').stdout.trim(), 'enabled');
	fs.writeFileSync(desktop, '[Desktop Entry]\nExec=/other/program\n');
	assert.equal(
		run('status').stdout.trim(),
		'other',
		'the actual foreign command is read-only conflict evidence'
	);
	assert.notEqual(run('disable').status, 0, 'foreign startup commands are never replaced');
	assert.equal(fs.readFileSync(desktop, 'utf8'), '[Desktop Entry]\nExec=/other/program\n');
	console.log(
		'PASS Linux login startup: explicit changes, read-only status, ownership and failure handling'
	);
} finally {
	assert.ok(path.resolve(sandbox).startsWith(path.resolve(os.tmpdir()) + path.sep));
	fs.rmSync(sandbox, { recursive: true, force: true });
}
