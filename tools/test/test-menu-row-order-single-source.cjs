// tools/test/test-menu-row-order-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Menu Row Order Single-Source Gate
 * DESCRIPTION:
 * The display-order rules of the menus live once, in
 * _shared/modules/menu/row_order.json, and reach the Lua drivers through the
 * generated menu.row_order_data. This gate refuses a second copy of any rule in
 * a driver or in shared Lua, whether spelled as an ordered list of names or as a
 * name -> position table.
 *
 * FEATURES & RATIONALE:
 * 1. Copy detection: four consecutive entries of a rule (the whole rule when shorter), in rule order, spelled
 *    as quoted list items or as `name = position` pairs, are a hard-coded order.
 * 2. Rows pinned to the manifest: the llm_menu_rows rule, which a native menu
 *    uses when the manifest cannot be read, must equal the manifest's own rows
 *    for the macOS driver, so the data cannot drift from the order it mirrors.
 * 3. The detector is mutation-tested on candidate text, so it cannot go blind.
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
	path.join(SHARED, 'lua')
];

const data = JSON.parse(
	fs.readFileSync(path.join(SHARED, 'modules', 'menu', 'row_order.json'), 'utf8')
);

/** Escapes a name for a regular expression. */
function escaped(text) {
	return text.replace(/[.*+?^${}()[\]\\]/g, '\\$&');
}

/**
 * Finds the rules a Lua text spells out in order.
 * @param {string} text Lua source.
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
			if (asList.test(text) || asRanks.test(text))
				found.push(`${name}: ${order.slice(start, start + width).join(', ')}`);
		}
	}
	return found;
}

/** Every Lua file a driver or the shared Lua ships, tests and generated data aside. */
function* luaFiles(directory) {
	for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
		const full = path.join(directory, entry.name);
		if (entry.isDirectory()) {
			if (['tests', 'test', '_generated', 'node_modules', 'fixtures'].includes(entry.name))
				continue;
			yield* luaFiles(full);
		} else if (entry.name.endsWith('.lua') && entry.name !== 'row_order_data.lua') yield full;
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
assert.equal(
	hardCodedOrders('local O = { "alpha", "beta", "gamma" }', data.rules).length,
	0,
	'unrelated'
);

for (const root of SCANNED) {
	for (const file of luaFiles(root)) {
		const found = hardCodedOrders(fs.readFileSync(file, 'utf8'), data.rules);
		assert.deepEqual(
			found,
			[],
			`${path.relative(ROOT, file)} spells a menu order of row_order.json: read menu.row_order instead`
		);
	}
}

const manifest = JSON.parse(
	fs.readFileSync(path.join(SHARED, 'modules', 'menu', 'menu_manifest.json'), 'utf8')
);
const macosRows = manifest.llm_menu
	.filter(
		(row) =>
			typeof row.id === 'string' &&
			row.id !== '' &&
			(row.type === 'dynamic' || row.type === 'group') &&
			(row.platforms === undefined || row.platforms.includes('hs'))
	)
	.map((row) => row.id);
assert.deepEqual(
	data.rules.llm_menu_rows.order,
	macosRows,
	'llm_menu_rows must list the macOS rows of menu_manifest.json llm_menu in manifest order'
);

console.log(
	`PASS menu row order single source: ${Object.keys(data.rules).length} rules, no driver copy, llm rows match the manifest`
);
