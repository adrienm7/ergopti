// tools/test/test-menu-lex-unit-query-reuse.cjs

/** Preserve lexical query results and avoid repeated scans within one private unit. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const acorn = require('acorn');
const { scriptTokens } = require('../lib/script-source.cjs');

const source = fs.readFileSync(
	path.join(__dirname, '../lib/menu-native-llm-parent-binding.cjs'),
	'utf8'
);
const tree = acorn.parse(source, { ecmaVersion: 'latest' });
const factories = tree.body.filter(
	(node) => node.type === 'FunctionDeclaration' && node.id.name === 'luaPublicationParser'
);
assert.equal(factories.length, 1, 'inspect the unique actual lexical query factory');
const parserFactory = new Function(
	'scriptTokens',
	"'use strict';\n" +
		source.slice(factories[0].start, factories[0].end) +
		'\nreturn luaPublicationParser;'
)(scriptTokens);
const parser = parserFactory();
const nested = parser.lex('x = 1\nfunction f()\n x = 2\nend\nx = 3');
assert.ok(nested, 'real lexical unit is balanced');
assert.deepEqual(parser.positions(nested, 'x'), [0, 7, 11], 'preserve lexical order');
assert.deepEqual(parser.rootPositions(nested, 'x'), [0, 11], 'root depth stays distinct');
assert.equal(parser.one(nested, 'x'), false);
assert.equal(parser.one(nested, 'x = 1'), true);
assert.deepEqual(
	parser.positions(nested, ''),
	Array.from({ length: 14 }, (_, at) => at)
);
assert.deepEqual(parser.positions(null, 'x'), []);
assert.equal(parser.lex('function f()'), null);

const quoted = parser.lex('emit("x")\nemit(\'x\')\nemit([[x]])\n-- emit("x")');
for (const [statement, expected] of [
	['emit("x")', [0]],
	["emit('x')", [4]],
	['emit([[x]])', [8]],
	['emit ( "x" )', [0]],
	['emit("missing")', []]
]) {
	assert.deepEqual(parser.positions(quoted, statement), expected);
}
assert.deepEqual(parser.positions(parser.lex('emit("😀é")\r\nx = 1'), 'emit("😀é")'), [0]);
assert.deepEqual(parser.positions(parser.lex('owner.x = 1\nowner:x()\nx = 2'), 'x'), [10]);
assert.deepEqual(parser.positions(parser.lex('--[[ x = 1 ]]\nx = 2'), 'x'), [0]);

// Install a read-only observation port before the first query. The real unit's
// token values remain intact; no global prototypes or parser operations change.
const unit = parser.lex('x = 1\nfunction f()\n x = 2\nend\nx = 3');
let reads = 0;
unit.tokens = new Proxy(unit.tokens, {
	get(target, property, receiver) {
		reads++;
		return Reflect.get(target, property, receiver);
	}
});
const first = parser.positions(unit, 'x');
assert.ok(reads > 0, 'first query executes the actual scanner');
first.reverse();
first.push(999);
reads = 0;
const second = parserFactory().positions(unit, 'x');
assert.deepEqual(second, [0, 7, 11], 'another factory reads the same immutable unit');
assert.notEqual(first, second, 'a caller always owns a fresh result array');
assert.equal(reads, 0, 'an exact repeated query must not scan unit tokens again');
second.pop();
assert.deepEqual(
	parser.positions(unit, 'x'),
	[0, 7, 11],
	'mutating a hit cannot alter later answers'
);
assert.deepEqual(parser.rootPositions(unit, 'x'), [0, 11]);
reads = 0;
const absent = parser.positions(unit, 'absent');
assert.deepEqual(absent, []);
assert.ok(reads > 0, 'changed query performs its own actual scan');
absent.push(999);
reads = 0;
assert.deepEqual(parser.positions(unit, 'absent'), []);
assert.equal(reads, 0, 'zero-match queries also avoid repeated scans');
assert.deepEqual(parser.positions(unit, 'x'), [0, 7, 11], 'good/miss/good remains independent');
assert.deepEqual(parser.positions(parser.lex('x = 1'), 'x'), [0], 'new source gets a fresh unit');
assert.deepEqual(
	parser.positions(parser.lex('missing = 1'), 'x'),
	[],
	'foreign source cannot reuse answers'
);
assert.deepEqual(
	parser.positions(parser.lex('x = 1'), 'x'),
	[0],
	'good/bad/good source calls remain fresh'
);
console.log(
	'[OK] lexical unit queries retain ordering, quote/depth distinctions, fresh arrays and bounded repeat work'
);
