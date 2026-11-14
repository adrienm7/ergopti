// tools/codegen/codegen-value-schema.cjs

/**
 * ==============================================================================
 * MODULE: User Value Schema Codegen
 * DESCRIPTION:
 * Emits the declarations of _shared/settings/data/value_schema/value_schema.json
 * as the data the Windows value check (windows/infra/value_check.ahk) reads and
 * as the Lua table both Lua drivers require (_shared/settings/engine/
 * value_schema_data.lua), so no driver resolves a path to read the schema,
 * and as the classic script the shared WebView pages load (_shared/ui/
 * value_check.js), the canonical check with the schema inlined: the pages are
 * plain scripts, and the macOS host inlines every local <script src>.
 *
 * WHY THIS EXISTS:
 * A compiled AHK build has no JSON reader at include time, so it gets a
 * generated copy instead of a hand-maintained one. The Lua drivers resolve the
 * shared folder differently (and a packaged build has no source tree), so a
 * required module serves them; the web pages import the JSON. The declarations are checked by
 * tools/test/test-value-schema.cjs, which also compares this output with a
 * fresh render.
 *
 * USAGE:  node tools/codegen/codegen-value-schema.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const SOURCE = path.join(SP, '_shared', 'settings', 'data', 'value_schema', 'value_schema.json');
const OUTPUT = path.join(SP, 'windows', '_generated', 'value_schema.ahk');
const LUA_OUTPUT = path.join(SP, '_shared', 'settings', 'engine', 'value_schema_data.lua');
const CHECK_SOURCE = path.join(SP, '_shared', 'settings', 'data', 'value_schema', 'value_check.js');
const BROWSER_OUTPUT = path.join(SP, '_shared', 'ui', 'value_check.js');
const RUN_HINT = 'npm run codegen:value-schema';

// ==========================================
// ==========================================
// ======= 1/ Emitters =====================
// ==========================================
// ==========================================

/** An AHK v2 double-quoted string literal (backtick is the escape character). */
function ahkStr(value) {
	return '"' + String(value).replace(/`/g, '``').replace(/"/g, '`"') + '"';
}

// Declaration fields whose value is a flag, read only for its truth.
const FLAG_FIELDS = ['allow_empty'];

/**
 * One JSON value as an AHK v2 expression: objects become Maps, arrays Arrays.
 * A boolean has no type of its own in AHK, so it is refused: a declaration
 * whose enum holds true or false needs a string spelling first. A flag field
 * (FLAG_FIELDS) is read only for its truth and is spelt 1 or 0.
 * @param {*} value - JSON value.
 * @param {string} where - Path for the error message.
 * @param {number} depth - Indentation depth.
 * @return {string}
 */
function ahkValue(value, where, depth) {
	if (typeof value === 'string') return ahkStr(value);
	if (typeof value === 'number') {
		if (!Number.isFinite(value)) throw new Error(`${where} is not a finite number`);
		return String(value);
	}
	if (typeof value === 'boolean') {
		// A flag field is read for its truth (the port tests allow_empty), so 1
		// and 0 spell it; a boolean anywhere else (an enum value) would be
		// indistinguishable from the numbers 1 and 0 and is refused.
		if (FLAG_FIELDS.includes(where.split('.').pop())) return value ? '1' : '0';
		throw new Error(`${where}: a boolean has no AHK spelling distinct from 1 and 0`);
	}
	if (Array.isArray(value)) {
		return (
			'[' + value.map((item, index) => ahkValue(item, `${where}[${index}]`, depth)).join(', ') + ']'
		);
	}
	if (value && typeof value === 'object') {
		const pad = '\t'.repeat(depth + 1);
		const pairs = Object.entries(value).map(
			([key, item]) => `${pad}${ahkStr(key)}, ${ahkValue(item, `${where}.${key}`, depth + 1)}`
		);
		return 'Map(\n' + pairs.join(',\n') + ')';
	}
	throw new Error(`${where} has no AHK spelling`);
}

/** A Lua string literal. */
function luaStr(value) {
	return JSON.stringify(String(value));
}

/**
 * One JSON value as a Lua expression, keys sorted so the output is stable.
 * @param {*} value - JSON value.
 * @param {string} where - Path for the error message.
 * @param {number} depth - Indentation depth.
 * @return {string}
 */
function luaValue(value, where, depth) {
	if (typeof value === 'string') return luaStr(value);
	if (typeof value === 'boolean') return String(value);
	if (typeof value === 'number') {
		if (!Number.isFinite(value)) throw new Error(`${where} is not a finite number`);
		return String(value);
	}
	const pad = '\t'.repeat(depth + 1);
	const close = '\t'.repeat(depth);
	if (Array.isArray(value)) {
		return (
			'{ ' +
			value.map((item, index) => luaValue(item, `${where}[${index}]`, depth)).join(', ') +
			' }'
		);
	}
	if (value && typeof value === 'object') {
		const pairs = Object.keys(value)
			.sort()
			.map(
				(key) => `${pad}[${luaStr(key)}] = ${luaValue(value[key], `${where}.${key}`, depth + 1)},`
			);
		return '{\n' + pairs.join('\n') + '\n' + close + '}';
	}
	throw new Error(`${where} has no Lua spelling`);
}

/**
 * A constant name for every declared key, so a driver reads the key from the
 * schema instead of typing it: dots become underscores and a `*` segment ANY
 * (tap_hold.keys.*.time_activation_seconds is TAP_HOLD_KEYS_ANY_TIME_ACTIVATION_SECONDS).
 * @param {Object} schema - Decoded value_schema.json.
 * @return {Object} Constant name to key.
 */
function keyConstants(schema) {
	const constants = {};
	for (const key of Object.keys(schema.settings)) {
		const name = key.replace(/\*/g, 'any').replace(/\./g, '_').toUpperCase();
		if (constants[name])
			throw new Error(`${key} and ${constants[name]} share the constant ${name}`);
		constants[name] = key;
	}
	return constants;
}

/**
 * Renders the generated Lua module from the schema on disk.
 * @return {string}
 */
function renderLua() {
	const schema = JSON.parse(fs.readFileSync(SOURCE, 'utf8'));
	return (
		'--- _shared/settings/engine/value_schema_data.lua\n' +
		'--- AUTO-GENERATED from _shared/settings/data/value_schema/value_schema.json.\n' +
		`--- DO NOT EDIT BY HAND — run \`${RUN_HINT}\` to refresh.\n` +
		'---\n' +
		'--- The declaration of every user-entered setting value, as the table\n' +
		'--- settings.engine.value_check reads on macOS and Linux.\n' +
		'\n' +
		`return {\n\t["version"] = ${luaValue(schema.version, 'version', 1)},\n\t["keys"] = ${luaValue(keyConstants(schema), 'keys', 1)},\n\t["settings"] = ${luaValue(schema.settings, 'settings', 1)},\n}\n`
	);
}

/**
 * Renders the browser copy: the canonical check without its ES export, the
 * schema and its key constants inlined, exposed as window.ErgoptiValueCheck.
 * @return {string}
 */
function renderBrowser() {
	const schema = JSON.parse(fs.readFileSync(SOURCE, 'utf8'));
	const source = fs.readFileSync(CHECK_SOURCE, 'utf8');
	const exportAt = source.lastIndexOf('export {');
	if (exportAt < 0) throw new Error('value_check.js lost its export list');
	const names = source
		.slice(exportAt + 'export {'.length, source.indexOf('}', exportAt))
		.split(',')
		.map((name) => name.trim())
		.filter(Boolean);
	const body = source
		.slice(0, exportAt)
		.replace(/^\/\/ _shared\/settings\/data\/value_schema\/value_check\.js\n/, '')
		.replace(/^'use strict';\n/m, '')
		.trim();
	return (
		'// _shared/ui/value_check.js\n' +
		'// AUTO-GENERATED from _shared/settings/data/value_schema/value_check.js and\n' +
		'// value_schema.json. DO NOT EDIT BY HAND — run `' +
		RUN_HINT +
		'` to refresh.\n' +
		'// The shared WebView pages load it as a classic script: window.ErgoptiValueCheck.\n\n' +
		'(function () {\n' +
		"\t'use strict';\n\n" +
		body +
		'\n\n\tconst SCHEMA = ' +
		JSON.stringify(schema, null, '\t').replace(/\n/g, '\n\t') +
		';\n\tconst KEY = ' +
		JSON.stringify(keyConstants(schema), null, '\t').replace(/\n/g, '\n\t') +
		';\n\n\twindow.ErgoptiValueCheck = Object.freeze({ ' +
		names.join(', ') +
		', SCHEMA, KEY });\n})();\n'
	);
}

/**
 * Renders the generated AHK file from the schema on disk.
 * @return {string}
 */
function render() {
	const schema = JSON.parse(fs.readFileSync(SOURCE, 'utf8'));
	const settings = {};
	for (const name of Object.keys(schema.settings).sort()) settings[name] = schema.settings[name];
	return (
		'﻿; _generated/value_schema.ahk\n' +
		'; AUTO-GENERATED from _shared/settings/data/value_schema/value_schema.json.\n' +
		`; DO NOT EDIT BY HAND — run \`${RUN_HINT}\` to refresh.\n` +
		'#Requires AutoHotkey v2.0\n' +
		'\n' +
		'; ==============================================================================\n' +
		'; MODULE: User Value Schema Data (Windows)\n' +
		'; DESCRIPTION:\n' +
		'; The declaration of every user-entered setting value, as the data\n' +
		'; infra/value_check.ahk checks against. A compiled build has no JSON reader\n' +
		'; at include time, and a hand-maintained copy would drift.\n' +
		'; ==============================================================================\n' +
		'\n' +
		'; A function rather than a global initialiser so include ORDER cannot matter;\n' +
		'; the Map is built once and shared by every caller.\n' +
		'ValueSchemaData() {\n' +
		'\tstatic Data := 0\n' +
		'\tif IsObject(Data)\n' +
		'\t\treturn Data\n' +
		`\tData := Map("version", ${ahkValue(schema.version, 'version', 1)}, "settings", ${ahkValue(settings, 'settings', 1)})\n` +
		'\treturn Data\n' +
		'}\n'
	);
}

// ==========================================
// ==========================================
// ======= 2/ Main =========================
// ==========================================
// ==========================================

function main() {
	fs.mkdirSync(path.dirname(OUTPUT), { recursive: true });
	for (const [file, content] of [
		[OUTPUT, render()],
		[LUA_OUTPUT, renderLua()],
		[BROWSER_OUTPUT, renderBrowser()]
	]) {
		fs.writeFileSync(file, content, 'utf8');
		console.log(`  wrote ${path.relative(ROOT, file).split(path.sep).join('/')}`);
	}
}

if (require.main === module) main();

module.exports = { render, renderLua, renderBrowser, OUTPUT, LUA_OUTPUT, BROWSER_OUTPUT };
