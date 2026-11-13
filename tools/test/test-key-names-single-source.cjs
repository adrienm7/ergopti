// tools/test/test-key-names-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Key Names Have One Source
 * DESCRIPTION:
 * `_shared/layouts/data/keycodes/key_names.json` is the one table naming a key or a
 * modifier in visible text. This holds it to the locales, to the ids the
 * drivers name keys by, and to its two projections.
 *
 * THE BUG THIS CLOSES:
 * The tap-hold rows read `LCtrl`, `RShift` in every locale, a hold spelled
 * `lalt` printed `lalt`, and the Linux keyboard shortcuts baked a French
 * « Maj » into a table of their own. Each tray named keys from a table of its
 * own or from the id itself.
 *
 * WHAT IS CHECKED:
 * 1. Every key the table names has a text in all 21 catalogues, and every
 *    `key_name.*` catalogue key is named by the table.
 * 2. Every id the drivers name keys by resolves: the tap-hold catalogue, the
 *    hold picker and its aliases, the slot roles, the modifier chords.
 * 3. The Lua and AutoHotkey projections hold the table's rows.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const TOML = require('smol-toml');
const { TABLE, canonical, i18n, stickyModifiers } = require('../lib/key-names.cjs');
const { shared } = require('../lib/paths.cjs');

const LOCALE_COUNT = 21;
const errors = [];

// =====================================
// ======= 1/ Locales ==================
// =====================================

const localesDir = shared('core', 'i18n', 'data', 'locales');
const catalogues = fs
	.readdirSync(localesDir)
	.filter((name) => name.endsWith('.json'))
	.map((name) => ({
		code: name.replace('.json', ''),
		data: JSON.parse(fs.readFileSync(path.join(localesDir, name), 'utf8'))
	}));
if (catalogues.length !== LOCALE_COUNT)
	errors.push(`expected ${LOCALE_COUNT} catalogues, found ${catalogues.length}`);

const named = new Set();
for (const entry of Object.values(TABLE.keys)) {
	named.add(entry.i18n);
	for (const key of Object.values(entry.platforms || {})) named.add(key);
}
named.add(TABLE.physical.numpad);
for (const key of named)
	for (const { code, data } of catalogues)
		if (typeof data[key] !== 'string' || data[key].trim() === '')
			errors.push(`${code} has no text for ${key}`);
for (const { code, data } of catalogues)
	for (const key of Object.keys(data))
		if (key.startsWith('key_name.') && !named.has(key))
			errors.push(`${code}: ${key} is named by no row of key_names.json`);

// =====================================
// ======= 2/ Driver ids ===============
// =====================================

const defaults = TOML.parse(fs.readFileSync(shared('tap_hold', 'data', 'defaults.toml'), 'utf8'));
const resolve = (spelling, where) => {
	if (canonical(spelling) === null) errors.push(`${where} "${spelling}" has no key name`);
};

const catalog = defaults.tap_hold.catalog.keys;
if (!Array.isArray(catalog) || catalog.length < 15)
	errors.push('the tap-hold catalogue reads short');
for (const entry of catalog) {
	resolve(entry.id, '[tap_hold.catalog] id');
	for (const column of ['ahk', 'hs', 'linux'])
		if (entry[column] !== undefined) resolve(entry[column], `[tap_hold.catalog] ${column}`);
	if (Object.hasOwn(entry, 'label_key'))
		errors.push(`[tap_hold.catalog] ${entry.id} carries a label_key: key_names.json names it`);
}

// The per-menu name families this table replaced may not come back.
const RETIRED = /^(tap_hold\.group\.|tap_hold\.hold\.(ctrl|shift|alt|alt_gr|win)$)/;
for (const { code, data } of catalogues)
	for (const key of Object.keys(data))
		if (RETIRED.test(key)) errors.push(`${code}: ${key} names a key outside key_names.json`);

const picker = defaults.tap_hold.hold_picker;
for (const modifier of picker.modifiers) resolve(modifier, '[tap_hold.hold_picker] modifier');
for (const field of ['modifier_aliases', 'left_modifier_aliases'])
	for (const [alias, id] of Object.entries(picker[field])) {
		resolve(alias, `[tap_hold.hold_picker] ${field}`);
		resolve(id, `[tap_hold.hold_picker] ${field} target`);
	}

const roles = JSON.parse(
	fs.readFileSync(shared('shortcuts', 'data', 'actions', 'slot_roles.json'), 'utf8')
);
for (const [name, role] of Object.entries(roles.roles))
	for (const platform of TABLE.platforms)
		if (role[platform] !== null) resolve(role[platform], `slot role ${name} on ${platform}`);

const chords = JSON.parse(
	fs.readFileSync(shared('shortcuts', 'data', 'actions', 'modifier_chords.json'), 'utf8')
);
for (const [platform, data] of Object.entries(chords.platforms))
	for (const modifier of data.modifiers) resolve(modifier.id, `modifier chord on ${platform}`);
// A chord key the table names is named from it in the picker rows, which read
// « Cmd + Option + Shift + Enter » in every locale until 2026-11-03; any other
// key prints its legend, which no table translates (A, 1, .).
for (const key of chords.keys) {
	if (key.key_name !== undefined) {
		resolve(key.key_name, `modifier chord key ${key.id} key_name`);
		if (canonical(key.key_name) !== canonical(key.id))
			errors.push(`modifier chord key ${key.id} names another key: ${key.key_name}`);
	} else {
		if (canonical(key.id) !== null || canonical(String(key.label)) !== null)
			errors.push(`modifier chord key ${key.id} is a named key without key_name`);
		if (typeof key.label !== 'string' || key.label === '' || /[a-z]{2}/i.test(key.label))
			errors.push(
				`modifier chord key ${key.id} needs key_name: its legend "${key.label}" is a word`
			);
	}
}

// A sticky label is a template its modifiers fill from this table
// (_shared/shortcuts/engine/actions/sticky_label.lua): it spelled « Cmd+Shift » in every
// locale until 2026-11-03. sticky_hyper is named by its own word.
const actionRows = TOML.parse(
	fs.readFileSync(shared('shortcuts', 'data', 'actions', 'actions.toml'), 'utf8')
).sg_actions;
const stickyIds = Object.keys(actionRows).filter((id) => id.startsWith('sticky_'));
if (stickyIds.length < 15) errors.push(`only ${stickyIds.length} sticky actions found`);
for (const id of stickyIds) {
	let modifiers = null;
	try {
		modifiers = stickyModifiers(id);
	} catch (error) {
		errors.push(error.message);
		continue;
	}
	for (const modifier of modifiers || []) resolve(modifier, `sticky action ${id}`);
	for (const { code, data } of catalogues) {
		const holes = String(data[`sg_actions.${id}`]).split('{1}').length - 1;
		if (holes !== (modifiers === null ? 0 : 1))
			errors.push(`${code}: sg_actions.${id} holds {1} ${holes} time(s)`);
		if (modifiers !== null && /Cmd|Option|Shift|Ctrl|Maj/.test(String(data[`sg_actions.${id}`])))
			errors.push(`${code}: sg_actions.${id} spells a key name the table should fill`);
	}
}

// Every position a physical shortcut slot can hold is named, never shown as
// its W3C code (`KeyA`): the rule of key_names.lua physical_label.
const physicalKeys = JSON.parse(
	fs.readFileSync(shared('layouts', 'data', 'keycodes', 'physical_keys.json'), 'utf8')
).keys;
const MODIFIER_POSITIONS = /^(Shift|Control|Alt|Meta)(Left|Right)$|^CapsLock$/;
const legends = TABLE.physical.legends;
const physicalNamed = (code) => {
	if (/^Key[A-Z]$|^Digit\d$|^F\d\d?$/.test(code) || Object.hasOwn(legends, code)) return true;
	const pad = code.match(/^Numpad(.+)$/);
	if (pad) return /^\d$/.test(pad[1]) || canonical(pad[1]) !== null;
	return canonical(code) !== null;
};
for (const [code, record] of Object.entries(physicalKeys))
	if (record.kind === 'key' && !MODIFIER_POSITIONS.test(code) && !physicalNamed(code))
		errors.push(`physical key ${code} has no name in key_names.json`);
for (const { code, data } of catalogues)
	if (!String(data[TABLE.physical.numpad] || '').includes('{1}'))
		errors.push(`${code}: ${TABLE.physical.numpad} must hold {1}`);

// The usual name on each OS, as the maintainer asked (2026-11-03).
const expect = (spelling, platform, key) => {
	if (i18n(spelling, platform) !== key)
		errors.push(`${spelling} on ${platform} reads ${i18n(spelling, platform)}, not ${key}`);
};
expect('alt', 'macos', 'key_name.option');
expect('win', 'linux', 'key_name.super');
expect('win', 'windows', 'key_name.win');
expect('LCtrl', 'windows', 'key_name.left_ctrl');

// =====================================
// ======= 3/ Projections ==============
// =====================================

const lua = fs.readFileSync(shared('platform', 'input', 'keycodes', 'key_names_data.lua'), 'utf8');
const ahk = fs.readFileSync(shared('..', 'windows', '_generated', 'key_names.ahk'), 'utf8');
for (const id of Object.keys(TABLE.keys)) {
	const row = TABLE.platforms.map((p) => `${p} = "${i18n(id, p)}"`).join(', ');
	if (!lua.includes(`\t\t${id} = { ${row} },`))
		errors.push(`key_names_data.lua lacks the row of ${id}`);
	if (!ahk.includes(`"${id}", "${i18n(id, 'windows')}"`))
		errors.push(`_generated/key_names.ahk lacks the row of ${id}`);
}
for (const [id, entry] of Object.entries(TABLE.keys)) {
	if (entry.macos_symbol === undefined) continue;
	if (!lua.includes(`\t\t${id} = "${entry.macos_symbol}",`))
		errors.push(`key_names_data.lua lacks the macOS symbol of ${id}`);
}
// The AI tooltip's shortcut column names every modifier of its order from this
// table: a glyph on macOS, a translated name elsewhere.
const tooltip = TOML.parse(
	fs.readFileSync(shared('core', 'ui', 'data', 'tooltip', 'constants.toml'), 'utf8')
).llm_ui;
for (const modifier of tooltip.shortcut_modifier_order.split(',')) {
	const id = canonical(modifier);
	if (id === null || TABLE.keys[id].macos_symbol === undefined)
		errors.push(
			`tooltip shortcut_modifier_order names ${modifier}, which has no key name and glyph`
		);
}
// The footer's navigation hints name their keys from this table and their words
// from the locales: they read French (« Tab pour accepter », « ⇧G + Tab ») in
// every locale until 2026-11-03.
for (const field of ['hint_accept_key', 'hint_nav_left_keys', 'hint_nav_right_keys']) {
	const value = tooltip[field];
	if (typeof value !== 'string' || value === '')
		errors.push(`tooltip [llm_ui].${field} is missing`);
	else for (const part of value.split('+')) resolve(part, `tooltip [llm_ui].${field}`);
}
for (const field of Object.keys(tooltip))
	if (/^hint_(accept_single|accept_center|or|nav_left|nav_right)$/.test(field))
		errors.push(`tooltip [llm_ui].${field} spells words the locales own`);
for (const [key, holes] of [
	['llm.tooltip.hint_accept_single', ['{1}']],
	['llm.tooltip.hint_accept_center', ['{1}']],
	['llm.tooltip.hint_or', ['{1}', '{2}']]
])
	for (const { code, data } of catalogues)
		if (typeof data[key] !== 'string' || !holes.every((hole) => data[key].includes(hole)))
			errors.push(`${code}: ${key} must hold ${holes.join(' and ')}`);
for (const [code, legend] of Object.entries(legends))
	if (!lua.includes(`\t\t\t${code} = ${JSON.stringify(legend)},`))
		errors.push(`key_names_data.lua lacks the physical legend of ${code}`);
for (const [alias, id] of Object.entries(TABLE.aliases)) {
	if (!lua.includes(`\t\t["${alias}"] = "${id}",`))
		errors.push(`key_names_data.lua lacks alias ${alias}`);
	if (!ahk.includes(`"${alias}", "${id}"`))
		errors.push(`_generated/key_names.ahk lacks alias ${alias}`);
}

if (errors.length > 0) {
	console.error(`\x1b[31m[ERROR] ${errors.length} key name defect(s):\x1b[0m`);
	for (const error of errors) console.error(`  ${error}`);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] ${Object.keys(TABLE.keys).length} key names and ${Object.keys(TABLE.aliases).length} aliases hold in ${catalogues.length} catalogues and both projections.\x1b[0m`
);
