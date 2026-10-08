// tools/test/test-managed-ollama-protocol.cjs

/** Receive portable source admission and operation closure without native credit. */
'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pythonExecutable } = require('../lib/python.cjs');

const cases = [
	['tools/test/managed_ollama_runtime_policy_test.py', 7],
	['tools/test/managed_ollama_pull_test.py', 8]
];
if (process.platform !== 'win32') {
	cases.push(['tools/test/macos_native_ollama_api_test.py', 8]);
	cases.push(['tools/diagnostics/macos_managed_ollama_receiving_test.py', 7]);
} else {
	process.stdout.write(
		'SKIP actual POSIX process peers on Windows; Apple SDK receiving is separate.\n'
	);
}
for (const [script, expected] of cases) {
	const result = spawnSync(pythonExecutable(), [script], {
		cwd: path.resolve(__dirname, '../..'),
		encoding: 'utf8',
		timeout: 60000
	});
	assert.equal(result.error, undefined, 'the portable receiver must start');
	assert.equal(result.signal, null, 'the portable receiver must retire');
	assert.equal(result.status, 0, result.stderr || result.stdout);
	assert.match(result.stderr, new RegExp(`Ran ${expected} tests in`));
	assert.match(result.stderr, /\bOK\b/);
	assert.doesNotMatch(result.stderr, /skipped=/);
	process.stdout.write(result.stdout);
	process.stdout.write(result.stderr);
}
process.stdout.write(
	'Native Go/macOS build, signing, model exchange and SDK admission were not executed.\n'
);
