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
 * 5. A row narrower than the menu containing it should say why (`reason_key`).
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
	global_actions: 'global_actions',
	debug: 'debug_menu',
	shortcuts: 'shortcuts_menu',
	metrics: 'metrics_menu',
	keyboard_layout: 'layout_menu',
	hotstrings: 'hotstrings_menu',
	gestures: 'gestures_menu',
	tap_holds: 'tap_holds_menu',
	modifier_combos: 'modifier_combos_group',
	accented_letters: 'accented_letters_group',
	hotstrings_params: 'hotstrings_params_group'
};

const errors = [];

const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
const MENU_KEYS = Object.keys(manifest).filter((k) => Array.isArray(manifest[k]));

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
	const key = row.i18n || row.i18n_on || row.category;
	if (key) parts.push(`@${key}`);
	return parts.join(' ');
}

/**
 * The rows of one menu visible on one platform, in manifest order.
 * @param {string} menuKey A manifest array key.
 * @param {string} platform "ahk", "hs" or "linux".
 * @returns {object[]}
 */
function project(menuKey, platform) {
	return (manifest[menuKey] || []).filter((row) => visibleOn(row, platform));
}

/**
 * The rows a user can actually act on: everything that is not a separator.
 * @param {string} menuKey A manifest array key.
 * @param {string} platform "ahk", "hs" or "linux".
 * @returns {object[]}
 */
function actionable(menuKey, platform) {
	return project(menuKey, platform).filter((row) => !isSeparator(row));
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
			const target = OPENS_SUBMENU[row.id];
			if (!target) continue;
			const effective = PLATFORMS.filter((p) => visibleOn(row, p) && parentVisibility.includes(p));
			const before = (reachableOn[target] || []).join(',');
			if (before !== effective.join(',')) {
				reachableOn[target] = effective;
				changed = true;
			}
			openedBy[target] = `${menuKey}/${row.id}`;
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
// is the one that never has the gap.
const LABEL_FIELDS = ['i18n', 'i18n_on', 'i18n_off', 'reason_key'];

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
	errors.push(`read ${localeFiles.length} locale file(s) — the scan is broken, so nothing below is checked`);
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
		if (narrower.length === 0 || row.reason_key) continue;
		unreasoned.push(
			`${menuKey}/${row.id || row.i18n || row.category || row.type} hidden on ` +
				`${narrower.map((p) => DRIVER_OF[p]).join(', ')}`
		);
	}
}

// Frozen at the measurement of 2026-08-04. Convention S wants the row present
// and greyed with its reason rather than absent, and 40 rows predate that; making
// them all red at once would mean this gate could only land by being silenced.
// It may fall, never rise — 41 became 40 the moment hotstring_extensions stopped
// claiming to be Windows-only.
const UNREASONED_BASELINE = 40;

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
const RENDERED_THROUGH_SHARED = { hs: 4, linux: 4 };

const DRIVER_ROOTS = { hs: path.join(SP, 'macos'), linux: path.join(SP, 'linux') };

/**
 * The whole Lua source of a driver, concatenated, tests excluded.
 * @param {string} root Absolute path to the driver tree.
 * @returns {string}
 */
function driverSource(root) {
	let out = '';
	const walk = (dir) => {
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			const full = path.join(dir, entry.name);
			if (entry.isDirectory()) {
				if (entry.name === 'tests' || entry.name === '_generated') continue;
				walk(full);
			} else if (entry.name.endsWith('.lua')) {
				out += fs.readFileSync(full, 'utf8');
			}
		}
	};
	walk(root);
	return out;
}

const renderedCounts = {};
for (const [driver, root] of Object.entries(DRIVER_ROOTS)) {
	const src = driverSource(root);
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
		}
	}
	const absent = [...needed].filter((key) => !src.includes(key));
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




// ==================================================
// ==================================================
// ======= 8/ Report ================================
// ==================================================
// ==================================================

if (process.argv.includes('--measure')) {
	console.log(`menus: ${MENU_KEYS.length}`);
	for (const menuKey of MENU_KEYS) {
		const counts = PLATFORMS.map((p) => `${p}=${project(menuKey, p).length}`).join(' ');
		console.log(`  ${menuKey.padEnd(24)} ${counts}   reachable on: ${(reachableOn[menuKey] || []).join(',')}`);
	}
	console.log(`unreasoned hidden rows: ${unreasoned.length}`);
	console.log(`rendered through the shared renderer: ${JSON.stringify(renderedCounts)}`);
	process.exit(0);
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] the three menus differ in ways the manifest does not declare:\x1b[0m');
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
