// tools/test/test-menu-action-handler-bijection.cjs

/**
 * ==============================================================================
 * MODULE: Menu Action ↔ Handler Bijection (I3)
 * DESCRIPTION:
 * Every `action` or `dynamic` row the manifest declares for a platform must have
 * a handler named in that driver. Windows is held at **zero** unresolved rows;
 * macOS and Linux are frozen at their current gap so it cannot grow.
 *
 * WHAT AN UNRESOLVED ROW DOES:
 * The manifest says the user gets a row. The renderer looks up a handler by id,
 * finds none, and — depending on the driver — logs a warning nobody reads or
 * renders a row that does nothing when clicked. Neither raises. The row is in
 * the manifest, so every manifest-reading gate is satisfied; it just does not
 * work.
 *
 * WHY WINDOWS IS ZERO AND THE OTHERS ARE NOT:
 * Windows renders its menu from the manifest and resolves all 38 of its declared
 * action rows. macOS renders part of its menu that way and leaves 20 unresolved.
 * Linux renders **none** of it: the manifest carries no `linux` platform value
 * anywhere (27 rows are `[ahk]`, 19 `[hs]`, 2 both), so its 27 rows are visible
 * to Linux only because an unrestricted row defaults to every platform — while
 * `ui/menu/menu_builder.lua` builds its 97 rows by hand.
 *
 * That gap is the I2/I3 migration, not a defect to fix here. Freezing it is what
 * this guard is for: Windows cannot regress from zero, and the other two cannot
 * drift further from the manifest while the migration proceeds. Lower these
 * baselines as rows are wired. Never raise them.
 *
 * WHAT THIS DOES NOT PROVE:
 * A row counts as handled when its id appears as a quoted string anywhere in the
 * driver's production source. That is a **necessary** condition, not a
 * sufficient one — it catches the case this guard is for, a manifest row no
 * driver mentions at all, and it will NOT catch a handler renamed away while the
 * same id survives elsewhere in the file (`MenuRenderer_ResolveDisabledWhen(…,
 * "shortcut_typing", …)` on the next line keeps it "named").
 *
 * A tighter "the id must be bound to a callable on the same line" rule was tried
 * and rejected: it reported `"tap_hold_keys", _TH_DynKeys,` as unbound, because
 * that handler is a function REFERENCE rather than a lambda. Distinguishing a
 * handler-map entry from a call argument needs a parser, not a regex, and a
 * predicate that flags correct bindings is worse than a coarse one — the change
 * it demands is to rewrite working code. The floors below are what keep the
 * coarse version honest: if the scan stops matching, it fails instead of
 * reporting everything resolved.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const MANIFEST = path.join(SP, '_shared', 'modules', 'menu', 'menu_manifest.json');

// Frozen baselines — declared rows with no handler named, on 2026-08-01.
// 2026-08-04: hs 20 → 16, linux 27 → 10. Two different kinds of progress, and
// the distinction matters more than the numbers.
//
// SIX of the eleven that came off Linux are real handlers: its metrics submenu
// is the first on that driver to render from the manifest at all, with
// disabled_when and checked_when resolved declaratively instead of re-derived.
//
// The rest came off BOTH Lua drivers, because the rows could never have been
// rendered on either: each enumerates features the FEATURE manifest already
// declares platforms = ["ahk"]. layout_features_base and layout_features_altgr
// list features.layout.*, all five of which are ahk. script_control_shortcuts
// lists features.shortcuts.script_control, all four ahk. extensions_shortcuts
// walks a Windows extensions directory. And seven metrics rows configure the WPM
// widget, the two window shortcuts and the app-exclusion list — none of which
// exists on Linux, where ui/wpm is absent and the keylogger exposes no
// disabled-apps setter. A row declared for a driver that cannot draw it is not a
// gap in the driver; it is the manifest making a promise on the driver's behalf.
// hs 5 → 4 on 2026-08-06: `hotstring_bulk_actions` was one row that expanded
// to two, and macOS had no handler for the id at all — it built its bulk rows
// by hand in builder.lua and the manifest's promise went unanswered. Splitting
// it into two `command` rows is what let the declaration and the driver meet.
// ── ahk 0 → 1 and hs 4 → 7 on 2026-08-06, and NEITHER is a regression ──
//
// Read the filter before reading the numbers. Until today this gate looked only
// at `action` and `dynamic` rows, so every `list` row in the manifest was
// invisible to it — and `list` is what a repeated block becomes. Widening the
// set to every type that names a behaviour (BEHAVIOUR_TYPES below) is what
// revealed these, and all of them predate the migration that prompted the
// widening:
//
//   ahk llm_menu.llm_models — Windows does not read `llm_menu` from the
//     manifest at all; it builds its LLM menu by hand under ui/menu/menu_llm/.
//     Two rows declared for every platform, answered by one driver.
//   hs — the same llm_models, layout_menu.active_layouts, and the five
//     hotstrings rows, because macOS assembles its hotstrings menu by hand in
//     ui/menu/builder.lua and reads the manifest for none of it.
//
// So the honest number rose while the code improved, exactly as the row-bypass
// ratchet's own linux 2 → 124 did when ITS definition was corrected. Lower these
// by wiring the rows or by putting those two menus on the renderer — never by
// narrowing the filter again.
// hs 7 → 6: active_layouts is answered now — macOS's keyboard-layout menu
// renders the manifest's own rows through the shared renderer instead of
// building that list in place.
// hs 6 → 5: llm_models is answered — macOS places its model row through the
// shared renderer now instead of inserting it in place.
// ahk 1 → 0: `llm_models` and `llm_generation` were declared for every platform
// while only Linux ever drew them, so Windows was promised two rows it has never
// had. They say platforms = ["linux"] now, and the eight rows Windows DOES draw
// are declared beside them — the IA menu's second shared description folded into
// the manifest. Windows answers every row the manifest offers it.
// hs 5 → 0: the hotstrings submenu reads the manifest. Those five were its five
// declared `list` rows — the standard, dynamic, ergopti, personal and extension
// category blocks — which this driver assembled by hand while the declaration
// named slots nothing filled. Every row every driver declares is answered now.
const BASELINE = { ahk: 0, hs: 0, linux: 0 };

// The manifest types that name a behaviour the driver must register: `action`
// and `dynamic` hand the id to a handler, `list` to a provider, `check` and
// `command` to a named command. A row of any other type is drawn from the
// declaration alone and has nothing for a driver to miss.
const BEHAVIOUR_TYPES = new Set(['action', 'dynamic', 'list', 'check', 'command']);

// WHY LINUX IS ZERO AND macOS IS NOT, AND WHAT THE FIVE ARE.
// Linux reached zero by wiring every row: its metrics and hotstrings submenus
// render from the manifest, and the rows it could never draw were restricted
// away with reasons. macOS wired its hotstrings-parameters group the same way
// and stopped at five, for a reason worth writing down rather than re-deriving:
//
//   hotstring_bulk_actions, hotstring_categories_{standard,dynamic,ergopti}
//     macOS assembles this submenu in a DIFFERENT SHAPE from the manifest. Its
//     section headers carry live counts (menu.hotstrings.header_common_count,
//     formatted with a total) where a manifest section_header is a static key,
//     and it merges the standard and dynamic categories into one non-Ergopti
//     block. Making the three ids true means reshaping the menu the user sees —
//     three categories with plain headers — or teaching section_header to carry
//     a count. Either is a product decision, not a wiring job.
//
//   active_layouts
//     Built by hand in menu_keyboard_layout.lua, which does not go through the
//     renderer at all. One handler once that submenu is routed.
//
// A CAUTION FROM THE SAME PASS. An unresolved id does NOT mean the driver lacks
// the feature. Seven macOS rows counted here were handled all along — their
// dispatch tables used bare Lua keys, which this scan cannot see because it
// looks for a quoted string. Quoting them changed nothing but the count. Worse,
// magic_key_config was read as "no Lua driver can edit the magic key" and nearly
// restricted out of the macOS menu it has always been in: the row is built
// inline in menu_hotstrings_management, id unnamed. Check the driver before
// concluding anything from a number here.

// Floors: a driver whose scan collapses would report zero unresolved rows and
// pass while having read nothing.
// linux 20 → 12 on 2026-08-04. The floor guards against a broken manifest walk,
// which would report ~0 declared rows; it is not a target. Eleven rows were
// restricted away from this driver in the same pass because they enumerate
// ahk-only features, so the honest declared count fell to 16 and a floor of 20
// would have failed on correct data. Twelve still separates "16 real rows" from
// "the walk returned nothing".
const MIN_DECLARED = { ahk: 30, hs: 30, linux: 12 };

const PLATFORMS = [
	{ key: 'ahk', driver: 'windows', ext: '.ahk' },
	{ key: 'hs', driver: 'macos', ext: '.lua' },
	{ key: 'linux', driver: 'linux', ext: '.lua' }
];

const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
const sections = Object.entries(manifest).filter(([k, v]) => !k.startsWith('_') && Array.isArray(v));

/** A row with no `platforms` list is visible everywhere — that is the documented default. */
function visibleOn(entry, platform) {
	if (!Array.isArray(entry.platforms)) return true;
	return entry.platforms.includes(platform);
}

const errors = [];
const summary = [];

for (const { key, driver, ext } of PLATFORMS) {
	const base = path.join(SP, driver);
	if (!fs.existsSync(base)) {
		errors.push(`${driver}: driver directory is missing — its rows are unchecked`);
		continue;
	}

	// The driver's production source, as one corpus. A handler is "named" when
	// the row id appears as a quoted string: every driver dispatches by id, and
	// the id has to be written down somewhere to be dispatched on.
	const chunks = [];
	(function walk(dir) {
		for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
			const p = path.join(dir, e.name);
			if (e.isDirectory()) {
				if (e.name !== 'tests' && e.name !== 'vendor' && e.name !== 'node_modules') walk(p);
			} else if (path.extname(e.name) === ext) {
				chunks.push(fs.readFileSync(p, 'utf8'));
			}
		}
	})(base);
	const corpus = chunks.join('\n');

	if (chunks.length < 20) {
		errors.push(`${driver}: read only ${chunks.length} source file(s) — the scan is broken`);
		continue;
	}

	const declared = [];
	for (const [section, rows] of sections) {
		for (const row of rows) {
			if (!row || typeof row !== 'object') continue;
			// Every id-bearing type whose behaviour the driver has to supply.
			//
			// Was `action` and `dynamic` alone, and that made the floor below
			// measure the OLD shape: each migration to `list`, `check` or
			// `command` moved rows out of the count, and the floor fired as if
			// the manifest walk had broken. The set has to be what the renderer
			// looks a driver up for, or the guard fights the work it guards.
			if (!BEHAVIOUR_TYPES.has(row.type)) continue;
			if (typeof row.id !== 'string' || row.id === '') continue;
			if (!visibleOn(row, key)) continue;
			declared.push({ section, id: row.id });
		}
	}

	if (declared.length < MIN_DECLARED[key]) {
		errors.push(
			`${key}: only ${declared.length} behaviour row(s) declared (floor ${MIN_DECLARED[key]}) — ` +
				'the manifest walk is broken, and every row would then look resolved'
		);
		continue;
	}

	const unresolved = declared.filter(({ id }) => !corpus.includes(`"${id}"`) && !corpus.includes(`'${id}'`));
	summary.push(`${key} ${unresolved.length}/${BASELINE[key]}`);

	if (unresolved.length > BASELINE[key]) {
		const added = unresolved.slice(0, 6).map((u) => `${u.section}.${u.id}`);
		errors.push(
			`${key}: ${unresolved.length} declared menu row(s) have no handler named in ${driver}/ ` +
				`(baseline ${BASELINE[key]}). The manifest promises the user a row; the renderer looks up a ` +
				'handler by id and finds none, so the row either vanishes with a warning nobody reads or ' +
				'does nothing when clicked — and every manifest-reading gate still passes. ' +
				`Wire it up, or drop the row. Do NOT raise the baseline.\n      unresolved: ${added.join(', ')}` +
				`${unresolved.length > 6 ? `, +${unresolved.length - 6} more` : ''}`
		);
	}

	// A ratchet that only stops the number rising lets a hard-won drop be given
	// back for free: wire five rows today, unwire them next month, gate still
	// green. Lowering the baseline is one line and it is the line that makes the
	// gain permanent.
	if (unresolved.length < BASELINE[key]) {
		errors.push(
			`${key}: only ${unresolved.length} unresolved row(s) remain, below the baseline of ` +
				`${BASELINE[key]}. That is progress — lower BASELINE.${key} to ${unresolved.length} so it ` +
				'cannot be silently given back.'
		);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] menu rows with no handler:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(`\x1b[32m[OK] No new unresolved menu rows (${summary.join(', ')}).\x1b[0m`);
