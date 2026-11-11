// tools/lib/kbd-dll/source.cjs

/**
 * ==============================================================================
 * MODULE: Layout Source <-> kbd Tables Model
 * DESCRIPTION:
 * Converts between the Ergopti layout source (docs/design/layout-source-format.md)
 * and the kbd tables model the Windows DLL builder reads (model.cjs):
 *   - toSource(model): a Windows layout (a KLC read by klc.cjs) as an editable
 *     source, one layer per character column, its dead keys and chains, its
 *     ligatures, Caps Lock attributes, virtual keys and key names;
 *   - fromSource(doc): a source as the tables a DLL holds, the Kana level
 *     included as the real KBDKANA column.
 * fromSource(toSource(m)) gives m back table for table, which is what the
 * fidelity test proves on the official bépo KLC.
 *
 * FEATURES & RATIONALE:
 * 1. Physical keys come from the shared registry (physical_keys.json, `ahk`
 *    scan codes), the only table that names a Windows scan code.
 * 2. A column is the selector Windows uses for it: Shift 1, Ctrl 2, AltGr 6
 *    (Ctrl+Alt, KLLF_ALTGR), Kana 8; Caps Lock is a key attribute (CAPLOK,
 *    SGCAPS, CAPLOKALTGR), never a layer, as in kbd.h.
 * 3. Fail fast: a model or a source this mapping cannot carry exactly is
 *    refused with a stable code instead of being approximated.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const C = require('./constants.cjs');
const Model = require('./model.cjs');
const { shared } = require('../paths.cjs');

// The modifier ids of a column's bits; AltGr (Ctrl+Alt) is the right Alt key.
const COLUMN_IDS = [
	[C.MOD_BITS.shift, 'shift'],
	[C.MOD_BITS.kana, 'kana']
];
const ALTGR = C.MOD_BITS.ctrl | C.MOD_BITS.alt;
const DEFAULT_KANA_KEY = 'AltRight';

/** A stable refusal of this conversion. */
class SourceMappingError extends Error {
	constructor(code, path) {
		super(`${code}: ${path}`);
		this.name = 'SourceMappingError';
		this.code = code;
		this.path = path;
	}
}
const fail = (code, path) => {
	throw new SourceMappingError(code, path);
};

/** Physical key name <-> extended scan code (0x1nn for an E0 key), from the registry. */
function scanTable() {
	const keys = JSON.parse(
		fs.readFileSync(shared('data', 'keycodes', 'physical_keys.json'), 'utf8')
	).keys;
	const bySc = new Map();
	const byCode = new Map();
	for (const [code, key] of Object.entries(keys)) {
		if (key.kind !== 'key' || typeof key.ahk !== 'string') continue;
		const match = /^SC([0-9A-F]{3})$/.exec(key.ahk);
		if (!match) continue;
		const sc = parseInt(match[1], 16);
		bySc.set(sc, code);
		byCode.set(code, sc);
	}
	return { bySc, byCode };
}

// The keypad scan codes keep their navigation key; Num Lock types these
// virtual keys (VK_DECIMAL, VK_NUMPAD0-9), which carry the characters.
const NUM_LOCK_VK = new Map([
	[0x53, 0x6e],
	[0x52, 0x60],
	[0x4f, 0x61],
	[0x50, 0x62],
	[0x51, 0x63],
	[0x4b, 0x64],
	[0x4c, 0x65],
	[0x4d, 0x66],
	[0x47, 0x67],
	[0x48, 0x68],
	[0x49, 0x69]
]);
const keypad = (sc) => Boolean(C.DEFAULT_SCANCODES[sc] & C.SC_FLAGS.NUMPAD);

/** The virtual key a scan code types characters with, without the layout's moves. */
const defaultVk = (sc) =>
	keypad(sc) && NUM_LOCK_VK.has(sc) ? NUM_LOCK_VK.get(sc) : C.DEFAULT_SCANCODES[sc] & 0xff;

/** The modifier ids of a column bit mask, or null when Windows types no character there. */
function columnIds(mask, altgr) {
	const ids = [];
	let rest = mask;
	if (altgr && (mask & ALTGR) === ALTGR) {
		ids.push('alt_right');
		rest &= ~ALTGR;
	}
	if (rest & C.MOD_BITS.ctrl) {
		ids.push('control');
		rest &= ~C.MOD_BITS.ctrl;
	}
	for (const [bit, id] of COLUMN_IDS)
		if (rest & bit) {
			ids.push(id);
			rest &= ~bit;
		}
	return rest === 0 ? ids : null;
}

/** A layer id for a column's modifiers, readable and stable. */
function layerId(ids) {
	if (ids.length === 0) return 'base';
	const named = ids.map((id) => (id === 'alt_right' ? 'altgr' : id));
	return named.includes('shift')
		? ['shift', ...named.filter((n) => n !== 'shift')].join('_')
		: named.join('_');
}

const text = (units) => String.fromCharCode(...units);
const unitsOf = (string) => Array.from({ length: string.length }, (_, i) => string.charCodeAt(i));
const deadId = (unit) => `dead_${unit.toString(16).padStart(4, '0')}`;

// =================================
// ======= 1/ Model -> source ======
// =================================

/**
 * A Windows layout as an Ergopti layout source.
 * @param {object} model - A checked kbd tables model.
 * @param {{id: string, name?: string}} options
 * @returns {object} The source document (validate it with LayoutSource).
 */
function toSource(model, options) {
	Model.check(model);
	const altgr = model.flags.includes('altgr');
	const { bySc } = scanTable();
	// Effective scan code -> virtual key, the layout's moves applied.
	const vkOfSc = new Map();
	for (let sc = 1; sc < 0x80; sc++) if (defaultVk(sc)) vkOfSc.set(sc, defaultVk(sc));
	for (const move of model.scancodes) vkOfSc.set(move.sc, move.vk);
	const scOfVk = new Map();
	for (const [sc, vk] of vkOfSc)
		if (!scOfVk.has(vk) || model.scancodes.some((m) => m.sc === sc)) scOfVk.set(vk, sc);
	const declared = new Set(model.dead_keys.map((dead) => dead.dead));
	const layers = model.columns.map((mask, column) => {
		const ids = columnIds(mask, altgr);
		if (ids === null) fail('source_column_unmapped', `columns[${column}]`);
		return { id: layerId(ids), required: ids, optional: [], keys: {} };
	});
	const keys = {};
	const unplacedNames = {};
	model.keys.forEach((key, index) => {
		const sc = scOfVk.get(key.vk);
		const code = sc === undefined ? undefined : bySc.get(sc);
		if (code === undefined) fail('source_key_unplaced', `keys[${index}]`);
		if (key.attributes & C.ATTRIBUTES.sgcaps) fail('source_sgcaps_unsupported', `keys[${index}]`);
		if (key.attributes & C.ATTRIBUTES.kanalok) fail('source_kanalok_unsupported', `keys[${index}]`);
		key.cells.forEach((cell, column) => {
			if (cell === null) return;
			const mapping = own(cell, 'char')
				? { text: text([cell.char]) }
				: own(cell, 'ligature')
					? { text: text(cell.ligature) }
					: { dead_key: deadId(cell.dead) };
			layers[column].keys[code] = mapping;
		});
		const entry = {};
		if (key.attributes & C.ATTRIBUTES.caplok) entry.caps_lock = 'shift';
		if (key.attributes & C.ATTRIBUTES.caplokaltgr) entry.caps_altgr = true;
		if (defaultVk(sc) !== key.vk) entry.virtual_key = key.vk;
		if (Object.keys(entry).length) keys[code] = entry;
	});
	for (const [field, extended] of [
		['key_names', 0],
		['key_names_ext', 0x100]
	])
		model[field].forEach((named) => {
			const code = bySc.get(named.sc | extended);
			if (code !== undefined) keys[code] = Object.assign(keys[code] || {}, { name: named.name });
			else
				unplacedNames[`${extended ? 'e0' : 'sc'}_${named.sc.toString(16).padStart(2, '0')}`] =
					named.name;
		});
	const deadKeys = model.dead_keys.map((dead) => {
		const rules = [];
		for (const rule of dead.rules) {
			const result = rule.dead ? { next: deadId(rule.result) } : { text: text([rule.result]) };
			rules.push(Object.assign({ input: text([rule.base]) }, result));
			// A dead key pressed while this one is pending sends its own character.
			if (declared.has(rule.base) && rule.base !== dead.dead)
				rules.push(Object.assign({ input_dead_key: deadId(rule.base) }, result));
		}
		return Object.assign(
			{ id: deadId(dead.dead) },
			dead.name === undefined ? {} : { name: dead.name },
			{ terminator: text([dead.dead]), rules }
		);
	});
	const source = {
		format: 'ergopti-layout',
		version: 1,
		layout: { id: options.id, name: options.name || model.layout_text },
		physical: { base: 'iso' },
		layers
	};
	if (Object.keys(keys).length) source.keys = keys;
	if (deadKeys.length) source.dead_keys = deadKeys;
	const windows = {};
	if (model.flags.length) windows.flags = model.flags.slice();
	if (Object.keys(unplacedNames).length) windows.key_names = unplacedNames;
	if (Object.keys(windows).length) source.windows = windows;
	const texts = (entries) =>
		Object.fromEntries(entries.map((entry) => [entry.lang.toLowerCase(), entry.text]));
	source.exports = {
		windows: Object.assign(
			{
				locale: model.locale_name,
				layout_id: `0000${model.lcid.toLowerCase()}`,
				dll_name: model.dll_name
			},
			model.copyright ? { copyright: model.copyright } : {},
			model.company ? { company: model.company } : {},
			model.descriptions.length ? { descriptions: texts(model.descriptions) } : {},
			model.language_names.length ? { language_names: texts(model.language_names) } : {}
		)
	};
	return source;
}

// =================================
// ======= 2/ Source -> model ======
// =================================

/** The column mask of a layer selector, or null when Windows has no such column. */
function selectorMask(selector, altgr) {
	// An optional Caps Lock keeps the column as it is with Caps Lock on.
	if (selector.optional.some((id) => id !== 'caps_lock')) return null;
	let mask = 0;
	for (const id of selector.required) {
		if (id === 'shift') mask |= C.MOD_BITS.shift;
		else if (id === 'control') mask |= C.MOD_BITS.ctrl;
		else if (id === 'kana') mask |= C.MOD_BITS.kana;
		else if (id === 'alt_right' && altgr) mask |= ALTGR;
		else return null;
	}
	return mask;
}

/**
 * A source as the tables of a Windows DLL. Layers whose selector has no
 * Windows column (Command, Caps Lock, a custom modifier) are listed in
 * `omitted`; a Caps Lock layer is read back as the CAPLOK attribute when it
 * types each key's Shift column, else the source is refused.
 * @param {object} source - A validated structured source with exports.windows.
 * @param {{lcid?: string}} [options]
 * @returns {{model: object, omitted: {path: string, reason: string}[]}}
 */
function fromSource(source) {
	const windows = source.exports && source.exports.windows;
	if (!windows) fail('source_windows_metadata', 'exports.windows');
	const altgr =
		((source.windows && source.windows.flags) || []).includes('altgr') ||
		source.layers.some((layer) => layer.required.includes('alt_right'));
	const { byCode } = scanTable();
	const omitted = [];
	const columns = [];
	const columnLayers = [];
	// A Caps Lock layer of the base or Shift column becomes the key's CAPLOK or
	// SGCAPS row, as kbd.h holds Caps Lock: an attribute, not a column.
	const capsLayers = new Map();
	for (const layer of source.layers) {
		if (!layer.required.includes('caps_lock') || (layer.alternatives || []).length) continue;
		const mask = selectorMask(
			{ required: layer.required.filter((id) => id !== 'caps_lock'), optional: layer.optional },
			altgr
		);
		if (mask !== null) capsLayers.set(mask, layer);
	}
	const capsLayerIds = new Set([...capsLayers.values()].map((layer) => layer.id));
	for (const layer of source.layers) {
		if (capsLayerIds.has(layer.id)) continue;
		const mask = selectorMask(layer, altgr);
		if (mask === null || (layer.alternatives || []).length) {
			omitted.push({ path: `layers.${layer.id}`, reason: 'no_windows_column' });
			continue;
		}
		if (columns.includes(mask)) fail('source_column_duplicate', `layers.${layer.id}`);
		columns.push(mask);
		columnLayers.push(layer);
	}
	if (columns[0] !== 0) fail('source_base_column', 'layers');
	const deadUnit = new Map();
	for (const dead of source.dead_keys || []) {
		const units = unitsOf(dead.terminator);
		if (units.length !== 1) fail('source_dead_terminator_unit', `dead_keys.${dead.id}`);
		deadUnit.set(dead.id, units[0]);
	}
	const codes = new Set(
		columnLayers.concat([...capsLayers.values()]).flatMap((layer) => Object.keys(layer.keys))
	);
	// A key Windows has no scan code for (macOS's keypad =) is said, not dropped.
	for (const code of codes)
		if (!byCode.has(code)) omitted.push({ path: `keys.${code}`, reason: 'no_windows_scan_code' });
	const keyFields = source.keys || {};
	const keys = [];
	const scancodes = [];
	const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
	for (const code of [...byCode.keys()].filter((c) => codes.has(c))) {
		const sc = byCode.get(code);
		const fields = keyFields[code] || {};
		// An E0 key (keypad divide, keypad Enter…) keeps its standard virtual key.
		const e0 = sc >= 0x100 ? C.DEFAULT_E0.find(([low]) => low === (sc & 0xff)) : undefined;
		if (sc >= 0x100 && (e0 === undefined || own(fields, 'virtual_key')))
			fail('source_extended_character_key', code);
		const vk = e0 ? e0[1] & 0xff : own(fields, 'virtual_key') ? fields.virtual_key : defaultVk(sc);
		if (!vk) fail('source_key_without_vk', code);
		if (!e0 && vk !== defaultVk(sc)) {
			if (keypad(sc)) fail('source_keypad_virtual_key', `keys.${code}`);
			scancodes.push({ sc, vk });
		}
		const cellOf = (layer) => {
			const mapping = layer.keys[code];
			if (mapping === undefined || mapping.disabled) return null;
			if (own(mapping, 'dead_key')) return { dead: deadUnit.get(mapping.dead_key) };
			if (!own(mapping, 'text')) {
				omitted.push({ path: `layers.${layer.id}.keys.${code}`, reason: 'not_a_character' });
				return null;
			}
			const units = unitsOf(mapping.text);
			return units.length === 1 ? { char: units[0] } : { ligature: units };
		};
		const cells = columnLayers.map(cellOf);
		let attributes = 0;
		let capsCells;
		if (capsLayers.size) {
			const cellAt = (mask) => (columns.includes(mask) ? cells[columns.indexOf(mask)] : null);
			const capsAt = (mask) => (capsLayers.has(mask) ? cellOf(capsLayers.get(mask)) : cellAt(mask));
			// Each pair of a column and its Shift: unchanged, swapped (CAPLOK for the
			// base pair, CAPLOKALTGR for the AltGr pair), or anything else, which only
			// a Caps Lock row (SGCAPS) holds: Kana has no Caps Lock attribute of its own.
			const swapped = (low) => {
				const high = low | C.MOD_BITS.shift;
				return (
					same(capsAt(low), cellAt(high)) &&
					same(capsAt(high), cellAt(low)) &&
					!same(cellAt(low), cellAt(high))
				);
			};
			const unchanged = (mask) => same(capsAt(mask), cellAt(mask));
			const pairs = [...new Set(columns.map((mask) => mask & ~C.MOD_BITS.shift))];
			const kinds = pairs.map((low) =>
				unchanged(low) && unchanged(low | C.MOD_BITS.shift)
					? 'same'
					: swapped(low) && (low === 0 || (altgr && low === ALTGR))
						? 'swap'
						: 'row'
			);
			if (kinds.includes('row')) {
				attributes |= C.ATTRIBUTES.sgcaps;
				capsCells = columns.map((mask) => capsAt(mask));
				if (capsCells.some((cell) => cell && (own(cell, 'dead') || own(cell, 'ligature'))))
					fail('source_caps_lock_row_dead_or_ligature', `keys.${code}`);
				if (cells.some((cell) => cell && own(cell, 'dead')))
					fail('source_caps_lock_row_beside_dead_key', `keys.${code}`);
			} else
				pairs.forEach((low, i) => {
					if (kinds[i] !== 'swap') return;
					attributes |= low === 0 ? C.ATTRIBUTES.caplok : C.ATTRIBUTES.caplokaltgr;
				});
		}
		if (fields.caps_lock === 'shift') attributes |= C.ATTRIBUTES.caplok;
		if (fields.caps_lock === 'separate') fail('source_sgcaps_unsupported', `keys.${code}`);
		if (fields.caps_altgr) attributes |= C.ATTRIBUTES.caplokaltgr;
		const row = capsCells
			? { vk, attributes, cells, caps_cells: capsCells }
			: { vk, attributes, cells };
		// Two physical keys of one virtual key (Enter and keypad Enter) share one row.
		const twin = keys.find((key) => key.vk === vk);
		if (twin) {
			if (!same(twin, row)) omitted.push({ path: `keys.${code}`, reason: 'shares_a_virtual_key' });
			continue;
		}
		keys.push(row);
	}
	const names = { key_names: [], key_names_ext: [] };
	for (const [code, fields] of Object.entries(keyFields)) {
		if (!own(fields, 'name')) continue;
		const sc = byCode.get(code);
		if (sc === undefined) fail('source_key_name_unplaced', `keys.${code}`);
		names[sc >= 0x100 ? 'key_names_ext' : 'key_names'].push({ sc: sc & 0xff, name: fields.name });
	}
	for (const [scan, name] of Object.entries((source.windows && source.windows.key_names) || {}))
		names[scan.startsWith('e0_') ? 'key_names_ext' : 'key_names'].push({
			sc: parseInt(scan.slice(3), 16),
			name
		});
	for (const list of Object.values(names)) list.sort((a, b) => a.sc - b.sc);
	const deadKeys = (source.dead_keys || []).map((dead) => {
		const rules = [];
		const seen = new Map();
		for (const rule of dead.rules) {
			const base = own(rule, 'input') ? unitsOf(rule.input) : [deadUnit.get(rule.input_dead_key)];
			if (base.length !== 1) fail('source_dead_input_unit', `dead_keys.${dead.id}`);
			const entry = own(rule, 'next')
				? { base: base[0], result: deadUnit.get(rule.next), dead: true }
				: { base: base[0], result: unitsOf(rule.text) };
			if (!entry.dead) {
				if (entry.result.length !== 1) fail('source_dead_result_unit', `dead_keys.${dead.id}`);
				entry.result = entry.result[0];
			}
			const key = entry.base;
			if (seen.has(key)) {
				if (JSON.stringify(seen.get(key)) !== JSON.stringify(entry))
					fail('source_dead_input_conflict', `dead_keys.${dead.id}`);
				continue;
			}
			seen.set(key, entry);
			rules.push(entry);
		}
		return Object.assign(
			{ dead: deadUnit.get(dead.id) },
			dead.name === undefined ? {} : { name: dead.name },
			{ rules }
		);
	});
	// The physical key that holds Kana: VK_OEM_8 on it and Kana's bit on VK_OEM_8,
	// KbdEdit's momentary (non-togglable) Kana; Right Alt unless the source names
	// another (decided by the coordinator on 2026-11-11, to review by the maintainer).
	const extra = {};
	if (columns.some((mask) => mask & C.MOD_BITS.kana)) {
		const kanaKey = (source.windows && source.windows.kana_key) || DEFAULT_KANA_KEY;
		const sc = byCode.get(kanaKey);
		if (sc === undefined) fail('source_kana_key_unplaced', 'windows.kana_key');
		extra.modifier_vks = { kana: C.VK.OEM_8 };
		if (sc >= 0x100) extra.scancodes_e0 = [{ sc: sc & 0xff, vk: C.VK.OEM_8 }];
		else scancodes.push({ sc, vk: C.VK.OEM_8 });
	}
	const model = {
		format: Model.FORMAT,
		version: Model.VERSION,
		dll_name: windows.dll_name,
		layout_text: source.layout.name,
		locale_name: windows.locale,
		lcid: windows.layout_id.slice(4).toLowerCase(),
		version_string: '1.0',
		copyright: windows.copyright || '',
		company: windows.company || '',
		flags: altgr ? ['altgr'] : [],
		columns,
		scancodes,
		keys,
		dead_keys: deadKeys,
		key_names: names.key_names,
		key_names_ext: names.key_names_ext,
		descriptions: Object.entries(windows.descriptions || {}).map(([lang, text]) => ({
			lang,
			text
		})),
		language_names: Object.entries(windows.language_names || {}).map(([lang, text]) => ({
			lang,
			text
		})),
		...extra
	};
	return { model: Model.check(model), omitted };
}

function own(value, key) {
	return Object.prototype.hasOwnProperty.call(value, key);
}

module.exports = { toSource, fromSource, SourceMappingError };
