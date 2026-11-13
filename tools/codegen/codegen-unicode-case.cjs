// tools/codegen/codegen-unicode-case.cjs

/**
 * ==============================================================================
 * MODULE: Unicode Case Data Codegen
 * DESCRIPTION:
 * Emits complete default Unicode upper-, lower-, and title-case mappings for the
 * shared Lua text-case module (_shared/core/text/engine/unicode_case), which the macOS and Linux
 * drivers both load. Lua's byte-oriented string.upper/string.lower only handle
 * ASCII, so the selection case actions consume this generated lookup instead.
 * Windows converts through the operating system (StrUpper / StrLower), which has
 * no title-case form, so this script also writes the characters whose title
 * case differs from their uppercase (ǆ -> ǅ, ß -> Ss, ﬁ -> Fi) to
 * windows/_generated/unicode_title.ahk for its title-case rule.
 *
 * WHY ONE TABLE IN _shared:
 * The table used to be generated for Linux alone, while macOS transformed the
 * selection with string.upper/string.lower and left é, à and ç unchanged. One
 * generated file loaded by both drivers leaves no second copy to drift.
 *
 * REPRODUCIBILITY:
 * ECMAScript case conversion is defined from Unicode default case conversion.
 * The repository pins its Node runtime in .node-version; the explicit
 * Unicode-version guard makes a runtime data upgrade fail loudly instead of
 * silently changing output.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const EXPECTED_UNICODE_VERSION = '17.0';
const ROOT = path.resolve(__dirname, '..', '..');
const OUT = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'_shared',
	'core',
	'text',
	'engine',
	'unicode_case',
	'data.lua'
);
const AHK_OUT = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'windows',
	'_generated',
	'unicode_title.ahk'
);
const FOLD_SOURCE = path.join(ROOT, 'tools', 'codegen', 'unicode', 'CaseFolding-17.0.0.txt');
const FOLD_SHA256 = 'ff8d8fefbf123574205085d6714c36149eb946d717a0c585c27f0f4ef58c4183';
const foldBytes = fs.readFileSync(FOLD_SOURCE);
if (crypto.createHash('sha256').update(foldBytes).digest('hex') !== FOLD_SHA256) {
	throw new Error('Unicode 17.0.0 CaseFolding.txt does not match the reviewed official source');
}
// Unicode simple case folding uses exactly statuses C and S. F is the distinct
// full-fold mapping (which may expand), and T is the Turkic-specific mapping.
const simpleFold = [];
for (const line of foldBytes.toString('utf8').split(/\r?\n/)) {
	const record = line.match(/^([0-9A-F]+);\s*([CSFT]);\s*([0-9A-F ]+);/);
	if (!record || (record[2] !== 'C' && record[2] !== 'S')) continue;
	const mapped = record[3].trim().split(/\s+/);
	if (mapped.length !== 1) throw new Error('simple case fold must retain one scalar');
	simpleFold.push([
		String.fromCodePoint(parseInt(record[1], 16)),
		String.fromCodePoint(parseInt(mapped[0], 16))
	]);
}
if (simpleFold.length < 1400)
	throw new Error('Unicode simple case fold is unexpectedly incomplete');

if (process.versions.unicode !== EXPECTED_UNICODE_VERSION) {
	throw new Error(
		`Unicode ${EXPECTED_UNICODE_VERSION} is required; Node exposes ${process.versions.unicode}. ` +
			'Update the pinned version and review the generated diff deliberately.'
	);
}

const titlecaseByLower = new Map();
for (let codepoint = 0; codepoint <= 0x10ffff; codepoint++) {
	if (codepoint >= 0xd800 && codepoint <= 0xdfff) continue;
	const character = String.fromCodePoint(codepoint);
	if (/^\p{Lt}$/u.test(character)) titlecaseByLower.set(character.toLowerCase(), character);
}

function uppercaseFirstCodepoint(text) {
	const characters = [...text];
	if (characters.length === 0) return text;
	return characters[0].toUpperCase() + characters.slice(1).join('');
}

function titlecaseCharacter(character) {
	const dedicated = titlecaseByLower.get(character.toLowerCase());
	if (dedicated) return dedicated;
	return uppercaseFirstCodepoint(character.toUpperCase().toLowerCase());
}

const upper = [];
const lower = [];
const title = [];
const boundary = [];
const wordSeparator = [];
const caseIgnorable = [];
const cased = [];
for (let codepoint = 0; codepoint <= 0x10ffff; codepoint++) {
	if (codepoint >= 0xd800 && codepoint <= 0xdfff) continue;
	const character = String.fromCodePoint(codepoint);
	const uppercase = character.toUpperCase();
	const lowercase = character.toLowerCase();
	if (/^[\p{White_Space}\p{P}]$/u.test(character)) boundary.push(character);
	if (/^[\p{White_Space}\p{Pd}]$/u.test(character)) wordSeparator.push(character);
	if (/^\p{Case_Ignorable}$/u.test(character)) caseIgnorable.push(character);
	if (/^\p{Cased}$/u.test(character)) cased.push(character);
	if (uppercase !== character) {
		upper.push([character, uppercase]);
		const titlecase = titlecaseCharacter(character);
		if (titlecase !== character) title.push([character, titlecase]);
	}
	if (lowercase !== character) lower.push([character, lowercase]);
}

if (
	upper.length < 1500 ||
	lower.length < 1400 ||
	title.length < 1500 ||
	boundary.length < 800 ||
	wordSeparator.length < 45 ||
	caseIgnorable.length < 2700 ||
	cased.length < 4500
) {
	throw new Error(
		`case data unexpectedly small: upper=${upper.length}, lower=${lower.length}, ` +
			`title=${title.length}, boundary=${boundary.length}, wordSeparator=${wordSeparator.length}, ` +
			`caseIgnorable=${caseIgnorable.length}, cased=${cased.length}`
	);
}
if (
	'straße'.toUpperCase() !== 'STRASSE' ||
	titlecaseCharacter('ß') !== 'Ss' ||
	titlecaseCharacter('ǆ') !== 'ǅ'
) {
	throw new Error('the runtime does not expose the expected Unicode special casing');
}

function quote(value) {
	const escaped = value
		.replace(/\\/g, '\\\\')
		.replace(/"/g, '\\"')
		.replace(
			/[\0-\x1F\x7F]/g,
			(character) => '\\' + String(character.codePointAt(0)).padStart(3, '0')
		);
	return '"' + escaped + '"';
}

const lines = [
	'--- _shared/core/text/engine/unicode_case/data.lua',
	'--- AUTO-GENERATED from Unicode default case conversion in Node 22.',
	'--- DO NOT EDIT BY HAND — run `npm run codegen:unicode-case` to refresh.',
	'',
	'--- ==============================================================================',
	'--- MODULE: Unicode Case Data',
	'--- DESCRIPTION:',
	`--- Complete Unicode ${EXPECTED_UNICODE_VERSION} default case mappings consumed by`,
	'--- the shared unicode_case module on macOS and Linux. Multi-codepoint mappings are',
	'--- retained verbatim. word_separator (whitespace and dashes) starts a title-case',
	'--- word.',
	'--- ==============================================================================',
	'',
	'return {',
	`\tunicode_version = ${quote(EXPECTED_UNICODE_VERSION)},`
];

for (const [name, rows] of [
	['upper', upper],
	['lower', lower],
	['title', title],
	['simple_fold', simpleFold]
]) {
	lines.push(`\t${name} = {`);
	for (const [from, to] of rows) lines.push(`\t\t[${quote(from)}] = ${quote(to)},`);
	lines.push('\t},');
}
for (const [name, characters] of [
	['boundary', boundary],
	['word_separator', wordSeparator],
	['case_ignorable', caseIgnorable],
	['cased', cased]
]) {
	lines.push(`\t${name} = {`);
	for (const character of characters) lines.push(`\t\t[${quote(character)}] = true,`);
	lines.push('\t},');
}
lines.push('}', '');

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, lines.join('\n'), 'utf8');
console.log(`  wrote ${path.relative(ROOT, OUT).split(path.sep).join('/')}`);

// The title-case forms Windows' StrUpper cannot give.
const titleExceptions = title.filter(([from, to]) => to !== from.toUpperCase());
if (titleExceptions.length < 40 || !titleExceptions.some(([from]) => from === 'ǆ')) {
	throw new Error(`title-case exceptions unexpectedly few: ${titleExceptions.length}`);
}
// The file is UTF-8 with a BOM, so the characters are written literally; none
// of them is a quote or AHK's escape character.
const ahkString = (value) => {
	if (/["`\p{Cc}]/u.test(value))
		throw new Error(`unexpected character in ${JSON.stringify(value)}`);
	return '"' + value + '"';
};
const ahk = [
	'\uFEFF; _generated/unicode_title.ahk',
	'',
	'; Generated by tools/codegen/codegen-unicode-case.cjs; do not edit.',
	`; Source: Unicode ${EXPECTED_UNICODE_VERSION} default case conversion in Node 22, the table the Lua`,
	'; drivers read (_shared/core/text/engine/unicode_case/data.lua): the characters whose title',
	"; case is not their uppercase, which Windows' StrUpper cannot give.",
	'',
	'UnicodeTitleExceptions() {',
	'\tstatic Data := Map(',
	titleExceptions
		.map(
			([from, to], index) =>
				`\t\t${ahkString(from)}, ${ahkString(to)}${index < titleExceptions.length - 1 ? ',' : ''}`
		)
		.join('\n'),
	'\t)',
	'\treturn Data',
	'}',
	''
].join('\n');
fs.writeFileSync(AHK_OUT, ahk, 'utf8');
console.log(`  wrote ${path.relative(ROOT, AHK_OUT).split(path.sep).join('/')}`);
console.log(
	`[OK] Unicode ${EXPECTED_UNICODE_VERSION}: ${upper.length} upper, ${lower.length} lower, ` +
		`${title.length} title mappings, ${boundary.length} word boundaries, ` +
		`${wordSeparator.length} title-case word separators, ` +
		`${caseIgnorable.length} case-ignorable characters, ${cased.length} cased characters.`
);
