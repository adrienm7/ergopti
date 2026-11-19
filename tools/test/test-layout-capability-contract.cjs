// tools/test/test-layout-capability-contract.cjs

/**
 * ============================================================================
 * MODULE: Layout Capability Contract (three drivers)
 * DESCRIPTION:
 * The maintainer's three layout capabilities, per OS and per surface: install
 * and remove a keyboard layout on the OS and switch between installed ones,
 * emulate a layout without installing it, and tune small changes (layers,
 * AltGr, emulated rows, number row, accented-letter shortcuts, magic key) on
 * top of either the OS layout or the emulated one. For each OS it asserts that
 * every path exists in the driver's code and is wired from the tray menu
 * (menu.toml's layout_menu) and from Ergopti Studio (the page's messages and
 * each host's allowlist). An OS that cannot offer one path must carry a reason
 * key with its technical text and 21 translations.
 *
 * FEATURES & RATIONALE:
 * 1. Source tokens are matched in code lines only: comment lines are stripped,
 *    so a path that survives only as a comment fails.
 * 2. Menu rows are found by id anywhere in layout_menu, so reordering the menu
 *    keeps the contract; a row restricted to some OS must name a reason.
 * 3. Both bases of the tuning: the shared emulation runs the AltGr layer alone
 *    over the OS layout, and the drivers keep the OS-base tuning paths (number
 *    row, accented shortcuts) next to the emulated ones.
 * 4. Mutations: each contract is replayed on a source with its token removed
 *    and must then fail, so no entry can pass vacuously.
 * ============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const toml = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const TREE = path.join(ROOT, 'static', 'ergopti_plus');
const SHARED = path.join(TREE, '_shared');
const OSES = ['windows', 'macos', 'linux'];
const MENU_PLATFORM = { windows: 'ahk', macos: 'hs', linux: 'linux' };

/** The source of a driver file with its comments removed. */
function code(rel) {
	const file = path.join(TREE, rel);
	const text = fs.readFileSync(file, 'utf8');
	const comment = rel.endsWith('.ahk')
		? /^\s*;.*$/gm
		: rel.endsWith('.lua')
			? /^s*--.*$/gm
			: /^\s*\/\/.*$/gm;
	return text.replace(comment, '');
}

// [capability, os, surface, file, token]: the code line each path needs.
const PATHS = [
	// 1. Install, remove and switch.
	[
		'install',
		'windows',
		'menu',
		'windows/modules/keymap/system_layout_install.ahk',
		'SystemLayout_MenuRows('
	],
	[
		'install',
		'windows',
		'studio',
		'windows/ui/layout_manager/composer.ahk',
		'_LayoutComposer_SaveSource('
	],
	[
		'install',
		'windows',
		'studio',
		'windows/ui/layout_manager/kbd_register_core.ahk',
		'KbdRegister_Install('
	],
	['install', 'windows', 'studio', 'windows/ui/layout_manager/init.ahk', 'Action == "install"'],
	['remove', 'windows', 'studio', 'windows/ui/layout_manager/init.ahk', 'Action == "uninstall"'],
	[
		'remove',
		'windows',
		'studio',
		'windows/ui/layout_manager/kbd_register_core.ahk',
		'KbdRegister_Uninstall('
	],
	['switch', 'windows', 'menu', 'windows/ui/menu/menu_layout.ahk', '_LAY_SelectActiveLayout('],
	['switch', 'windows', 'menu', 'windows/adapters/keyboard_layout_switch.ahk', 'KLS_Select('],
	[
		'switch',
		'windows',
		'menu',
		'windows/modules/keymap/pause_layout_switch.ahk',
		'PauseLayoutSwitch_MenuRows('
	],
	[
		'install',
		'macos',
		'menu',
		'macos/ui/menu/menu_keyboard_layout.lua',
		'install_user(bundles_dir, latest)'
	],
	[
		'remove',
		'macos',
		'menu',
		'macos/ui/menu/menu_keyboard_layout.lua',
		'install.remove_user(bundle_name)'
	],
	[
		'remove',
		'macos',
		'menu',
		'macos/modules/keymap/layout_install.lua',
		'local function remove_user_unlocked('
	],
	['install', 'macos', 'studio', 'macos/modules/keymap/layout_registry.lua', 'function M.install('],
	[
		'install',
		'macos',
		'studio',
		'macos/modules/keymap/layout_registry.lua',
		'function M.composer_save('
	],
	[
		'remove',
		'macos',
		'studio',
		'macos/modules/keymap/layout_registry.lua',
		'function M.uninstall('
	],
	['switch', 'macos', 'menu', 'macos/ui/menu/menu_keyboard_layout.lua', 'set_input_source_async('],
	['switch', 'macos', 'studio', 'macos/modules/keymap/layout_registry.lua', 'function M.select('],
	['install', 'linux', 'studio', 'linux/modules/keymap/layout_registry.lua', 'function M.install('],
	[
		'install',
		'linux',
		'studio',
		'linux/modules/keymap/layout_registry.lua',
		'function M.install_local('
	],
	// X11 reads no user XKB tree: both installs pass the permission, the selection loads it live.
	[
		'install',
		'linux',
		'studio',
		'linux/modules/keymap/layout_registry.lua',
		'run_installer(deps, with_x11_permission(deps, args)'
	],
	[
		'install',
		'linux',
		'studio',
		'linux/modules/keymap/layout_registry.lua',
		'run_installer(deps, with_x11_permission(deps, { "install"'
	],
	[
		'remove',
		'linux',
		'studio',
		'linux/modules/keymap/layout_registry.lua',
		'run_installer(deps, { "uninstall", "--layout-id", id }'
	],
	[
		'switch',
		'linux',
		'studio',
		'linux/modules/keymap/layout_registry.lua',
		'{ "apply-x11", "--layout-id", id }'
	],
	['switch', 'linux', 'menu', 'linux/ui/menu/active_layout_rows.lua', 'function M.rows('],
	// 2. Emulate without installing: the engine, then the Studio host's port.
	['emulate', 'windows', 'menu', 'windows/ui/menu/menu_layout.ahk', '_LAY_ChooseEmulation('],
	[
		'emulate',
		'windows',
		'engine',
		'windows/modules/keymap/keylayout/keylayout_emulation.ahk',
		'KeylayoutEmulation_Boot('
	],
	[
		'emulate',
		'windows',
		'studio',
		'windows/ui/layout_manager/composer.ahk',
		'_LayoutComposer_Emulate('
	],
	[
		'emulate',
		'windows',
		'studio',
		'windows/ui/layout_manager/editor_window.ahk',
		'"emulate", LayMgrJsonBool_Of(true)'
	],
	[
		'emulate',
		'macos',
		'engine',
		'macos/modules/keymap/layout_emulation.lua',
		'function M.key_down('
	],
	[
		'emulate',
		'macos',
		'studio',
		'macos/ui/layout_manager/init.lua',
		'emulate = _emulation_applier and function'
	],
	['emulate', 'linux', 'engine', 'linux/modules/keymap/layout_emulation.lua', 'function M.on_key('],
	[
		'emulate',
		'linux',
		'studio',
		'linux/ui/layout_manager/bridge.lua',
		'emulate = preferences and function'
	],
	// 3. Tuning: the AltGr layer, the number row and the accented letters on both bases.
	['tune', 'windows', 'engine', 'windows/modules/keymap/layout.ahk', 'RegisterAltGrLayer('],
	[
		'tune',
		'windows',
		'engine',
		'windows/modules/keymap/layout.ahk',
		'AccentedShortcuts_Register()'
	],
	['tune', 'windows', 'menu', 'windows/ui/menu/menu_layout.ahk', '_LAY_NumberRowRows('],
	['tune', 'windows', 'menu', 'windows/core/ui/ui/editors.ahk', 'MagicKeySourceMenuRows('],
	[
		'tune',
		'macos',
		'menu',
		'macos/ui/menu/menu_keyboard_layout.lua',
		'status().number_row == true'
	],
	['tune', 'macos', 'engine', 'macos/modules/keymap/number_row_live.lua', 'function M.apply('],
	['tune', 'linux', 'menu', 'linux/ui/menu/menu_layouts.lua', 'status().number_row == true'],
	['tune', 'linux', 'engine', 'linux/modules/keymap/number_row_live.lua', 'function M.set('],
	[
		'tune',
		'linux',
		'engine',
		'linux/modules/shortcuts/accented_shortcuts.lua',
		'function M.on_key('
	],
	// The shared emulation: the AltGr layer alone runs over the OS layout.
	[
		'tune',
		'macos',
		'engine',
		'_shared/layouts/engine/emulation/settings.lua',
		'settings.base == true or settings.alt_gr == true'
	],
	[
		'tune',
		'linux',
		'engine',
		'_shared/layouts/engine/emulation/settings.lua',
		'settings.base == true or settings.alt_gr == true'
	],
	[
		'tune',
		'macos',
		'engine',
		'_shared/layouts/engine/composer/keylayout_emulation.lua',
		'function M.orders_number_row('
	]
];

// Studio's page messages each host must accept: the editor's Install, Emulate and Download.
const STUDIO_MESSAGES = [
	'install',
	'uninstall',
	'select',
	'composer_save',
	'composer_emulate',
	'source_export'
];

// layout_menu rows by capability; a row with platforms must carry a reason for the others.
const MENU_ROWS = {
	install: ['layout_manager', 'layout_bundle', 'layout_system_install'],
	switch: ['active_layouts', 'layout_switching'],
	emulate: ['layout_emulation'],
	tune: [
		'layout_features_base',
		'layout_features_altgr',
		'layout_emulated_rows',
		'number_row_policy',
		'magic_key_source',
		'accented_letters'
	]
};

/** Checks one path entry against a source text; returns the failure or null. */
function checkPath([capability, os, surface, rel, token], read = code) {
	let text;
	try {
		text = read(rel);
	} catch (error) {
		return `${capability}/${os}/${surface}: ${rel} is unreadable (${error.code || error.message})`;
	}
	return text.includes(token)
		? null
		: `${capability}/${os}/${surface}: ${rel} has no code line with ${token}`;
}

/** Every row of layout_menu keyed by id. */
function layoutRows(menu) {
	const rows = new Map();
	for (const row of menu.layout_menu || []) if (row.id) rows.set(row.id, row);
	return rows;
}

/** The OS a menu row is drawn on, and the reason of each other OS. */
function rowFailures(rows, id, reasons, locales) {
	const row = rows.get(id);
	if (!row) return [`menu: layout_menu has no row ${id}`];
	if (!Array.isArray(row.platforms)) return [];
	const failures = [];
	if (OSES.every((os) => row.platforms.includes(MENU_PLATFORM[os]))) return failures;
	const key = row.reason_key;
	if (typeof key !== 'string' || !key)
		return [`menu: ${id} is restricted to ${row.platforms} without a reason`];
	if (!reasons[key] || typeof reasons[key].technical !== 'string' || !reasons[key].technical)
		failures.push(`menu: ${id}'s reason ${key} has no technical text`);
	for (const [locale, strings] of Object.entries(locales))
		if (typeof strings[key] !== 'string' || !strings[key].trim())
			failures.push(`menu: ${key} is missing in ${locale}`);
	return failures;
}

function main() {
	const menu = toml.parse(
		fs.readFileSync(path.join(SHARED, 'menu', 'data', 'menu.toml'), 'utf8')
	).menu;
	const parity = toml.parse(
		fs.readFileSync(
			path.join(SHARED, 'settings', 'data', 'features', 'platform_parity.toml'),
			'utf8'
		)
	);
	const localesDir = path.join(SHARED, 'core', 'i18n', 'data', 'locales');
	const locales = {};
	for (const file of fs.readdirSync(localesDir).filter((name) => name.endsWith('.json')))
		locales[file.slice(0, -5)] = JSON.parse(fs.readFileSync(path.join(localesDir, file), 'utf8'));
	assert.equal(Object.keys(locales).length, 21, 'the 21 locales');

	const failures = [];
	for (const entry of PATHS) {
		const failure = checkPath(entry);
		if (failure) failures.push(failure);
	}
	// Every OS has each capability on each surface it can offer.
	for (const capability of ['install', 'remove', 'switch', 'emulate', 'tune'])
		for (const os of OSES)
			if (!PATHS.some(([c, o]) => c === capability && o === os))
				failures.push(`${capability}/${os}: no path is declared`);

	// Studio: the page sends each message, the shared bridge and the Windows host accept it.
	const bridge = code('_shared/layouts/engine/manager_bridge.lua');
	const windowsHost =
		code('windows/ui/layout_manager/init.ahk') +
		code('windows/ui/layout_manager/editor_window.ahk');
	const page =
		code('_shared/ui/layout_editor_window/script.js') + code('_shared/ui/layout_manager/script.js');
	for (const message of STUDIO_MESSAGES) {
		if (!new RegExp(`\\b${message} = true,`).test(bridge))
			failures.push(`studio: manager_bridge.lua M.ACTIONS refuses ${message}`);
		if (!windowsHost.includes(`"${message}"`))
			failures.push(`studio: the Windows host never names ${message}`);
		if (!page.includes(`'${message}'`) && !page.includes(`"${message}"`))
			failures.push(`studio: no page sends ${message}`);
	}
	const optimizer = code('_shared/ui/layout_optimizer/optimizer_page.js');
	if (!optimizer.includes("const GET_ACTIONS = ['download', 'install', 'emulate'];"))
		failures.push("studio: the Optimiser's Download, Install and Emulate actions are gone");

	// Menu: each capability's rows exist; a restricted row names a translated reason.
	const rows = layoutRows(menu);
	for (const ids of Object.values(MENU_ROWS))
		for (const id of ids) failures.push(...rowFailures(rows, id, parity.reasons || {}, locales));
	// Removing the macOS bundle is its own declared frame, hidden elsewhere with a reason.
	const remove = (menu.layout_bundle_remove || [])[0];
	if (!remove || remove.id !== 'layout_remove' || !(remove.platforms || []).includes('hs'))
		failures.push('menu: the macOS bundle removal row layout_bundle_remove is gone');

	if (failures.length) {
		console.error('Layout capability contract broken:\n  - ' + failures.join('\n  - '));
		process.exit(1);
	}

	// Mutations: each path fails once its token is gone, and a reason-less
	// restricted row is named.
	for (const entry of PATHS) {
		const [, , , rel, token] = entry;
		const mutated = (name) => (name === rel ? code(rel).split(token).join('') : code(name));
		assert.notEqual(checkPath(entry, mutated), null, `the mutation of ${rel} (${token}) is named`);
	}
	const restricted = new Map([
		['accented_letters', { id: 'accented_letters', platforms: ['ahk'] }]
	]);
	assert.equal(
		rowFailures(restricted, 'accented_letters', {}, locales).length,
		1,
		'a reason-less row is named'
	);
	assert.deepEqual(rowFailures(new Map(), 'layout_emulation', {}, locales), [
		'menu: layout_menu has no row layout_emulation'
	]);

	console.log(
		`PASS: ${PATHS.length} layout paths on Windows, macOS and Linux, ${STUDIO_MESSAGES.length} Studio messages and ` +
			`${Object.values(MENU_ROWS).flat().length} menu rows hold; every mutation is named.`
	);
}

main();
