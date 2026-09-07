// tools/test/test-verify-change-ahk-registration.cjs

/**
 * ==============================================================================
 * MODULE: AHK Change-Scoped Registration Tests
 * DESCRIPTION:
 * Exercises registration prechecks against real temporary include graphs so
 * nested test modules cannot silently escape verification during suite splits.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { checkTestsAreRegistered } = require('./verify-change.cjs');

const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-ahk-registration-'));
const prefix = 'static/ergopti_plus/windows/tests/';
const tests = path.join(root, prefix);
try {
	fs.mkdirSync(path.join(tests, 'unit', 'nested', 'deeper'), { recursive: true });
	fs.writeFileSync(path.join(tests, 'run_all.ahk'), [
		'#Include unit/test_facade.ahk',
		'; unit/test_comment_only.ahk',
	].join('\n'));
	fs.writeFileSync(path.join(tests, 'unit/test_facade.ahk'),
		'#Include nested/deeper/test_child.ahk\n');
	fs.writeFileSync(path.join(tests, 'unit/nested/deeper/test_child.ahk'), '; reachable\n');
	fs.writeFileSync(path.join(tests, 'unit/nested/deeper/test_orphan.ahk'), '; orphan\n');
	fs.writeFileSync(path.join(tests, 'unit/test_comment_only.ahk'), '; orphan\n');
	fs.writeFileSync(path.join(tests, 'unit/nested/deeper/test with spaces.ahk'), '; orphan\n');
	const check = (relative) => checkTestsAreRegistered([prefix + relative], root);

	assert.equal(check('unit/nested/deeper/test_orphan.ahk').length, 1,
		'a nested orphan must fail the same precheck as a flat orphan');
	assert.equal(check('unit/test_comment_only.ahk').length, 1,
		'mentioning a filename in a comment cannot register its tests');
	assert.equal(check('unit/nested/deeper/test with spaces.ahk').length, 1,
		'valid filenames with spaces must not bypass registration checks');
	assert.deepEqual(check('unit/nested/deeper/test_child.ahk'), [],
		'a transitive include registers a nested test without a direct runner include');
	assert.deepEqual(check('unit/test_facade.ahk'), [],
		'the original directly included facade remains valid');
	assert.deepEqual(check('unit/test_removed.ahk'), [],
		'a removed file need not remain included');
} finally {
	fs.rmSync(root, { recursive: true, force: true });
}

console.log('verify-change AHK registration: nested and transitive cases passed.');
