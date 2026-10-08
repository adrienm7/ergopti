// tools/test/test-macos-managed-bootstrap-http.cjs

/** Receive actual pinned bootstrap publication and redirect controls. */
'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pythonExecutable } = require('../lib/python.cjs');

if (process.platform === 'win32') {
	console.log(
		'[DEFERRED] POSIX exclusive bootstrap publication runs in Core / js on Ubuntu and native macOS CI; not executed on Windows.'
	);
	process.exit(0);
}
const result = spawnSync(pythonExecutable(), ['tools/test/macos_managed_bootstrap_http_test.py'], {
	cwd: path.resolve(__dirname, '../..'),
	encoding: 'utf8',
	timeout: 60000
});
assert.equal(result.error, undefined, 'the bootstrap receiver must start');
assert.equal(result.signal, null, 'the bootstrap receiver must close within its bound');
assert.equal(result.status, 0, result.stderr || result.stdout);
assert.match(result.stderr, /Ran 21 tests in/);
assert.match(result.stderr, /\bOK\b/);
assert.doesNotMatch(result.stderr, /skipped=/);
process.stdout.write(result.stdout);
process.stdout.write(result.stderr);

const coldReceipt = spawnSync(
	pythonExecutable(),
	['tools/diagnostics/macos_cold_bootstrap_test.py'],
	{ cwd: path.resolve(__dirname, '../..'), encoding: 'utf8', timeout: 30000 }
);
assert.equal(coldReceipt.error, undefined, 'the independent cold receipt receiver must start');
assert.equal(coldReceipt.signal, null, 'the independent cold receipt receiver must retire');
assert.equal(coldReceipt.status, 0, coldReceipt.stderr || coldReceipt.stdout);
assert.match(coldReceipt.stderr, /Ran 8 tests in/);
assert.match(coldReceipt.stderr, /\bOK\b/);
assert.doesNotMatch(coldReceipt.stderr, /skipped=/);
process.stdout.write(coldReceipt.stdout);
process.stdout.write(coldReceipt.stderr);

const officialColdReceipt = spawnSync(
	pythonExecutable(),
	['tools/diagnostics/macos_cold_ollama_bootstrap_test.py'],
	{ cwd: path.resolve(__dirname, '../..'), encoding: 'utf8', timeout: 30000 }
);
assert.equal(officialColdReceipt.error, undefined, 'the official cold receipt receiver must start');
assert.equal(officialColdReceipt.signal, null, 'the official cold receipt receiver must retire');
assert.equal(
	officialColdReceipt.status,
	0,
	officialColdReceipt.stderr || officialColdReceipt.stdout
);
assert.match(officialColdReceipt.stderr, /Ran 17 tests in/);
assert.match(officialColdReceipt.stderr, /\bOK\b/);
assert.doesNotMatch(officialColdReceipt.stderr, /skipped=/);
process.stdout.write(officialColdReceipt.stdout);
process.stdout.write(officialColdReceipt.stderr);
