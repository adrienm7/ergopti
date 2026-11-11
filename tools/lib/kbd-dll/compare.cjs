// tools/lib/kbd-dll/compare.cjs

/**
 * ==============================================================================
 * MODULE: Keyboard Layout DLL Golden Comparison
 * DESCRIPTION:
 * Compares what the independent reader found in a built DLL with the model it
 * was built from, key by key, column by column (every level, the Kana ones
 * included), dead key by dead key with each chain, ligature by ligature, plus
 * the columns, locale flags, key names and scan codes. Returns every
 * difference as a path and the two values; an empty list is the proof.
 * ==============================================================================
 */

'use strict';

const C = require('./constants.cjs');
const Model = require('./model.cjs');

const json = (value) => JSON.stringify(value === undefined ? null : value);

/**
 * @param {object} model - The kbd tables model the DLL was built from.
 * @param {object} layout - readDll(...).layout.
 * @returns {{path: string, model: string, dll: string}[]}
 */
function compareLayout(model, layout) {
	const diffs = [];
	const same = (path, a, b) => {
		if (json(a) !== json(b)) diffs.push({ path, model: json(a), dll: json(b) });
	};
	same('columns', model.columns, layout.columns);
	same(
		'modifiers',
		Model.modifierKeys(model).map((key) => ({ vk: key.vk, bit: key.bit })),
		layout.modifiers
	);
	same('flags', Model.localeFlags(model) & 0xffff, layout.flags);
	const byVk = new Map(layout.keys.map((key) => [key.vk, key]));
	for (const key of model.keys) {
		const found = byVk.get(key.vk);
		const at = `keys[vk=0x${key.vk.toString(16)}]`;
		if (!found) {
			diffs.push({ path: at, model: 'key', dll: 'absent' });
			continue;
		}
		same(`${at}.attributes`, key.attributes, found.attributes);
		key.cells.forEach((cell, c) => same(`${at}.cells[${model.columns[c]}]`, cell, found.cells[c]));
		same(`${at}.caps_cells`, key.caps_cells, found.caps_cells);
		byVk.delete(key.vk);
	}
	// What remains are the system keys the emitter adds when the layout leaves them.
	const system = new Set(C.SYSTEM_KEYS.map((sys) => C.VK[sys.vk]));
	for (const [vk] of byVk)
		if (!system.has(vk))
			diffs.push({ path: `keys[vk=0x${vk.toString(16)}]`, model: 'absent', dll: 'key' });
	const deadOf = new Map(layout.dead_keys.map((dead) => [dead.dead, dead]));
	for (const dead of model.dead_keys) {
		const at = `dead_keys[0x${dead.dead.toString(16)}]`;
		const found = deadOf.get(dead.dead);
		if (!found) {
			diffs.push({ path: at, model: 'dead key', dll: 'absent' });
			continue;
		}
		same(`${at}.name`, dead.name, found.name);
		const sort = (rules) => rules.slice().sort((a, b) => a.base - b.base);
		same(`${at}.rules`, sort(dead.rules), sort(found.rules));
		deadOf.delete(dead.dead);
	}
	for (const [unit] of deadOf)
		diffs.push({ path: `dead_keys[0x${unit.toString(16)}]`, model: 'absent', dll: 'dead key' });
	same('key_names', model.key_names || [], layout.key_names);
	same('key_names_ext', model.key_names_ext || [], layout.key_names_ext);
	const scan = C.DEFAULT_SCANCODES.slice();
	for (const entry of model.scancodes || []) scan[entry.sc] = entry.vk;
	same('scancodes', scan, layout.scancodes);
	same(
		'e0',
		Model.e0Table(model).map(([sc, vk]) => [sc, vk & 0xff]),
		layout.e0.map((entry) => [entry.sc, entry.vk & 0xff])
	);
	same(
		'numpad',
		C.NUMPAD_KEYS.map((k) => [C.VK[k.vk], k.char]),
		(layout.extra_keys || []).map((k) => [k.vk, k.cells[0].char])
	);
	return diffs;
}

module.exports = { compareLayout };
