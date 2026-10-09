// tools/test/test-macos-native-http-receiving.cjs

/** Run the actual owned-pipe receiver and shared routing controls. */
'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pythonExecutable } = require('../lib/python.cjs');

/** Require one complete planned-count line across LF and CRLF transports. */
function hasPlannedCases(output, count) {
	if (typeof output !== 'string' || !output.endsWith('\n')) return false;
	const witness = `Planned cases: ${count}`;
	return output.split(/\r?\n/).filter((line) => line === witness).length === 1;
}

// These portable parser controls run in the existing mandatory receiving owner.
for (const ending of ['\n', '\r\n']) {
	assert.ok(hasPlannedCases('Planned cases: 2' + ending, 2));
}
for (const rejected of [
	'',
	'Planned cases: 3\n',
	'Planned cases: 2',
	'Planned cases: 2\r',
	'Planned cases: 2\nPlanned cases: 2\n',
	'Planned cases: 2\r\nPlanned cases: 2\r\n'
]) {
	assert.equal(hasPlannedCases(rejected, 2), false);
}

const root = path.resolve(__dirname, '../..');
const selection = process.platform === 'win32' ? '--policy-only' : '--protocol-only';
const expectedCases = process.platform === 'win32' ? 2 : 10;
const result = spawnSync(
	pythonExecutable(),
	['static/ergopti_plus/macos/tests/support/native_http_receiving_test.py', selection],
	{ cwd: root, encoding: 'utf8', timeout: 60000 }
);
assert.equal(result.error, undefined, 'the receiving interpreter must start');
assert.equal(result.signal, null, 'the receiving process must finish within its bound');
assert.equal(result.status, 0, result.stderr || result.stdout);
assert.ok(hasPlannedCases(result.stdout, expectedCases));
assert.ok(result.stderr.includes(`Ran ${expectedCases} tests in`));
assert.match(result.stderr, /\bOK\b/);
assert.doesNotMatch(result.stderr, /skipped=/);
process.stdout.write(result.stdout);
process.stdout.write(result.stderr);

const portableOwners = [['tools/test/macos_managed_http_test_deps_test.py', 3]];
if (process.platform !== 'win32') {
	portableOwners.push([
		'static/ergopti_plus/macos/tests/support/native_http_wire_fixture_test.py',
		3
	]);
}
for (const [script, expected] of portableOwners) {
	const owner = spawnSync(pythonExecutable(), [script], {
		cwd: root,
		encoding: 'utf8',
		timeout: 60000
	});
	assert.equal(owner.error, undefined, 'the independent fixture owner must start');
	assert.equal(owner.signal, null, 'the independent fixture owner must retire');
	assert.equal(owner.status, 0, owner.stderr || owner.stdout);
	assert.match(owner.stderr, new RegExp(`Ran ${expected} tests in`));
	assert.match(owner.stderr, /\bOK\b/);
	assert.doesNotMatch(owner.stderr, /skipped=/);
	process.stdout.write(owner.stdout);
	process.stdout.write(owner.stderr);
}
