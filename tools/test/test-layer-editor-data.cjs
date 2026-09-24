// tools/test/test-layer-editor-data.cjs

/**
 * ==============================================================================
 * MODULE: Layer Editor Data Gate
 * DESCRIPTION:
 * The navigation layer editor (_shared/ui/layer_editor) reads everything it
 * knows about keys and actions from one generated file,
 * _shared/ui/layer_editor/_generated/layer_data.js, built by
 * tools/codegen/codegen-layer-editor-data-js.cjs from the physical-key registry,
 * the layer vocabulary and Ergopti's recommended layer. This gate holds that
 * file to its sources.
 *
 * WHAT IS CHECKED:
 * 1. Drift: the committed file is exactly what the generator writes today.
 * 2. Picker: every vocabulary action is listed once, under the group its
 *    `group` field names, and the groups follow [editor].groups.
 * 3. Availability: the OSes the editor offers an action, a modifier, a
 *    parameter or an input kind on are the ones the vocabulary resolves it on,
 *    read here straight from layer_actions.toml rather than through the
 *    reference loader the generator asks, so the two answers are independent.
 * 4. Labels: every label and reason key the page shows reads in all 21 locales.
 * 5. Keys and preset: the registry's codes, kinds and geometry in registry
 *    order, and the recommended layer as layers.recommended.toml writes it.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const TOML = require('smol-toml');
const { shared } = require('../lib/paths.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const GENERATOR = path.join(ROOT, 'tools', 'codegen', 'codegen-layer-editor-data-js.cjs');
const OUT = shared('ui', 'layer_editor', '_generated', 'layer_data.js');
const LOCALES_DIR = shared('data', 'locales');

// Floors: a data file or a vocabulary that stopped being read would otherwise
// pass with nothing compared.
const MIN_ACTIONS = 30;
const MIN_KEYS = 100;
const MIN_LOCALES = 21;
const MIN_RECOMMENDED_BINDINGS = 40;

const errors = [];
const fail = (msg) => errors.push(msg);

function finish() {
	if (errors.length > 0) {
		console.error('\x1b[31m[FAIL] the layer editor data disagrees with its sources:\x1b[0m');
		for (const e of errors) console.error('    - ' + e);
		process.exit(1);
	}
}

if (!fs.existsSync(GENERATOR)) fail(`${path.relative(ROOT, GENERATOR)} is missing — nothing builds the editor's data`);
if (!fs.existsSync(OUT)) fail(`${path.relative(ROOT, OUT)} is missing — the editor would open with no key and no action`);
finish();

const { buildSource } = require(GENERATOR);
const committed = fs.readFileSync(OUT, 'utf8');





// ===========================
// ===========================
// ======= 1/ No drift =======
// ===========================
// ===========================

if (committed !== buildSource()) fail(`${path.relative(ROOT, OUT)} is stale: run npm run codegen:layer-editor-data:js`);

const sandbox = {};
vm.createContext(sandbox);
vm.runInContext(committed, sandbox, { filename: OUT });
const data = vm.runInContext('LAYER_EDITOR_DATA', sandbox);

const vocabulary = TOML.parse(fs.readFileSync(shared('keymap', 'layer_actions.toml'), 'utf8'));
const registry = JSON.parse(fs.readFileSync(shared('data', 'keycodes', 'physical_keys.json'), 'utf8'));
const recommendedDoc = TOML.parse(fs.readFileSync(shared('keymap', 'layers.recommended.toml'), 'utf8'));
const OSES = vocabulary._meta.platforms;





// ==========================
// ==========================
// ======= 2/ Picker ========
// ==========================
// ==========================

const actionIds = Object.keys(vocabulary.actions);
if (actionIds.length < MIN_ACTIONS) fail(`only ${actionIds.length} vocabulary actions read (floor ${MIN_ACTIONS})`);
const groupIds = data.groups.map((g) => g.id);
if (JSON.stringify(groupIds) !== JSON.stringify(vocabulary.editor.groups)) fail(`groups ${JSON.stringify(groupIds)} do not follow [editor].groups ${JSON.stringify(vocabulary.editor.groups)}`);
const listed = new Map();
for (const group of data.groups) {
	if (group.label_key !== `layer_editor.group.${group.id}`) fail(`group "${group.id}" reads label ${group.label_key}`);
	const expected = actionIds.filter((id) => vocabulary.actions[id].group === group.id);
	if (JSON.stringify(group.actions) !== JSON.stringify(expected)) fail(`group "${group.id}" lists ${JSON.stringify(group.actions)}, the vocabulary files ${JSON.stringify(expected)} under it`);
	for (const id of group.actions) listed.set(id, (listed.get(id) || 0) + 1);
}
for (const id of actionIds) if (listed.get(id) !== 1) fail(`action "${id}" is listed ${listed.get(id) || 0} time(s) in the picker`);
if (Object.keys(data.actions).length !== actionIds.length) fail(`${Object.keys(data.actions).length} actions described for ${actionIds.length} in the vocabulary`);





// ================================
// ================================
// ======= 3/ Availability ========
// ================================
// ================================

/** The OSes a vocabulary rule { platforms } allows, every OS when absent. */
const allowed = (rule) => (rule && Array.isArray(rule.platforms) ? rule.platforms : OSES);
const sameList = (a, b) => JSON.stringify([...a].sort()) === JSON.stringify([...b].sort());

let checkedActions = 0;
for (const id of actionIds) {
	const action = vocabulary.actions[id];
	const described = data.actions[id];
	if (!described) {
		fail(`action "${id}" is not described`);
		continue;
	}
	checkedActions += 1;
	const expected = OSES.filter((os) => action[os] !== undefined || action.all !== undefined);
	if (!sameList(described.platforms, expected)) fail(`action "${id}" is offered on ${described.platforms}, resolves on ${expected}`);
	const expectedReason = expected.length < OSES.length ? action.reason_key : null;
	if (described.reason_key !== expectedReason) fail(`action "${id}" gives reason ${described.reason_key}, the vocabulary ${expectedReason}`);
	if (described.repeatable !== action.repeatable) fail(`action "${id}" repeatable = ${described.repeatable}, the vocabulary ${action.repeatable}`);
	const labelKey = action.catalogue === true ? `sg_actions.${id}` : `layer_actions.${id}`;
	if (described.label_key !== labelKey) fail(`action "${id}" reads label ${described.label_key}, expected ${labelKey}`);
}

for (const mod of vocabulary._meta.modifier_order) {
	const rule = (vocabulary.modifiers || {})[mod];
	const described = data.modifiers[mod];
	if (!described) fail(`modifier "${mod}" is not described`);
	else if (!sameList(described.platforms, allowed(rule))) fail(`modifier "${mod}" is offered on ${described.platforms}, exists on ${allowed(rule)}`);
}

const kinds = [...new Set(Object.values(registry.keys).map((k) => k.kind))];
for (const kind of kinds) {
	const rule = (vocabulary.source_kinds || {})[kind];
	const described = data.source_kinds[kind];
	if (!described) fail(`input kind "${kind}" is not described`);
	else if (!sameList(described.platforms, allowed(rule))) fail(`input kind "${kind}" is offered on ${described.platforms}, is a layer key on ${allowed(rule)}`);
}

const repeat = vocabulary.parameters.repeat_count;
if (!sameList(data.repeat_count.platforms, repeat.platforms)) fail(`repeat_count is offered on ${data.repeat_count.platforms}, exists on ${repeat.platforms}`);
if (data.repeat_count.min !== repeat.min || data.repeat_count.max !== repeat.max) fail('repeat_count bounds differ from [parameters.repeat_count]');
if (JSON.stringify(data.modifier_order) !== JSON.stringify(vocabulary._meta.modifier_order)) fail('modifier_order differs from the vocabulary');
if (JSON.stringify(data.primary_modifier) !== JSON.stringify(vocabulary.primary_modifier)) fail('primary_modifier differs from the vocabulary');
if (data.schema_version !== vocabulary._meta.layers_schema_version) fail('schema_version differs from [_meta].layers_schema_version');
if (data.user_file !== vocabulary._meta.user_file) fail('user_file differs from [_meta].user_file');





// ==========================
// ==========================
// ======= 4/ Labels ========
// ==========================
// ==========================

const labelKeys = new Set();
for (const group of data.groups) labelKeys.add(group.label_key);
for (const described of Object.values(data.actions)) {
	labelKeys.add(described.label_key);
	if (described.reason_key) labelKeys.add(described.reason_key);
}
for (const rule of [...Object.values(data.modifiers), ...Object.values(data.source_kinds), data.repeat_count]) if (rule.reason_key) labelKeys.add(rule.reason_key);

const localeFiles = fs.readdirSync(LOCALES_DIR).filter((f) => f.endsWith('.json'));
if (localeFiles.length < MIN_LOCALES) fail(`only ${localeFiles.length} locale files (floor ${MIN_LOCALES})`);
for (const file of localeFiles) {
	const strings = JSON.parse(fs.readFileSync(path.join(LOCALES_DIR, file), 'utf8').replace(/^﻿/, ''));
	for (const key of labelKeys) {
		if (typeof strings[key] !== 'string' || strings[key].trim() === '') fail(`${file}: "${key}" is missing or blank`);
	}
}





// ==================================
// ==================================
// ======= 5/ Keys and preset =======
// ==================================
// ==================================

const registryCodes = Object.keys(registry.keys);
if (registryCodes.length < MIN_KEYS) fail(`only ${registryCodes.length} registry keys read (floor ${MIN_KEYS})`);
if (JSON.stringify(data.keys.map((k) => k.code)) !== JSON.stringify(registryCodes)) fail('the editor keys are not the registry codes in registry order');
for (const key of data.keys) {
	const entry = registry.keys[key.code];
	if (!entry) continue;
	if (key.kind !== entry.kind || key.group !== entry.group) fail(`${key.code}: kind/group ${key.kind}/${key.group}, registry ${entry.kind}/${entry.group}`);
	if (JSON.stringify(key.geometry || null) !== JSON.stringify(entry.geometry || null)) fail(`${key.code}: geometry differs from the registry`);
}

const recommendedLayers = recommendedDoc.layers || {};
if (Object.keys(recommendedLayers).length !== 1 || !recommendedLayers[data.layer]) fail(`the recommended file must define exactly the edited layer "${data.layer}"`);
else {
	if (JSON.stringify(data.recommended) !== JSON.stringify(recommendedLayers[data.layer])) fail('the recommended layer differs from layers.recommended.toml');
	const count = Object.values(recommendedLayers[data.layer]).reduce((n, section) => n + Object.keys(section).length, 0);
	if (count < MIN_RECOMMENDED_BINDINGS) fail(`only ${count} recommended bindings read (floor ${MIN_RECOMMENDED_BINDINGS})`);
}

finish();
console.log(
	`\x1b[32m[OK] layer editor data matches its sources: ${checkedActions} actions in ${data.groups.length} groups, ` +
		`${data.keys.length} keys, ${labelKeys.size} label key(s) read in ${localeFiles.length} locales.\x1b[0m`
);
