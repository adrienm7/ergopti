// tools/codegen/codegen-hotstring-catalogue-js.cjs

/**
 * ==============================================================================
 * MODULE: Hotstring Catalogue Codegen (Studio)
 * DESCRIPTION:
 * Writes _shared/ui/layout_analysis/_generated/hotstring_catalogue.js, the
 * global LAYOUT_HOTSTRING_CATALOGUE the Comparer's « Typed with the Ergopti+
 * shortcuts » option reads: every hotstring section a user can enable (the
 * feature manifest's rows under hotstrings.<group>), with its entries read from
 * the files the drivers load (the shared catalogue, its language packs and the
 * Ergopti extension's bound files), the default end characters
 * (Terminators.spec.js) and the magic key's layout rule (magic_key.json).
 *
 * FEATURES & RATIONALE:
 * 1. One source each: sections from the manifest, entries from the TOML,
 *    flags packed by the bits of shortcut_typing.js (FLAGS), end characters
 *    from the terminator spec. Nothing is copied by hand.
 * 2. Fail fast: a manifest section without entries, a file section the
 *    manifest does not list, or a group no file answers stops the build.
 * 3. No default selection: the user's enabled sections come from their host,
 *    or from their own choice on the site (docs/design/layout-analysis.md).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const vm = require('vm');
const path = require('path');
const { parse: parseToml } = require('smol-toml');
const { shared, sharedRel } = require('../lib/paths.cjs');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const CATALOGUE_DIR = shared('hotstrings', 'data', 'catalogue');
const EXTENSION_DIR = path.join(REPO_ROOT, 'static', 'layouts', 'registry', 'ergopti');
const MANIFEST_PATH = shared('settings', 'data', 'features', 'manifest.toml');
const MAGIC_KEY_PATH = shared('hotstrings', 'data', 'magic_key.json');
const TERMINATORS_PATH = shared('core', 'text', 'data', 'domain', 'Terminators.spec.js');
const MODULE_PATH = shared('ui', 'layout_analysis', 'shortcut_typing.js');
const EN_LOCALE_PATH = shared('core', 'i18n', 'data', 'locales', 'en.json');
const OUT_PATH = shared('ui', 'layout_analysis', '_generated', 'hotstring_catalogue.js');
// The manifest groups that hold no catalogue file: generated hotstrings and
// the user's own files, which the host sends apart.
const NON_CATALOGUE_GROUPS = new Set(['dynamic', 'personal']);
// sections_order writes a menu separator as this.
const SEPARATOR = '-';

// ==================================================
// ==================================================
// ======= 1/ Sources =======
// ==================================================
// ==================================================

/** Reads a TOML file, without a byte order mark. */
function readToml(file) {
	return parseToml(fs.readFileSync(file, 'utf8').replace(/^﻿+/, ''));
}

/** The terminator spec's catalogue (a CommonJS file in an ESM package). */
function terminatorDefs() {
	const mod = { exports: {} };
	// eslint-disable-next-line no-new-func
	new Function('require', 'module', 'exports', fs.readFileSync(TERMINATORS_PATH, 'utf8'))(
		require,
		mod,
		mod.exports
	);
	return mod.exports.TERMINATOR_DEFS;
}

/** shortcut_typing.js, loaded as the classic script a page loads. */
function loadModule() {
	const sandbox = {};
	vm.createContext(sandbox);
	vm.runInContext(fs.readFileSync(MODULE_PATH, 'utf8'), sandbox, { filename: MODULE_PATH });
	return vm.runInContext('LAYOUT_SHORTCUT_TYPING', sandbox);
}

/**
 * The hotstring groups a user enables, and their section rows, from the
 * feature manifest: group → [{id, description_key, default}].
 * @returns {Map<string, object[]>}
 */
function manifestGroups() {
	// [[features.hotstrings.<group>]] tables land on whichever
	// [[features.hotstrings]] row precedes them, so every row is read.
	const groups = new Map();
	for (const row of readToml(MANIFEST_PATH).features.hotstrings)
		for (const [group, rows] of Object.entries(row)) {
			if (NON_CATALOGUE_GROUPS.has(group) || !Array.isArray(rows)) continue;
			if (!rows.every((r) => r && typeof r === 'object' && typeof r.id === 'string')) continue;
			groups.set(group, (groups.get(group) || []).concat(rows));
		}
	return groups;
}

/** The locale of the language pack a group belongs to (<pack>_<stem>), or null. */
function packLocale(index, group) {
	const pack = index.languages.order.find((name) => group.startsWith(`${name}_`));
	return pack ? index.languages[pack].locale : null;
}

/**
 * Each file the drivers load, with the group whose sections it holds: the
 * catalogue's categories (group = stem without underscores, or
 * <language>_<stem>) and the extension's bound files (their feature_section).
 * @param {Set<string>} groupIds - The manifest's groups.
 * @returns {Array<{file: string, group: string, language: string|null, sections: string[]|null}>}
 */
function sourceFiles(groupIds) {
	const index = readToml(path.join(CATALOGUE_DIR, '_index.toml'));
	const groupOf = (prefix, stem) => {
		const found = [...groupIds].filter(
			(g) => g.replace(/_/g, '') === `${prefix}${stem}`.replace(/_/g, '')
		);
		if (found.length !== 1)
			throw new Error(
				`hotstring catalogue: ${prefix}${stem} answers ${found.length} manifest groups`
			);
		return found[0];
	};
	const files = index.menu.categories_order.map((stem) => ({
		file: path.join(CATALOGUE_DIR, `${stem}.toml`),
		group: groupOf('', stem),
		language: null,
		sections: null
	}));
	for (const pack of index.languages.order) {
		const declared = index.languages[pack];
		for (const stem of declared.categories_order)
			files.push({
				file: path.join(CATALOGUE_DIR, pack, `${stem}.toml`),
				group: groupOf(`${pack}_`, stem),
				language: declared.locale,
				sections: null
			});
	}
	const bindings = readToml(path.join(EXTENSION_DIR, 'manifest.toml')).extension.hotstring_bindings;
	for (const [stem, binding] of Object.entries(bindings)) {
		const group = binding.feature_section.replace(/^hotstrings\./, '');
		if (!groupIds.has(group))
			throw new Error(`hotstring catalogue: ${stem} binds unknown ${group}`);
		files.push({
			file: path.join(EXTENSION_DIR, 'hotstrings', `${stem}.toml`),
			group,
			language: packLocale(index, group),
			sections: binding.sections || null
		});
	}
	return files;
}

// ==================================================
// ==================================================
// ======= 2/ Build =======
// ==================================================
// ==================================================

/**
 * The catalogue data.
 * @returns {object} LAYOUT_HOTSTRING_CATALOGUE.
 */
function buildCatalogue() {
	const { FLAGS } = loadModule();
	const en = JSON.parse(fs.readFileSync(EN_LOCALE_PATH, 'utf8'));
	const groups = manifestGroups();
	const found = new Map();
	// Sections a sections_order lists without any file holding their table.
	const listedOnly = new Map();
	for (const source of sourceFiles(new Set(groups.keys()))) {
		const doc = readToml(source.file);
		const meta = doc._meta || {};
		const order = (meta.sections_order || []).filter((name) => name !== SEPARATOR);
		for (const name of order) {
			if (source.sections && !source.sections.includes(name)) continue;
			const id = `${source.group}.${name}`;
			// A section bound to the extension has no table in the catalogue
			// file; one no file holds is a driver rule (space_around_symbols).
			if (!Array.isArray(doc[name])) {
				if (!found.has(id))
					listedOnly.set(id, {
						group: source.group,
						section: name,
						language: source.language,
						label: (meta.sections && meta.sections[name]) || name
					});
				continue;
			}
			if (found.has(id)) throw new Error(`hotstring catalogue: ${id} is in two files`);
			const entries = doc[name].flatMap((table) =>
				Object.entries(table).map(([trigger, entry]) => {
					if (typeof entry.output !== 'string')
						throw new Error(`hotstring catalogue: ${id} ${trigger} has no output`);
					const bits =
						(entry.is_word ? FLAGS.word : 0) |
						(entry.auto_expand ? FLAGS.auto : 0) |
						(entry.is_case_sensitive ? FLAGS.caseSensitive : 0) |
						(entry.is_case_sensitive_strict ? FLAGS.strict : 0) |
						(entry.final_result ? FLAGS.final : 0);
					return [trigger, entry.output, bits];
				})
			);
			found.set(id, {
				group: source.group,
				section: name,
				language: source.language,
				label: (meta.sections && meta.sections[name]) || name,
				entries
			});
		}
	}
	const sections = [];
	for (const [group, rows] of groups) {
		for (const row of rows) {
			// A setting of the group (a delay, a toggle) is not a section.
			if (!row.default || typeof row.default !== 'object' || !('enabled' in row.default)) continue;
			const id = `${group}.${row.id}`;
			// A row no file holds a table for is a rule the drivers apply in code
			// (space_around_symbols): it has no entries, and the page says so.
			const section =
				found.get(id) ||
				Object.assign(
					{ group, section: row.id, language: null, label: row.id },
					listedOnly.get(id) || {},
					{ entries: [], driver_rule: true }
				);
			found.delete(id);
			sections.push(
				Object.assign({ id }, section, {
					label_key: typeof en[row.description_key] === 'string' ? row.description_key : null
				})
			);
		}
	}
	if (found.size)
		throw new Error(`hotstring catalogue: no manifest row for ${[...found.keys()].join(', ')}`);
	const terminators = terminatorDefs()
		.filter((def) => def.type !== 'separator' && def.default_enabled)
		.map((def) => ({ key: def.key, chars: def.chars, consume: def.consume === true }));
	const magic = JSON.parse(fs.readFileSync(MAGIC_KEY_PATH, 'utf8'));
	return {
		marker: magic.marker,
		terminators,
		magic_key: { families: magic.layout_families, fallback: magic.marker },
		sections
	};
}

/**
 * The generated file.
 * @param {object} catalogue - buildCatalogue().
 * @returns {string} JS source.
 */
function buildSource(catalogue) {
	return [
		'// _shared/ui/layout_analysis/_generated/hotstring_catalogue.js',
		'',
		'// ==========================================',
		'// AUTO-GENERATED — do not edit manually',
		`// Source: ${sharedRel('hotstrings/data/catalogue')}, static/layouts/registry/ergopti/hotstrings,`,
		`// ${sharedRel('settings/data/features/manifest.toml')}`,
		'// Run: npm run codegen:hotstring-catalogue:js',
		'// ==========================================',
		'',
		'// Every hotstring section a user can enable, its entries as [trigger, output,',
		'// flag bits (LAYOUT_SHORTCUT_TYPING.FLAGS)], the default end characters and',
		'// the magic key rule, for the Studio typing a corpus with the user’s shortcuts.',
		'// eslint-disable-next-line no-unused-vars',
		`var LAYOUT_HOTSTRING_CATALOGUE = ${JSON.stringify(catalogue)};`,
		''
	].join('\n');
}

/** Writes the generated file. */
function main() {
	fs.mkdirSync(path.dirname(OUT_PATH), { recursive: true });
	fs.writeFileSync(OUT_PATH, buildSource(buildCatalogue()));
	console.log(`codegen:hotstring-catalogue:js — wrote ${path.relative(REPO_ROOT, OUT_PATH)}`);
}

if (require.main === module) main();

module.exports = { buildCatalogue, buildSource, OUT_PATH };
