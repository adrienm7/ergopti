// tools/codegen/codegen-logger-sub-files.cjs

/**
 * ==============================================================================
 * MODULE: Logger Sub-file Routing Codegen
 * DESCRIPTION:
 * Emits the logger's sub-file routing table for each driver from the canonical
 * _shared/modules/logger/sub_files.toml.
 *
 * WHY THIS EXISTS:
 * Both drivers hand-rolled a TOML [[array_of_tables]] parser for this one file —
 * 120 lines of Lua and 112 of AutoHotkey — because array-of-tables is outside
 * the scope of their shared TOML readers. Two parsers of the same grammar means
 * every bug in that grammar has to be found and fixed twice, and both carried
 * the same one: a `]` INSIDE a quoted pattern closed the array early. The file's
 * own authoring guidance is "prefer tag-based patterns (e.g. \"[gestures\")", so
 * bracket-bearing patterns are the documented norm, not an edge case — every
 * pattern after such a line was silently dropped and its sub-file simply never
 * received those log lines.
 *
 * Each parser also carried a hardcoded fallback list for when the shared file is
 * unreachable, which is a second copy of the data, free to drift. It had:
 * the macOS fallback routed `gestures` on one pattern where the canonical file
 * has two ("[gestures" and "gesture"), so a stripped build silently lost every
 * bare `gesture` line.
 *
 * Generating the table removes the grammar from the drivers entirely. There is
 * no parser to get wrong twice and no fallback to drift, because the generated
 * file is committed and always present — the same convention terminators.ahk
 * already follows.
 *
 * USAGE:  node tools/codegen/codegen-logger-sub-files.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const SOURCE = path.join(SP, '_shared/modules/logger/sub_files.toml');

const parsed = toml.parse(fs.readFileSync(SOURCE, 'utf8'));
const entries = parsed.sub_files || [];

if (entries.length === 0) {
	console.error('[ERROR] sub_files.toml declares no [[sub_files]] entries.');
	process.exit(1);
}

for (const e of entries) {
	if (typeof e.name !== 'string' || !Array.isArray(e.patterns) || !Array.isArray(e.platforms)) {
		console.error(`[ERROR] malformed entry ${JSON.stringify(e.name)}: name, patterns and platforms are required.`);
		process.exit(1);
	}
	if (e.patterns.length === 0) {
		console.error(`[ERROR] entry "${e.name}" has no patterns — it would create a log file nothing routes to.`);
		process.exit(1);
	}
}

/** Entries a given driver writes, in declaration order. */
const forPlatform = (p) => entries.filter((e) => e.platforms.includes(p));

/** A Lua double-quoted string literal. */
function luaStr(s) {
	return '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
}

/** An AHK v2 double-quoted string literal (backtick is the escape character). */
function ahkStr(s) {
	return '"' + s.replace(/`/g, '``').replace(/"/g, '`"') + '"';
}

/** A Swift double-quoted string literal. */
function swiftStr(s) {
	return '"' + s.replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
}

const BANNER_WHY =
	'Both drivers used to parse the TOML themselves — two hand-rolled\n' +
	'array-of-tables parsers, each of which had to have the same bug fixed\n' +
	'separately (a "]" inside a quoted pattern closed the array early), plus a\n' +
	'hardcoded fallback list that had already drifted from the source.';

// ── macOS ───────────────────────────────────────────────────────────────────

function emitLua() {
	const rows = forPlatform('hs').map((e) => {
		const pats = e.patterns.map(luaStr).join(', ');
		return (
			`\t-- ${e.description || e.name}\n` +
			`\t{ name = "ErgoptiPlus_${e.name}.log", patterns = { ${pats} } },`
		);
	});

	return (
		'--- _generated/logger_sub_files.lua\n' +
		'--- AUTO-GENERATED from _shared/modules/logger/sub_files.toml.\n' +
		'--- DO NOT EDIT BY HAND — run `npm run codegen:logger-sub-files` to refresh.\n' +
		'\n' +
		'--- ==============================================================================\n' +
		'--- MODULE: Logger Sub-file Routing Table (macOS)\n' +
		'--- DESCRIPTION:\n' +
		'--- The [[sub_files]] entries whose platforms list includes "hs", as the table\n' +
		'--- infra/logger.lua fans log lines out with. A line is routed to a sub-file when\n' +
		'--- ANY of its patterns is a substring of the complete line; it is always also\n' +
		'--- written to the main daily log.\n' +
		'---\n' +
		BANNER_WHY.split('\n')
			.map((l) => '--- ' + l)
			.join('\n') +
		'\n' +
		'--- ==============================================================================\n' +
		'\n' +
		'return {\n' +
		rows.join('\n') +
		'\n}\n'
	);
}

// ── Windows ─────────────────────────────────────────────────────────────────

function emitAhk() {
	const rows = forPlatform('ahk').map((e) => {
		const pats = e.patterns.map(ahkStr).join(', ');
		return (
			`\t\t; ${e.description || e.name}\n` +
			`\t\tMap("name", "ErgoptiPlus_${e.name}.log", "tags", [${pats}]),`
		);
	});

	return (
		'﻿; _generated/logger_sub_files.ahk\n' +
		'; AUTO-GENERATED from _shared/modules/logger/sub_files.toml.\n' +
		'; DO NOT EDIT BY HAND — run `npm run codegen:logger-sub-files` to refresh.\n' +
		'#Requires AutoHotkey v2.0\n' +
		'\n' +
		'; ==============================================================================\n' +
		'; MODULE: Logger Sub-file Routing Table (Windows)\n' +
		'; DESCRIPTION:\n' +
		'; The [[sub_files]] entries whose platforms list includes "ahk", as the array\n' +
		'; infra/logger.ahk fans log lines out with. A line is routed to a sub-file when\n' +
		'; ANY of its tags is a substring of the complete line; it is always also\n' +
		'; written to the main daily log.\n' +
		';\n' +
		BANNER_WHY.split('\n')
			.map((l) => '; ' + l)
			.join('\n') +
		'\n' +
		'; ==============================================================================\n' +
		'\n' +
		'; A function rather than a global initialiser so include ORDER cannot matter:\n' +
		'; the logger calls this when it initialises, long after every #Include has been\n' +
		'; processed. A global would have to be declared before infra/logger.ahk to be\n' +
		'; visible, which is a constraint the generated file has no way to enforce.\n' +
		'LoggerSubFilesData() {\n' +
		'\treturn [\n' +
		rows.join('\n') +
		'\n\t]\n' +
		'}\n'
	);
}

// -- Native macOS launcher -----------------------------------------------------

function emitSwift() {
	const rows = forPlatform('hs').map((e) =>
		`\t${swiftStr(`ErgoptiPlus_${e.name}.log`)},`
	);

	return (
		'// Sources/ErgoptiPlus/LoggerTopics.generated.swift\n' +
		'// AUTO-GENERATED from _shared/modules/logger/sub_files.toml.\n' +
		'// DO NOT EDIT BY HAND -- run `npm run codegen:logger-sub-files` to refresh.\n' +
		'\n' +
		'// ==============================================================================\n' +
		'// MODULE: Native Logger Topical Filename Set\n' +
		'// DESCRIPTION:\n' +
		'// Restricts authenticated logger datagrams to the same canonical filenames\n' +
		'// routed by the Hammerspoon logger. Generating this set prevents the native\n' +
		'// validator from becoming a second source that can reject a newly added topic.\n' +
		'// ==============================================================================\n' +
		'\n' +
		'let kLoggerTopicalFileNames: Set<String> = [\n' +
		rows.join('\n') +
		'\n]\n'
	);
}

// ── Write ───────────────────────────────────────────────────────────────────

const targets = [
	[path.join(SP, 'macos/_generated/logger_sub_files.lua'), emitLua()],
	[path.join(SP, 'windows/_generated/logger_sub_files.ahk'), emitAhk()],
	[
		path.join(SP, 'macos/launcher/Sources/ErgoptiPlus/LoggerTopics.generated.swift'),
		emitSwift()
	]
];

for (const [abs, content] of targets) {
	fs.mkdirSync(path.dirname(abs), { recursive: true });
	// LF everywhere, per the repo's source-encoding rule; the AHK payload already
	// carries its required UTF-8 BOM as the first character.
	fs.writeFileSync(abs, content.replace(/\r\n/g, '\n'), 'utf8');
	console.log(`  wrote ${path.relative(ROOT, abs).split(path.sep).join('/')}`);
}

console.log(
	`[OK] logger sub-file routing generated: ${forPlatform('hs').length} macOS entr(ies), ` +
		`${forPlatform('ahk').length} Windows entr(ies), from ${entries.length} declaration(s).`
);
