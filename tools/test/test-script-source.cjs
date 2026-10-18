// tools/test/test-script-source.cjs

/**
 * ==============================================================================
 * MODULE: Script Tokenizer Cache Contract
 * DESCRIPTION:
 * tools/lib/script-source.cjs caches each scan because the menu guards tokenize
 * the same driver files thousands of times in one process. A cache may only
 * change the cost: every call must return what a fresh scan returns, in fresh
 * objects, per language mode, after any eviction.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const { scriptTokens, stripComments } = require('../lib/script-source.cjs');

const LUA = [
	'--[==[ block ]==] local x = "a\\"b" -- tail',
	"local y = [[long]] .. 'q'",
	'if x then y = x:upper() end'
].join('\n');
const AHK = ['x := "a`"b" ; note', '/* block', '*/ y := Func(x)', 'z:=1;not a comment'].join('\n');

const expectedLua = [
	['identifier', 'local'],
	['identifier', 'x'],
	['symbol', '='],
	['string', 'a"b'],
	['identifier', 'local'],
	['identifier', 'y'],
	['symbol', '='],
	['string', 'long'],
	['symbol', '.'],
	['symbol', '.'],
	['string', 'q'],
	['identifier', 'if'],
	['identifier', 'x'],
	['identifier', 'then'],
	['identifier', 'y'],
	['symbol', '='],
	['identifier', 'x'],
	['symbol', ':'],
	['identifier', 'upper'],
	['symbol', '('],
	['symbol', ')'],
	['identifier', 'end']
];
const shape = (tokens) => tokens.map((token) => [token.kind, token.value]);

// The scan itself: literals, long brackets and both comment syntaxes.
assert.deepEqual(shape(scriptTokens(LUA, '.lua')), expectedLua);
assert.deepEqual(shape(scriptTokens(AHK, '.ahk')).slice(0, 4), [
	['identifier', 'x'],
	['symbol', ':='],
	['string', 'a"b'],
	['identifier', 'y']
]);
assert.ok(
	shape(scriptTokens(AHK, '.ahk')).some(([kind, value]) => kind === 'symbol' && value === ';'),
	'a semicolon that does not follow whitespace is code, not an AHK comment'
);

// Every code token keeps exactly its four fields, in their original order.
for (const token of scriptTokens(LUA, '.lua'))
	assert.deepEqual(Object.keys(token), ['kind', 'value', 'start', 'end']);

// One source is cached per language mode: the same text reads differently as AHK.
assert.notDeepEqual(shape(scriptTokens(LUA, '.ahk')), expectedLua);
assert.deepEqual(shape(scriptTokens(LUA, '.lua')), expectedLua);

// A caller that edits what it received cannot change what the next caller sees.
const edited = scriptTokens(LUA, '.lua');
edited[0].value = 'edited';
edited[1].lineBefore = true;
edited.splice(0, 3);
const fresh = scriptTokens(LUA, '.lua');
assert.deepEqual(shape(fresh), expectedLua, 'a cached scan is not shared with an editing caller');
assert.equal(Object.hasOwn(fresh[1], 'lineBefore'), false);
assert.notEqual(fresh[0], scriptTokens(LUA, '.lua')[0], 'each call receives its own tokens');

// Comment masking reads the same cached scan and keeps every offset.
const masked = stripComments(LUA, '.lua');
assert.equal(masked.length, LUA.length);
assert.equal(masked.includes('block'), false);
assert.equal(masked.includes('tail'), false);
assert.equal(masked.includes('"a\\"b"'), true);

// Eviction: far more distinct source than the cache keeps, then the first again.
const filler = 'local value = 1\n'.repeat(64 * 1024);
for (let index = 0; index < 12; index++) scriptTokens(filler + '-- ' + index, '.lua');
assert.deepEqual(shape(scriptTokens(LUA, '.lua')), expectedLua, 'an evicted source scans again');

console.log('PASS: script tokenizer cache returns fresh, mode-specific scans after eviction.');
