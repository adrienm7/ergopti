// tools/codegen/codegen-config-keys.cjs

/**
 * ==============================================================================
 * MODULE: Config-Key and Menu-Command Constants Codegen
 * DESCRIPTION:
 * Emits one constant per configuration key and per menu command id, for the
 * Lua drivers (macOS and Linux share `_shared/lua/config_keys.lua`), the shared
 * web UI (`_shared/ui/_generated/config_keys.js`) and the AutoHotkey driver
 * (`windows/_generated/config_keys.ahk`).
 *
 * WHY THIS EXISTS:
 * The cross-OS parity audit counted `private_filter_enabled` in five Windows,
 * three macOS, four Linux and three shared files, and `time_activation_seconds`
 * in eighteen Windows files, every one a hand-typed string. A misspelt key is
 * not an error anywhere: a TOML lookup of a key that does not exist answers
 * nil, the default applies, and the user's setting is silently ignored. A
 * generated constant turns that typo into an immediate failure, because every
 * emitted table refuses an unknown name (a Lua metatable, a JS Proxy, an AHK
 * class whose missing static property throws).
 *
 * SOURCES, BOTH READ AS DATA:
 * 1. `_shared/core/config_schema/config.schema.json`: every property path,
 *    sections included, with `$ref` resolved.
 * 2. `_shared/modules/menu/menu_manifest.json`: the `path` of every row that
 *    names a configuration leaf (some are not yet declared in the schema), and
 *    the `id` of every dispatchable row (command, check, toggle, choice).
 *
 * Three tables come out of them: KEY (the dotted path), LEAF (the last segment,
 * for code that already scoped itself to a section) and COMMAND (menu ids).
 * A constant name is its value upper-cased with dots folded to underscores; two
 * values that fold to one name are a hard error rather than a silent overwrite.
 *
 * USAGE:  node tools/codegen/codegen-config-keys.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const SCHEMA = 'static/ergopti_plus/_shared/core/config_schema/config.schema.json';
const MENU_MANIFEST = 'static/ergopti_plus/_shared/modules/menu/menu_manifest.json';
const LUA_OUTPUT = 'static/ergopti_plus/_shared/lua/config_keys.lua';
const JS_OUTPUT = 'static/ergopti_plus/_shared/ui/_generated/config_keys.js';
const AHK_OUTPUT = 'static/ergopti_plus/windows/_generated/config_keys.ahk';

// The menu row types a dispatcher routes by id. Groups, labels, separators and
// provider lists carry ids too, but nothing dispatches on them.
const DISPATCHABLE_ROW_TYPES = new Set(['command', 'check', 'toggle', 'choice']);

const IDENTIFIER = /^[a-z_][a-z0-9_]*$/;

// ==========================================
// ==========================================
// ======= 1/ Collection ====================
// ==========================================
// ==========================================

/**
 * Every property path declared by the configuration schema.
 * @param {object} schema The parsed config.schema.json.
 * @returns {string[]} Dotted paths, sections included.
 */
function schemaPaths(schema) {
	const defs = schema.$defs || {};
	const resolve = (node) => {
		const seen = new Set();
		while (node && typeof node === 'object' && typeof node.$ref === 'string') {
			if (seen.has(node.$ref)) throw new Error(`config.schema.json: $ref cycle at ${node.$ref}`);
			seen.add(node.$ref);
			const name = node.$ref.replace(/^#\/\$defs\//, '');
			if (!(name in defs)) throw new Error(`config.schema.json: unresolved $ref ${node.$ref}`);
			node = defs[name];
		}
		return node;
	};
	const out = [];
	const walk = (node, segments) => {
		const resolved = resolve(node);
		if (segments.length > 0) out.push(segments.join('.'));
		if (resolved && typeof resolved === 'object' && resolved.properties) {
			for (const name of Object.keys(resolved.properties))
				walk(resolved.properties[name], [...segments, name]);
		}
	};
	walk(schema, []);
	return out;
}

/**
 * Configuration paths and dispatchable command ids named by the menu manifest.
 * @param {object} manifest The parsed menu_manifest.json.
 * @returns {{paths: string[], commands: string[]}}
 */
function manifestNames(manifest) {
	const paths = [];
	const commands = [];
	const walk = (node) => {
		if (Array.isArray(node)) return node.forEach(walk);
		if (!node || typeof node !== 'object') return;
		if (typeof node.path === 'string') paths.push(node.path);
		if (typeof node.id === 'string' && DISPATCHABLE_ROW_TYPES.has(node.type))
			commands.push(node.id);
		for (const [key, value] of Object.entries(node)) if (!key.startsWith('_')) walk(value);
	};
	walk(manifest);
	return { paths, commands };
}

/**
 * Upper-cases a value into a constant name.
 * @param {string} value A dotted key, a leaf or a command id.
 * @returns {string}
 */
function constantName(value) {
	return value.replace(/\./g, '_').toUpperCase();
}

/**
 * Builds one name-to-value table, refusing malformed values and name clashes.
 * @param {string} label The table name, for error messages.
 * @param {Iterable<string>} values The values to name.
 * @returns {Array<[string, string]>} Sorted [name, value] pairs.
 */
function table(label, values) {
	const byName = new Map();
	for (const value of new Set(values)) {
		if (!value.split('.').every((segment) => IDENTIFIER.test(segment)))
			throw new Error(`${label}: "${value}" is not a dotted lower-case identifier`);
		const name = constantName(value);
		if (byName.has(name) && byName.get(name) !== value)
			throw new Error(`${label}: "${byName.get(name)}" and "${value}" both fold to ${name}`);
		byName.set(name, value);
	}
	return [...byName.entries()].sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
}

/**
 * Reads both sources and returns the three constant tables.
 * @param {string} [root] Repository root (a test passes a private copy).
 * @returns {{KEY: Array<[string,string]>, LEAF: Array<[string,string]>, COMMAND: Array<[string,string]>}}
 */
function collect(root = REPO_ROOT) {
	const schema = JSON.parse(fs.readFileSync(path.join(root, SCHEMA), 'utf8'));
	const manifest = JSON.parse(fs.readFileSync(path.join(root, MENU_MANIFEST), 'utf8'));
	const fromManifest = manifestNames(manifest);
	const keys = [...schemaPaths(schema), ...fromManifest.paths];
	if (keys.length === 0) throw new Error('no configuration key found in either source');
	if (fromManifest.commands.length === 0) throw new Error('menu_manifest.json names no command id');
	return {
		KEY: table('KEY', keys),
		LEAF: table(
			'LEAF',
			keys.map((key) => key.split('.').pop())
		),
		COMMAND: table('COMMAND', fromManifest.commands)
	};
}

// ==========================================
// ==========================================
// ======= 2/ Emitters ======================
// ==========================================
// ==========================================

const BANNER_WHY = [
	'One constant per configuration key, leaf and menu command id. A misspelt',
	'string key reads as nil and the default silently applies; a misspelt',
	'constant fails at the first access, because every table below refuses a',
	'name it does not hold.'
];

const TABLE_NAMES = ['KEY', 'LEAF', 'COMMAND'];

/** A double-quoted literal; every value is a validated identifier path. */
const quoted = (value) => `"${value}"`;

/**
 * The shared Lua module, read by the macOS and Linux drivers.
 * @param {ReturnType<typeof collect>} tables
 * @returns {string}
 */
function emitLua(tables) {
	const body = TABLE_NAMES.map(
		(name) =>
			`M.${name} = strict("${name}", {\n` +
			tables[name].map(([k, v]) => `\t${k} = ${quoted(v)},`).join('\n') +
			'\n})'
	).join('\n\n');
	return (
		'--- _shared/lua/config_keys.lua\n' +
		'--- AUTO-GENERATED from _shared/core/config_schema/config.schema.json and\n' +
		'--- _shared/modules/menu/menu_manifest.json.\n' +
		'--- DO NOT EDIT BY HAND — run `npm run codegen:config-keys` to refresh.\n' +
		'\n' +
		'--- ==============================================================================\n' +
		'--- MODULE: Config-Key and Menu-Command Constants\n' +
		'--- DESCRIPTION:\n' +
		BANNER_WHY.map((line) => '--- ' + line).join('\n') +
		'\n' +
		'--- ==============================================================================\n' +
		'\n' +
		'local M = {}\n' +
		'\n' +
		'--- Seals one table so an unknown name raises instead of answering nil.\n' +
		'--- @param label string The table name, quoted in the error.\n' +
		'--- @param values table The constants.\n' +
		'--- @return table values, sealed.\n' +
		'local function strict(label, values)\n' +
		'\treturn setmetatable(values, {\n' +
		'\t\t__index = function(_, name)\n' +
		'\t\t\terror("config_keys." .. label .. " has no constant " .. tostring(name), 2)\n' +
		'\t\tend,\n' +
		'\t\t__newindex = function(_, name)\n' +
		'\t\t\terror("config_keys." .. label .. " is read-only (" .. tostring(name) .. ")", 2)\n' +
		'\t\tend,\n' +
		'\t})\n' +
		'end\n' +
		'\n' +
		body +
		'\n\nreturn M\n'
	);
}

/**
 * The shared web UI script; also loadable from Node through module.exports.
 * @param {ReturnType<typeof collect>} tables
 * @returns {string}
 */
function emitJs(tables) {
	const body = TABLE_NAMES.map(
		(name) =>
			`\t\t${name}: strict('${name}', {\n` +
			tables[name].map(([k, v]) => `\t\t\t${k}: ${quoted(v)},`).join('\n') +
			'\n\t\t})'
	).join(',\n');
	return (
		'// _shared/ui/_generated/config_keys.js\n' +
		'\n' +
		'// ==========================================\n' +
		'// AUTO-GENERATED — do not edit manually\n' +
		`// Sources: ${SCHEMA}\n` +
		`//          ${MENU_MANIFEST}\n` +
		'// Run: npm run codegen:config-keys\n' +
		'// ==========================================\n' +
		'\n' +
		BANNER_WHY.map((line) => '// ' + line).join('\n') +
		'\n' +
		'(function (global) {\n' +
		"\t'use strict';\n" +
		'\n' +
		'\tfunction strict(label, values) {\n' +
		'\t\treturn new Proxy(Object.freeze(values), {\n' +
		'\t\t\tget: function (target, name) {\n' +
		"\t\t\t\tif (typeof name === 'symbol' || Object.prototype.hasOwnProperty.call(target, name))\n" +
		'\t\t\t\t\treturn target[name];\n' +
		"\t\t\t\tthrow new Error('ERGOPTI_CONFIG_KEYS.' + label + ' has no constant ' + String(name));\n" +
		'\t\t\t}\n' +
		'\t\t});\n' +
		'\t}\n' +
		'\n' +
		'\tvar tables = Object.freeze({\n' +
		body +
		'\n\t});\n' +
		'\n' +
		'\tglobal.ERGOPTI_CONFIG_KEYS = tables;\n' +
		"\tif (typeof module !== 'undefined' && module.exports) module.exports = tables;\n" +
		"})(typeof window !== 'undefined' ? window : globalThis);\n"
	);
}

/**
 * The AutoHotkey classes; a missing static property throws a PropertyError.
 * @param {ReturnType<typeof collect>} tables
 * @returns {string}
 */
function emitAhk(tables) {
	const classes = { KEY: 'ConfigKey', LEAF: 'ConfigLeaf', COMMAND: 'MenuCommand' };
	const body = TABLE_NAMES.map(
		(name) =>
			`class ${classes[name]} {\n` +
			tables[name].map(([k, v]) => `\tstatic ${k} := ${quoted(v)}`).join('\n') +
			'\n}'
	).join('\n\n');
	return (
		'﻿; _generated/config_keys.ahk\n' +
		'; AUTO-GENERATED from _shared/core/config_schema/config.schema.json and\n' +
		'; _shared/modules/menu/menu_manifest.json.\n' +
		'; DO NOT EDIT BY HAND — run `npm run codegen:config-keys` to refresh.\n' +
		'#Requires AutoHotkey v2.0\n' +
		'\n' +
		'; ==============================================================================\n' +
		'; MODULE: Config-Key and Menu-Command Constants\n' +
		'; DESCRIPTION:\n' +
		BANNER_WHY.map((line) => '; ' + line).join('\n') +
		'\n' +
		'; ==============================================================================\n' +
		'\n' +
		body +
		'\n'
	);
}

// ==========================================
// ==========================================
// ======= 3/ Write =========================
// ==========================================
// ==========================================

/**
 * Regenerates the three outputs under `root`.
 * @param {string} [root] Repository root.
 * @returns {ReturnType<typeof collect>} The tables written.
 */
function main(root = REPO_ROOT) {
	const tables = collect(root);
	const targets = [
		[LUA_OUTPUT, emitLua(tables)],
		[JS_OUTPUT, emitJs(tables)],
		[AHK_OUTPUT, emitAhk(tables)]
	];
	for (const [rel, content] of targets) {
		const abs = path.join(root, rel);
		fs.mkdirSync(path.dirname(abs), { recursive: true });
		fs.writeFileSync(abs, content, 'utf8');
	}
	return tables;
}

if (require.main === module) {
	const tables = main();
	console.log(
		`[OK] config-key constants generated: ${tables.KEY.length} key(s), ${tables.LEAF.length} leaf ` +
			`name(s), ${tables.COMMAND.length} command id(s).`
	);
}

module.exports = {
	SCHEMA,
	MENU_MANIFEST,
	LUA_OUTPUT,
	JS_OUTPUT,
	AHK_OUTPUT,
	collect,
	constantName,
	table,
	emitLua,
	emitJs,
	emitAhk,
	main
};
