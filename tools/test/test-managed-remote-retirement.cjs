// tools/test/test-managed-remote-retirement.cjs

/** Exercise the actual managed fixture accept/retirement bodies on owned TCP. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

if (process.platform !== 'win32') {
	console.log('SKIP: managed fixture retirement requires Windows PowerShell and owned loopback.');
	process.exit(0);
}

const powershell = path.join(
	process.env.SystemRoot,
	'System32/WindowsPowerShell/v1.0/powershell.exe'
);
assert.ok(fs.existsSync(powershell), 'The real Windows PowerShell runtime is required.');
const script = path.join(__dirname, 'test_managed_remote_retirement.ps1');
const result = spawnSync(
	powershell,
	['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', script],
	{ encoding: 'utf8', windowsHide: true }
);
assert.ifError(result.error);
assert.equal(result.status, 0, result.stdout + result.stderr);
assert.equal(result.stderr, '', 'The real fixture body compilation and execution must be quiet.');
assert.deepEqual(result.stdout.trim().split(/\r?\n/), [
	'PASS admitted-client exact close and retirement',
	'PASS late-client admission refusal and retirement'
]);
console.log(
	'PASS: actual fixture bodies retire admitted clients and reject late accepted clients.'
);
