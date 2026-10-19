// tools/test/test-compact-data-sql.cjs

/** Run real SQLite and public CLI compaction regressions on the native Python. */
'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pythonExecutable } = require('../lib/python.cjs');

const root = path.resolve(__dirname, '..', '..');
// The 15 tests own 11 CLI calls (each bounded at 30 s), five standalone disk
// schema constructions and one startup allowance. Budget the whole protocol;
// Windows run 39168988892 took 175.412 s with every individual CLI below 30 s.
const operationBudgetMs = 30000;
const protocol = { cliCalls: 11, diskSchemas: 5, startup: 1 };
const timeoutMs = operationBudgetMs * (protocol.cliCalls + protocol.diskSchemas + protocol.startup);
const result = spawnSync(pythonExecutable(), ['tools/test/test_compact_data_sql.py'], {
	cwd: root,
	env: {
		...process.env,
		PYTHONDONTWRITEBYTECODE: '1',
		PYTHONUTF8: '1',
		PYTHONIOENCODING: 'utf-8'
	},
	encoding: 'utf8',
	timeout: timeoutMs,
	maxBuffer: 1024 * 1024
});
// Receive the native evidence even when an exit, timeout or incomplete report
// rejects the child. Printing only PASS hid all per-case Windows diagnostics.
if (result.stdout) process.stdout.write(result.stdout);
if (result.stderr) process.stderr.write(result.stderr);
assert.ifError(result.error);
assert.equal(result.status, 0, 'Native Python compaction tests failed.');
assert.match(result.stderr, /Ran 15 tests/);
assert.match(result.stderr, /\nOK\s*$/);
console.log('PASS lossless SQL compaction: 15 native SQLite and public CLI regressions.');
