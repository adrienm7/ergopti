// tools/lib/kbd-dll/model.cjs

/**
 * ==============================================================================
 * MODULE: Keyboard Layout Tables Model
 * DESCRIPTION:
 * The JSON form of everything a Windows keyboard layout DLL holds, the one
 * input of the C emitter (docs/design/layout-windows-dll.md, « The model »):
 * the columns (modifier-bit combinations), the character keys with their
 * attributes and cells, the dead keys and their chains, the ligatures, the key
 * names and the locale flags. `check` refuses an invalid model with a stable
 * code before anything is written.
 *
 * FEATURES & RATIONALE:
 * 1. Characters are UTF-16 code units, as the DLL stores them: a cell holds one
 *    unit; a ligature holds several (a non-BMP character is its surrogate pair).
 * 2. Kana, Roya and Loya are columns like Shift, Ctrl and Alt: a column is any
 *    combination of the six modifier bits, so the Kana level is first-class.
 * 3. Fail fast: a cell naming an undeclared dead key, a dead chain to nowhere,
 *    a reserved code unit (WCH_NONE, WCH_DEAD, WCH_LGTR), a duplicate key, a
 *    column count over 126 or a ligature over 15 units refuses the model.
 * ==============================================================================
 */

'use strict';

const C = require('./constants.cjs');

const FORMAT = 'ergopti-kbd-tables';
const VERSION = 1;
// The VK_TO_WCHAR_TABLE row size is a BYTE: 2 + 2 * columns must fit.
const MAX_COLUMNS = 126;
// A LIGATURE entry's size (cbLgEntry) is a BYTE: 4 + 2 * units must fit, and
// Windows' own tables never exceed 16 units.
const MAX_LIGATURE_UNITS = 15;
const ALL_BITS = Object.values(C.MOD_BITS).reduce((a, b) => a | b, 0);

/** A refused model: a stable code and the path that refuses it. */
class ModelError extends Error {
	constructor(code, path) {
		super(`${code}: ${path}`);
		this.name = 'ModelError';
		this.code = code;
		this.path = path;
	}
}

const fail = (code, path) => {
	throw new ModelError(code, path);
};

const isUnit = (value) => Number.isInteger(value) && value >= 1 && value <= 0xffff;
const reserved = (unit) => unit === C.WCH.NONE || unit === C.WCH.DEAD || unit === C.WCH.LGTR;

/** Checks one code unit a table stores as a character. */
function checkUnit(unit, path) {
	if (!isUnit(unit)) fail('kbd_unit_invalid', path);
	if (reserved(unit)) fail('kbd_unit_reserved', path);
}

/** Checks a cell: null, {char}, {dead} or {ligature}. */
function checkCell(cell, path, deadIds) {
	if (cell === null) return;
	if (typeof cell !== 'object') fail('kbd_cell_invalid', path);
	const kinds = ['char', 'dead', 'ligature'].filter((k) => Object.hasOwn(cell, k));
	if (kinds.length !== 1 || Object.keys(cell).length !== 1) fail('kbd_cell_invalid', path);
	if (kinds[0] === 'char') checkUnit(cell.char, `${path}.char`);
	if (kinds[0] === 'dead') {
		checkUnit(cell.dead, `${path}.dead`);
		if (!deadIds.has(cell.dead)) fail('kbd_dead_undeclared', `${path}.dead`);
	}
	if (kinds[0] === 'ligature') {
		const units = cell.ligature;
		if (!Array.isArray(units) || units.length < 2 || units.length > MAX_LIGATURE_UNITS)
			fail('kbd_ligature_length', `${path}.ligature`);
		units.forEach((unit, i) => checkUnit(unit, `${path}.ligature[${i}]`));
	}
}

/**
 * Validates a model; returns it unchanged or throws a ModelError.
 * @param {object} model
 * @returns {object}
 */
function check(model) {
	if (!model || model.format !== FORMAT) fail('kbd_format', 'format');
	if (model.version !== VERSION) fail('kbd_version', 'version');
	if (typeof model.dll_name !== 'string' || !/^[a-z][a-z0-9]{0,7}$/.test(model.dll_name))
		fail('kbd_dll_name', 'dll_name');
	for (const field of ['layout_text', 'locale_name'])
		if (
			typeof model[field] !== 'string' ||
			model[field] === '' ||
			/[\u0000-\u001f"]/.test(model[field])
		)
			fail('kbd_text_invalid', field);
	if (typeof model.lcid !== 'string' || !/^[0-9a-f]{4}$/.test(model.lcid) || model.lcid === '0000')
		fail('kbd_lcid', 'lcid');
	const flags = model.flags || [];
	if (!Array.isArray(flags) || flags.some((f) => !Object.hasOwn(C.LOCALE_FLAGS, f)))
		fail('kbd_flag_unknown', 'flags');
	const columns = model.columns;
	if (!Array.isArray(columns) || columns.length === 0 || columns.length > MAX_COLUMNS)
		fail('kbd_columns', 'columns');
	if (columns[0] !== 0) fail('kbd_columns_base', 'columns[0]');
	columns.forEach((bits, i) => {
		if (!Number.isInteger(bits) || bits < 0 || (bits & ~ALL_BITS) !== 0)
			fail('kbd_column_bits', `columns[${i}]`);
	});
	if (new Set(columns).size !== columns.length) fail('kbd_column_duplicate', 'columns');
	const deadIds = new Set();
	(model.dead_keys || []).forEach((dead, i) => {
		checkUnit(dead.dead, `dead_keys[${i}].dead`);
		if (deadIds.has(dead.dead)) fail('kbd_dead_duplicate', `dead_keys[${i}]`);
		deadIds.add(dead.dead);
	});
	(model.dead_keys || []).forEach((dead, i) => {
		if (!Array.isArray(dead.rules) || dead.rules.length === 0)
			fail('kbd_dead_empty', `dead_keys[${i}]`);
		const bases = new Set();
		dead.rules.forEach((rule, j) => {
			const path = `dead_keys[${i}].rules[${j}]`;
			checkUnit(rule.base, `${path}.base`);
			checkUnit(rule.result, `${path}.result`);
			if (bases.has(rule.base)) fail('kbd_dead_rule_duplicate', path);
			bases.add(rule.base);
			if (rule.dead === true && !deadIds.has(rule.result)) fail('kbd_dead_chain_undeclared', path);
		});
	});
	const vks = new Set();
	(model.keys || []).forEach((key, i) => {
		const path = `keys[${i}]`;
		if (!Number.isInteger(key.vk) || key.vk < 1 || key.vk >= C.VK_FOLLOW_ROW)
			fail('kbd_vk', `${path}.vk`);
		if (vks.has(key.vk)) fail('kbd_key_duplicate', path);
		vks.add(key.vk);
		const known = Object.values(C.ATTRIBUTES).reduce((a, b) => a | b, 0);
		if (!Number.isInteger(key.attributes) || (key.attributes & ~known) !== 0)
			fail('kbd_attributes', `${path}.attributes`);
		if (!Array.isArray(key.cells) || key.cells.length !== columns.length)
			fail('kbd_cells_count', `${path}.cells`);
		key.cells.forEach((cell, c) => checkCell(cell, `${path}.cells[${c}]`, deadIds));
		const sg = (key.attributes & C.ATTRIBUTES.sgcaps) !== 0;
		if (sg !== Array.isArray(key.caps_cells)) fail('kbd_sgcaps_row', `${path}.caps_cells`);
		if (sg) {
			if (key.caps_cells.length !== columns.length) fail('kbd_cells_count', `${path}.caps_cells`);
			key.caps_cells.forEach((cell, c) => {
				checkCell(cell, `${path}.caps_cells[${c}]`, deadIds);
				// One follow row per key: Caps Lock's row cannot also carry dead characters.
				if (cell && (cell.dead !== undefined || cell.ligature !== undefined))
					fail('kbd_sgcaps_cell', `${path}.caps_cells[${c}]`);
			});
			if (key.cells.some((cell) => cell && cell.dead !== undefined)) fail('kbd_sgcaps_dead', path);
		}
	});
	(model.scancodes || []).forEach((entry, i) => {
		if (!Number.isInteger(entry.sc) || entry.sc < 1 || entry.sc > 0x7f)
			fail('kbd_scancode', `scancodes[${i}].sc`);
		if (!Number.isInteger(entry.vk) || entry.vk < 1 || entry.vk > 0xfe)
			fail('kbd_vk', `scancodes[${i}].vk`);
	});
	for (const field of ['key_names', 'key_names_ext'])
		(model[field] || []).forEach((entry, i) => {
			if (!Number.isInteger(entry.sc) || entry.sc < 1 || entry.sc > 0xff)
				fail('kbd_scancode', `${field}[${i}].sc`);
			if (typeof entry.name !== 'string' || entry.name === '')
				fail('kbd_text_invalid', `${field}[${i}].name`);
		});
	(model.dead_keys || []).forEach((dead, i) => {
		if (dead.name !== undefined && (typeof dead.name !== 'string' || dead.name === ''))
			fail('kbd_text_invalid', `dead_keys[${i}].name`);
	});
	return model;
}

/** The modifier names a model's columns use, in bit order (VK_TO_BIT rows). */
function modifierNames(model) {
	const used = model.columns.reduce((a, b) => a | b, 0);
	// Shift, Ctrl and Alt are always declared, as every Windows layout does.
	return Object.keys(C.MOD_BITS).filter(
		(name) => ['shift', 'ctrl', 'alt'].includes(name) || (used & C.MOD_BITS[name]) !== 0
	);
}

/** The locale flags word: KLLF bits low, KBD_VERSION high. */
function localeFlags(model) {
	const bits = (model.flags || []).reduce((a, f) => a | C.LOCALE_FLAGS[f], 0);
	return ((C.KBD_VERSION << 16) | bits) >>> 0;
}

module.exports = {
	FORMAT,
	VERSION,
	MAX_COLUMNS,
	MAX_LIGATURE_UNITS,
	ModelError,
	check,
	modifierNames,
	localeFlags
};
