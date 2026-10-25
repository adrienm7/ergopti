// tools/test/test-macos-journal-native-receipt.cjs

/** Executes the mandatory Linux FILE boundary control for the macOS journal. */
'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

assert.equal(
	process.platform,
	'linux',
	'the native prlimit feature must select its declared Linux host'
);
const root = path.resolve(__dirname, '../..');
const result = spawnSync(
	process.env.PYTHON || 'python3',
	['tools/diagnostics/journal_native_append_receipt.py'],
	{ cwd: root, encoding: 'utf8', maxBuffer: 1024 * 1024 }
);
assert.ifError(result.error);
assert.equal(result.signal, null, result.stderr);
assert.equal(result.status, 0, result.stdout + result.stderr);
assert.match(result.stderr, /Ran 1 test\b/, 'the selected actual native control must execute');
assert.match(result.stderr, /\bOK\s*$/, 'the native assertion suite must complete');
const prefix = 'NATIVE_JOURNAL_APPEND_RECEIPT ';
const receipts = result.stdout.split('\n').filter((line) => line.startsWith(prefix));
assert.equal(receipts.length, 1, result.stdout);
assert.deepEqual(JSON.parse(receipts[0].slice(prefix.length)), {
	fault_mode: 'native',
	raw_rows: 1,
	aggregate_app_time_ms: 100,
	duration_ms: 100,
	rows_before_recovery: 0,
	append_streams: 1,
	native_limit_changes: 2
});
console.log(
	'PASS: actual native journal refusal and retry preserve one public event and its duration.'
);
