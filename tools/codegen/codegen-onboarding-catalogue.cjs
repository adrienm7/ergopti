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
 *   _shared/tap_hold/defaults.toml           tap-hold keys and each engine's preset
 *   _shared/modules/actions/actions.toml     [karabiner_aliases] of the macOS tap-hold actions
 *   macos/platform/remap/data/actions.json   macOS tap-hold action labels without a locale key
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
 *    manifest. Hosts write what the page emits without interpreting it. The
 *    one exception is a tap-hold key (`tap_hold_key`): its host imports that
 *    key's shipped recommendation through its own tap-hold writer, because no
 *    driver keeps its keys in config.toml.
 * 2. Labels are locale keys the drivers already use, resolved through the tray
 *    menu's candidate chain; an item whose label exists in no locale stops the
 *    generation instead of shipping a raw identifier.
 * 3. An item that binds an action names its trigger (a chord, a gesture, a
 *    tap-hold key) and the action apart, so the page draws one separator
 *    between them: VALUE_SEPARATOR, which no label may contain.
 * 4. Deterministic: manifest and file order, no timestamp.
 *
 * USAGE:  node tools/codegen/codegen-onboarding-catalogue.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const TOML = require('smol-toml');
const { REPO_ROOT, shared, sharedRel } = require('../lib/paths.cjs');
const { candidateKeys } = require('../lib/manifest-label-keys.cjs');

const MANIFEST_PATH = shared('modules', 'features', 'manifest.toml');
const HOTSTRINGS_DIR = shared('modules', 'hotstrings');
// The Ergopti layout extension every driver ships and counts as installed. Its
// manifest binds the Ergopti-only hotstring files (SFB reduction, rolls, the
// magic key's repeat corrections) to their historical categories and sections.
const ERGOPTI_EXTENSION_DIR = path.join(REPO_ROOT, 'static', 'layouts', 'registry', 'ergopti');
const TAP_HOLD_DEFAULTS_PATH = shared('tap_hold', 'defaults.toml');
const ACTIONS_PATH = shared('modules', 'actions', 'actions.toml');
const MACOS_REMAP_ACTIONS_PATH = path.join(
	REPO_ROOT,
	'static',
	'ergopti_plus',
	'macos',
	'platform',
	'remap',
	'data',
	'actions.json'
);
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

const CHECKLIST_KINDS = ['recommended', 'hotstrings', 'tap_holds', 'none'];
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
	'magic_key',
	'sub_switch',
	'state',
	'triggers',
	'settings',
	'settings_label_key'
]);

// What the page draws between an item's trigger and the action it imports. No
// label may contain it, nor the "%s" of a tray label that spells its own
// separator, so trigger and action always read apart.
const VALUE_SEPARATOR = '➔';
const LABEL_PLACEHOLDER = '%s';

// The page template joining a tap-hold key's tap and hold, as {1} and {2}.
const TAP_HOLD_ASSIGNMENT_KEY = 'onboarding.checklist.tap_hold';

// The separator a hotstring file writes between groups of its sections_order.
const SECTION_SEPARATOR = '-';

// The answer path of a tap-hold key the wizard imports. It names no
// configuration key: every host hands these answers to its own tap-hold writer
// and never to config.toml, so the prefix stays outside every manifest path.
const TAP_HOLD_KEY_PREFIX = 'tap_holds.keys.';

// The value a host reports for a tap-hold key that holds a setting other than
// the recommendation. The page shows such a key as kept and never imports it:
// the wizard only adds keys, it never overwrites one the user configured.
const TAP_HOLD_CUSTOMISED = 'customised';

// The keys each engine ships a recommendation for: Windows and Linux read the
// [tap_hold.keys.*] preset, macOS its own Karabiner slots, where a key whose
// tap and hold are both "none" has none.
const TAP_HOLD_PRESETS = {
	ahk: (defaults) => Object.keys((defaults.tap_hold && defaults.tap_hold.keys) || {}),
	linux: (defaults) => Object.keys((defaults.tap_hold && defaults.tap_hold.keys) || {}),
	hs: (defaults) =>
		Object.entries(defaults.hs_tap_hold || {})
			.filter(
				([, slots]) => isPlainObject(slots) && (slots.tap !== 'none' || slots.hold !== 'none')
			)
			.map(([key]) => key)
};

// The tray's hand headers, which the page reuses for its two key groups.
const TAP_HOLD_HAND_LABELS = {
	left: 'menu.tapholds.left_hand_tap_hold',
	right: 'menu.tapholds.right_hand_tap_hold'
};

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

	/** Whether the canonical locale translates the key. */
	function hasKey(key) {
		const value = locales.get('en')[key];
		return typeof value === 'string' && value !== '';
	}

	/** Every translation of a key, for checks over what the page will show. */
	function translations(key) {
		return codes.map((code) => locales.get(code)[key]);
	}

	/** The picker label of an action identifier used as a slot value. */
	function actionLabelKey(action, context) {
		const en = locales.get('en');
		for (const key of [`sg_actions.${action}`, `ax_actions.${action}`]) {
			if (typeof en[key] === 'string') return requireKey(key, context);
		}
		throw new Error(`${context}: action ${action} has no picker label`);
	}

	return {
		requireKey,
		hasKey,
		translations,
		featureLabelKey,
		localizedText,
		actionLabelKey,
		codes,
		texts
	};
}

// Keyboard-slot and built-in shortcut ids spell their chord: a modifier prefix,
// then the key, formatted as each tray prints them: the Windows slots
// (windows/infra/config_io.ahk _FormatSlotLabel), the macOS Shortcuts menu
// (macos/ui/menu/menu_shortcuts.lua pretty_key) and the Linux slot prefixes
// (linux/modules/shortcuts/keyboard_shortcuts.lua SLOT_MODS). Longest prefix
// first; only named keys translate.
const CHORD_PREFIXES = {
	ahk: [
		['ctrl_shift_', 'Ctrl + Shift + '],
		['ctrl_', 'Ctrl + '],
		['win_', 'Win + '],
		['alt_', 'Alt + ']
	],
	hs: [
		['hs_ctrl_shift_', 'Ctrl + Shift + '],
		['hs_ctrl_', 'Ctrl + '],
		['hs_option_', 'Option + '],
		['cmd_shift_', 'Cmd + Shift + '],
		['cmd_', 'Cmd + '],
		['ctrl_', 'Ctrl + ']
	],
	linux: [
		['ctrl_shift_', 'Ctrl + Shift + '],
		['super_shift_', 'Super + Shift + '],
		['alt_shift_', 'Alt + Shift + '],
		['ctrl_', 'Ctrl + '],
		['super_', 'Super + '],
		['alt_', 'Alt + ']
	]
};
const CHORD_KEY_NAMES = { space: 'common.key_space', enter: 'common.key_enter' };
const CHORD_KEY_GLYPHS = { period: '.', comma: ',', quote: "'", sc029: '²', capslock: 'CapsLock' };
// The key the macOS Cmd + star shortcut names: the hotstring trigger character.
const CHORD_TRIGGER_KEY = 'star';
const TRIGGER_CHARACTER_PATH = 'hotstrings.trigger_char';

// The manifest sections whose ids spell a chord: the keyboard slots, whose
// value is the action they run, and the macOS built-in shortcuts, whose label
// is the action their chord runs.
const SLOT_SECTION = 'shortcuts.keyboard';
// A key-combination slot is named by its two keys, the one held first then the
// one struck under it, as the Shortcuts menu lists the pair.
const COMBINATION_SECTION = 'shortcuts.key_combination_taps';
const COMBINATION_SEPARATOR = '_then_';
const BUILT_IN_SHORTCUT_SECTION = 'shortcuts.keys';

/**
 * Label segments of a key-combination slot: its two tap-hold keys, each under
 * the name the Tap-Hold menu gives it.
 * @param {string} slot Id such as alt_gr_then_left_alt.
 * @param {object} labels Label helpers.
 * @param {string} context Error context.
 * @returns {object[]} Segments.
 */
function combinationSegments(slot, labels, context) {
	const keys = slot.split(COMBINATION_SEPARATOR);
	if (keys.length !== 2 || keys.some((key) => key === '')) {
		throw new Error(`${context}: ${slot} names no pair of tap-hold keys`);
	}
	return [
		{ key: labels.requireKey(`tap_hold.group.${keys[0]}`, context) },
		{ text: ' + ' },
		{ key: labels.requireKey(`tap_hold.group.${keys[1]}`, context) }
	];
}

/**
 * Label segments of a keyboard slot or built-in shortcut id on one platform,
 * or null when the id spells no chord.
 * @param {string} slot Id such as win_a or cmd_shift_v.
 * @param {string} platform Manifest platform token.
 * @param {object} labels Label helpers.
 * @param {function(): string} triggerCharacter The platform's default trigger.
 * @returns {object[]|null} Segments.
 */
function chordSegments(slot, platform, labels, triggerCharacter) {
	for (const [prefix, text] of CHORD_PREFIXES[platform]) {
		if (!slot.startsWith(prefix)) continue;
		const key = slot.slice(prefix.length);
		if (key === '') return null;
		if (Object.hasOwn(CHORD_KEY_NAMES, key)) {
			return [{ text }, { key: labels.requireKey(CHORD_KEY_NAMES[key], slot) }];
		}
		if (key === CHORD_TRIGGER_KEY) return [{ text: text + triggerCharacter() }];
		return [{ text: text + (CHORD_KEY_GLYPHS[key] || key.toUpperCase()) }];
	}
	return null;
}

/**
 * Refuses a checklist label that could not read apart from the separator the
 * page draws between a trigger and its action: one containing the separator
 * itself, or a tray template's "%s" that spells its own. A template segment
 * must fill each of its arguments.
 * @param {object} platforms Built platforms.
 * @param {object} labels Label helpers.
 */
function refuseSeparatorsInLabels(platforms, labels) {
	const refuse = (text, where) => {
		for (const needle of [VALUE_SEPARATOR, LABEL_PLACEHOLDER]) {
			if (text.includes(needle)) throw new Error(`${where} shows "${needle}": ${text}`);
		}
	};
	const walkSegments = (segments, where) => {
		for (const segment of segments) {
			if (typeof segment.key === 'string') {
				labels.translations(segment.key).forEach((text) => refuse(text, `${where} ${segment.key}`));
			} else if (typeof segment.text === 'string') {
				refuse(segment.text, where);
			} else if (typeof segment.text_ref === 'string') {
				Object.values(labels.texts[segment.text_ref]).forEach((text) => refuse(text, where));
			} else if (typeof segment.template === 'string') {
				for (const text of labels.translations(segment.template)) {
					refuse(text, `${where} ${segment.template}`);
					segment.args.forEach((_arg, index) => {
						if (!text.includes(`{${index + 1}}`)) {
							throw new Error(`${where} ${segment.template} does not show {${index + 1}}: ${text}`);
						}
					});
				}
				segment.args.forEach((arg) => walkSegments(arg, where));
			} else {
				throw new Error(`${where} has an unknown label segment`);
			}
		}
	};
	for (const [driver, data] of Object.entries(platforms)) {
		for (const page of data.pages) {
			(function walk(groups) {
				for (const group of groups) {
					if (group.label) walkSegments(group.label, `${driver}/${page.id}`);
					for (const item of group.items || []) {
						walkSegments(item.label, `${driver}/${item.path}`);
						if (item.value_label) walkSegments(item.value_label, `${driver}/${item.path}`);
					}
					walk(group.groups || []);
				}
			})(page.groups);
		}
	}
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
	for (const field of [
		'master',
		'hint_key',
		'note_key',
		'file_path',
		'section_path',
		'sub_switch',
		'state'
	]) {
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
	if (page.checklist === 'tap_holds' && id !== 'tap_holds') {
		throw new Error(`[onboarding.pages.${id}] only the tap_holds page lists tap-hold keys`);
	}
	if (page.settings !== undefined) {
		if (!isPlainObject(page.settings) || Object.keys(page.settings).length === 0) {
			throw new Error(`[onboarding.pages.${id}] settings maps setting paths to label keys`);
		}
		if (typeof page.settings_label_key !== 'string')
			throw new Error(`[onboarding.pages.${id}] settings need a settings_label_key`);
		labels.requireKey(page.settings_label_key, `onboarding page ${id} settings`);
		for (const [settingPath, key] of Object.entries(page.settings)) {
			labels.requireKey(key, `onboarding page ${id} setting ${settingPath}`);
		}
	} else if (page.settings_label_key !== undefined) {
		throw new Error(`[onboarding.pages.${id}] settings_label_key names no settings`);
	}
}

/**
 * The recommended settings a page imports besides its own checklist: one
 * labelled group of the listed paths declared on the platform whose
 * recommendation differs from their neutral default. The hotstrings page lists
 * its hotstring groups, and without this the preview bubbles, which only show
 * what a hotstring will type, stayed off on every fresh configuration.
 * @param {string} id Page id.
 * @param {object} page Declaration.
 * @param {string} platform Manifest platform token.
 * @param {object} features Indexed manifest features.
 * @param {object} projection Value projection.
 * @returns {object[]} One labelled group, or none.
 */
function settingsGroups(id, page, platform, features, projection) {
	if (page.settings === undefined) return [];
	const items = [];
	for (const [settingPath, key] of Object.entries(page.settings)) {
		const feature = features.get(settingPath);
		if (!feature)
			throw new Error(`onboarding page ${id} setting ${settingPath} is not a manifest feature`);
		if (projection.scopeOf(settingPath) !== id) {
			throw new Error(`onboarding page ${id} setting ${settingPath} belongs to another scope`);
		}
		if (!feature.platforms.includes(platform)) continue;
		const values = projection.project(settingPath, platform);
		if (sameValue(values.default, values.recommended)) {
			throw new Error(
				`onboarding page ${id} setting ${settingPath} recommends its neutral default`
			);
		}
		items.push({
			path: settingPath,
			value: values.recommended,
			default: values.default,
			recommended: true,
			label: [{ key }]
		});
	}
	return items.length > 0
		? [{ label: [{ key: page.settings_label_key }], select_all: true, items }]
		: [];
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
 * The page's sub-switch on one platform, or null: the switch of part of the
 * checklist that the category switch does not reach. The page writes it where
 * the answer changes what is in force, off when it turns the category switch
 * from Yes to No and on when it imports one of its items that was off, so those
 * items follow the answer as they did when the category switch reached them.
 * @param {string} id Page id.
 * @param {object} page Declaration.
 * @param {string} platform Manifest platform token.
 * @param {object|null} master The page's category switch on the platform.
 * @param {object[]} groups The page's checklist on the platform.
 * @param {object} manifest Parsed manifest.
 * @param {object} projection Manifest projection.
 * @returns {object|null} Sub-switch descriptor.
 */
function subSwitchFor(id, page, platform, master, groups, manifest, projection) {
	const declared = page.sub_switch && page.sub_switch[platform];
	if (declared === undefined) return null;
	if (
		!isPlainObject(declared) ||
		typeof declared.path !== 'string' ||
		!Array.isArray(declared.sections) ||
		declared.sections.length === 0 ||
		declared.sections.some((section) => typeof section !== 'string' || section === '')
	) {
		throw new Error(`[onboarding.pages.${id}] sub_switch needs a path and its sections`);
	}
	if (!master) {
		throw new Error(`onboarding page ${id}: a sub-switch needs the category switch on ${platform}`);
	}
	const values = projection.project(declared.path, platform);
	if (typeof values.default !== 'boolean') {
		throw new Error(`onboarding page ${id}: ${declared.path} must be a boolean`);
	}
	if (projection.scopeOf(declared.path) !== id) {
		throw new Error(`onboarding page ${id}: ${declared.path} belongs to another scope`);
	}
	const sections = declared.sections;
	for (const section of sections) {
		const known =
			manifest.sections &&
			section.split('.').reduce((node, part) => node && node[part], manifest.sections);
		if (!isPlainObject(known)) {
			throw new Error(`onboarding page ${id}: sub_switch names no feature section ${section}`);
		}
	}
	const itemPaths = [];
	(function walk(list) {
		for (const group of list) {
			(group.items || []).forEach((item) => itemPaths.push(item.path));
			walk(group.groups || []);
		}
	})(groups);
	const items = [];
	for (const section of sections) {
		const governed = itemPaths.filter((itemPath) => itemPath.startsWith(section + '.'));
		// A section the page cannot import could never turn the switch back on.
		if (governed.length === 0) {
			throw new Error(`onboarding page ${id}: ${section} has no checklist item on ${platform}`);
		}
		items.push(...governed);
	}
	return { path: declared.path, default: values.default, items };
}

/**
 * The page's state on one platform, or null: on a platform without a category
 * switch in config.toml, the switch its host reads from its own file so the
 * question starts from what is in force. The page never writes it.
 * @param {string} id Page id.
 * @param {object} page Declaration.
 * @param {string} platform Manifest platform token.
 * @param {object|null} master The page's category switch on the platform.
 * @param {object} projection Manifest projection.
 * @returns {object|null} State descriptor.
 */
function stateFor(id, page, platform, master, projection) {
	const statePath = page.state && page.state[platform];
	if (statePath === undefined) return null;
	if (master) {
		throw new Error(
			`onboarding page ${id}: ${platform} asks through a category switch, not a state`
		);
	}
	const values = projection.project(statePath, platform);
	if (typeof values.default !== 'boolean') {
		throw new Error(`onboarding page ${id}: ${statePath} must be a boolean`);
	}
	if (projection.scopeOf(statePath) !== id) {
		throw new Error(`onboarding page ${id}: ${statePath} belongs to another scope`);
	}
	return { path: statePath, default: values.default };
}

/**
 * The recommended checklist: every input-altering feature of the scope, on the
 * platform, whose recommendation differs from its neutral default. An item that
 * binds an action is labelled by its trigger and carries the action apart, as
 * its value_label.
 * @returns {object[]} One unlabelled group, or none.
 */
function recommendedItems(id, page, platform, master, features, projection, labels, usedOverrides) {
	const excluded = page.exclude || [];
	const overrides = page.labels || {};
	const triggers = page.triggers || {};
	for (const [itemPath, key] of Object.entries(overrides)) {
		labels.requireKey(key, `onboarding page ${id} label for ${itemPath}`);
	}
	for (const [itemPath, key] of Object.entries(triggers)) {
		labels.requireKey(key, `onboarding page ${id} trigger for ${itemPath}`);
	}
	const triggerCharacter = () => {
		const character = projection.project(TRIGGER_CHARACTER_PATH, platform).default;
		if (typeof character !== 'string' || character === '') {
			throw new Error(`${TRIGGER_CHARACTER_PATH} has no default character on ${platform}`);
		}
		return character;
	};
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
		let action = null;
		if (Object.hasOwn(overrides, itemPath)) {
			label = [{ key: overrides[itemPath] }];
			usedOverrides.add(itemPath);
		} else if (feature.type === 'action' && feature.section === SLOT_SECTION) {
			label = chordSegments(feature.id, platform, labels, triggerCharacter);
			if (!label) label = [{ key: labels.featureLabelKey(feature, context) }];
		} else if (feature.type === 'action' && feature.section === COMBINATION_SECTION) {
			label = combinationSegments(feature.id, labels, context);
		} else if (feature.section === BUILT_IN_SHORTCUT_SECTION) {
			// The label names what the shortcut does, so its trigger comes first.
			if (Object.hasOwn(triggers, itemPath)) {
				label = [{ key: triggers[itemPath] }];
				usedOverrides.add(itemPath);
			} else {
				label = chordSegments(feature.id, platform, labels, triggerCharacter);
			}
			if (!label) {
				throw new Error(
					`${context}: its id spells no chord; name its trigger in [onboarding.pages.${id}.triggers]`
				);
			}
			action = [{ key: labels.featureLabelKey(feature, context) }];
		} else {
			label = [{ key: labels.featureLabelKey(feature, context) }];
		}
		if (feature.type === 'action') {
			action = [{ key: labels.actionLabelKey(values.recommended, context) }];
		}
		const item = {
			path: itemPath,
			value: values.recommended,
			default: values.default,
			recommended: true,
			label
		};
		if (action) item.value_label = action;
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
	const neutral = root.map((stem) => ({ stem, dir: '' }));
	// A whole file bound to its own category is still that language-neutral
	// category, read from the extension instead of the bundled folder.
	for (const [stem, binding] of Object.entries(loadExtensionBindings())) {
		if (binding.sections === undefined && binding.category === stem)
			neutral.push({ stem, dir: '', extension: true });
	}
	const languages = [{ id: null, locale: null, files: neutral }];
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
 * The hotstring bindings of the shipped Ergopti extension, keyed by file stem.
 * @returns {object} stem → { category, sections? }.
 */
function loadExtensionBindings() {
	const text = fs.readFileSync(path.join(ERGOPTI_EXTENSION_DIR, 'manifest.toml'), 'utf8');
	const extension = TOML.parse(text).extension;
	const bindings = (isPlainObject(extension) && extension.hotstring_bindings) || {};
	for (const [stem, binding] of Object.entries(bindings)) {
		if (
			!isPlainObject(binding) ||
			typeof binding.category !== 'string' ||
			(binding.sections !== undefined && !Array.isArray(binding.sections))
		) {
			throw new Error(
				`the Ergopti extension binding ${stem} needs a category and optional sections`
			);
		}
	}
	return bindings;
}

/**
 * Reads one hotstring file's _meta, from the bundled folder or the extension.
 * @param {string} relative Path under the bundled hotstrings folder.
 * @param {boolean} extension True for a file the Ergopti extension carries.
 * @returns {{meta: object, origin: string}} Its _meta and a label origin.
 */
function readHotstringMeta(relative, extension) {
	const file = extension
		? path.join(ERGOPTI_EXTENSION_DIR, 'hotstrings', relative)
		: path.join(HOTSTRINGS_DIR, relative);
	const meta = TOML.parse(fs.readFileSync(file, 'utf8'))._meta;
	if (
		!isPlainObject(meta) ||
		!Array.isArray(meta.sections_order) ||
		!isPlainObject(meta.sections)
	) {
		throw new Error(`${relative} needs _meta.sections_order and _meta.sections`);
	}
	return {
		meta,
		origin: extension ? `layouts/registry/ergopti/hotstrings/${relative}` : `hotstrings/${relative}`
	};
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
	// A section a category keeps in its order but whose rules the Ergopti
	// extension carries (repeat_corrections of magickey) takes its description
	// from the bound file.
	const boundSections = new Map();
	for (const [stem, binding] of Object.entries(loadExtensionBindings())) {
		for (const section of binding.sections || []) {
			boundSections.set(`${binding.category}.${section}`, readHotstringMeta(`${stem}.toml`, true));
		}
	}
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
			const { meta, origin } = readHotstringMeta(relative, file.extension === true);
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
				label: [labels.localizedText(meta.description, origin)],
				items: []
			};
			for (const section of meta.sections_order) {
				if (section === SECTION_SEPARATOR) continue;
				let described = { meta, origin };
				if (!Object.hasOwn(meta.sections, section) && boundSections.has(`${stem}.${section}`))
					described = boundSections.get(`${stem}.${section}`);
				if (!Object.hasOwn(described.meta.sections, section))
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
					label: [
						labels.localizedText(described.meta.sections[section], `${described.origin}#${section}`)
					]
				});
			}
			languageGroup.groups.push(fileGroup);
		}
		groups.push(languageGroup);
	}
	return groups;
}

/**
 * Creates the resolver of macOS tap-hold action labels, named as its tray
 * names them (macos/platform/remap/config.lua localise_action_labels): the
 * action registry's label under the action's Karabiner alias, else the
 * Karabiner catalogue's own short label.
 * @param {object} labels Label helpers.
 * @returns {function(string, string): object[]} Action id, context → segments.
 */
function createKarabinerLabels(labels) {
	const aliases = TOML.parse(fs.readFileSync(ACTIONS_PATH, 'utf8')).karabiner_aliases || {};
	const actions = JSON.parse(fs.readFileSync(MACOS_REMAP_ACTIONS_PATH, 'utf8'));
	return function karabinerActionSegments(action, context) {
		const registryKey = `sg_actions.${aliases[action] || action}`;
		if (labels.hasKey(registryKey)) return [{ key: labels.requireKey(registryKey, context) }];
		const entry = actions.find((candidate) => candidate.id === action);
		const text = entry && (entry.short_label || entry.label);
		if (typeof text !== 'string' || text === '') {
			throw new Error(`${context}: Karabiner action ${action} has no label`);
		}
		return [{ text }];
	};
}

/**
 * The tap and the hold a platform's engine ships for one key, as label
 * segments named the way its tray names them: Windows and Linux through the
 * action registry and the hold picker's labels, macOS through its Karabiner
 * actions.
 * @param {string} platform Manifest platform token.
 * @param {string} key The key's id on the platform.
 * @param {object} defaults Parsed defaults.toml.
 * @param {object} labels Label helpers.
 * @param {function(string, string): object[]} karabinerLabel macOS action labels.
 * @param {string} context Error context.
 * @returns {{tap: object[], hold: object[]}} Segments.
 */
function tapHoldAssignment(platform, key, defaults, labels, karabinerLabel, context) {
	if (platform === 'hs') {
		const slots = defaults.hs_tap_hold[key];
		return {
			tap: karabinerLabel(slots.tap, `${context} tap`),
			hold: karabinerLabel(slots.hold, `${context} hold`)
		};
	}
	const preset = defaults.tap_hold.keys[key];
	const tap =
		typeof preset.tap_action === 'string' && preset.tap_action !== ''
			? [{ key: labels.actionLabelKey(preset.tap_action, `${context} tap`) }]
			: [{ key: labels.requireKey('tap_hold.tap.none', context) }];
	let hold;
	if (typeof preset.hold_layer === 'string' && preset.hold_layer !== '') {
		hold = [{ key: labels.requireKey(`tap_hold.hold.${preset.hold_layer}_layer`, context) }];
	} else if (typeof preset.hold_modifier === 'string' && preset.hold_modifier !== '') {
		// A combination reads as the tray draws it: its modifiers joined by " + ".
		hold = [];
		for (const modifier of preset.hold_modifier.split('+')) {
			if (hold.length > 0) hold.push({ text: ' + ' });
			hold.push({ key: labels.requireKey(`tap_hold.hold.${modifier.trim()}`, context) });
		}
	} else {
		hold = [{ key: labels.requireKey('tap_hold.hold.none', context) }];
	}
	return { tap, hold };
}

/**
 * The tap-hold checklist: every key of the platform's column of the shared key
 * catalogue that its engine ships a recommendation for, in tray order under the
 * tray's two hand headers. An item imports that key's recommended tap and hold
 * through the host's tap-hold writer; the host reads the recommendation from
 * the same defaults.toml, so the catalogue carries the key id, and the tap and
 * hold only as the label the page shows.
 * @param {string} id Page id.
 * @param {string} platform Manifest platform token.
 * @param {object} labels Label helpers.
 * @returns {object[]} One group per hand that has a recommended key.
 */
function tapHoldGroups(id, platform, labels) {
	const defaults = TOML.parse(fs.readFileSync(TAP_HOLD_DEFAULTS_PATH, 'utf8'));
	const template = labels.requireKey(TAP_HOLD_ASSIGNMENT_KEY, `onboarding page ${id}`);
	const karabinerLabel = createKarabinerLabels(labels);
	const catalog = defaults.tap_hold && defaults.tap_hold.catalog && defaults.tap_hold.catalog.keys;
	if (!Array.isArray(catalog) || catalog.length === 0) {
		throw new Error('_shared/tap_hold/defaults.toml declares no [tap_hold.catalog] keys');
	}
	const recommended = new Set(TAP_HOLD_PRESETS[platform](defaults));
	const listed = new Set();
	const hands = new Map(Object.keys(TAP_HOLD_HAND_LABELS).map((hand) => [hand, []]));
	for (const entry of catalog) {
		const key = entry[platform];
		if (key === undefined) continue;
		listed.add(key);
		if (!recommended.has(key)) continue;
		if (!hands.has(entry.hand))
			throw new Error(`tap-hold key ${entry.id} names unknown hand ${entry.hand}`);
		const context = `onboarding page ${id} key ${key}`;
		const assignment = tapHoldAssignment(platform, key, defaults, labels, karabinerLabel, context);
		hands.get(entry.hand).push({
			path: TAP_HOLD_KEY_PREFIX + key,
			value: true,
			default: false,
			recommended: true,
			tap_hold_key: key,
			customised_value: TAP_HOLD_CUSTOMISED,
			label: [{ key: labels.requireKey(entry.label_key, context) }],
			value_label: [{ template, args: [assignment.tap, assignment.hold] }]
		});
	}
	for (const key of recommended) {
		if (!listed.has(key)) {
			throw new Error(
				`the ${platform} tap-hold preset recommends ${key}, which [tap_hold.catalog] does not list`
			);
		}
	}
	const groups = [];
	for (const [hand, items] of hands) {
		if (items.length === 0) continue;
		groups.push({
			label: [{ key: labels.requireKey(TAP_HOLD_HAND_LABELS[hand], `onboarding page ${id}`) }],
			items
		});
	}
	if (groups.length === 0)
		throw new Error(`onboarding page ${id} recommends no tap-hold key on ${platform}`);
	return groups;
}

/**
 * The hotstring trigger character choice, or undefined on a platform its
 * `platforms` list leaves out.
 * @returns {object|undefined} Choice descriptor.
 */
function magicKeyFor(id, page, platform, projection, labels) {
	const choice = page.magic_key;
	if (!isPlainObject(choice) || typeof choice.path !== 'string' || !Array.isArray(choice.options)) {
		throw new Error(`[onboarding.pages.${id}.magic_key] needs a path and options`);
	}
	if (
		!Array.isArray(choice.platforms) ||
		choice.platforms.length === 0 ||
		choice.platforms.some((name) => !MANIFEST_PLATFORMS.includes(name))
	) {
		throw new Error(`[onboarding.pages.${id}.magic_key] platforms must list known platforms`);
	}
	if (!choice.platforms.includes(platform)) return undefined;
	const values = projection.project(choice.path, platform);
	if (typeof values.default !== 'string' || values.default === '') {
		throw new Error(`${choice.path} must default to a character`);
	}
	for (const option of choice.options) {
		if (!isPlainObject(option)) throw new Error(`${choice.path} option must be a table`);
		if (
			option.platforms !== undefined &&
			(!Array.isArray(option.platforms) ||
				option.platforms.length === 0 ||
				new Set(option.platforms).size !== option.platforms.length ||
				option.platforms.some((name) => !choice.platforms.includes(name)))
		)
			throw new Error(`${choice.path} option platforms must be a nonempty known subset`);
	}
	if (choice.validation !== undefined) {
		if (!isPlainObject(choice.validation))
			throw new Error(`${choice.path} validation must be per platform`);
		for (const [owner, policy] of Object.entries(choice.validation)) {
			if (owner !== 'linux' || policy !== 'safe_magic_key')
				throw new Error(`${choice.path} has an unsupported validation policy`);
		}
	}
	const options = choice.options
		.filter((option) => !option.platforms || option.platforms.includes(platform))
		.map((option) => {
			if (typeof option.value !== 'string' || option.value === '')
				throw new Error(`${choice.path} option needs a value`);
			return { value: option.value, label_key: labels.requireKey(option.label_key, choice.path) };
		});
	if (!options.some((option) => option.value === values.default)) {
		throw new Error(`${choice.path} options must include its default ${values.default}`);
	}
	if (!Number.isInteger(choice.max_characters) || choice.max_characters < 1) {
		throw new Error(`[onboarding.pages.${id}.magic_key] needs a positive max_characters`);
	}
	return {
		path: choice.path,
		default: values.default,
		recommended: values.recommended,
		label_key: labels.requireKey(choice.label_key, choice.path),
		hint_key: labels.requireKey(choice.hint_key, choice.path),
		custom_label_key: labels.requireKey(choice.custom_label_key, choice.path),
		max_characters: choice.max_characters,
		...(choice.validation?.[platform] ? { validation: choice.validation[platform] } : {}),
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
	} else if (page.checklist === 'tap_holds') {
		groups = tapHoldGroups(id, platform, labels);
	}
	groups = groups.concat(settingsGroups(id, page, platform, features, projection));
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
	const state = stateFor(id, page, platform, master, projection);
	if (state) built.state = state;
	const subSwitch = subSwitchFor(id, page, platform, master, groups, manifest, projection);
	if (subSwitch) built.sub_switch = subSwitch;
	if (hint) built.hint_key = hint;
	if (note) built.note_key = note;
	if (page.checklist === 'hotstrings') {
		const magicKey = magicKeyFor(id, page, platform, projection, labels);
		if (magicKey) built.magic_key = magicKey;
	}
	return built;
}

/**
 * Builds the complete catalogue.
 * @returns {object} Catalogue.
 */
function buildCatalogue() {
	const manifest = loadManifest();
	const features = indexFeatures(manifest);
	for (const featurePath of features.keys()) {
		if ((featurePath + '.').startsWith(TAP_HOLD_KEY_PREFIX)) {
			throw new Error(
				`${featurePath} would make a tap-hold key answer read as a configuration path`
			);
		}
	}
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
	// Nested menu scopes belong to their containing wizard page. The global
	// composition names every root scope that needs its own question.
	const scopes = manifest.scopes.global.includes;
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
	// Answers are Booleans or strings: AutoHotkey's JSON reader has no Boolean
	// type, so a numeric answer could not be told from a switch there.
	for (const [driver, data] of Object.entries(platforms)) {
		const seen = new Set();
		const claim = (entry) => {
			if (seen.has(entry.path))
				throw new Error(`${driver}: ${entry.path} is written by two wizard rows`);
			seen.add(entry.path);
			for (const field of ['value', 'default']) {
				const kind = typeof entry[field];
				if (field in entry && kind !== 'boolean' && kind !== 'string') {
					throw new Error(`${driver}: ${entry.path} ${field} must be a Boolean or a string`);
				}
			}
		};
		for (const page of data.pages) {
			if (page.master) claim(page.master);
			if (page.sub_switch) claim(page.sub_switch);
			if (page.state) claim(page.state);
			if (page.magic_key) claim(page.magic_key);
			(function walk(groups) {
				for (const group of groups) {
					if (group.path) claim(group);
					for (const item of group.items || []) claim(item);
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
	// A label or trigger kept for an item no platform lists outlives the gap it filled.
	for (const id of order) {
		for (const table of ['labels', 'triggers']) {
			for (const itemPath of Object.keys(manifest.onboarding.pages[id][table] || {})) {
				if (!usedOverrides.has(itemPath)) {
					throw new Error(`[onboarding.pages.${id}.${table}] ${itemPath} names no checklist item`);
				}
			}
		}
	}
	refuseSeparatorsInLabels(platforms, labels);
	return {
		schema_version: SCHEMA_VERSION,
		order,
		value_separator: VALUE_SEPARATOR,
		texts: labels.texts,
		platforms
	};
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

module.exports = { buildCatalogue, DRIVERS, SCHEMA_VERSION, VALUE_SEPARATOR };
