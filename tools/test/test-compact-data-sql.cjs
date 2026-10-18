// tools/test/test-compact-data-sql.cjs

/** Run real SQLite and public CLI compaction regressions on the native Python. */
'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pythonExecutable } = require('../lib/python.cjs');

const root = path.resolve(__dirname, '..', '..');
const result = spawnSync(pythonExecutable(), ['tools/test/test_compact_data_sql.py'], {
	cwd: root,
	env: {
		...process.env,
		PYTHONDONTWRITEBYTECODE: '1',
		PYTHONUTF8: '1',
		PYTHONIOENCODING: 'utf-8'
	},
	encoding: 'utf8',
	timeout: 120000,
	maxBuffer: 1024 * 1024
});
assert.ifError(result.error);
assert.equal(result.status, 0, result.stdout + result.stderr);
assert.match(result.stderr, /Ran 12 tests/);
assert.match(result.stderr, /\nOK\s*$/);
console.log('PASS lossless SQL compaction: 12 native SQLite and public CLI regressions.');
