// tools/codegen/codegen-layer-editor-data-js.cjs

/**
 * ==============================================================================
 * MODULE: Layer Editor Data Codegen
 * DESCRIPTION:
 * Generates `_shared/ui/layer_editor/_generated/layer_data.js`, everything the
 * navigation layer editor page knows about keys and actions, from the shared
 * layer sources:
 *   - _shared/data/keycodes/physical_keys.json (codes, kinds, geometry);
 *   - _shared/keymap/layer_actions.toml (actions, groups, OS availability);
 *   - _shared/keymap/layers.recommended.toml (Ergopti's recommended layer);
 *   - _shared/tap_hold/defaults.toml (the layers a hold key can enter).
 *
 * FEATURES & RATIONALE:
 * 1. One answer for availability: whether an action, a modifier, a parameter
 *    or an input kind exists on an OS is asked of the reference loader
 *    (tools/lib/keymap-layers.cjs) with a one-binding probe file, so the page
 *    offers exactly what the drivers' loaders accept and states the vocabulary's
 *    reason for what they refuse.
 * 2. Classic script: `_shared/ui/*` pages load plain `<script src>` tags, and
 *    the Linux and macOS hosts inline them, so the data is a top-level const
 *    the page scripts read, not a module or a fetch.
 * 3. Labels are locale keys: a catalogue action reuses its sg_actions.<id>
 *    label, the others read layer_actions.<id>; a missing English key fails
 *    the generation instead of shipping a raw identifier.
 * 4. Deterministic: registry order, vocabulary order, no timestamp.
 * 5. Legends: a key marked `character` types what the active layout puts on
 *    it, so the page shows the legend its host resolved; every other key is a
 *    named key the page labels itself.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const TOML = require('smol-toml');
const { shared, sharedRel } = require('../lib/paths.cjs');
const { loadContext, loadLayers, RECOMMENDED_PATH } = require('../lib/keymap-layers.cjs');

const OUT_PATH = shared('ui', 'layer_editor', '_generated', 'layer_data.js');
const TAP_HOLD_DEFAULTS_PATH = shared('tap_hold', 'defaults.toml');
const EN_LOCALE_PATH = shared('data', 'locales', 'en.json');
const SOURCES = [
	'data/keycodes/physical_keys.json',
	'keymap/layer_actions.toml',
	'keymap/layers.recommended.toml',
	'tap_hold/defaults.toml'
];

// The key every availability probe binds, and the probe layer's id: any key of
// kind "key" and any valid layer id would do.
const PROBE_KEY = 'KeyA';
const PROBE_LAYER = 'probe';

// =====================================
// =====================================
// ======= 1/ Availability probes =======
// =====================================
// =====================================

/**
 * Asks the reference loader on which OSes one binding resolves.
 * @param {object} ctx - From loadContext().
 * @param {string} code - The physical key the probe binds.
 * @param {string} binding - A binding value.
 * @param {string} what - What is probed, for the error message.
 * @returns {{platforms: string[], reason_key: string|null}}
 */
function probe(ctx, code, binding, what) {
	const text = `[_meta]\nschema_version = ${ctx.vocabulary._meta.layers_schema_version}\n\n[layers.${PROBE_LAYER}.all]\n"${code}" = "${binding}"\n`;
	const platforms = [];
	const reasons = new Set();
	for (const os of ctx.platforms) {
		const result = loadLayers(text, os, ctx);
		if (result.ok) {
			platforms.push(os);
			continue;
		}
		for (const e of result.errors) {
			if (e.code !== 'unavailable_on_os')
				throw new Error(`${what}: the probe binding is invalid (${e.code}: ${e.detail})`);
			if (typeof e.reason_key !== 'string')
				throw new Error(`${what}: unavailable on ${os} without a reason_key`);
			reasons.add(e.reason_key);
		}
	}
	if (platforms.length === 0) throw new Error(`${what}: resolves on no OS`);
	if (reasons.size > 1)
		throw new Error(`${what}: ${reasons.size} different reasons for the OSes it leaves out`);
	return { platforms, reason_key: reasons.size === 1 ? [...reasons][0] : null };
}

// ================================
// ================================
// ======= 2/ Data assembly =======
// ================================
// ================================

/**
 * Builds the data object the page reads.
 * @returns {object}
 */
function buildData() {
	const ctx = loadContext();
	const vocabulary = ctx.vocabulary;
	const registry = ctx.registry;
	const english = JSON.parse(fs.readFileSync(EN_LOCALE_PATH, 'utf8').replace(/^﻿/, ''));
	const requireLabel = (key, what) => {
		if (typeof english[key] !== 'string' || english[key].trim() === '')
			throw new Error(`${what}: en.json has no "${key}"`);
		return key;
	};

	const recommendedDoc = TOML.parse(fs.readFileSync(RECOMMENDED_PATH, 'utf8'));
	const layerIds = Object.keys(recommendedDoc.layers || {});
	if (layerIds.length !== 1)
		throw new Error(
			`${sharedRel('keymap/layers.recommended.toml')} must define exactly one layer, found ${layerIds.length}`
		);
	const layer = layerIds[0];
	const holdLayers =
		((TOML.parse(fs.readFileSync(TAP_HOLD_DEFAULTS_PATH, 'utf8')).tap_hold || {}).hold_picker || {})
			.layers || [];
	if (!holdLayers.includes(layer))
		throw new Error(
			`layer "${layer}" is not one a hold key can enter ([tap_hold.hold_picker].layers)`
		);

	const groups = (vocabulary.editor || {}).groups;
	if (!Array.isArray(groups) || groups.length === 0)
		throw new Error('[editor].groups is missing from the layer vocabulary');
	const actions = {};
	const grouped = Object.fromEntries(groups.map((g) => [g, []]));
	for (const [id, action] of Object.entries(vocabulary.actions)) {
		if (!grouped[action.group])
			throw new Error(
				`[actions.${id}].group = ${JSON.stringify(action.group)} is not one of [editor].groups`
			);
		grouped[action.group].push(id);
		const labelKey = action.catalogue === true ? `sg_actions.${id}` : `layer_actions.${id}`;
		const availability = probe(ctx, PROBE_KEY, id, `action "${id}"`);
		actions[id] = {
			label_key: requireLabel(labelKey, `action "${id}"`),
			platforms: availability.platforms,
			reason_key: availability.reason_key,
			repeatable: action.repeatable === true
		};
	}

	const modifiers = {};
	for (const mod of vocabulary._meta.modifier_order)
		modifiers[mod] = probe(ctx, PROBE_KEY, `keystroke:${mod}+${PROBE_KEY}`, `modifier "${mod}"`);

	const sourceKinds = {};
	for (const [code, entry] of Object.entries(registry.keys)) {
		if (sourceKinds[entry.kind]) continue;
		sourceKinds[entry.kind] = probe(ctx, code, 'none', `input kind "${entry.kind}"`);
	}

	const repeat = vocabulary.parameters.repeat_count;
	const repeatAvailability = probe(ctx, PROBE_KEY, `repeat_count:${repeat.min}`, 'repeat_count');

	// A key the registry sends by its scan code rather than by name
	// (`ahk_send: null`) types whatever the active layout puts there: its
	// legend is the host's to send (script.js init), never a guess of the page.
	const keys = Object.entries(registry.keys).map(([code, entry]) => {
		const key = { code, kind: entry.kind, group: entry.group };
		if (entry.kind === 'key' && entry.ahk_send === null) key.character = true;
		if (entry.geometry) key.geometry = entry.geometry;
		return key;
	});

	return {
		schema_version: vocabulary._meta.layers_schema_version,
		user_file: vocabulary._meta.user_file,
		layer,
		platforms: ctx.platforms,
		modifier_order: vocabulary._meta.modifier_order,
		primary_modifier: vocabulary.primary_modifier,
		modifiers,
		source_kinds: sourceKinds,
		repeat_count: {
			platforms: repeatAvailability.platforms,
			reason_key: repeatAvailability.reason_key,
			min: repeat.min,
			max: repeat.max
		},
		groups: groups.map((id) => {
			if (grouped[id].length === 0)
				throw new Error(`[editor].groups lists "${id}" and no action belongs to it`);
			return {
				id,
				label_key: requireLabel(`layer_editor.group.${id}`, `group "${id}"`),
				actions: grouped[id]
			};
		}),
		actions,
		keys,
		recommended: recommendedDoc.layers[layer]
	};
}

// =============================
// =============================
// ======= 3/ JS source ========
// =============================
// =============================

/**
 * Formats a value as JSON with its first two levels one entry per line and
 * everything deeper on that entry's line, so a key or an action reads as one
 * line of the file and a diff names the entry that changed.
 * @param {any} value - The value to format.
 * @param {number} depth - How many more levels to expand.
 * @param {string} indent - The indentation of the value's own line.
 * @returns {string}
 */
function formatJson(value, depth, indent) {
	if (depth === 0 || value === null || typeof value !== 'object') return JSON.stringify(value);
	const inner = indent + '\t';
	const entries = Array.isArray(value)
		? value.map((item) => inner + formatJson(item, depth - 1, inner))
		: Object.entries(value).map(
				([k, v]) => `${inner}${JSON.stringify(k)}: ${formatJson(v, depth - 1, inner)}`
			);
	if (entries.length === 0) return JSON.stringify(value);
	const [open, close] = Array.isArray(value) ? ['[', ']'] : ['{', '}'];
	return `${open}\n${entries.join(',\n')}\n${indent}${close}`;
}

/**
 * Builds the complete generated file.
 * @returns {string} JS source with LF line ends and a final newline.
 */
function buildSource() {
	const json = formatJson(buildData(), 2, '');
	const lines = [
		'// _shared/ui/layer_editor/_generated/layer_data.js',
		'',
		'// ==========================================',
		'// AUTO-GENERATED — do not edit manually',
		...SOURCES.map((s) => `// Source: ${sharedRel(s)}`),
		'// Run: npm run codegen:layer-editor-data:js',
		'// ==========================================',
		'',
		'// Keys, actions, groups, OS availability and the recommended layer, as the',
		'// layer editor page reads them. Loaded by a <script> tag before the page scripts.',
		`const LAYER_EDITOR_DATA = ${json};`,
		''
	];
	return lines.join('\n');
}

/**
 * Writes the generated file.
 */
function main() {
	console.log('codegen:layer-editor-data:js — generating the layer editor data…');
	const source = buildSource();
	fs.mkdirSync(path.dirname(OUT_PATH), { recursive: true });
	fs.writeFileSync(OUT_PATH, source, 'utf8');
	console.log(`  Written: ${sharedRel('ui/layer_editor/_generated/layer_data.js')}`);
	console.log('codegen:layer-editor-data:js — done.');
}

if (require.main === module) main();

module.exports = { buildSource, buildData, OUT_PATH };
