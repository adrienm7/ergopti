// tools/test/test-app-switch-labels.cjs

/**
 * ==============================================================================
 * MODULE: App and Window Switching Labels Gate (app-switch-labels)
 * DESCRIPTION:
 * The action picker offered « App préc. » and « App précédente » side by side,
 * and « Fenêtre préc. » next to « Fenêtre préc. (toutes apps) », with nothing
 * saying which switched what where. This gate holds three things:
 *   1. In every locale, no two actions a driver offers share a label.
 *   2. Every switching action's label says what it switches (an application
 *      or a window) and where (this screen, every screen, the active app...).
 *   3. The ids macOS stopped offering are migrated: config migration step
 *      v5_to_v6 maps each one to the action that does the same thing, in every
 *      key of config.toml it lists, and those keys are the whole enumerable
 *      action slot space of macOS (gesture slots, tap keys, script control),
 *      each named as it was at v6: a later rename step leads back to it, and
 *      a key macOS gained after v6 (INTRODUCED_AFTER_V6) held no retired id.
 * In-memory mutations prove each check can fail.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');

const SP = path.resolve(__dirname, '../../static/ergopti_plus');
const read = (file) => fs.readFileSync(path.join(SP, file), 'utf8').replace(/^﻿/, '');
const PLATFORMS = ['ahk', 'hs', 'linux'];

// Action keys macOS gained after config schema v6, so no v5 id can be in them:
// the Delete script chord came with the shared chords of v6_to_v7.
const INTRODUCED_AFTER_V6 = new Set(['shortcuts.script_control.script_altgr_delete']);

// What each switching action switches and where, in the English label.
const SWITCHING = {
	app_previous: /\bapp\b.*\ball screens\b/,
	app_previous_screen: /\bapp\b.*\bthis screen\b/,
	cmd_shift_tab: /\bapp\b.*\ball screens\b/,
	alt_tab_windows: /\bwindow\b.*\ball screens\b/,
	alt_tab_monitor: /\bwindow\b.*\bthis screen\b/,
	win_prev: /\bwindow\b.*\ball apps\b/,
	win_next: /\bwindow\b.*\ball apps\b/,
	win_app_prev: /\bwindow\b.*\bactive app\b/,
	win_app_next: /\bwindow\b.*\bactive app\b/,
	app_window_previous: /\bwindow\b.*\bno switcher\b/,
	// The operating system's own keystroke: what it switches is the OS's choice.
	app_switcher: /\bSystem Alt\+Tab\b/
};

// The ids macOS stopped offering, and the action each one became.
const MERGED = {
	app_switcher: 'app_previous',
	alt_tab_apps: 'app_previous',
	app_window_previous: 'win_app_next',
	cycle_windows_in_app: 'win_app_next',
	win_prev: 'win_app_prev',
	win_next: 'win_app_next'
};

/**
 * @param {string} platform Catalogue platform field.
 * @returns {string[]} The drivers it names.
 */
function platformsOf(platform) {
	return platform === 'all' ? PLATFORMS : String(platform || '').split(',');
}

/**
 * Checks labels, switching descriptions and the migration.
 * @param {object} input Parsed catalogue, locales, manifest keys and registry.
 * @returns {{errors: string[], checks: number}} Violations and check count.
 */
function validate(input) {
	const errors = [];
	let checks = 0;
	const check = (ok, message) => {
		checks += 1;
		if (!ok) errors.push(message);
	};
	const rows = input.catalogue.sg_actions;
	const offered = (platform) =>
		Object.keys(rows).filter(
			(id) => !rows[id].is_header && platformsOf(rows[id].platform).includes(platform)
		);

	// 1. Unique labels per driver and locale.
	check(Object.keys(input.locales).length === 21, 'inventory: 21 locales expected');
	for (const platform of PLATFORMS) {
		for (const [locale, strings] of Object.entries(input.locales)) {
			const byLabel = new Map();
			for (const id of offered(platform)) {
				const label = strings[`sg_actions.${id}`];
				if (label === undefined) continue;
				check(
					!byLabel.has(label),
					`unique: ${platform} ${locale} labels ${byLabel.get(label)} and ${id} "${label}"`
				);
				byLabel.set(label, id);
			}
		}
	}

	// 2. Every switching label says what and where.
	for (const [id, pattern] of Object.entries(SWITCHING)) {
		const label = input.locales.en[`sg_actions.${id}`];
		check(
			typeof label === 'string' && pattern.test(label),
			`explicit: ${id} "${label}" must say what it switches and where`
		);
	}

	// 3. The migration of what macOS stopped offering.
	const hs = new Set(offered('hs'));
	const aliases = input.catalogue.karabiner_aliases || {};
	for (const [from, to] of Object.entries(MERGED)) {
		check(!hs.has(from), `merged: macOS must not offer ${from}`);
		check(hs.has(to), `merged: macOS must offer ${to}, the twin of ${from}`);
		if (from === 'alt_tab_apps' || from === 'cycle_windows_in_app') {
			check(aliases[from] === to, `alias: the remap key ${from} must read as ${to}`);
		}
	}
	for (const alias of ['cmd_tab', 'alt_tab_apps_list']) {
		check(aliases[alias] === 'app_previous', `alias: ${alias} must read as app_previous`);
	}
	const step = (input.registry.steps || {}).v5_to_v6;
	check(step !== undefined, 'migration: step v5_to_v6 is missing');
	if (!step) return { errors, checks };
	check(JSON.stringify(step.drivers) === '["hs"]', 'migration: v5_to_v6 is macOS only');
	const listed = new Set();
	for (const op of step.ops || []) {
		listed.add(`${op.section}.${op.key}`);
		const map = Object.fromEntries((op.map || []).map((pair) => [pair.from, pair.to]));
		check(
			op.op === 'map_value' && JSON.stringify(map) === JSON.stringify(MERGED),
			`migration: ${op.section}.${op.key} must map every merged id to its twin`
		);
	}
	// A later rename step gives a v6 key its current name: follow it back.
	const renamedFrom = new Map();
	for (const later of Object.values(input.registry.steps || {})) {
		if (later.from < 6) continue;
		for (const op of later.ops || []) {
			if (op.op !== 'rename') continue;
			renamedFrom.set(
				`${op.to_section || op.section}.${op.to_key || op.key}`,
				`${op.section}.${op.key}`
			);
		}
	}
	const keysAtV6 = input.actionKeys
		.filter((key) => !INTRODUCED_AFTER_V6.has(key))
		.map((key) => renamedFrom.get(key) || key);
	for (const key of keysAtV6) {
		check(listed.has(key), `migration: ${key} holds an action id and is not migrated`);
	}
	check(
		listed.size === keysAtV6.length,
		`migration: ${listed.size} key(s) listed for ${keysAtV6.length} action key(s)`
	);
	return { errors, checks };
}

const manifest = toml.parse(
	read('_shared/modules/features/manifest.toml').replace(
		/^\[\[features\.([^\]]+)\]\]\r?$/gm,
		(_match, prefix) => `[[entries]]\npath_prefix = "${prefix}"`
	)
);
const catalogue = toml.parse(read('_shared/modules/actions/actions.toml'));
const locales = {};
for (const file of fs.readdirSync(path.join(SP, '_shared/data/locales'))) {
	if (file.endsWith('.json')) {
		locales[file.slice(0, -5)] = JSON.parse(read(`_shared/data/locales/${file}`));
	}
}
const actionKeys = [
	...catalogue.slots.single.map((slot) => `gestures.${slot}`),
	...(manifest.entries || [])
		.filter(
			(entry) =>
				['shortcuts.tap_keys', 'shortcuts.script_control'].includes(entry.path_prefix) &&
				entry.type === 'action' &&
				(entry.platforms || []).includes('hs')
		)
		.map((entry) => `${entry.path_prefix}.${entry.id}`)
];
const input = {
	catalogue,
	locales,
	actionKeys,
	registry: toml.parse(read('_shared/core/config_schema/migrations.toml'))
};

const result = validate(input);
const mutations = [
	[
		'unique: hs fr',
		(copy) => {
			copy.locales.fr['sg_actions.app_previous_screen'] =
				copy.locales.fr['sg_actions.app_previous'];
		}
	],
	[
		'explicit: alt_tab_monitor',
		(copy) => {
			copy.locales.en['sg_actions.alt_tab_monitor'] = 'Alt-Tab (monitor)';
		}
	],
	[
		'merged: macOS must not offer app_switcher',
		(copy) => {
			copy.catalogue.sg_actions.app_switcher.platform = 'all';
		}
	],
	[
		'alias: the remap key alt_tab_apps',
		(copy) => {
			delete copy.catalogue.karabiner_aliases.alt_tab_apps;
		}
	],
	[
		'migration: gestures.tap_3 holds',
		(copy) => {
			copy.registry.steps.v5_to_v6.ops = copy.registry.steps.v5_to_v6.ops.filter(
				(op) => op.key !== 'tap_3'
			);
		}
	],
	[
		'migration: shortcuts.tap_keys.number_row_left must map',
		(copy) => {
			const op = copy.registry.steps.v5_to_v6.ops.find((entry) => entry.key === 'number_row_left');
			op.map = op.map.slice(1);
		}
	]
];
let undetected = 0;
for (const [expected, mutate] of mutations) {
	const copy = structuredClone(input);
	try {
		mutate(copy);
	} catch (error) {
		undetected += 1;
		console.error(`  - mutation "${expected}" could not be applied: ${error.message}`);
		continue;
	}
	const mutated = validate(copy);
	if (!mutated.errors.some((error) => error.startsWith(expected))) {
		undetected += 1;
		console.error(
			`  - mutation "${expected}" was not detected: ${mutated.errors.join('; ') || 'no error'}`
		);
	}
}

if (result.errors.length > 0 || undetected > 0) {
	console.error('\x1b[31m[FAIL] app and window switching actions are ambiguous:\x1b[0m');
	for (const error of result.errors) console.error(`  - ${error}`);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] app-switch-labels: ${result.checks} check(s) and ${mutations.length} ` +
		'mutation(s) hold one explicit action per switch and the migration of the rest.\x1b[0m'
);
