// tools/codegen/codegen-unicode-case-linux.cjs

/**
 * ==============================================================================
 * MODULE: Unicode Case Data Codegen (Linux)
 * DESCRIPTION:
 * Emits complete default Unicode upper-, lower-, and title-case mappings for the
 * LuaJIT Linux driver. Lua's byte-oriented string.upper/string.lower only handle
 * ASCII, so runtime selection transforms consume this generated lookup instead.
 *
 * REPRODUCIBILITY:
 * ECMAScript case conversion is defined from Unicode default case conversion.
 * Node 22 is the repository CI runtime; the explicit Unicode-version guard makes
 * a future runtime data upgrade fail loudly instead of silently changing output.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const EXPECTED_UNICODE_VERSION = '16.0';
const ROOT = path.resolve(__dirname, '..', '..');
const OUT = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'linux',
	'_generated',
	'unicode_case_data.lua'
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
const caseIgnorable = [];
for (let codepoint = 0; codepoint <= 0x10FFFF; codepoint++) {
	if (codepoint >= 0xD800 && codepoint <= 0xDFFF) continue;
	const character = String.fromCodePoint(codepoint);
	const uppercase = character.toUpperCase();
	const lowercase = character.toLowerCase();
	if (/^[\p{White_Space}\p{P}]$/u.test(character)) boundary.push(character);
	if (/^\p{Case_Ignorable}$/u.test(character)) caseIgnorable.push(character);
	if (uppercase !== character) {
		upper.push([character, uppercase]);
		const titlecase = titlecaseCharacter(character);
		if (titlecase !== character) title.push([character, titlecase]);
	}
	if (lowercase !== character) lower.push([character, lowercase]);
}

if (upper.length < 1500 || lower.length < 1400 || title.length < 1500
		|| boundary.length < 800 || caseIgnorable.length < 2700) {
	throw new Error(
		`case data unexpectedly small: upper=${upper.length}, lower=${lower.length}, ` +
		`title=${title.length}, boundary=${boundary.length}, caseIgnorable=${caseIgnorable.length}`
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
	'--- _generated/unicode_case_data.lua',
	'--- AUTO-GENERATED from Unicode default case conversion in Node 22.',
	'--- DO NOT EDIT BY HAND — run `npm run codegen:unicode-case:linux` to refresh.',
	'',
	'--- ==============================================================================',
	'--- MODULE: Unicode Case Data (Linux)',
	'--- DESCRIPTION:',
	`--- Complete Unicode ${EXPECTED_UNICODE_VERSION} default case mappings consumed by`,
	'--- infra/unicode_case.lua. Multi-codepoint mappings are retained verbatim.',
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
lines.push('\tboundary = {');
for (const character of boundary) lines.push(`\t\t[${quote(character)}] = true,`);
lines.push('\t},');
lines.push('\tcase_ignorable = {');
for (const character of caseIgnorable) lines.push(`\t\t[${quote(character)}] = true,`);
lines.push('\t},');
lines.push('}', '');

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, lines.join('\n'), 'utf8');
console.log(`  wrote ${path.relative(ROOT, OUT).split(path.sep).join('/')}`);
console.log(
	`[OK] Unicode ${EXPECTED_UNICODE_VERSION}: ${upper.length} upper, ${lower.length} lower, ` +
	`${title.length} title mappings, ${boundary.length} word boundaries, ` +
	`${caseIgnorable.length} case-ignorable characters.`
);
