// tools/test/test-ahk-module-matrix.cjs

/**
 * MODULE: Windows AHK module matrix
 * DESCRIPTION:
 * The Windows unit job runs one AHK module group per runner (run_all.ahk
 * --module=<group>). A group defined in TEST_MODULE_GROUPS but missing from
 * the CI matrix would never run, and a matrix entry naming no group would fail
 * only at runtime. The matrix must list exactly the defined groups, once each.
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const pipeline = require('./ci-full-default.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const framework = fs.readFileSync(
	path.join(ROOT, 'static/ergopti_plus/windows/tests/test_framework.ahk'),
	'utf8'
);
const table = framework.match(/^global TEST_MODULE_GROUPS := \[\r?\n([\s\S]*?)^\]/m);
assert.ok(table, 'TEST_MODULE_GROUPS is a literal table');
const groups = [...table[1].matchAll(/^\t\["([a-z][a-z0-9-]*)",/gm)].map((match) => match[1]);
assert.ok(groups.length >= 2, 'the suite is split into module groups');
assert.equal(new Set(groups).size, groups.length, 'every module group name is unique');

/**
 * Reads the module list of the Windows unit job's matrix.
 * @param {string} body The test-ahk job body.
 * @returns {string[]} The matrix modules, in order.
 */
function matrixModules(body) {
	const block = body.match(/^ {8}module:\s*\r?\n\s*\[([\s\S]*?)\]/m);
	assert.ok(block, 'the Windows unit job has a module matrix');
	return block[1]
		.split(',')
		.map((item) => item.trim())
		.filter(Boolean);
}

const body = pipeline.job('test-ahk');
assert.deepEqual(
	[...matrixModules(body)].sort(),
	[...groups].sort(),
	'the CI matrix runs exactly the AHK module groups'
);
assert.match(body, /--module=\$env:ERGOPTI_AHK_MODULE/, 'each runner selects its own group');

// A group dropped from the matrix, or a stray entry, must be refused.
const lastGroup = groups[groups.length - 1];
assert.throws(() =>
	assert.deepEqual(
		matrixModules(body.replace(new RegExp(`^\\s+${lastGroup}\\s*$`, 'm'), '')).sort(),
		[...groups].sort()
	)
);

console.log(`AHK module matrix: OK (${groups.length} groups)`);
