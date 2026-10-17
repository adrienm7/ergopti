// tools/test/test-number-row-current-test-causal.cjs

/** Receive controlled Carbon fixture contracts without granting native credit. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pythonExecutable } = require('../lib/python.cjs');

const parent = fs.realpathSync(os.tmpdir());
const directory = fs.mkdtempSync(path.join(parent, 'ergopti-carbon-current-test-'));
const canonical = fs.realpathSync(directory);
assert.equal(path.dirname(canonical), parent, 'The controls own one direct temporary child.');
assert.ok(path.basename(canonical).startsWith('ergopti-carbon-current-test-'));
let closed = false;
try {
	const result = spawnSync(
		pythonExecutable(),
		['-B', 'tools/diagnostics/test_number_row_current_test_causal.py', '--receiving', canonical],
		{
			cwd: path.resolve(__dirname, '../..'),
			encoding: 'utf8',
			windowsHide: true,
			timeout: 30000,
			maxBuffer: 1048576
		}
	);
	closed = !result.error && result.signal === null && Number.isInteger(result.status);
	assert.equal(result.error, undefined, 'The actual controlled Python child must start.');
	assert.equal(result.signal, null, 'The controls must retire within their original bound.');
	assert.equal(result.status, 0, result.stderr || result.stdout);
	assert.match(result.stderr, /\bRan 23 tests in [0-9.]+s\b/);
	assert.match(result.stderr, /^OK\r?$/m);
	assert.doesNotMatch(result.stderr, /skipped=/);
	process.stdout.write(result.stdout);
	process.stdout.write(result.stderr);
	console.log(
		'Controlled software only: source approval was not issued; native receiving is UNRUN.'
	);
} finally {
	// A timed-out child cannot establish that its scratch namespace is unused.
	if (closed) {
		assert.equal(fs.realpathSync(directory), canonical);
		assert.equal(path.dirname(canonical), parent);
		fs.rmSync(canonical, { recursive: true });
	}
}
