// tools/test/test-menu-reader-line-snapshot.cjs

/** Preserve the actual reader's lexical contract and once-per-source line work. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const acorn = require('acorn');

const source = fs.readFileSync(
	path.join(__dirname, 'test-menu-manifest-keys-have-readers.cjs'),
	'utf8'
);
const tree = acorn.parse(source, { ecmaVersion: 'latest' });
const functions = tree.body.filter(
	(node) => node.type === 'FunctionDeclaration' && node.id.name === 'readersOf'
);
assert.equal(functions.length, 1, 'inspect the unique actual reader function');
const snapshots = tree.body.filter(
	(node) =>
		node.type === 'VariableDeclaration' &&
		node.declarations.some((declaration) => declaration.id.name === 'readerSources')
);
assert.ok(snapshots.length <= 1, 'inspect the unambiguous actual snapshot initializer');
// An absent initializer leaves the actual old reader executable: its repeated
// line operations must fail the behavioral work bound below, not a text check.
const makeReader = new Function(
	'sources',
	snapshots.map((node) => source.slice(node.start, node.end)).join('\n') +
		'\n' +
		source.slice(functions[0].start, functions[0].end) +
		'\nreturn readersOf;'
);

// Expected tokens are authored independently of the actual regular expressions.
const cases = [
	['dot', '.item', ['item']],
	['dot boundary', '.item_suffix\n.item-more', ['item', 'item_suffix']],
	['double quote', '"item"', ['item']],
	['single quote', "'item'", ['item']],
	['double bracket', '["item"]', ['item']],
	['single bracket', "['item']", ['item']],
	['bracket spaces', '[ "item" ]', ['item']],
	['Lua comment', '-- "item"', []],
	['AHK comment', '; .item', []],
	['JS comment', '// ["item"]', []],
	['indented comments', ' \t-- .item\n\t; "item"\n // \'item\'', []],
	['inline comment remains credited', 'x -- "item"', ['item']],
	['quoted comment marker', '"-- item"\n"item"', ['item']],
	['opposite quote', '"x \'item\' y"', ['item']],
	['long-comment interior retains prior contract', '--[[\n"item"\n]]', ['item']],
	['empty', '', []],
	['blank', '\n \t\n', []],
	['CRLF', '; .item\r\n"item"\r\n', ['item']],
	['lone CR retains LF-only splitting', '// first\r"item"', []],
	['EOF', 'tail.item', ['item']],
	['BOM', '\ufeff-- "item"\n"item"', ['item']],
	['Unicode', 'π.item\n"é"', ['item', 'é']],
	['non-BMP', '😀.item\n"😀"', ['item', '😀']],
	['dot in key', '"a.b"', ['a.b']],
	['regex symbol in key', '"a*b"', ['a*b']],
	['quote in key', '"a\'b"', ["a'b"]],
	['dollar in key', '"$name"', ['$name']],
	['dash after word boundary', '.item-more', ['item']],
	['multiple hits in one record', '"item"\n.item\n[\'item\']', ['item']],
	['no hit', 'ordinary text', []]
];
const tokens = ['item', 'item_suffix', 'a.b', 'a*b', "a'b", '$name', 'é', '😀', 'absent'];
for (const [name, src, accepted] of cases) {
	const reader = makeReader([
		{ rel: 'first', src },
		{ rel: 'duplicate', src },
		{ rel: 'duplicate', src },
		{ rel: 'last', src: '"item"' }
	]);
	for (const token of tokens) {
		const expected = accepted.includes(token) ? ['first', 'duplicate', 'duplicate'] : [];
		if (token === 'item') expected.push('last');
		assert.deepEqual(reader(token), expected, name + '/' + token);
	}
}

const counts = [
	{ split: 0, trim: 0 },
	{ split: 0, trim: 0 },
	{ split: 0, trim: 0 }
];
const records = ['"item"', '; "item"', 'other.item'].map((value, index) => {
	const src = new String(value);
	// Observe only these owned fixture values, without replacing a prototype.
	src.split = (...args) => {
		counts[index].split++;
		return String.prototype.split.apply(value, args).map((text) => {
			const line = new String(text);
			line.trimStart = () => {
				counts[index].trim++;
				return String.prototype.trimStart.call(text);
			};
			return line;
		});
	};
	return { rel: 'source-' + index, src };
});
const reader = makeReader(records);
for (const token of ['item', 'absent', 'item', 'other']) reader(token);
assert.deepEqual(
	counts,
	[
		{ split: 1, trim: 1 },
		{ split: 1, trim: 1 },
		{ split: 1, trim: 1 }
	],
	'each captured source is split and each line classified exactly once across independent queries'
);
console.log('Menu reader line snapshot: 270 semantic queries and deterministic work bounds OK');
