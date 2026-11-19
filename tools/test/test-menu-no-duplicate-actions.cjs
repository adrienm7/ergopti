// tools/test/test-menu-no-duplicate-actions.cjs

/**
 * ==============================================================================
 * MODULE: Every Tray Action Has One Place
 * DESCRIPTION:
 * The maintainer's rule of 2026-11-19 for the layout menu, « il faut pas de
 * doublon et que tout soit clair », held for the tray root and its first-level
 * submenus on each platform: one action, one row.
 *
 * The layout menu broke it twice. « Créer ou modifier une disposition… »
 * (`open_layout_editor`) opened Ergopti Studio, which the tray root's « Ergopti
 * Studio… » row opens too. « Disposition personnalisée » (`custom_layouts`)
 * listed, on macOS and Linux, the registry layouts the « Sources de saisie »
 * list (`active_layouts`) lists with the same switch, and on Windows the
 * emulated layout the « Disposition à émuler » row (`layout_emulation`)
 * already names. Different ids, so no id check could see them: the actions
 * below name the rows that do one thing.
 *
 * WHAT THIS HOLDS, for each platform's rows (drawn or greyed with a reason):
 *   1. A row identity (type and id, or the feature path) is drawn in one menu
 *      only, and once there, except a menu's own scope rows (restore, clear),
 *      which act on that menu's scope only. A nested group is a menu of its own.
 *   2. Each action of ACTIONS is reached by one row at most, and Ergopti Studio
 *      by the tray root's row alone.
 *   3. The tray root puts Ergopti Studio right before the layout menu
 *      (maintainer request of 2026-11-19).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const MANIFEST = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'_shared',
	'menu',
	'data',
	'menu_manifest.json'
);
const PLATFORMS = ['ahk', 'hs', 'linux'];
const SEPARATOR = '---';

// The submenu each tray-root group opens (written out: `keyboard_layout` opens
// `layout_menu`, so a naming rule would need exceptions). Nested groups keep
// their rows in `<id>_group`.
const ROOT_SUBMENUS = {
	tap_holds: 'tap_holds_menu',
	shortcuts: 'shortcuts_menu',
	gestures: 'gestures_menu',
	keyboard_layout: 'layout_menu',
	hotstrings: 'hotstrings_menu',
	metrics: 'metrics_menu',
	llm: 'llm_menu',
	agent: 'agent_menu',
	apps: 'apps_menu',
	about: 'about_menu',
	configuration: 'configuration_menu',
	language: 'language_menu',
	debug: 'debug_menu'
};

// A menu's own restore and clear: one per menu, each acting on that menu's scope.
const SCOPE_ROWS = new Set(['command:scope_restore', 'command:scope_clear']);

// Rows with different ids that do one thing. `platforms` narrows an alias to
// the drivers where its row does that thing.
const ACTIONS = [
	{
		action: 'opens Ergopti Studio',
		rows: [{ id: 'ergopti_studio' }, { id: 'open_layout_editor' }],
		only_in: 'top_level'
	},
	{
		action: 'switches the system keyboard layout',
		rows: [{ id: 'active_layouts' }, { id: 'custom_layouts', platforms: ['hs', 'linux'] }]
	},
	{
		action: 'names the emulated layout',
		rows: [{ id: 'layout_emulation' }, { id: 'custom_layouts', platforms: ['ahk'] }]
	}
];

const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
const errors = [];

/** Whether a platform draws the row, greyed with its reason included. */
function drawn(row, platform) {
	if (!Array.isArray(row.platforms) || row.platforms.includes(platform)) return true;
	return row.unavailable === 'grey';
}

/** A row's identity: type and id, or type and feature path. */
function identity(row) {
	const key = row.id || row.path;
	return key ? `${row.type || 'row'}:${key}` : null;
}

/**
 * The rows a platform draws in one menu, nested `<id>_group` rows included,
 * each with the menu it sits in.
 */
function menuRows(key, platform, trail = []) {
	const rows = manifest[key];
	if (!Array.isArray(rows)) {
		errors.push(`${trail.concat(key).join(' > ')}: the manifest declares no such menu`);
		return [];
	}
	const where = trail.concat(key).join(' > ');
	const out = [];
	for (const row of rows) {
		if (!row || row.type === SEPARATOR || row.id === SEPARATOR || !drawn(row, platform)) continue;
		out.push({ row, menu: where });
		const nested = `${row.id}_group`;
		if (row.type === 'group' && Array.isArray(manifest[nested]) && !trail.includes(nested))
			out.push(...menuRows(nested, platform, trail.concat(key)));
	}
	return out;
}

for (const platform of PLATFORMS) {
	const root = menuRows('top_level', platform);
	const shown = [...root];
	for (const { row } of root) {
		if (ROOT_SUBMENUS[row.id])
			shown.push(...menuRows(ROOT_SUBMENUS[row.id], platform, ['top_level']));
	}

	const placed = new Map();
	const inMenu = new Set();
	for (const { row, menu } of shown) {
		const id = identity(row);
		if (!id) continue;
		// The root declares reload and quit once per platform caption: one row each.
		if (inMenu.has(`${menu}|${id}`) && menu !== 'top_level')
			errors.push(`${platform} ${menu}: ${id} is drawn twice in one menu`);
		inMenu.add(`${menu}|${id}`);
		if (SCOPE_ROWS.has(id)) continue;
		const seen = placed.get(id);
		if (seen && seen !== menu) errors.push(`${platform}: ${id} is drawn in ${seen} and in ${menu}`);
		placed.set(id, menu);
	}

	for (const { action, rows, only_in: onlyIn } of ACTIONS) {
		const reached = shown.filter(({ row }) =>
			rows.some(
				(alias) => alias.id === row.id && (!alias.platforms || alias.platforms.includes(platform))
			)
		);
		const places = new Set(reached.map(({ row, menu }) => `${menu}: ${row.id}`));
		if (places.size > 1)
			errors.push(
				`${platform}: one action (${action}) has ${places.size} rows: ${[...places].join(', ')}`
			);
		if (onlyIn && (places.size !== 1 || reached.some(({ menu }) => menu !== onlyIn)))
			errors.push(`${platform}: ${action} belongs to one row of ${onlyIn} alone`);
	}

	const order = root.map(({ row }) => row.id);
	const studio = order.indexOf('ergopti_studio');
	if (studio < 0 || order[studio + 1] !== 'keyboard_layout')
		errors.push(`${platform}: the tray root must put ergopti_studio right before keyboard_layout`);
}

if (errors.length) {
	console.error(`[FAIL] ${errors.length} duplicate or misplaced tray action(s):`);
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}
console.log(
	'[OK] every tray action has one place on Windows, macOS and Linux; Ergopti Studio precedes the layout menu.'
);
