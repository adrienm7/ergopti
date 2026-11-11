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
	'helpers.assert_false(pcall(subject))',
	'helpers.assert_eq(pcall(subject, { a = ")" }), false)',
	'helpers.assert_equal(pcall(subject), false, "expected rejection")'
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
	'helpers.assert_eq(pcall(subject), true)',
	'helpers.assert_eq(pcall(subject, false), true)',
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
for (const [body, count, reason] of [
	[
		'helpers.assert_true(pcall(subject))\nhelpers.assert_eq(observed, 1)',
		0,
		'inline status with observed effect'
	],
	[
		'local ok = pcall(subject)\nhelpers.assert_true(ok)\nhelpers.assert_eq(observed, 1)',
		0,
		'named status with observed effect'
	],
	[
		'local ok = pcall(subject)\nhelpers.assert_true(ok)\n-- helpers.assert_eq(observed, 1)',
		1,
		'comment is not an observation'
	],
	[
		'local ok = pcall(subject)\nlocal other = pcall(subject)\nhelpers.assert_true(ok)\nhelpers.assert_true(other)',
		2,
		'another status is not an observation'
	],
	[
		'helpers.assert_true(pcall(subject))\nhelpers.assert_true(true)',
		1,
		'tautology is not an observation'
	]
]) {
	const text = `helpers.it("case", function()\n${body}\nend)`;
	assert.equal(scan(fixture, text).length, count, reason);
}
assert.equal(
	scan(
		fixture,
		[
			'helpers.it("weak", function()',
			'  helpers.assert_true(pcall(subject))',
			'end)',
			'helpers.it("next", function()',
			'  helpers.assert_eq(observed, 1)',
			'end)'
		].join('\n')
	).length,
	1,
	'an observation in another test cannot hide a weak test'
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
	const withArgument = nested
		.replace('Register() {', 'Register(Name) {')
		.replace('\nRegister()', '\nRegister("updates")');
	assert.equal(
		context.findDeadTests(ahkFixture, withArgument, '.ahk').length,
		0,
		'a registration helper called at top level with an argument is reached'
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
// An error message is not a throw witness: Error("") has an empty one. Each
// seeded violation judges the throw by the message alone and must be reported;
// each control carries an explicit caught state or a never-empty message.
const witness = (body) =>
	context.findMessageWitnesses(ahkFixture, ['Case() {', ...body, '}'].join('\n'));
for (const [body, reason] of [
	[
		['\tX := ""', '\ttry F()', '\tcatch as E', '\t\tX := E.Message', '\tAssertEqual("", X)'],
		'no-throw by empty message'
	],
	[
		[
			'\tX := ""',
			'\ttry {',
			'\t\tF()',
			'\t} catch as E {',
			'\t\tX := E.Message',
			'\t}',
			'\tAssert(X == "", "no throw")'
		],
		'braced catch on the closing line'
	],
	[
		[
			'\tX := ""',
			'\ttry F()',
			'\tcatch ValueError as E',
			'\t\tX := E.Message',
			'\tAssertTrue(X != "", "must raise")'
		],
		'must-throw by non-empty message'
	],
	[
		[
			'\tX := ""',
			'\ttry F()',
			'\tcatch as E',
			'\t\tX := E.Message',
			'\treturn X != "" ? "" : "accepted"'
		],
		'verdict returned to the caller'
	],
	[
		[
			'\tX := ""',
			'\ttry F()',
			'\tcatch as E',
			'\t\tX := E.Message',
			'\tAssertEqual(Throws ? "boom" : "", X)'
		],
		'ternary empty expectation'
	],
	[
		[
			'\ttry F()',
			'\tcatch as E',
			'\t\tthis.Failure := E.Message',
			'\tAssertEqual("", Fixture.Failure)'
		],
		'property read through another receiver'
	],
	[
		[
			'\ttry F()',
			'\tcatch OSError as E {',
			'\t\tState["read_error"] := E.Message',
			'\t}',
			'\twhile Other["read_error"] == ""',
			'\t\tSleep(10)'
		],
		'map member'
	]
]) {
	assert.equal(witness(body).length, 1, `a message-only throw witness must be reported: ${reason}`);
}
for (const [body, reason] of [
	[
		[
			'\tCaught := false, X := ""',
			'\ttry F()',
			'\tcatch as E {',
			'\t\tCaught := true',
			'\t\tX := E.Message',
			'\t}',
			'\tAssertFalse(Caught, X)'
		],
		'explicit caught state'
	],
	[
		[
			'\tX := ""',
			'\ttry F()',
			'\tcatch as E',
			'\t\tX := Type(E) . ": " . E.Message',
			'\tAssertEqual("", X)'
		],
		'message that is never empty'
	],
	[
		[
			'\tX := ""',
			'\ttry F()',
			'\tcatch as E',
			'\t\tX := E.Message',
			'\tAssertContains(X, "refused")'
		],
		'presence assertion fails on an empty message'
	],
	[
		['\tX := ""', '\ttry F()', '\tcatch as E', '\t\tX := E.Message', '\t; AssertEqual("", X)'],
		'comment is not a verdict'
	]
]) {
	assert.equal(witness(body).length, 0, `a real caught-state witness is not reported: ${reason}`);
}
console.log(
	'false-green pcall rejection: 14 scenarios; AHK mixed quotes: 5 live/dead/nested vectors; ' +
		'continuation child harness live/dead vectors; message witness: 7 seeded violations, 4 controls passed'
);
