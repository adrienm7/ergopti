// tools/test/test-apple-shortcuts-event-diagnostic.cjs

/**
 * ==============================================================================
 * MODULE: Shortcuts Event Diagnostic Controls
 * DESCRIPTION:
 * Runs controlled JXA getters and the real Python capture/validator with recording
 * process ports. These controls do not qualify a native catalogue or invocation.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');

function run(command, args) {
	const result = spawnSync(command, args, {
		cwd: root,
		encoding: 'utf8',
		timeout: 30000,
		env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' }
	});
	assert.equal(result.error, undefined, 'diagnostic controls must actually start');
	assert.equal(result.signal, null);
	assert.equal(result.status, 0, result.stdout + result.stderr);
	return result;
}

for (const [file, count, label] of [
	['test_probe.cjs', 13, 'Controlled JXA'],
	['test_diagnostic.cjs', 20, 'Controlled diagnostic JXA']
]) {
	const result = run(process.execPath, ['tools/diagnostics/apple_shortcuts_probe/' + file]);
	assert.equal(result.stderr, '');
	assert.ok(
		result.stdout.includes(
			label + ' cases: ' + count + ' passed, 0 failed; native execution untested'
		)
	);
}
for (const [file, count] of [
	['test_probe.py', 18],
	['test_diagnostic.py', 17]
]) {
	const result = run(process.platform === 'win32' ? 'python' : 'python3', [
		'-m',
		'unittest',
		'discover',
		'-s',
		'tools/diagnostics/apple_shortcuts_probe',
		'-p',
		file
	]);
	assert.equal(result.stdout, '');
	assert.ok(result.stderr.includes('Ran ' + count + ' tests in '));
	assert.match(result.stderr, /\nOK\s*$/);
	assert.doesNotMatch(result.stderr, /skipped|FAILED/);
}
process.stdout.write(
	'Shortcuts event diagnostic recording controls passed; native execution pending.\n'
);
