// tools/test/test-ahk-runner-arguments.cjs

/**
 * Execute the real runner's argument admission before its first include.
 * Invalid filters must never broaden a targeted run into the keyboard suite.
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '../..');
const entry = fs.readFileSync(
	path.join(root, 'static/ergopti_plus/windows/tests/run_all.ahk'),
	'utf8'
);
const boundary = /^#Include test_framework\.ahk\s*$/m.exec(entry);
assert.ok(boundary, 'the argument probe must stop before framework initialization');
const admission = entry.slice(0, boundary.index);
assert.doesNotMatch(
	admission,
	/^\s*#Include/im,
	'the isolated argument probe must include no driver or tests'
);
assert.match(admission, /A_Args/, 'the probe must execute the real native argument parser');

const e2eEntry = fs.readFileSync(
	path.join(root, 'static/ergopti_plus/windows/tests/e2e/run_e2e.ahk'),
	'utf8'
);
const e2eBoundary = /^#Include \.\.\/test_framework\.ahk\s*$/m.exec(e2eEntry);
assert.ok(e2eBoundary, 'the E2E probe must stop before framework initialization');
const e2eAdmission = e2eEntry.slice(0, e2eBoundary.index);
assert.doesNotMatch(e2eAdmission, /^\s*#Include/im);
assert.match(e2eAdmission, /A_Args/);

require('./support/ahk-registration-ownership.cjs');

if (process.platform !== 'win32') {
	console.log('[SKIP] native AHK runner arguments require Windows');
	process.exit(0);
}
const ahk = [
	process.env.ERGOPTI_REPLAY_AHK,
	'C:/Program Files/AutoHotkey/v2/AutoHotkey64.exe',
	'C:/Program Files/AutoHotkey/v2/AutoHotkey32.exe'
].find((file) => file && fs.existsSync(file));
if (!ahk) {
	console.log('[SKIP] native AHK runner arguments require AutoHotkey v2');
	process.exit(0);
}

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-runner-arguments-'));
try {
	const probe = path.join(dir, 'argument_admission.ahk');
	fs.writeFileSync(
		probe,
		admission.replace(/\r\n?/g, '\n') +
			'FileAppend("ADMITTED:" . _AHK_DRY_RUN . ":" . _AHK_ONLY_FILTER . "`n", "*")\nExitApp(0)\n',
		'utf8'
	);
	function invoke(args) {
		const result = spawnSync(ahk, ['/ErrorStdOut', probe, ...args], {
			encoding: 'utf8',
			windowsHide: true,
			timeout: 5000
		});
		assert.ifError(result.error);
		assert.notEqual(result.status, null, 'native exit receipt is required');
		return { status: result.status, out: result.stdout || '', err: result.stderr || '' };
	}
	for (const [args, expected] of [
		[[], 'ADMITTED:0:'],
		[['--dry-run'], 'ADMITTED:1:'],
		[['--only', 'specific slug'], 'ADMITTED:0:specific slug'],
		[['--dry-run', '--only=slug'], 'ADMITTED:1:slug'],
		[['--only=--slug'], 'ADMITTED:0:--slug'],
		[['--only', 'slug', '--dry-run'], 'ADMITTED:1:slug'],
		[['--only', '0'], 'ADMITTED:0:0']
	]) {
		const result = invoke(args);
		assert.equal(result.status, 0, JSON.stringify({ args, result }));
		assert.equal(result.out.trim(), expected);
		assert.equal(result.err, '');
	}
	console.log('AHK runner valid argument controls: ok');
	for (const args of [
		['--only'],
		['--only='],
		['--only', ''],
		['--only', '   '],
		['--only', '--dry-run'],
		['--onyl', 'slug'],
		['--dryrun'],
		['stray'],
		['--only=alpha', '--only=beta'],
		['--only', 'alpha', 'extra']
	]) {
		const result = invoke(args);
		assert.equal(
			result.status,
			2,
			'invalid arguments must fail before suite admission: ' + JSON.stringify({ args, result })
		);
		assert.doesNotMatch(result.out, /ADMITTED:/);
		assert.match(result.out + result.err, /Invalid test runner arguments/);
	}
	console.log('AHK runner rejects malformed arguments before test admission: ok');
	fs.writeFileSync(
		probe,
		e2eAdmission.replace(/\r\n?/g, '\n') +
			'FileAppend("ADMITTED:" . _AHK_DRY_RUN . ":" . _AHK_DUMP_PLAN . "`n", "*")\nExitApp(0)\n',
		'utf8'
	);
	for (const [args, expected] of [
		[[], 'ADMITTED:0:'],
		[['--dry-run'], 'ADMITTED:1:'],
		[['--dump-plan=plan.tsv'], 'ADMITTED:0:plan.tsv'],
		[['--dry-run', '--dump-plan=plan.tsv'], 'ADMITTED:1:plan.tsv'],
		[['--dump-plan=plan.tsv', '--dry-run'], 'ADMITTED:1:plan.tsv']
	]) {
		const result = invoke(args);
		assert.equal(result.status, 0, JSON.stringify({ args, result }));
		assert.equal(result.out.trim(), expected);
		assert.equal(result.err, '');
	}
	for (const args of [
		['--dump-plan'],
		['--dump-plan='],
		['--dump-plan=   '],
		['--dryrun'],
		['--only=slug'],
		['stray'],
		['--dry-run', '--dry-run'],
		['--dump-plan=a', '--dump-plan=b']
	]) {
		const result = invoke(args);
		assert.equal(result.status, 2, JSON.stringify({ args, result }));
		assert.doesNotMatch(result.out, /ADMITTED:/);
		assert.match(result.out + result.err, /Invalid E2E runner arguments/);
	}
	console.log('AHK E2E runner discovery argument controls: ok');
} finally {
	fs.rmSync(dir, { recursive: true, force: true });
}
