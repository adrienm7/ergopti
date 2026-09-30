// tools/test/test-script-chords-three-os.cjs

/**
 * ==============================================================================
 * MODULE: Script Chords Three OS Gate (script-chords-three-os-2026-09-30)
 * DESCRIPTION:
 * The maintainer's decision of 2026-09-30: « On met tout en commun sur les 3
 * OS ». The script-management chords are one model on Windows, macOS and
 * Linux, and this gate holds it from the sources on every OS:
 *
 * 1. The four slots and the switch are one manifest entry each, on the three
 *    drivers, starting with the maintainer's presets (Enter → pause toggle,
 *    Backspace → reload, Delete → personal shortcuts, Escape → quit), active
 *    by default, cleared to "none"; each generated manifest carries the same
 *    values, and no driver keeps a slot of its own.
 * 2. _shared/modules/actions/script_chords.json names the same slots, each
 *    key as the shared physical-key registry does, and the actions a paused
 *    driver still runs. Windows declares the same slots, scan codes and paused
 *    actions (feature_state.ahk, config_io.ahk); macOS gives every slot a
 *    distinct Karabiner sentinel; Linux and macOS read the catalogue and apply
 *    the shared rule (_shared/lua/script_chords.lua).
 * 3. The submenu is script_control_group on the three drivers (switch, restore,
 *    clear, separator, slots), its title ticked from the switch getter, and each
 *    driver registers its group, its three commands and the getter.
 * 4. The first-run wizard lists none of them: their preset is their default.
 *
 * ROOT CAUSE ENCODED:
 * Each driver had its own chords: four AltGr slots on Windows, three
 * right-Option slots off by default on macOS whose submenu no manifest row
 * drew, none on Linux.
 *
 * `--root <dir>` scans another checkout's copy of the tree.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { parse } = require('smol-toml');

const rootArg = process.argv.indexOf('--root');
const ROOT =
	rootArg > 0 ? path.resolve(process.argv[rootArg + 1]) : path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');

const errors = [];
let checks = 0;
const check = (ok, message) => {
	checks += 1;
	if (!ok) errors.push(message);
};

/**
 * Reads one file of the tree, BOM removed; an absent file reads as "".
 * @param {...string} parts Path below static/ergopti_plus.
 * @returns {string} Content.
 */
const read = (...parts) => {
	const file = path.join(SP, ...parts);
	return fs.existsSync(file) ? fs.readFileSync(file, 'utf8').replace(/^﻿/, '') : '';
};

const PLATFORMS = ['ahk', 'hs', 'linux'];
// The maintainer's mapping, in menu order (Windows slots at cbd9ae615).
const PRESETS = [
	['script_altgr_enter', 'script_pause_toggle', 'Enter'],
	['script_altgr_backspace', 'script_reload', 'Backspace'],
	['script_altgr_delete', 'open_personal_shortcuts', 'Delete'],
	['script_altgr_escape', 'script_quit', 'Escape']
];
const SLOT_IDS = PRESETS.map(([id]) => id);
const SECTION = 'shortcuts.script_control';

// ==================================================
// ==================================================
// ======= 1/ One manifest entry per slot ===========
// ==================================================
// ==================================================

const manifestSource = read('_shared', 'modules', 'features', 'manifest.toml');
const manifest = manifestSource
	? parse(
			manifestSource.replace(
				/^\[\[features\.([^\]]+)\]\]$/gm,
				(_match, section) => `[[entries]]\nsection = "${section}"`
			)
		)
	: { entries: [], sections: {} };
const entries = (manifest.entries || []).filter((entry) => entry.section === SECTION);
const byId = new Map(entries.map((entry) => [entry.id, entry]));
check(
	JSON.stringify(entries.map((entry) => entry.id).sort()) ===
		JSON.stringify(['chords_enabled', ...SLOT_IDS].sort()),
	`[${SECTION}] must hold the switch and the four shared slots only, found [${entries.map((e) => e.id)}]`
);
const section = ((manifest.sections || {}).shortcuts || {}).script_control || {};
check(
	JSON.stringify(section.platforms) === JSON.stringify(PLATFORMS),
	`the ${SECTION} section must be on the three drivers, found ${JSON.stringify(section.platforms)}`
);
for (const [id, preset] of PRESETS) {
	const entry = byId.get(id) || {};
	check(
		JSON.stringify(entry.platforms) === JSON.stringify(PLATFORMS),
		`${id} must be on the three drivers`
	);
	check(
		entry.default === preset && entry.recommended === preset,
		`${id} must start with its preset ${preset}, found ${entry.default} / ${entry.recommended}`
	);
	check(
		entry.active_by_default === true && entry.cleared === 'none' && entry.type === 'action',
		`${id} must be an action active by default whose clear writes "none"`
	);
	check(
		entry.default_per_platform === undefined && entry.recommended_per_platform === undefined,
		`${id} must have one preset on every driver`
	);
}
const toggle = byId.get('chords_enabled') || {};
check(
	JSON.stringify(toggle.platforms) === JSON.stringify(PLATFORMS) &&
		toggle.default === true &&
		toggle.recommended === true &&
		toggle.input_altering === false,
	'chords_enabled must be a parameter on the three drivers that starts on'
);

// Each generated manifest carries the same five entries.
const luaEntry = (source, id) => {
	const match = source.match(new RegExp(`path = "${SECTION}\\.${id}", id = "${id}",[^\\n]*`, 'u'));
	return match ? match[0] : '';
};
for (const [driver, file] of [
	['hs', ['macos', '_generated', 'features_manifest.lua']],
	['linux', ['linux', '_generated', 'features_manifest.lua']]
]) {
	const source = read(...file);
	for (const [id, preset] of PRESETS) {
		const line = luaEntry(source, id);
		check(
			line.includes(`default = "${preset}"`) &&
				line.includes(`recommended = "${preset}"`) &&
				line.includes('cleared = "none"'),
			`${driver}'s generated manifest must carry ${id} on ${preset}, cleared to "none"`
		);
	}
	check(
		/default = true[^\n]*recommended = true/.test(luaEntry(source, 'chords_enabled')),
		`${driver}'s generated manifest must carry the switch on`
	);
}
const ahkManifest = read('windows', '_generated', 'features_manifest.ahk');
for (const [id, preset] of PRESETS) {
	const line = (ahkManifest.match(new RegExp(`"path", "${SECTION}\\.${id}"[^\\n]*`)) || [''])[0];
	check(
		line.includes(`"default", "${preset}"`) &&
			line.includes(`"recommended", "${preset}"`) &&
			line.includes('"cleared", "none"'),
		`Windows's generated manifest must carry ${id} on ${preset}, cleared to "none"`
	);
}

// ==================================================
// ==================================================
// ======= 2/ The shared catalogue and each key =====
// ==================================================
// ==================================================

let catalogue = { slots: [], paused_actions: [] };
try {
	catalogue = JSON.parse(read('_shared', 'modules', 'actions', 'script_chords.json'));
} catch (error) {
	check(false, `script_chords.json must parse: ${error.message}`);
}
check(
	JSON.stringify((catalogue.slots || []).map((slot) => slot.id)) === JSON.stringify(SLOT_IDS),
	'script_chords.json must list the four manifest slots in menu order'
);
let registry = { keys: {} };
try {
	registry = JSON.parse(read('_shared', 'data', 'keycodes', 'physical_keys.json'));
} catch (error) {
	check(false, `physical_keys.json must parse: ${error.message}`);
}
for (const [id, , keyName] of PRESETS) {
	const slot = (catalogue.slots || []).find((row) => row.id === id) || {};
	const key = (registry.keys || {})[keyName] || {};
	check(
		slot.ahk === key.ahk &&
			slot.hs === key.hs &&
			slot.linux === key.evdev &&
			slot.karabiner === (key.karabiner || {}).key_code,
		`${id} must name the ${keyName} key as physical_keys.json does`
	);
}

// Windows declares the same slots, scan codes and paused actions.
const featureState = read('windows', 'infra', 'feature_state.ahk');
const configIo = read('windows', 'infra', 'config_io.ahk');
const ahkBlock = (source, name) => {
	const match = source.match(new RegExp(`global ${name} := (?:Map|\\[)\\(?([\\s\\S]*?)\\n\\)`));
	const brackets = source.match(new RegExp(`global ${name} := \\[([\\s\\S]*?)\\]`));
	return ((brackets && brackets[1]) || (match && match[1]) || '').replace(/;[^\n]*/g, '');
};
const strings = (block) => [...block.matchAll(/"([^"]*)"/g)].map((m) => m[1]);
check(
	JSON.stringify(strings(ahkBlock(featureState, 'SCRIPT_SHORTCUT_SLOTS'))) ===
		JSON.stringify(SLOT_IDS),
	'Windows SCRIPT_SHORTCUT_SLOTS must be the four shared slots in menu order'
);
const scanCodes = strings(ahkBlock(featureState, 'SCRIPT_SHORTCUT_SCAN_CODES'));
for (const slot of catalogue.slots || []) {
	const at = scanCodes.indexOf(slot.id);
	check(
		at >= 0 && scanCodes[at + 1] === slot.ahk,
		`Windows SCRIPT_SHORTCUT_SCAN_CODES must bind ${slot.id} to ${slot.ahk}`
	);
}
const suspendAllowed = strings(ahkBlock(configIo, 'SCRIPT_SHORTCUT_SUSPEND_ALLOWED')).filter(
	(value) => !/^(true|false)$/.test(value)
);
check(
	JSON.stringify([...suspendAllowed].sort()) ===
		JSON.stringify([...(catalogue.paused_actions || [])].sort()),
	`Windows SCRIPT_SHORTCUT_SUSPEND_ALLOWED [${suspendAllowed}] must be the shared paused actions [${catalogue.paused_actions}]`
);

// macOS: one distinct sentinel per slot, and the shared rule on both Lua drivers.
const keycodes = read('_shared', 'lua', 'keycodes', 'init.lua');
const sentinels = (keycodes.match(/M\.SCRIPT_CHORD_SENTINELS = \{([\s\S]*?)\n\}/) || ['', ''])[1];
const sentinelNames = [...sentinels.matchAll(/(\w+)\s*=\s*"(\w+)"/g)];
check(
	JSON.stringify(sentinelNames.map((m) => m[1])) === JSON.stringify(SLOT_IDS),
	'Keycodes.SCRIPT_CHORD_SENTINELS must give each shared slot its sentinel, in menu order'
);
const sentinelCodes = sentinelNames.map(
	(m) => (keycodes.match(new RegExp(`^M\\.${m[2]} = (\\d+)$`, 'm')) || [])[1]
);
check(
	sentinelCodes.every((code) => code !== undefined) &&
		new Set(sentinelCodes).size === SLOT_IDS.length,
	`each script chord must have a sentinel keycode of its own, found [${sentinelCodes}]`
);
const macControl = read('macos', 'modules', 'shortcuts', 'script_control.lua');
check(
	/ScriptChords\.runs\(ChordCatalogue\.get\(\), actions\[slot_id\], chords_on, paused\)/.test(
		macControl
	) && !/PAUSED_ACTION_ALLOWLIST/.test(macControl),
	'macOS script control must judge each chord with the shared rule and the shared paused actions'
);
const macRules = read('macos', 'platform', 'remap', 'script_chord_rules.lua');
check(
	/for _, slot in ipairs\(ordered\(plan\.normal\)\)/.test(macRules) &&
		/for _, slot in ipairs\(ordered\(plan\.paused\)\)/.test(macRules),
	'the Karabiner rules must give a sentinel only to the slots the plan runs, running and paused'
);
const linuxChords = read('linux', 'modules', 'shortcuts', 'script_chords.lua');
check(
	/ScriptChords\.runs\(M\.catalogue\(\), _assignments\[slot_id\], _chords_on, paused\)/.test(
		linuxChords
	),
	'Linux script chords must judge each chord with the shared rule'
);
check(
	/if script_chords\.on_key\(detail\) then return true end/.test(
		read('linux', 'ergopti_hotstrings.lua')
	),
	'the Linux keyboard hook must ask the script chords about every key press'
);

// ==================================================
// ==================================================
// ======= 3/ One submenu on every driver ===========
// ==================================================
// ==================================================

let menu = {};
try {
	menu = JSON.parse(read('_shared', 'modules', 'menu', 'menu_manifest.json'));
} catch (error) {
	check(false, `menu_manifest.json must parse: ${error.message}`);
}
const group = menu.script_control_group || [];
check(
	JSON.stringify(group.map((row) => `${row.type}:${row.id || ''}`)) ===
		JSON.stringify([
			'toggle:script_control_toggle',
			'command:restore_recommended',
			'command:clear_to_system',
			'---:',
			'list:script_control_shortcuts'
		]),
	'script_control_group must be switch, restore, clear, separator, slots'
);
check(
	group.every((row) => row.platforms === undefined),
	'every row of script_control_group must be on the three drivers'
);
const parent = (menu.shortcuts_menu || []).find((row) => row.id === 'script_control') || {};
check(
	parent.type === 'group' &&
		parent.platforms === undefined &&
		JSON.stringify(parent.checked_when) === JSON.stringify(['script_control_enabled']) &&
		JSON.stringify((group[0] || {}).checked_when) === JSON.stringify(['script_control_enabled']),
	'the Shortcuts submenu must open the group on the three drivers, its title ticked from the switch'
);
for (const [driver, file, builder] of [
	[
		'macOS',
		['macos', 'ui', 'menu', 'menu_shortcuts.lua'],
		/\["script_control"\] = script_control_group/
	],
	[
		'Linux',
		['linux', 'ui', 'menu', 'menu_builder.lua'],
		/group_builders\["script_control"\] = function/
	]
]) {
	const source = read(...file);
	check(builder.test(source), `${driver} must build the script_control group`);
	for (const command of ['script_control_toggle', 'restore_recommended', 'clear_to_system']) {
		check(
			source.includes(`["${command}"]`),
			`${driver} must register the ${command} command of the script chords`
		);
	}
	check(
		(source.match(/state_getters\["script_control_enabled"\]/g) || []).length >= 2,
		`${driver} must tick the title and the switch from the same switch`
	);
	check(
		/ManifestMenu\.build\("script_control_group"/.test(source),
		`${driver} must draw the group from script_control_group`
	);
}
check(
	!/dyn_script_control/.test(read('macos', 'ui', 'menu', 'menu_shortcuts.lua')),
	"macOS's dead script-control provider must be gone"
);
const menuShortcuts = read('windows', 'ui', 'menu', 'menu_shortcuts.ahk');
check(
	/"script_control",\s*\(\) => _SC_ScriptControlSubmenu\(\)/.test(menuShortcuts) &&
		/MenuRenderer_Build\("script_control_group"/.test(menuShortcuts),
	'Windows must build the script_control group from script_control_group'
);

// ==================================================
// ==================================================
// ======= 4/ The wizard lists none of them =========
// ==================================================
// ==================================================

const labels = (((manifest.onboarding || {}).pages || {}).shortcuts || {}).labels || {};
check(
	!Object.keys(labels).some((key) => key.startsWith(`${SECTION}.`)),
	"the wizard's Shortcuts page must not list the chords: their preset is their default"
);

if (errors.length > 0) {
	for (const e of errors) console.error(`  FAIL  ${e}`);
	console.error(`\n[script-chords-three-os] ${errors.length} of ${checks} check(s) failed.`);
	process.exit(1);
}
console.log(
	`[script-chords-three-os] ${checks} checks: the three drivers share the script chords, their presets, their defaults and their submenu.`
);
