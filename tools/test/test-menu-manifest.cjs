#!/usr/bin/env node
// tools/test/test-menu-manifest.cjs
//
// Drift gate for the shared tray-menu manifest
// (_shared/modules/menu/menu_manifest.json). The menu is a single shared file
// both drivers read at runtime; its `feature` items reference canonical v2
// feature paths declared in _shared/modules/features/manifest.toml, and every
// item label is an i18n key resolved against _shared/data/locales/*.json. Those
// references can silently drift (a renamed feature path, a removed locale key)
// because nothing validated them — a stale `path` just renders a dead toggle,
// a missing i18n key shows the raw key string.
//
// This check is the validation layer that makes the menu provably consistent
// with the manifest (the "1 SSoT" goal): it is also the gate any future
// codegen-emitted menu tree must pass. It asserts, for every menu item across
// every list in the manifest:
//   - type === "feature" with a `path` → the path resolves to a real
//     manifest.toml feature entry;
//   - any i18n key (i18n / i18n_on / i18n_off / i18n_dynamic) exists in the
//     reference locales (fr + en — full parity is enforced separately);
//   - any `platforms` value is one of the known drivers (ahk / hs);
//   - type === "toggle" carries a non-empty `category`.
//
// Exit 0 when clean, 1 with a list of violations otherwise.

const { readFileSync, readdirSync } = require('fs');
const { resolve, dirname } = require('path');
const { parse: parseToml } = require('smol-toml');

const REPO_ROOT = resolve(__dirname, '..', '..');
const SHARED = resolve(REPO_ROOT, 'static/ergopti_plus/_shared');
const MENU_PATH = resolve(SHARED, 'modules/menu/menu_manifest.json');
const MANIFEST_PATH = resolve(SHARED, 'modules/features/manifest.toml');
const LOCALES_DIR = resolve(SHARED, 'data/locales');

const KNOWN_PLATFORMS = new Set(['ahk', 'hs', 'both']);

// Section sub-keys that are metadata, not nested sections.
const SECTION_META_KEYS = new Set(['order', 'description_key', 'platforms', 'subsections']);

// Recursively collect every section path under [sections.*] (e.g.
// "ahk.shortcuts.alt_gr_lalt"). A menu `feature` item may target a section
// rather than a leaf feature: the renderer expands a section path into a
// mutually-exclusive sub-menu of its per-action toggles (the modifier combos).
function collectSectionPaths(node, parts, out) {
	if (!node || typeof node !== 'object' || Array.isArray(node)) return;
	for (const [key, val] of Object.entries(node)) {
		if (SECTION_META_KEYS.has(key)) continue;
		if (val && typeof val === 'object' && !Array.isArray(val)) {
			out.add([...parts, key].join('.'));
			collectSectionPaths(val, [...parts, key], out);
		}
	}
}

// Same pre-process as tools/build/build-features-manifest.js: rewrite the nested
// [[features.X.Y]] blocks into a flat [[entries]] AoT carrying a path_prefix so
// the TOML parser yields independent entries instead of sub-AoTs. Returns the
// set of all resolvable menu target paths: leaf feature paths AND section paths.
function loadResolvablePaths() {
	const raw = readFileSync(MANIFEST_PATH, 'utf8');
	const preprocessed = raw.replace(
		/^\[\[features\.([^\]]+)\]\]\r?$/gm,
		(_m, prefix) => `[[entries]]\npath_prefix = "${prefix}"`
	);
	const parsed = parseToml(preprocessed);
	const paths = new Set();
	for (const entry of parsed.entries || []) {
		if (entry.id && entry.path_prefix) {
			paths.add(`${entry.path_prefix}.${entry.id}`);
		}
	}
	collectSectionPaths(parsed.sections || {}, [], paths);
	return paths;
}

// Reference locale key sets. Full cross-locale parity is enforced by
// test_locale_json_valid / audit-translations; here we only need a key to
// exist, so fr (source) + en (fallback) are a sufficient reference.
function loadLocaleKeys() {
	const keysByLocale = {};
	for (const name of ['fr', 'en']) {
		const file = resolve(LOCALES_DIR, `${name}.json`);
		// Locale JSON files are UTF-8-with-BOM by convention (matches the AHK
		// driver) — strip the leading BOM code point before parsing, the same
		// fix as audit-translations.cjs already applies to these same files.
		let raw = readFileSync(file, 'utf8');
		raw = raw.replace(/^\uFEFF+/, '');
		keysByLocale[name] = new Set(Object.keys(JSON.parse(raw)));
	}
	return keysByLocale;
}

function main() {
	const menu = JSON.parse(readFileSync(MENU_PATH, 'utf8'));
	const featurePaths = loadResolvablePaths();
	const localeKeys = loadLocaleKeys();
	const violations = [];

	const i18nFields = ['i18n', 'i18n_on', 'i18n_off', 'i18n_dynamic'];

	// Walk every array at the top level of the manifest and validate each
	// object element. Maps (gesture_slots, hotstring_groups, …) and string
	// arrays carry no validatable references, so non-object elements are skipped.
	for (const [listName, value] of Object.entries(menu)) {
		if (!Array.isArray(value)) continue;
		value.forEach((item, idx) => {
			if (!item || typeof item !== 'object') return;
			const where = `${listName}[${idx}]`;

			if (item.type === 'feature' && typeof item.path === 'string') {
				if (!featurePaths.has(item.path)) {
					violations.push(`${where}: feature path "${item.path}" not found in manifest.toml`);
				}
			}

			if (item.type === 'toggle') {
				if (typeof item.category !== 'string' || item.category === '') {
					violations.push(`${where}: toggle is missing a non-empty "category"`);
				}
			}

			for (const field of i18nFields) {
				const key = item[field];
				if (typeof key !== 'string' || key === '') continue;
				for (const loc of ['fr', 'en']) {
					if (!localeKeys[loc].has(key)) {
						violations.push(`${where}: ${field} "${key}" missing from ${loc}.json`);
					}
				}
			}

			if (item.platforms !== undefined) {
				if (!Array.isArray(item.platforms)) {
					violations.push(`${where}: "platforms" must be an array`);
				} else {
					for (const p of item.platforms) {
						if (!KNOWN_PLATFORMS.has(p)) {
							violations.push(`${where}: unknown platform "${p}" (expected ahk/hs)`);
						}
					}
				}
			}
		});
	}

	if (violations.length > 0) {
		console.error(`menu manifest drift gate: ${violations.length} violation(s):`);
		for (const v of violations) console.error(`  - ${v}`);
		process.exit(1);
	}

	console.log(
		`menu manifest drift gate: OK — ${featurePaths.size} feature paths, ` +
		`all menu feature paths + i18n keys + platforms valid.`
	);
}

main();
