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
 *              driver with no remap menu at all. (Retired 2026-09-24: the
 *              tap-holds moved into the daemon and Linux now shows the shared
 *              `tap_holds` row, which section 1 pins on all three drivers.)
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
 * 3. macOS and Windows build exactly the top-level rows the manifest declares
 *    for them. Added 2026-08-04, because "those two render from the manifest"
 *    was true and misleading: they iterated only its tail and dispatched each id
 *    through a hardcoded if/elseif chain, so the manifest supplied part of the
 *    ORDER and the driver supplied every ROW. A driver whose root loops over the
 *    whole top_level through a builder table is read here the way Linux is:
 *    an id declared and missing from the table renders nothing, and an id in
 *    the table the manifest does not declare is dead code.
 * 4. The manifest declares the approved top-level order, and Applications for
 *    macOS only. Every driver builds whatever the manifest declares, so this is
 *    where a reordering is held to the product decision. It also marks the rows
 *    a pause greys: every feature row, and no row of the tail.
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
const projections = {
	hs: projectionFor('hs'),
	ahk: projectionFor('ahk'),
	linux: projectionFor('linux')
};
const shapes = new Set(Object.values(projections).map((p) => p.join(',')));
if (shapes.size === 1) {
	errors.push(
		'the manifest projects the same top-level menu for all three drivers. Either every platform ' +
			'restriction was removed, or the projection is ignoring the platforms field — and in both ' +
			'cases this gate is comparing nothing.'
	);
}

// The tap-hold submenu is shared since 2026-09-24, when Linux retired kanata for
// the in-daemon engine and its own « Kanata » submenu with it. A Linux-only
// remap row reappearing, or tap_holds narrowing back to a subset of drivers,
// would split the one tap-hold menu into per-driver copies again.
for (const [driver, ids] of Object.entries(projections)) {
	if (!ids.includes('tap_holds')) {
		errors.push(`the manifest no longer projects the shared tap_holds row for ${driver}`);
	}
	if (ids.includes('kanata')) {
		errors.push(
			`the manifest projects a kanata row for ${driver}; kanata was retired on 2026-09-24`
		);
	}
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
// Anchored on the function's own `end` at column 0 — inner ends are indented, so
// this cannot stop early. It used to anchor on `return items`, and on 2026-08-07
// M.build stopped returning that variable: it collects row DATA and hands it to
// the shared renderer. The parse read nothing and the gate reported all
// seventeen rows as unimplemented — the loudest possible way for a test to be
// pinned to a spelling rather than to a shape.
const buildBody = linuxSrc.match(/function M\.build\(ctx\)([\s\S]*?)\nend\n/);
if (!buildBody) {
	errors.push(
		'could not find M.build(ctx) in the Linux menu builder — the parse below reads nothing'
	);
}

// Read from the `builders` map that M.build dispatches through, not from a
// sequence of calls. Until 2026-08-07 this driver appended one `_build_x(ctx)`
// per entry in a fixed order, and that order had already drifted from the
// manifest — the debug submenu sat between "reload" and "quit" while the
// declaration puts it last. M.build reads the declared order now, so the ids it
// can build are the keys of that map, and the ORDER is the manifest's by
// construction rather than by comparison.
const buildersBlock = (buildBody ? buildBody[1] : '').match(/local builders = \{([\s\S]*?)\n\t\}/);
const linuxBuilt = [];
for (const m of (buildersBlock ? buildersBlock[1] : '').matchAll(
	/\["(\w+)"\]\s*=\s*_build_(\w+)/g
)) {
	const id = m[1];
	if (LINUX_NON_ROWS.has(id)) continue;
	linuxBuilt.push(LINUX_BUILDER_ALIASES[id] || id);
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
//
// M.build follows the declared order and holds back exactly one row: Quit is
// appended last, because every tray application on this desktop puts it there
// (SNI/dbusmenu) and a user reaching for the bottom entry expects it. So the
// order the tray shows is the declaration with that one rule applied, and this
// is where the rule is modelled — reading it from the driver rather than
// assuming it, so removing it there fails here instead of passing quietly.
const HOLDS_QUIT_LAST = /quit_row = build\(ctx\)/.test(linuxSrc);
if (!HOLDS_QUIT_LAST && KNOWN_ORDER_DIVERGENCES.linux) {
	errors.push(
		'a Linux order divergence is recorded, but menu_builder.lua no longer holds Quit back — ' +
			'either it follows the declaration exactly now (remove the entry) or the rule was ' +
			'renamed and this gate has stopped seeing it'
	);
}

const declaredOrder = projections.linux.join(',');
const builtOrder = (
	HOLDS_QUIT_LAST ? [...linuxBuilt.filter((id) => id !== 'quit'), 'quit'] : linuxBuilt
).join(',');
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
// macOS and Windows both "rendered from the manifest", which was true and hid
// the gap: they iterated only the manifest's TAIL, from `global_actions` onward,
// and dispatched each id through a hardcoded if/elseif chain, while the feature
// rows above it were a fixed sequence of calls. The manifest supplied half the
// order and none of the rows, so reordering the feature rows, putting a
// separator among them or renaming the anchor changed Linux and nothing else.
//
// A driver that builds its root the way Linux does — one loop over the whole
// top_level, one builder per id — gets the ORDER from the manifest by
// construction. What can still be wrong is membership: an id declared and
// absent from the table renders nothing (the loop logs it, nothing fails), and
// an id in the table that the manifest does not declare for that driver is dead
// code. Both directions are checked here, per driver. The rendered order,
// separators included, is compared by each driver's own drift gate
// (test_menu_top_level_drift_gate.{lua,ahk}), which renders the root.

const DRIVER_ROOTS = {
	hs: {
		file: path.join(SP, 'macos', 'ui', 'menu', 'builder.lua'),
		label: 'macos/ui/menu/builder.lua',
		// The dispatch loop, which must read the WHOLE array, not a tail of it.
		loop: 'for _, entry in ipairs(load_top_level()) do',
		// The builder table M.generate dispatches through. Its entries sit two
		// tabs deep; the command tables inside the builders sit deeper, so the
		// anchored key pattern reads the top level and only the top level.
		table: /\n\tlocal builders = \{\n([\s\S]*?)\n\t\}\n/,
		key: /^\t\t\["(\w+)"\]\s*=/gm
	},
	ahk: {
		file: path.join(SP, 'windows', 'ui', 'menu', 'menu_init.ahk'),
		label: 'windows/ui/menu/menu_init.ahk',
		loop: '_MI_StageTopLevel(MenuManifest_LoadTopLevel(), Builders)',
		factory: 'Builders := _MI_TopLevelBuilders()',
		// The Map _MI_TopLevelBuilders returns: one "id", builder pair per line.
		table: /\n_MI_TopLevelBuilders\(\) \{\n\treturn Map\(\n([\s\S]*?)\n\t\)\n\}/,
		key: /^\t\t"(\w+)",\s*_MI_Stage\w+/gm
	}
};

// Floor. A regex that stops matching would report the driver as building nothing
// and then complain that the manifest declares everything — loud, but for the
// wrong reason, and the fix would be to the wrong file.
const MIN_ROOT_IDS = 8;

/**
 * The top-level ids one driver builds, read from its source.
 * @param {object} spec Entry of DRIVER_ROOTS.
 * @param {string} src Driver source.
 * @returns {string[]|null} Ids, or null when the scan found no anchor.
 */
function builtIds(spec, src) {
	if (spec.factory && !src.includes(spec.factory)) {
		errors.push(
			`${spec.label}: the per-invocation map must retain the canonical complete builder factory.`
		);
		return null;
	}
	if (!src.includes(spec.loop)) {
		errors.push(
			`${spec.label}: could not find "${spec.loop}" — the root no longer loops over the whole ` +
				'top_level, so the manifest does not decide its order. Repoint this gate only if the loop ' +
				'was renamed; a fixed sequence of calls is the defect it exists to catch.'
		);
		return null;
	}
	const block = src.match(spec.table);
	if (!block) {
		errors.push(`${spec.label}: could not find its builder table — this comparison reads nothing.`);
		return null;
	}
	return [...block[1].matchAll(spec.key)].map((m) => m[1]);
}

for (const [driver, spec] of Object.entries(DRIVER_ROOTS)) {
	const built = builtIds(spec, fs.readFileSync(spec.file, 'utf8'));
	if (!built) continue;

	if (built.length < MIN_ROOT_IDS) {
		errors.push(
			`${spec.label}: read only ${built.length} top-level id(s) (floor ${MIN_ROOT_IDS}) — the scan ` +
				'is broken, so the comparison below would report the manifest as wholly unimplemented'
		);
		continue;
	}

	const declared = new Set(projections[driver]);
	const handled = new Set(built);

	const unhandled = [...declared].filter((id) => !handled.has(id));
	if (unhandled.length > 0) {
		errors.push(
			`the manifest declares ${unhandled.length} top-level row(s) for ${driver} that ${spec.label} has ` +
				`no builder for: ${unhandled.join(', ')}. The loop will reach the id and skip it, so the row is ` +
				'in the manifest, counted by every gate, and invisible in the menu.'
		);
	}

	const orphaned = [...handled].filter((id) => !declared.has(id));
	if (orphaned.length > 0) {
		errors.push(
			`${spec.label} has ${orphaned.length} builder(s) for top-level row(s) the manifest does not ` +
				`declare for ${driver}: ${orphaned.join(', ')}. Either the manifest dropped the row and this is ` +
				'dead code, or a platform restriction excludes it and the builder is unreachable.'
		);
	}
}

// ==================================================
// ==================================================
// ======= 5/ The approved order ====================
// ==================================================
// ==================================================

// The top-level order is a product decision, taken once for the three trays:
// the keyboard and trackpad features first, including daemon-owned Tap-Holds
// on Linux, then what is about typing (layout, hotstrings, metrics), then
// the two AI rows together, then the macOS applications in a group of their
// own, then the tail: Versions, Configuration, Language (the maintainer's
// order of 2026-10-01, its tail reordered on 2026-10-02). The drivers build whatever the
// manifest declares, so this is the one place a reordering of the manifest is
// held to the decision rather than silently shipped. Changing the order means
// changing this list, in the same commit and on purpose.
const APPROVED_TOP_LEVEL = [
	'tap_holds',
	'shortcuts',
	'gestures',
	SEPARATOR,
	'keyboard_layout',
	'hotstrings',
	'metrics',
	SEPARATOR,
	'llm',
	'agent',
	SEPARATOR,
	'apps',
	SEPARATOR,
	'about',
	'configuration',
	'language',
	SEPARATOR,
	'suspend',
	'reload',
	'quit',
	'debug'
];

const declaredTopLevel = (topLevel || []).map((row) => row.id);
// Only Reload/Quit have adjacent, disjoint native caption declarations.
// Pin their physical multiplicity and the unchanged approved native order.
const approvedPhysicalOrder = APPROVED_TOP_LEVEL.flatMap((id) =>
	id === 'reload' || id === 'quit' ? [id, id] : [id]
);
if (declaredTopLevel.join(',') !== approvedPhysicalOrder.join(',')) {
	errors.push(
		'the manifest top level is not the approved order.\n' +
			`      approved: ${APPROVED_TOP_LEVEL.join(', ')}\n      declared: ${declaredTopLevel.join(', ')}`
	);
}

for (const [driver, ids] of Object.entries(projections)) {
	const approved = APPROVED_TOP_LEVEL.filter(
		(id) =>
			id !== SEPARATOR &&
			(id !== 'apps' || driver === 'hs') &&
			(id !== 'suspend' || driver === 'ahk')
	);
	if (ids.join(',') !== approved.join(',')) {
		errors.push(
			`the ${driver} native top level is not the approved order or has duplicate identities`
		);
	}
}

// Applications lists the applications bundled with the macOS app; the other
// two drivers ship none.
const appsRow = (topLevel || []).find((row) => row.id === 'apps');
if (!appsRow || JSON.stringify(appsRow.platforms) !== JSON.stringify(['hs'])) {
	errors.push('the Applications row must be declared for macOS only (platforms = ["hs"]).');
}

// « Pause = tout éteint »: a pause greys every feature row and leaves the tail
// live, because the tail is how the user resumes, inspects or leaves a paused
// script. The manifest marks those rows once, the macOS and Linux roots read the
// mark, and the AHK pause test holds the Windows builders to it. The approved
// order puts every feature before the tail, which Versions (the About row)
// opens, so the mark must cover exactly the rows above it.
const PAUSE_MARK = 'greyed_when_paused';
const tailAt = (topLevel || []).findIndex((row) => row.id === 'about');
let pauseMarked = 0;
(topLevel || []).forEach((row, index) => {
	const mark = row[PAUSE_MARK];
	if (mark !== undefined && mark !== true) {
		errors.push(
			`top_level "${row.id}": ${PAUSE_MARK} is ${JSON.stringify(mark)}; only true is a mark.`
		);
	}
	if (row.id === SEPARATOR) {
		if (mark !== undefined)
			errors.push(`a top_level separator carries ${PAUSE_MARK}; it has no row to grey.`);
		return;
	}
	if (mark === true) pauseMarked += 1;
	const isFeature = tailAt >= 0 && index < tailAt;
	if (isFeature && mark !== true) {
		errors.push(
			`the feature row "${row.id}" lacks ${PAUSE_MARK} = true: a pause would leave it live.`
		);
	}
	if (!isFeature && mark === true) {
		errors.push(
			`the tail row "${row.id}" carries ${PAUSE_MARK}: a pause would grey a row the user resumes or leaves with.`
		);
	}
});
if (tailAt < 0 || pauseMarked < 7) {
	errors.push(
		`read ${pauseMarked} row(s) marked ${PAUSE_MARK} (floor 7) and ${tailAt < 0 ? 'no' : 'a'} Configuration ` +
			'row — the pause-mark check compared nothing'
	);
}

// ==================================================
// ==================================================
// ======= 6/ Report ================================
// ==================================================
// ==================================================

// Only this unfinished component is presentation-disabled. The neighboring
// AI component keeps its original provider/model/prediction subtree owner.
const agentDeclarations = topLevel.filter((row) => row.id === 'agent');
if (
	agentDeclarations.length !== 1 ||
	agentDeclarations[0].disabled !== true ||
	agentDeclarations[0].i18n !== 'menu.agent.title' ||
	agentDeclarations[0].reason_key !== 'menu.agent.not_ready' ||
	agentDeclarations[0].platforms !== undefined
)
	errors.push(
		'Agent IA must be explicitly disabled on all three top-level menus with its exact reason.'
	);
for (const row of topLevel) {
	if (row.id !== 'agent' && row.disabled !== undefined)
		errors.push(`The Agent-only presentation gate reached neighboring row ${row.id}.`);
}
for (const locale of [
	'ar',
	'cs',
	'da',
	'de',
	'en',
	'es',
	'fr',
	'he',
	'hi',
	'it',
	'ja',
	'ko',
	'nl',
	'no',
	'pl',
	'pt',
	'ru',
	'sv',
	'tr',
	'uk',
	'zh'
]) {
	const dictionary = JSON.parse(
		fs.readFileSync(path.join(SP, '_shared', 'data', 'locales', locale + '.json'), 'utf8')
	);
	if (
		typeof dictionary['menu.agent.not_ready'] !== 'string' ||
		dictionary['menu.agent.not_ready'].trim() === ''
	)
		errors.push(`${locale}: Agent IA needs its localized unready reason.`);
}

const availability = require('../lib/menu-row-availability.cjs');
const disabledBase = {
	id: 'agent',
	disabled: true,
	i18n: 'menu.agent.title',
	reason_key: 'menu.agent.not_ready'
};
for (const [patch, owner, message] of [
	[{ disabled: 'true' }, 'menu.top_level row "agent"', 'boolean top-level'],
	[{}, 'menu.agent_menu row "agent"', 'boolean top-level'],
	[{ i18n: '' }, 'menu.top_level row "agent"', 'exact label and reason'],
	[{ reason_key: '' }, 'menu.top_level row "agent"', 'exact label and reason'],
	[{ reason_key: false }, 'menu.top_level row "agent"', 'exact label and reason'],
	[{ id: '---' }, 'menu.top_level row "agent"', 'exact label and reason'],
	[{ disabled_when: ['hidden_condition'] }, 'menu.top_level row "agent"', 'exact label and reason']
]) {
	let refused = false;
	try {
		availability.classifyMenuRow({ ...disabledBase, ...patch }, owner);
	} catch (error) {
		refused = error instanceof Error && error.message.includes(message);
	}
	if (!refused)
		errors.push('Disabled root declaration must refuse ' + JSON.stringify(patch) + ' in ' + owner);
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] menu top-level parity:\x1b[0m');
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] top-level menu shape agrees: manifest projects ${projections.ahk.length} row(s) for ` +
		`Windows, ${projections.hs.length} for macOS, ${projections.linux.length} for Linux; ` +
		`menu_builder.lua builds exactly those ${linuxBuilt.length}, and the macOS and Windows roots ` +
		'build exactly the rows their driver is declared for.\x1b[0m'
);
for (const [driver, why] of Object.entries(KNOWN_ORDER_DIVERGENCES)) {
	console.log(`     · ${driver} order: ${why}`);
}

// Disabled metadata remains rejected by the same inert owner on every compiler path.
{
	const assert = require('node:assert/strict');
	const { classifyMenuRow } = require('../lib/menu-row-availability.cjs');
	for (const [type, reason] of [
		['section_header', /section header needs a caption without behavior metadata/],
		['label', /inert label needs an identity and caption without behavior metadata/]
	]) {
		for (const disabled of [true, false, 'unowned', 1])
			assert.throws(
				() =>
					classifyMenuRow(
						{ type, id: 'inert', i18n: 'caption', disabled },
						'menu.fixture row "inert"'
					),
				reason
			);
	}
	assert.throws(
		() =>
			classifyMenuRow(
				{ type: 'group', id: 'agent', i18n: 'caption', disabled: 'true' },
				'menu.top_level row "agent"'
			),
		/disabled is a boolean top-level presentation gate/
	);
	assert.doesNotThrow(() =>
		classifyMenuRow(
			{ type: 'group', id: 'agent', i18n: 'caption', disabled: true, reason_key: 'reason' },
			'menu.top_level row "agent"'
		)
	);
}
