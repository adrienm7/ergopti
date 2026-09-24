// tools/codegen/codegen-unicode-case.cjs

/**
 * ==============================================================================
 * MODULE: Unicode Case Data Codegen
 * DESCRIPTION:
 * Emits complete default Unicode upper-, lower-, and title-case mappings for the
 * shared Lua text-case module (_shared/lua/unicode_case), which the macOS and Linux
 * drivers both load. Lua's byte-oriented string.upper/string.lower only handle
 * ASCII, so the selection case actions consume this generated lookup instead.
 * Windows converts through the operating system (StrUpper / StrLower) and does
 * not read this table.
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

const EXPECTED_UNICODE_VERSION = '17.0';
const ROOT = path.resolve(__dirname, '..', '..');
const OUT = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'_shared',
	'lua',
	'unicode_case',
	'data.lua'
);

if (process.versions.unicode !== EXPECTED_UNICODE_VERSION) {
	throw new Error(
		`Unicode ${EXPECTED_UNICODE_VERSION} is required; Node exposes ${process.versions.unicode}. ` +
		'Update the pinned version and review the generated diff deliberately.'
	);
}

const titlecaseByLower = new Map();
for (let codepoint = 0; codepoint <= 0x10FFFF; codepoint++) {
	if (codepoint >= 0xD800 && codepoint <= 0xDFFF) continue;
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
for (let codepoint = 0; codepoint <= 0x10FFFF; codepoint++) {
	if (codepoint >= 0xD800 && codepoint <= 0xDFFF) continue;
	const character = String.fromCodePoint(codepoint);
	const uppercase = character.toUpperCase();
	const lowercase = character.toLowerCase();
	if (/^[\p{White_Space}\p{P}]$/u.test(character)) boundary.push(character);
	if (/^[\p{White_Space}\p{Pd}]$/u.test(character)) wordSeparator.push(character);
	if (/^\p{Case_Ignorable}$/u.test(character)) caseIgnorable.push(character);
	if (uppercase !== character) {
		upper.push([character, uppercase]);
		const titlecase = titlecaseCharacter(character);
		if (titlecase !== character) title.push([character, titlecase]);
	}
	if (lowercase !== character) lower.push([character, lowercase]);
}

if (upper.length < 1500 || lower.length < 1400 || title.length < 1500
		|| boundary.length < 800 || wordSeparator.length < 45 || caseIgnorable.length < 2700) {
	throw new Error(
		`case data unexpectedly small: upper=${upper.length}, lower=${lower.length}, ` +
		`title=${title.length}, boundary=${boundary.length}, wordSeparator=${wordSeparator.length}, ` +
		`caseIgnorable=${caseIgnorable.length}`
	);
}
if ('straße'.toUpperCase() !== 'STRASSE' || titlecaseCharacter('ß') !== 'Ss'
		|| titlecaseCharacter('ǆ') !== 'ǅ') {
	throw new Error('the runtime does not expose the expected Unicode special casing');
}

function quote(value) {
	const escaped = value
		.replace(/\\/g, '\\\\')
		.replace(/"/g, '\\"')
		.replace(/[\0-\x1F\x7F]/g, (character) =>
			'\\' + String(character.codePointAt(0)).padStart(3, '0'));
	return '"' + escaped + '"';
}

const lines = [
	'--- _shared/lua/unicode_case/data.lua',
	'--- AUTO-GENERATED from Unicode default case conversion in Node 22.',
	'--- DO NOT EDIT BY HAND — run `npm run codegen:unicode-case` to refresh.',
	'',
	'--- ==============================================================================',
	'--- MODULE: Unicode Case Data',
	'--- DESCRIPTION:',
	`--- Complete Unicode ${EXPECTED_UNICODE_VERSION} default case mappings consumed by`,
	'--- unicode_case/init.lua on macOS and Linux. Multi-codepoint mappings are retained',
	'--- verbatim. word_separator (whitespace and dashes) starts a title-case word.',
	'--- ==============================================================================',
	'',
	'return {',
	`\tunicode_version = ${quote(EXPECTED_UNICODE_VERSION)},`,
];

for (const [name, rows] of [['upper', upper], ['lower', lower], ['title', title]]) {
	lines.push(`\t${name} = {`);
	for (const [from, to] of rows) lines.push(`\t\t[${quote(from)}] = ${quote(to)},`);
	lines.push('\t},');
}
for (const [name, characters] of [
	['boundary', boundary],
	['word_separator', wordSeparator],
	['case_ignorable', caseIgnorable]
]) {
	lines.push(`\t${name} = {`);
	for (const character of characters) lines.push(`\t\t[${quote(character)}] = true,`);
	lines.push('\t},');
}
lines.push('}', '');

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, lines.join('\n'), 'utf8');
console.log(`  wrote ${path.relative(ROOT, OUT).split(path.sep).join('/')}`);
console.log(
	`[OK] Unicode ${EXPECTED_UNICODE_VERSION}: ${upper.length} upper, ${lower.length} lower, ` +
	`${title.length} title mappings, ${boundary.length} word boundaries, ` +
	`${wordSeparator.length} title-case word separators, ` +
	`${caseIgnorable.length} case-ignorable characters.`
);
