// tools/codegen/codegen-unicode-names.cjs

/**
 * ==============================================================================
 * MODULE: Unicode Names Table Codegen
 * DESCRIPTION:
 * Generates `_shared/ui/layout_editor/_generated/unicode_names.js`, the
 * character names, aliases and blocks the layout editor's name search and
 * character magnifier read (layout_editor/unicode_names.js decodes it), from
 * the vendored Unicode 17.0.0 files in tools/codegen/unicode/:
 *   - UnicodeNames-17.0.0.txt: `CODE;NAME` per named character, with each run
 *     of algorithmic names collapsed to one `FIRST..LAST;RULE` line, where RULE
 *     is `PREFIX-*` (the code point in hex), `HANGUL SYLLABLE *` (Unicode
 *     chapter 3.12) or `PREFIX#NNN` (a zero-padded decimal counter);
 *   - NameAliases-17.0.0.txt: NameAliases.txt layout (`CODE;ALIAS;TYPE`);
 *   - Blocks-17.0.0.txt: Blocks.txt layout (`FIRST..LAST; Name`).
 *
 * PROVENANCE:
 * unicode.org is not reachable from the session that vendored these files, so
 * they were extracted, as data, from the npm package @unicode/unicode-17.0.0
 * 2.1.0 (MIT, built from the official UCD 17.0.0; tarball integrity
 * sha512-vin4t0thqky14…rl2Ae9+YjJjtA==): its brotli name, alias and block
 * payloads were decoded without running the package, the 159,801 names were
 * checked to expand back exactly from the collapsed list, and block spellings
 * were taken from the official 16.0.0 Blocks.txt for every block 17.0 kept
 * (the eight blocks new in 17.0 have no hyphen or apostrophe). Unicode data is
 * under the Unicode License v3 (notice in _shared/ui/vendor/LICENSES.md).
 * Replace the three files with the official UCD when refreshing, keep their
 * layout and update the digests below.
 *
 * FEATURES & RATIONALE:
 * 1. Small: names are tokenized on spaces into a frequency-sorted word list,
 *    each name a run of 5-bit variable-length word indices; algorithmic runs
 *    stay rules, so CJK, Tangut and Hangul cost one line each.
 * 2. Classic script: the macOS and Linux hosts inline the page's scripts and
 *    the site injects this one lazily, so the table is a top-level var.
 * 3. Deterministic: no timestamp; digests fail loudly on a changed input.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { shared } = require('../lib/paths.cjs');

const UNICODE_VERSION = '17.0.0';
const SOURCE_DIR = path.join(__dirname, 'unicode');
const OUT_PATH = shared('ui', 'layout_editor', '_generated', 'unicode_names.js');
const SOURCES = {
	names: [
		`UnicodeNames-${UNICODE_VERSION}.txt`,
		'223a1798b0e93d30d73ff8fe1032703dd156c244130b8e76f088f33f4099dca4'
	],
	aliases: [
		`NameAliases-${UNICODE_VERSION}.txt`,
		'85cd333bc1fb395932a54f7fd5316d79a25882ce9ade179b4c7ff6425f8dd292'
	],
	blocks: [
		`Blocks-${UNICODE_VERSION}.txt`,
		'ebb014f06cef57c9582c65f04c7e41a1290d20b6211cdb0009a7239a67075da5'
	]
};
// The 64 characters of an encoded index; none needs escaping in a JS string.
const DIGITS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';

/**
 * Reads a vendored file and checks its pinned digest.
 * @param {string} kind - Key of SOURCES.
 * @returns {string[]} Its non-empty lines.
 */
function readSource(kind) {
	const [file, digest] = SOURCES[kind];
	const bytes = fs.readFileSync(path.join(SOURCE_DIR, file));
	const actual = crypto.createHash('sha256').update(bytes).digest('hex');
	if (actual !== digest)
		throw new Error(`${file}: sha256 ${actual} does not match the pinned ${digest}`);
	return bytes.toString('utf8').split('\n').filter(Boolean);
}

/**
 * Encodes a non-negative integer: 5 bits per digit, low bits first; digits
 * 32..63 continue, 0..31 end the number.
 * @param {number} value
 * @returns {string}
 */
function encodeNumber(value) {
	let out = '';
	let rest = value;
	while (rest >= 32) {
		out += DIGITS[32 + (rest & 31)];
		rest = Math.floor(rest / 32);
	}
	return out + DIGITS[rest];
}

/** Parses a `FIRST..LAST` or `CODE` field. */
function parseRange(field) {
	const [first, last] = field.split('..').map((hex) => {
		if (!/^[0-9A-F]{4,6}$/.test(hex)) throw new Error(`bad code point ${hex}`);
		return parseInt(hex, 16);
	});
	return [first, last === undefined ? first : last];
}

/**
 * Builds the table from the vendored files.
 * @returns {{version: string, words: string, names: string, rules: Array,
 *   aliases: Array, blocks: Array}}
 */
function buildData() {
	const explicit = [];
	const rules = [];
	for (const line of readSource('names')) {
		const [field, name] = line.split(';');
		const [first, last] = parseRange(field);
		if (first !== last) {
			const counter = /^(.*)#(\d+)$/.exec(name);
			if (name === 'HANGUL SYLLABLE *') rules.push([first, last, 'hangul']);
			else if (name.endsWith('-*')) rules.push([first, last, 'hex', name.slice(0, -1)]);
			else if (counter) rules.push([first, last, 'decimal', counter[1], counter[2]]);
			else throw new Error(`unknown name rule ${line}`);
		} else explicit.push([first, name]);
	}
	const frequency = new Map();
	for (const [, name] of explicit)
		for (const word of name.split(' ')) frequency.set(word, (frequency.get(word) || 0) + 1);
	const words = [...frequency.keys()].sort(
		(a, b) => frequency.get(b) - frequency.get(a) || (a < b ? -1 : a > b ? 1 : 0)
	);
	const index = new Map(words.map((word, i) => [word, i + 1]));
	let names = '';
	let previous = -1;
	for (const [point, name] of explicit) {
		if (point <= previous) throw new Error(`names out of order at ${point.toString(16)}`);
		names += encodeNumber(point - previous - 1);
		for (const word of name.split(' ')) names += encodeNumber(index.get(word));
		names += encodeNumber(0);
		previous = point;
	}
	const aliases = readSource('aliases').map((line) => {
		const [code, alias, type] = line.split(';');
		return [parseRange(code)[0], alias, type];
	});
	const blocks = readSource('blocks').map((line) => {
		const match = /^([0-9A-F.]+); (.+)$/.exec(line);
		if (!match) throw new Error(`bad block line ${line}`);
		return [...parseRange(match[1]), match[2]];
	});
	return { version: UNICODE_VERSION, words: words.join(' '), names, rules, aliases, blocks };
}

/**
 * Builds the complete generated file.
 * @returns {string} JS source with LF line ends and a final newline.
 */
function buildSource() {
	const data = buildData();
	return [
		'// _shared/ui/layout_editor/_generated/unicode_names.js',
		'',
		'// ==========================================',
		'// AUTO-GENERATED — do not edit manually',
		...Object.values(SOURCES).map(([file]) => `// Source: tools/codegen/unicode/${file}`),
		'// Run: npm run codegen:unicode-names',
		'// ==========================================',
		'',
		`// Unicode ${UNICODE_VERSION} names, aliases and blocks, decoded by layout_editor/unicode_names.js.`,
		'// Unicode data: Copyright © 1991-2025 Unicode, Inc., Unicode License v3.',
		'var UNICODE_NAMES_DATA = {',
		Object.entries(data)
			.map(([name, value]) => `\t${JSON.stringify(name)}: ${JSON.stringify(value)}`)
			.join(',\n'),
		'};',
		''
	].join('\n');
}

/** Writes the generated file. */
function main() {
	console.log('codegen:unicode-names — generating the layout editor Unicode names table…');
	fs.mkdirSync(path.dirname(OUT_PATH), { recursive: true });
	fs.writeFileSync(OUT_PATH, buildSource());
	console.log(`codegen:unicode-names — wrote ${OUT_PATH}`);
}

if (require.main === module) main();

module.exports = { buildData, buildSource, OUT_PATH, DIGITS, UNICODE_VERSION };
