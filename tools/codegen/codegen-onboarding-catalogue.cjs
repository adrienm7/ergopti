// tools/codegen/codegen-onboarding-catalogue.cjs

/**
 * ==============================================================================
 * MODULE: Onboarding Catalogue Codegen
 * DESCRIPTION:
 * Projects the manifest's [onboarding] declaration into the data the first-run
 * wizard renders and every host validates: one page per configuration scope,
 * each with its category switch and its checklist of recommended items, for
 * each driver platform.
 *
 * Inputs:
 *   _shared/modules/features/manifest.toml   features, scopes, [onboarding]
 *   _shared/modules/hotstrings/_index.toml   languages and category order
 *   _shared/modules/hotstrings/**.toml       file and section descriptions
 *   _shared/data/locales/*.json              label keys must exist in all 21
 *   _shared/data/locale_names.json           language-pack labels
 *
 * Outputs:
 *   _shared/ui/_generated/onboarding_catalogue.js    the page's data script
 *   _shared/ui/_generated/onboarding_catalogue.json  the hosts' validation data
 *
 * FEATURES & RATIONALE:
 * 1. One vocabulary: every persisted item is a manifest path declared for its
 *    platform (a feature, a feature's sub-key or a scope's dynamic leaf), with
 *    the neutral default and recommendation the drivers read from the same
 *    manifest. Hosts write what the page emits without interpreting it.
 * 2. Labels are locale keys the drivers already use, resolved through the tray
 *    menu's candidate chain; an item whose label exists in no locale stops the
 *    generation instead of shipping a raw identifier.
 * 3. Deterministic: manifest and file order, no timestamp.
 *
 * USAGE:  node tools/codegen/codegen-onboarding-catalogue.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const TOML = require('smol-toml');
const { shared, sharedRel } = require('../lib/paths.cjs');
const { candidateKeys } = require('../lib/manifest-label-keys.cjs');

const MANIFEST_PATH = shared('modules', 'features', 'manifest.toml');
const HOTSTRINGS_DIR = shared('modules', 'hotstrings');
const LOCALE_DIR = shared('data', 'locales');
const LOCALE_NAMES_PATH = shared('data', 'locale_names.json');
const PAGE_OUTPUT = shared('ui', '_generated', 'onboarding_catalogue.js');
const HOST_OUTPUT = shared('ui', '_generated', 'onboarding_catalogue.json');
const RUN_HINT = 'npm run codegen:onboarding-catalogue';

// Driver name → manifest platform token. The page and the hosts speak driver
// names (initData.platform); the manifest speaks platform tokens.
const DRIVERS = { windows: 'ahk', macos: 'hs', linux: 'linux' };
const MANIFEST_PLATFORMS = Object.values(DRIVERS);

// The catalogue format the page and the hosts accept. Bump it with any shape
// change so a stale host refuses the data instead of misreading it.
const SCHEMA_VERSION = 1;

const CHECKLIST_KINDS = ['recommended', 'hotstrings', 'none'];
const PAGE_FIELDS = new Set([
	'title_key',
	'question_key',
	'description_key',
	'master',
	'checklist',
	'exclude',
	'labels',
	'hint_key',
	'note_key',
	'consent',
	'file_path',
	'section_path',
	'neutral_label_key',
	'magic_key'
]);

// The separator a hotstring file writes between groups of its sections_order.
const SECTION_SEPARATOR = '-';

// ==========================================
// ==========================================
// ======= 1/ Sources =======================
// ==========================================
// ==========================================

/**
 * Parses the manifest, flattening the nested [[features.X.Y]] arrays the same
 * way tools/build/build-features-manifest.js does.
 * @returns {object} Parsed manifest with `entries`.
 */
function loadManifest() {
	const raw = fs
		.readFileSync(MANIFEST_PATH, 'utf8')
		.replace(/^\[\[features\.([^\]]+)\]\]\r?$/gm, (_m, prefix) => {
			return `[[entries]]\npath_prefix = "${prefix}"`;
		});
	const parsed = TOML.parse(raw);
	if (!parsed.onboarding || !parsed.scopes || !parsed.entries || !parsed.sections) {
		throw new Error('manifest.toml must declare [onboarding], [scopes], [sections] and features');
	}
	return parsed;
}

/**
 * Resolves each feature's platforms from its nearest declaring section, as the
 * manifest builder does, and indexes the features by path.
 * @param {object} manifest Parsed manifest.
 * @returns {Map<string, object>} Path → feature.
 */
function indexFeatures(manifest) {
	const sectionPlatforms = new Map();
	(function walk(node, parts) {
		if (!node || typeof node !== 'object' || Array.isArray(node)) return;
		if (parts.length > 0 && Array.isArray(node.platforms)) {
			sectionPlatforms.set(parts.join('.'), node.platforms);
		}
		for (const [key, value] of Object.entries(node)) {
			if (!['order', 'description_key', 'platforms', 'subsections'].includes(key)) {
				walk(value, [...parts, key]);
			}
		}
	})(manifest.sections, []);
	const index = new Map();
	for (const entry of manifest.entries) {
		const feature = {
			...entry,
			section: entry.path_prefix,
			path: `${entry.path_prefix}.${entry.id}`
		};
		delete feature.path_prefix;
		if (!feature.platforms || feature.platforms.length === 0) {
			const parts = feature.section.split('.');
			while (parts.length > 0 && !sectionPlatforms.has(parts.join('.'))) parts.pop();
			feature.platforms =
				parts.length > 0 ? sectionPlatforms.get(parts.join('.')) : MANIFEST_PLATFORMS;
		}
		if (index.has(feature.path)) throw new Error(`duplicate manifest feature ${feature.path}`);
		index.set(feature.path, feature);
	}
	return index;
}

/**
 * Reads every locale file as a flat key → string map.
 * @returns {Map<string, object>} Locale code → strings.
 */
function loadLocales() {
	const locales = new Map();
	for (const name of fs.readdirSync(LOCALE_DIR).sort()) {
		if (!name.endsWith('.json')) continue;
		const text = fs.readFileSync(path.join(LOCALE_DIR, name), 'utf8').replace(/^﻿/, '');
		locales.set(name.slice(0, -5), JSON.parse(text));
	}
	if (!locales.has('en')) throw new Error('the canonical en.json locale is missing');
	return locales;
}

// ==========================================
// ==========================================
// ======= 2/ Manifest projections ==========
// ==========================================
// ==========================================

/**
 * Creates the per-platform value projection over the indexed manifest: the
 * same static-entry, sub-key and dynamic-default rules the drivers' readers
 * (_shared/lua/config_defaults.lua, windows/infra/manifest_reader.ahk) apply.
 * @param {Map<string, object>} features Indexed features.
 * @param {object} scopes Manifest scope declarations.
 * @returns {object} Projection helpers.
 */
function createProjection(features, scopes) {
	function dynamicEntry(entryPath) {
		let parent = entryPath;
		while (parent) {
			if (features.has(parent)) return null;
			const dot = parent.lastIndexOf('.');
			parent = dot > 0 ? parent.slice(0, dot) : '';
		}
		for (const scope of Object.values(scopes)) {
			for (const definition of scope.dynamic_defaults || []) {
				const prefix = definition.prefix + '.';
				if (!entryPath.startsWith(prefix)) continue;
				const tail = entryPath.slice(prefix.length);
				const parts = tail.split('.');
				if (parts.length !== definition.depth || parts.some((part) => part === '')) continue;
				if (definition.suffix && parts[parts.length - 1] !== definition.suffix) continue;
				return definition;
			}
		}
		return null;
	}

	function perPlatform(feature, field, platform) {
		const table = feature[`${field}_per_platform`];
		if (table !== undefined) {
			if (!Object.hasOwn(table, platform)) {
				throw new Error(`${feature.path} has no ${field} for ${platform}`);
			}
			return table[platform];
		}
		if (feature[field] === undefined) throw new Error(`${feature.path} has no ${field}`);
		return feature[field];
	}

	/**
	 * Projects a declared path for one platform.
	 * @param {string} entryPath Dotted configuration path.
	 * @param {string} platform Manifest platform token.
	 * @returns {{default: *, recommended: *, feature: object|null}} Values.
	 */
	function project(entryPath, platform) {
		const dynamic = dynamicEntry(entryPath);
		if (dynamic)
			return { default: dynamic.default, recommended: dynamic.recommended, feature: null };
		let prefix = entryPath;
		const suffix = [];
		while (!features.has(prefix)) {
			const dot = prefix.lastIndexOf('.');
			if (dot <= 0) throw new Error(`${entryPath} is not a manifest path`);
			suffix.unshift(prefix.slice(dot + 1));
			prefix = prefix.slice(0, dot);
		}
		const feature = features.get(prefix);
		if (!feature.platforms.includes(platform)) {
			throw new Error(`${entryPath} is not declared for ${platform}`);
		}
		let neutral = perPlatform(feature, 'default', platform);
		let recommended = perPlatform(feature, 'recommended', platform);
		for (const key of suffix) {
			if (!isPlainObject(neutral) || !Object.hasOwn(neutral, key)) {
				throw new Error(`${entryPath} is not a manifest path`);
			}
			neutral = neutral[key];
			recommended = recommended[key];
		}
		return { default: neutral, recommended, feature };
	}

	function scopeOf(entryPath) {
		for (const [id, scope] of Object.entries(scopes)) {
			for (const prefix of scope.prefixes || []) {
				if (entryPath === prefix || entryPath.startsWith(prefix + '.')) return id;
			}
		}
		return null;
	}

	return { project, scopeOf, perPlatform };
}

/**
 * True for a TOML table decoded into a plain object.
 * @param {*} value Candidate.
 * @returns {boolean} Whether it is a plain object.
 */
function isPlainObject(value) {
	return value !== null && typeof value === 'object' && !Array.isArray(value);
}

/**
 * Deep structural equality over TOML values.
 * @param {*} left First value.
 * @param {*} right Second value.
 * @returns {boolean} Equality.
 */
function sameValue(left, right) {
	return JSON.stringify(left) === JSON.stringify(right);
}

// ==========================================
// ==========================================
// ======= 3/ Labels ========================
// ==========================================
// ==========================================

/**
 * Builds the label checks bound to the loaded locales.
 * @param {Map<string, object>} locales Locale code → strings.
 * @returns {object} Label helpers.
 */
function createLabels(locales) {
	const codes = [...locales.keys()];

	/** Throws unless every locale translates the key with a non-empty string. */
	function requireKey(key, context) {
		for (const code of codes) {
			const value = locales.get(code)[key];
			if (typeof value !== 'string' || value === '') {
				throw new Error(`${context}: locale key ${key} is missing from ${code}.json`);
			}
		}
		return key;
	}

	/** The first candidate key of a manifest entry that every locale carries. */
	function featureLabelKey(feature, context) {
		const en = locales.get('en');
		for (const candidate of candidateKeys(feature.description_key || '', feature.path)) {
			if (candidate !== '' && typeof en[candidate] === 'string' && en[candidate] !== '') {
				return requireKey(candidate, context);
			}
		}
		throw new Error(
			`${context}: no locale key labels ${feature.path}; declare one in the page's labels`
		);
	}

	// Translations written in data files, stored once and referenced by id so
	// the three platforms' pages do not each carry a copy.
	const texts = {};

	/** A value that is either one literal or a translation in every locale. */
	function localizedText(value, id) {
		if (typeof value === 'string') return { text: value };
		if (!isPlainObject(value))
			throw new Error(`${id}: description is neither text nor translations`);
		const translations = {};
		for (const code of codes) {
			if (typeof value[code] !== 'string' || value[code] === '') {
				throw new Error(`${id}: description has no ${code} translation`);
			}
			translations[code] = value[code];
		}
		if (Object.hasOwn(texts, id) && !sameValue(texts[id], translations)) {
			throw new Error(`${id}: two different translations share one id`);
		}
		texts[id] = translations;
		return { text_ref: id };
	}

	/** The picker label of an action identifier used as a slot value. */
	function actionLabelKey(action, context) {
		const en = locales.get('en');
		for (const key of [`sg_actions.${action}`, `ax_actions.${action}`]) {
			if (typeof en[key] === 'string') return requireKey(key, context);
		}
		throw new Error(`${context}: action ${action} has no picker label`);
	}

	return { requireKey, featureLabelKey, localizedText, actionLabelKey, codes, texts };
}

// Keyboard-slot ids spell their chord: the Windows tray formats them the same
// way (windows/infra/config_io.ahk _FormatSlotLabel). Only named keys translate.
const CHORD_PREFIXES = [
	['ctrl_shift_', 'Ctrl + Shift + '],
	['ctrl_', 'Ctrl + '],
	['win_', 'Win + '],
	['alt_', 'Alt + ']
];
const CHORD_KEY_NAMES = { space: 'common.key_space', enter: 'common.key_enter' };
const CHORD_KEY_GLYPHS = { period: '.', comma: ',', sc029: '²' };

/**
 * Label segments of a keyboard slot id, or null when the id spells no chord.
 * @param {string} slot Slot id such as win_a.
 * @param {object} labels Label helpers.
 * @returns {object[]|null} Segments.
 */
function chordSegments(slot, labels) {
	for (const [prefix, text] of CHORD_PREFIXES) {
		if (!slot.startsWith(prefix)) continue;
		const key = slot.slice(prefix.length);
		if (Object.hasOwn(CHORD_KEY_NAMES, key)) {
			return [{ text }, { key: labels.requireKey(CHORD_KEY_NAMES[key], slot) }];
		}
		return [{ text: text + (CHORD_KEY_GLYPHS[key] || key.toUpperCase()) }];
	}
	return null;
}

// ==========================================
// ==========================================
// ======= 4/ Pages =========================
// ==========================================
// ==========================================

/**
 * Validates the page declaration's shape and label keys.
 * @param {string} id Page id.
 * @param {object} page Declaration.
 * @param {object} manifest Parsed manifest.
 * @param {object} labels Label helpers.
 */
function validatePage(id, page, manifest, labels) {
	if (!isPlainObject(page)) throw new Error(`[onboarding.pages.${id}] is missing`);
	for (const field of Object.keys(page)) {
		if (!PAGE_FIELDS.has(field))
			throw new Error(`[onboarding.pages.${id}] has unknown field ${field}`);
	}
	if (!manifest.scopes[id] || id === 'global')
		throw new Error(`onboarding page ${id} is not a scope`);
	if (!CHECKLIST_KINDS.includes(page.checklist)) {
		throw new Error(
			`[onboarding.pages.${id}] checklist must be one of ${CHECKLIST_KINDS.join(', ')}`
		);
	}
	for (const field of ['title_key', 'question_key', 'description_key']) {
		if (typeof page[field] !== 'string') throw new Error(`[onboarding.pages.${id}] needs ${field}`);
		labels.requireKey(page[field], `onboarding page ${id}`);
	}
	for (const field of ['master', 'hint_key', 'note_key', 'file_path', 'section_path']) {
		if (page[field] === undefined) continue;
		if (!isPlainObject(page[field]))
			throw new Error(`[onboarding.pages.${id}] ${field} must be per platform`);
		for (const platform of Object.keys(page[field])) {
			if (!MANIFEST_PLATFORMS.includes(platform)) {
				throw new Error(`[onboarding.pages.${id}] ${field} names unknown platform ${platform}`);
			}
		}
	}
	if (page.consent !== undefined && page.consent !== true) {
		throw new Error(`[onboarding.pages.${id}] consent is either true or absent`);
	}
	if (page.consent && page.checklist !== 'none') {
		throw new Error(`[onboarding.pages.${id}] a consent page imports nothing else`);
	}
}

/**
 * The page's category switch on one platform, or null.
 * @param {string} id Page id.
 * @param {object} page Declaration.
 * @param {string} platform Manifest platform token.
 * @param {object} projection Manifest projection.
 * @returns {object|null} Master descriptor.
 */
function masterFor(id, page, platform, projection) {
	const masterPath = page.master && page.master[platform];
	if (masterPath === undefined) return null;
	const values = projection.project(masterPath, platform);
	if (values.default !== false || typeof values.recommended !== 'boolean') {
		throw new Error(
			`onboarding page ${id}: ${masterPath} must be a boolean whose neutral value is false`
		);
	}
	if (projection.scopeOf(masterPath) !== id) {
		throw new Error(`onboarding page ${id}: ${masterPath} belongs to another scope`);
	}
	if (page.consent && values.recommended !== true) {
		// A consent switch is still recommended by the manifest; the wizard alone
		// decides never to pre-select it.
		throw new Error(`onboarding page ${id}: ${masterPath} must carry the manifest recommendation`);
	}
	return { path: masterPath, default: false };
}

/**
 * The recommended checklist: every input-altering feature of the scope, on the
 * platform, whose recommendation differs from its neutral default.
 * @returns {object[]} One unlabelled group, or none.
 */
function recommendedItems(id, page, platform, master, features, projection, labels, usedOverrides) {
	const excluded = page.exclude || [];
	const overrides = page.labels || {};
	for (const [itemPath, key] of Object.entries(overrides)) {
		labels.requireKey(key, `onboarding page ${id} label for ${itemPath}`);
	}
	const items = [];
	for (const feature of features.values()) {
		if (projection.scopeOf(feature.path) !== id) continue;
		if (!feature.platforms.includes(platform) || feature.input_altering !== true) continue;
		if (excluded.some((prefix) => feature.path === prefix || feature.path.startsWith(prefix + '.')))
			continue;
		const itemPath = feature.type === 'feature' ? `${feature.path}.enabled` : feature.path;
		if (master && itemPath === master.path) continue;
		const values = projection.project(itemPath, platform);
		if (sameValue(values.default, values.recommended)) continue;
		const context = `onboarding page ${id} item ${itemPath}`;
		let label;
		if (Object.hasOwn(overrides, itemPath)) {
			label = [{ key: overrides[itemPath] }];
			usedOverrides.add(itemPath);
		} else if (feature.type === 'action' && feature.section === 'shortcuts.keyboard') {
			label = chordSegments(feature.id, labels);
			if (!label) label = [{ key: labels.featureLabelKey(feature, context) }];
		} else {
			label = [{ key: labels.featureLabelKey(feature, context) }];
		}
		const item = {
			path: itemPath,
			value: values.recommended,
			default: values.default,
			recommended: true,
			label
		};
		if (feature.type === 'action')
			item.value_label = { key: labels.actionLabelKey(values.recommended, context) };
		items.push(item);
	}
	return items.length > 0 ? [{ items }] : [];
}

/**
 * Loads the hotstring index: the neutral categories, then each language pack.
 * @returns {object[]} Ordered languages { id, locale|null, files: [{stem, group, file}] }.
 */
function loadHotstringLanguages() {
	const index = TOML.parse(fs.readFileSync(path.join(HOTSTRINGS_DIR, '_index.toml'), 'utf8'));
	const root = index.menu && index.menu.categories_order;
	if (!Array.isArray(root) || root.length === 0)
		throw new Error('_index.toml needs [menu] categories_order');
	const languages = [{ id: null, locale: null, files: root.map((stem) => ({ stem, dir: '' })) }];
	const packs = index.languages || { order: [] };
	for (const id of packs.order) {
		const pack = packs[id];
		if (
			!isPlainObject(pack) ||
			typeof pack.locale !== 'string' ||
			!Array.isArray(pack.categories_order)
		) {
			throw new Error(`_index.toml language ${id} needs a locale and categories_order`);
		}
		languages.push({
			id,
			locale: pack.locale,
			files: pack.categories_order.map((stem) => ({ stem, dir: id }))
		});
	}
	return languages;
}

/**
 * The hotstring checklist: language → file → section, each file gated by its
 * category switch and each section by its own manifest path.
 * @returns {object[]} Language groups.
 */
function hotstringGroups(id, page, platform, manifest, features, projection, labels) {
	const filePattern = page.file_path && page.file_path[platform];
	const sectionPattern = page.section_path && page.section_path[platform];
	if (!filePattern || !sectionPattern)
		throw new Error(`onboarding page ${id} has no hotstring paths for ${platform}`);
	labels.requireKey(page.neutral_label_key, `onboarding page ${id}`);
	const localeNames = JSON.parse(fs.readFileSync(LOCALE_NAMES_PATH, 'utf8')).locales;
	const flatten = (value) => value.split('_').join('');
	const manifestGroups = manifest.sections.hotstrings.subsections;
	const groups = [];
	for (const language of loadHotstringLanguages()) {
		const languageGroup = { select_all: true, groups: [] };
		if (language.locale === null) {
			languageGroup.label = [{ key: page.neutral_label_key }];
		} else {
			const names = localeNames[language.locale];
			if (!names)
				throw new Error(
					`hotstring language ${language.id} names unknown locale ${language.locale}`
				);
			languageGroup.label = [{ text: `${names.flag} ${names.name}` }];
		}
		for (const file of language.files) {
			const stem = language.id === null ? file.stem : `${language.id}_${file.stem}`;
			const group = manifestGroups.find((candidate) => flatten(candidate) === flatten(stem));
			if (!group) throw new Error(`hotstring file ${stem} has no manifest section`);
			const relative =
				language.id === null ? `${file.stem}.toml` : `${language.id}/${file.stem}.toml`;
			const source = TOML.parse(fs.readFileSync(path.join(HOTSTRINGS_DIR, relative), 'utf8'));
			const meta = source._meta;
			if (
				!isPlainObject(meta) ||
				!Array.isArray(meta.sections_order) ||
				!isPlainObject(meta.sections)
			) {
				throw new Error(`${relative} needs _meta.sections_order and _meta.sections`);
			}
			const fill = (pattern, section) =>
				pattern
					.replace('{group}', group)
					.replace('{stem}', stem)
					.replace('{section}', section || '');
			const gatePath = fill(filePattern);
			const gate = projection.project(gatePath, platform);
			if (gate.default !== false) throw new Error(`${gatePath} must default to false`);
			const fileGroup = {
				path: gatePath,
				value: true,
				default: false,
				label: [labels.localizedText(meta.description, `hotstrings/${relative}`)],
				items: []
			};
			for (const section of meta.sections_order) {
				if (section === SECTION_SEPARATOR) continue;
				if (!Object.hasOwn(meta.sections, section))
					throw new Error(`${relative} has no description for ${section}`);
				const sectionPath = fill(sectionPattern, section);
				const values = projection.project(sectionPath, platform);
				if (values.default !== false) throw new Error(`${sectionPath} must default to false`);
				// The section's own manifest row decides its recommendation on every
				// platform, whatever path the platform persists it under.
				const canonical = projection.project(`hotstrings.${group}.${section}.enabled`, platform);
				fileGroup.items.push({
					path: sectionPath,
					value: true,
					default: false,
					recommended: canonical.recommended === true,
					label: [labels.localizedText(meta.sections[section], `hotstrings/${relative}#${section}`)]
				});
			}
			languageGroup.groups.push(fileGroup);
		}
		groups.push(languageGroup);
	}
	return groups;
}

/**
 * The hotstring trigger character choice.
 * @returns {object} Choice descriptor.
 */
function magicKeyFor(id, page, platform, projection, labels) {
	const choice = page.magic_key;
	if (!isPlainObject(choice) || typeof choice.path !== 'string' || !Array.isArray(choice.options)) {
		throw new Error(`[onboarding.pages.${id}.magic_key] needs a path and options`);
	}
	const values = projection.project(choice.path, platform);
	if (typeof values.default !== 'string' || values.default === '') {
		throw new Error(`${choice.path} must default to a character`);
	}
	const options = choice.options.map((option) => {
		if (typeof option.value !== 'string' || option.value === '')
			throw new Error(`${choice.path} option needs a value`);
		return { value: option.value, label_key: labels.requireKey(option.label_key, choice.path) };
	});
	if (!options.some((option) => option.value === values.default)) {
		throw new Error(`${choice.path} options must include its default ${values.default}`);
	}
	return {
		path: choice.path,
		default: values.default,
		recommended: values.recommended,
		label_key: labels.requireKey(choice.label_key, choice.path),
		hint_key: labels.requireKey(choice.hint_key, choice.path),
		custom_label_key: labels.requireKey(choice.custom_label_key, choice.path),
		options
	};
}

/**
 * Builds one page for one platform.
 * @returns {object} Page descriptor.
 */
function buildPage(id, page, platform, manifest, features, projection, labels, usedOverrides) {
	const master = masterFor(id, page, platform, projection);
	let groups = [];
	if (page.checklist === 'recommended') {
		groups = recommendedItems(
			id,
			page,
			platform,
			master,
			features,
			projection,
			labels,
			usedOverrides
		);
	} else if (page.checklist === 'hotstrings') {
		groups = hotstringGroups(id, page, platform, manifest, features, projection, labels);
	}
	const hint = page.hint_key && page.hint_key[platform];
	const note = page.note_key && page.note_key[platform];
	if (hint) labels.requireKey(hint, `onboarding page ${id}`);
	if (note) labels.requireKey(note, `onboarding page ${id}`);
	if (!master && groups.length === 0 && !note) {
		throw new Error(`onboarding page ${id} asks nothing on ${platform}: declare a note_key`);
	}
	// Absent fields are omitted, never null: the Lua hosts' JSON reader turns a
	// null into a table, which would read as a present value.
	const built = {
		id,
		title_key: page.title_key,
		question_key: page.question_key,
		description_key: page.description_key,
		consent: page.consent === true,
		groups
	};
	if (master) built.master = master;
	if (hint) built.hint_key = hint;
	if (note) built.note_key = note;
	if (page.checklist === 'hotstrings')
		built.magic_key = magicKeyFor(id, page, platform, projection, labels);
	return built;
}

/**
 * Builds the complete catalogue.
 * @returns {object} Catalogue.
 */
function buildCatalogue() {
	const manifest = loadManifest();
	const features = indexFeatures(manifest);
	const projection = createProjection(features, manifest.scopes);
	const labels = createLabels(loadLocales());
	const order = manifest.onboarding.order;
	if (!Array.isArray(order) || order.length === 0) throw new Error('[onboarding] needs an order');
	const declared = Object.keys(manifest.onboarding.pages || {});
	for (const id of declared) {
		if (!order.includes(id))
			throw new Error(`[onboarding.pages.${id}] is not in [onboarding] order`);
	}
	for (const id of order) validatePage(id, (manifest.onboarding.pages || {})[id], manifest, labels);
	const scopes = Object.keys(manifest.scopes).filter((scope) => scope !== 'global');
	for (const scope of scopes) {
		if (!order.includes(scope))
			throw new Error(`configuration scope ${scope} has no onboarding page`);
	}
	const platforms = {};
	const usedOverrides = new Set();
	for (const [driver, platform] of Object.entries(DRIVERS)) {
		platforms[driver] = {
			manifest_platform: platform,
			pages: order.map((id) =>
				buildPage(
					id,
					manifest.onboarding.pages[id],
					platform,
					manifest,
					features,
					projection,
					labels,
					usedOverrides
				)
			)
		};
	}
	// One answer per path: two rows writing one key would race in the batch.
	for (const [driver, data] of Object.entries(platforms)) {
		const seen = new Set();
		const claim = (entryPath) => {
			if (seen.has(entryPath))
				throw new Error(`${driver}: ${entryPath} is written by two wizard rows`);
			seen.add(entryPath);
		};
		for (const page of data.pages) {
			if (page.master) claim(page.master.path);
			if (page.magic_key) claim(page.magic_key.path);
			(function walk(groups) {
				for (const group of groups) {
					if (group.path) claim(group.path);
					for (const item of group.items || []) claim(item.path);
					walk(group.groups || []);
				}
			})(page.groups);
		}
	}
	(function refuseNull(value, where) {
		if (value === null) throw new Error(`the catalogue carries a null at ${where}`);
		if (typeof value === 'object') {
			for (const [key, child] of Object.entries(value)) refuseNull(child, `${where}.${key}`);
		}
	})(platforms, 'platforms');
	// A label kept for an item no platform lists outlives the gap it filled.
	for (const id of order) {
		for (const itemPath of Object.keys(manifest.onboarding.pages[id].labels || {})) {
			if (!usedOverrides.has(itemPath)) {
				throw new Error(`[onboarding.pages.${id}.labels] ${itemPath} labels no checklist item`);
			}
		}
	}
	return { schema_version: SCHEMA_VERSION, order, texts: labels.texts, platforms };
}

// ==========================================
// ==========================================
// ======= 5/ Emitters ======================
// ==========================================
// ==========================================

/**
 * The page's classic data script.
 * @param {object} catalogue Catalogue.
 * @returns {string} Script source.
 */
function emitPage(catalogue) {
	const literal = JSON.stringify(catalogue, null, '\t').replace(/\n/g, '\n\t');
	return [
		'// _shared/ui/_generated/onboarding_catalogue.js',
		'',
		'// ==========================================',
		'// AUTO-GENERATED — do not edit manually',
		`// Source: ${sharedRel('modules', 'features', 'manifest.toml')} [onboarding]`,
		`// Run: ${RUN_HINT}`,
		'// ==========================================',
		'',
		'// The first-run wizard pages as page data. A page cannot read the manifest,',
		'// so it loads this script before script.js, which renders it.',
		'(function (global) {',
		"\t'use strict';",
		'',
		`\tglobal.ONBOARDING_CATALOGUE = ${literal};`,
		'})(window);',
		''
	].join('\n');
}

/**
 * Writes a file only when its content changed.
 * @param {string} file Absolute path.
 * @param {string} content Content.
 */
function write(file, content) {
	fs.mkdirSync(path.dirname(file), { recursive: true });
	const current = fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null;
	if (current === content) {
		console.log(`unchanged ${path.relative(process.cwd(), file)}`);
		return;
	}
	fs.writeFileSync(file, content);
	console.log(`wrote ${path.relative(process.cwd(), file)}`);
}

if (require.main === module) {
	const catalogue = buildCatalogue();
	write(PAGE_OUTPUT, emitPage(catalogue));
	write(HOST_OUTPUT, JSON.stringify(catalogue, null, '\t') + '\n');
}

module.exports = { buildCatalogue, DRIVERS, SCHEMA_VERSION };
