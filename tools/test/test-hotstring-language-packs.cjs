// tools/test/test-hotstring-language-packs.cjs

/**
 * ==============================================================================
 * MODULE: Hotstring Language Packs Are Complete Data
 * DESCRIPTION:
 * Hotstrings written for one natural language live in
 * _shared/modules/hotstrings/<language>/<stem>.toml and are declared in
 * _index.toml [languages]. Each one loads as the group "<language>_<stem>",
 * which config.toml, the feature manifest and the three tray menus key on.
 *
 * Adding a language is meant to be DATA ONLY, so every piece of data a driver
 * needs must be present, or a driver renders a dead row, fails at boot, or
 * silently loads nothing:
 *   - the declared locale names a shipped locale (the submenu is labelled with
 *     its native name from locale_names.json);
 *   - every declared category file exists, and is named after a neutral root
 *     category (its menu title is that category's);
 *   - every section of that file has a [[features.hotstrings.<group>]] row, and
 *     the manifest has a hotstring_category_keys gate for the group;
 *   - no section appears both in a language file and in its neutral file, so a
 *     split can never leave a duplicate behind.
 *
 * It also pins the opt-in contract: every bundled hotstring section ships
 * disabled. The one hotstrings.* row that stays on is the magic key's layout
 * remap, which is a key assignment, not a hotstring.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const assert = require('assert');
const { parse } = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const HS = path.join(SHARED, 'modules', 'hotstrings');
const MANIFEST = path.join(SHARED, 'modules', 'features', 'manifest.toml');
const LOCALE_NAMES = path.join(SHARED, 'data', 'locale_names.json');

// Rows under hotstrings.* that are not hotstring sections: the J→★ key remap.
const NOT_A_HOTSTRING = new Set(['hotstrings.magic_key.replace']);

const errors = [];
const readToml = (p) => parse(fs.readFileSync(p, 'utf8'));

const index = readToml(path.join(HS, '_index.toml'));
const manifest = readToml(MANIFEST);
const locales = JSON.parse(fs.readFileSync(LOCALE_NAMES, 'utf8')).locales;
const neutralFiles = new Map(
	(index.menu?.categories_order ?? []).map((stem) => [stem, path.join(HS, `${stem}.toml`)])
);
// A layout-specific neutral category retains its title and language siblings
// when its whole-file binding moves its source into a registry extension.
const registry = path.join(ROOT, 'static/layouts/registry');
for (const folder of fs
	.readdirSync(registry, { withFileTypes: true })
	.filter((entry) => entry.isDirectory())) {
	const manifestPath = path.join(registry, folder.name, 'manifest.toml');
	if (!fs.existsSync(manifestPath)) continue;
	const bindings = readToml(manifestPath).extension?.hotstring_bindings ?? {};
	for (const [stem, binding] of Object.entries(bindings)) {
		if (binding.sections) continue;
		if (neutralFiles.has(binding.category))
			errors.push(`${binding.category}: duplicate neutral category source`);
		neutralFiles.set(
			binding.category,
			path.join(registry, folder.name, 'hotstrings', `${stem}.toml`)
		);
	}
}
const neutralStems = new Set(neutralFiles.keys());
// [[features.hotstrings]] is itself an array of tables, so TOML files every
// [[features.hotstrings.<category>]] under its LAST element. Merge them all.
const featureRows = {};
for (const element of [].concat(manifest.features?.hotstrings ?? [])) {
	for (const [key, value] of Object.entries(element)) {
		if (Array.isArray(value)) featureRows[key] = (featureRows[key] ?? []).concat(value);
	}
}
const gateKeys = manifest.menu?.hotstring_category_keys ?? {};

/** Sections a hotstring file declares, in its [_meta] order, without separators. */
const sectionsOf = (doc) => (doc._meta?.sections_order ?? []).filter((s) => s !== '-');

// This capture predates the proposed section split. It must stay independent of
// its source and classification: an edited rule cannot bless its own expectation.
try {
	const reference = JSON.parse(
		fs.readFileSync(
			path.join(SHARED, 'tests/corpus/hotstrings/common_autocorrection_entries.json'),
			'utf8'
		)
	);
	const classification = JSON.parse(
		fs.readFileSync(
			path.join(SHARED, 'data/hotstrings/common_autocorrection_sections.json'),
			'utf8'
		)
	);
	assert.strictEqual(reference.schema_version, 1);
	assert.strictEqual(reference.category, 'autocorrection');
	assert.strictEqual(reference.legacy_section, 'caps');
	assert.strictEqual(reference.source, 'common');
	assert.strictEqual(reference.source_priority, 10);
	assert.match(reference.captured_commit, /^[a-f0-9]{40}$/);
	assert.match(reference.source_sha256, /^[a-f0-9]{64}$/);
	assert.deepStrictEqual(reference.section_counts, { caps: 140 });
	assert.strictEqual(reference.entries.length, 140);
	const document = readToml(path.join(HS, 'autocorrection.toml'));
	assert.deepStrictEqual(document._meta, reference.meta, 'all historical metadata remains exact');
	const actualEntries = Object.entries(document)
		.filter(([section]) => section !== '_meta')
		.flatMap(([section, blocks]) =>
			blocks.flatMap((block) =>
				Object.entries(block).map(([trigger, fields]) => ({ section, trigger, ...fields }))
			)
		)
		.map((row, index) => ({ ordinal: index + 1, ...row }));
	assert.deepStrictEqual(
		actualEntries,
		reference.entries,
		'the complete historical corpus, flags and source order remain exact'
	);
	const tiers = JSON.parse(fs.readFileSync(path.join(HS, 'priority.json'), 'utf8'));
	assert.strictEqual(tiers.common, reference.source_priority);
	assert.strictEqual(new Set(reference.entries.map((row) => row.trigger)).size, 140);
	assert.strictEqual(classification.schema_version, 1);
	assert.strictEqual(classification.status, 'classification_only');
	assert.strictEqual(classification.category, reference.category);
	assert.strictEqual(classification.legacy_section, reference.legacy_section);
	assert.deepStrictEqual(
		classification.sections.map((section) => section.id),
		['names', 'abbreviations', 'technical_terms']
	);
	assert.deepStrictEqual(
		classification.sections.map((section) => section.triggers.length),
		[34, 95, 11]
	);
	const classified = classification.sections.flatMap((section) => section.triggers);
	assert.strictEqual(
		new Set(classified).size,
		140,
		'each trigger belongs to exactly one proposed section'
	);
	assert.deepStrictEqual(
		[...classified].sort(),
		reference.entries.map((row) => row.trigger).sort()
	);
	for (const section of classification.sections) {
		assert.strictEqual(typeof section.description, 'string');
		assert.ok(section.description.length > 0, 'the reviewed classification explains its meaning');
	}
	assert.deepStrictEqual(
		sectionsOf(document),
		['caps'],
		'the editorial catalogue must not change live preferences'
	);
	assert.deepStrictEqual(
		featureRows.autocorrection.map((row) => row.id),
		['caps']
	);
	assert.deepStrictEqual(featureRows.autocorrection[0].default, {
		enabled: false,
		time_activation_seconds: 0.5
	});
} catch (error) {
	errors.push(`common autocorrection independent reference: ${error.message}`);
}

const languages = index.languages?.order ?? [];
if (languages.length === 0)
	errors.push('_index.toml declares no [languages] — the French pack is not wired');

for (const lang of languages) {
	const pack = index.languages[lang];
	if (!pack || typeof pack.locale !== 'string' || !locales[pack.locale]) {
		errors.push(`language '${lang}': locale '${pack?.locale}' is not in locale_names.json`);
		continue;
	}
	// The Lua drivers put this flag before the language's name in the menu.
	if (typeof locales[pack.locale].flag !== 'string' || locales[pack.locale].flag === '') {
		errors.push(`language '${lang}': locale '${pack.locale}' has no flag in locale_names.json`);
	}
	for (const stem of pack.categories_order ?? []) {
		const group = `${lang}_${stem}`;
		const file = path.join(HS, lang, `${stem}.toml`);
		if (!neutralStems.has(stem))
			errors.push(`${group}: '${stem}' is not a neutral category, so it has no title`);
		if (!fs.existsSync(file)) {
			errors.push(`${group}: ${path.relative(ROOT, file)} does not exist`);
			continue;
		}
		const doc = readToml(file);
		const rows = new Set((featureRows[group] ?? []).map((r) => r.id));
		if (!gateKeys[group]) errors.push(`${group}: no [menu.hotstring_category_keys] gate`);
		if (!(manifest.sections?.hotstrings?.subsections ?? []).includes(group)) {
			errors.push(`${group}: missing from [sections.hotstrings] subsections`);
		}
		const neutral = readToml(neutralFiles.get(stem));
		const neutralSections = new Set(sectionsOf(neutral));
		for (const section of sectionsOf(doc)) {
			if (!rows.has(section))
				errors.push(`${group}.${section}: no [[features.hotstrings.${group}]] row`);
			if (neutralSections.has(section))
				errors.push(`${group}.${section}: also declared in the neutral ${stem}.toml`);
			if (!Array.isArray(doc[section]) && section !== 'replace') {
				errors.push(
					`${group}.${section}: listed in sections_order but has no [[${section}]] entries`
				);
			}
		}
	}
}

// Opt-in: every bundled or dynamic hotstring section ships disabled.
for (const [category, rows] of Object.entries(featureRows)) {
	if (!Array.isArray(rows) || category === 'personal') continue;
	for (const row of rows) {
		const p = `hotstrings.${category}.${row.id}`;
		if (NOT_A_HOTSTRING.has(p)) continue;
		if (row.default && typeof row.default === 'object' && row.default.enabled !== false) {
			errors.push(`${p}: ships enabled — every hotstring section must default to disabled`);
		}
	}
}

if (errors.length) {
	console.error('\x1b[31m[FAIL] hotstring language packs are incomplete:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] ${languages.length} hotstring language pack(s) are complete data and every section ships disabled.\x1b[0m`
);
