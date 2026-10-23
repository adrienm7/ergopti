// tools/lint/audit-translations.cjs

/**
 * ==============================================================================
 * MODULE: Translation Key Audit
 * DESCRIPTION:
 * Checks the shared localization catalogue against the code in both directions.
 *
 * 1. Missing keys: every static key passed to the translation accessor of the
 *    Windows, macOS and Linux drivers, of the shared Lua modules and of the
 *    shared webviews (`t("key")`, `i18n_safe("key")`, `data-i18n="key"`, ...)
 *    and every `i18n` field of the menu manifest must exist in en.json.
 * 2. Unused keys: a key of en.json that no source file names, neither as a full
 *    string literal nor under a dynamic prefix literal ("group.item."), is dead
 *    weight in 21 catalogues. The keys known to be in that state live in
 *    `audit-translations-unused-baseline.json`; the audit fails when a new key
 *    becomes unused AND when a baseline key is used again or deleted, so the
 *    baseline can only shrink.
 *
 * FEATURES & RATIONALE:
 * 1. Every driver is scanned. The audit used to read Windows and macOS only, so
 *    a missing key in the Linux driver or in a shared webview rendered as a raw
 *    key name in the field and failed no gate.
 * 2. Usage is searched in every text source the repository ships (AutoHotkey,
 *    Lua, JavaScript, HTML, TOML, JSON, AppleScript, shell and Python), not only
 *    the three that call the accessor: the macOS helper applications read their
 *    keys from AppleScript, and treating those as unused would delete live text.
 * 3. A dynamic prefix keeps its whole family alive. A key built at run time
 *    cannot be traced statically, so any literal ending in "." protects the keys
 *    below it; that errs towards keeping a key, never towards deleting one.
 *
 * USAGE:  node tools/lint/audit-translations.cjs [--write-baseline]
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { shared, sharedRel } = require('../lib/paths.cjs');

const REPO_ROOT = path.resolve(__dirname, '../../');
const DRIVERS_DIR = path.join(REPO_ROOT, 'static/ergopti_plus');
const LOCALES_DIR = shared('data/locales');
const MANIFEST_PATH = shared('modules/menu/menu_manifest.json');
const BASELINE_PATH = path.join(__dirname, 'audit-translations-unused-baseline.json');

// Directories that never carry user-facing source.
const SKIPPED_DIRECTORIES = new Set(['node_modules', '.git', '_generated', 'tests', 'vendor']);

// The Windows and macOS call shapes, unchanged: an accessor with one literal.
const CORE_CALL = /\b(t|i18n\.get|locale_mod\.get)\(\s*["']([^"']+)["']\s*\)/g;

// The Linux driver, the shared Lua and the shared webviews add their own
// accessors (`tr`, `i18n_safe`, `I18n.get`, `_t`) and the HTML attributes. The
// literal must be followed by `)` or `,` so a dynamic `t("prefix." .. name)` is
// not read as the key "prefix.".
const EXTENDED_CALL =
	/(?<![A-Za-z0-9_])(?:t|tr|_t|i18n_safe|i18n\.get|I18n\.get|locale_mod\.get)\(\s*["']([A-Za-z0-9_.]+)["']\s*[,)]/g;
const HTML_ATTRIBUTE = /data-i18n(?:-title|-placeholder)?="([A-Za-z0-9_.]+)"/g;

// Every extension a key can be named in. Usage, unlike a call, is never traced
// through a particular accessor.
const USAGE_EXTENSIONS = new Set([
	'.ahk',
	'.lua',
	'.js',
	'.cjs',
	'.mjs',
	'.html',
	'.toml',
	'.json',
	'.py',
	'.applescript',
	'.sh',
	'.swift',
	'.plist',
	'.ps1',
	'.svelte'
]);

// The usage walk skips the catalogues themselves, build output, recorded
// history and the tests (a key that only a test names is not user-facing).
const USAGE_SKIPPED = new Set([
	'node_modules',
	'.git',
	'locales',
	'video',
	'build',
	'.claude',
	'.tmp',
	'reports',
	'docs',
	'tests'
]);

/**
 * Lists the files of a tree with one of the given extensions.
 * @param {string} dir Directory to walk.
 * @param {string[]} extensions Extensions with their dot.
 * @param {Set<string>} skipped Directory names never entered.
 * @param {string[]} out Accumulator.
 * @returns {string[]} The matching absolute paths.
 */
function walkFiles(dir, extensions, skipped = SKIPPED_DIRECTORIES, out = []) {
	let entries;
	try {
		entries = fs.readdirSync(dir);
	} catch {
		return out;
	}
	for (const entry of entries) {
		if (skipped.has(entry)) continue;
		const full = path.join(dir, entry);
		let stat;
		try {
			stat = fs.statSync(full);
		} catch {
			continue;
		}
		if (stat.isDirectory()) walkFiles(full, extensions, skipped, out);
		else if (extensions.includes(path.extname(entry))) out.push(full);
	}
	return out;
}

/**
 * Removes the comments that would be read as calls.
 * @param {string} content File content.
 * @param {string} extension File extension with its dot.
 * @returns {string} The content without comments.
 */
function stripComments(content, extension) {
	if (extension === '.ahk') return content.replace(/;.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');
	if (extension === '.lua')
		return content.replace(/--\[\[[\s\S]*?\]\]/g, '').replace(/--.*$/gm, '');
	if (extension === '.js')
		return content.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|\s)\/\/.*$/gm, '$1');
	return content;
}

/**
 * Extracts the static keys one source file passes to a translation accessor.
 * @param {string} content File content, BOM removed.
 * @param {string} extension File extension with its dot.
 * @param {boolean} extended Whether the Linux/shared accessor set applies.
 * @returns {string[]} The keys, in order of appearance.
 */
function extractKeys(content, extension, extended) {
	const clean = stripComments(content, extension);
	const patterns = extended ? [EXTENDED_CALL, HTML_ATTRIBUTE] : [CORE_CALL];
	const keys = [];
	for (const pattern of patterns) {
		pattern.lastIndex = 0;
		let match;
		while ((match = pattern.exec(clean)) !== null) {
			const key = match[match.length - 1];
			// Dynamic keys (a format placeholder or a computed family) cannot be audited statically.
			if (key.includes('%') || key.startsWith('category.')) continue;
			keys.push(key);
		}
	}
	return keys;
}

/**
 * The files the missing-key direction scans, with the call shapes that apply.
 * @returns {{file: string, extended: boolean}[]} The scan plan.
 */
function scanPlan() {
	const plan = [];
	for (const file of walkFiles(path.join(DRIVERS_DIR, 'windows'), ['.ahk'])) {
		plan.push({ file, extended: false });
	}
	for (const file of walkFiles(path.join(DRIVERS_DIR, 'macos'), ['.lua'])) {
		plan.push({ file, extended: false });
	}
	for (const file of walkFiles(path.join(DRIVERS_DIR, 'linux'), ['.lua'])) {
		plan.push({ file, extended: true });
	}
	for (const file of walkFiles(path.join(DRIVERS_DIR, '_shared'), ['.lua', '.js', '.html'])) {
		plan.push({ file, extended: true });
	}
	return plan;
}

/**
 * Loads the English catalogue.
 * @returns {Set<string>} Its keys.
 */
function loadAvailableKeys() {
	const raw = fs.readFileSync(path.join(LOCALES_DIR, 'en.json'), 'utf8').replace(/^﻿+/, '');
	return new Set(Object.keys(JSON.parse(raw)));
}

/**
 * Finds the keys the code and the menu manifest use but en.json lacks.
 * @param {Set<string>} available The English keys.
 * @returns {Map<string, string[]>} Missing key to the files naming it.
 */
function findMissingKeys(available) {
	const missing = new Map();
	const note = (key, where) => {
		if (!missing.has(key)) missing.set(key, []);
		missing.get(key).push(where);
	};
	for (const { file, extended } of scanPlan()) {
		const content = fs.readFileSync(file, 'utf8').replace(/^﻿/, '');
		for (const key of extractKeys(content, path.extname(file), extended)) {
			if (!available.has(key)) note(key, path.relative(REPO_ROOT, file));
		}
	}
	const manifest = JSON.parse(fs.readFileSync(MANIFEST_PATH, 'utf8').replace(/^﻿+/, ''));
	const visit = (node) => {
		if (Array.isArray(node)) node.forEach(visit);
		else if (typeof node === 'object' && node !== null) {
			if (node.i18n && !available.has(node.i18n)) {
				note(node.i18n, sharedRel('modules/menu/menu_manifest.json'));
			}
			Object.values(node).forEach(visit);
		}
	};
	visit(manifest);
	return missing;
}

/**
 * Finds the keys of en.json that no source names.
 * @param {Set<string>} available The English keys.
 * @returns {string[]} The unused keys, sorted.
 */
function findUnusedKeys(available) {
	const literals = new Set();
	const prefixes = new Set();
	const literal = /["'`]([A-Za-z0-9_.-]+)["'`]/g;
	const roots = ['static', 'tools'].map((name) => path.join(REPO_ROOT, name));
	for (const root of roots) {
		for (const file of walkFiles(root, [...USAGE_EXTENSIONS], USAGE_SKIPPED)) {
			let stat;
			try {
				stat = fs.statSync(file);
			} catch {
				continue;
			}
			// The baseline names every unused key, which would make each one used.
			if (stat.size > 3e6 || file === BASELINE_PATH) continue;
			const content = fs.readFileSync(file, 'utf8');
			let match;
			literal.lastIndex = 0;
			while ((match = literal.exec(content)) !== null) {
				literals.add(match[1]);
				if (match[1].endsWith('.')) prefixes.add(match[1]);
			}
			// The HTML attributes are quoted, so the literal scan already saw them.
		}
	}
	const unused = [];
	for (const key of available) {
		if (literals.has(key)) continue;
		if ([...prefixes].some((prefix) => key.startsWith(prefix))) continue;
		unused.push(key);
	}
	return unused.sort();
}

/**
 * Reads the recorded unused keys.
 * @returns {string[]} The baseline, sorted.
 */
function readBaseline() {
	return JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'));
}

/**
 * The required dynamic keys: families no static call names.
 * @returns {string[]} The keys.
 */
function requiredDynamicKeys() {
	// The frequency rows build their key from the shared presets, so the keys come
	// from the same list the drivers read instead of a copy of it.
	const updaterDefaults = JSON.parse(
		fs.readFileSync(shared('modules/updater/defaults.json'), 'utf8')
	);
	const frequencyKeys = updaterDefaults.timing.check_interval_presets.map(
		(preset) => `menu.about.frequency.${preset.code}`
	);
	if (frequencyKeys.length === 0) {
		throw new Error('defaults.json declares no check_interval_presets.');
	}
	return [...frequencyKeys, 'menu.layout.no_bundle'];
}

/** Runs the audit as a command. */
function main() {
	const available = loadAvailableKeys();
	const missing = findMissingKeys(available);
	for (const key of requiredDynamicKeys()) {
		if (!available.has(key)) {
			if (!missing.has(key)) missing.set(key, []);
			missing.get(key).push('Dynamic key check');
		}
	}
	let failed = false;
	if (missing.size > 0) {
		failed = true;
		console.error('\x1b[31m[ERROR] Missing translation keys detected:\x1b[0m');
		for (const [key, locations] of missing) {
			console.error(`  - \x1b[33m${key}\x1b[0m referenced in:`);
			[...new Set(locations)].forEach((loc) => console.error(`      ${loc}`));
		}
	}

	const unused = findUnusedKeys(available);
	if (process.argv.includes('--write-baseline')) {
		fs.writeFileSync(BASELINE_PATH, JSON.stringify(unused, null, '\t') + '\n');
		console.log(`wrote ${path.relative(REPO_ROOT, BASELINE_PATH)} (${unused.length} key(s))`);
		return;
	}
	const baseline = new Set(readBaseline());
	const fresh = unused.filter((key) => !baseline.has(key));
	const stale = [...baseline].filter((key) => !unused.includes(key));
	if (fresh.length > 0) {
		failed = true;
		console.error(
			'\x1b[31m[ERROR] Translation keys no source uses (delete them from all 21 locales):\x1b[0m'
		);
		fresh.forEach((key) => console.error(`  - ${key}`));
	}
	if (stale.length > 0) {
		failed = true;
		console.error(
			'\x1b[31m[ERROR] Baseline keys that are used again or no longer exist (remove them from the baseline):\x1b[0m'
		);
		stale.forEach((key) => console.error(`  - ${key}`));
	}
	if (failed) process.exit(1);
	console.log('\x1b[32m[OK] All static translation keys are present in en.json.\x1b[0m');
	console.log(`\x1b[32m[OK] ${baseline.size} unused key(s) are baselined; none is new.\x1b[0m`);
}

if (require.main === module) main();

module.exports = { extractKeys, findMissingKeys, findUnusedKeys, scanPlan, loadAvailableKeys };
