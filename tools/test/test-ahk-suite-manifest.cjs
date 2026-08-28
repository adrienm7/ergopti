// tools/test/test-ahk-suite-manifest.cjs

'use strict';

const assert = require('node:assert/strict');
const { validateAhkSuiteManifest } = require('./validate-ahk-suite-manifest.cjs');

const beforeSlowTail = [
	'\uFEFF1..3',
	'RUNNING 1/3 - fast head',
	'ok 1 - fast head',
	'RUNNING 2/3 - ordinary middle',
	'ok 2 - ordinary middle',
	'# 2 passed, 0 failed.',
].join('\n');
const early = validateAhkSuiteManifest(beforeSlowTail);
assert.equal(early.complete, false, 'a green-looking footer must not complete before the slow tail');
assert.match(early.errors.join('\n'), /planned test 3\/3 never started/);

const afterSlowTail = [
	'1..3',
	'RUNNING 1/3 - fast head',
	'ok 1 - fast head',
	'RUNNING 2/3 - ordinary middle',
	'ok 2 - ordinary middle',
	'RUNNING 3/3 - deliberately slow tail',
	'ok 3 - deliberately slow tail',
	'# 3 passed, 0 failed.',
].join('\n');
const complete = validateAhkSuiteManifest(afterSlowTail);
assert.equal(complete.complete, true, complete.errors.join('\n'));
assert.deepEqual(complete.executed.map((entry) => entry.index), [1, 2, 3]);

const missingTerminal = validateAhkSuiteManifest(afterSlowTail.replace('ok 3 - deliberately slow tail\n', ''));
assert.equal(missingTerminal.complete, false, 'RUNNING without a terminal result must fail the manifest');

console.log('AHK suite execution manifest: slow tail and early-completion guards passed.');
