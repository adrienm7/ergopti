// _shared/ui/layout_editor/_generated/klc_generator.js

// ==========================================
// AUTO-GENERATED — do not edit manually
// Source: tools/codegen/lib/windows-keyboard-layout.cjs
// Run: npm run codegen:layout-editor-klc:js
// ==========================================

// The MSKLC generator of the repository tool, loaded by the layout editor page.
var LayoutKlcGenerator = (function () {
	var module = { exports: {} };
	(function (module, exports) {
// tools/codegen/lib/windows-keyboard-layout.cjs

/**
 * ==============================================================================
 * MODULE: Windows Keyboard Layout Model and Sources
 * DESCRIPTION:
 * Turns the canonical form of a macOS .keylayout (the shared Lua reader,
 * _shared/lua/layouts/keylayout.lua) into a Windows keyboard layout: one model
 * of scan codes, virtual keys, characters, dead keys and ligatures, written as
 * the C, header, resource and module-definition sources a keyboard DLL is
 * compiled from, and as the MSKLC .klc source of the same layout.
 *
 * FEATURES & RATIONALE:
 * 1. The DLL is built by a plain MSVC + Windows SDK toolchain without MSKLC:
 *    the C tables are written from kbd.h's structures (KBDTABLES and the
 *    tables it points to) and the .klc from the MSKLC source format. Kalamine
 *    showed the idea; none of its code or templates is used. The key names
 *    come from the shared physical key registry.
 * 2. Nothing is specific to one layout: each Windows column is read from the
 *    keyMap the layout's own modifierMap selects (base, Shift, AltGr, Shift +
 *    AltGr), the physical keys come from the shared keycode table through the
 *    layout's keycode convention, and the dead keys from its actions and
 *    terminators.
 * 3. A virtual key follows the character a key types:
 *    Ctrl+C is on the key that types c. Windows keys its character tables by
 *    virtual key, so two keys cannot share one; the macOS Command keyMap's
 *    left-hand shortcuts cannot be expressed and are not read.
 * 4. Fail fast on what a keyboard DLL cannot say and the layout needs (a
 *    Caps Lock that is neither "none" nor "like Shift", two dead keys with one
 *    dead character, a chained dead key loop); a dead-key result Windows cannot
 *    type (more than one UTF-16 unit) is left out and listed in `omitted`,
 *    which the generated sources name and the codegen test pins.
 * ==============================================================================
 */

'use strict';

// The Windows columns of the generated character table, in table order, and
// the macOS modifiers whose keyMap gives each one. The two Ctrl columns stay
// empty (Windows derives Ctrl+letter control characters itself).
const COLUMNS = [
	{ name: 'base', klc: '0', mac: [] },
	{ name: 'shift', klc: '1', mac: ['shift'] },
	{ name: 'ctrl', klc: '2', mac: null },
	{ name: 'shift_ctrl', klc: '3', mac: null },
	{ name: 'altgr', klc: '6', mac: ['option'] },
	{ name: 'shift_altgr', klc: '7', mac: ['option', 'shift'] }
];

// The virtual keys a character key may take when the character it types names
// none, in allocation order (the VK_OEM_* keys, the ISO key's own last).
const OEM_POOL = [
	'OEM_1',
	'OEM_2',
	'OEM_3',
	'OEM_4',
	'OEM_5',
	'OEM_6',
	'OEM_7',
	'OEM_8',
	'OEM_102'
];

// Scan code of the ISO key left of Z: it keeps its own VK_OEM_102.
const ISO_KEY_SCAN_CODE = 0x56;

// The QWERTY virtual key of every scan code a layout key can sit on (kbd.h,
// KBD_TYPE 4): a punctuation key keeps its own when the layout leaves it free.
const QWERTY_VK = {
	0x02: '1',
	0x03: '2',
	0x04: '3',
	0x05: '4',
	0x06: '5',
	0x07: '6',
	0x08: '7',
	0x09: '8',
	0x0a: '9',
	0x0b: '0',
	0x0c: 'OEM_MINUS',
	0x0d: 'OEM_PLUS',
	0x10: 'Q',
	0x11: 'W',
	0x12: 'E',
	0x13: 'R',
	0x14: 'T',
	0x15: 'Y',
	0x16: 'U',
	0x17: 'I',
	0x18: 'O',
	0x19: 'P',
	0x1a: 'OEM_4',
	0x1b: 'OEM_6',
	0x1e: 'A',
	0x1f: 'S',
	0x20: 'D',
	0x21: 'F',
	0x22: 'G',
	0x23: 'H',
	0x24: 'J',
	0x25: 'K',
	0x26: 'L',
	0x27: 'OEM_1',
	0x28: 'OEM_7',
	0x29: 'OEM_3',
	0x2b: 'OEM_5',
	0x2c: 'Z',
	0x2d: 'X',
	0x2e: 'C',
	0x2f: 'V',
	0x30: 'B',
	0x31: 'N',
	0x32: 'M',
	0x33: 'OEM_COMMA',
	0x34: 'OEM_PERIOD',
	0x35: 'OEM_2',
	0x39: 'SPACE',
	0x56: 'OEM_102'
};

// Characters that name a punctuation virtual key of their own.
const PUNCTUATION_VK = { ',': 'OEM_COMMA', '.': 'OEM_PERIOD', '+': 'OEM_PLUS', '-': 'OEM_MINUS' };

// Longest ligature a keyboard DLL can carry (kbd.h defines LIGATURE1..5) and
// the longest MSKLC accepts.
const MAX_LIGATURE = 4;

// ===================================
// ===================================
// ======= 1/ Canonical Lookup =======
// ===================================
// ===================================

/**
 * A canonical list field as an array: the Lua JSON encoder writes an empty
 * table as {}.
 * @param {unknown} value - Decoded field.
 * @param {string} what - Field name for the error.
 * @returns {Array} The list.
 */
function list(value, what) {
	if (Array.isArray(value)) return value;
	if (value && typeof value === 'object' && Object.keys(value).length === 0) return [];
	throw new Error(`canonical keylayout: ${what} must be a list`);
}

/**
 * Indexes the canonical form for lookups.
 * @param {object} canonical - Schema-1 canonical keylayout.
 * @returns {object} The indexed layout.
 */
function indexLayout(canonical) {
	if (!canonical || canonical.schema !== 1) throw new Error('canonical keylayout must be schema 1');
	const sets = new Map();
	for (const set of list(canonical.key_map_sets, 'key_map_sets')) {
		const maps = new Map();
		for (const keyMap of list(set.key_maps, 'key_maps')) {
			const keys = new Map();
			for (const key of list(keyMap.keys, 'keys')) {
				keys.set(
					key.code,
					key.output !== undefined ? { output: key.output } : { action: key.action }
				);
			}
			maps.set(keyMap.index, { keys, base: keyMap.base });
		}
		sets.set(set.id, maps);
	}
	const actions = new Map();
	for (const action of list(canonical.actions, 'actions')) {
		const whens = new Map();
		for (const when of list(action.whens, 'whens')) whens.set(when.state, when);
		actions.set(action.id, { id: action.id, whens });
	}
	const terminators = new Map();
	for (const item of list(canonical.terminators, 'terminators'))
		terminators.set(item.state, item.output);
	const selects = list(canonical.selects, 'selects').map((select) => ({
		index: select.index,
		modifiers: list(select.modifiers, 'modifiers').map((modifier) => ({
			required: list(modifier.required, 'required'),
			optional: list(modifier.optional, 'optional')
		}))
	}));
	return { canonical, sets, actions, terminators, selects };
}

/**
 * The keyMap index the layout selects when exactly `pressed` are down (the
 * rule of xkb_converter.lua's key_map_index: first matching select wins).
 * @param {object} layout - Indexed layout.
 * @param {string[]} pressed - Modifier tokens held.
 * @returns {number} The keyMap index.
 */
function keyMapIndex(layout, pressed) {
	for (const select of layout.selects) {
		for (const modifier of select.modifiers) {
			const allowed = new Set([...modifier.required, ...modifier.optional]);
			if (
				modifier.required.every((token) => pressed.includes(token)) &&
				pressed.every((token) => allowed.has(token))
			)
				return select.index;
		}
	}
	return layout.canonical.default_index;
}

/**
 * The <key> entry of `code` in keyMap `index`, following baseMapSet.
 * @returns {object|null} { output } or { action }.
 */
function keyEntry(layout, setId, index, code, depth) {
	if (depth > 8) throw new Error('keyMap base chain is too deep (cycle?)');
	const maps = layout.sets.get(setId);
	if (!maps) throw new Error(`keyMapSet '${setId}' is not defined`);
	const map = maps.get(index);
	if (map && map.keys.has(code)) return map.keys.get(code);
	if (map && map.base) return keyEntry(layout, map.base.set, map.base.index, code, depth + 1);
	return null;
}

/**
 * Whether `text` types something visible (no C0 or C1 control character), as
 * xkb_converter.lua's is_printable.
 * @param {string} text - Output text.
 * @returns {boolean}
 */
function isPrintable(text) {
	if (typeof text !== 'string' || text === '') return false;
	for (const char of text) {
		const cp = char.codePointAt(0);
		if (cp < 0x20 || cp === 0x7f || (cp >= 0x80 && cp <= 0x9f)) return false;
	}
	return true;
}

/**
 * What `code` types in keyMap `index` from the neutral state.
 * @returns {{kind: string, text?: string, state?: string, action?: string}}
 */
function resolveCell(layout, index, code) {
	const entry = keyEntry(layout, layout.canonical.map_set, index, code, 0);
	if (!entry) return { kind: 'none' };
	if (entry.output !== undefined)
		return isPrintable(entry.output) ? { kind: 'text', text: entry.output } : { kind: 'none' };
	const action = layout.actions.get(entry.action);
	if (!action) throw new Error(`key ${code} uses undefined action '${entry.action}'`);
	const when = action.whens.get('none');
	if (when && when.next) return { kind: 'dead', state: when.next, action: action.id };
	if (when && isPrintable(when.output))
		return { kind: 'text', text: when.output, action: action.id };
	return { kind: 'none' };
}

// ===================================
// ===================================
// ======= 2/ Windows Model ==========
// ===================================
// ===================================

/** UTF-16 code units of a string. */
function units(text) {
	const out = [];
	for (let i = 0; i < text.length; i++) out.push(text.charCodeAt(i));
	return out;
}

/**
 * The physical keys of a layout, from the shared keycode table.
 * @param {object} table - Decoded _shared/modules/layouts/mac_keycodes.json.
 * @param {string} convention - "iso" or "ansi".
 * @returns {{code: string, scanCode: number, mac: number}[]}
 */
function physicalKeys(table, convention) {
	if (!list(table.conventions, 'conventions').includes(convention))
		throw new Error(`unknown keycode convention '${convention}'`);
	return list(table.keys, 'keys').map((key) => {
		const match = /^SC([0-9A-F]{3})$/.exec(key.ahk);
		if (!match) throw new Error(`key ${key.code} has no scan code (ahk '${key.ahk}')`);
		return {
			code: key.code,
			scanCode: parseInt(match[1], 16),
			mac: typeof key.mac === 'object' ? key.mac[convention] : key.mac
		};
	});
}

/**
 * The Caps Lock attribute of a key: 0 when Caps Lock changes nothing, CAPLOK
 * when it acts as Shift on the base and Shift columns.
 */
function capsAttribute(layout, code, cells, keyName) {
	const caps = resolveCell(layout, keyMapIndex(layout, ['caps']), code);
	const shiftCaps = resolveCell(layout, keyMapIndex(layout, ['caps', 'shift']), code);
	const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
	if (same(caps, cells.base) && same(shiftCaps, cells.shift)) return 0;
	if (same(caps, cells.shift) && same(shiftCaps, cells.base)) return 'CAPLOK';
	throw new Error(
		`${keyName}: Caps Lock types neither the base nor the Shift characters (SGCAP is not generated)`
	);
}

/**
 * Assigns the virtual keys: the ISO key's own, a digit or letter the key
 * types, a punctuation character's own; then the key's QWERTY punctuation
 * virtual key when free; then the OEM pool.
 * @param {object[]} keys - Model keys with their cells.
 */
function assignVirtualKeys(keys) {
	const used = new Set();
	const pending = [];
	const take = (key, vk) => {
		if (used.has(vk)) return false;
		used.add(vk);
		key.vk = vk;
		return true;
	};
	const plain = (cell) => (cell.kind === 'text' && [...cell.text].length === 1 ? cell.text : null);
	for (const key of keys) {
		const base = plain(key.cells.base);
		const shifted = plain(key.cells.shift);
		let wanted = null;
		if (key.scanCode === ISO_KEY_SCAN_CODE) wanted = 'OEM_102';
		else if (base !== null && /^[0-9]$/.test(base)) wanted = base;
		else if (shifted !== null && /^[0-9]$/.test(shifted)) wanted = shifted;
		else if (shifted !== null && /^[A-Z]$/.test(shifted)) wanted = shifted;
		else if (base === ' ') wanted = 'SPACE';
		else if (base !== null && PUNCTUATION_VK[base]) wanted = PUNCTUATION_VK[base];
		else if (shifted !== null && PUNCTUATION_VK[shifted]) wanted = PUNCTUATION_VK[shifted];
		if (wanted === null || !take(key, wanted)) pending.push(key);
	}
	// Every key that can keep its own QWERTY punctuation virtual key does, before
	// the pool hands one out: otherwise a pooled key could take a later key's own.
	const pooled = [];
	for (const key of pending) {
		const qwerty = QWERTY_VK[key.scanCode];
		if (!(qwerty && qwerty.startsWith('OEM_') && take(key, qwerty))) pooled.push(key);
	}
	for (const key of pooled) {
		const free = OEM_POOL.find((vk) => !used.has(vk));
		if (!free) throw new Error(`no virtual key is left for ${key.code}`);
		take(key, free);
	}
}

/**
 * The name of a dead-key state shown by Windows ("s1_circumflex" → "CIRCUMFLEX").
 * @param {string} state - State id.
 * @returns {string} ASCII upper-case name.
 */
function deadKeyName(state) {
	const name = state
		.replace(/^s\d+_/, '')
		.replace(/[^A-Za-z0-9]+/g, ' ')
		.trim()
		.toUpperCase();
	if (name === '') throw new Error(`dead-key state '${state}' has no usable name`);
	return name;
}

/**
 * Builds the Windows model of one layout.
 * @param {object} canonical - Schema-1 canonical keylayout.
 * @param {object} keycodeTable - Decoded mac_keycodes.json.
 * @param {string} convention - The layout's keycode convention.
 * @returns {object} { keys, deadKeys, ligatures, omitted }.
 */
function buildModel(canonical, keycodeTable, convention) {
	const layout = indexLayout(canonical);
	for (const modifier of [['option'], ['option', 'shift']]) {
		if (keyMapIndex(layout, [...modifier, 'caps']) !== keyMapIndex(layout, modifier))
			throw new Error('Caps Lock changes the AltGr columns (CAPLOKALTGR is not generated)');
	}
	const keys = [];
	for (const physical of physicalKeys(keycodeTable, convention)) {
		const cells = {};
		for (const column of COLUMNS) {
			cells[column.name] =
				column.mac === null
					? { kind: 'none' }
					: resolveCell(layout, keyMapIndex(layout, column.mac), physical.mac);
		}
		if (COLUMNS.every((column) => cells[column.name].kind === 'none')) continue;
		const key = { code: physical.code, scanCode: physical.scanCode, cells, vk: null, attribute: 0 };
		key.attribute = capsAttribute(layout, physical.mac, cells, physical.code);
		keys.push(key);
	}
	assignVirtualKeys(keys);

	// Dead characters: a state's terminator, one UTF-16 unit, distinct per state.
	const deadChars = new Map();
	const charStates = new Map();
	const deadCharOf = (state) => {
		if (deadChars.has(state)) return deadChars.get(state);
		const terminator = layout.terminators.get(state);
		if (typeof terminator !== 'string' || terminator.length !== 1)
			throw new Error(
				`dead-key state '${state}' needs a one-unit terminator, has ${JSON.stringify(terminator)}`
			);
		const unit = terminator.charCodeAt(0);
		if (charStates.has(unit))
			throw new Error(
				`dead-key states '${charStates.get(unit)}' and '${state}' share the dead character ${terminator}`
			);
		charStates.set(unit, state);
		deadChars.set(state, unit);
		return unit;
	};

	const ligatures = [];
	for (const key of keys) {
		COLUMNS.forEach((column, position) => {
			const cell = key.cells[column.name];
			if (cell.kind === 'dead') cell.deadChar = deadCharOf(cell.state);
			if (cell.kind !== 'text') return;
			const textUnits = units(cell.text);
			if (textUnits.length === 1) {
				cell.char = textUnits[0];
				return;
			}
			if (textUnits.length > MAX_LIGATURE)
				throw new Error(
					`${key.code} ${column.name} types ${textUnits.length} UTF-16 units (at most ${MAX_LIGATURE})`
				);
			cell.kind = 'ligature';
			cell.units = textUnits;
			ligatures.push({ vk: key.vk, column: position, units: textUnits });
		});
	}

	// What each dead key does to the next key, from the actions the keys type.
	const deadKeys = new Map();
	const omitted = [];
	const addEntry = (state, baseUnit, entry, where) => {
		const dead = deadKeys.get(state);
		const existing = dead.entries.find((item) => item.base === baseUnit);
		if (existing) {
			if (existing.result !== entry.result || existing.chained !== entry.chained)
				throw new Error(
					`${where}: two actions give ${state} different results for U+${hex4(baseUnit)}`
				);
			return;
		}
		dead.entries.push({ base: baseUnit, ...entry });
	};
	for (const key of keys) {
		for (const column of COLUMNS) {
			const cell = key.cells[column.name];
			if (cell.kind === 'dead' && !deadKeys.has(cell.state))
				deadKeys.set(cell.state, {
					state: cell.state,
					deadChar: cell.deadChar,
					name: deadKeyName(cell.state),
					entries: []
				});
		}
	}
	const stateOrder = [...deadKeys.keys()].sort();
	for (const key of keys) {
		for (const column of COLUMNS) {
			const cell = key.cells[column.name];
			if (!cell.action) continue;
			const typed =
				cell.kind === 'dead'
					? String.fromCharCode(cell.deadChar)
					: cell.kind === 'text'
						? cell.text
						: cell.units
							? String.fromCharCode(...cell.units)
							: null;
			if (typed === null) continue;
			const action = layout.actions.get(cell.action);
			for (const state of stateOrder) {
				const when = action.whens.get(state);
				if (!when) continue;
				const where = `${key.code} ${column.name}`;
				const result = when.next ? null : isPrintable(when.output) ? when.output : null;
				if (!when.next && result === null) continue;
				// DEADTRANS pairs one UTF-16 unit with one: a ligature cell or a
				// longer result cannot be typed through a dead key.
				if (typed.length !== 1 || (result !== null && result.length !== 1)) {
					if (!omitted.some((seen) => seen.state === state && seen.typed === typed))
						omitted.push({ state, typed, output: result === null ? `(${when.next})` : result });
					continue;
				}
				const baseUnit = typed.charCodeAt(0);
				if (when.next) {
					if (!deadKeys.has(when.next))
						throw new Error(`${where}: state '${when.next}' has no dead key`);
					addEntry(
						state,
						baseUnit,
						{ result: deadKeys.get(when.next).deadChar, chained: true },
						where
					);
				} else {
					addEntry(state, baseUnit, { result: result.charCodeAt(0), chained: false }, where);
				}
			}
		}
	}
	return {
		keys,
		deadKeys: stateOrder.map((state) => deadKeys.get(state)),
		ligatures,
		omitted
	};
}

// ===================================
// ===================================
// ======= 3/ Source Writers =========
// ===================================
// ===================================

/** Four lower-case hex digits. */
function hex4(value) {
	return value.toString(16).padStart(4, '0');
}

/** A C virtual key expression. */
function cVk(vk) {
	return vk.length === 1 ? `'${vk}'` : `VK_${vk}`;
}

/** The C value of one cell in the main row. */
function cCell(cell) {
	if (cell.kind === 'text') return `0x${hex4(cell.char)}`;
	if (cell.kind === 'dead') return 'WCH_DEAD';
	if (cell.kind === 'ligature') return 'WCH_LGTR';
	return 'WCH_NONE';
}

/** The KLC value of one cell. */
function klcCell(cell) {
	if (cell.kind === 'text') return hex4(cell.char);
	if (cell.kind === 'dead') return `${hex4(cell.deadChar)}@`;
	if (cell.kind === 'ligature') return '%%';
	return '-1';
}

/**
 * The generated-file banner shared by every C-family source.
 * @param {object} context - { fileName, meta, sourceRel }.
 * @returns {string[]} Comment lines.
 */
function banner(context, commentPrefix) {
	return [
		`${commentPrefix} ${context.fileName}`,
		`${commentPrefix} GENERATED by tools/codegen/codegen-windows-keyboard-layout.cjs from`,
		`${commentPrefix} ${context.sourceRel} (${context.meta.name} ${context.meta.version}).`,
		`${commentPrefix} Do not edit: change the layout or the generator and regenerate.`
	];
}

/** "U+0020 U+20AC" for a string (ASCII-only, for the generated comments). */
function codePoints(text) {
	return [...text]
		.map((char) => `U+${char.codePointAt(0).toString(16).toUpperCase().padStart(4, '0')}`)
		.join(' ');
}

/** The omitted dead-key sequences, as comment lines. */
function omittedLines(model, commentPrefix) {
	if (model.omitted.length === 0) return [];
	return [
		`${commentPrefix} Dead-key sequences a keyboard DLL cannot type (a key or a result of more than one UTF-16 unit), left out:`,
		...model.omitted.map(
			(item) =>
				`${commentPrefix}   ${item.state}: ${codePoints(item.typed)} -> ${codePoints(item.output)}`
		)
	];
}

/**
 * The layout header: overrides kbd.h's QWERTY scan code to virtual key macros.
 */
function renderHeader(model, context) {
	const lines = [...banner(context, '//'), '', '#pragma once', ''];
	for (const key of [...model.keys].sort((a, b) => a.scanCode - b.scanCode)) {
		const macro = `T${key.scanCode.toString(16).toUpperCase().padStart(2, '0')}`;
		lines.push(`#undef ${macro}`, `#define ${macro} ${cVk(key.vk)}`);
	}
	return `${lines.join('\n')}\n`;
}

// Scan codes whose virtual key Windows needs flagged (kbd.h): the right Shift
// is extended, Num * and Num Lock have a second virtual key, and the number
// pad keys that double as navigation are KBDNUMPAD | KBDSPECIAL.
const SCAN_FLAGS = new Map([
	[0x36, 'KBDEXT'],
	[0x37, 'KBDMULTIVK'],
	[0x45, 'KBDEXT | KBDMULTIVK'],
	[0x46, 'KBDMULTIVK'],
	...[0x47, 0x48, 0x49, 0x4b, 0x4c, 0x4d, 0x4f, 0x50, 0x51, 0x52, 0x53].map((sc) => [
		sc,
		'KBDNUMPAD | KBDSPECIAL'
	])
]);

// Highest plain scan code the table maps (kbd.h's T00..T7E).
const MAX_PLAIN_SCAN_CODE = 0x7e;

// E0-prefixed scan codes kbd.h names an X macro for: right-hand modifiers,
// navigation, the number pad's Enter and divide, the Windows keys and media.
const E0_SCAN_CODES = [
	0x10, 0x19, 0x1c, 0x1d, 0x20, 0x21, 0x22, 0x24, 0x2e, 0x30, 0x32, 0x35, 0x37, 0x38, 0x46, 0x47,
	0x48, 0x49, 0x4b, 0x4d, 0x4f, 0x50, 0x51, 0x52, 0x53, 0x5b, 0x5c, 0x5d, 0x5f, 0x65, 0x66, 0x67,
	0x68, 0x69, 0x6a, 0x6b, 0x6c, 0x6d
];

// Keys outside the layout whose characters every Windows layout gives: by
// table width, each row the virtual key and its characters per column.
const FIXED_KEYS = [
	{
		width: 1,
		rows: [...'0123456789'].map((digit) => [`VK_NUMPAD${digit}`, `'${digit}'`])
	},
	{
		width: 2,
		rows: [
			['VK_TAB', "'\\t'", "'\\t'"],
			['VK_ADD', "'+'", "'+'"],
			['VK_SUBTRACT', "'-'", "'-'"],
			['VK_MULTIPLY', "'*'", "'*'"],
			['VK_DIVIDE', "'/'", "'/'"],
			['VK_DECIMAL', "'.'", "'.'"]
		]
	},
	{
		width: 3,
		rows: [
			['VK_BACK', "'\\b'", "'\\b'", '0x007f'],
			['VK_ESCAPE', '0x001b', '0x001b', '0x001b'],
			['VK_RETURN', "'\\r'", "'\\r'", "'\\n'"],
			['VK_CANCEL', '0x0003', '0x0003', '0x0003']
		]
	}
];

/**
 * The names Windows shows for keys that type no character (GetKeyNameText),
 * from the shared physical key registry: the W3C code with its words split
 * ("ArrowUp" → "Arrow Up"). Plain and E0-extended keys are separate tables.
 * @param {object} registry - Decoded _shared/data/keycodes/physical_keys.json.
 * @returns {{plain: Array<[number, string]>, extended: Array<[number, string]>}}
 */
function keyNames(registry) {
	const entries = Array.isArray(registry.keys) ? registry.keys : Object.entries(registry.keys);
	const plain = [];
	const extended = [];
	for (const [code, key] of entries) {
		if (key.kind !== 'key' || key.ahk_send === null || key.ahk_send === undefined) continue;
		const match = /^SC([0-9A-F]{3})$/.exec(key.ahk);
		if (!match) throw new Error(`physical key ${code} has no scan code (ahk '${key.ahk}')`);
		const value = parseInt(match[1], 16);
		const name = code.replace(/([a-z])([A-Z0-9])/g, '$1 $2');
		if (!/^[A-Za-z0-9 ]+$/.test(name))
			throw new Error(`physical key ${code} gives a non-ASCII key name`);
		if (value >= 0x100) extended.push([value & 0xff, name]);
		else plain.push([value, name]);
	}
	const byCode = (a, b) => a[0] - b[0];
	return { plain: plain.sort(byCode), extended: extended.sort(byCode) };
}

/** Two upper-case hex digits. */
function hex2(value) {
	return value.toString(16).toUpperCase().padStart(2, '0');
}

/** A C array definition in the DLL's data section. */
function cArray(type, name, lines) {
	return [`static KBD_DATA ${type} ${name}[] = {`, ...lines.map((line) => `    ${line}`), '};', ''];
}

/**
 * The tables of the keyboard DLL, written from this model and kbd.h's
 * structures (KBDTABLES, VK_TO_WCHARS<n>, DEADKEY, LIGATURE<n>).
 */
function renderC(model, context) {
	const names = keyNames(context.physicalKeys);
	const out = [
		...banner(context, '//'),
		...omittedLines(model, '//'),
		'',
		'#include <windows.h>',
		'#include "kbd.h"',
		`#include "${context.spec.dll_name}.h"`,
		'',
		'// win32k reads the tables from the image: keep them in one writable data section.',
		'#pragma data_seg(".data")',
		'#define KBD_DATA',
		''
	];

	const scanRows = [];
	for (let sc = 0; sc <= MAX_PLAIN_SCAN_CODE; sc++) {
		const flags = SCAN_FLAGS.get(sc);
		scanRows.push(`T${hex2(sc)}${flags ? ` | ${flags}` : ''},`);
	}
	out.push(...cArray('USHORT', 'ScanToVk', scanRows));
	out.push(
		...cArray('VSC_VK', 'ScanE0ToVk', [
			...E0_SCAN_CODES.map((sc) => `{ 0x${hex2(sc)}, X${hex2(sc)} | KBDEXT },`),
			'{ 0, 0 }'
		])
	);
	out.push(...cArray('VSC_VK', 'ScanE1ToVk', ['{ 0x1D, Y1D },', '{ 0, 0 }']));
	out.push(
		...cArray('VK_TO_BIT', 'ModifierKeys', [
			'{ VK_SHIFT, KBDSHIFT },',
			'{ VK_CONTROL, KBDCTRL },',
			'{ VK_MENU, KBDALT },',
			'{ 0, 0 }'
		])
	);
	// Columns: none, Shift, Ctrl, Shift+Ctrl, then AltGr (Ctrl+Alt) and Shift+AltGr;
	// Alt alone types nothing.
	out.push(
		'static KBD_DATA MODIFIERS Modifiers = {',
		'    &ModifierKeys[0],',
		'    7,',
		'    { 0, 1, 2, 3, SHFT_INVALID, SHFT_INVALID, 4, 5 }',
		'};',
		''
	);

	const layoutRows = [];
	for (const key of model.keys) {
		const cells = COLUMNS.map((column) => key.cells[column.name]);
		layoutRows.push(
			`{ ${[cVk(key.vk), key.attribute === 0 ? '0' : key.attribute, ...cells.map(cCell)].join(', ')} },`
		);
		// The row after a dead key holds, in its columns, the dead characters.
		if (cells.some((cell) => cell.kind === 'dead'))
			layoutRows.push(
				`{ ${['0xff', '0', ...cells.map((cell) => (cell.kind === 'dead' ? `0x${hex4(cell.deadChar)}` : 'WCH_NONE'))].join(', ')} },`
			);
	}
	layoutRows.push(
		`{ ${Array(COLUMNS.length + 2)
			.fill('0')
			.join(', ')} }`
	);
	out.push(...cArray(`VK_TO_WCHARS${COLUMNS.length}`, 'LayoutKeys', layoutRows));
	for (const group of [...FIXED_KEYS].reverse()) {
		out.push(
			...cArray(`VK_TO_WCHARS${group.width}`, `FixedKeys${group.width}`, [
				...group.rows.map((row) => `{ ${[row[0], '0', ...row.slice(1)].join(', ')} },`),
				`{ ${Array(group.width + 2)
					.fill('0')
					.join(', ')} }`
			])
		);
	}
	// The layout's keys first: VkKeyScan then finds a digit on the digit row,
	// not on the number pad.
	out.push(
		...cArray('VK_TO_WCHAR_TABLE', 'CharacterTables', [
			`{ (PVK_TO_WCHARS1)LayoutKeys, ${COLUMNS.length}, sizeof(LayoutKeys[0]) },`,
			...[...FIXED_KEYS]
				.reverse()
				.map(
					(group) =>
						`{ (PVK_TO_WCHARS1)FixedKeys${group.width}, ${group.width}, sizeof(FixedKeys${group.width}[0]) },`
				),
			'{ NULL, 0, 0 }'
		])
	);

	const deadTrans = [];
	for (const dead of model.deadKeys) {
		deadTrans.push(`// ${dead.name}`);
		for (const entry of dead.entries)
			deadTrans.push(
				`DEADTRANS(0x${hex4(entry.base)}, 0x${hex4(dead.deadChar)}, 0x${hex4(entry.result)}, ${entry.chained ? '0x0001' : '0x0000'}),`
			);
	}
	out.push(...cArray('DEADKEY', 'DeadKeys', [...deadTrans, '{ 0, 0, 0 }']));
	out.push(
		...cArray('DEADKEY_LPWSTR', 'DeadKeyNames', [
			...model.deadKeys.map((dead) => `L"\\x${hex4(dead.deadChar)}" L"${dead.name}",`),
			'NULL'
		])
	);
	const nameRows = (rows) => [
		...rows.map(([sc, name]) => `{ 0x${hex2(sc)}, L"${name}" },`),
		'{ 0, NULL }'
	];
	out.push(...cArray('VSC_LPWSTR', 'KeyNames', nameRows(names.plain)));
	out.push(...cArray('VSC_LPWSTR', 'KeyNamesExtended', nameRows(names.extended)));

	const width = Math.max(1, ...model.ligatures.map((item) => item.units.length));
	out.push(
		...cArray(`LIGATURE${width}`, 'Ligatures', [
			...model.ligatures.map(
				(item) =>
					`{ ${[cVk(item.vk), String(item.column), ...item.units.map((unit) => `0x${hex4(unit)}`), ...Array(width - item.units.length).fill('WCH_NONE')].join(', ')} },`
			),
			`{ ${Array(width + 2)
				.fill('0')
				.join(', ')} }`
		])
	);
	out.push(
		'static KBD_DATA KBDTABLES Tables = {',
		'    &Modifiers,',
		'    CharacterTables,',
		'    DeadKeys,',
		'    KeyNames,',
		'    KeyNamesExtended,',
		'    DeadKeyNames,',
		'    ScanToVk,',
		'    sizeof(ScanToVk) / sizeof(ScanToVk[0]),',
		'    ScanE0ToVk,',
		'    ScanE1ToVk,',
		'    MAKELONG(KLLF_ALTGR, KBD_VERSION),',
		model.ligatures.length === 0
			? '    0, 0, NULL'
			: `    ${width}, sizeof(Ligatures[0]), (PLIGATURE1)Ligatures`,
		'};',
		'',
		'// The one export: Windows asks the DLL for its tables.',
		'PKBDTABLES KbdLayerDescriptor(VOID)',
		'{',
		'    return &Tables;',
		'}',
		''
	);
	return out.join('\n');
}

/** The comma-separated four-part version of a.b.c[.d]. */
function rcVersion(version) {
	const parts = String(version).split('.');
	if (parts.length < 3 || parts.length > 4 || parts.some((part) => !/^\d+$/.test(part)))
		throw new Error(`layout version '${version}' must be a.b.c[.d]`);
	while (parts.length < 4) parts.push('0');
	return parts.join(',');
}

/** The version resource and the strings Windows reads from the DLL. */
function renderRc(model, context) {
	const { meta, spec } = context;
	const version = rcVersion(meta.version);
	const dotted = version.replace(/,/g, '.');
	return `${[...banner(context, '//')].join('\n')}

#include "winver.h"

1 VERSIONINFO
 FILEVERSION       ${version}
 PRODUCTVERSION    ${version}
 FILEFLAGSMASK 0x3fL
 FILEFLAGS 0x0L
 FILEOS 0x40004L
 FILETYPE VFT_DLL
 FILESUBTYPE VFT2_DRV_KEYBOARD
BEGIN
    BLOCK "StringFileInfo"
    BEGIN
        BLOCK "000004B0"
        BEGIN
            VALUE "CompanyName",     "${meta.author}\\0"
            VALUE "FileDescription", "${spec.layout_description}\\0"
            VALUE "FileVersion",     "${dotted}\\0"
            VALUE "InternalName",    "${spec.dll_name}\\0"
            VALUE "LegalCopyright",  "(c) ${meta.author}, ${meta.licence} licence\\0"
            VALUE "OriginalFilename","${spec.dll_name}.dll\\0"
            VALUE "ProductName",     "${meta.name}\\0"
            VALUE "ProductVersion",  "${dotted}\\0"
        END
    END
    BLOCK "VarFileInfo"
    BEGIN
        VALUE "Translation", 0x0000, 0x04B0
    END
END

STRINGTABLE DISCARDABLE
LANGUAGE 9, 1
BEGIN
    1000    "${spec.layout_text}"
    1100    "${spec.layout_description} ${meta.version}"
    1200    "${spec.locale_name}"
END
`;
}

/** The module definition: the one export Windows calls. */
function renderDef(context) {
	return `; ${context.spec.dll_name}.def
; GENERATED by tools/codegen/codegen-windows-keyboard-layout.cjs. Do not edit.

LIBRARY ${context.spec.dll_name.toUpperCase()}

EXPORTS
    KbdLayerDescriptor @1
`;
}

/**
 * The MSKLC source of the same layout. MSKLC reads it as UTF-16LE with CRLF;
 * the caller encodes it.
 */
function renderKlc(model, context) {
	const { meta, spec } = context;
	const lines = [
		...banner(context, '//'),
		...omittedLines(model, '//'),
		'',
		`KBD\t${spec.dll_name}\t"${spec.layout_text}"`,
		`COPYRIGHT\t"(c) ${meta.author}"`,
		`COMPANY\t"${meta.author}"`,
		`LOCALENAME\t"${spec.locale_name}"`,
		`LOCALEID\t"0000${spec.language_id.toLowerCase()}"`,
		`VERSION\t${String(meta.version).split('.').slice(0, 2).join('.')}`,
		'',
		'SHIFTSTATE',
		...COLUMNS.map((column) => column.klc),
		'',
		'LAYOUT',
		`//SC\tVK_\tCap\t${COLUMNS.map((column) => column.klc).join('\t')}`
	];
	for (const key of model.keys) {
		const sc = key.scanCode.toString(16).padStart(2, '0');
		const cap = key.attribute === 'CAPLOK' ? '1' : '0';
		lines.push(
			[sc, key.vk, cap, ...COLUMNS.map((column) => klcCell(key.cells[column.name]))].join('\t')
		);
	}
	lines.push(`53\tDECIMAL\t0\t002e\t002e\t-1\t-1\t-1\t-1`, '');
	if (model.ligatures.length > 0) {
		lines.push('LIGATURE', '');
		for (const item of model.ligatures)
			lines.push([item.vk, String(item.column), ...item.units.map(hex4)].join('\t'));
		lines.push('');
	}
	for (const dead of model.deadKeys) {
		lines.push(`DEADKEY\t${hex4(dead.deadChar)}`, '');
		for (const entry of dead.entries)
			lines.push(`${hex4(entry.base)}\t${hex4(entry.result)}${entry.chained ? '@' : ''}`);
		lines.push('');
	}
	const names = keyNames(context.physicalKeys);
	const klcName = ([sc, name]) =>
		`${hex2(sc).toLowerCase()}\t${name.includes(' ') ? `"${name}"` : name}`;
	lines.push(
		'KEYNAME',
		'',
		...names.plain.map(klcName),
		'',
		'KEYNAME_EXT',
		'',
		...names.extended.map(klcName)
	);
	lines.push('', 'KEYNAME_DEAD', '');
	for (const dead of model.deadKeys) lines.push(`${hex4(dead.deadChar)}\t"${dead.name}"`);
	lines.push(
		'',
		'DESCRIPTIONS',
		'',
		`0409\t${spec.layout_text}`,
		'',
		'LANGUAGENAMES',
		'',
		`0409\t${spec.language_name}`,
		'',
		'ENDKBD',
		''
	);
	return lines.join('\n');
}

/**
 * Every generated source of one layout.
 * @param {object} canonical - Canonical keylayout.
 * @param {object} context - { meta, spec, keycodes, sourceRel }.
 * @returns {{model: object, files: Map<string, string>, klc: string}}
 */
function generate(canonical, context) {
	if (!/^[a-z][a-z0-9]{0,7}$/.test(context.spec.dll_name))
		throw new Error(
			`dll_name '${context.spec.dll_name}' must be 1 to 8 lower-case letters and digits`
		);
	if (!/^[0-9A-F]{4}$/.test(context.spec.language_id))
		throw new Error(`language_id '${context.spec.language_id}' must be four upper-case hex digits`);
	const model = buildModel(canonical, context.keycodes, context.meta.keycode_convention);
	const name = context.spec.dll_name;
	const files = new Map();
	files.set(`${name}.c`, renderC(model, { ...context, fileName: `${name}.c` }));
	files.set(`${name}.h`, renderHeader(model, { ...context, fileName: `${name}.h` }));
	files.set(`${name}.rc`, renderRc(model, { ...context, fileName: `${name}.rc` }));
	files.set(`${name}.def`, renderDef(context));
	return { model, files, klc: renderKlc(model, { ...context, fileName: `${name}.klc` }) };
}

/**
 * Encodes a .klc as MSKLC reads it: UTF-16LE with a byte order mark and CRLF.
 * @param {string} text - LF text.
 * @returns {Buffer}
 */
function encodeKlc(text) {
	return Buffer.concat([
		Buffer.from([0xff, 0xfe]),
		Buffer.from(text.replace(/\n/g, '\r\n'), 'utf16le')
	]);
}

module.exports = {
	COLUMNS,
	buildModel,
	generate,
	encodeKlc,
	keyMapIndex,
	indexLayout,
	resolveCell
};
	})(module, module.exports);
	return module.exports;
})();
