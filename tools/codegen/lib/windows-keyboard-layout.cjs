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
 * 1. Kalamine's approach (https://github.com/OneDeadKey/kalamine, MIT): the C
 *    file follows its full.C template and klc.py rules, so the DLL is built by
 *    a plain MSVC + Windows SDK toolchain (kbd.h is in the SDK) without MSKLC.
 * 2. Nothing is specific to one layout: each Windows column is read from the
 *    keyMap the layout's own modifierMap selects (base, Shift, AltGr, Shift +
 *    AltGr), the physical keys come from the shared keycode table through the
 *    layout's keycode convention, and the dead keys from its actions and
 *    terminators.
 * 3. A virtual key follows the character a key types (kalamine's default):
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
// none, in allocation order (kalamine's VK_OEM_* pool, plus the ISO key's own).
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

// Scan code of the ISO key left of Z: it keeps VK_OEM_102 (kalamine).
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

// Characters that name a punctuation virtual key (kalamine's klc_virtual_key).
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
 * Assigns the virtual keys (kalamine's klc_virtual_key rules, then the key's
 * QWERTY punctuation virtual key when free, then the OEM pool).
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
 * Fills every @NAME@ placeholder of a template, refusing a placeholder left
 * unfilled or a value with no placeholder.
 * @param {string} template - Template text.
 * @param {Record<string, string>} values - Placeholder values.
 * @returns {string}
 */
function fill(template, values) {
	let text = template;
	for (const [name, value] of Object.entries(values)) {
		const marker = `@${name}@`;
		if (!text.includes(marker)) throw new Error(`template has no ${marker}`);
		text = text.split(marker).join(value);
	}
	const left = /@[A-Z0-9_]+@/.exec(text);
	if (left) throw new Error(`template placeholder ${left[0]} is not filled`);
	return text;
}

/** One C table row, padded like kalamine's. */
function cRow(values) {
	return `  {${values.map((value) => value.padEnd(13)).join(',')}},`;
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

/**
 * The layout tables (kalamine's full.C template, with this model).
 */
function renderC(model, context) {
	const name8 = context.spec.dll_name;
	const rows = [];
	for (const key of model.keys) {
		const cells = COLUMNS.map((column) => key.cells[column.name]);
		rows.push(cRow([cVk(key.vk), key.attribute === 0 ? '0' : key.attribute, ...cells.map(cCell)]));
		if (cells.some((cell) => cell.kind === 'dead')) {
			rows.push(
				cRow([
					'0xff',
					'0',
					...cells.map((cell) => (cell.kind === 'dead' ? `0x${hex4(cell.deadChar)}` : 'WCH_NONE'))
				])
			);
		}
	}
	const deadNames = model.deadKeys.map(
		(dead) => `    L"\\x${hex4(dead.deadChar)}" L"${dead.name}",`
	);
	const deadTrans = [];
	for (const dead of model.deadKeys) {
		deadTrans.push(`    // ${dead.name}`);
		for (const entry of dead.entries) {
			deadTrans.push(
				`    DEADTRANS(0x${hex4(entry.base)}, 0x${hex4(dead.deadChar)}, 0x${hex4(entry.result)}, ${entry.chained ? '0x0001' : '0x0000'}),`
			);
		}
	}
	const ligatureWidth = Math.max(1, ...model.ligatures.map((item) => item.units.length));
	const ligatureRows = model.ligatures.map(
		(item) =>
			`    {${cVk(item.vk)}, ${item.column}, ${[...item.units.map((unit) => `0x${hex4(unit)}`), ...Array(ligatureWidth - item.units.length).fill('WCH_NONE')].join(', ')}},`
	);
	const ligatureEnd = `    {0, 0, ${Array(ligatureWidth).fill('0').join(', ')}}`;
	return fill(C_TEMPLATE, {
		BANNER: [...banner(context, '//'), ...omittedLines(model, '//')].join('\n'),
		NAME8: name8,
		LAYOUT: rows.join('\n'),
		DEAD_KEY_NAMES: deadNames.join('\n'),
		DEAD_KEYS: deadTrans.join('\n'),
		LIGATURE_TYPE: `LIGATURE${ligatureWidth}`,
		LIGATURES: [...ligatureRows, ligatureEnd].join('\n'),
		LIGATURE_TABLE:
			model.ligatures.length === 0
				? '0,\n    0,\n    NULL'
				: `${ligatureWidth},\n    sizeof(aLigature[0]),\n    (PLIGATURE1)aLigature`
	});
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
	lines.push(KLC_KEY_NAMES, '', 'KEYNAME_DEAD', '');
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

const KLC_KEY_NAMES = `KEYNAME

01\tEsc
0e\tBackspace
0f\tTab
1c\tEnter
1d\tCtrl
2a\tShift
36\t"Right Shift"
37\t"Num *"
38\tAlt
39\tSpace
3a\t"Caps Lock"
3b\tF1
3c\tF2
3d\tF3
3e\tF4
3f\tF5
40\tF6
41\tF7
42\tF8
43\tF9
44\tF10
45\tPause
46\t"Scroll Lock"
47\t"Num 7"
48\t"Num 8"
49\t"Num 9"
4a\t"Num -"
4b\t"Num 4"
4c\t"Num 5"
4d\t"Num 6"
4e\t"Num +"
4f\t"Num 1"
50\t"Num 2"
51\t"Num 3"
52\t"Num 0"
53\t"Num Del"
54\t"Sys Req"
57\tF11
58\tF12

KEYNAME_EXT

1c\t"Num Enter"
1d\t"Right Ctrl"
35\t"Num /"
37\t"Prnt Scrn"
38\t"Right Alt"
45\t"Num Lock"
46\tBreak
47\tHome
48\tUp
49\t"Page Up"
4b\tLeft
4d\tRight
4f\tEnd
50\tDown
51\t"Page Down"
52\tInsert
53\tDelete
54\t<00>
56\tHelp
5b\t"Left Windows"
5c\t"Right Windows"
5d\tApplication`;

// Kalamine's full.C template (MIT), with the ligature table this layout needs.
const C_TEMPLATE = `@BANNER@
//
// Tables of a Windows keyboard layout DLL, after kalamine's full.C template
// (https://github.com/OneDeadKey/kalamine, MIT licence).

#include <windows.h>
#include "kbd.h"
#include "@NAME8@.h"

#if defined(_M_IA64)
#pragma section(".data")
#define ALLOC_SECTION_LDATA __declspec(allocate(".data"))
#else
#pragma data_seg(".data")
#define ALLOC_SECTION_LDATA
#endif

/*
 * ausVK[] - Virtual Scan Code to Virtual Key conversion table
 */
static ALLOC_SECTION_LDATA USHORT ausVK[] = {
    T00, T01, T02, T03, T04, T05, T06, T07,
    T08, T09, T0A, T0B, T0C, T0D, T0E, T0F,
    T10, T11, T12, T13, T14, T15, T16, T17,
    T18, T19, T1A, T1B, T1C, T1D, T1E, T1F,
    T20, T21, T22, T23, T24, T25, T26, T27,
    T28, T29, T2A, T2B, T2C, T2D, T2E, T2F,
    T30, T31, T32, T33, T34, T35,

    /* Right-hand Shift key must have KBDEXT bit set. */
    T36 | KBDEXT,

    T37 | KBDMULTIVK,               // numpad_* + Shift/Alt -> SnapShot

    T38, T39, T3A, T3B, T3C, T3D, T3E,
    T3F, T40, T41, T42, T43, T44,

    /* NumLock: an extended key, VK_NUMLOCK or VK_PAUSE (without or with Ctrl). */
    T45 | KBDEXT | KBDMULTIVK,

    T46 | KBDMULTIVK,

    /* Number pad keys: digits and decimal point, special processing by Windows. */
    T47 | KBDNUMPAD | KBDSPECIAL,   // Numpad 7 (Home)
    T48 | KBDNUMPAD | KBDSPECIAL,   // Numpad 8 (Up)
    T49 | KBDNUMPAD | KBDSPECIAL,   // Numpad 9 (PgUp)
    T4A,
    T4B | KBDNUMPAD | KBDSPECIAL,   // Numpad 4 (Left)
    T4C | KBDNUMPAD | KBDSPECIAL,   // Numpad 5 (Clear)
    T4D | KBDNUMPAD | KBDSPECIAL,   // Numpad 6 (Right)
    T4E,
    T4F | KBDNUMPAD | KBDSPECIAL,   // Numpad 1 (End)
    T50 | KBDNUMPAD | KBDSPECIAL,   // Numpad 2 (Down)
    T51 | KBDNUMPAD | KBDSPECIAL,   // Numpad 3 (PgDn)
    T52 | KBDNUMPAD | KBDSPECIAL,   // Numpad 0 (Ins)
    T53 | KBDNUMPAD | KBDSPECIAL,   // Numpad . (Del)

    T54, T55, T56, T57, T58, T59, T5A, T5B,
    T5C, T5D, T5E, T5F, T60, T61, T62, T63,
    T64, T65, T66, T67, T68, T69, T6A, T6B,
    T6C, T6D, T6E, T6F, T70, T71, T72, T73,
    T74, T75, T76, T77, T78, T79, T7A, T7B,
    T7C, T7D, T7E
};

static ALLOC_SECTION_LDATA VSC_VK aE0VscToVk[] = {
    { 0x10, X10 | KBDEXT },  // Previous Track
    { 0x19, X19 | KBDEXT },  // Next Track
    { 0x1D, X1D | KBDEXT },  // RControl
    { 0x20, X20 | KBDEXT },  // Volume Mute
    { 0x21, X21 | KBDEXT },  // Launch App 2
    { 0x22, X22 | KBDEXT },  // Media Play/Pause
    { 0x24, X24 | KBDEXT },  // Media Stop
    { 0x2E, X2E | KBDEXT },  // Volume Down
    { 0x30, X30 | KBDEXT },  // Volume Up
    { 0x32, X32 | KBDEXT },  // Browser Home
    { 0x35, X35 | KBDEXT },  // Numpad Divide
    { 0x37, X37 | KBDEXT },  // Snapshot
    { 0x38, X38 | KBDEXT },  // RMenu
    { 0x47, X47 | KBDEXT },  // Home
    { 0x48, X48 | KBDEXT },  // Up
    { 0x49, X49 | KBDEXT },  // Prior
    { 0x4B, X4B | KBDEXT },  // Left
    { 0x4D, X4D | KBDEXT },  // Right
    { 0x4F, X4F | KBDEXT },  // End
    { 0x50, X50 | KBDEXT },  // Down
    { 0x51, X51 | KBDEXT },  // Next
    { 0x52, X52 | KBDEXT },  // Insert
    { 0x53, X53 | KBDEXT },  // Delete
    { 0x5B, X5B | KBDEXT },  // Left Win
    { 0x5C, X5C | KBDEXT },  // Right Win
    { 0x5D, X5D | KBDEXT },  // Application
    { 0x5F, X5F | KBDEXT },  // Sleep
    { 0x65, X65 | KBDEXT },  // Browser Search
    { 0x66, X66 | KBDEXT },  // Browser Favorites
    { 0x67, X67 | KBDEXT },  // Browser Refresh
    { 0x68, X68 | KBDEXT },  // Browser Stop
    { 0x69, X69 | KBDEXT },  // Browser Forward
    { 0x6A, X6A | KBDEXT },  // Browser Back
    { 0x6B, X6B | KBDEXT },  // Launch App 1
    { 0x6C, X6C | KBDEXT },  // Launch Mail
    { 0x6D, X6D | KBDEXT },  // Launch Media Selector
    { 0x1C, X1C | KBDEXT },  // Numpad Enter
    { 0x46, X46 | KBDEXT },  // Break (Ctrl + Pause)
    { 0,    0            }
};

static ALLOC_SECTION_LDATA VSC_VK aE1VscToVk[] = {
    { 0x1D, Y1D },  // Pause
    { 0,    0   }
};

/*
 * aVkToBits[] - map Virtual Keys to Modifier Bits
 */
static ALLOC_SECTION_LDATA VK_TO_BIT aVkToBits[] = {
    { VK_SHIFT,   KBDSHIFT },
    { VK_CONTROL, KBDCTRL  },
    { VK_MENU,    KBDALT   },
    { 0,          0        }
};

/*
 * CharModifiers - map character modifier bits to the column of the tables
 */
static ALLOC_SECTION_LDATA MODIFIERS CharModifiers = {
    &aVkToBits[0],
    7,
    {
        0,            // (none)
        1,            // Shift
        2,            // Control
        3,            // Shift + Control
        SHFT_INVALID, // Menu
        SHFT_INVALID, // Shift + Menu
        4,            // Control + Menu (AltGr)
        5             // Shift + Control + Menu (Shift + AltGr)
    }
};

static ALLOC_SECTION_LDATA VK_TO_WCHARS2 aVkToWch2[] = {
  {VK_TAB       ,0      ,'\\t'     ,'\\t'     },
  {VK_ADD       ,0      ,'+'      ,'+'      },
  {VK_DECIMAL   ,0      ,'.'      ,'.'      },
  {VK_DIVIDE    ,0      ,'/'      ,'/'      },
  {VK_MULTIPLY  ,0      ,'*'      ,'*'      },
  {VK_SUBTRACT  ,0      ,'-'      ,'-'      },
  {0            ,0      ,0        ,0        }
};

static ALLOC_SECTION_LDATA VK_TO_WCHARS3 aVkToWch3[] = {
  {VK_BACK      ,0      ,'\\b'     ,'\\b'     ,0x007f   },
  {VK_ESCAPE    ,0      ,0x001b   ,0x001b   ,0x001b   },
  {VK_RETURN    ,0      ,'\\r'     ,'\\r'     ,'\\n'     },
  {VK_CANCEL    ,0      ,0x0003   ,0x0003   ,0x0003   },
  {0            ,0      ,0        ,0        ,0        }
};

/*
 * aVkToWch6[] - the layout's keys: base, Shift, Ctrl, Shift + Ctrl, AltGr,
 * Shift + AltGr. A 0xff row holds the dead characters of the row above.
 */
static ALLOC_SECTION_LDATA VK_TO_WCHARS6 aVkToWch6[] = {
@LAYOUT@
  {0        ,0        ,0        ,0        ,0        ,0        ,0        ,0        }
};

// Last, so that VkKeyScan finds digits in the main section before the numpad.
static ALLOC_SECTION_LDATA VK_TO_WCHARS1 aVkToWch1[] = {
    { VK_NUMPAD0, 0, '0' },
    { VK_NUMPAD1, 0, '1' },
    { VK_NUMPAD2, 0, '2' },
    { VK_NUMPAD3, 0, '3' },
    { VK_NUMPAD4, 0, '4' },
    { VK_NUMPAD5, 0, '5' },
    { VK_NUMPAD6, 0, '6' },
    { VK_NUMPAD7, 0, '7' },
    { VK_NUMPAD8, 0, '8' },
    { VK_NUMPAD9, 0, '9' },
    { 0,          0, '\\0' }
};

static ALLOC_SECTION_LDATA VK_TO_WCHAR_TABLE aVkToWcharTable[] = {
    { (PVK_TO_WCHARS1)aVkToWch3, 3, sizeof(aVkToWch3[0]) },
    { (PVK_TO_WCHARS1)aVkToWch6, 6, sizeof(aVkToWch6[0]) },
    { (PVK_TO_WCHARS1)aVkToWch2, 2, sizeof(aVkToWch2[0]) },
    { (PVK_TO_WCHARS1)aVkToWch1, 1, sizeof(aVkToWch1[0]) },
    { NULL,                      0, 0                    }
};

static ALLOC_SECTION_LDATA VSC_LPWSTR aKeyNames[] = {
    0x01, L"Esc",
    0x0e, L"Backspace",
    0x0f, L"Tab",
    0x1c, L"Enter",
    0x1d, L"Ctrl",
    0x2a, L"Shift",
    0x36, L"Right Shift",
    0x37, L"Num *",
    0x38, L"Alt",
    0x39, L"Space",
    0x3a, L"Caps Lock",
    0x3b, L"F1",
    0x3c, L"F2",
    0x3d, L"F3",
    0x3e, L"F4",
    0x3f, L"F5",
    0x40, L"F6",
    0x41, L"F7",
    0x42, L"F8",
    0x43, L"F9",
    0x44, L"F10",
    0x45, L"Pause",
    0x46, L"Scroll Lock",
    0x47, L"Num 7",
    0x48, L"Num 8",
    0x49, L"Num 9",
    0x4a, L"Num -",
    0x4b, L"Num 4",
    0x4c, L"Num 5",
    0x4d, L"Num 6",
    0x4e, L"Num +",
    0x4f, L"Num 1",
    0x50, L"Num 2",
    0x51, L"Num 3",
    0x52, L"Num 0",
    0x53, L"Num Del",
    0x54, L"Sys Req",
    0x57, L"F11",
    0x58, L"F12",
    0x7c, L"F13",
    0x7d, L"F14",
    0x7e, L"F15",
    0x7f, L"F16",
    0x80, L"F17",
    0x81, L"F18",
    0x82, L"F19",
    0x83, L"F20",
    0x84, L"F21",
    0x85, L"F22",
    0x86, L"F23",
    0x87, L"F24",
    0,    NULL
};

static ALLOC_SECTION_LDATA VSC_LPWSTR aKeyNamesExt[] = {
    0x1c, L"Num Enter",
    0x1d, L"Right Ctrl",
    0x35, L"Num /",
    0x37, L"Prnt Scrn",
    0x38, L"Right Alt",
    0x45, L"Num Lock",
    0x46, L"Break",
    0x47, L"Home",
    0x48, L"Up",
    0x49, L"Page Up",
    0x4b, L"Left",
    0x4d, L"Right",
    0x4f, L"End",
    0x50, L"Down",
    0x51, L"Page Down",
    0x52, L"Insert",
    0x53, L"Delete",
    0x54, L"<00>",
    0x56, L"Help",
    0x5b, L"Left Windows",
    0x5c, L"Right Windows",
    0x5d, L"Application",
    0,    NULL
};

static ALLOC_SECTION_LDATA DEADKEY_LPWSTR aKeyNamesDead[] = {
@DEAD_KEY_NAMES@
    NULL
};

static ALLOC_SECTION_LDATA DEADKEY aDeadKey[] = {
@DEAD_KEYS@
    0, 0, 0
};

static ALLOC_SECTION_LDATA @LIGATURE_TYPE@ aLigature[] = {
@LIGATURES@
};

static ALLOC_SECTION_LDATA KBDTABLES KbdTables = {
    /* Modifier keys */
    &CharModifiers,

    /* Characters tables */
    aVkToWcharTable,

    /* Diacritics */
    aDeadKey,

    /* Names of keys */
    aKeyNames,
    aKeyNamesExt,
    aKeyNamesDead,

    /* Scan codes to virtual keys */
    ausVK,
    sizeof(ausVK) / sizeof(ausVK[0]),
    aE0VscToVk,
    aE1VscToVk,

    /* Locale-specific special processing */
    MAKELONG(KLLF_ALTGR, KBD_VERSION),

    /* Ligatures */
    @LIGATURE_TABLE@
};

PKBDTABLES KbdLayerDescriptor(VOID)
{
    return &KbdTables;
}
`;

module.exports = {
	COLUMNS,
	buildModel,
	generate,
	encodeKlc,
	keyMapIndex,
	indexLayout,
	resolveCell
};
