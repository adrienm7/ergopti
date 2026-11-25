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
 *   4. The layout menu reads, on each platform, the input sources, the
 *      emulation, then the tuning of the active layout, OS or emulated, and
 *      last the rows that tune no layout (maintainer decision of 2026-11-19:
 *      « inputs, émulation, puis tuning de dispo »). Each row sits in its
 *      section, in LAYOUT_SECTIONS order, and the menu draws no other row.
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
	keep_awake: 'keep_awake_menu',
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

// The layout menu, section by section: its header, then its rows in order. The
// rows a platform does not draw drop out; the separators between sections stay.
// docs/memory/maintainer-decisions.md says why each row sits where it does.
const LAYOUT_LEAD = ['toggle:layout_toggle', 'command:scope_restore', 'command:scope_clear'];
const LAYOUT_SECTIONS = [
	{
		header: 'menu.layout.active_layouts',
		rows: [
			'list:active_layouts',
			'list:layout_switching',
			'list:compose_input_method',
			'command:layout_manager',
			'list:layout_user_install',
			'list:layout_bundle',
			'list:layout_system_install'
		]
	},
	{ header: 'menu.layout.header_emulation', rows: ['list:layout_emulation'] },
	{
		header: 'menu.layout.header_tuning',
		rows: [
			'list:layout_features_base',
			'list:layout_features_altgr',
			'group:layout_emulated_rows',
			'list:number_row_policy',
			'group:accented_letters',
			'list:magic_key_source',
			'feature:layout.ctrl_magic_save'
		]
	},
	{ header: null, rows: ['list:base_layouts', 'choice:virtual_keyboard', 'choice:menubar_icon'] }
];

const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
const errors = [];

/**
 * A sequence with its separators collapsed: none first, last or twice in a row,
 * as the renderers normalise them.
 */
function collapse(tokens) {
	const out = [];
	for (const token of tokens) {
		if (token === SEPARATOR && (out.length === 0 || out[out.length - 1] === SEPARATOR)) continue;
		out.push(token);
	}
	while (out[out.length - 1] === SEPARATOR) out.pop();
	return out;
}

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

/** The layout menu a platform draws, as header and row tokens with separators. */
function layoutTokens(platform) {
	return collapse(
		(manifest.layout_menu || [])
			.filter((row) => row && (row.type === SEPARATOR || drawn(row, platform)))
			.map((row) => {
				if (row.type === SEPARATOR) return SEPARATOR;
				if (row.type === 'section_header') return `section_header:${row.i18n}`;
				return identity(row);
			})
	);
}

/** The layout menu LAYOUT_SECTIONS expects, given the rows a platform draws. */
function expectedLayoutTokens(drawnTokens) {
	const present = new Set(drawnTokens);
	const tokens = LAYOUT_LEAD.filter((token) => present.has(token));
	for (const { header, rows } of LAYOUT_SECTIONS) {
		const kept = rows.filter((token) => present.has(token));
		if (kept.length === 0) continue;
		tokens.push(SEPARATOR);
		if (header) tokens.push(`section_header:${header}`);
		tokens.push(...kept);
	}
	return collapse(tokens);
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

	const layout = layoutTokens(platform);
	const known = new Set(LAYOUT_LEAD.concat(...LAYOUT_SECTIONS.map(({ rows }) => rows)));
	for (const token of layout) {
		if (token !== SEPARATOR && !token.startsWith('section_header:') && !known.has(token))
			errors.push(`${platform}: layout_menu draws ${token}, which LAYOUT_SECTIONS places nowhere`);
	}
	const expected = expectedLayoutTokens(layout);
	if (layout.join(',') !== expected.join(','))
		errors.push(
			`${platform}: the layout menu must read input sources, emulation, tuning, then the rest:\n` +
				`      drawn    ${layout.join(', ')}\n      expected ${expected.join(', ')}`
		);

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
	'[OK] every tray action has one place on Windows, macOS and Linux; Ergopti Studio precedes the layout menu, which reads input sources, emulation, then tuning.'
);
