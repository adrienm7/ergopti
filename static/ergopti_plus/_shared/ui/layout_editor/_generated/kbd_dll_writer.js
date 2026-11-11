// _shared/ui/layout_editor/_generated/kbd_dll_writer.js

// ==========================================
// AUTO-GENERATED — do not edit manually
// Sources: tools/lib/kbd-dll/{constants.cjs,model.cjs,emit-c.cjs,source.cjs,pe-writer.cjs}
// Run: npm run codegen:layout-editor-kbd-dll:js
// ==========================================

// The repository tool's Windows keyboard layout DLL writer, loaded by the layout editor page.
var LayoutKbdDll = (function () {
	var loaded = {};
	var factories = {};
	function load(name) {
		if (["node:fs","../paths.cjs"].indexOf(name) >= 0)
			throw new Error(name + ' reads the repository; pass physicalKeys in the page');
		if (!factories[name]) throw new Error('kbd dll module not bundled: ' + name);
		if (!loaded[name]) {
			var module = { exports: {} };
			loaded[name] = module;
			factories[name](module, module.exports, load);
		}
		return loaded[name].exports;
	}
	factories['./constants.cjs'] = function (module, exports, require) {
// tools/lib/kbd-dll/constants.cjs

/**
 * ==============================================================================
 * MODULE: Keyboard Layout DLL Constants
 * DESCRIPTION:
 * The numeric vocabulary of a Windows keyboard layout DLL, written from
 * Microsoft's public documentation of the kbd.h tables (WDK « Keyboard layout
 * samples », the Virtual-Key Codes reference and the Keyboard Input overview):
 * virtual-key codes, the shift-state bits, the per-key attributes, the locale
 * flags, the scan-code flag bits and the standard 101/102-key scan-code to
 * virtual-key tables every layout starts from.
 *
 * FEATURES & RATIONALE:
 * 1. One owner: the KLC reader, the model checks and the C emitter take every
 *    number from here; the independent DLL reader keeps its own copy on purpose
 *    so a wrong value here cannot agree with itself.
 * 2. The default scan-code tables are the standard PC/AT set 1 assignment a
 *    layout keeps unless its LAYOUT section moves a character key.
 * ==============================================================================
 */

'use strict';

// =================================
// ======= 1/ Virtual keys =========
// =================================

const VK = Object.freeze({
	CANCEL: 0x03,
	BACK: 0x08,
	TAB: 0x09,
	CLEAR: 0x0c,
	RETURN: 0x0d,
	SHIFT: 0x10,
	CONTROL: 0x11,
	MENU: 0x12,
	PAUSE: 0x13,
	CAPITAL: 0x14,
	KANA: 0x15,
	IME_ON: 0x16,
	JUNJA: 0x17,
	FINAL: 0x18,
	KANJI: 0x19,
	IME_OFF: 0x1a,
	ESCAPE: 0x1b,
	CONVERT: 0x1c,
	NONCONVERT: 0x1d,
	ACCEPT: 0x1e,
	MODECHANGE: 0x1f,
	SPACE: 0x20,
	PRIOR: 0x21,
	NEXT: 0x22,
	END: 0x23,
	HOME: 0x24,
	LEFT: 0x25,
	UP: 0x26,
	RIGHT: 0x27,
	DOWN: 0x28,
	SELECT: 0x29,
	PRINT: 0x2a,
	EXECUTE: 0x2b,
	SNAPSHOT: 0x2c,
	INSERT: 0x2d,
	DELETE: 0x2e,
	HELP: 0x2f,
	...Object.fromEntries([...'0123456789'].map((d, i) => [d, 0x30 + i])),
	...Object.fromEntries([...'ABCDEFGHIJKLMNOPQRSTUVWXYZ'].map((c, i) => [c, 0x41 + i])),
	LWIN: 0x5b,
	RWIN: 0x5c,
	APPS: 0x5d,
	SLEEP: 0x5f,
	...Object.fromEntries(Array.from({ length: 10 }, (_, i) => [`NUMPAD${i}`, 0x60 + i])),
	MULTIPLY: 0x6a,
	ADD: 0x6b,
	SEPARATOR: 0x6c,
	SUBTRACT: 0x6d,
	DECIMAL: 0x6e,
	DIVIDE: 0x6f,
	...Object.fromEntries(Array.from({ length: 24 }, (_, i) => [`F${i + 1}`, 0x70 + i])),
	NUMLOCK: 0x90,
	SCROLL: 0x91,
	OEM_NEC_EQUAL: 0x92,
	OEM_FJ_MASSHOU: 0x93,
	OEM_FJ_TOUROKU: 0x94,
	OEM_FJ_LOYA: 0x95,
	OEM_FJ_ROYA: 0x96,
	LSHIFT: 0xa0,
	RSHIFT: 0xa1,
	LCONTROL: 0xa2,
	RCONTROL: 0xa3,
	LMENU: 0xa4,
	RMENU: 0xa5,
	BROWSER_BACK: 0xa6,
	BROWSER_FORWARD: 0xa7,
	BROWSER_REFRESH: 0xa8,
	BROWSER_STOP: 0xa9,
	BROWSER_SEARCH: 0xaa,
	BROWSER_FAVORITES: 0xab,
	BROWSER_HOME: 0xac,
	VOLUME_MUTE: 0xad,
	VOLUME_DOWN: 0xae,
	VOLUME_UP: 0xaf,
	MEDIA_NEXT_TRACK: 0xb0,
	MEDIA_PREV_TRACK: 0xb1,
	MEDIA_STOP: 0xb2,
	MEDIA_PLAY_PAUSE: 0xb3,
	LAUNCH_MAIL: 0xb4,
	LAUNCH_MEDIA_SELECT: 0xb5,
	LAUNCH_APP1: 0xb6,
	LAUNCH_APP2: 0xb7,
	OEM_1: 0xba,
	OEM_PLUS: 0xbb,
	OEM_COMMA: 0xbc,
	OEM_MINUS: 0xbd,
	OEM_PERIOD: 0xbe,
	OEM_2: 0xbf,
	OEM_3: 0xc0,
	ABNT_C1: 0xc1,
	ABNT_C2: 0xc2,
	OEM_4: 0xdb,
	OEM_5: 0xdc,
	OEM_6: 0xdd,
	OEM_7: 0xde,
	OEM_8: 0xdf,
	OEM_AX: 0xe1,
	OEM_102: 0xe2,
	ICO_HELP: 0xe3,
	ICO_00: 0xe4,
	PROCESSKEY: 0xe5,
	ICO_CLEAR: 0xe6,
	PACKET: 0xe7,
	OEM_RESET: 0xe9,
	OEM_JUMP: 0xea,
	OEM_PA1: 0xeb,
	OEM_PA2: 0xec,
	OEM_PA3: 0xed,
	OEM_WSCTRL: 0xee,
	OEM_CUSEL: 0xef,
	OEM_ATTN: 0xf0,
	OEM_FINISH: 0xf1,
	OEM_COPY: 0xf2,
	OEM_AUTO: 0xf3,
	OEM_ENLW: 0xf4,
	OEM_BACKTAB: 0xf5,
	ATTN: 0xf6,
	CRSEL: 0xf7,
	EXSEL: 0xf8,
	EREOF: 0xf9,
	PLAY: 0xfa,
	ZOOM: 0xfb,
	NONAME: 0xfc,
	PA1: 0xfd,
	OEM_CLEAR: 0xfe
});

// The marker rows of a VK_TO_WCHARS table: the dead-character row after a key
// with a dead cell, and the Caps Lock row after an SGCAPS key.
const VK_FOLLOW_ROW = 0xff;

// =====================================
// ======= 2/ Shift states, flags ======
// =====================================

// Modifier bits a column is selected by (KBDSHIFT ... KBDLOYA).
const MOD_BITS = Object.freeze({
	shift: 0x01,
	ctrl: 0x02,
	alt: 0x04,
	kana: 0x08,
	roya: 0x10,
	loya: 0x20
});
// The virtual key each modifier bit is read from (VK_TO_BIT).
const MOD_VK = Object.freeze({
	shift: VK.SHIFT,
	ctrl: VK.CONTROL,
	alt: VK.MENU,
	kana: VK.KANA,
	roya: VK.OEM_FJ_ROYA,
	loya: VK.OEM_FJ_LOYA
});
// A modifier combination with no column (SHFT_INVALID).
const SHFT_INVALID = 0x0f;
// Per-key attributes (VK_TO_WCHARS Attributes).
const ATTRIBUTES = Object.freeze({ caplok: 0x01, sgcaps: 0x02, caplokaltgr: 0x04, kanalok: 0x08 });
// Special cell values (WCH_NONE, WCH_DEAD, WCH_LGTR).
const WCH = Object.freeze({ NONE: 0xf000, DEAD: 0xf001, LGTR: 0xf002 });
// A dead-key transition that enters another dead key (DKF_DEAD).
const DKF_DEAD = 0x0001;
// fLocaleFlags low word; the high word is KBD_VERSION.
const LOCALE_FLAGS = Object.freeze({ altgr: 0x0001, shiftlock: 0x0002, lrm_rlm: 0x0004 });
const KBD_VERSION = 1;
// Scan-code to virtual-key flags (high byte of each pusVSCtoVK entry).
const SC_FLAGS = Object.freeze({ EXT: 0x0100, MULTIVK: 0x0200, SPECIAL: 0x0400, NUMPAD: 0x0800 });
// The keyboard type of a standard 101/102-key PC keyboard (dwType = 4).
const KEYBOARD_TYPE = 4;
// The string resource holding the layout's display name (Layout Display Name).
const DISPLAY_NAME_RESOURCE = 1000;

// =========================================
// ======= 3/ Standard scan-code tables ====
// =========================================

const { EXT, MULTIVK, SPECIAL, NUMPAD } = SC_FLAGS;
const NONE = 0xff;

/** The set 1 scan codes 0x00-0x7f of a 101/102-key keyboard and their virtual keys. */
const DEFAULT_SCANCODES = Object.freeze([
	NONE,
	VK.ESCAPE,
	VK['1'],
	VK['2'],
	VK['3'],
	VK['4'],
	VK['5'],
	VK['6'],
	VK['7'],
	VK['8'],
	VK['9'],
	VK['0'],
	VK.OEM_MINUS,
	VK.OEM_PLUS,
	VK.BACK,
	VK.TAB,
	VK.Q,
	VK.W,
	VK.E,
	VK.R,
	VK.T,
	VK.Y,
	VK.U,
	VK.I,
	VK.O,
	VK.P,
	VK.OEM_4,
	VK.OEM_6,
	VK.RETURN,
	VK.LCONTROL,
	VK.A,
	VK.S,
	VK.D,
	VK.F,
	VK.G,
	VK.H,
	VK.J,
	VK.K,
	VK.L,
	VK.OEM_1,
	VK.OEM_7,
	VK.OEM_3,
	VK.LSHIFT,
	VK.OEM_5,
	VK.Z,
	VK.X,
	VK.C,
	VK.V,
	VK.B,
	VK.N,
	VK.M,
	VK.OEM_COMMA,
	VK.OEM_PERIOD,
	VK.OEM_2,
	VK.RSHIFT | EXT,
	VK.MULTIPLY | MULTIVK,
	VK.LMENU,
	VK.SPACE,
	VK.CAPITAL,
	VK.F1,
	VK.F2,
	VK.F3,
	VK.F4,
	VK.F5,
	VK.F6,
	VK.F7,
	VK.F8,
	VK.F9,
	VK.F10,
	VK.NUMLOCK | EXT | MULTIVK,
	VK.SCROLL | MULTIVK,
	VK.HOME | SPECIAL | NUMPAD,
	VK.UP | SPECIAL | NUMPAD,
	VK.PRIOR | SPECIAL | NUMPAD,
	VK.SUBTRACT,
	VK.LEFT | SPECIAL | NUMPAD,
	VK.CLEAR | SPECIAL | NUMPAD,
	VK.RIGHT | SPECIAL | NUMPAD,
	VK.ADD,
	VK.END | SPECIAL | NUMPAD,
	VK.DOWN | SPECIAL | NUMPAD,
	VK.NEXT | SPECIAL | NUMPAD,
	VK.INSERT | SPECIAL | NUMPAD,
	VK.DELETE | SPECIAL | NUMPAD,
	VK.SNAPSHOT,
	NONE,
	VK.OEM_102,
	VK.F11,
	VK.F12,
	VK.CLEAR,
	VK.OEM_WSCTRL,
	VK.OEM_FINISH,
	VK.OEM_JUMP,
	VK.EREOF,
	VK.OEM_BACKTAB,
	VK.OEM_AUTO,
	NONE,
	NONE,
	VK.ZOOM,
	VK.HELP,
	VK.F13,
	VK.F14,
	VK.F15,
	VK.F16,
	VK.F17,
	VK.F18,
	VK.F19,
	VK.F20,
	VK.F21,
	VK.F22,
	VK.F23,
	VK.OEM_PA3,
	NONE,
	VK.OEM_RESET,
	NONE,
	VK.ABNT_C1,
	NONE,
	NONE,
	VK.F24,
	NONE,
	NONE,
	NONE,
	NONE,
	VK.OEM_PA1,
	VK.TAB,
	NONE,
	VK.ABNT_C2,
	VK.OEM_PA2
]);

/** The scan codes behind the E0 prefix and their virtual keys, all extended. */
const DEFAULT_E0 = Object.freeze([
	[0x10, VK.MEDIA_PREV_TRACK],
	[0x19, VK.MEDIA_NEXT_TRACK],
	[0x1d, VK.RCONTROL],
	[0x20, VK.VOLUME_MUTE],
	[0x21, VK.LAUNCH_APP2],
	[0x22, VK.MEDIA_PLAY_PAUSE],
	[0x24, VK.MEDIA_STOP],
	[0x2e, VK.VOLUME_DOWN],
	[0x30, VK.VOLUME_UP],
	[0x32, VK.BROWSER_HOME],
	[0x35, VK.DIVIDE],
	[0x37, VK.SNAPSHOT],
	[0x38, VK.RMENU],
	[0x47, VK.HOME],
	[0x48, VK.UP],
	[0x49, VK.PRIOR],
	[0x4b, VK.LEFT],
	[0x4d, VK.RIGHT],
	[0x4f, VK.END],
	[0x50, VK.DOWN],
	[0x51, VK.NEXT],
	[0x52, VK.INSERT],
	[0x53, VK.DELETE],
	[0x5b, VK.LWIN],
	[0x5c, VK.RWIN],
	[0x5d, VK.APPS],
	[0x5f, VK.SLEEP],
	[0x65, VK.BROWSER_SEARCH],
	[0x66, VK.BROWSER_FAVORITES],
	[0x67, VK.BROWSER_REFRESH],
	[0x68, VK.BROWSER_STOP],
	[0x69, VK.BROWSER_FORWARD],
	[0x6a, VK.BROWSER_BACK],
	[0x6b, VK.LAUNCH_APP1],
	[0x6c, VK.LAUNCH_MAIL],
	[0x6d, VK.LAUNCH_MEDIA_SELECT],
	[0x1c, VK.RETURN],
	[0x46, VK.CANCEL]
]);

/** The scan code behind the E1 prefix: Pause. */
const DEFAULT_E1 = Object.freeze([[0x1d, VK.PAUSE]]);

/**
 * The characters every layout's control and keypad keys type, as Windows'
 * own layouts declare them; a layout's LAYOUT section may replace any of them.
 * Each lists the character per modifier name: base, shift, ctrl.
 */
const SYSTEM_KEYS = Object.freeze([
	{ vk: 'TAB', cells: { base: 0x09, shift: 0x09 } },
	{ vk: 'ADD', cells: { base: 0x2b, shift: 0x2b } },
	{ vk: 'DIVIDE', cells: { base: 0x2f, shift: 0x2f } },
	{ vk: 'MULTIPLY', cells: { base: 0x2a, shift: 0x2a } },
	{ vk: 'SUBTRACT', cells: { base: 0x2d, shift: 0x2d } },
	{ vk: 'BACK', cells: { base: 0x08, shift: 0x08, ctrl: 0x7f } },
	{ vk: 'CANCEL', cells: { base: 0x03, shift: 0x03, ctrl: 0x03 } },
	{ vk: 'ESCAPE', cells: { base: 0x1b, shift: 0x1b, ctrl: 0x1b } },
	{ vk: 'RETURN', cells: { base: 0x0d, shift: 0x0d, ctrl: 0x0a } },
	{ vk: 'SPACE', cells: { base: 0x20, shift: 0x20, ctrl: 0x20 } }
]);

/** The keypad digits: one column, in their own last table (VkKeyScan looks there last). */
const NUMPAD_KEYS = Object.freeze(
	Array.from({ length: 10 }, (_, i) => ({ vk: `NUMPAD${i}`, char: 0x30 + i }))
);

module.exports = {
	VK,
	VK_FOLLOW_ROW,
	MOD_BITS,
	MOD_VK,
	SHFT_INVALID,
	ATTRIBUTES,
	WCH,
	DKF_DEAD,
	LOCALE_FLAGS,
	KBD_VERSION,
	SC_FLAGS,
	KEYBOARD_TYPE,
	DISPLAY_NAME_RESOURCE,
	DEFAULT_SCANCODES,
	DEFAULT_E0,
	DEFAULT_E1,
	SYSTEM_KEYS,
	NUMPAD_KEYS
};
	};
	factories['./model.cjs'] = function (module, exports, require) {
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
	if (model.modifier_vks !== undefined) {
		if (
			!model.modifier_vks ||
			typeof model.modifier_vks !== 'object' ||
			Array.isArray(model.modifier_vks)
		)
			fail('kbd_modifier_vks', 'modifier_vks');
		for (const [name, vk] of Object.entries(model.modifier_vks)) {
			if (!['kana', 'roya', 'loya'].includes(name))
				fail('kbd_modifier_vks', `modifier_vks.${name}`);
			if (!Number.isInteger(vk) || vk < 1 || vk >= C.VK_FOLLOW_ROW)
				fail('kbd_vk', `modifier_vks.${name}`);
		}
	}
	if (model.scancodes_e0 !== undefined) {
		if (!Array.isArray(model.scancodes_e0)) fail('kbd_scancode', 'scancodes_e0');
		const seen = new Set();
		model.scancodes_e0.forEach((entry, i) => {
			if (!Number.isInteger(entry.sc) || entry.sc < 1 || entry.sc > 0x7f || seen.has(entry.sc))
				fail('kbd_scancode', `scancodes_e0[${i}].sc`);
			seen.add(entry.sc);
			if (!Number.isInteger(entry.vk) || entry.vk < 1 || entry.vk >= C.VK_FOLLOW_ROW)
				fail('kbd_vk', `scancodes_e0[${i}].vk`);
		});
	}
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
/**
 * The virtual key each declared modifier bit is held with: the standard one
 * (VK_SHIFT, VK_CONTROL, VK_MENU, VK_KANA, VK_OEM_FJ_ROYA, VK_OEM_FJ_LOYA),
 * or the model's `modifier_vks` override, as KbdEdit puts a momentary Kana on
 * VK_OEM_8 (only Kana, Roya and Loya can move: Shift, Ctrl and Alt are the
 * system's).
 * @returns {{name: string, vk: number, bit: number}[]}
 */
function modifierKeys(model) {
	const overrides = model.modifier_vks || {};
	return modifierNames(model).map((name) => ({
		name,
		vk: Object.hasOwn(overrides, name) ? overrides[name] : C.MOD_VK[name],
		bit: C.MOD_BITS[name]
	}));
}

/** The E0 scan-code table: the standard one with the model's `scancodes_e0` moves. */
function e0Table(model) {
	const table = new Map(C.DEFAULT_E0.map(([sc, vk]) => [sc, vk]));
	for (const move of model.scancodes_e0 || []) table.set(move.sc, move.vk);
	return [...table].sort((a, b) => a[0] - b[0]);
}

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
	modifierKeys,
	e0Table,
	localeFlags
};
	};
	factories['./emit-c.cjs'] = function (module, exports, require) {
// tools/lib/kbd-dll/emit-c.cjs

/**
 * ==============================================================================
 * MODULE: Keyboard Layout DLL C Emitter
 * DESCRIPTION:
 * Writes the C translation unit and the resource script of a Windows keyboard
 * layout DLL from a checked kbd tables model (model.cjs). The structures are
 * this project's own definitions of the kbd.h tables, written from Microsoft's
 * documentation of KBDTABLES and its members (MODIFIERS and VK_TO_BIT,
 * VK_TO_WCHAR_TABLE and VK_TO_WCHARSn, DEADKEY with DKF_DEAD, LIGATUREn,
 * VSC_LPWSTR, VSC_VK, fLocaleFlags with KBD_VERSION) and its export,
 * KbdLayerDescriptor; no WDK header is used.
 *
 * FEATURES & RATIONALE:
 * 1. One source, four images: x86 (32-bit Windows), wow64 (the 32-bit copy a
 *    64-bit Windows keeps in SysWOW64, whose table pointers are 64 bits wide as
 *    kbd.h's KBD_LONG_POINTER makes them under BUILD_WOW6432), x64 and arm64.
 *    A wow64 pointer is a 32-bit pointer followed by a zero word, 8-aligned: the
 *    64-bit layout, filled by a 32-bit image's relocations.
 * 2. Every table is const, so it lands in read-only data; static assertions pin
 *    each structure's size to the layout the reader checks independently.
 * 3. Deterministic: the same model gives the same text.
 * ==============================================================================
 */

'use strict';

const C = require('./constants.cjs');
const Model = require('./model.cjs');

const ARCHES = Object.freeze(['x86', 'wow64', 'x64', 'arm64']);
const hex = (n, width = 4) => `0x${n.toString(16).padStart(width, '0')}`;

/** A C array initializer of UTF-16 units ending with a zero unit. */
function wstring(text) {
	const units = [];
	for (let i = 0; i < text.length; i++) units.push(hex(text.charCodeAt(i)));
	units.push('0x0000');
	return `{ ${units.join(', ')} }`;
}

/** The unit a cell stores in its VK_TO_WCHARS slot. */
function slot(cell) {
	if (cell === null) return C.WCH.NONE;
	if (cell.char !== undefined) return cell.char;
	if (cell.dead !== undefined) return C.WCH.DEAD;
	return C.WCH.LGTR;
}

/** The VK_TO_WCHARS rows of the main table: layout keys, then the system keys they leave. */
function mainRows(model) {
	const n = model.columns.length;
	const rows = [];
	for (const key of model.keys) {
		rows.push({ vk: key.vk, attr: key.attributes, wch: key.cells.map(slot) });
		if (key.cells.some((cell) => cell && cell.dead !== undefined))
			rows.push({
				vk: C.VK_FOLLOW_ROW,
				attr: 0,
				wch: key.cells.map((cell) => (cell && cell.dead !== undefined ? cell.dead : C.WCH.NONE))
			});
		if (key.caps_cells) rows.push({ vk: C.VK_FOLLOW_ROW, attr: 0, wch: key.caps_cells.map(slot) });
	}
	const defined = new Set(model.keys.map((key) => key.vk));
	const columnOf = { base: 0, shift: C.MOD_BITS.shift, ctrl: C.MOD_BITS.ctrl };
	for (const sys of C.SYSTEM_KEYS) {
		const vk = C.VK[sys.vk];
		if (defined.has(vk)) continue;
		const wch = Array(n).fill(C.WCH.NONE);
		for (const [name, unit] of Object.entries(sys.cells)) {
			const index = model.columns.indexOf(columnOf[name]);
			if (index >= 0) wch[index] = unit;
		}
		rows.push({ vk, attr: 0, wch });
	}
	return rows;
}

/** The ModNumber array: each modifier-bit combination's column, or SHFT_INVALID. */
function modNumbers(model) {
	const names = Model.modifierNames(model);
	const max = names.reduce((a, name) => a | C.MOD_BITS[name], 0);
	return Array.from({ length: max + 1 }, (_, bits) => {
		const index = model.columns.indexOf(bits);
		return index >= 0 ? index : C.SHFT_INVALID;
	});
}

/** The scan-code to virtual-key table with the layout's moves applied. */
function scanTable(model) {
	const table = C.DEFAULT_SCANCODES.slice();
	// A moved character key carries no scan-code flag.
	for (const entry of model.scancodes || []) table[entry.sc] = entry.vk;
	return table;
}

/**
 * The C source of one layout DLL; KBD_WOW64 selects the SysWOW64 layout.
 * @param {object} input - A kbd tables model.
 * @returns {string}
 */
function emitC(input) {
	const model = Model.check(input);
	const n = model.columns.length;
	const rows = mainRows(model);
	const mods = modNumbers(model);
	const names = Model.modifierNames(model);
	const ligatures = [];
	model.keys.forEach((key) =>
		key.cells.forEach((cell, column) => {
			if (cell && cell.ligature) ligatures.push({ vk: key.vk, column, units: cell.ligature });
		})
	);
	const lgMax = ligatures.reduce((a, l) => Math.max(a, l.units.length), 0);
	const deadRows = [];
	for (const dead of model.dead_keys)
		for (const rule of dead.rules)
			deadRows.push({
				both: ((dead.dead << 16) | rule.base) >>> 0,
				result: rule.result,
				flags: rule.dead ? C.DKF_DEAD : 0
			});
	const named = model.dead_keys.filter((dead) => dead.name);
	const out = [];
	const line = (text = '') => out.push(text);
	line(
		`/* ${model.dll_name}.c: generated by tools/kbd-dll.cjs from the kbd tables model; do not edit. */`
	);
	line('typedef unsigned char BYTE;');
	line('typedef unsigned short WORD;');
	line('typedef unsigned short WCHAR;');
	line('typedef unsigned int DWORD;');
	line('#if defined(KBD_WOW64)');
	line('/* The SysWOW64 image: kbd.h pointers are 64 bits wide (BUILD_WOW6432). */');
	line('#define KPTR(T) struct { T *p; DWORD hi; } __attribute__((aligned(8)))');
	line('#define KP(x) { (x), 0 }');
	line('#define KBD_PTR_SIZE 8');
	line('#else');
	line('#define KPTR(T) T *');
	line('#define KP(x) (x)');
	line('#define KBD_PTR_SIZE (sizeof(void *))');
	line('#endif');
	line('');
	line('typedef struct { BYTE Vk; BYTE ModBits; } VK_TO_BIT;');
	line(
		`typedef struct { KPTR(const VK_TO_BIT) pVkToBit; WORD wMaxModBits; BYTE ModNumber[${mods.length}]; } MODIFIERS;`
	);
	line(`typedef struct { BYTE VirtualKey; BYTE Attributes; WCHAR wch[${n}]; } VK_TO_WCHARS_N;`);
	line('typedef struct { BYTE VirtualKey; BYTE Attributes; WCHAR wch[1]; } VK_TO_WCHARS_1;');
	line(
		'typedef struct { KPTR(const void) pVkToWchars; BYTE nModifications; BYTE cbSize; } VK_TO_WCHAR_TABLE;'
	);
	line('typedef struct { DWORD dwBoth; WCHAR wchComposed; WORD uFlags; } DEADKEY;');
	line('typedef struct { BYTE vsc; KPTR(const WCHAR) pwsz; } VSC_LPWSTR;');
	line('typedef struct { BYTE Vsc; WORD Vk; } VSC_VK;');
	line('typedef struct { KPTR(const void) p; } DEADNAME;');
	if (lgMax)
		line(
			`typedef struct { BYTE VirtualKey; WORD ModificationNumber; WCHAR wch[${lgMax}]; } LIGATURE_N;`
		);
	line('typedef struct {');
	line('\tKPTR(const MODIFIERS) pCharModifiers;');
	line('\tKPTR(const VK_TO_WCHAR_TABLE) pVkToWcharTable;');
	line('\tKPTR(const DEADKEY) pDeadKey;');
	line('\tKPTR(const VSC_LPWSTR) pKeyNames;');
	line('\tKPTR(const VSC_LPWSTR) pKeyNamesExt;');
	line('\tKPTR(const DEADNAME) pKeyNamesDead;');
	line('\tKPTR(const WORD) pusVSCtoVK;');
	line('\tBYTE bMaxVSCtoVK;');
	line('\tKPTR(const VSC_VK) pVSCtoVK_E0;');
	line('\tKPTR(const VSC_VK) pVSCtoVK_E1;');
	line('\tDWORD fLocaleFlags;');
	line('\tBYTE nLgMax;');
	line('\tBYTE cbLgEntry;');
	line('\tKPTR(const void) pLigature;');
	line('\tDWORD dwType;');
	line('\tDWORD dwSubType;');
	line('} KBDTABLES;');
	line('');
	line('/* The layouts the independent reader (kbd-dll/reader.cjs) expects. */');
	line('_Static_assert(sizeof(KBDTABLES) == (KBD_PTR_SIZE == 8 ? 104 : 60), "KBDTABLES layout");');
	line(
		'_Static_assert(sizeof(VK_TO_WCHAR_TABLE) == (KBD_PTR_SIZE == 8 ? 16 : 8), "VK_TO_WCHAR_TABLE layout");'
	);
	line('_Static_assert(sizeof(VSC_LPWSTR) == 2 * KBD_PTR_SIZE, "VSC_LPWSTR layout");');
	line('_Static_assert(sizeof(DEADKEY) == 8, "DEADKEY layout");');
	line('_Static_assert(sizeof(VSC_VK) == 4, "VSC_VK layout");');
	line(`_Static_assert(sizeof(VK_TO_WCHARS_N) == ${2 + 2 * n}, "VK_TO_WCHARS layout");`);
	if (lgMax) line(`_Static_assert(sizeof(LIGATURE_N) == ${4 + 2 * lgMax}, "LIGATURE layout");`);
	line('');
	line('static const VK_TO_BIT aVkToBits[] = {');
	for (const key of Model.modifierKeys(model)) line(`\t{ ${hex(key.vk, 2)}, ${hex(key.bit, 2)} },`);
	line('\t{ 0, 0 }');
	line('};');
	line(
		`static const MODIFIERS CharModifiers = { KP(aVkToBits), ${mods.length - 1}, { ${mods.map((m) => hex(m, 2)).join(', ')} } };`
	);
	line('');
	line(`static const VK_TO_WCHARS_N aVkToWchMain[] = {`);
	for (const row of rows)
		line(
			`\t{ ${hex(row.vk, 2)}, ${hex(row.attr, 2)}, { ${row.wch.map((u) => hex(u)).join(', ')} } },`
		);
	line(`\t{ 0, 0, { ${Array(n).fill('0').join(', ')} } }`);
	line('};');
	line('static const VK_TO_WCHARS_1 aVkToWchNumpad[] = {');
	for (const key of C.NUMPAD_KEYS) line(`\t{ ${hex(C.VK[key.vk], 2)}, 0, { ${hex(key.char)} } },`);
	line('\t{ 0, 0, { 0 } }');
	line('};');
	line('/* The keypad digits come last: VkKeyScan prefers the main keys. */');
	line('static const VK_TO_WCHAR_TABLE aVkToWcharTable[] = {');
	line(`\t{ KP(aVkToWchMain), ${n}, sizeof(VK_TO_WCHARS_N) },`);
	line('\t{ KP(aVkToWchNumpad), 1, sizeof(VK_TO_WCHARS_1) },');
	line('\t{ KP(0), 0, 0 }');
	line('};');
	line('');
	if (deadRows.length) {
		line('static const DEADKEY aDeadKey[] = {');
		for (const row of deadRows)
			line(`\t{ ${hex(row.both, 8)}, ${hex(row.result)}, ${hex(row.flags)} },`);
		line('\t{ 0, 0, 0 }');
		line('};');
	}
	const nameTable = (id, list) => {
		list.forEach((entry, i) => line(`static const WCHAR ${id}_${i}[] = ${wstring(entry.name)};`));
		line(`static const VSC_LPWSTR ${id}[] = {`);
		list.forEach((entry, i) => line(`\t{ ${hex(entry.sc, 2)}, KP(${id}_${i}) },`));
		line('\t{ 0, KP(0) }');
		line('};');
	};
	nameTable('aKeyNames', model.key_names || []);
	nameTable('aKeyNamesExt', model.key_names_ext || []);
	if (named.length) {
		named.forEach((dead, i) =>
			line(
				`static const WCHAR aDeadName_${i}[] = ${wstring(String.fromCharCode(dead.dead) + dead.name)};`
			)
		);
		line('static const DEADNAME aKeyNamesDead[] = {');
		named.forEach((_, i) => line(`\t{ KP(aDeadName_${i}) },`));
		line('\t{ KP(0) }');
		line('};');
	}
	line('');
	const scan = scanTable(model);
	line(`static const WORD ausVSCtoVK[${scan.length}] = {`);
	for (let i = 0; i < scan.length; i += 8)
		line(
			`\t${scan
				.slice(i, i + 8)
				.map((v) => hex(v))
				.join(', ')},`
		);
	line('};');
	line('static const VSC_VK aE0VscToVk[] = {');
	for (const [sc, vk] of Model.e0Table(model))
		line(`\t{ ${hex(sc, 2)}, ${hex(vk | C.SC_FLAGS.EXT)} },`);
	line('\t{ 0, 0 }');
	line('};');
	line('static const VSC_VK aE1VscToVk[] = {');
	for (const [sc, vk] of C.DEFAULT_E1) line(`\t{ ${hex(sc, 2)}, ${hex(vk)} },`);
	line('\t{ 0, 0 }');
	line('};');
	if (lgMax) {
		line('static const LIGATURE_N aLigature[] = {');
		for (const lig of ligatures) {
			const units = lig.units.concat(Array(lgMax - lig.units.length).fill(C.WCH.NONE));
			line(`\t{ ${hex(lig.vk, 2)}, ${lig.column}, { ${units.map((u) => hex(u)).join(', ')} } },`);
		}
		line(`\t{ 0, 0, { ${Array(lgMax).fill('0').join(', ')} } }`);
		line('};');
	}
	line('');
	line('static const KBDTABLES KbdTables = {');
	line('\tKP(&CharModifiers),');
	line('\tKP(aVkToWcharTable),');
	line(`\tKP(${deadRows.length ? 'aDeadKey' : '0'}),`);
	line('\tKP(aKeyNames),');
	line('\tKP(aKeyNamesExt),');
	line(`\tKP(${named.length ? 'aKeyNamesDead' : '0'}),`);
	line('\tKP(ausVSCtoVK),');
	line(`\t${scan.length},`);
	line('\tKP(aE0VscToVk),');
	line('\tKP(aE1VscToVk),');
	line(`\t${hex(Model.localeFlags(model), 8)},`);
	line(`\t${lgMax},`);
	line(`\t${lgMax ? 'sizeof(LIGATURE_N)' : '0'},`);
	line(`\tKP(${lgMax ? 'aLigature' : '0'}),`);
	line(`\t${C.KEYBOARD_TYPE},`);
	line('\t0');
	line('};');
	line('');
	line('/* The one export (ordinal 1): the system calls it to get the tables. */');
	line('const KBDTABLES *__stdcall KbdLayerDescriptor(void) { return &KbdTables; }');
	return `${out.join('\n')}\n`;
}

/** A resource-script string: printable ASCII kept, everything else escaped. */
function rcString(text) {
	let out = '';
	for (const ch of text) {
		const code = ch.codePointAt(0);
		if (code >= 0x20 && code < 0x7f && ch !== '"' && ch !== '\\') out += ch;
		else
			for (const unit of String.fromCodePoint(code).split(''))
				out += `\\x${unit.charCodeAt(0).toString(16).padStart(4, '0')}`;
	}
	return `L"${out}"`;
}

/** The version as four numbers for VERSIONINFO. */
function versionParts(text) {
	const parts = String(text || '1.0')
		.split('.')
		.map((p) => Number(p));
	if (parts.some((p) => !Number.isInteger(p) || p < 0 || p > 65535) || parts.length > 4)
		throw new Model.ModelError('kbd_version_string', 'version_string');
	while (parts.length < 4) parts.push(0);
	return parts;
}

/**
 * The resource script: the display name string (Layout Display Name points at
 * it) and a version resource typed as a keyboard driver (VFT_DRV, VFT2_DRV_KEYBOARD).
 * @param {object} input - A kbd tables model.
 * @returns {string}
 */
function emitRc(input) {
	const model = Model.check(input);
	const v = versionParts(model.version_string).join(',');
	const field = (name, value) => `\t\t\tVALUE "${name}", ${rcString(value)}`;
	return [
		`// ${model.dll_name}.rc: generated by tools/kbd-dll.cjs; do not edit.`,
		'STRINGTABLE',
		'BEGIN',
		`\t${C.DISPLAY_NAME_RESOURCE}, ${rcString(model.layout_text)}`,
		'END',
		'',
		'1 VERSIONINFO',
		`FILEVERSION ${v}`,
		`PRODUCTVERSION ${v}`,
		'FILEFLAGSMASK 0x3f',
		'FILEFLAGS 0x0',
		'FILEOS 0x40004',
		'FILETYPE 0x3',
		'FILESUBTYPE 0x2',
		'BEGIN',
		'\tBLOCK "StringFileInfo"',
		'\tBEGIN',
		'\t\tBLOCK "040904B0"',
		'\t\tBEGIN',
		field('CompanyName', model.company || model.layout_text),
		field('FileDescription', `${model.layout_text} keyboard layout`),
		field('FileVersion', model.version_string || '1.0'),
		field('InternalName', model.dll_name),
		field('LegalCopyright', model.copyright || ''),
		field('OriginalFilename', `${model.dll_name}.dll`),
		field('ProductName', model.layout_text),
		field('ProductVersion', model.version_string || '1.0'),
		'\t\tEND',
		'\tEND',
		'\tBLOCK "VarFileInfo"',
		'\tBEGIN',
		'\t\tVALUE "Translation", 0x409, 1200',
		'\tEND',
		'END',
		''
	].join('\n');
}

/** The module definition: KbdLayerDescriptor at ordinal 1, as Windows' own layouts export it. */
function emitDef(input) {
	const model = Model.check(input);
	return `LIBRARY ${model.dll_name}\nEXPORTS\n\tKbdLayerDescriptor @1\n`;
}

module.exports = { ARCHES, emitC, emitRc, emitDef, mainRows, modNumbers, scanTable };
	};
	factories['./source.cjs'] = function (module, exports, require) {
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

const C = require('./constants.cjs');
const Model = require('./model.cjs');

// The modifier ids of a column's bits; AltGr (Ctrl+Alt) is the right Alt key.
const COLUMN_IDS = [
	[C.MOD_BITS.shift, 'shift'],
	[C.MOD_BITS.kana, 'kana']
];
const ALTGR = C.MOD_BITS.ctrl | C.MOD_BITS.alt;
const DEFAULT_KANA_KEY = 'AltRight';
// The private-use characters a dead key without a one-character identity gets.
const PRIVATE_DEAD_FIRST = 0xe000;
const PRIVATE_DEAD_LAST = 0xf8ff;

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

/**
 * The physical-key registry (_shared/data/keycodes/physical_keys.json) read from
 * the repository; a page passes the table it already holds instead.
 */
function repositoryPhysicalKeys() {
	const fs = require('node:fs');
	const { shared } = require('../paths.cjs');
	return JSON.parse(fs.readFileSync(shared('data', 'keycodes', 'physical_keys.json'), 'utf8'));
}

/** Physical key name <-> extended scan code (0x1nn for an E0 key), from the registry. */
function scanTable(physicalKeys) {
	const keys = (physicalKeys || repositoryPhysicalKeys()).keys;
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
 * @param {{id: string, name?: string, physicalKeys?: object}} options - physicalKeys: the
 *   physical-key registry, read from the repository when absent.
 * @returns {object} The source document (validate it with LayoutSource).
 */
function toSource(model, options) {
	Model.check(model);
	const altgr = model.flags.includes('altgr');
	const { bySc } = scanTable(options.physicalKeys);
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
	// Optional modifiers make no column of their own: the column is the same with
	// them held (Caps Lock, or Command, which Windows has no character level for).
	let mask = 0;
	for (const id of selector.required) {
		if (id === 'shift') mask |= C.MOD_BITS.shift;
		else if (id === 'control') mask |= C.MOD_BITS.ctrl;
		else if (id === 'kana') mask |= C.MOD_BITS.kana;
		// Option is AltGr on Windows, as the XKB and KLC converters read it.
		else if ((id === 'alt_right' || id === 'alt') && altgr) mask |= ALTGR;
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
 * @param {{physicalKeys?: object}} [options] - physicalKeys: the physical-key registry, read
 *   from the repository when absent (a page passes its own).
 * @returns {{model: object, omitted: {path: string, reason: string}[]}}
 */
function fromSource(source, options = {}) {
	const windows = source.exports && source.exports.windows;
	if (!windows) fail('source_windows_metadata', 'exports.windows');
	const altgr =
		((source.windows && source.windows.flags) || []).includes('altgr') ||
		source.layers.some(
			(layer) => layer.required.includes('alt_right') || layer.required.includes('alt')
		);
	const { byCode } = scanTable(options.physicalKeys);
	const omitted = [];
	const columns = [];
	const columnLayers = [];
	// A Caps Lock layer of the base or Shift column becomes the key's CAPLOK or
	// SGCAPS row, as kbd.h holds Caps Lock: an attribute, not a column.
	const capsLayers = new Map();
	for (const layer of source.layers) {
		if (!layer.required.includes('caps_lock')) continue;
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
		(layer.alternatives || []).forEach((alternative, i) => {
			if (selectorMask(alternative, altgr) !== mask)
				omitted.push({
					path: `layers.${layer.id}.alternatives[${i}]`,
					reason: 'alternative_selector_not_on_windows'
				});
		});
		if (mask === null) {
			omitted.push({ path: `layers.${layer.id}`, reason: 'no_windows_column' });
			continue;
		}
		if (columns.includes(mask)) fail('source_column_duplicate', `layers.${layer.id}`);
		columns.push(mask);
		columnLayers.push(layer);
	}
	if (columns[0] !== 0) fail('source_base_column', 'layers');
	// A Windows dead key is one character. One whose terminator is not a single
	// unit, or is another dead key's, gets a private-use character, as KbdEdit's
	// chained dead characters do (U+E000 up); a chain still works, but a key with
	// no rule after it types that private character, which `omitted` says.
	const deadUnit = new Map();
	const takenUnits = new Set();
	for (const dead of source.dead_keys || []) {
		const units = unitsOf(dead.terminator);
		if (units.length === 1 && !takenUnits.has(units[0])) {
			deadUnit.set(dead.id, units[0]);
			takenUnits.add(units[0]);
		}
	}
	let privateUnit = PRIVATE_DEAD_FIRST;
	for (const dead of source.dead_keys || []) {
		if (deadUnit.has(dead.id)) continue;
		while (takenUnits.has(privateUnit)) privateUnit++;
		if (privateUnit > PRIVATE_DEAD_LAST) fail('source_dead_private_units', `dead_keys.${dead.id}`);
		deadUnit.set(dead.id, privateUnit);
		takenUnits.add(privateUnit);
		omitted.push({ path: `dead_keys.${dead.id}.terminator`, reason: 'dead_key_private_character' });
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
			const label = own(rule, 'input') ? rule.input : `@${rule.input_dead_key}`;
			const at = `dead_keys.${dead.id}.rules[${label}]`;
			const base = own(rule, 'input') ? unitsOf(rule.input) : [deadUnit.get(rule.input_dead_key)];
			// DEADKEY entries pair one character with one character (kbd.h).
			if (base.length !== 1) {
				omitted.push({ path: at, reason: 'dead_input_not_one_unit' });
				continue;
			}
			const entry = own(rule, 'next')
				? { base: base[0], result: deadUnit.get(rule.next), dead: true }
				: { base: base[0], result: unitsOf(rule.text) };
			if (!entry.dead) {
				if (entry.result.length !== 1) {
					omitted.push({ path: at, reason: 'dead_result_not_one_unit' });
					continue;
				}
				entry.result = entry.result[0];
			}
			const key = entry.base;
			if (seen.has(key)) {
				if (JSON.stringify(seen.get(key)) !== JSON.stringify(entry))
					omitted.push({ path: at, reason: 'dead_input_conflict' });
				continue;
			}
			seen.set(key, entry);
			rules.push(entry);
		}
		// Windows needs one entry: Space then types the terminator's first character.
		if (!rules.length) {
			rules.push({ base: 0x20, result: unitsOf(dead.terminator)[0] });
			omitted.push({ path: `dead_keys.${dead.id}`, reason: 'dead_key_without_windows_rule' });
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
	};
	factories['./pe-writer.cjs'] = function (module, exports, require) {
// tools/lib/kbd-dll/pe-writer.cjs

/**
 * ==============================================================================
 * MODULE: Keyboard Layout DLL PE Writer
 * DESCRIPTION:
 * Writes the four Windows keyboard layout DLL images of a kbd tables model
 * directly, with no compiler, linker or resource compiler, so a page or a PC
 * without the LLVM toolchain can build them. The tables are the C emitter's
 * (emit-c.cjs mainRows, modNumbers, scanTable), laid out as the C structures
 * that emitter declares: natural alignment, pointers of 4 bytes (x86) or 8
 * (x64, arm64, and wow64, whose kbd.h pointers are 64 bits wide in a 32-bit
 * image). The resources are the ones emitRc describes: string 1000 (the
 * Layout Display Name) and the keyboard-driver version resource.
 *
 * FEATURES & RATIONALE:
 * 1. The images the loader expects from Microsoft's layout DLLs: a DLL with no
 *    entry point, subsystem native, read-only tables, KbdLayerDescriptor at
 *    ordinal 1 returning &KbdTables, base relocations for every table pointer
 *    (HIGHLOW in a 32-bit image, DIR64 in a 64-bit one) and the PE checksum.
 * 2. The same code the clang build produces for KbdLayerDescriptor: mov eax /
 *    ret (x86), lea rax,[rip] / ret (x64), adrp / add / ret (arm64), which the
 *    independent reader (reader.cjs) decodes.
 * 3. Deterministic: the same model gives the same bytes (no timestamp).
 * ==============================================================================
 */

'use strict';

const C = require('./constants.cjs');
const Model = require('./model.cjs');
const Emit = require('./emit-c.cjs');

const SECTION_ALIGN = 0x1000;
const FILE_ALIGN = 0x200;
const HEADERS_SIZE = 0x400;
const PE_OFFSET = 0x40;
const RESOURCE_LANGUAGE = 0x409;
const RT_STRING = 6;
const RT_VERSION = 16;
const REL_HIGHLOW = 3;
const REL_DIR64 = 10;
const SCN = Object.freeze({
	code: 0x60000020,
	rdata: 0x40000040,
	reloc: 0x42000040
});

// Each image: machine, PE32+ or not, pointer width, base and characteristics,
// as lld-link writes them for /dll /noentry /subsystem:native.
const IMAGES = Object.freeze({
	x86: { machine: 0x014c, plus: false, width: 4, base: 0x10000000, chars: 0x2102, dll: 0x0540 },
	wow64: { machine: 0x014c, plus: false, width: 8, base: 0x10000000, chars: 0x2102, dll: 0x0540 },
	x64: { machine: 0x8664, plus: true, width: 8, base: 0x180000000, chars: 0x2022, dll: 0x0160 },
	arm64: { machine: 0xaa64, plus: true, width: 8, base: 0x180000000, chars: 0x2022, dll: 0x0160 }
});

const align = (n, a) => Math.ceil(n / a) * a;

// Plain Uint8Array bytes, so the page (no Node Buffer) runs the same writer.
const Bytes = Object.freeze({
	alloc: (n) => new Uint8Array(n),
	of: (values) => Uint8Array.from(values),
	utf16: (text) => {
		const out = new Uint8Array(2 * text.length);
		for (let i = 0; i < text.length; i++) {
			out[2 * i] = text.charCodeAt(i) & 0xff;
			out[2 * i + 1] = text.charCodeAt(i) >>> 8;
		}
		return out;
	},
	concat: (parts) => {
		const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
		let at = 0;
		for (const p of parts) {
			out.set(p, at);
			at += p.length;
		}
		return out;
	},
	view: (bytes) => new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength),
	u16: (bytes, v, at) => Bytes.view(bytes).setUint16(at, v, true),
	u32: (bytes, v, at) => Bytes.view(bytes).setUint32(at, v >>> 0, true),
	i32: (bytes, v, at) => Bytes.view(bytes).setInt32(at, v, true),
	u64: (bytes, v, at) => Bytes.view(bytes).setBigUint64(at, BigInt(v), true),
	read16: (bytes, at) => Bytes.view(bytes).getUint16(at, true),
	latin1: (bytes, text, at) => {
		for (let i = 0; i < text.length; i++) bytes[at + i] = text.charCodeAt(i);
	}
});

/** A growable little-endian byte area with pointer fixups to named objects. */
class Area {
	constructor() {
		this.bytes = [];
		this.fixups = [];
	}
	pad(to) {
		while (this.bytes.length % to) this.bytes.push(0);
	}
	u8(v) {
		this.bytes.push(v & 0xff);
	}
	u16(v) {
		this.u8(v);
		this.u8(v >>> 8);
	}
	u32(v) {
		this.u16(v & 0xffff);
		this.u16(v >>> 16);
	}
}

/**
 * The read-only data objects of one image, in the C emitter's order: each a
 * {name, align, write(area, ptr)} where ptr(target) writes a pointer slot.
 */
function tableObjects(model) {
	const n = model.columns.length;
	const rows = Emit.mainRows(model);
	const mods = Emit.modNumbers(model);
	const ligatures = [];
	model.keys.forEach((key) =>
		key.cells.forEach((cell, column) => {
			if (cell && cell.ligature) ligatures.push({ vk: key.vk, column, units: cell.ligature });
		})
	);
	const lgMax = ligatures.reduce((a, l) => Math.max(a, l.units.length), 0);
	const deadRows = [];
	for (const dead of model.dead_keys)
		for (const rule of dead.rules)
			deadRows.push({
				both: ((dead.dead << 16) | rule.base) >>> 0,
				result: rule.result,
				flags: rule.dead ? C.DKF_DEAD : 0
			});
	const named = model.dead_keys.filter((dead) => dead.name);
	const scan = Emit.scanTable(model);
	const objects = [];
	const add = (name, alignment, write) => objects.push({ name, align: alignment, write });
	const wchars = (area, text) => {
		for (let i = 0; i < text.length; i++) area.u16(text.charCodeAt(i));
		area.u16(0);
	};

	add('aVkToBits', 1, (a) => {
		for (const key of Model.modifierKeys(model)) {
			a.u8(key.vk);
			a.u8(key.bit);
		}
		a.u8(0);
		a.u8(0);
	});
	add('CharModifiers', 'ptr', (a, ptr, P) => {
		ptr('aVkToBits');
		a.u16(mods.length - 1);
		for (const m of mods) a.u8(m);
		a.pad(P.align);
	});
	add('aVkToWchMain', 2, (a) => {
		for (const row of rows) {
			a.u8(row.vk);
			a.u8(row.attr);
			for (const u of row.wch) a.u16(u);
		}
		for (let i = 0; i < 2 + 2 * n; i++) a.u8(0);
	});
	add('aVkToWchNumpad', 2, (a) => {
		for (const key of C.NUMPAD_KEYS) {
			a.u8(C.VK[key.vk]);
			a.u8(0);
			a.u16(key.char);
		}
		a.u32(0);
	});
	add('aVkToWcharTable', 'ptr', (a, ptr, P) => {
		const entry = (target, count, size) => {
			ptr(target);
			a.u8(count);
			a.u8(size);
			a.pad(P.align);
		};
		entry('aVkToWchMain', n, 2 + 2 * n);
		entry('aVkToWchNumpad', 1, 4);
		entry(null, 0, 0);
	});
	if (deadRows.length)
		add('aDeadKey', 4, (a) => {
			for (const row of deadRows) {
				a.u32(row.both);
				a.u16(row.result);
				a.u16(row.flags);
			}
			a.u32(0);
			a.u32(0);
		});
	const nameTable = (id, list) => {
		list.forEach((entry, i) => add(`${id}_${i}`, 2, (a) => wchars(a, entry.name)));
		add(id, 'ptr', (a, ptr, P) => {
			for (const [i, entry] of list.entries()) {
				a.u8(entry.sc);
				a.pad(P.align);
				ptr(`${id}_${i}`);
			}
			a.u8(0);
			a.pad(P.align);
			ptr(null);
		});
	};
	nameTable('aKeyNames', model.key_names || []);
	nameTable('aKeyNamesExt', model.key_names_ext || []);
	if (named.length) {
		named.forEach((dead, i) =>
			add(`aDeadName_${i}`, 2, (a) => wchars(a, String.fromCharCode(dead.dead) + dead.name))
		);
		add('aKeyNamesDead', 'ptr', (a, ptr) => {
			named.forEach((_, i) => ptr(`aDeadName_${i}`));
			ptr(null);
		});
	}
	add('ausVSCtoVK', 2, (a) => {
		for (const v of scan) a.u16(v);
	});
	const vscVk = (pairs) => (a) => {
		for (const [sc, vk] of pairs) {
			a.u8(sc);
			a.u8(0);
			a.u16(vk);
		}
		a.u32(0);
	};
	add('aE0VscToVk', 2, vscVk(Model.e0Table(model).map(([sc, vk]) => [sc, vk | C.SC_FLAGS.EXT])));
	add('aE1VscToVk', 2, vscVk(C.DEFAULT_E1));
	if (lgMax)
		add('aLigature', 2, (a) => {
			for (const lig of ligatures) {
				a.u8(lig.vk);
				a.u8(0);
				a.u16(lig.column);
				for (let i = 0; i < lgMax; i++) a.u16(i < lig.units.length ? lig.units[i] : C.WCH.NONE);
			}
			for (let i = 0; i < 4 + 2 * lgMax; i++) a.u8(0);
		});
	add('KbdTables', 'ptr', (a, ptr, P) => {
		ptr('CharModifiers');
		ptr('aVkToWcharTable');
		ptr(deadRows.length ? 'aDeadKey' : null);
		ptr('aKeyNames');
		ptr('aKeyNamesExt');
		ptr(named.length ? 'aKeyNamesDead' : null);
		ptr('ausVSCtoVK');
		a.u8(scan.length);
		a.pad(P.align);
		ptr('aE0VscToVk');
		ptr('aE1VscToVk');
		a.u32(Model.localeFlags(model));
		a.u8(lgMax);
		a.u8(lgMax ? 4 + 2 * lgMax : 0);
		a.pad(P.align);
		ptr(lgMax ? 'aLigature' : null);
		a.u32(C.KEYBOARD_TYPE);
		a.u32(0);
		a.pad(P.align);
	});
	return objects;
}

/** The .rdata area of one image: every table, then the export directory. */
function rdata(model, image, rva) {
	const P = { width: image.width, align: image.width };
	const area = new Area();
	const at = new Map();
	for (const object of tableObjects(model)) {
		area.pad(object.align === 'ptr' ? P.align : object.align);
		at.set(object.name, area.bytes.length);
		const ptr = (target) => {
			area.pad(P.align);
			if (target !== null) area.fixups.push({ offset: area.bytes.length, target });
			for (let i = 0; i < P.width; i++) area.u8(0);
		};
		object.write(area, ptr, P);
	}
	// The export directory: KbdLayerDescriptor at ordinal 1, as the .def names it.
	area.pad(4);
	const exportAt = area.bytes.length;
	const dllName = `${model.dll_name}.dll`;
	const fn = 'KbdLayerDescriptor';
	const eat = exportAt + 40;
	const enpt = eat + 4;
	const eot = enpt + 4;
	const nameAt = eot + 2;
	const fnAt = nameAt + dllName.length + 1;
	const exportsDir = {
		offset: exportAt,
		size: fnAt + fn.length + 1 - exportAt,
		patch: (bytes, codeRva) => {
			const w = (off, v) => {
				Bytes.u32(bytes, v, off);
			};
			w(exportAt + 12, rva + nameAt);
			w(exportAt + 16, 1);
			w(exportAt + 20, 1);
			w(exportAt + 24, 1);
			w(exportAt + 28, rva + eat);
			w(exportAt + 32, rva + enpt);
			w(exportAt + 36, rva + eot);
			w(eat, codeRva);
			w(enpt, rva + fnAt);
		}
	};
	for (let i = exportAt; i < nameAt; i++) area.u8(0);
	for (const ch of dllName) area.u8(ch.charCodeAt(0));
	area.u8(0);
	for (const ch of fn) area.u8(ch.charCodeAt(0));
	area.u8(0);
	const bytes = Bytes.of(area.bytes);
	// Pointer slots hold virtual addresses; the relocations let the loader move them.
	const relocations = [];
	for (const fix of area.fixups) {
		const va = image.base + rva + at.get(fix.target);
		if (image.plus) Bytes.u64(bytes, va, fix.offset);
		else Bytes.u32(bytes, va, fix.offset);
		relocations.push({ rva: rva + fix.offset, type: image.plus ? REL_DIR64 : REL_HIGHLOW });
	}
	return { bytes, relocations, tablesRva: rva + at.get('KbdTables'), exportsDir };
}

/** KbdLayerDescriptor's code: return &KbdTables. */
function descriptorCode(image, codeRva, tablesRva) {
	if (image.machine === 0x014c) {
		const code = Bytes.of([0xb8, 0, 0, 0, 0, 0xc3]);
		Bytes.u32(code, image.base + tablesRva, 1);
		return { code, relocations: [{ rva: codeRva + 1, type: REL_HIGHLOW }] };
	}
	if (image.machine === 0x8664) {
		const code = Bytes.of([0x48, 0x8d, 0x05, 0, 0, 0, 0, 0xc3]);
		Bytes.i32(code, tablesRva - (codeRva + 7), 3);
		return { code, relocations: [] };
	}
	const pages = (tablesRva >> 12) - (codeRva >> 12);
	const immlo = pages & 3;
	const immhi = (pages >> 2) & 0x7ffff;
	const code = Bytes.alloc(12);
	Bytes.u32(code, 0x90000000 | (immlo << 29) | (immhi << 5), 0);
	Bytes.u32(code, 0x91000000 | ((tablesRva & 0xfff) << 10), 4);
	Bytes.u32(code, 0xd65f03c0, 8);
	return { code, relocations: [] };
}

/** One length-prefixed VS_VERSIONINFO node (wLength, wValueLength, wType, key, value, children). */
function versionNode(key, value, type, children) {
	const parts = [];
	const head = Bytes.alloc(6);
	const keyBytes = Bytes.utf16(`${key}\0`);
	let body = Bytes.concat([head, keyBytes]);
	body = Bytes.concat([body, Bytes.alloc(align(body.length, 4) - body.length)]);
	let valueLength = 0;
	if (value !== null) {
		body = Bytes.concat([body, value.bytes]);
		valueLength = value.length;
	}
	for (const child of children) {
		body = Bytes.concat([body, Bytes.alloc(align(body.length, 4) - body.length), child]);
	}
	Bytes.u16(body, body.length, 0);
	Bytes.u16(body, valueLength, 2);
	Bytes.u16(body, type, 4);
	parts.push(body);
	return Bytes.concat(parts);
}

/** The keyboard-driver version resource emitRc describes. */
function versionResource(model) {
	const v = (model.version_string || '1.0').split('.').map(Number);
	while (v.length < 4) v.push(0);
	const fixed = Bytes.alloc(52);
	const words = [
		0xfeef04bd,
		0x00010000,
		((v[0] << 16) | v[1]) >>> 0,
		((v[2] << 16) | v[3]) >>> 0,
		((v[0] << 16) | v[1]) >>> 0,
		((v[2] << 16) | v[3]) >>> 0,
		0x3f,
		0,
		0x40004,
		3,
		2,
		0,
		0
	];
	words.forEach((word, i) => Bytes.u32(fixed, word, 4 * i));
	const text = (s) => {
		const bytes = Bytes.utf16(`${s}\0`);
		return { bytes, length: bytes.length / 2 };
	};
	const strings = [
		['CompanyName', model.company || model.layout_text],
		['FileDescription', `${model.layout_text} keyboard layout`],
		['FileVersion', model.version_string || '1.0'],
		['InternalName', model.dll_name],
		['LegalCopyright', model.copyright || ''],
		['OriginalFilename', `${model.dll_name}.dll`],
		['ProductName', model.layout_text],
		['ProductVersion', model.version_string || '1.0']
	].map(([key, value]) => versionNode(key, text(value), 1, []));
	const translation = Bytes.alloc(4);
	Bytes.u16(translation, 0x409, 0);
	Bytes.u16(translation, 1200, 2);
	return versionNode('VS_VERSION_INFO', { bytes: fixed, length: 52 }, 0, [
		versionNode('StringFileInfo', null, 1, [versionNode('040904B0', null, 1, strings)]),
		versionNode('VarFileInfo', null, 1, [
			versionNode('Translation', { bytes: translation, length: 4 }, 0, [])
		])
	]);
}

/** The string-table block holding the Layout Display Name (string 1000). */
function stringBlock(model) {
	const id = C.DISPLAY_NAME_RESOURCE;
	const parts = [];
	for (let i = 0; i < 16; i++) {
		const s = i === id % 16 ? model.layout_text : '';
		const len = Bytes.alloc(2);
		Bytes.u16(len, s.length, 0);
		parts.push(len, Bytes.utf16(s));
	}
	return { name: Math.floor(id / 16) + 1, data: Bytes.concat(parts) };
}

/** The .rsrc section: type → name → language directories, data entries, data. */
function resources(model, rva) {
	const block = stringBlock(model);
	const leaves = [
		{ type: RT_STRING, name: block.name, data: block.data },
		{ type: RT_VERSION, name: 1, data: versionResource(model) }
	];
	const dir = (count) => {
		const b = Bytes.alloc(16 + 8 * count);
		Bytes.u16(b, count, 14);
		return b;
	};
	// Layout: root, one name directory per type, one language directory per name.
	const root = dir(leaves.length);
	const names = leaves.map(() => dir(1));
	const langs = leaves.map(() => dir(1));
	let at = root.length + names.reduce((a, b) => a + b.length, 0);
	at += langs.reduce((a, b) => a + b.length, 0);
	const entriesAt = at;
	at += 16 * leaves.length;
	const dataAt = [];
	for (const leaf of leaves) {
		at = align(at, 8);
		dataAt.push(at);
		at += leaf.data.length;
	}
	const out = Bytes.alloc(at);
	let cursor = root.length;
	const nameAt = [];
	for (const b of names) {
		nameAt.push(cursor);
		cursor += b.length;
	}
	const langAt = [];
	for (const b of langs) {
		langAt.push(cursor);
		cursor += b.length;
	}
	leaves.forEach((leaf, i) => {
		Bytes.u32(root, leaf.type, 16 + 8 * i);
		Bytes.u32(root, (0x80000000 | nameAt[i]) >>> 0, 20 + 8 * i);
		Bytes.u32(names[i], leaf.name, 16);
		Bytes.u32(names[i], (0x80000000 | langAt[i]) >>> 0, 20);
		Bytes.u32(langs[i], RESOURCE_LANGUAGE, 16);
		Bytes.u32(langs[i], entriesAt + 16 * i, 20);
		const entry = entriesAt + 16 * i;
		Bytes.u32(out, rva + dataAt[i], entry);
		Bytes.u32(out, leaf.data.length, entry + 4);
		out.set(leaf.data, dataAt[i]);
	});
	out.set(root, 0);
	names.forEach((b, i) => out.set(b, nameAt[i]));
	langs.forEach((b, i) => out.set(b, langAt[i]));
	return out;
}

/** The .reloc section: one block per 4 KiB page, padded to a 4-byte size. */
function relocationSection(relocations) {
	const pages = new Map();
	for (const r of relocations.slice().sort((a, b) => a.rva - b.rva)) {
		const page = r.rva & ~0xfff;
		if (!pages.has(page)) pages.set(page, []);
		pages.get(page).push(((r.type << 12) | (r.rva & 0xfff)) >>> 0);
	}
	const blocks = [];
	for (const [page, entries] of pages) {
		if (entries.length % 2) entries.push(0);
		const b = Bytes.alloc(8 + 2 * entries.length);
		Bytes.u32(b, page, 0);
		Bytes.u32(b, b.length, 4);
		entries.forEach((e, i) => Bytes.u16(b, e, 8 + 2 * i));
		blocks.push(b);
	}
	return Bytes.concat(blocks);
}

/** The PE checksum: 16-bit one's-complement sum of the file, checksum field skipped, plus its length. */
function peChecksum(bytes, checksumOffset) {
	let sum = 0;
	for (let i = 0; i < bytes.length; i += 2) {
		if (i === checksumOffset || i === checksumOffset + 2) continue;
		sum += i + 1 < bytes.length ? Bytes.read16(bytes, i) : bytes[i];
		sum = (sum & 0xffff) + Math.floor(sum / 0x10000);
	}
	sum = (sum & 0xffff) + (sum >>> 16);
	return (sum + bytes.length) >>> 0;
}

/**
 * One layout DLL image.
 * @param {object} model - A checked kbd tables model.
 * @param {string} arch - x86, wow64, x64 or arm64.
 * @returns {Uint8Array}
 */
function writeImage(model, arch) {
	const image = IMAGES[arch];
	if (!image) throw new Model.ModelError('kbd_arch_unknown', arch);
	const codeRva = SECTION_ALIGN;
	const codeSize = image.machine === 0x014c ? 6 : image.machine === 0x8664 ? 8 : 12;
	const rdataRva = codeRva + align(codeSize, SECTION_ALIGN);
	const data = rdata(model, image, rdataRva);
	const code = descriptorCode(image, codeRva, data.tablesRva);
	data.exportsDir.patch(data.bytes, codeRva);
	const rsrcRva = rdataRva + align(data.bytes.length, SECTION_ALIGN);
	const rsrc = resources(model, rsrcRva);
	const relocRva = rsrcRva + align(rsrc.length, SECTION_ALIGN);
	const reloc = relocationSection(code.relocations.concat(data.relocations));
	const sections = [
		{ name: '.text', rva: codeRva, bytes: code.code, flags: SCN.code },
		{ name: '.rdata', rva: rdataRva, bytes: data.bytes, flags: SCN.rdata },
		{ name: '.rsrc', rva: rsrcRva, bytes: rsrc, flags: SCN.rdata },
		{ name: '.reloc', rva: relocRva, bytes: reloc, flags: SCN.reloc }
	];
	let raw = HEADERS_SIZE;
	for (const s of sections) {
		s.raw = raw;
		s.rawSize = align(s.bytes.length, FILE_ALIGN);
		raw += s.rawSize;
	}
	const file = Bytes.alloc(raw);
	Bytes.u16(file, 0x5a4d, 0);
	Bytes.u32(file, PE_OFFSET, 0x3c);
	const pe = PE_OFFSET;
	Bytes.u32(file, 0x00004550, pe);
	const optSize = image.plus ? 0xf0 : 0xe0;
	Bytes.u16(file, image.machine, pe + 4);
	Bytes.u16(file, sections.length, pe + 6);
	Bytes.u16(file, optSize, pe + 20);
	Bytes.u16(file, image.chars, pe + 22);
	const opt = pe + 24;
	const sizeOf = (flags) =>
		sections.filter((s) => s.flags === flags).reduce((a, s) => a + s.rawSize, 0);
	Bytes.u16(file, image.plus ? 0x20b : 0x10b, opt);
	file[opt + 2] = 14;
	Bytes.u32(file, sizeOf(SCN.code), opt + 4);
	Bytes.u32(file, sizeOf(SCN.rdata) + sizeOf(SCN.reloc), opt + 8);
	Bytes.u32(file, 0, opt + 16);
	Bytes.u32(file, codeRva, opt + 20);
	if (image.plus) Bytes.u64(file, image.base, opt + 24);
	else {
		Bytes.u32(file, rdataRva, opt + 24);
		Bytes.u32(file, image.base, opt + 28);
	}
	Bytes.u32(file, SECTION_ALIGN, opt + 32);
	Bytes.u32(file, FILE_ALIGN, opt + 36);
	Bytes.u16(file, 6, opt + 40);
	Bytes.u16(file, 6, opt + 48);
	Bytes.u32(file, relocRva + align(reloc.length, SECTION_ALIGN), opt + 56);
	Bytes.u32(file, HEADERS_SIZE, opt + 60);
	Bytes.u16(file, 1, opt + 68);
	Bytes.u16(file, image.dll, opt + 70);
	const reserve = [0x100000, 0x1000, 0x100000, 0x1000];
	let field = opt + 72;
	for (const value of reserve) {
		if (image.plus) {
			Bytes.u64(file, value, field);
			field += 8;
		} else {
			Bytes.u32(file, value, field);
			field += 4;
		}
	}
	field += 4;
	Bytes.u32(file, 16, field);
	const dirs = field + 4;
	const dirEntry = (index, rva, size) => {
		Bytes.u32(file, rva, dirs + 8 * index);
		Bytes.u32(file, size, dirs + 8 * index + 4);
	};
	dirEntry(0, rdataRva + data.exportsDir.offset, data.exportsDir.size);
	dirEntry(2, rsrcRva, rsrc.length);
	dirEntry(5, relocRva, reloc.length);
	const table = opt + optSize;
	sections.forEach((s, i) => {
		const at = table + 40 * i;
		Bytes.latin1(file, s.name, at);
		Bytes.u32(file, s.bytes.length, at + 8);
		Bytes.u32(file, s.rva, at + 12);
		Bytes.u32(file, s.rawSize, at + 16);
		Bytes.u32(file, s.raw, at + 20);
		Bytes.u32(file, s.flags, at + 36);
		file.set(s.bytes, s.raw);
	});
	const checksumAt = opt + 64;
	Bytes.u32(file, peChecksum(file, checksumAt), checksumAt);
	return file;
}

/**
 * The four layout DLL images of a model, written without a toolchain.
 * @param {object} input - A kbd tables model.
 * @returns {Object<string, Uint8Array>} x86, wow64, x64 and arm64 images.
 */
function writeDlls(input) {
	const model = Model.check(input);
	return Object.fromEntries(Object.keys(IMAGES).map((arch) => [arch, writeImage(model, arch)]));
}

module.exports = { IMAGES, writeDlls, writeImage, peChecksum };
	};
	var Source = load('./source.cjs');
	var Writer = load('./pe-writer.cjs');
	return {
		Model: load('./model.cjs'),
		fromSource: Source.fromSource,
		writeDlls: Writer.writeDlls,
		IMAGES: Writer.IMAGES
	};
})();
