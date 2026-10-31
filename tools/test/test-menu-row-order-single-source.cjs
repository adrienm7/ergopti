// tools/test/test-menu-row-order-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Menu Row Order Single-Source Gate
 * DESCRIPTION:
 * The display-order rules of the menus live once, in
 * _shared/modules/menu/row_order.json, and reach the Lua drivers through the
 * generated menu.row_order_data. Windows reads the same rules through
 * windows/_generated/menu_row_order.ahk. This gate refuses a second copy of any
 * rule in a driver or in shared Lua, whether spelled as an ordered list of names
 * or as a name -> position table.
 *
 * FEATURES & RATIONALE:
 * 1. Copy detection: four consecutive entries of a rule (the whole rule when shorter), in rule order, spelled
 *    as quoted list items, as `name = position` pairs or as AutoHotkey
 *    `"name", position` Map arguments, are a hard-coded order.
 * 2. The detector is mutation-tested on candidate text, so it cannot go blind.
 * 3. Windows is pinned twice: its generated table must equal the JSON rule by
 *    rule, and the reader must keep loading that table.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const WINDOW = 4;
const SCANNED = [
	path.join(ROOT, 'static', 'ergopti_plus', 'macos'),
	path.join(ROOT, 'static', 'ergopti_plus', 'linux'),
	path.join(ROOT, 'static', 'ergopti_plus', 'windows'),
	path.join(SHARED, 'lua'),
	path.join(SHARED, 'modules')
];
const WINDOWS_TABLE = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'windows',
	'_generated',
	'menu_row_order.ahk'
);
const WINDOWS_READER = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'windows',
	'infra',
	'menu_row_order.ahk'
);

const data = JSON.parse(
	fs.readFileSync(path.join(SHARED, 'modules', 'menu', 'row_order.json'), 'utf8')
);

/** Escapes a name for a regular expression. */
function escaped(text) {
	return text.replace(/[.*+?^${}()[\]\\]/g, '\\$&');
}

/**
 * Finds the rules a driver text spells out in order.
 * @param {string} text Lua or AutoHotkey source.
 * @param {Record<string, {order: string[]}>} rules The rules of row_order.json.
 * @returns {string[]} Descriptions of every hard-coded window found.
 */
function hardCodedOrders(text, rules) {
	const found = [];
	for (const [name, { order }] of Object.entries(rules)) {
		const width = Math.min(WINDOW, order.length);
		for (let start = 0; start + width <= order.length; start += 1) {
			const slice = order.slice(start, start + width).map(escaped);
			const asList = new RegExp(slice.map((item) => `"${item}"`).join('\\s*,\\s*'));
			const asRanks = new RegExp(
				slice.map((item) => `(?:\\["${item}"\\]|${item})\\s*=\\s*\\d+`).join('\\s*,\\s*')
			);
			const asMapRanks = new RegExp(
				slice.map((item) => `"${item}"\\s*,\\s*\\d+`).join('\\s*,\\s*')
			);
			if (asList.test(text) || asRanks.test(text) || asMapRanks.test(text))
				found.push(`${name}: ${order.slice(start, start + width).join(', ')}`);
		}
	}
	return found;
}

/** Every Lua or AutoHotkey file a driver or shared ships, tests and generated data aside. */
function* driverFiles(directory) {
	for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
		const full = path.join(directory, entry.name);
		if (entry.isDirectory()) {
			if (['tests', 'test', '_generated', 'node_modules', 'fixtures'].includes(entry.name))
				continue;
			yield* driverFiles(full);
		} else if (/\.(?:lua|ahk)$/.test(entry.name) && entry.name !== 'row_order_data.lua') yield full;
	}
}

// The detector sees a copy, in both spellings, and ignores an unrelated list.
const sample = data.rules.menu_chord_modifiers.order;
assert(
	hardCodedOrders(`local O = { "${sample.join('", "')}" }`, data.rules).length > 0,
	'list copy'
);
assert(
	hardCodedOrders(
		`local O = { ${sample.map((item, i) => `${item} = ${i + 1}`).join(', ')} }`,
		data.rules
	).length > 0,
	'rank table copy'
);
assert(
	hardCodedOrders(
		`O := Map(${sample.map((item, i) => `"${item}", ${i + 1}`).join(', ')})`,
		data.rules
	).length > 0,
	'AutoHotkey rank Map copy'
);
assert(
	hardCodedOrders(
		'global Cats := [\n\t"magickey", "autocorrection", "rolls",\n\t"sfbsreduction", "distancesreduction"\n]',
		data.rules
	).length > 0,
	'the multi-line AutoHotkey array the configuration window used to hold'
);
assert.equal(
	hardCodedOrders('local O = { "alpha", "beta", "gamma" }', data.rules).length,
	0,
	'unrelated'
);

let scanned = { lua: 0, ahk: 0 };
for (const root of SCANNED) {
	for (const file of driverFiles(root)) {
		scanned[file.endsWith('.ahk') ? 'ahk' : 'lua'] += 1;
		const found = hardCodedOrders(fs.readFileSync(file, 'utf8'), data.rules);
		assert.deepEqual(
			found,
			[],
			`${path.relative(ROOT, file)} spells a menu order of row_order.json: read menu.row_order (MenuRowOrderList on Windows) instead`
		);
	}
}
assert(scanned.lua > 100 && scanned.ahk > 100, `the scan went blind: ${JSON.stringify(scanned)}`);

// The Windows projection equals the JSON, rule by rule, and the reader loads it.
const table = fs.readFileSync(WINDOWS_TABLE, 'utf8');
const entries = [...table.matchAll(/^\t("[^"]+"), (\[.*\]),?$/gmu)].map((match) => [
	JSON.parse(match[1]),
	JSON.parse(match[2])
]);
assert.deepEqual(
	Object.fromEntries(entries),
	Object.fromEntries(Object.entries(data.rules).map(([name, rule]) => [name, rule.order])),
	'windows/_generated/menu_row_order.ahk must project row_order.json: run the codegen'
);
assert(
	fs.readFileSync(WINDOWS_READER, 'utf8').includes('#Include ../_generated/menu_row_order.ahk'),
	'infra/menu_row_order.ahk must load the generated table'
);

console.log(
	`PASS menu row order single source: ${Object.keys(data.rules).length} rules, no driver copy`
);
