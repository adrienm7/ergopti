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

// ─────────────────────────────────────────────────
// Every registering test file belongs to exactly one declared category
// ─────────────────────────────────────────────────
const entries = [...table[1].matchAll(/^\t\["([a-z][a-z0-9-]*)", "((?:[^"\\]|\\.)*)"\],?$/gm)].map(
	(match) => ({ name: match[1], pattern: match[2] })
);
assert.deepEqual(
	entries.map((entry) => entry.name),
	groups,
	'every category is one literal name and pattern'
);
assert.ok(
	entries.every((entry) => entry.pattern !== ''),
	'no category is a catch-all: an undeclared file must fail, not land in a default'
);
const matchers = entries.map((entry) => ({ name: entry.name, regex: new RegExp(entry.pattern) }));
/** The category _TestModuleOf picks for a file relative to tests/, or null. */
function categoryOf(relative) {
	const found = matchers.find((entry) => entry.regex.test(relative.toLowerCase()));
	return found ? found.name : null;
}
const TESTS = path.join(ROOT, 'static/ergopti_plus/windows/tests');
const registering = [];
for (const top of ['unit', 'meta'])
	(function walk(directory) {
		for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
			const file = path.join(directory, entry.name);
			if (entry.isDirectory()) walk(file);
			else if (entry.name.endsWith('.ahk') && /^\s*Test\(/m.test(fs.readFileSync(file, 'utf8')))
				registering.push(path.relative(TESTS, file).replace(/\\/g, '/'));
		}
	})(path.join(TESTS, top));
assert.ok(registering.length > 1000, 'the category scan found the registering test files');
const undeclared = registering.filter((relative) => categoryOf(relative) === null);
assert.deepEqual(undeclared, [], 'every registering test file belongs to a declared category');
const sizes = new Map(groups.map((name) => [name, 0]));
for (const relative of registering)
	sizes.set(categoryOf(relative), sizes.get(categoryOf(relative)) + 1);
for (const [name, size] of sizes)
	assert.ok(size > 0, `category ${name} holds at least one test file`);
assert.equal(categoryOf('unit/new_area/test_x.ahk'), null, 'a new undeclared folder is refused');
assert.equal(categoryOf('run_all.ahk'), null, 'the runner itself declares no tests');

// The workflow documents each category in one line beside the matrix.
const documented = [...body.matchAll(/^ {4}# {3}([a-z][a-z0-9-]*): \S/gm)].map((match) => match[1]);
assert.deepEqual(documented, groups, 'the Windows unit job documents every category, in order');
assert.throws(() =>
	assert.deepEqual(
		[
			...body
				.replace(new RegExp(`^ {4}# {3}${lastGroup}: .*\\n`, 'm'), '')
				.matchAll(/^ {4}# {3}([a-z][a-z0-9-]*): \S/gm)
		].map((match) => match[1]),
		groups
	)
);

console.log(
	`AHK module matrix: OK (${groups.length} categories, ${registering.length} registering files, none undeclared)`
);
