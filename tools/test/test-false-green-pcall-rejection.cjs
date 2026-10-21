// tools/test/test-false-green-pcall-rejection.cjs

/** Exercise the real detector against expected rejection and weak success checks. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.join(__dirname, 'find-false-greens.cjs'), 'utf8');
const entry = 'process.exit(main());';
assert.ok(source.trimEnd().endsWith(entry), 'isolate the scanner before its CLI entry');
const context = { require, __dirname };
vm.createContext(context);
vm.runInContext(source.slice(0, source.lastIndexOf(entry)), context);
const scan = context.findPcallOnly;
assert.equal(typeof scan, 'function');
const fixture = path.join(__dirname, 'synthetic-pcall.lua');

for (const statement of [
	'helpers.assert_eq(ok, false)',
	'helpers.assert_equal(ok, false, "expected rejection")',
	'helpers.assert_false(ok)',
	'helpers.assert_false(pcall(subject))'
]) {
	assert.equal(
		scan(fixture, `local ok = pcall(subject)\n${statement}`).length,
		0,
		`an expected rejection is a behavioral assertion: ${statement}`
	);
}
for (const statement of [
	'helpers.assert_true(ok)',
	'helpers.assert_eq(ok, true)',
	'helpers.assert_eq(ok, false or true)',
	'helpers.assert_true(pcall(subject))',
	'helpers.assert_false(ok); helpers.assert_true(ok)'
]) {
	assert.equal(
		scan(fixture, `local ok = pcall(subject)\n${statement}`).length,
		1,
		`a weak success check must remain detectable: ${statement}`
	);
}
assert.equal(
	scan(
		fixture,
		'local ok, value = pcall(subject)\nhelpers.assert_true(ok)\nhelpers.assert_eq(value, 42)'
	).length,
	0,
	'an assertion on the returned value remains a positive control'
);
const ahkFixture = path.join(__dirname, 'synthetic-mixed-quotes.ahk');
for (const literal of [
	"{Source: ' # fake } ] \"', Expected: 1}",
	'{Source: " # fake } ] \'", Expected: 1}',
	"{Source: ' # fake `' } ] \"', Expected: 1}",
	'{Source: " # fake `" } ] \'", Expected: 1}',
	"{Source: '; fake } \"', Expected: 1}"
]) {
	const live = [
		'Live() {',
		`    Vector := ${literal} ; ignored trailing }`,
		'    AssertEqual(Vector.Expected, 1)',
		'}',
		'Test("live", Live)'
	].join('\n');
	const blocks = context.ahkFunctionBlocks(live);
	assert.equal(blocks.length, 1);
	assert.equal(
		blocks[0].end,
		4,
		'mixed literals cannot truncate a real function before its assertion'
	);
	assert.ok(blocks[0].text.includes('AssertEqual(Vector.Expected, 1)'));
	assert.ok(
		context.ahkAllFunctionBlocks(live).get('Live').text.includes('AssertEqual(Vector.Expected, 1)')
	);
	assert.equal(context.ahkEnclosingFunction(live)[2], 'Live');
	assert.equal(context.ahkEnclosingFunction(live)[4], null);
	assert.equal(context.findDeadTests(ahkFixture, live, '.ahk').length, 0);
	const dead = ['Empty() {', `    Vector := ${literal}`, '}', 'Test("empty", Empty)'].join('\n');
	assert.equal(
		context.findDeadTests(ahkFixture, dead, '.ahk').length,
		1,
		'real non-asserting tests remain dead'
	);
	const nested = [
		'Register() {',
		`    Vector := ${literal}`,
		'    Nested() {',
		`        Vector := ${literal}`,
		'        AssertEqual(Vector.Expected, 1)',
		'    }',
		'    Test("nested", Nested)',
		'}',
		'Register()'
	].join('\n');
	assert.ok(
		context
			.ahkAllFunctionBlocks(nested)
			.get('Nested')
			.text.includes('AssertEqual(Vector.Expected, 1)')
	);
	assert.equal(context.ahkEnclosingFunction(nested)[4], 'Nested');
	assert.equal(context.ahkEnclosingFunction(nested)[6], 'Register');
	assert.equal(
		context.findDeadTests(ahkFixture, nested, '.ahk').length,
		0,
		'a genuinely reached nested registration stays live'
	);
	assert.equal(
		context.findDeadTests(ahkFixture, nested.replace('\nRegister()', ''), '.ahk').length,
		1,
		'an unreached nested registration remains dead'
	);
}
// A child-process harness carries its registrations as continuation data: they
// register in the child, which the parent test then reads back. Only a real
// registration in an unreached function of this file stays dead.
const childHarness = [
	'Script() {',
	"\tHarness := '",
	'(',
	'Child() {',
	'\tAssertEqual(1, 1)',
	'}',
	'Test("child", Child)',
	'RunTests()',
	")'",
	'\treturn Harness',
	'}',
	'Parent() {',
	'\tAssertContains(Script(), "child")',
	'}',
	'Test("parent", Parent)'
].join('\n');
assert.deepEqual(
	Array.from(context.ahkContinuationLines(childHarness.split('\n'))),
	childHarness.split('\n').map((_, i) => i >= 3 && i <= 7)
);
assert.equal(context.ahkEnclosingFunction(childHarness)[6], 'Script');
assert.equal(context.ahkEnclosingFunction(childHarness)[12], 'Parent');
assert.equal(
	context.findDeadTests(ahkFixture, childHarness, '.ahk').length,
	0,
	'a child script registration in continuation data is not a dead registration here'
);
const unreached = childHarness.replace(
	'\treturn Harness\n}',
	'\tTest("unreached", Parent)\n\treturn Harness\n}'
);
assert.deepEqual(
	Array.from(context.findDeadTests(ahkFixture, unreached, '.ahk'), (finding) => finding.line),
	[10],
	'a real registration after the continuation section remains dead'
);
console.log(
	'false-green pcall rejection: 10 scenarios; AHK mixed quotes: 5 live/dead/nested vectors; ' +
		'continuation child harness live/dead vectors passed'
);
