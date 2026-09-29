// tools/test/test-shared-pages-never-show-raw-keys.cjs

/**
 * ==============================================================================
 * MODULE: Shared Pages Never Show a Raw Locale Key
 * DESCRIPTION:
 * A shared webview page shows a raw key when the key is missing from the
 * catalogue, or when the catalogue never reaches the page. This gate covers
 * both halves for every page under _shared/ui:
 * 1. every key a page names literally (data-i18n, data-i18n-title,
 *    data-i18n-placeholder, and the first argument of its _t(), t() and
 *    _fmt() translators) exists in en.json, the canonical catalogue;
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
// The literal must be the whole argument: 'prefix_' + value is built at run time
const TRANSLATOR = /(?<![\w.$])(?:_t|t|_fmt)\(\s*(['"])([^'"]+)\1\s*(?=[,)])/g;

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

let checkedKeys = 0;
const checkedPages = pages();
if (checkedPages.length < 10)
	fail(`found only ${checkedPages.length} shared page(s) under ${UI} — the scan is broken`);

for (const page of checkedPages) {
	const { html, files } = pageScripts(page);
	const named = new Map();
	for (const match of html.matchAll(ATTRIBUTE)) named.set(match[1], 'index.html');
	for (const file of files) {
		const source = stripComments(fs.readFileSync(file, 'utf8'));
		for (const match of source.matchAll(TRANSLATOR)) {
			if (KEY.test(match[2])) named.set(match[2], path.relative(UI, file));
		}
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
