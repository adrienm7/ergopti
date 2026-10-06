// tools/codegen/codegen-action-catalogue.cjs

/**
 * ==============================================================================
 * MODULE: Action Catalogue Codegen
 * DESCRIPTION:
 * Turns the shared action registry, _shared/modules/actions/actions.toml, into
 * one generated catalogue per driver: the ordered picker items (headings with
 * their level and i18n key, actions, the modifier-chord block), the metadata of
 * every action the driver claims (label key, parameter kind, confirmation,
 * requirements), and the driver-specific extras (Karabiner aliases on macOS,
 * the gesture slot-space on Linux).
 *
 * WHY GENERATED RATHER THAN READ AT RUNTIME:
 * Three drivers read the same TOML with three parsers. Windows parsed it with
 * ParseTomlFile inside a loader deferred off the boot path; macOS used a
 * hand-written line reader that only understood `key = "string"` and silently
 * stored anything else as a raw string; Linux decoded it for its slots and
 * parameter kinds but listed its actions from a hard-coded table of 42 ids,
 * sorted alphabetically, without headings and without the platform filter. The
 * same file therefore produced three different pickers. Filtering, ordering and
 * validating once, here, leaves each driver a plain data file to load.
 *
 * WHY STRICT:
 * Every field, platform token, parameter kind and requirement token is checked.
 * A field this generator does not know would otherwise be dropped on the floor,
 * which is how a declaration comes to promise something no driver does.
 *
 * USAGE:  node tools/codegen/codegen-action-catalogue.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const CATALOGUE = path.join(SP, '_shared', 'modules', 'actions', 'actions.toml');

/** Driver key -> generated file, relative to the repository root. */
const OUTPUTS = {
	hs: 'static/ergopti_plus/macos/_generated/action_catalogue.lua',
	linux: 'static/ergopti_plus/linux/_generated/action_catalogue.lua',
	ahk: 'static/ergopti_plus/windows/_generated/action_catalogue.ahk'
};

const PLATFORMS = ['ahk', 'hs', 'linux'];

/** Locale key prefix every picker heading resolves through. */
const HEADER_KEY_PREFIX = 'sg_actions.sg_order.header.';

/** The heading key of one modifier-combination group; `{1}` is its label. */
const CHORD_GROUP_KEY = HEADER_KEY_PREFIX + 'modifier_chord_group';

/** The sg_order entry that expands into the modifier-chord matrix. */
const CHORD_PLACEHOLDER = '_modifier_chords_placeholder';

// Every driver validates and prompts for each kind; adding one means adding it
// to the three gesture modules (validator, prompt, error text) in the same change.
const PARAMETER_KINDS = new Set([
	'url',
	'search_url',
	'wrap_pair',
	'text',
	'key',
	'shortcut',
	'llm_prompt',
	'llm_vision',
	'llm_language',
	'app',
	'program'
]);

const SG_FIELDS = new Set([
	'platform',
	'emit_ahk_key',
	'emit_ahk_mods',
	'emit_ahk',
	'emit_hs_key',
	'emit_hs_mods',
	'emit_linux',
	'parameter',
	'confirm',
	'is_header',
	'requires_ahk',
	'requires_hs',
	'requires_linux'
]);
const AX_FIELDS = new Set(['platform', 'scalable']);

/**
 * Requirement tokens each driver can probe. A token with no probe would be a
 * declaration nothing checks, so the generator refuses it instead.
 * @type {Record<string, RegExp[]>}
 */
const REQUIREMENT_TOKENS = {
	ahk: [],
	hs: [],
	linux: [/^tool:[A-Za-z0-9._+-]+$/, /^session:x11$/, /^session:workspaces$/]
};

/**
 * Parses and validates the registry.
 * @param {string} source TOML text.
 * @returns {object} The decoded registry.
 * @throws {Error} On the first schema violation.
 */
function parseRegistry(source) {
	const data = toml.parse(source);
	for (const section of ['sg_actions', 'ax_actions', 'sg_order', 'ax_order', 'slots']) {
		if (!data[section] || typeof data[section] !== 'object') {
			throw new Error(`actions.toml has no [${section}] section`);
		}
	}
	validateFamily(data.sg_actions, SG_FIELDS, 'sg_actions');
	validateFamily(data.ax_actions, AX_FIELDS, 'ax_actions');
	validateOrder(data.sg_order.items, data.sg_actions, 'sg_order', true);
	validateOrder(data.ax_order.items, data.ax_actions, 'ax_order', false);
	for (const [alias, target] of Object.entries(data.karabiner_aliases || {})) {
		if (!data.sg_actions[target]) {
			throw new Error(
				`karabiner_aliases.${alias} targets "${target}", which is not an sg_actions row`
			);
		}
		if (data.sg_actions[alias]) {
			throw new Error(
				`karabiner_aliases.${alias} is also an sg_actions row — one name, two meanings`
			);
		}
	}
	return data;
}

/**
 * Splits a platform field into the drivers it claims.
 * @param {unknown} value The declared field.
 * @param {string} where Location for the error message.
 * @returns {string[]} Driver keys.
 */
function platformsOf(value, where) {
	if (typeof value !== 'string' || value.trim() === '') {
		throw new Error(`${where}: platform must be a non-empty string`);
	}
	if (value === 'all') return [...PLATFORMS];
	const keys = value.split(',').map((s) => s.trim());
	for (const key of keys) {
		if (!PLATFORMS.includes(key)) {
			throw new Error(
				`${where}: unknown platform "${key}" (expected all, ${PLATFORMS.join(', ')})`
			);
		}
	}
	return keys;
}

/**
 * Validates every row of one action family.
 * @param {Record<string, object>} family Rows keyed by id.
 * @param {Set<string>} allowed Allowed field names.
 * @param {string} name Family name for messages.
 */
function validateFamily(family, allowed, name) {
	for (const [id, row] of Object.entries(family)) {
		const where = `${name}.${id}`;
		if (!/^[a-z_][a-z0-9_]*$/.test(id)) throw new Error(`${where}: invalid action id`);
		if (!row || typeof row !== 'object') throw new Error(`${where}: not a table`);
		for (const field of Object.keys(row)) {
			if (!allowed.has(field)) throw new Error(`${where}: unknown field "${field}"`);
		}
		const claimed = platformsOf(row.platform, where);
		if (row.parameter !== undefined && !PARAMETER_KINDS.has(row.parameter)) {
			throw new Error(`${where}: unknown parameter kind "${row.parameter}"`);
		}
		if (row.confirm !== undefined && typeof row.confirm !== 'boolean') {
			throw new Error(`${where}: confirm must be a boolean`);
		}
		if (row.is_header !== undefined && row.is_header !== true) {
			throw new Error(`${where}: is_header may only be true`);
		}
		for (const driver of PLATFORMS) {
			const tokens = row[`requires_${driver}`];
			if (tokens === undefined) continue;
			if (!claimed.includes(driver)) {
				throw new Error(`${where}: requires_${driver} on an action that does not claim ${driver}`);
			}
			if (!Array.isArray(tokens) || tokens.length === 0) {
				throw new Error(`${where}: requires_${driver} must be a non-empty array`);
			}
			for (const token of tokens) {
				if (typeof token !== 'string' || !REQUIREMENT_TOKENS[driver].some((re) => re.test(token))) {
					throw new Error(
						`${where}: requires_${driver} token "${token}" has no ${driver} probe — ` +
							'add the probe to the driver before declaring the requirement'
					);
				}
			}
		}
	}
}

/**
 * Validates one order list against its family: every entry resolves, every
 * dispatchable row is ordered exactly once.
 * @param {unknown} items The `items` array.
 * @param {Record<string, object>} family Rows keyed by id.
 * @param {string} name Order table name.
 * @param {boolean} allowStructure Whether headings, separators and the chord
 *   placeholder may appear.
 */
function validateOrder(items, family, name, allowStructure) {
	if (!Array.isArray(items) || items.length === 0)
		throw new Error(`[${name}].items must be a non-empty array`);
	const seen = new Set();
	for (const item of items) {
		if (typeof item !== 'string') throw new Error(`[${name}].items: non-string entry`);
		if (allowStructure && (item === '--' || /^#{1,2}[a-z_][a-z0-9_]*$/.test(item))) continue;
		if (allowStructure && item.startsWith('#'))
			throw new Error(`[${name}].items: malformed heading "${item}"`);
		if (!family[item]) throw new Error(`[${name}].items: "${item}" has no table`);
		if (seen.has(item)) throw new Error(`[${name}].items: "${item}" is listed twice`);
		seen.add(item);
	}
	for (const id of Object.keys(family)) {
		if (!seen.has(id))
			throw new Error(`${name}: "${id}" is declared but never ordered — the picker would hide it`);
	}
}

/**
 * Builds the filtered catalogue model of one driver.
 * @param {object} data The validated registry.
 * @param {string} platform Driver key.
 * @returns {object} The model the renderers print.
 */
function buildModel(data, platform) {
	const actions = {};
	const claims = (row, where) => platformsOf(row.platform, where).includes(platform);

	for (const [family, rows] of [
		['sg', data.sg_actions],
		['ax', data.ax_actions]
	]) {
		for (const [id, row] of Object.entries(rows)) {
			if (row.is_header) continue;
			if (!claims(row, `${family}_actions.${id}`)) continue;
			if (actions[id]) throw new Error(`"${id}" is both an sg and an ax action`);
			const entry = { family, labelKey: `${family}_actions.${id}` };
			if (row.parameter) entry.parameter = row.parameter;
			if (row.confirm === true) entry.confirm = true;
			const req = row[`requires_${platform}`];
			if (req) entry.requires = [...req];
			actions[id] = entry;
		}
	}

	// Walk the order, keep what this driver claims, then drop the headings left
	// without content: "Navigation" holds two Windows-only rows, and an empty
	// heading on macOS reads as a list that failed to load.
	const raw = [];
	let parentLevel = 0;
	for (const item of data.sg_order.items) {
		if (item === '--') continue;
		const heading = item.match(/^(#{1,2})([a-z_][a-z0-9_]*)$/);
		if (heading) {
			parentLevel = heading[1].length;
			raw.push({ kind: 'heading', level: parentLevel, key: HEADER_KEY_PREFIX + heading[2] });
			continue;
		}
		if (item === CHORD_PLACEHOLDER) {
			if (!claims(data.sg_actions[item], `sg_actions.${item}`)) continue;
			raw.push({ kind: 'modifier_chords', level: parentLevel + 1, groupKey: CHORD_GROUP_KEY });
			continue;
		}
		if (actions[item]) raw.push({ kind: 'action', id: item });
	}
	const sgItems = [];
	for (let i = 0; i < raw.length; i++) {
		const entry = raw[i];
		if (entry.kind !== 'heading') {
			sgItems.push(entry);
			continue;
		}
		let hasContent = false;
		for (let j = i + 1; j < raw.length; j++) {
			if (raw[j].kind === 'heading' && raw[j].level <= entry.level) break;
			if (raw[j].kind !== 'heading') {
				hasContent = true;
				break;
			}
		}
		if (hasContent) sgItems.push(entry);
	}

	const axItems = data.ax_order.items.filter((id) => actions[id] && actions[id].family === 'ax');
	const model = { platform, sgItems, axItems, actions };
	if (platform === 'hs') model.karabinerAliases = { ...(data.karabiner_aliases || {}) };
	if (platform === 'linux')
		model.slots = { single: [...data.slots.single], axis: [...data.slots.axis] };
	return model;
}

/** A Lua double-quoted literal. */
const luaQ = (s) => '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';

/** An AHK v2 double-quoted literal (backtick is the escape character). */
const ahkQ = (s) => '"' + String(s).replace(/`/g, '``').replace(/"/g, '`"') + '"';

/**
 * Renders a Lua catalogue.
 * @param {object} model From buildModel.
 * @param {string} refresh The npm command that regenerates it.
 * @returns {string}
 */
function renderLua(model, refresh) {
	const label = model.platform === 'hs' ? 'macOS' : 'Linux';
	const out = [];
	out.push('--- _generated/action_catalogue.lua');
	out.push('--- AUTO-GENERATED from _shared/modules/actions/actions.toml.');
	out.push(`--- DO NOT EDIT BY HAND — run \`${refresh}\` to refresh.`);
	out.push('');
	out.push('--- ==============================================================================');
	out.push(`--- MODULE: Action Catalogue (${label})`);
	out.push('--- DESCRIPTION:');
	out.push(`--- Every action the ${label} driver offers, already filtered to its platform:`);
	out.push('--- the picker order with heading levels and locale keys, the modifier-chord');
	out.push('--- block the driver expands from its own chord registry, and per-action');
	out.push('--- metadata (label key, parameter kind, confirmation, requirements). The');
	out.push('--- driver loads this table instead of parsing the shared TOML at runtime.');
	out.push('--- ==============================================================================');
	out.push('');
	out.push('return {');
	out.push(`\tplatform = ${luaQ(model.platform)},`);
	out.push('\tsg_items = {');
	for (const item of model.sgItems) {
		if (item.kind === 'action') out.push(`\t\t{ kind = "action", id = ${luaQ(item.id)} },`);
		else if (item.kind === 'heading') {
			out.push(`\t\t{ kind = "heading", level = ${item.level}, key = ${luaQ(item.key)} },`);
		} else {
			out.push(
				`\t\t{ kind = "modifier_chords", level = ${item.level}, group_key = ${luaQ(item.groupKey)} },`
			);
		}
	}
	out.push('\t},');
	out.push(
		model.axItems.length
			? `\tax_items = { ${model.axItems.map(luaQ).join(', ')} },`
			: '\tax_items = {},'
	);
	out.push('\tactions = {');
	for (const id of Object.keys(model.actions).sort()) {
		const a = model.actions[id];
		const parts = [`family = ${luaQ(a.family)}`, `label_key = ${luaQ(a.labelKey)}`];
		if (a.parameter) parts.push(`parameter = ${luaQ(a.parameter)}`);
		if (a.confirm) parts.push('confirm = true');
		if (a.requires) parts.push(`requires = { ${a.requires.map(luaQ).join(', ')} }`);
		out.push(`\t\t[${luaQ(id)}] = { ${parts.join(', ')} },`);
	}
	out.push('\t},');
	if (model.karabinerAliases) {
		out.push('\tkarabiner_aliases = {');
		for (const alias of Object.keys(model.karabinerAliases).sort()) {
			out.push(`\t\t[${luaQ(alias)}] = ${luaQ(model.karabinerAliases[alias])},`);
		}
		out.push('\t},');
	}
	if (model.slots) {
		out.push('\tslots = {');
		out.push(`\t\tsingle = { ${model.slots.single.map(luaQ).join(', ')} },`);
		out.push(`\t\taxis = { ${model.slots.axis.map(luaQ).join(', ')} },`);
		out.push('\t},');
	}
	out.push('}');
	out.push('');
	return out.join('\n');
}

/**
 * Renders the AutoHotkey catalogue. One statement per line: a single Map
 * literal of a few hundred entries is one giant expression for the parser.
 * @param {object} model From buildModel.
 * @param {string} refresh The npm command that regenerates it.
 * @returns {string}
 */
function renderAhk(model, refresh) {
	const out = [];
	out.push('﻿; _generated/action_catalogue.ahk');
	out.push('; AUTO-GENERATED from _shared/modules/actions/actions.toml.');
	out.push(`; DO NOT EDIT BY HAND — run \`${refresh}\` to refresh.`);
	out.push('#Requires AutoHotkey v2.0');
	out.push('');
	out.push('; ==============================================================================');
	out.push('; MODULE: Action Catalogue (Windows)');
	out.push('; DESCRIPTION:');
	out.push('; Every action the Windows driver offers, already filtered to its platform:');
	out.push('; the picker order with heading levels and locale keys, the modifier-chord');
	out.push('; block the driver expands from its own chord registry, and per-action');
	out.push('; metadata (label key, parameter kind, confirmation). A data function rather');
	out.push('; than a global, so include order cannot matter, and no TOML is parsed to');
	out.push('; build the picker.');
	out.push('; ==============================================================================');
	out.push('');
	out.push('GestureActionCatalogueData() {');
	out.push(
		`\tCatalogue := { Platform: ${ahkQ(model.platform)}, SgItems: [], AxItems: [], Actions: Map() }`
	);
	out.push('\tItems := Catalogue.SgItems');
	for (const item of model.sgItems) {
		if (item.kind === 'action') out.push(`\tItems.Push({ Kind: "action", Id: ${ahkQ(item.id)} })`);
		else if (item.kind === 'heading') {
			out.push(`\tItems.Push({ Kind: "heading", Level: ${item.level}, Key: ${ahkQ(item.key)} })`);
		} else {
			out.push(
				`\tItems.Push({ Kind: "modifier_chords", Level: ${item.level}, GroupKey: ${ahkQ(item.groupKey)} })`
			);
		}
	}
	for (const id of model.axItems) out.push(`\tCatalogue.AxItems.Push(${ahkQ(id)})`);
	out.push('\tActions := Catalogue.Actions');
	for (const id of Object.keys(model.actions).sort()) {
		const a = model.actions[id];
		const parts = [
			`Family: ${ahkQ(a.family)}`,
			`LabelKey: ${ahkQ(a.labelKey)}`,
			`Parameter: ${ahkQ(a.parameter || '')}`,
			`Confirm: ${a.confirm ? 'true' : 'false'}`
		];
		out.push(`\tActions[${ahkQ(id)}] := { ${parts.join(', ')} }`);
	}
	out.push('\treturn Catalogue');
	out.push('}');
	out.push('');
	return out.join('\n');
}

/**
 * Generates the three catalogues from a registry source.
 * @param {string} source TOML text.
 * @returns {Record<string, {path: string, text: string, model: object}>}
 */
function generate(source) {
	const data = parseRegistry(source);
	const refresh = 'npm run codegen:action-catalogue';
	const result = {};
	for (const platform of PLATFORMS) {
		const model = buildModel(data, platform);
		const text = platform === 'ahk' ? renderAhk(model, refresh) : renderLua(model, refresh);
		result[platform] = { path: OUTPUTS[platform], text, model };
	}
	return result;
}

module.exports = {
	generate,
	parseRegistry,
	buildModel,
	OUTPUTS,
	CHORD_GROUP_KEY,
	HEADER_KEY_PREFIX
};

if (require.main === module) {
	let generated;
	try {
		generated = generate(fs.readFileSync(CATALOGUE, 'utf8'));
	} catch (err) {
		console.error(`[ERROR] ${err.message}`);
		process.exit(1);
	}
	for (const platform of PLATFORMS) {
		const { path: rel, text, model } = generated[platform];
		const abs = path.join(ROOT, rel);
		fs.mkdirSync(path.dirname(abs), { recursive: true });
		fs.writeFileSync(abs, text, 'utf8');
		console.log(
			`  wrote ${rel} (${model.sgItems.length} picker item(s), ${Object.keys(model.actions).length} action(s))`
		);
	}
	console.log('[OK] action catalogues generated.');
}
