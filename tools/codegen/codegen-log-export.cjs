// tools/codegen/codegen-log-export.cjs

/**
 * ==============================================================================
 * MODULE: Log Export Codegen
 * DESCRIPTION:
 * Emits the « Export the logs (zip) » archive data (days kept, archive name,
 * crash report extension and the privacy scrub rules) for the shared Lua tree
 * (macOS and Linux) and for AutoHotkey, from the canonical
 * _shared/core/logger/data/log_export.toml.
 *
 * WHY THIS EXISTS:
 * The scrub rules decide what typed text never leaves the machine. Three
 * hand-kept copies would drift the way the topical routing tables did before
 * they were generated, and a drifted copy ships the user's text. The generated
 * files are committed, so no driver parses the TOML at runtime.
 *
 * USAGE:  node tools/codegen/codegen-log-export.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const SOURCE = path.join(SP, '_shared/core/logger/data/log_export.toml');

/** Prints a refusal and stops before any output is written. */
function fail(message) {
	console.error(`[ERROR] log_export.toml: ${message}`);
	process.exit(1);
}

/** A non-empty string field, or a refusal. */
function requireString(table, key, where, allowEmpty = false) {
	const value = table ? table[key] : undefined;
	if (typeof value !== 'string' || (!allowEmpty && value === '') || /[\r\n\0]/.test(value)) {
		fail(`${where}.${key} must be a single-line${allowEmpty ? '' : ' non-empty'} string.`);
	}
	return value;
}

const parsed = toml.parse(fs.readFileSync(SOURCE, 'utf8'));
const archive = parsed.archive || fail('[archive] is missing.');
const scrub = parsed.scrub || fail('[scrub] is missing.');

const days = archive.days;
if (!Number.isSafeInteger(days) || days < 1 || days > 31) {
	fail('archive.days must be a whole number of days from 1 to 31.');
}
const namePrefix = requireString(archive, 'name_prefix', 'archive');
const extension = requireString(archive, 'extension', 'archive');
const crashReportExtension = requireString(archive, 'crash_report_extension', 'archive');
for (const [key, value] of [
	['name_prefix', namePrefix],
	['extension', extension],
	['crash_report_extension', crashReportExtension]
]) {
	if (/[\\/:*?"<>|]/.test(value)) fail(`archive.${key} must be usable in a file name.`);
}
const withheld = requireString(scrub, 'withheld', 'scrub');
const rules = scrub.rules;
if (!Array.isArray(rules) || rules.length === 0) fail('[[scrub.rules]] declares no rule.');
const markers = new Set();
for (const [index, rule] of rules.entries()) {
	const where = `scrub.rules[${index}]`;
	const marker = requireString(rule, 'marker', where);
	requireString(rule, 'cut', where, true);
	if (markers.has(marker)) fail(`${where}.marker repeats ${JSON.stringify(marker)}.`);
	markers.add(marker);
}

/** A Lua double-quoted string literal. */
function luaStr(s) {
	return '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
}

/** An AHK v2 double-quoted string literal (backtick is the escape character). */
function ahkStr(s) {
	return '"' + s.replace(/`/g, '``').replace(/"/g, '`"') + '"';
}

function emitLua() {
	return (
		'--- _shared/core/logger/engine/log_export_data.lua\n' +
		'--- AUTO-GENERATED from _shared/core/logger/data/log_export.toml.\n' +
		'--- DO NOT EDIT BY HAND — run `npm run codegen:log-export` to refresh.\n' +
		'\n' +
		'--- ==============================================================================\n' +
		'--- DATA: Log Export Archive\n' +
		'--- DESCRIPTION:\n' +
		'--- What « Export the logs (zip) » archives and the privacy rules each entry is\n' +
		'--- copied through, read by core/logger/engine/log_export.lua on macOS and Linux.\n' +
		'--- ==============================================================================\n' +
		'\n' +
		'return {\n' +
		`\tdays = ${days},\n` +
		`\tname_prefix = ${luaStr(namePrefix)},\n` +
		`\textension = ${luaStr(extension)},\n` +
		`\tcrash_report_extension = ${luaStr(crashReportExtension)},\n` +
		`\twithheld = ${luaStr(withheld)},\n` +
		'\trules = {\n' +
		rules.map((r) => `\t\t{ marker = ${luaStr(r.marker)}, cut = ${luaStr(r.cut)} },\n`).join('') +
		'\t},\n' +
		'}\n'
	);
}

function emitAhk() {
	return (
		'﻿; _generated/log_export_data.ahk\n' +
		'; AUTO-GENERATED from _shared/core/logger/data/log_export.toml.\n' +
		'; DO NOT EDIT BY HAND — run `npm run codegen:log-export` to refresh.\n' +
		'#Requires AutoHotkey v2.0\n' +
		'\n' +
		'; ==============================================================================\n' +
		'; MODULE: Log Export Archive Data (Windows)\n' +
		'; DESCRIPTION:\n' +
		'; What « Export the logs (zip) » archives and the privacy rules each entry is\n' +
		'; copied through, read by diagnostics/engine/log_export.ahk.\n' +
		';\n' +
		'; A function rather than a global initialiser so include ORDER cannot matter.\n' +
		'; ==============================================================================\n' +
		'\n' +
		'LogExportData() {\n' +
		'\treturn Map(\n' +
		`\t\t"days", ${days},\n` +
		`\t\t"name_prefix", ${ahkStr(namePrefix)},\n` +
		`\t\t"extension", ${ahkStr(extension)},\n` +
		`\t\t"crash_report_extension", ${ahkStr(crashReportExtension)},\n` +
		`\t\t"withheld", ${ahkStr(withheld)},\n` +
		'\t\t"rules", [\n' +
		rules
			.map((r) => `\t\t\tMap("marker", ${ahkStr(r.marker)}, "cut", ${ahkStr(r.cut)}),\n`)
			.join('') +
		'\t\t]\n' +
		'\t)\n' +
		'}\n'
	);
}

const targets = [
	[path.join(SP, '_shared/core/logger/engine/log_export_data.lua'), emitLua()],
	[path.join(SP, 'windows/_generated/log_export_data.ahk'), emitAhk()]
];

for (const [abs, content] of targets) {
	fs.mkdirSync(path.dirname(abs), { recursive: true });
	fs.writeFileSync(abs, content.replace(/\r\n/g, '\n'), 'utf8');
	console.log(`  wrote ${path.relative(ROOT, abs).split(path.sep).join('/')}`);
}

console.log(`[OK] log export data generated: ${days} day(s), ${rules.length} scrub rule(s).`);
