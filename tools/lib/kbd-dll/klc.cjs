// tools/lib/kbd-dll/klc.cjs

/**
 * ==============================================================================
 * MODULE: KLC Reader
 * DESCRIPTION:
 * Reads a Microsoft Keyboard Layout Creator source file (.klc) into the kbd
 * tables model (model.cjs): KBD, COPYRIGHT, COMPANY, LOCALENAME, LOCALEID,
 * VERSION, ATTRIBUTES, SHIFTSTATE, LAYOUT (hex, literal, -1, %% and @ cells,
 * the Cap column and SGCap rows), LIGATURE, DEADKEY, KEYNAME, KEYNAME_EXT,
 * KEYNAME_DEAD, DESCRIPTIONS and LANGUAGENAMES, from UTF-16LE (with its byte
 * order mark, as MSKLC writes it) or UTF-8.
 *
 * FEATURES & RATIONALE:
 * 1. Written from the KLC format as MSKLC documents and writes it; anything
 *    the reader does not know refuses the file with its line, never skipped.
 * 2. KLLF_ALTGR follows MSKLC: set when a column is Ctrl+Alt (6), unless an
 *    ATTRIBUTES section states the flags itself.
 * 3. A DEADKEY result written with an « @ » enters another dead key (DKF_DEAD),
 *    the chaining the KLC files of KbdEdit-era tools carry; plain KLCs have none.
 * ==============================================================================
 */

'use strict';

const C = require('./constants.cjs');
const Model = require('./model.cjs');

const SECTIONS = new Set([
	'KBD',
	'COPYRIGHT',
	'COMPANY',
	'LOCALENAME',
	'LOCALEID',
	'VERSION',
	'ATTRIBUTES',
	'SHIFTSTATE',
	'LAYOUT',
	'LIGATURE',
	'DEADKEY',
	'KEYNAME',
	'KEYNAME_EXT',
	'KEYNAME_DEAD',
	'DESCRIPTIONS',
	'LANGUAGENAMES',
	'ENDKBD'
]);

/** A refused KLC line. */
class KlcError extends Error {
	constructor(reason, line) {
		super(`klc ${reason} (line ${line})`);
		this.name = 'KlcError';
		this.code = 'klc_invalid';
		this.reason = reason;
		this.line = line;
	}
}

/** Decodes the file bytes: UTF-16LE with a BOM, else strict UTF-8 (BOM allowed). */
function decode(bytes) {
	if (typeof bytes === 'string') return bytes.replace(/^﻿/, '');
	const view = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
	if (view[0] === 0xff && view[1] === 0xfe)
		return new TextDecoder('utf-16le', { fatal: true }).decode(view.subarray(2));
	return new TextDecoder('utf-8', { fatal: true }).decode(view).replace(/^﻿/, '');
}

/** Strips a // comment that starts a field (a literal « / » cell is kept). */
function stripComment(line) {
	const match = /(^|\s)\/\//.exec(line);
	return (match ? line.slice(0, match.index) : line).trim();
}

/** Splits fields, keeping a double-quoted value whole. */
function fields(line) {
	const out = [];
	const re = /"([^"]*)"|(\S+)/g;
	let m;
	while ((m = re.exec(line))) out.push(m[1] !== undefined ? m[1] : m[2]);
	return out;
}

/** A virtual-key name of the LAYOUT column (« A », « 1 », « OEM_1 », « SPACE »). */
function vkOf(name, line) {
	if (!Object.hasOwn(C.VK, name)) throw new KlcError(`unknown virtual key ${name}`, line);
	return C.VK[name];
}

/** One hexadecimal code unit (4 digits, as the KLC writes characters). */
function hexUnit(text, line) {
	if (!/^[0-9a-fA-F]{4}$/.test(text)) throw new KlcError(`not a code unit: ${text}`, line);
	return parseInt(text, 16);
}

/** One LAYOUT cell: -1, %%, a 4-digit hex unit or a one-unit literal, « @ » for dead. */
function cellOf(token, line) {
	if (token === '-1') return null;
	if (token === '%%') return { ligature: null };
	const dead = token.length > 1 && token.endsWith('@');
	const body = dead ? token.slice(0, -1) : token;
	let unit;
	if (/^[0-9a-fA-F]{4}$/.test(body)) unit = parseInt(body, 16);
	else if (body.length === 1) unit = body.charCodeAt(0);
	else throw new KlcError(`unreadable cell ${token}`, line);
	return dead ? { dead: unit } : { char: unit };
}

/**
 * Reads a KLC into the kbd tables model.
 * @param {Uint8Array|string} bytes - The file, UTF-16LE (BOM) or UTF-8.
 * @param {{dll_name?: string}} [options] - Overrides the KBD name.
 * @returns {object} A checked model.
 */
function fromKlc(bytes, options = {}) {
	const lines = decode(bytes).split(/\r?\n/);
	const model = {
		format: Model.FORMAT,
		version: Model.VERSION,
		dll_name: '',
		layout_text: '',
		locale_name: '',
		lcid: '',
		version_string: '1.0',
		copyright: '',
		company: '',
		flags: [],
		columns: [],
		scancodes: [],
		keys: [],
		dead_keys: [],
		key_names: [],
		key_names_ext: [],
		descriptions: [],
		language_names: []
	};
	let attributes = null;
	let section = null;
	let dead = null;
	let sgFor = null;
	const ligatures = [];
	let ended = false;
	lines.forEach((raw, index) => {
		const number = index + 1;
		const line = stripComment(raw);
		if (line === '' || ended) return;
		const parts = fields(line);
		const head = parts[0];
		if (SECTIONS.has(head)) {
			section = head;
			dead = null;
			if (head === 'KBD') {
				model.dll_name = parts[1];
				model.layout_text = parts[2] || '';
			} else if (head === 'COPYRIGHT') model.copyright = parts[1] || '';
			else if (head === 'COMPANY') model.company = parts[1] || '';
			else if (head === 'LOCALENAME') model.locale_name = parts[1] || '';
			else if (head === 'LOCALEID') {
				if (!/^0000[0-9a-fA-F]{4}$/.test(parts[1] || ''))
					throw new KlcError('LOCALEID is not 0000xxxx', number);
				model.lcid = parts[1].slice(4).toLowerCase();
			} else if (head === 'VERSION') model.version_string = parts[1] || '1.0';
			else if (head === 'ATTRIBUTES') attributes = [];
			else if (head === 'DEADKEY') {
				dead = { dead: hexUnit(parts[1], number), rules: [] };
				model.dead_keys.push(dead);
			} else if (head === 'ENDKBD') ended = true;
			return;
		}
		switch (section) {
			case 'ATTRIBUTES': {
				const flag = head.toLowerCase();
				if (!Object.hasOwn(C.LOCALE_FLAGS, flag))
					throw new KlcError(`unknown attribute ${head}`, number);
				attributes.push(flag);
				return;
			}
			case 'SHIFTSTATE': {
				if (!/^\d+$/.test(head)) throw new KlcError(`shift state ${head}`, number);
				model.columns.push(Number(head));
				return;
			}
			case 'LAYOUT': {
				if (sgFor && head === '-1' && parts[1] === '-1') {
					// The SGCap row: the Caps Lock characters of the key above.
					sgFor.caps_cells = parts.slice(2).map((t) => cellOf(t, number));
					while (sgFor.caps_cells.length < model.columns.length) sgFor.caps_cells.push(null);
					sgFor = null;
					return;
				}
				const sc = parseInt(head, 16);
				if (!/^[0-9a-fA-F]{1,2}$/.test(head)) throw new KlcError(`scan code ${head}`, number);
				const vk = vkOf(parts[1], number);
				const cap = parts[2];
				let attr;
				if (cap === 'SGCap') attr = C.ATTRIBUTES.sgcaps;
				else if (/^\d+$/.test(cap)) attr = Number(cap);
				else throw new KlcError(`Cap column ${cap}`, number);
				const cells = parts.slice(3).map((t) => cellOf(t, number));
				if (cells.length > model.columns.length)
					throw new KlcError('more cells than shift states', number);
				while (cells.length < model.columns.length) cells.push(null);
				const key = { vk, attributes: attr, cells, sc };
				model.keys.push(key);
				sgFor = cap === 'SGCap' ? key : null;
				return;
			}
			case 'LIGATURE': {
				const vk = vkOf(head, number);
				const column = Number(parts[1]);
				if (!Number.isInteger(column)) throw new KlcError('ligature column', number);
				ligatures.push({
					vk,
					column,
					units: parts.slice(2).map((t) => hexUnit(t, number)),
					line: number
				});
				return;
			}
			case 'DEADKEY': {
				if (!dead) throw new KlcError('rule outside a DEADKEY', number);
				const chained = parts[1] && parts[1].endsWith('@');
				const rule = {
					base: hexUnit(head, number),
					result: hexUnit(chained ? parts[1].slice(0, -1) : parts[1], number)
				};
				if (chained) rule.dead = true;
				dead.rules.push(rule);
				return;
			}
			case 'KEYNAME':
			case 'KEYNAME_EXT': {
				const list = section === 'KEYNAME' ? model.key_names : model.key_names_ext;
				list.push({ sc: parseInt(head, 16), name: parts.slice(1).join(' ') });
				return;
			}
			case 'KEYNAME_DEAD': {
				const unit = hexUnit(head, number);
				const entry = model.dead_keys.find((d) => d.dead === unit);
				if (!entry) throw new KlcError(`name of an undeclared dead key ${head}`, number);
				entry.name = parts.slice(1).join(' ');
				return;
			}
			case 'DESCRIPTIONS':
			case 'LANGUAGENAMES': {
				const list = section === 'DESCRIPTIONS' ? model.descriptions : model.language_names;
				list.push({ lang: head.toLowerCase(), text: parts.slice(1).join(' ') });
				return;
			}
			default:
				throw new KlcError(`line outside a known section: ${head}`, number);
		}
	});
	if (!ended) throw new KlcError('no ENDKBD', lines.length);
	for (const lig of ligatures) {
		const key = model.keys.find((k) => k.vk === lig.vk);
		if (!key || !key.cells[lig.column] || key.cells[lig.column].ligature !== null)
			throw new KlcError('LIGATURE without a %% cell', lig.line);
		key.cells[lig.column] = { ligature: lig.units };
	}
	model.keys.forEach((key) => {
		key.cells.forEach((cell) => {
			if (cell && cell.ligature === null) throw new KlcError(`%% cell without a LIGATURE row`, 0);
		});
	});
	// The LAYOUT section moves character keys between scan codes.
	model.scancodes = model.keys
		// A keypad scan code keeps its navigation key: Num Lock turns it into the
		// LAYOUT's VK_DECIMAL or VK_NUMPADn (KBDNUMPAD), it is never reassigned.
		.filter((key) => !(C.DEFAULT_SCANCODES[key.sc] & C.SC_FLAGS.NUMPAD))
		.filter((key) => (C.DEFAULT_SCANCODES[key.sc] & 0xff) !== key.vk)
		.map((key) => ({ sc: key.sc, vk: key.vk }));
	model.keys.forEach((key) => delete key.sc);
	if (options.dll_name) model.dll_name = options.dll_name;
	model.flags = attributes !== null ? attributes : model.columns.includes(6) ? ['altgr'] : [];
	return Model.check(model);
}

module.exports = { fromKlc, decode, KlcError };
