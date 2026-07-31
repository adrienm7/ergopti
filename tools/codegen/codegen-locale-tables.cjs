// tools/codegen/codegen-locale-tables.cjs

/**
 * ==============================================================================
 * MODULE: Locale Table Codegen
 * DESCRIPTION:
 * Emits each driver's language-menu table from the two shared sources:
 * locale_order.json (display order) and locale_names.json (native name + flag).
 *
 * WHY THIS EXISTS:
 * The order was already single-sourced and gated. The NAMES were not — three
 * hand-maintained tables, and one of them had silently fallen behind: the Linux
 * `display_name()` map carried 16 of the 21 locales, and its lookup ends in
 * `return names[code] or code`. So `da`, `no`, `cs`, `he` and `hi` rendered in
 * the Linux language menu as those raw two-letter codes, sitting between
 * `Nederlands` and `Русский`, while the other sixteen showed their native names.
 * Nothing failed; five rows just looked like a bug nobody had filed.
 *
 * macOS and Windows agreed on all 21 names, which is what made the shared file
 * derivable rather than a judgement call.
 *
 * WHAT STAYS PER-DRIVER:
 * The presentation column. macOS and Linux show a flag emoji; Windows shows a
 * "[XX]" tag, because flag emoji do not render in Win32 menus — that is a real
 * platform constraint, not drift, so the generator emits the right column for
 * each target rather than forcing one representation on all three. The Windows
 * tag is derived from the code and therefore carries no data of its own.
 *
 * USAGE:  node tools/codegen/codegen-locale-tables.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const SHARED = path.join(SP, '_shared', 'data');

const order = JSON.parse(fs.readFileSync(path.join(SHARED, 'locale_order.json'), 'utf8')).order;
const names = JSON.parse(fs.readFileSync(path.join(SHARED, 'locale_names.json'), 'utf8')).locales;

// Fail before writing anything: a locale in the order with no name would emit a
// table whose row is silently blank, which is the failure being fixed.
const missing = order.filter((c) => !names[c] || !names[c].name);
if (missing.length > 0) {
	console.error(
		`[ERROR] locale_order.json lists ${missing.join(', ')} but locale_names.json has no name for ` +
			'them — every ordered locale needs a native name or its menu row renders as a bare code.'
	);
	process.exit(1);
}
const extra = Object.keys(names).filter((c) => !order.includes(c));
if (extra.length > 0) {
	console.error(
		`[ERROR] locale_names.json names ${extra.join(', ')}, which locale_order.json does not list — ` +
			'an unordered locale never appears in any menu, so the name is unreachable.'
	);
	process.exit(1);
}

/**
 * Pads an already-quoted token to a fixed display width, counting codepoints.
 *
 * The padding goes AFTER the closing quote, never inside the string. The
 * hand-written tables this replaces aligned that way; padding inside would put
 * trailing spaces into the name the menu actually renders — invisible in a diff
 * and visible in the UI.
 */
function padToken(token, width) {
	const len = Array.from(token).length;
	return token + ' '.repeat(Math.max(0, width - len));
}

const HEADER_WHY = [
	'The display ORDER comes from _shared/data/locale_order.json and the native',
	'names from _shared/data/locale_names.json. Both are shared, because three',
	'hand-maintained copies is how the Linux table came to hold 16 of 21 locales',
	'— its five missing rows rendered as bare two-letter codes in the menu.'
];

// ── macOS: { code, flag, name } ─────────────────────────────────────────────

function emitMacos() {
	const rows = order.map((c) => {
		const e = names[c];
		return `\t{ code = "${c}", flag = "${e.flag}", name = ${padToken('"' + e.name + '"', 14)} },`;
	});
	return (
		'--- _generated/locale_table.lua\n' +
		'--- AUTO-GENERATED from _shared/data/locale_order.json + locale_names.json.\n' +
		'--- DO NOT EDIT BY HAND — run `npm run codegen:locale-tables` to refresh.\n' +
		'\n' +
		'--- ==============================================================================\n' +
		'--- MODULE: Locale Table (macOS)\n' +
		'--- DESCRIPTION:\n' +
		'--- The language menu rows, in canonical display order.\n' +
		'---\n' +
		HEADER_WHY.map((l) => '--- ' + l).join('\n') +
		'\n' +
		'--- ==============================================================================\n' +
		'\n' +
		'return {\n' +
		rows.join('\n') +
		'\n}\n'
	);
}

// ── Linux: code → name (its menu resolves the flag separately) ──────────────

function emitLinux() {
	const rows = order.map((c) => `\t{ code = "${c}", flag = "${names[c].flag}", name = "${names[c].name}" },`);
	return (
		'--- _generated/locale_table.lua\n' +
		'--- AUTO-GENERATED from _shared/data/locale_order.json + locale_names.json.\n' +
		'--- DO NOT EDIT BY HAND — run `npm run codegen:locale-tables` to refresh.\n' +
		'\n' +
		'--- ==============================================================================\n' +
		'--- MODULE: Locale Table (Linux)\n' +
		'--- DESCRIPTION:\n' +
		'--- The language menu rows, in canonical display order.\n' +
		'---\n' +
		HEADER_WHY.map((l) => '--- ' + l).join('\n') +
		'\n' +
		'--- ==============================================================================\n' +
		'\n' +
		'return {\n' +
		rows.join('\n') +
		'\n}\n'
	);
}

// ── Windows: [XX] tag instead of a flag ─────────────────────────────────────

function emitWindows() {
	const rows = order.map(
		(c) => `\t\t{ Code: "${c}", Tag: "[${c.toUpperCase()}]", Name: ${padToken('"' + names[c].name + '"', 14)} },`
	);
	return (
		'﻿; _generated/locale_table.ahk\n' +
		'; AUTO-GENERATED from _shared/data/locale_order.json + locale_names.json.\n' +
		'; DO NOT EDIT BY HAND — run `npm run codegen:locale-tables` to refresh.\n' +
		'#Requires AutoHotkey v2.0\n' +
		'\n' +
		'; ==============================================================================\n' +
		'; MODULE: Locale Table (Windows)\n' +
		'; DESCRIPTION:\n' +
		'; The language menu rows, in canonical display order.\n' +
		';\n' +
		HEADER_WHY.map((l) => '; ' + l).join('\n') +
		'\n' +
		'; The presentation column is a "[XX]" tag rather than a flag emoji, because\n' +
		'; flag emoji do not render in Win32 menus. It is derived from the code, so it\n' +
		'; carries no data of its own and cannot drift from one.\n' +
		'; ==============================================================================\n' +
		'\n' +
		'; A function, not a global initialiser, so include order cannot matter.\n' +
		'LocaleTableData() {\n' +
		'\treturn [\n' +
		rows.join('\n') +
		'\n\t]\n' +
		'}\n'
	);
}

const targets = [
	[path.join(SP, 'macos/_generated/locale_table.lua'), emitMacos()],
	[path.join(SP, 'linux/_generated/locale_table.lua'), emitLinux()],
	[path.join(SP, 'windows/_generated/locale_table.ahk'), emitWindows()]
];

for (const [abs, content] of targets) {
	fs.mkdirSync(path.dirname(abs), { recursive: true });
	fs.writeFileSync(abs, content.replace(/\r\n/g, '\n'), 'utf8');
	console.log(`  wrote ${path.relative(ROOT, abs).split(path.sep).join('/')}`);
}

console.log(`[OK] locale tables generated for three drivers: ${order.length} locale(s) each.`);
