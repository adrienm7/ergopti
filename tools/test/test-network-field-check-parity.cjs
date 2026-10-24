// tools/test/test-network-field-check-parity.cjs

/**
 * ==============================================================================
 * MODULE: Network Field Check Parity
 * DESCRIPTION:
 * The Debug menu's « Test network (PAC, proxy, download) » exists on every
 * driver: macOS and Linux run the shared Lua steps
 * (_shared/lua/network/field_check_network.lua), Windows runs the same steps in
 * AutoHotkey (windows/ui/field_check/network_check.ahk). This gate pins what
 * keeps the three reports comparable when a maintainer pastes one back:
 * 1. the Lua and AutoHotkey step lists are the same identities in the same order;
 * 2. every step has its label in every locale;
 * 3. the menu row is declared once, for every platform, with no platform reason,
 *    and each driver routes it to its check;
 * 4. no driver spells a URL into the evidence: the check files carry no
 *    literal address except the documented Atom feed template.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..', '..');
const sp = path.join(root, 'static', 'ergopti_plus');
const read = (...parts) => fs.readFileSync(path.join(sp, ...parts), 'utf8');

let passed = 0;
const check = (label, action) => {
	try {
		action();
	} catch (error) {
		error.message = `${label}: ${error.message}`;
		throw error;
	}
	passed++;
};

const luaSource = read('_shared', 'lua', 'network', 'field_check_network.lua');
const ahkSource = read('windows', 'ui', 'field_check', 'network_check.ahk');

/** The quoted identities of a Lua `{ "a", "b" }` or AutoHotkey `["a", "b"]` list. */
const identities = (list) => [...list.matchAll(/"([a-z_]+)"/g)].map((match) => match[1]);

const luaSteps = identities(/M\.STEP_IDS = \{([^}]*)\}/.exec(luaSource)?.[1] ?? '');
const ahkSteps = identities(/NETWORK_CHECK_STEPS := \[([^\]]*)\]/.exec(ahkSource)?.[1] ?? '');

check('the Lua step list is declared', () => {
	assert.ok(luaSteps.length >= 7, `only ${luaSteps.length} step(s) found in the Lua definition`);
});

check('Windows reports the same steps in the same order as macOS and Linux', () => {
	assert.deepEqual(ahkSteps, luaSteps);
});

check('the Lua chain steps are a suffix of the full list', () => {
	const chain = identities(/M\.CHAIN_STEPS = \{([^}]*)\}/.exec(luaSource)?.[1] ?? '');
	assert.deepEqual(luaSteps.slice(luaSteps.length - chain.length), chain);
});

check('every step has a label in every locale', () => {
	const dir = path.join(sp, '_shared', 'data', 'locales');
	const locales = fs.readdirSync(dir).filter((file) => file.endsWith('.json'));
	assert.equal(locales.length, 21);
	for (const file of locales) {
		const strings = JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8'));
		for (const id of [...luaSteps, 'internal_error']) {
			const key = `field_check.step.${id}`;
			assert.equal(typeof strings[key], 'string', `${file} misses ${key}`);
			assert.notEqual(strings[key], '', `${file} has an empty ${key}`);
		}
		assert.equal(
			typeof strings['menu.debug.field_check_network'],
			'string',
			`${file} misses the row label`
		);
	}
});

check('the menu row is declared once, for every platform, without a platform reason', () => {
	const manifest = JSON.parse(read('_shared', 'modules', 'menu', 'menu_manifest.json'));
	const rows = [];
	(function walk(node) {
		if (Array.isArray(node)) node.forEach(walk);
		else if (node && typeof node === 'object') {
			if (node.id === 'field_check_network') rows.push(node);
			Object.values(node).forEach(walk);
		}
	})(manifest);
	assert.equal(rows.length, 1, `the row is declared ${rows.length} time(s)`);
	assert.equal(rows[0].platforms, undefined, 'the row is limited to some platforms');
	assert.equal(rows[0].reason_key, undefined, 'a row for every platform needs no platform reason');
	assert.equal(rows[0].i18n, 'menu.debug.field_check_network');
});

check('each driver routes the row to its check', () => {
	assert.match(
		read('macos', 'ui', 'field_check', 'init.lua'),
		/field_check_network = \{ check = "network"/
	);
	assert.match(
		read('windows', 'ui', 'menu', 'menu_init.ahk'),
		/"field_check_network", NetworkCheck_Command/
	);
	assert.match(
		read('linux', 'ui', 'menu', 'menu_builder.lua'),
		/\["field_check_network"\] = function\(\) require\("ui\.network_check"\)\.run\(\) end/
	);
});

check('the Windows file is included by the driver and by the suite', () => {
	assert.match(
		read('windows', 'ErgoptiPlus.ahk'),
		/^#Include ui\/field_check\/network_check\.ahk$/m
	);
	assert.match(
		read('windows', 'tests', 'run_all.ahk'),
		/^#Include \.\.\/ui\/field_check\/network_check\.ahk$/m
	);
	assert.match(
		read('windows', 'tests', 'run_all.ahk'),
		/^#Include unit\/ui\/field_check\/test_network_check\.ahk$/m
	);
});

check('the check files spell no address of their own', () => {
	const files = [
		luaSource,
		ahkSource,
		read('linux', 'adapters', 'network_check_ports.lua'),
		read('linux', 'ui', 'network_check.lua')
	];
	for (const source of files) {
		const addresses = source.match(/https?:\/\/[^\s"')]+/g) ?? [];
		assert.deepEqual(
			addresses,
			[],
			`an address is spelled in a check file: ${addresses.join(', ')}`
		);
	}
});

console.log(`[OK] network field check parity: ${passed} check(s)`);
