// tools/test/test-shared-pages-never-show-raw-keys.cjs

/**
 * ==============================================================================
 * MODULE: Shared Pages Never Show a Raw Locale Key
 * DESCRIPTION:
 * A shared webview page shows a raw key when the key is missing from the
 * catalogue, or when the catalogue never reaches the page. This gate covers
 * both halves for every page under _shared/ui:
 * 1. every key a page names literally (data-i18n, data-i18n-title,
 *    data-i18n-placeholder, each option of a data-i18n-option-prefix select,
 *    and every whole quoted key in the first argument of its _t(), t() and
 *    _fmt() translators, both branches of a ternary included) exists in
 *    en.json, the canonical catalogue;
 * 2. every page that loads i18n.js gets its catalogue whatever its own fetch
 *    does: the macOS and Linux page builders seed window._i18n_strings in the
 *    boot script they prepend, and the macOS app payload ships the page, the
 *    loader, the seed module, the locale core and all 21 locale files.
 *
 * WHY THE DELIVERY HALF EXISTS:
 * The diagnostics page on macOS showed every section title as its key. Every
 * key existed in all 21 locales; the page lost the host's strings to its own
 * refused file:// fetch. A key check alone passes on exactly that bug.
 *
 * Keys built at run time from data (the diagnostics schema's section, field
 * and state labels) are covered by test-healthcheck-model.cjs.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const STATIC = path.join(ROOT, 'static', 'ergopti_plus');
const SHARED = path.join(STATIC, '_shared');
const UI = path.join(SHARED, 'ui');
const LOCALES = path.join(SHARED, 'data', 'locales');
const en = JSON.parse(fs.readFileSync(path.join(LOCALES, 'en.json'), 'utf8'));

const failures = [];
const fail = (message) => failures.push(message);

// A dotted locale key, as the catalogue spells them
const KEY = /^[a-z0-9_]+(?:\.[a-z0-9_-]+)+$/;
const ATTRIBUTE = /\bdata-i18n(?:-title|-placeholder)?="([^"]+)"/g;
// A translator call; its first argument is the key it looks up
const TRANSLATOR_CALL = /(?<![\w.$])(?:_t|t|_fmt)\(/g;
// A first argument longer than this is a scan that lost its way, not a key
const ARGUMENT_MAX_LENGTH = 400;
// A select, whose options i18n.js may label from data-i18n-option-prefix
const OPTION_SELECT = /<select\b([^>]*)>([\s\S]*?)<\/select>/g;

// ===================================
// ===================================
// ======= 1/ Keys Exist in en =======
// ===================================
// ===================================

/** The shared pages: every directory under _shared/ui with an index.html. */
function pages() {
	return fs
		.readdirSync(UI, { withFileTypes: true })
		.filter((entry) => entry.isDirectory())
		.map((entry) => entry.name)
		.filter((name) => fs.existsSync(path.join(UI, name, 'index.html')));
}

/** The page's own scripts, as its index.html loads them, plus the page's directory. */
function pageScripts(page) {
	const dir = path.join(UI, page);
	const html = fs.readFileSync(path.join(dir, 'index.html'), 'utf8');
	const files = new Set();
	for (const match of html.matchAll(/<script[^>]*\bsrc="([^"?#]+)[^"]*"/g)) {
		if (/^https?:/.test(match[1])) continue;
		files.add(path.resolve(dir, match[1]));
	}
	for (const entry of fs.readdirSync(dir)) {
		if (entry.endsWith('.js')) files.add(path.join(dir, entry));
	}
	return { html, files: [...files].filter((file) => fs.existsSync(file)) };
}

/** Removes comments so a key named in prose is not taken for a lookup. */
function stripComments(source) {
	return source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:'"\\])\/\/.*$/gm, '$1');
}

/**
 * The source of a call's first argument: from `start`, just after the "(",
 * to the first top-level "," or the ")" that closes the call.
 * @param {string} source
 * @param {number} start
 * @returns {string|null} null when the argument does not end within the bound.
 */
function firstArgument(source, start) {
	const end = Math.min(source.length, start + ARGUMENT_MAX_LENGTH);
	let depth = 0;
	for (let i = start; i < end; i++) {
		const c = source[i];
		if (c === "'" || c === '"' || c === '`') {
			for (i++; i < end && source[i] !== c; i++) if (source[i] === '\\') i++;
			continue;
		}
		if ('([{'.includes(c)) depth++;
		else if (')]}'.includes(c)) {
			if (depth === 0) return source.slice(start, i);
			depth--;
		} else if (c === ',' && depth === 0) return source.slice(start, i);
	}
	return null;
}

/**
 * The keys a script's translator calls can look up: every whole quoted key in
 * a call's first argument, so both branches of `t(a ? 'x.y' : 'x.z')` and the
 * fallback of `t(map[id] || 'x.y')` count. A literal joined with "+" is only
 * part of a key built at run time and is left out.
 * @param {string} source Script source without comments.
 * @param {string} where File name for the failure message.
 * @returns {Set<string>}
 */
function translatorKeys(source, where = 'fixture') {
	const keys = new Set();
	for (const call of source.matchAll(TRANSLATOR_CALL)) {
		const argument = firstArgument(source, call.index + call[0].length);
		if (argument === null) {
			fail(
				`${where}: the translator call at offset ${call.index} has no first argument the scan can delimit`
			);
			continue;
		}
		for (const literal of argument.matchAll(/(['"])((?:(?!\1)[^\\])*)\1/g)) {
			const before = argument.slice(0, literal.index).trimEnd();
			const after = argument.slice(literal.index + literal[0].length).trimStart();
			if (before.endsWith('+') || after.startsWith('+')) continue;
			if (KEY.test(literal[2])) keys.add(literal[2]);
		}
	}
	return keys;
}

/**
 * The keys i18n.js reads for a page's <select data-i18n-option-prefix>: the
 * prefix, a dot and each option's value, as its required_keys() builds them.
 * @param {string} html
 * @param {string} where File name for the failure message.
 * @returns {Set<string>}
 */
function optionKeys(html, where = 'fixture') {
	const keys = new Set();
	for (const select of html.matchAll(OPTION_SELECT)) {
		const prefix = (select[1].match(/\bdata-i18n-option-prefix="([^"]+)"/) || [])[1];
		if (!prefix) continue;
		const options = [...select[2].matchAll(/<option\b([^>]*)>([^<]*)/g)];
		if (options.length === 0)
			fail(`${where}: the select labelled by '${prefix}' has no option to check`);
		for (const [, attributes, text] of options) {
			const value = (attributes.match(/\bvalue="([^"]*)"/) || [null, text.trim()])[1];
			keys.add(`${prefix}.${value}`);
		}
	}
	return keys;
}

// The extraction itself is checked first: it once read only a lone literal
// argument, so the crash heading of the error window and the options of the
// metrics selects were never compared with en.json
const FIXTURE_SCRIPT = [
	"heading.textContent = t(crash ? 'fixture.heading_crash' : 'fixture.heading');",
	"label.textContent = _t(keys[id] || 'fixture.fallback', count);",
	"title.textContent = _fmt('fixture.plain', name);",
	"dynamic.textContent = t('fixture.prefix_' + id);",
	"row.textContent = t(id, 'fixture.second_argument');"
].join('\n');
const FIXTURE_HTML =
	'<select id="period" data-i18n-option-prefix="fixture.period">' +
	'<option value="day"></option><option value="week" selected></option></select>';
const fixtureFound = [...translatorKeys(FIXTURE_SCRIPT), ...optionKeys(FIXTURE_HTML)].sort();
const fixtureExpected = [
	'fixture.fallback',
	'fixture.heading',
	'fixture.heading_crash',
	'fixture.period.day',
	'fixture.period.week',
	'fixture.plain'
];
if (fixtureFound.join() !== fixtureExpected.join())
	fail(
		`the key extraction found [${fixtureFound.join(', ')}] in its fixture, expected ` +
			`[${fixtureExpected.join(', ')}] — a key it cannot see can be missing from en.json unnoticed`
	);

let checkedKeys = 0;
const checkedPages = pages();
if (checkedPages.length < 10)
	fail(`found only ${checkedPages.length} shared page(s) under ${UI} — the scan is broken`);

for (const page of checkedPages) {
	const { html, files } = pageScripts(page);
	const named = new Map();
	for (const match of html.matchAll(ATTRIBUTE)) named.set(match[1], 'index.html');
	for (const key of optionKeys(html, `${page}/index.html`)) named.set(key, 'index.html');
	for (const file of files) {
		const where = path.relative(UI, file);
		const source = stripComments(fs.readFileSync(file, 'utf8'));
		for (const key of translatorKeys(source, where)) named.set(key, where);
	}
	for (const [key, where] of named) {
		checkedKeys++;
		if (typeof en[key] !== 'string')
			fail(`${page}: ${where} names '${key}', which en.json does not define — it would show raw`);
	}
}
if (checkedKeys < 300) fail(`only ${checkedKeys} literal key(s) found — the extraction is broken`);

// ======================================
// ======================================
// ======= 2/ Every Host Delivers =======
// ======================================
// ======================================

/** Reads a repository file, failing the gate when it is gone. */
function read(rel) {
	const file = path.join(ROOT, rel);
	if (!fs.existsSync(file)) {
		fail(`${rel} is missing — the delivery check has nothing to read`);
		return '';
	}
	return fs.readFileSync(file, 'utf8');
}

// The inline-page builders: the boot script they prepend carries the strings
const BUILDERS = [
	{
		driver: 'macOS',
		rel: 'static/ergopti_plus/macos/ui/ui_builder.lua',
		seed: /window\._i18n_locale="%s";%s<\/script>'[\s\S]{0,120}strings_seed\(/
	},
	{
		driver: 'Linux',
		rel: 'static/ergopti_plus/linux/ui/webkit_host.lua',
		seed: /window\._i18n_locale="%s";%s<\/script>'[\s\S]{0,80}base, active_locale, seed/
	}
];
for (const builder of BUILDERS) {
	const source = read(builder.rel);
	if (source && !builder.seed.test(source))
		fail(
			`${builder.driver}: ${builder.rel} no longer seeds window._i18n_strings in the page's ` +
				`boot script. Its pages are inline and cannot fetch file:// locales, so they would ` +
				`show raw keys.`
		);
	if (source && !source.includes('webview.i18n_seed'))
		fail(`${builder.driver}: ${builder.rel} must build its seed through webview/i18n_seed.lua`);
}
const linuxShow = read('static/ergopti_plus/linux/ui/webview_manager.lua');
if (linuxShow && !/build_app_html\([^)]*catalogue\)/.test(linuxShow))
	fail('Linux: webview_manager.show() no longer hands build_app_html the locale catalogue');

// The macOS app payload ships what a page needs to be translated
const payload = require(path.join(ROOT, 'tools', 'build', 'macos-bundle-payload.cjs'));
const manifest = payload.loadManifest(ROOT);
const shipped = new Set(
	payload.resolvePayload(manifest, payload.trackedFiles(ROOT, manifest)).files.map((f) => f.target)
);
const required = [
	'ergopti_plus/_shared/ui/i18n.js',
	'ergopti_plus/_shared/lua/webview/i18n_seed.lua',
	'ergopti_plus/_shared/lua/locale/core.lua',
	...fs
		.readdirSync(LOCALES)
		.filter((name) => name.endsWith('.json'))
		.map((name) => `ergopti_plus/_shared/data/locales/${name}`),
	...checkedPages.map((page) => `ergopti_plus/_shared/ui/${page}/index.html`)
];
if (required.filter((rel) => rel.includes('/data/locales/')).length < 21)
	fail('fewer than 21 locale files found — the locale scan is broken');
for (const rel of required) {
	if (!shipped.has(rel)) fail(`macOS: the app payload does not ship ${rel}`);
}

// =========================
// =========================
// ======= 3/ Report =======
// =========================
// =========================

if (failures.length) {
	console.error(`FAIL - ${failures.length} way(s) a shared page can show a raw key:`);
	for (const message of failures) console.error(`  - ${message}`);
	process.exit(1);
}
console.log(
	`OK - ${checkedPages.length} shared page(s), ${checkedKeys} literal key(s) in en.json, ` +
		`catalogue delivered by the macOS and Linux builders and shipped in the macOS payload`
);
