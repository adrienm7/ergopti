// tools/test/test-menu-parity.cjs

/**
 * ==============================================================================
 * MODULE: Cross-Driver Menu Parity (I3)
 * DESCRIPTION:
 * Projects menu_manifest.json for Windows, macOS and Linux, walks the three
 * resulting menu trees, and asserts they differ only where the manifest says so.
 *
 * WHY A SECOND MENU GATE, NEXT TO test-menu-top-level-parity.cjs:
 * That one compares the TOP LEVEL and stops there — deliberately, because when it
 * was written Linux had no manifest renderer and reading its submenus meant
 * reading 1200 lines of hand-built rows. Everything below the top level was
 * therefore unmeasured, and three defects were living in that gap on 2026-08-04:
 *
 *   tap_holds  — top_level declared it for macOS, every row of tap_holds_menu was
 *                restricted to Windows, and no macOS file builds a tap-hold menu
 *                at all. macOS shipped a top-level entry that opened an EMPTY
 *                submenu. The top-level gate could not see it: it reads the macOS
 *                dispatch chain only from `global_actions` onward, and tap_holds
 *                sits above that boundary.
 *   gestures   — unrestricted at the top level, so visible on Linux, while the
 *                manifest projected exactly ONE row of gestures_menu for Linux:
 *                a bare separator. menu_builder.lua has always built a toggle,
 *                both bulk actions and every slot. Same shape of omission as
 *                kanata/updates/apps, one level deeper.
 *   extensions — a section_header with no platforms, introducing a single row
 *                restricted to Windows. macOS and Linux drew the title with
 *                nothing under it.
 *
 * None of the three is a coding mistake. All three are the manifest declaring a
 * shape no driver has, which is exactly what a manifest cannot be trusted to do
 * unless something checks.
 *
 * WHAT IT HOLDS:
 * 1. Every submenu is reachable, and a parent row visible on a platform opens a
 *    submenu with at least one actionable row THERE.
 * 2. No section header is left without a section on any platform.
 * 3. Every divergence between two platforms traces to a `platforms` field on the
 *    diverging row itself — never to a structural accident.
 * 4. Every i18n key the manifest names resolves in all 21 locales, so a label
 *    tree is a tree of labels and not of raw keys.
 * 5. A row narrower than the menu containing it should say why (`reason_key`),
 *    or be declared not applicable there (`unavailable = "hide"`, the
 *    maintainer's classification of 2026-09-30, which owes no reason).
 *    Ratcheted, because 41 predate this gate.
 * 6. The Lua drivers render an ever-growing share of the manifest through the
 *    shared renderer rather than by hand. Ratcheted upward.
 *
 * WHAT IT DELIBERATELY DOES NOT COMPARE:
 * the rows a `list` provider or a `dynamic` handler produces at runtime. Their
 * content is a function of what the user has installed — five hotstring packs on
 * one machine, twelve on another — so comparing it would compare two machines
 * rather than two drivers. Their PRESENCE is compared, which is the part the
 * manifest owns.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { scriptTokens } = require('../lib/script-source.cjs');
const {
	delegatedMenuSources,
	combineMenuVisibility
} = require('../lib/menu-shared-delegation.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const MANIFEST = path.join(SP, '_shared', 'modules', 'menu', 'menu_manifest.json');
const LOCALES = path.join(SP, '_shared', 'data', 'locales');

const PLATFORMS = ['ahk', 'hs', 'linux'];

// Which driver each platform token names. A reader who has to map "hs" to macOS
// themselves reads every failure twice.
const DRIVER_OF = { ahk: 'Windows', hs: 'macOS', linux: 'Linux' };

// Rows that carry no label and cannot be compared by name.
const SEPARATOR = '---';

// Which manifest key each row opens as a submenu. Written out rather than
// derived from the id, because the two disagree often enough (`debug` opens
// `debug_menu`, `keyboard_layout` opens `layout_menu`) that a naming rule would
// be a rule with four exceptions — and a missing entry here would silently make
// a whole submenu unreachable, which is one of the things being checked.
const OPENS_SUBMENU = {
	// The empty native Input Sources provider composes its actual shared command.
	active_layouts: {
		menu: 'layout_active_source_empty_commands',
		platforms: ['hs'],
		kind: 'compose',
		native_sources: { hs: 'macos/ui/menu/menu_keyboard_layout.lua' }
	},
	apps_installed: {
		menu: 'apps_empty_rows',
		platforms: ['hs'],
		kind: 'compose',
		native_sources: { hs: 'macos/ui/menu/menu_apps.lua' }
	},
	system_gesture_status: {
		menu: 'gesture_system_status_controls',
		platforms: ['ahk', 'hs'],
		kind: 'compose',
		native_sources: {
			ahk: 'windows/ui/gesture_conflicts.ahk',
			hs: 'macos/ui/menu/menu_gestures.lua'
		}
	},
	selection_operations: [
		'selection_caps_word_control',
		'selection_case_commands',
		'selection_helper_commands'
	],
	// Every native live-mode provider renders the shared fixed Off choice.
	llm_live_mode: 'llm_live_controls',
	agent_system1: 'agent_system_controls',
	agent_system2: 'agent_system_controls',
	configuration: 'configuration_menu',
	debug: 'debug_menu',
	shortcuts: 'shortcuts_menu',
	// Native wrap providers compose these fixed fragments into their existing picker.
	wrap_symbols_menu: [
		{
			menu: 'wrap_symbols_global_controls',
			platforms: ['ahk', 'hs'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_shortcuts.ahk',
				hs: 'macos/ui/menu/menu_shortcuts.lua'
			}
		},
		{
			menu: 'wrap_symbols_group_controls',
			platforms: ['ahk', 'hs'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_shortcuts.ahk',
				hs: 'macos/ui/menu/menu_shortcuts.lua'
			}
		},
		{
			menu: 'wrap_symbols_custom_separator',
			platforms: ['ahk', 'hs'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_shortcuts.ahk',
				hs: 'macos/ui/menu/menu_shortcuts.lua'
			}
		},
		{
			menu: 'wrap_symbols_custom_controls',
			platforms: ['ahk', 'hs'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_shortcuts.ahk',
				hs: 'macos/ui/menu/menu_shortcuts.lua'
			}
		},
		{
			menu: 'wrap_symbols_add_controls',
			platforms: ['ahk', 'hs'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_shortcuts.ahk',
				hs: 'macos/ui/menu/menu_shortcuts.lua'
			}
		}
	],
	metrics: 'metrics_menu',
	// Its native state branches compose readouts into the existing Metrics menu.
	metrics_migration: ['metrics_migration_unavailable_rows', 'metrics_migration_idle_rows'].map(
		(menu) => ({
			menu,
			platforms: ['linux'],
			kind: 'compose',
			native_sources: { linux: 'linux/ui/menu/menu_builder.lua' }
		})
	),
	keyboard_layout: 'layout_menu',
	number_row_policy: 'number_row_policy_rows',
	hotstrings: 'hotstrings_menu',
	// The personal provider renders the shared editor command head on every driver.
	hotstring_personal: [
		'personal_hotstring_commands',
		'personal_file_controls',
		'personal_file_unavailable',
		'personal_directory_unavailable'
	],
	// Lua category providers build the parent; Windows publishes its child inline.
	hotstring_category_sections: [
		{ menu: 'programmable_hotstring_entry', platforms: ['hs', 'linux'] },
		{ menu: 'programmable_hotstrings', platforms: ['ahk'] }
	],
	programmable_hotstrings: { menu: 'programmable_hotstrings', platforms: ['hs', 'linux'] },
	// Each standard category provider opens the shared explicit command head.
	hotstring_categories_standard: 'hotstring_category_menu',
	gestures: 'gestures_menu',
	gesture_slots_2: [
		{
			menu: 'gesture_swipe_slot_menu',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		},
		{ menu: 'gesture_slot_mode_commands', platforms: ['hs'] },
		{
			menu: 'gesture_sensitivity_head',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		},
		{
			menu: 'gesture_change_action',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		}
	],
	gesture_slots_3: [
		{
			menu: 'gesture_swipe_slot_menu',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		},
		{ menu: 'gesture_slot_mode_commands', platforms: ['hs'] },
		{
			menu: 'gesture_sensitivity_head',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		},
		{
			menu: 'gesture_change_action',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		}
	],
	gesture_slots_4: [
		{
			menu: 'gesture_swipe_slot_menu',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		},
		{ menu: 'gesture_slot_mode_commands', platforms: ['hs'] },
		{
			menu: 'gesture_sensitivity_head',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		},
		{
			menu: 'gesture_change_action',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		}
	],
	gesture_slots_5: [
		{
			menu: 'gesture_swipe_slot_menu',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		},
		{ menu: 'gesture_slot_mode_commands', platforms: ['hs'] },
		{
			menu: 'gesture_sensitivity_head',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		},
		{
			menu: 'gesture_change_action',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
		}
	],
	gesture_mode_options: { menu: 'gesture_slot_mode_commands', platforms: ['hs'] },
	gesture_sensitivity_options: {
		menu: 'gesture_sensitivity_head',
		platforms: ['hs'],
		kind: 'compose',
		native_sources: { hs: 'macos/ui/menu/menu_gestures.lua' }
	},
	tap_holds: [
		'tap_holds_menu',
		{
			menu: 'tap_hold_karabiner_off_rows',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_tap_holds.lua' }
		},
		{
			menu: 'tap_hold_guardian_approval_rows',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_tap_holds.lua' }
		},
		{
			menu: 'tap_hold_guardian_unavailable_rows',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_tap_holds.lua' }
		},
		{
			menu: 'tap_hold_login_items_open_rows',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_tap_holds.lua' }
		},
		{
			menu: 'tap_hold_legacy_rules_rows',
			platforms: ['hs'],
			kind: 'compose',
			native_sources: { hs: 'macos/ui/menu/menu_tap_holds.lua' }
		}
	],
	// Both hand providers render this declared fixed command under every native key.
	tap_hold_keys_left: 'tap_hold_key_rows',
	tap_hold_keys_right: 'tap_hold_key_rows',
	tap_hold_key_delay: 'tap_hold_key_delay_rows',
	key_combinations: 'key_combinations_group',
	// Both drivers render each pair's declaration: Windows opens it at the
	// pointer, while macOS hangs it under the cached pair row.
	key_combination_rows_left: { menu: 'key_combination_pair_menu', platforms: ['ahk', 'hs'] },
	key_combination_rows_right: { menu: 'key_combination_pair_menu', platforms: ['ahk', 'hs'] },
	// « Raccourcis de gestion du script », the script chords of the three drivers.
	script_control: 'script_control_group',
	accented_letters: 'accented_letters_group',
	hotstrings_params: 'hotstrings_params_group',
	word_expanders: 'word_expanders_menu',
	// The native delay providers open the same declared configuration command.
	delays_colors: 'hotstrings_delays_menu',
	// Both Lua preview providers consume the same declared coloured checkbox.
	preview_bubbles: [
		'preview_magic_control',
		'preview_presence_controls',
		'preview_colored_control'
	],
	// Custom entries expose this head nested on Windows/macOS and inline on Linux.
	word_expander_entries: 'word_expander_custom_menu',
	// The model provider publishes its fixed browser command on every driver.
	llm_models: 'llm_model_commands',
	// The backend/model providers render the active API-entry command head.
	llm_backend: 'llm_api_active_commands',
	llm_model: 'llm_api_active_commands',
	// All three profile providers render the shared Create/Clone command head.
	llm_profile: 'llm_profile_commands',
	// Optional category-file providers return this declared opening command.
	hotstring_category_file: 'hotstring_file_commands',
	llm_display: 'llm_display_menu',
	// Native prediction modifier providers consume the shared child records.
	llm_navigation: 'llm_navigation_rows',
	llm_trigger: 'llm_trigger_menu',
	llm_generation_settings: 'llm_generation_menu',
	// Linux uses the same generation child inline, through its dynamic handler.
	llm_generation: 'llm_generation_menu',
	// The language selector. Its rows inherit `top_level/language`'s visibility,
	// which is every driver — the DECLARATION is narrower than that, and says why
	// in its own reason_key rather than through this map.
	language: 'language_menu',
	// The Applications submenu. Its rows inherit `top_level/apps`'s visibility —
	// macOS and Linux — and each declaration inside is narrower than that, for the
	// reason each carries.
	apps: 'apps_menu',
	// The About submenu, declared 2026-08-07. Visible on all three, with the same
	// rows: Linux folded its top-level Updates submenu into it in 2026-09.
	about: 'about_menu',
	// The About updater provider renders the registry-backed channel choice.
	about_updates: [
		'about_update_channel_menu',
		'about_update_frequency_menu',
		'about_source_menu',
		{
			menu: 'about_version_separator',
			platforms: ['ahk', 'hs', 'linux'],
			kind: 'compose',
			native_sources: {
				ahk: 'windows/ui/menu/menu_init.ahk',
				hs: 'macos/ui/menu/menu_about.lua',
				linux: 'linux/ui/menu/menu_builder.lua'
			}
		}
	],
	// The LLM submenu, which had no manifest tree at all until 2026-08-06: the
	// top-level row has existed on all three drivers since the feature shipped
	// and each built the submenu beneath it by hand, so the section and its six
	// subsections described capabilities with no rows behind them.
	llm: 'llm_menu',
	// The AI agent submenu (_shared/modules/llm/agent.json), on every driver.
	agent: 'agent_menu'
};

/**
 * The native personal provider must actually consume its declared command head.
 * A graph edge alone would conceal a provider that stopped rendering the row.
 * @param {string} text Native provider source.
 * @param {string} driver Host source syntax.
 * @returns {boolean}
 */
function personalCommandReference(text, driver) {
	const method = driver === 'windows' ? 'MenuRenderer_CommandRow' : 'ManifestMenu\\.command_row';
	return new RegExp(
		method + '\\(\\s*"personal_hotstring_commands"\\s*,\\s*"personal_hotstring_open_editor"\\s*,'
	).test(text.replace(/^\s*(?:;|--).*$/gm, ''));
}

// Independent call shapes also reject the right command under the wrong head.
for (const [driver, method] of [
	['windows', 'MenuRenderer_CommandRow'],
	['macos', 'ManifestMenu.command_row'],
	['linux', 'ManifestMenu.command_row']
]) {
	const call = `${method}("personal_hotstring_commands", "personal_hotstring_open_editor", commands)`;
	if (!personalCommandReference(call, driver))
		throw new Error(`Missed ${driver} command reference.`);
	for (const broken of [
		call.replace('personal_hotstring_commands', 'another_menu'),
		call.replace('personal_hotstring_open_editor', 'another_command'),
		call.replace(method, 'UnownedCommandRow'),
		(driver === 'windows' ? '; ' : '-- ') + call
	]) {
		if (personalCommandReference(broken, driver))
			throw new Error(`Admitted broken ${driver} reference.`);
	}
}

const errors = [];

const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
const MENU_KEYS = Object.keys(manifest).filter((k) => Array.isArray(manifest[k]));

for (const [driver, relative] of [
	['windows', 'windows/ui/menu/menu_hotstrings.ahk'],
	['macos', 'macos/ui/menu/menu_hotstrings_custom.lua'],
	['linux', 'linux/ui/menu/menu_builder.lua']
]) {
	if (!personalCommandReference(fs.readFileSync(path.join(SP, relative), 'utf8'), driver))
		errors.push(
			`${driver}: the personal provider no longer renders its shared editor command head.`
		);
}

// Floors. A parse that silently yielded nothing would make every comparison
// below vacuously true, and the suite would go green on an empty menu.
if (MENU_KEYS.length < 10) {
	errors.push(
		`the manifest declares ${MENU_KEYS.length} menu(s) — expected at least 10. The parse is broken ` +
			'and every check below is vacuous.'
	);
}

// ==================================================
// ==================================================
// ======= 1/ Projecting the manifest ===============
// ==================================================
// ==================================================

/**
 * Whether a row is visible on a platform.
 *
 * A row with no `platforms` is visible everywhere. That default is what makes an
 * UNDECLARED difference impossible to express, and therefore makes any difference
 * this gate finds a real one.
 * @param {object} row The manifest row.
 * @param {string} platform "ahk", "hs" or "linux".
 * @returns {boolean}
 */
function visibleOn(row, platform) {
	if (!row || typeof row !== 'object') return false;
	if (!Array.isArray(row.platforms)) return true;
	return row.platforms.includes(platform);
}

/**
 * Whether a row is a separator.
 *
 * Two spellings, both live: the submenus carry `type = "---"`, while top_level
 * and debug_menu carry bare `{ id = "---" }` rows with no type at all. Reading
 * only one of the two made every top-level separator look like an actionable row
 * with a duplicate identity.
 * @param {object} row The manifest row.
 * @returns {boolean}
 */
function isSeparator(row) {
	return row.type === SEPARATOR || row.id === SEPARATOR;
}

/**
 * The identity of a row: what makes it THIS row rather than another.
 *
 * Type plus whatever the row is keyed by, not the rendered label. A row that
 * changed id while keeping its label is a different row wired to a different
 * handler, and comparing labels alone would call the two equal. `feature` rows
 * have no id at all — they are keyed by the manifest `path` they toggle — so
 * leaving that out collapsed every feature row in a menu onto one identity.
 * @param {object} row The manifest row.
 * @returns {string}
 */
function identityOf(row) {
	const parts = [row.type || 'ref'];
	if (row.id) parts.push(`#${row.id}`);
	if (row.path) parts.push(`:${row.path}`);
	const key = row.i18n || row.category;
	if (key) parts.push(`@${key}`);
	return parts.join(' ');
}

/**
 * The rows of one menu visible on one platform, in manifest order.
 * @param {string} menuKey A manifest array key.
 * @param {string} platform "ahk", "hs" or "linux".
 * @returns {object[]}
 */
function project(menuKey, platform, visiting = new Set()) {
	if (visiting.has(menuKey)) throw new Error(`cyclic menu include: ${menuKey}`);
	if (!Array.isArray(manifest[menuKey])) throw new Error(`missing menu include: ${menuKey}`);
	visiting.add(menuKey);
	const rows = [];
	for (const row of manifest[menuKey] || []) {
		if (!visibleOn(row, platform)) continue;
		if (row.type === 'include') rows.push(...project(row.section, platform, visiting));
		else rows.push(row);
	}
	visiting.delete(menuKey);
	return rows;
}

// Includes are transparent: hidden tails add no clickable row, while a
// duplicated included command still has the same actionable identity.
{
	const assert = require('node:assert/strict');
	const root = manifest.tap_hold_key_rows;
	assert.equal(project('tap_hold_key_rows', 'ahk').length, 5);
	assert.equal(project('tap_hold_key_rows', 'hs').length, 6);
	assert.equal(project('tap_hold_key_rows', 'linux').length, 5);
	const original = root.slice();
	try {
		root.push({ type: 'include', section: 'tap_hold_key_head' });
		const identities = actionable('tap_hold_key_rows', 'ahk').map(identityOf);
		assert(
			identities.length > new Set(identities).size,
			'nested duplicate commands remain detectable'
		);
		root.splice(0, root.length, { type: 'include', section: 'tap_hold_key_rows' });
		assert.throws(() => project('tap_hold_key_rows', 'ahk'), /cyclic menu include/);
		root.splice(0, root.length, { type: 'include', section: 'absent_child_template' });
		assert.throws(() => project('tap_hold_key_rows', 'ahk'), /missing menu include/);
	} finally {
		root.splice(0, root.length, ...original);
	}
}

/**
 * The rows a user can actually act on: everything that is not a separator.
 * @param {string} menuKey A manifest array key.
 * @param {string} platform "ahk", "hs" or "linux".
 * @returns {object[]}
 */
function actionable(menuKey, platform) {
	return project(menuKey, platform).filter(
		(row) => !isSeparator(row) && !['label', 'section_header'].includes(row.type)
	);
}

// ==================================================
// ==================================================
// ======= 2/ The submenu graph =====================
// ==================================================
// ==================================================

// Where each menu can be reached from, and on which platforms — a submenu is
// only as visible as the row that opens it. `tap_holds_menu` restricted to
// Windows is not a Windows-only menu by its own rows; it is one because the row
// opening it says so, and its children inherit that without repeating it.
const reachableOn = { top_level: PLATFORMS.slice() };
const openedBy = {};
const reachedByKinds = {};

/** Distinguishes actual composed readouts from a clicked, empty submenu. */
function isComposedFragment(rows, kinds) {
	if (kinds.size !== 1 || !kinds.has('compose') || rows.length === 0) return false;
	return rows.every((row) => {
		if (row.type === SEPARATOR)
			return Object.keys(row).every((key) => ['type', 'platforms', 'unavailable'].includes(key));
		return (
			['label', 'section_header'].includes(row.type) &&
			typeof row.id === 'string' &&
			row.id !== '' &&
			typeof row.i18n === 'string' &&
			row.i18n !== '' &&
			Object.keys(row).every((key) =>
				['type', 'id', 'i18n', 'platforms', 'unavailable'].includes(key)
			)
		);
	});
}

const { publishesMenuTemplate: publishesTemplate } = require('../lib/menu-shared-delegation.cjs');

// An inert readout is admissible only through composition. A clicked parent,
// including one sharing the same target, still owes a usable child on that OS.
const readout = { type: 'label', id: 'readout', i18n: 'menu.metrics.status' };
const separator = { type: SEPARATOR };
const header = { type: 'section_header', id: 'readout_header', i18n: 'menu.metrics.status' };
for (const rows of [
	[readout],
	[separator],
	[readout, separator],
	[header],
	[header, readout, separator]
]) {
	if (!isComposedFragment(rows, new Set(['compose'])))
		throw new Error('Rejected a declared composed readout.');
	for (const kinds of [new Set(), new Set(['submenu']), new Set(['compose', 'submenu'])]) {
		if (isComposedFragment(rows, kinds)) throw new Error('Accepted an empty clicked submenu.');
	}
}
for (const rows of [
	[],
	[{ ...readout, callback: 'invoke' }],
	[{ ...readout, id: '' }],
	[{ ...readout, i18n: '' }],
	[{ type: 'check', id: 'readout', i18n: 'menu.metrics.status' }],
	[{ ...separator, id: 'command' }],
	[{ ...header, children: [] }],
	[{ ...header, callback: 'invoke' }],
	[{ ...header, caption_getter: 'read' }],
	[{ ...header, id: '' }],
	[readout, { type: 'section_header', i18n: 'menu.metrics.status' }]
]) {
	if (isComposedFragment(rows, new Set(['compose'])))
		throw new Error('Accepted an undeclared composed readout shape.');
}
const platformKinds = { linux: new Set(['compose']), ahk: new Set(['submenu']) };
if (
	!isComposedFragment([readout], platformKinds.linux) ||
	isComposedFragment([readout], platformKinds.ahk)
)
	throw new Error('Composition leaked across platform projections.');
for (const [extension, method, comment] of [
	['.lua', 'ManifestMenu.template_rows', '-- '],
	['.ahk', 'MenuRenderer_TemplateRows', '; ']
]) {
	const call = `${method}("declared_readout", options)`;
	if (!publishesTemplate(call, extension, 'declared_readout'))
		throw new Error(`Missed executable ${extension} template publication.`);
	for (const source of [
		comment + call,
		JSON.stringify(call),
		call.replace('declared_readout', 'another_readout'),
		call.replace(method, 'Unowned.template_rows'),
		'Foreign.' + call,
		'Foreign:' + call,
		call.replace('"declared_readout"', '"declared_readout" .. suffix'),
		`function ${call}`
	]) {
		if (publishesTemplate(source, extension, 'declared_readout'))
			throw new Error(`Credited non-publication ${extension} template evidence.`);
	}
}

// Iterated to a fixed point rather than walked once: the graph is shallow today
// but a group nested inside a group would make a single pass depth-dependent,
// and a check that silently depends on declaration order is a check that breaks
// on an unrelated edit.
for (let pass = 0; pass < MENU_KEYS.length + 1; pass += 1) {
	let changed = false;
	for (const menuKey of MENU_KEYS) {
		const parentVisibility = reachableOn[menuKey];
		if (!parentVisibility) continue;
		for (const row of manifest[menuKey]) {
			const published = row.type === 'include' ? row.section : OPENS_SUBMENU[row.id];
			if (!published) continue;
			// One provider can publish multiple independently declared children.
			// Every existing platform restriction still applies to its own edge.
			for (const opened of Array.isArray(published) ? published : [published]) {
				const target = typeof opened === 'string' ? opened : opened.menu;
				const only = typeof opened === 'string' ? PLATFORMS : opened.platforms;
				const kind = row.type === 'include' || opened.kind === 'compose' ? 'compose' : 'submenu';
				const effective = PLATFORMS.filter(
					(p) =>
						visibleOn(row, p) &&
						parentVisibility.includes(p) &&
						only.includes(p) &&
						(row.type !== 'include' || project(target, p).length > 0)
				);
				for (const platform of effective) {
					if (!reachedByKinds[target]) reachedByKinds[target] = {};
					if (!reachedByKinds[target][platform]) reachedByKinds[target][platform] = new Set();
					reachedByKinds[target][platform].add(kind);
					if (kind !== 'compose' || row.type === 'include') continue;
					const file = opened.native_sources?.[platform];
					const driver = { ahk: 'windows', hs: 'macos', linux: 'linux' }[platform];
					if (
						typeof file !== 'string' ||
						!file.startsWith(driver + '/') ||
						!publishesTemplate(
							fs.readFileSync(path.join(SP, file), 'utf8'),
							path.extname(file),
							target
						)
					)
						errors.push(
							`${menuKey}/${row.id}: composed ${target} has no native template publication on ${platform}`
						);
				}
				const before = (reachableOn[target] || []).join(',');
				const combined = combineMenuVisibility(PLATFORMS, reachableOn[target], effective);
				if (before !== combined.join(',')) {
					reachableOn[target] = combined;
					changed = true;
				}
				openedBy[target] = `${menuKey}/${row.id}`;
			}
		}
	}
	if (!changed) break;
}

for (const menuKey of MENU_KEYS) {
	if (reachableOn[menuKey]) continue;
	errors.push(
		`the manifest declares the menu "${menuKey}" and no row anywhere opens it. Either a row lost its ` +
			`id, or the menu is dead data every gate still counts. If it is opened by a row this gate does ` +
			'not know about, add it to OPENS_SUBMENU — an unmapped parent makes the whole submenu invisible ' +
			'to every check below.'
	);
}

// A parent row a user can click, opening a submenu with nothing in it. This is
// the shape all three of the defects in the header took.
for (const menuKey of MENU_KEYS) {
	const visibility = reachableOn[menuKey];
	if (!visibility || menuKey === 'top_level') continue;
	for (const platform of visibility) {
		if (actionable(menuKey, platform).length > 0) continue;
		if (
			isComposedFragment(
				project(menuKey, platform),
				reachedByKinds[menuKey]?.[platform] || new Set()
			)
		)
			continue;
		errors.push(
			`${DRIVER_OF[platform]}: "${openedBy[menuKey]}" is visible, and the "${menuKey}" it opens ` +
				`projects no actionable row for ${DRIVER_OF[platform]} — the user clicks an entry and gets an ` +
				'empty menu. Either restrict the row that opens it, or widen the rows inside it to the ' +
				'platform that already shows the parent.'
		);
	}
}

// ==================================================
// ==================================================
// ======= 3/ No heading without a section ==========
// ==================================================
// ==================================================

// A section_header is a disabled row whose whole purpose is to introduce the
// rows beneath it. When its content is restricted and the header is not, the
// header survives alone and reads to the user as a section the driver failed to
// fill. Cheaper to check than to explain in a bug report.
for (const menuKey of MENU_KEYS) {
	const visibility = reachableOn[menuKey] || PLATFORMS;
	for (const platform of visibility) {
		const rows = project(menuKey, platform);
		rows.forEach((row, index) => {
			if ((row.type || 'ref') !== 'section_header') return;
			let under = 0;
			for (let j = index + 1; j < rows.length; j += 1) {
				const type = rows[j].type || 'ref';
				if (type === 'section_header' || type === SEPARATOR) break;
				under += 1;
			}
			if (under > 0) return;
			errors.push(
				`${DRIVER_OF[platform]}: the header "${row.i18n}" in ${menuKey} introduces nothing — every ` +
					`row it heads is restricted away from ${DRIVER_OF[platform]}. Restrict the header with its ` +
					'content.'
			);
		});
	}
}

// ==================================================
// ==================================================
// ======= 4/ Every divergence is declared ==========
// ==================================================
// ==================================================

// NOT CHECKED HERE, deliberately: that the shared rows appear in the same ORDER
// on two platforms. One manifest array per menu means the order is a single list
// filtered three ways, so the three projections are subsequences of one sequence
// and cannot disagree. A first draft of this gate checked it anyway; mutating a
// row to a different position left it green, because moving the row moves it for
// all three at once. A check that cannot fail is worse than no check — it reads
// as protection.
//
// What CAN diverge is a row appearing twice under one identity: two entries the
// user cannot tell apart, and one handler lookup that resolves to the first. That
// is what found `feature` rows being keyed by `path` rather than by `id`.
let comparedRows = 0;

for (const menuKey of MENU_KEYS) {
	comparedRows += actionable(menuKey, PLATFORMS[0]).length;
}

if (comparedRows === 0) {
	errors.push(
		'no rows were compared — the projection is broken, not the tree. A comparison that silently ' +
			'examines nothing is the exact failure this gate exists to prevent.'
	);
}

// Duplicate identities inside one menu: two rows the user cannot tell apart and
// that every id-keyed handler lookup resolves to the same branch.
for (const menuKey of MENU_KEYS) {
	for (const platform of reachableOn[menuKey] || PLATFORMS) {
		const seen = new Set();
		for (const row of actionable(menuKey, platform)) {
			const id = identityOf(row);
			if (seen.has(id)) {
				errors.push(
					`${menuKey}: "${id}" appears twice for ${DRIVER_OF[platform]}. Two rows with one identity ` +
						'means one handler and two entries, and the second is unreachable.'
				);
			}
			seen.add(id);
		}
	}
}

// ==================================================
// ==================================================
// ======= 5/ Every label resolves ==================
// ==================================================
// ==================================================

// A menu row whose key is missing from a locale renders the raw key. Checked in
// every shipped locale rather than in the reference one, because the reference
// is the one that never has the gap. `disabled_reason_key` is why
// `disabled_when` greys a row, which the greyed row shows.
const LABEL_FIELDS = ['i18n', 'reason_key', 'disabled_reason_key'];

const namedKeys = [];
for (const menuKey of MENU_KEYS) {
	for (const row of manifest[menuKey]) {
		for (const field of LABEL_FIELDS) {
			if (typeof row[field] === 'string') namedKeys.push({ menuKey, row, field, key: row[field] });
		}
	}
}

const localeFiles = fs.readdirSync(LOCALES).filter((f) => f.endsWith('.json'));
if (localeFiles.length < 15) {
	errors.push(
		`read ${localeFiles.length} locale file(s) — the scan is broken, so nothing below is checked`
	);
}

for (const file of localeFiles) {
	const table = JSON.parse(fs.readFileSync(path.join(LOCALES, file), 'utf8'));
	for (const entry of namedKeys) {
		if (table[entry.key] !== undefined) continue;
		errors.push(
			`${file}: "${entry.key}" (${entry.menuKey}, ${entry.field}) has no translation — the menu will ` +
				'show the key itself to every user of that language.'
		);
	}
}

// ==================================================
// ==================================================
// ======= 6/ A hidden row says why =================
// ==================================================
// ==================================================

// Only rows narrower than the menu holding them are counted. A row inside
// tap_holds_menu need not repeat "Windows only" — the row that opens the menu
// already carries it, and demanding the reason on all five children turns a real
// signal into noise nobody reads.
const unreasoned = [];
for (const menuKey of MENU_KEYS) {
	const parentVisibility = reachableOn[menuKey] || PLATFORMS;
	for (const row of manifest[menuKey]) {
		if ((row.type || 'ref') === SEPARATOR) continue;
		if (isSeparator(row)) continue;
		const own = Array.isArray(row.platforms) ? row.platforms : PLATFORMS;
		const narrower = parentVisibility.filter((p) => !own.includes(p));
		if (narrower.length === 0 || row.reason_key || row.unavailable === 'hide') continue;
		unreasoned.push(
			`${menuKey}/${row.id || row.i18n || row.category || row.type} hidden on ` +
				`${narrower.map((p) => DRIVER_OF[p]).join(', ')}`
		);
	}
}

// Frozen at the measurement of 2026-08-04. Convention S wants the row present
// and greyed with its reason rather than absent, and these rows predate that;
// making them all red at once would mean this gate could only land by being
// silenced. It may fall, never rise:
//   41 → 40 when hotstring_extensions stopped claiming to be Windows-only
//   40 → 39 when repeat_key did the same. macOS had shipped both the engine and
//        the toggle all along, so the restriction recorded who wrote it first
//        rather than what the platforms can do; Linux now has it too.
//   39 → 37 on 2026-08-06 when the floating WPM widget and its colour toggle
//        stopped being Windows-and-macOS-only. Same story a third time: the
//        restriction was true when written — that driver had no floating widget
//        at all — and stopped being true when linux/ui/wpm/widget.lua drew one on
//        the GTK surface the preview bubble already uses.
//   37 → 36 on 2026-08-06 when wrap_symbols_menu stopped claiming to be
//        Windows-only. macOS and Linux had both been drawing the picker the
//        whole time, in a different position each; it is one shared row now.
// 36 → 0 on 2026-08-07. Every row narrower than the menu it sits in now says
// why, in twenty-one languages, and two of the thirty-six turned out not to need
// a reason at all: the metrics and gestures category toggles were restricted to
// platforms that were not the only ones drawing them — Windows builds both, from
// these very keys — so the honest fix was to widen the declaration rather than
// to explain a divergence that did not exist.
//
// This is now a HARD ZERO, not a ratchet with room in it. A new row hidden from
// a platform its menu is visible on fails this gate until it states its reason;
// the user of that driver can otherwise not tell "not supported here" from
// "forgotten".
const UNREASONED_BASELINE = 0;

if (process.argv.includes('--list-unreasoned')) {
	for (const u of unreasoned) console.log('  ' + u);
}
if (unreasoned.length > UNREASONED_BASELINE) {
	errors.push(
		`${unreasoned.length} row(s) are hidden from a platform their menu is visible on, with no ` +
			`reason_key (baseline ${UNREASONED_BASELINE}). The user of that driver cannot tell "not ` +
			`implemented here" from "removed":\n      ` +
			unreasoned.slice(UNREASONED_BASELINE).join('\n      ')
	);
}
if (unreasoned.length < UNREASONED_BASELINE) {
	errors.push(
		`only ${unreasoned.length} unreasoned hidden row(s) remain (baseline ${UNREASONED_BASELINE}) — ` +
			'lower the baseline in this file to lock the improvement in.'
	);
}

// ==================================================
// ==================================================
// ======= 7/ The drivers render it, not retype it ==
// ==================================================
// ==================================================

// The point of a manifest is that the menu exists once. Both Lua drivers bind
// the same shared renderer through infra/manifest_menu, so the number of menu
// keys each one passes to it is a direct measure of how much of its menu is
// still hand-built. Windows is excluded: its AHK loader exposes one function per
// key (MenuManifest_LoadDebugMenu and friends) instead of taking the key as an
// argument, so the same count would mean something different there.
// linux raised 4 → 5 on 2026-08-05: the shortcuts submenu now dispatches through
// the renderer. That is what let `extensions_shortcuts` lose its platforms =
// ["ahk"] restriction — the manifest had refused to promise a row to a menu that
// could not answer by id, and both Lua drivers had implemented the row for
// months while the manifest said neither had the concept.
// linux raised 5 → 7 on 2026-08-05: the kanata and updates submenus became the
// first blocks of menu_builder.lua whose rows the renderer MATERIALISES, through
// `list` providers. Routing a menu through the renderer and moving its rows out of the
// driver are two different things, and only the second one moves the bypass
// ratchet — this number counts the first.
// linux raised 8 → 9 on 2026-08-06: the debug submenu. It had never read the
// manifest at all — it wrote out three rows while the manifest declared five for
// this platform, so `open_today_log` and `open_error_log` were described, offered
// on the other two drivers and translated in all 21 locales, and simply absent
// here. A driver that does not READ a manifest section cannot notice a row it
// fails to build, which is why "is this menu on the renderer" is worth counting
// separately from "how many of its rows the renderer materialises".
// hs raised 4 → 5 on 2026-08-06: the Karabiner submenu, the largest hand-built
// menu in the project at thirty-six rows and the last one with NOTHING in the
// manifest describing it. Its shape is declared now — process control, the
// destructive resets, the timings, then tap-holds and chords under headers of
// their own — which is also the split the maintainer asked for: the two families
// used to run together under one heading.
// hs raised 5 → 6: the keyboard-layout menu. It renders the manifest's own
// rows now — the section header, its separators, and the active-layouts list
// that was declared for macOS and answered by nobody.
// hs raised 6 → 7: the LLM menu. Its two declared rows — the model picker and
// the generation settings — were built in place, and the separator the manifest
// puts between them was written out by hand as well.
// linux raised 9 → 10 on 2026-08-06: the global-actions submenu. Its three rows
// AND the separator between them were written out by each driver — macOS through
// a chain of `elseif` mapping id → label → action, which was the manifest's own
// table restated in a third language. macOS raised 7 → 8 in the same change,
// for the same menu.
// hs 8 → 9 on 2026-08-07: the hotstrings submenu. It was the last macOS menu
// that read the manifest for nothing at all — the drift gate in
// tests/meta/test_menu_hotstrings_layout_drift_gate.lua exists solely because
// this menu and its declaration could disagree with nothing comparing them.
// hs 9 → 10, linux 10 → 11 on 2026-08-07: the language selector. Three drivers
// listed the same twenty-one locales from the same shared catalogue into a menu
// nothing described.
// hs 10 → 11, linux 11 → 12 on 2026-08-07: the Applications submenu, which had
// no declaration at all and holds different things on the two drivers that have
// it — said out loud now, with the reason attached.
// linux 12 → 13 on 2026-08-07: the layout submenu, the last one this driver did
// not read the manifest for. Its rows came from two names written into the
// builder while the decoder already owned the list.
// hs 11 → 12, linux 13 → 14 on 2026-08-07: the About submenu, which the three
// drivers assembled independently and none declared.
// hs 12 → 13 on 2026-08-07: the debug submenu. It iterated the manifest's own
// debug_menu array and then wrote the label for each id by hand, in a chain of
// `elseif` — so the declaration decided the order and this driver decided
// everything else. Linux has rendered it since 2026-08-06 and Windows since this
// morning; macOS was the last of the three to still spell it out.
// linux 14 → 13, and no loss: its Applications submenu is gone. It held one
// row, the config folder, which moved to the Configuration submenu the three
// drivers render (global_actions became configuration_menu on all of them).
// linux 13 → 12 in 2026-09: the Updates submenu folded into About (about_menu
// renders the same rows on all three drivers), so one menu key went away
// without any row leaving the renderer.
// hs 14 → 15: the « Combinaisons de touches » group under Shortcuts
// (key_combinations_group) renders the Karabiner chords through the renderer.
// hs 15 → 16, linux 13 → 14: « Raccourcis de gestion du script »
// (script_control_group), the script chords the three drivers share.
// hs 16 → 17: every ordered pair reads key_combination_pair_menu; only its
// native slot picker data stays in the driver.
// Explicit hotstring category commands and section lists now have one shared head.
// The three Word Expander controls now share one declared child menu.
// The common AI Info Bar check delegates to a shared display child menu.
// Linux 19 → 20: navigation and validation now use their declared list providers.
const RENDERED_THROUGH_SHARED = { hs: 22, linux: 20 };

const DRIVER_ROOTS = { hs: path.join(SP, 'macos'), linux: path.join(SP, 'linux') };

/**
 * The whole Lua source of a driver, concatenated, tests excluded.
 * @param {string} root Absolute path to the driver tree.
 * @returns {string}
 */
function driverSource(root) {
	let out = '';
	const sources = [];
	const walk = (dir) => {
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			const full = path.join(dir, entry.name);
			if (entry.isDirectory()) {
				if (entry.name === 'tests' || entry.name === '_generated') continue;
				walk(full);
			} else if (entry.name.endsWith('.lua')) {
				const src = fs.readFileSync(full, 'utf8');
				out += src;
				sources.push({ rel: path.relative(root, full), src });
			}
		}
	};
	walk(root);
	return { src: out, delegated: delegatedMenuSources(sources, path.join(SP, '_shared', 'lua')) };
}

/** Resolve only the actual read-only number-row provider's shared getter owner. */
function numberRowGetterSource(source) {
	const { scriptTokens } = require('../lib/script-source.cjs');
	const contains = (text, expected) => {
		const tokens = scriptTokens(text, '.lua').map((token) => `${token.kind}:${token.value}`);
		return tokens.some((_, index) =>
			expected.every((value, offset) => tokens[index + offset] === value)
		);
	};
	if (
		!contains(source, [
			'identifier:local',
			'identifier:NumberRowPolicy',
			'symbol:=',
			'identifier:require',
			'symbol:(',
			'string:layout.number_row_policy',
			'symbol:)'
		]) ||
		!contains(source, [
			'identifier:NumberRowPolicy',
			'symbol:.',
			'identifier:native_rows',
			'symbol:(',
			'identifier:ManifestMenu',
			'symbol:,',
			'identifier:render_ctx',
			'symbol:.',
			'identifier:commands',
			'symbol:)'
		])
	)
		return '';
	if (
		!contains(source, [
			'identifier:render_ctx',
			'symbol:.',
			'identifier:commands',
			'symbol:[',
			'string:number_row_mode',
			'symbol:]',
			'symbol:=',
			'identifier:function',
			'symbol:(',
			'symbol:)',
			'identifier:return',
			'identifier:false',
			'identifier:end'
		])
	)
		return '';
	const sharedSource = fs.readFileSync(
		path.join(SP, '_shared/lua/layout/number_row_policy.lua'),
		'utf8'
	);
	if (
		!contains(sharedSource, [
			'identifier:function',
			'identifier:M',
			'symbol:.',
			'identifier:native_rows',
			'symbol:(',
			'identifier:renderer',
			'symbol:,',
			'identifier:commands',
			'symbol:)'
		]) ||
		!contains(sharedSource, [
			'identifier:renderer',
			'symbol:.',
			'identifier:choice_row',
			'symbol:(',
			'string:number_row_policy_rows',
			'symbol:,',
			'string:number_row_mode',
			'symbol:,',
			'identifier:commands',
			'symbol:,'
		]) ||
		!contains(sharedSource, [
			'symbol:[',
			'string:layout.direct_access_digits',
			'symbol:]',
			'symbol:=',
			'identifier:function',
			'symbol:(',
			'symbol:)',
			'identifier:return',
			'string:native',
			'identifier:end'
		])
	)
		return '';
	return sharedSource;
}

// Independent literal controls pin the new dependency boundary without changing
// any existing getter checks or menu floors. Comments and quoted code are inert.
{
	const assert = require('node:assert/strict');
	const binding = 'local NumberRowPolicy = require("layout.number_row_policy")';
	const call = 'NumberRowPolicy.native_rows(ManifestMenu, render_ctx.commands)';
	const command = 'render_ctx.commands["number_row_mode"] = function() return false end';
	assert(
		numberRowGetterSource(binding + '\n' + command + '\n' + call).includes(
			'layout.direct_access_digits'
		)
	);
	for (const source of [
		binding,
		call,
		binding + '\n' + call,
		binding + '\n' + command.replace('return false', 'return true') + '\n' + call,
		binding + '\n' + command + '\n' + call.replace('render_ctx.commands', 'other_commands'),
		'-- ' + binding + '\n' + call,
		binding + '\n-- ' + call,
		'local x = [[' + binding + '\n' + call + ']]',
		binding.replace('number_row_policy', 'other_policy') + '\n' + call,
		binding + '\n' + call.replace('ManifestMenu', 'OtherRenderer')
	]) {
		assert.equal(
			numberRowGetterSource(source),
			'',
			'a missing actual shared port cannot borrow its getter'
		);
	}
}

const renderedCounts = {};
for (const [driver, root] of Object.entries(DRIVER_ROOTS)) {
	const { src, delegated } = driverSource(root);
	const keys = new Set([...src.matchAll(/ManifestMenu\.build\(\s*"([a-z_]+)"/g)].map((m) => m[1]));
	renderedCounts[driver] = keys.size;

	// A disabled_when / checked_when key with no getter is not a row that stays
	// enabled: resolve_*_when logs an ERROR and returns the SAFE value, so the row
	// silently greys out or silently never ticks. macOS was missing all three
	// metrics_filter_* getters on 2026-08-04 — it read `state.…` inline instead, so
	// the manifest's checked_when was a second declaration nothing consulted, and
	// Linux resolved the same three through the manifest. Two drivers, two answers
	// to where the truth lives, which is the one thing a manifest exists to prevent.
	const needed = new Set();
	for (const menuKey of MENU_KEYS) {
		for (const row of manifest[menuKey]) {
			if (!visibleOn(row, driver)) continue;
			for (const field of ['disabled_when', 'checked_when']) {
				if (Array.isArray(row[field])) for (const key of row[field]) needed.add(key);
			}
			// A choice row ticks the value its driver answers under the feature path.
			if (row.type === 'choice' && typeof row.path === 'string') needed.add(row.path);
		}
	}
	const getterSource =
		src + numberRowGetterSource(src) + delegated.map((source) => source.src).join('\n');
	const absent = [...needed].filter((key) => !getterSource.includes(key));
	if (absent.length > 0) {
		errors.push(
			`${DRIVER_OF[driver]} names no getter for ${absent.length} state key(s) the manifest requires ` +
				`for rows it renders: ${absent.join(', ')}. The resolver logs an error and falls back, so ` +
				'the row is wrong in the menu and right in the manifest.'
		);
	}
	const floor = RENDERED_THROUGH_SHARED[driver];
	if (keys.size < floor) {
		errors.push(
			`${DRIVER_OF[driver]} renders ${keys.size} menu(s) through the shared renderer, down from ` +
				`${floor}. A menu that stops going through the manifest is a menu that starts drifting from ` +
				`the other two. Rendered: ${[...keys].sort().join(', ') || '(none)'}.`
		);
	}
	if (keys.size > floor) {
		errors.push(
			`${DRIVER_OF[driver]} now renders ${keys.size} menu(s) through the shared renderer (baseline ` +
				`${floor}) — raise the baseline in this file so the gain cannot be lost again. Rendered: ` +
				`${[...keys].sort().join(', ')}.`
		);
	}
}

// Startup is an installation action on every driver, immediately above removal.
// Pin its unique shared declaration so neither Configuration nor a native builder
// can silently restore the previous placement.
for (const platform of PLATFORMS) {
	const about = project('about_menu', platform);
	const startup = about[about.length - 2];
	const uninstall = about[about.length - 1];
	if (
		startup?.id !== 'start_at_login' ||
		startup.type !== 'check' ||
		startup.i18n !== 'menu.global.start_at_login' ||
		JSON.stringify(startup.checked_when) !== JSON.stringify(['start_at_login_enabled']) ||
		uninstall?.id !== 'uninstall' ||
		!isSeparator(about[about.length - 3])
	) {
		errors.push(
			`${DRIVER_OF[platform]} must draw the native startup check immediately above Uninstall.`
		);
	}
	const owners = MENU_KEYS.filter((key) =>
		project(key, platform).some((row) => row.id === 'start_at_login')
	);
	if (owners.length !== 1 || owners[0] !== 'about_menu') {
		errors.push(
			`${DRIVER_OF[platform]} startup must appear once, in Updates: ${owners.join(', ') || '(absent)'}.`
		);
	}
}

// ==================================================
// ==================================================
// ======= 8/ Report ================================
// ==================================================
// ==================================================

if (process.argv.includes('--measure')) {
	console.log(`menus: ${MENU_KEYS.length}`);
	for (const menuKey of MENU_KEYS) {
		const counts = PLATFORMS.map((p) => `${p}=${project(menuKey, p).length}`).join(' ');
		console.log(
			`  ${menuKey.padEnd(24)} ${counts}   reachable on: ${(reachableOn[menuKey] || []).join(',')}`
		);
	}
	console.log(`unreasoned hidden rows: ${unreasoned.length}`);
	console.log(`rendered through the shared renderer: ${JSON.stringify(renderedCounts)}`);
	process.exit(0);
}

if (errors.length > 0) {
	console.error(
		'\x1b[31m[FAIL] the three menus differ in ways the manifest does not declare:\x1b[0m'
	);
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] menu parity — ${MENU_KEYS.length} menus, ${comparedRows} row(s) projected for Windows; ` +
		`every submenu reachable and non-empty where its parent is visible, no orphaned header, no row ` +
		`duplicated under one identity, ${namedKeys.length} label key(s) resolved in ${localeFiles.length} ` +
		`locales, every disabled_when/checked_when getter present; ` +
		`${unreasoned.length} hidden row(s) still unreasoned (baseline ${UNREASONED_BASELINE}); shared ` +
		`renderer covers macOS ${renderedCounts.hs}, Linux ${renderedCounts.linux} menu(s).\x1b[0m`
);
