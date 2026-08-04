// tools/test/test-menu-top-level-parity.cjs

/**
 * ==============================================================================
 * MODULE: Menu Top-Level Parity Across the Three Drivers (I3)
 * DESCRIPTION:
 * The menu manifest is meant to be the single source of the menu's SHAPE. It was
 * that for two drivers: Windows and macOS both render from it. Linux builds its
 * tray menu by hand in ui/menu/menu_builder.lua, and the manifest carried no
 * `linux` platform value anywhere — so Linux "matched" only because an
 * unrestricted row defaults to every platform, and nothing could tell the
 * difference between "Linux has this row" and "nobody said".
 *
 * WHAT THAT HID, measured 2026-08-03 by projecting the manifest for Linux and
 * reading M.build() next to it:
 *
 *   kanata   — built by Linux since it was written, ABSENT from the manifest.
 *              It is the Linux twin of `karabiner`, so the manifest described a
 *              driver with no remap menu at all.
 *   updates  — built by Linux, absent from the manifest, and genuinely
 *              Linux-only: neither other driver has an update menu.
 *   apps     — built by Linux, and the manifest said platforms = ["hs"]. The
 *              restriction was simply false.
 *
 * Three rows, none of them findable, because the only thing that could have
 * compared them did not exist.
 *
 * WHAT THIS HOLDS:
 * 1. The manifest's projection for each driver contains exactly the top-level
 *    ids that driver builds. A row added to one side and not the other fails
 *    here, in both directions.
 * 2. Ordering divergences are declared with a reason. Linux is not required to
 *    match the manifest's ORDER — a tray menu has its own conventions — but a
 *    divergence has to be written down rather than discovered.
 * 3. macOS and Windows handle exactly the tail rows the manifest declares for
 *    them. Added 2026-08-04, because "those two render from the manifest" was
 *    true and misleading: they iterate it and dispatch each id through a
 *    hardcoded if/elseif chain, so the manifest supplies the ORDER and the driver
 *    supplies every ROW. An id added to the manifest and not to a chain renders
 *    nothing; an id removed leaves a dead branch. Their own drift gates compare
 *    the manifest against a hand-typed list and cannot see either. Linux — the
 *    driver with no manifest renderer at all — was the only one whose real
 *    builder was ever read.
 *
 * WHAT IT DELIBERATELY DOES NOT DO:
 * render the three menus and diff their translated labels. That needs Linux to
 * read the manifest at runtime, which is a 561-line renderer port
 * (macos/infra/manifest_menu.lua is the reference). This gate is the half that
 * can be true today, and it is what makes that port checkable when someone does
 * it: the shape is pinned first, so the port cannot quietly change it.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const MANIFEST = path.join(SP, '_shared', 'modules', 'menu', 'menu_manifest.json');
const LINUX_BUILDER = path.join(SP, 'linux', 'ui', 'menu', 'menu_builder.lua');

// The separator id, which carries no identity and cannot be compared by name.
const SEPARATOR = '---';

// Linux builds `_build_<name>(ctx)` functions whose name is not always the
// manifest id. Only the genuine spelling differences are listed; anything else
// must match by name, so a new row cannot be waved through by adding an alias.
const LINUX_BUILDER_ALIASES = {
	layouts: 'keyboard_layout'
};

// Rows Linux builds that are not menu rows at all: a non-interactive header and
// the driver's own separators. Declared rather than filtered silently.
const LINUX_NON_ROWS = new Set(['header']);

// Ordering differences that are deliberate. This list may only shrink.
const KNOWN_ORDER_DIVERGENCES = {
	linux:
		'Linux puts Quit LAST, after Debug, where the manifest order ends reload → quit → debug. ' +
		'That is the SNI/dbusmenu convention every other tray application on the desktop follows, ' +
		'and a user reaching for the bottom entry expects Quit. The manifest order is the macOS ' +
		'menubar order; neither is wrong, and forcing one on the other would make one platform feel ' +
		'foreign'
};

const errors = [];




// ==================================================
// ==================================================
// ======= 1/ The manifest projection ===============
// ==================================================
// ==================================================

const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
const topLevel = manifest.top_level;

if (!Array.isArray(topLevel) || topLevel.length < 15) {
	errors.push(
		`the manifest declares ${Array.isArray(topLevel) ? topLevel.length : 0} top-level row(s) — the ` +
			'parse is broken and every comparison below is vacuous'
	);
}

/**
 * The top-level ids the manifest declares for one driver, in manifest order.
 * @param {string} driver "hs", "ahk" or "linux".
 * @returns {string[]}
 */
function projectionFor(driver) {
	return (topLevel || [])
		.filter((row) => !row.platforms || row.platforms.includes(driver))
		.map((row) => row.id)
		.filter((id) => id !== SEPARATOR);
}

// A projection identical for all three drivers would mean the platforms fields
// stopped being read — the exact state this gate was written to end.
const projections = { hs: projectionFor('hs'), ahk: projectionFor('ahk'), linux: projectionFor('linux') };
const shapes = new Set(Object.values(projections).map((p) => p.join(',')));
if (shapes.size === 1) {
	errors.push(
		'the manifest projects the same top-level menu for all three drivers. Either every platform ' +
			'restriction was removed, or the projection is ignoring the platforms field — and in both ' +
			'cases this gate is comparing nothing.'
	);
}




// ==================================================
// ==================================================
// ======= 2/ What Linux actually builds ============
// ==================================================
// ==================================================

const linuxSrc = fs.readFileSync(LINUX_BUILDER, 'utf8');

// M.build() appends one entry per top-level row. Reading the calls in order is
// what makes this a comparison of the real menu rather than of a second list
// someone would have to remember to update.
const buildBody = linuxSrc.match(/function M\.build\(ctx\)([\s\S]*?)\n\treturn items/);
if (!buildBody) {
	errors.push('could not find M.build(ctx) in the Linux menu builder — the parse below reads nothing');
}

const linuxBuilt = [];
for (const m of (buildBody ? buildBody[1] : '').matchAll(/_build_(\w+)\(ctx\)/g)) {
	const name = m[1];
	if (LINUX_NON_ROWS.has(name)) continue;
	linuxBuilt.push(LINUX_BUILDER_ALIASES[name] || name);
}

if (linuxBuilt.length < 10) {
	errors.push(
		`read ${linuxBuilt.length} row(s) from the Linux M.build() — the scan is broken, and the ` +
			'comparison below would report the manifest as wholly unimplemented'
	);
}




// ==================================================
// ==================================================
// ======= 3/ The two must agree ====================
// ==================================================
// ==================================================

const declared = new Set(projections.linux);
const built = new Set(linuxBuilt);

const missingOnLinux = [...declared].filter((id) => !built.has(id));
if (missingOnLinux.length > 0) {
	errors.push(
		`the manifest declares ${missingOnLinux.length} top-level row(s) for Linux that menu_builder.lua ` +
			`does not build: ${missingOnLinux.join(', ')}. The manifest is the shape every driver is ` +
			'measured against, so a row declared and not built is a promise nothing keeps.'
	);
}

const undeclared = [...built].filter((id) => !declared.has(id));
if (undeclared.length > 0) {
	errors.push(
		`menu_builder.lua builds ${undeclared.length} top-level row(s) the manifest does not declare for ` +
			`Linux: ${undeclared.join(', ')}. This is the direction that stayed invisible for as long as ` +
			'the manifest carried no linux value at all — kanata, updates and apps were all found this ' +
			'way. Add the row with platforms = ["linux"], or widen the restriction that excludes it.'
	);
}

// The order divergence is allowed but must stay declared.
const declaredOrder = projections.linux.join(',');
const builtOrder = linuxBuilt.join(',');
if (declaredOrder === builtOrder && KNOWN_ORDER_DIVERGENCES.linux) {
	errors.push(
		'Linux now builds its top-level rows in exactly the manifest order, but an order divergence is ' +
			'still recorded for it. Remove the entry — this list may only shrink.'
	);
}
if (declaredOrder !== builtOrder && !KNOWN_ORDER_DIVERGENCES.linux) {
	errors.push(
		`Linux builds its top-level rows in a different order from the manifest and nothing records why.\n` +
			`      manifest: ${declaredOrder}\n      built:    ${builtOrder}`
	);
}




// ==================================================
// ==================================================
// ======= 4/ And so must the other two =============
// ==================================================
// ==================================================

// WHY THIS EXISTS, AND WHY IT WAS THE HOLE NOBODY SAW.
// macOS and Windows both "render from the manifest", which is true and hid the
// gap: they iterate the manifest's tail and dispatch each id through a hardcoded
// if/elseif chain. The rows are NOT generic — the manifest supplies the order,
// the driver supplies every row. So an id added to the manifest and not to a
// chain renders nothing, and an id removed from the manifest leaves a dead
// branch, and until 2026-08-04 neither was checked anywhere.
//
// Both drivers do have a drift gate — macos/tests/meta/ and windows/tests/meta/
// test_menu_top_level_drift_gate.{lua,ahk} — but each compares the manifest
// against a HAND-TYPED list of ids. That alarms on manifest edits and says
// nothing about the drivers. Linux, the driver with no manifest renderer at all,
// was the only one whose real builder was read (section 2 above). Generalising
// that read to the other two is smaller than writing two more drift gates, and
// it is what eventually makes the two hand-typed lists redundant.
//
// Order is deliberately NOT compared here. Both chains iterate the manifest and
// dispatch, so the ORDER a user sees is the manifest's whatever order the
// branches happen to be written in. Only membership can be wrong.

const DRIVER_TAIL_CHAINS = {
	hs: {
		file: path.join(SP, 'macos', 'ui', 'menu', 'builder.lua'),
		label: 'macos/ui/menu/builder.lua',
		// The tail loop. Its nested submenu chains compare `gid` and `did`, so a
		// word-boundary match on `id` selects the top level and only the top level.
		start: 'for _, entry in ipairs(load_top_level_tail()) do',
		end: '\n\tend\n',
		id: /\bid == "([^"]+)"/g
	},
	ahk: {
		file: path.join(SP, 'windows', 'ui', 'menu', 'menu_init.ahk'),
		label: 'windows/ui/menu/menu_init.ahk',
		start: '_MI_AppendTail() {',
		end: '\n}',
		id: /\bId == "([^"]+)"/g
	}
};

// Floor. A regex that stops matching would report the driver as building nothing
// and then complain that the manifest declares everything — loud, but for the
// wrong reason, and the fix would be to the wrong file.
const MIN_TAIL_IDS = 8;

// The tail is the manifest's own boundary between feature menus and system-wide
// actions: both drivers slice top_level from `global_actions` onward, and Linux
// builds the same rows through its own functions.
const TAIL_ANCHOR = 'global_actions';

/**
 * The tail ids the manifest declares for one driver.
 * @param {string} driver "hs" or "ahk".
 * @returns {string[]}
 */
function tailProjectionFor(driver) {
	const rows = topLevel || [];
	const at = rows.findIndex((row) => row && row.id === TAIL_ANCHOR);
	if (at < 0) return [];
	return rows
		.slice(at)
		.filter((row) => !row.platforms || row.platforms.includes(driver))
		.map((row) => row.id)
		.filter((id) => id !== SEPARATOR);
}

for (const [driver, spec] of Object.entries(DRIVER_TAIL_CHAINS)) {
	const src = fs.readFileSync(spec.file, 'utf8');
	const from = src.indexOf(spec.start);
	if (from < 0) {
		errors.push(
			`${spec.label}: could not find "${spec.start}" — the dispatch chain moved or was renamed, ` +
				'and this comparison reads nothing. Repoint it; do not delete it.'
		);
		continue;
	}
	const rest = src.slice(from);
	const to = rest.indexOf(spec.end);
	const block = to > 0 ? rest.slice(0, to) : rest;
	const built = [...block.matchAll(spec.id)].map((m) => m[1]).filter((id) => id !== SEPARATOR);

	if (built.length < MIN_TAIL_IDS) {
		errors.push(
			`${spec.label}: read only ${built.length} tail id(s) (floor ${MIN_TAIL_IDS}) — the scan is ` +
				'broken, so the comparison below would report the manifest as wholly unimplemented'
		);
		continue;
	}

	const declared = new Set(tailProjectionFor(driver));
	const handled = new Set(built);

	const unhandled = [...declared].filter((id) => !handled.has(id));
	if (unhandled.length > 0) {
		errors.push(
			`the manifest declares ${unhandled.length} tail row(s) for ${driver} that ${spec.label} has no ` +
				`branch for: ${unhandled.join(', ')}. The loop will reach the id and fall through, so the ` +
				'row is in the manifest, counted by every gate, and invisible in the menu.'
		);
	}

	const orphaned = [...handled].filter((id) => !declared.has(id));
	if (orphaned.length > 0) {
		errors.push(
			`${spec.label} has ${orphaned.length} branch(es) for tail row(s) the manifest does not declare ` +
				`for ${driver}: ${orphaned.join(', ')}. Either the manifest dropped the row and this is dead ` +
				'code, or a platform restriction excludes it and the branch is unreachable.'
		);
	}
}




// ==================================================
// ==================================================
// ======= 5/ Report ================================
// ==================================================
// ==================================================

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] menu top-level parity:\x1b[0m');
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] top-level menu shape agrees: manifest projects ${projections.ahk.length} row(s) for ` +
		`Windows, ${projections.hs.length} for macOS, ${projections.linux.length} for Linux; ` +
		`menu_builder.lua builds exactly those ${linuxBuilt.length}, and both dispatch chains handle ` +
		'exactly the tail rows their driver is declared for.\x1b[0m'
);
for (const [driver, why] of Object.entries(KNOWN_ORDER_DIVERGENCES)) {
	console.log(`     · ${driver} order: ${why}`);
}
