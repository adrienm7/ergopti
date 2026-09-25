// tools/test/test-updater-copy-is-shown.cjs

/**
 * ==============================================================================
 * MODULE: Updater Copy Is Shown
 * DESCRIPTION:
 * Every updater string in the shared catalogue must be read by a driver. The
 * translation audit only proves that keys the code reads exist; nothing
 * proved the reverse, and a string no driver shows still looks like the
 * right one to reuse.
 *
 * ROOT CAUSE ENCODED:
 * The macOS update adapter reported a refused check with
 * menu.about.update.install_error ("The update installation failed"), taken
 * from a family of eight menu.about.update.* strings that no driver had shown
 * since the update flows were rewritten. Five more (menu.about.install_update,
 * updater.new_version and three updater.changelog_* strings) were in the same
 * state. This guard fails on any updater, About-menu or Updates-menu key that
 * no driver source reads.
 *
 * A read counts only in code: comments are stripped first, since a comment
 * naming a key shows nothing. A key read through a quoted prefix joined to a
 * runtime suffix ("menu.about.frequency." . Preset.Code) counts only when the
 * prefix is the key minus its last segment and that segment is a string
 * literal in the same driver, the value the suffix takes. A bare
 * "menu.about." .. x would otherwise clear every key below it.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..', '..');
const driversRoot = path.join(root, 'static', 'ergopti_plus');
const en = JSON.parse(fs.readFileSync(path.join(driversRoot, '_shared', 'data', 'locales', 'en.json'), 'utf8'));
const FAMILY = /^(?:updater|menu\.about|menu\.updates)\./;
const SKIPPED_DIRS = new Set(['tests', 'Tests', 'locales', '.build', 'node_modules']);
const errors = [];

// Comment and string syntax of each source language the drivers use. AHK
// starts a line comment only at a line start or after whitespace, and a block
// comment only as the first thing on its line.
const C_LIKE = { line: ['//'], block: [['/*', '*/']], quotes: ['"', "'", '`'], escape: '\\' };
const SYNTAX_BY_EXTENSION = {
	'.lua': { line: ['--'], block: [], quotes: ['"', "'"], escape: '\\', luaLongComments: true },
	'.ahk': { line: [';'], block: [['/*', '*/']], quotes: ['"', "'"], escape: '`', ahk: true },
	'.swift': C_LIKE,
	'.js': C_LIKE,
	'.cjs': C_LIKE,
	'.html': { ...C_LIKE, block: [['/*', '*/'], ['<!--', '-->']] },
	'.json': { line: [], block: [], quotes: ['"'], escape: '\\' },
};

/**
 * Returns a source with its comments removed and its strings kept.
 * @param {string} source File text.
 * @param {object} syntax Entry of SYNTAX_BY_EXTENSION.
 * @returns {string} Code without comments; newlines are kept.
 */
function stripComments(source, syntax) {
	let out = '';
	let quote = null;
	let lineStart = true;
	let i = 0;
	while (i < source.length) {
		const ch = source[i];
		if (quote !== null) {
			out += ch;
			if (ch === syntax.escape && i + 1 < source.length) {
				out += source[i + 1];
				i += 2;
				continue;
			}
			if (ch === quote || (ch === '\n' && quote !== '`')) quote = null;
			i += 1;
			continue;
		}
		if (syntax.luaLongComments && source.startsWith('--[', i)) {
			const open = /^--\[(=*)\[/.exec(source.slice(i, i + 64));
			if (open) {
				const close = source.indexOf(`]${open[1]}]`, i + open[0].length);
				i = close < 0 ? source.length : close + open[1].length + 2;
				continue;
			}
		}
		const block = syntax.block.find(([opening]) => source.startsWith(opening, i)
			&& (!syntax.ahk || lineStart));
		if (block) {
			const close = source.indexOf(block[1], i + block[0].length);
			const skipped = source.slice(i, close < 0 ? source.length : close + block[1].length);
			out += skipped.replace(/[^\n]/g, '');
			i += skipped.length;
			continue;
		}
		const line = syntax.line.find((opening) => source.startsWith(opening, i)
			&& (!syntax.ahk || lineStart || /\s/.test(source[i - 1])));
		if (line) {
			const end = source.indexOf('\n', i);
			i = end < 0 ? source.length : end;
			continue;
		}
		if (syntax.quotes.includes(ch)) quote = ch;
		if (ch === '\n') lineStart = true;
		else if (!/\s/.test(ch)) lineStart = false;
		out += ch;
		i += 1;
	}
	return out;
}

/**
 * Collects every driver source outside tests and the catalogue itself.
 * @param {string} dir Directory to scan.
 * @param {{driver: string, code: string}[]} out Accumulated sources.
 * @returns {{driver: string, code: string}[]} Comment-free sources, each with its driver.
 */
function driverSources(dir, out = []) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		const syntax = SYNTAX_BY_EXTENSION[path.extname(entry.name)];
		if (entry.isDirectory()) {
			if (!SKIPPED_DIRS.has(entry.name)) driverSources(full, out);
		} else if (syntax) {
			const driver = path.relative(driversRoot, full).split(path.sep)[0];
			out.push({ driver, code: stripComments(fs.readFileSync(full, 'utf8'), syntax) });
		}
	}
	return out;
}

const escape = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const quoted = (code, value) => code.includes(`"${value}"`) || code.includes(`'${value}'`);

/**
 * Whether a driver reads the key: literally, or as its quoted parent prefix
 * joined to a runtime suffix ("x.y." . Code in AHK, .. in Lua, + in JS) whose
 * value, the key's last segment, is a string literal of that driver.
 * @param {string} key Catalogue key.
 * @param {{driver: string, code: string}[]} sources Comment-free sources.
 * @returns {boolean} True when some driver source reads it.
 */
function isRead(key, sources) {
	if (sources.some(({ code }) => quoted(code, key))) return true;
	const segments = key.split('.');
	if (segments.length < 3) return false;
	const prefix = `${segments.slice(0, -1).join('.')}.`;
	const suffix = segments[segments.length - 1];
	const composed = new RegExp(`["']${escape(prefix)}["']\\s*(?:\\.\\.?|\\+)`);
	return sources.some(({ driver, code }) => composed.test(code)
		&& sources.some((other) => other.driver === driver && quoted(other.code, suffix)));
}

// The guard itself: a key named only in a comment, or below a prefix that
// composes other keys, must not count as read.
const lua = SYNTAX_BY_EXTENSION['.lua'];
const ahk = SYNTAX_BY_EXTENSION['.ahk'];
const js = SYNTAX_BY_EXTENSION['.js'];
const SELF_TEST = [
	{ key: 'updater.gone', read: false, sources: [{ driver: 'macos', code: stripComments('-- t("updater.gone")\nlocal a = 1', lua) }] },
	{ key: 'updater.gone', read: false, sources: [{ driver: 'macos', code: stripComments('--[[ "updater.gone" ]] x()', lua) }] },
	{ key: 'updater.gone', read: false, sources: [{ driver: 'windows', code: stripComments('x := 1 ; t("updater.gone")', ahk) }] },
	{ key: 'updater.gone', read: false, sources: [{ driver: 'windows', code: stripComments('/*\nt("updater.gone")\n*/', ahk) }] },
	{ key: 'updater.gone', read: false, sources: [{ driver: 'linux', code: stripComments('f(); // "updater.gone"', js) }] },
	{ key: 'updater.kept', read: true, sources: [{ driver: 'windows', code: stripComments('t("updater.kept") ; note', ahk) }] },
	{ key: 'updater.kept', read: true, sources: [{ driver: 'macos', code: stripComments('get("updater.kept") -- note', lua) }] },
	{ key: 'updater.kept', read: true, sources: [{ driver: 'windows', code: stripComments('s := "a;b" . t("updater.kept")', ahk) }] },
	{
		key: 'menu.about.update.install_error',
		read: false,
		sources: [{ driver: 'macos', code: stripComments('get("menu.about." .. name) local n = "install_error"', lua) }],
	},
	{
		key: 'menu.about.frequency.12h',
		read: true,
		sources: [
			{ driver: 'windows', code: stripComments('t("menu.about.frequency." . Preset.Code)', ahk) },
			{ driver: 'windows', code: stripComments('P := [{ Code: "12h" }]', ahk) },
		],
	},
	{
		key: 'menu.about.frequency.12h',
		read: false,
		sources: [
			{ driver: 'windows', code: stripComments('t("menu.about.frequency." . Preset.Code)', ahk) },
			{ driver: 'linux', code: stripComments('local p = { code = "12h" }', lua) },
		],
	},
];
for (const { key, read, sources } of SELF_TEST) {
	if (isRead(key, sources) !== read) {
		errors.push(`guard self-test: ${key} must count as ${read ? 'read' : 'unread'} in ${JSON.stringify(sources)}`);
	}
}

const sources = driverSources(driversRoot);
const family = Object.keys(en).filter((key) => FAMILY.test(key));
// Floor: a family pattern that stopped matching would pass over nothing.
if (family.length < 40) errors.push(`expected the updater catalogue family, found only ${family.length} key(s)`);
for (const key of family) {
	if (!isRead(key, sources)) {
		errors.push(`${key} is in the catalogue but no driver shows it: remove it from all 21 locales`);
	}
}

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}

console.log(`[OK] all ${family.length} updater, About-menu and Updates-menu strings are shown by a driver.`);
