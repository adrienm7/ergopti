// tools/test/test-shortcut-inventory-matches-sources.cjs

/**
 * ==============================================================================
 * MODULE: Shortcut Inventory Matches The Sources
 * DESCRIPTION:
 * `docs/audits/2026-10-27-shortcut-inventory.json` lists every shortcut config
 * entry of the three drivers (PAR-41 step 1). Later steps of the one-shortcut
 * model consume it, so it must not rot: this gate re-derives each fact from the
 * code that owns it (the features manifest, the AutoHotkey `AddShortcut` calls,
 * the macOS hotkey registry, the slot prefix tables) and fails on any drift.
 *
 * FEATURES & RATIONALE:
 * 1. Entry sets: the inventory names exactly the manifest's legacy booleans,
 *    keyboard slots and personal toggles of each driver.
 * 2. Chords: every boolean's chord is the one its handler registers, read from
 *    the AutoHotkey and Lua sources (read-only).
 * 3. Actions: every action id exists in actions.toml.
 * 4. Slot families: the prefixes match each driver's slot prefix table.
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { parse: parseToml } = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS = path.join(ROOT, 'static', 'ergopti_plus');
const SHARED = path.join(DRIVERS, '_shared');
const read = (...parts) => fs.readFileSync(path.join(...parts), 'utf8');

const inventory = JSON.parse(read(ROOT, 'docs', 'audits', '2026-10-27-shortcut-inventory.json'));
const PLATFORM = { windows: 'ahk', macos: 'hs', linux: 'linux' };

// =======================================
// =======================================
// ======= 1/ Reading the sources =======
// =======================================
// =======================================

/** Manifest entries as { section, id, platforms }, headers rewritten so the
 *  array-of-tables nesting of TOML cannot hide a sub-section. */
function manifestEntries() {
	const source = read(SHARED, 'modules', 'features', 'manifest.toml');
	const records = parseToml(
		source.replace(
			/^\[\[features\.([^\]]+)\]\]$/gm,
			(_header, section) => `[[declarations]]\nsection_path = "${section}"`
		)
	).declarations;
	return records.map((r) => ({ section: r.section_path, id: r.id, platforms: r.platforms || [] }));
}

const entries = manifestEntries();
const idsOf = (section, platform) =>
	entries
		.filter((e) => e.section === section && e.platforms.includes(platform))
		.map((e) => e.id)
		.sort();
const inventoryIds = (driver, kinds, prefix) =>
	inventory.rows
		.filter((r) => r.driver === driver && kinds.includes(r.kind) && r.config_key.startsWith(prefix))
		.map((r) => r.config_key.slice(prefix.length))
		.sort();

const actionIds = new Set(
	[
		...read(SHARED, 'modules', 'actions', 'actions.toml').matchAll(
			/^\[sg_actions\.([a-z0-9_]+)\]/gm
		)
	].map((m) => m[1])
);

// ============================================
// ============================================
// ======= 2/ Entry sets per driver ============
// ============================================
// ============================================

assert.deepStrictEqual(
	inventoryIds('windows', ['legacy_boolean', 'special_boolean'], 'shortcuts.'),
	idsOf('shortcuts', 'ahk').filter((id) => !['enabled', 'chatgpt_url'].includes(id)),
	'Windows legacy booleans differ from the manifest'
);
assert.deepStrictEqual(
	inventoryIds('windows', ['keyboard_slot'], 'shortcuts.keyboard.'),
	idsOf('shortcuts.keyboard', 'ahk'),
	'Windows keyboard slots differ from the manifest'
);
assert.deepStrictEqual(
	inventoryIds('windows', ['personal_toggle'], 'shortcuts.personal.'),
	idsOf('shortcuts.personal', 'ahk'),
	'Windows personal toggles differ from the manifest'
);
assert.deepStrictEqual(
	inventoryIds('macos', ['legacy_boolean', 'special_boolean'], 'shortcuts.keys.'),
	idsOf('shortcuts.keys', 'hs'),
	'macOS shortcut booleans differ from the manifest'
);
assert.deepStrictEqual(
	inventoryIds('macos', ['keyboard_slot'], 'shortcuts.keyboard.'),
	idsOf('shortcuts.keyboard', 'hs'),
	'macOS keyboard slots differ from the manifest'
);
assert.deepStrictEqual(
	inventoryIds('linux', ['keyboard_slot'], 'shortcuts.keyboard.'),
	idsOf('shortcuts.keyboard', 'linux'),
	'Linux keyboard slots differ from the manifest'
);
assert.deepStrictEqual(
	inventory.rows
		.filter((r) => r.driver === 'linux' && r.kind === 'special_boolean')
		.map((r) => r.config_key.slice('shortcuts.'.length)),
	['wrap_text_if_selected'],
	'Linux shortcut booleans differ'
);
assert.deepStrictEqual(
	idsOf('shortcuts', 'linux').filter((id) => !['enabled', 'chatgpt_url'].includes(id)),
	['wrap_text_if_selected'],
	'the manifest gives Linux another shortcut boolean'
);

// ====================================
// ====================================
// ======= 3/ Chords and actions =======
// ====================================
// ====================================

const AHK_MODIFIERS = { '#': 'win', '^': 'ctrl', '+': 'shift', '!': 'alt' };
const AHK_KEYS = { "'": 'quote' };
const winSource = read(DRIVERS, 'windows', 'modules', 'shortcuts', 'win.ahk');
const ctrlSource = read(DRIVERS, 'windows', 'modules', 'shortcuts', 'ctrl.ahk');
const bindings = read(DRIVERS, 'macos', 'modules', 'shortcuts', 'bindings.lua');

/** The chord a Windows boolean registers: the first AddShortcut after its gate. */
function windowsChord(id) {
	for (const source of [winSource, ctrlSource]) {
		const gate = source.indexOf(`if Features["shortcuts"]["${id}"]`);
		if (gate === -1) continue;
		const call = source.slice(gate).match(/AddShortcut\(\s*"([#^+!]+)",\s*"(.)"/);
		assert(call, `no AddShortcut after the ${id} gate`);
		return {
			modifiers: [...call[1]].map((c) => AHK_MODIFIERS[c]).sort(),
			key: AHK_KEYS[call[2]] || call[2]
		};
	}
	if (id === 'win_caps_lock') {
		assert(/#SC03A::/.test(winSource), 'Win+CapsLock hotkey is gone');
		return { modifiers: ['win'], key: 'capslock' };
	}
	return null;
}

/** The chord a macOS boolean binds, from its hotkey_defs factory. */
function macosChord(id) {
	const block = bindings.match(
		new RegExp(`hotkey_defs\\.${id}\\s*=\\s*function\\(\\)([\\s\\S]*?)\\nend`)
	);
	assert(block, `hotkey_defs.${id} not found`);
	const bound = block[1].match(/bind_log\(\{([^}]*)\},\s*"([^"]+)"/);
	if (!bound) return null;
	const keys = { "'": 'quote', '.': 'period' };
	return {
		modifiers: [...bound[1].matchAll(/"(\w+)"/g)].map((m) => m[1]).sort(),
		key: keys[bound[2]] || bound[2]
	};
}

for (const row of inventory.rows) {
	if (row.action !== null) {
		assert(
			actionIds.has(row.action),
			`${row.config_key}: action "${row.action}" is not in actions.toml`
		);
	}
	if (row.kind === 'legacy_boolean') {
		const id = row.config_key.split('.').pop();
		const actual = row.driver === 'windows' ? windowsChord(id) : macosChord(id);
		assert.deepStrictEqual(
			actual,
			{ modifiers: [...row.chord.modifiers].sort(), key: row.chord.key },
			`${row.driver} ${row.config_key}: the inventory chord differs from the source`
		);
	}
	if (row.slot) {
		assert(
			entries.some(
				(e) =>
					e.section === 'shortcuts.keyboard' &&
					e.id === row.slot &&
					e.platforms.includes(PLATFORM[row.driver])
			),
			`${row.config_key}: slot "${row.slot}" is not declared for ${row.driver}`
		);
	}
}

// =====================================
// =====================================
// ======= 4/ Slot prefix tables =======
// =====================================
// =====================================

const families = (driver) =>
	inventory.slot_families
		.filter((f) => f.driver === driver)
		.map((f) => f.prefix)
		.sort();

const windowsGroups = [
	...read(DRIVERS, 'windows', 'infra', 'config_io.ahk')
		.match(/global KEYBOARD_SLOT_GROUPS := \[([\s\S]*?)\n\]/)[1]
		.matchAll(/Map\("prefix", "([a-z_]+_)"/g)
]
	.map((m) => m[1])
	.filter((p) => p !== 'magic_')
	.sort();
assert.deepStrictEqual(families('windows'), windowsGroups, 'Windows slot prefixes differ');

const roleFamilies = JSON.parse(read(SHARED, 'modules', 'actions', 'slot_roles.json')).families;
const prefixesOf = (driver) => roleFamilies[driver].map((roles) => roles.join('_') + '_').sort();
assert.deepStrictEqual(families('macos'), prefixesOf('macos'), 'macOS slot prefixes differ');
assert.deepStrictEqual(families('linux'), prefixesOf('linux'), 'Linux slot prefixes differ');

console.log(
	`[OK] the shortcut inventory matches the manifest, the handlers' chords and the slot prefix tables (${inventory.rows.length} rows).`
);
