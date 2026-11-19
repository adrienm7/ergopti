// tools/test/test-i18n-referenced-keys-resolve.cjs

/**
 * ==============================================================================
 * MODULE: Every Referenced Translation Key Resolves
 * DESCRIPTION:
 * Every key the shipped JavaScript, Lua and AutoHotkey pass to a translation
 * accessor must exist in en.json, and therefore in all 21 locales
 * (test-locale-catalogue-complete.cjs keeps them equal):
 * 1. a whole key, including those the static audit cannot read: a
 *    page-prefixed accessor (editor_page.js `tl('caps.label')`), a member
 *    accessor (`view.t(...)`, `INFO.t(...)`), a file constant;
 * 2. every key of a family built at run time from a literal head
 *    (`view.t('layer_editor.key.' + NAMED_KEYS[code])`,
 *    t(`layout_analysis.metric.${id}`), t("gesture.slots." . Slot)): each
 *    family is enumerated from the data the code reads, in
 *    lib/i18n-dynamic-keys/*.cjs. A family no module enumerates fails, a
 *    module family no code builds fails, and no module may read the locale
 *    catalogues, so a family can never agree with en.json by construction.
 *
 * ROOT CAUSE ENCODED:
 * The Studio's « Edit » tab showed layer_editor.key.shift for Shift on
 * Windows: the host sent a prefix-filtered subset of the catalogue and the key
 * names' family was outside it. Nothing listed the families the Studio
 * builds, so neither the missing family nor any other run-time key was ever
 * checked against a catalogue.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { allSites, KEY_SHAPE, REPO_ROOT } = require('./lib/i18n-key-sites.cjs');

const FAMILIES_DIR = path.join(__dirname, 'lib', 'i18n-dynamic-keys');
const EN = path.join(
	REPO_ROOT,
	'static',
	'ergopti_plus',
	'_shared',
	'core',
	'i18n',
	'data',
	'locales',
	'en.json'
);
// Floors: a scanner that lost its accessors must not read as complete.
const MIN_KEY_SITES = 3000;
const MIN_FAMILY_SITES = 150;

/**
 * Loads every family module, refusing one that reads anything but its context.
 * @returns {{module: string, prefix: string, files: string[], source: string, keys: Function}[]}
 */
function loadFamilies() {
	const families = [];
	for (const name of fs.readdirSync(FAMILIES_DIR).sort()) {
		if (!name.endsWith('.cjs') || name === 'context.cjs') continue;
		const file = path.join(FAMILIES_DIR, name);
		const text = fs.readFileSync(file, 'utf8');
		for (const m of text.matchAll(/require\(\s*['"]([^'"]+)['"]\s*\)/g))
			if (m[1] !== './context.cjs')
				throw new Error(`${name} requires ${m[1]}: a family reads its data through context.cjs`);
		for (const family of require(file)) families.push({ module: name, ...family });
	}
	return families;
}

/** Runs the gate. */
function main() {
	const en = new Set(Object.keys(JSON.parse(fs.readFileSync(EN, 'utf8'))));
	const sites = allSites();
	const errors = [];
	const keySites = sites.filter((site) => site.kind === 'key');
	const familySites = sites.filter((site) => site.kind === 'family');
	if (keySites.length < MIN_KEY_SITES) errors.push(`only ${keySites.length} whole-key calls found`);
	if (familySites.length < MIN_FAMILY_SITES)
		errors.push(`only ${familySites.length} family calls found`);

	// 1. Whole keys.
	for (const site of keySites)
		if (KEY_SHAPE.test(site.text) && !en.has(site.text))
			errors.push(`${site.file}:${site.line}: ${site.text} is not in en.json`);

	// 2. Families: each site claimed, each claim used, each key present.
	const families = loadFamilies();
	const byPrefix = new Map();
	const fallbacks = [];
	for (const family of families) {
		const where = `${family.module}: ${family.prefix}`;
		if (typeof family.prefix !== 'string' || family.prefix === '')
			errors.push(`${where}: no prefix`);
		if (typeof family.source !== 'string' || family.source.trim() === '')
			errors.push(`${where}: no source stated`);
		if (!Array.isArray(family.files) || family.files.length === 0) errors.push(`${where}: no file`);
		if (byPrefix.has(family.prefix))
			errors.push(`${where}: also declared in ${byPrefix.get(family.prefix).module}`);
		byPrefix.set(family.prefix, family);
		let keys;
		try {
			keys = family.keys();
		} catch (error) {
			errors.push(`${where}: cannot enumerate its keys: ${error.message}`);
			continue;
		}
		if (!Array.isArray(keys) || keys.length === 0) {
			errors.push(`${where}: enumerates no key`);
			continue;
		}
		const fallback = family.fallback;
		if (fallback) {
			// A family whose code words a missing key with a translated fallback:
			// the fallback must exist and every site file must test for the miss.
			if (!en.has(fallback.key))
				errors.push(`${where}: its fallback ${fallback.key} is not in en.json`);
			for (const file of family.files)
				if (!fallback.guard.test(fs.readFileSync(path.join(REPO_ROOT, file), 'utf8')))
					errors.push(
						`${where}: ${file} no longer falls back to ${fallback.key} (guard ${fallback.guard})`
					);
		}
		for (const key of keys) {
			if (typeof key !== 'string' || !key.startsWith(family.prefix) || !KEY_SHAPE.test(key))
				errors.push(`${where}: ${JSON.stringify(key)} is not a key of the family`);
			else if (en.has(key)) continue;
			else if (fallback) fallbacks.push(`${key} -> ${fallback.key}`);
			else errors.push(`${where}: ${key} is not in en.json`);
		}
		for (const file of family.files)
			if (!familySites.some((site) => site.file === file && site.text === family.prefix))
				errors.push(`${where}: ${file} builds no key of this family`);
	}
	for (const site of familySites) {
		const family = byPrefix.get(site.text);
		if (!family || !family.files.includes(site.file))
			errors.push(
				`${site.file}:${site.line}: the family ${site.text}… is built here and no ` +
					'lib/i18n-dynamic-keys module enumerates it for this file'
			);
	}

	if (errors.length) {
		console.error(
			'\x1b[31m[ERROR] translation keys the code references that do not resolve:\x1b[0m'
		);
		for (const line of [...new Set(errors)]) console.error(`  - ${line}`);
		process.exit(1);
	}
	const total = families.reduce((sum, family) => sum + family.keys().length, 0);
	if (fallbacks.length) {
		console.log(
			`${fallbacks.length} refusal code(s) have no text of their own and read as their family's translated fallback:`
		);
		for (const line of fallbacks) console.log(`  - ${line}`);
	}
	console.log(
		`\x1b[32m[OK] ${keySites.length} whole-key calls and ${familySites.length} family calls ` +
			`(${families.length} families, ${total} keys) resolve in en.json.\x1b[0m`
	);
}

main();
