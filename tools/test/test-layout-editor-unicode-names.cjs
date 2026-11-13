// tools/test/test-layout-editor-unicode-names.cjs

/**
 * ==============================================================================
 * MODULE: Layout Editor Unicode Names Tests
 * DESCRIPTION:
 * Runs the generated names table and its decoder (layout_editor/unicode_names.js)
 * in a vm, as the page loads them, and checks: the table is the codegen's
 * current output; explicit, algorithmic (CJK, Hangul, Tangut components) and
 * control names; blocks; every vendored name line decodes back; the name search
 * with words, `*` and `?` wildcards, glyphs, U+XXXX, aliases and its cap; and
 * that each host page lists the decoder (the layout manager also the table).
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { shared } = require('../lib/paths.cjs');
const codegen = require('../codegen/codegen-unicode-names.cjs');

const UI = shared('ui');
const TABLE = path.join(UI, 'layout_editor', '_generated', 'unicode_names.js');
const DECODER = path.join(UI, 'layout_editor', 'unicode_names.js');
const VENDORED = path.join(__dirname, '..', 'codegen', 'unicode', 'UnicodeNames-17.0.0.txt');

const plain = (value) => JSON.parse(JSON.stringify(value));
const tests = [];
const test = (name, fn) => tests.push([name, fn]);

/** A fresh vm with the decoder, and the table unless withoutTable. */
function load(withoutTable) {
	const context = vm.createContext({});
	if (!withoutTable)
		vm.runInContext(fs.readFileSync(TABLE, 'utf8'), context, { filename: 'unicode_names.js' });
	vm.runInContext(fs.readFileSync(DECODER, 'utf8'), context, { filename: 'unicode_names.js' });
	return vm.runInContext('UnicodeNames', context);
}

const U = load(false);

test('the committed table is the codegen output', () => {
	assert.equal(fs.readFileSync(TABLE, 'utf8'), codegen.buildSource());
	assert.equal(U.version(), '17.0.0');
});

test('explicit, algorithmic and control names', () => {
	const cases = {
		0x41: 'LATIN CAPITAL LETTER A',
		0xe9: 'LATIN SMALL LETTER E WITH ACUTE',
		0x2d: 'HYPHEN-MINUS',
		0x1f600: 'GRINNING FACE',
		0xac00: 'HANGUL SYLLABLE GA',
		0xd7a3: 'HANGUL SYLLABLE HIH',
		0xb1b1: 'HANGUL SYLLABLE NWAEG',
		0x4e00: 'CJK UNIFIED IDEOGRAPH-4E00',
		0x20000: 'CJK UNIFIED IDEOGRAPH-20000',
		0xf900: 'CJK COMPATIBILITY IDEOGRAPH-F900',
		0x18800: 'TANGUT COMPONENT-001',
		0x18aff: 'TANGUT COMPONENT-768',
		0xfe0f: 'VARIATION SELECTOR-16',
		0x0a: 'LINE FEED',
		0x00: 'NULL'
	};
	for (const [point, name] of Object.entries(cases)) assert.equal(U.nameOf(Number(point)), name);
	for (const point of [0xe000, 0xd800, 0x0378, 0x10ffff]) assert.equal(U.nameOf(point), null);
	assert.deepEqual(plain(U.aliasesOf(0xa0).map((a) => a.alias)), ['NBSP']);
});

test('blocks name every code point they hold', () => {
	assert.equal(U.blockOf(0xe9), 'Latin-1 Supplement');
	assert.equal(U.blockOf(0x1f600), 'Emoticons');
	assert.equal(U.blockOf(0x0378), 'Greek and Coptic');
	assert.equal(U.blocks().length, 346);
	assert.deepEqual(plain(U.describe('é€').map((row) => [row.code, row.name, row.block])), [
		['U+00E9', 'LATIN SMALL LETTER E WITH ACUTE', 'Latin-1 Supplement'],
		['U+20AC', 'EURO SIGN', 'Currency Symbols']
	]);
});

test('every vendored name decodes back', () => {
	let checked = 0;
	for (const line of fs.readFileSync(VENDORED, 'utf8').split('\n').filter(Boolean)) {
		const [range, name] = line.split(';');
		const [first, last] = range.split('..').map((hex) => parseInt(hex, 16));
		if (last === undefined) {
			assert.equal(U.nameOf(first), name, line);
			checked++;
		} else {
			assert.notEqual(U.nameOf(first), null, line);
			assert.notEqual(U.nameOf(last), null, line);
			checked += last - first + 1;
		}
	}
	assert.equal(checked, 159801, 'Unicode 17.0 names 159,801 characters');
});

test('the search: words, wildcards, glyphs, code points, aliases and cap', () => {
	const chars = (query, limit) =>
		U.search(query, limit)
			.results.map((r) => r.char)
			.join('');
	assert.equal(chars('e*acute'), 'ÉéḖḗẾế');
	assert.ok(chars('latin small e acute').includes('é'));
	assert.ok(!chars('latin small e acute').includes('É'), 'every word must match');
	assert.equal(chars('greek small letter ?eta'), 'ͱβζᵦ', '? is one character of a whole word');
	assert.equal(chars('U+00E9'), 'é');
	assert.equal(chars('0x1F600'), '😀');
	assert.equal(U.search('😀').results[0].name, 'GRINNING FACE');
	assert.equal(U.search('nbsp').results[0].code, 'U+00A0', 'aliases are searched');
	assert.equal(U.search('hangul syllable nwaeg').results[0].code, 'U+B1B1');
	assert.equal(U.search('CJK UNIFIED IDEOGRAPH-4E00').results[0].code, 'U+4E00');
	const capped = U.search('latin', 5);
	assert.equal(capped.results.length, 5);
	assert.equal(capped.truncated, true);
	assert.equal(U.search('arrow').results.length > 100, true);
	assert.equal(U.search('   ').results.length, 0);
	assert.equal(U.search('zzqqxx').results.length, 0);
	assert.equal(
		U.search('latin', 0).results.length,
		U.DEFAULT_LIMIT,
		'an invalid cap uses the default'
	);
});

test('without the table, the decoder refuses instead of guessing', () => {
	const bare = load(true);
	assert.equal(bare.available(), false);
	assert.throws(() => bare.nameOf(0x41), /unicode_names_not_loaded/);
	return bare.ensure().then(
		() => assert.fail('no page to load the table into'),
		(error) => assert.match(error.message, /unicode_names_not_loaded/)
	);
});

test('the host pages list the decoder, the editor window also the table', () => {
	const scripts = (page) =>
		[...fs.readFileSync(path.join(UI, page), 'utf8').matchAll(/<script src="([^"]+)"/g)].map(
			(m) => path.basename(path.dirname(m[1])) + '/' + path.basename(m[1])
		);
	const site = scripts('layout_editor/index.html');
	assert.ok(
		site.some((s) => s.endsWith('layout_editor/unicode_names.js') || s === './unicode_names.js')
	);
	assert.ok(
		!site.some((s) => s.startsWith('_generated/unicode_names')),
		'the site loads the table lazily'
	);
	// The inline hosts open the editor in its own window (layout_editor_window).
	const window = scripts('layout_editor_window/index.html');
	const table = window.findIndex((s) => s.endsWith('_generated/unicode_names.js'));
	const decoder = window.findIndex((s) => s.endsWith('layout_editor/unicode_names.js'));
	assert.ok(table >= 0 && decoder > table, 'the inline host lists the table before its decoder');
});

(async () => {
	for (const [name, fn] of tests) {
		await fn();
		console.log(`ok - ${name}`);
	}
	console.log(`ok - ${tests.length} layout editor Unicode names tests`);
})().catch((error) => {
	console.error(error);
	process.exit(1);
});
