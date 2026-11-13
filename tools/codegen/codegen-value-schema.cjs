// tools/codegen/codegen-value-schema.cjs

/**
 * ==============================================================================
 * MODULE: User Value Schema Codegen
 * DESCRIPTION:
 * Emits the declarations of _shared/settings/data/value_schema/value_schema.json
 * as the data the Windows value check (windows/infra/value_check.ahk) reads.
 *
 * WHY THIS EXISTS:
 * A compiled AHK build has no JSON reader at include time, so it gets a
 * generated copy instead of a hand-maintained one; macOS and Linux decode the
 * JSON at runtime and the web pages import it. The declarations are checked by
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

/**
 * One JSON value as an AHK v2 expression: objects become Maps, arrays Arrays.
 * A boolean has no type of its own in AHK, so it is refused: a declaration
 * whose enum holds true or false needs a string spelling first.
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
	fs.writeFileSync(OUTPUT, render(), 'utf8');
	console.log(`  wrote ${path.relative(ROOT, OUTPUT).split(path.sep).join('/')}`);
}

if (require.main === module) main();

module.exports = { render, OUTPUT };
