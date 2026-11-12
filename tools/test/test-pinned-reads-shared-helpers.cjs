// tools/test/test-pinned-reads-shared-helpers.cjs

/**
 * ==============================================================================
 * MODULE: Pinned-Read Fixer Ignores Shared Data Helpers
 * DESCRIPTION:
 * The pre-commit hook runs tools/lint/fix-pinned-source-reads.cjs on every
 * staged macOS test and blocks the commit on a refusal. A helper reading a
 * shared JSON corpus (read_json("tests/corpus/x.json") over SHARED .. path)
 * was refused as "not a driver source file", although it reads no driver
 * source at all. The hook then blocked any commit that touched such a test.
 * Every phase 2 step of the structure plan does. The fixer now leaves a
 * helper alone when none of its calls names a driver file. A helper that
 * mixes driver sources with other paths is still refused.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const FIXER = path.join(__dirname, '..', 'lint', 'fix-pinned-source-reads.cjs');

const run = spawnSync(process.execPath, [FIXER, '--all'], { encoding: 'utf8' });
assert.equal(run.status, 0, run.stderr);
const refusals = `${run.stdout}${run.stderr}`
	.split('\n')
	.filter((l) => l.includes('[not a driver source file]'));
assert.deepEqual(refusals, [], 'a helper that reads no driver source is not refused');
console.log('[OK] the pinned-read fixer leaves helpers that read shared data alone.');
