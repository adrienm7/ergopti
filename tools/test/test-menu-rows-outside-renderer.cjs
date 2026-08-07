// tools/test/test-menu-rows-outside-renderer.cjs

/**
 * ==============================================================================
 * MODULE: Menu-Row Bypass Ratchet (I3)
 * DESCRIPTION:
 * The number of menu rows built outside each driver's renderer may never rise.
 *
 * THE INVARIANT THIS SERVES:
 * One menu — the manifest describes what the user sees, the renderer describes
 * how this OS draws a row, and the driver supplies only named actions, state
 * getters and list providers. A row created anywhere else is a row no manifest
 * describes: it cannot be compared across drivers, it has no `platforms` field,
 * and it is invisible to every gate that reads the manifest.
 *
 * WHY A RATCHET AND NOT A BAN:
 * Measured on 2026-08-01, the three drivers are in completely different places.
 * Linux already builds 97 of its 100 rows inside menu_builder.lua. Windows
 * builds 8 of 230 inside the renderer, macOS 29 of 330. Banning the bypass today
 * would mean rewriting two menu layers in one change, so the count is frozen
 * instead: the migration can proceed row by row, and nothing new accumulates
 * while it does.
 *
 * Lower these baselines as rows migrate. Never raise them.
 *
 * WHAT COUNTS AS A ROW:
 * Each driver has its own row API, and using one predicate for all three is how
 * a first attempt produced numbers that meant nothing — `.Add(` matched every
 * AutoHotkey object, `title =` matched dialog and window titles, and Linux
 * scored 6 because it does not use `label =` at all. The predicates below follow
 * the actual call each driver makes, and are pinned by the floors: a predicate
 * that stops matching reports a suspiciously low count instead of passing.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS = path.join(ROOT, 'static', 'ergopti_plus');

const MEASURE = process.argv.includes('--measure');

// Frozen baselines: rows built OUTSIDE the renderer, per driver, on 2026-08-01.
// Re-measured 2026-08-04 with --measure: windows 232 total - 12 in the renderer,
// macos 331 - 30, linux 99 - 96. Every one of the three had drifted from the
// frozen header; run --measure rather than trusting this line.
// windows lowered 222 → 220 on 2026-08-03: the keyboard-shortcut groups moved
// onto the manifest "list" type, so the renderer builds them.
//
// ── WHAT LOWERS THIS NUMBER, because getting it wrong costs a large refactor ──
//
// Routing a menu through ManifestMenu.build does NOT lower it. Three macOS menus
// already call it — menu_gestures, menu_metrics, menu_shortcuts — and all three
// are still counted here, 16, 16 and 26 rows respectively. The reason is the
// `dynamic` item type: the manifest names a handler and the handler appends its
// rows IN THE DRIVER FILE, so the manifest describes the SLOT and the driver
// still builds the row. That is the whole distinction this ratchet measures.
//
// A row leaves this count only when the RENDERER materialises it: as a static
// `action` / `section_header` / `---` / `group` entry, or as a `list` row, where
// the provider returns `label = …` data and manifest_menu.lua turns it into the
// menu item. Converting a hand-built block to a `dynamic` handler moves nothing
// and is easy to mistake for progress — the 2026-08-03 windows drop came from a
// `list` migration, which is the only kind that has ever moved this number.
//
// Corollary worth knowing before reading a fall as a win: the macOS predicate
// keys on the field name `title =`, and provider rows use `label =`. So the
// number measures who owns the hs.menubar shape, not how many rows a user sees.
// linux lowered 3 → 2 on 2026-08-04: the gestures submenu moved onto
// ManifestMenu.build, so the rows the daemon used to append by hand — including
// an undeclared libinput row with a hardcoded French label — are dispatched from
// the manifest. The two that remain are in ergopti_hotstrings.lua.
//
// ── linux 2 → 124 on 2026-08-05, and that is NOT a regression ──
//
// Read the number before reading the jump. Until today this file listed
// `ui/menu/menu_builder.lua` as "the Linux renderer", so every one of that file's
// row sites counted as INSIDE and Linux read 2/2 — a number that could not move
// no matter how much of the menu was hand-built, because the hand-building WAS
// the renderer by definition. Linux is the only driver whose renderer is entirely
// shared (_shared/lua/menu/renderer.lua, bound by infra/manifest_menu.lua), and
// menu_builder.lua is a CALLER of it, exactly as menu_shortcuts.lua is on macOS —
// which this file has always counted as outside.
//
// So the definition was wrong and the measurement was vacuous. Nothing got worse
// today; the dial started working. The debt was 136 when the definition changed
// (134 sites in menu_builder.lua plus the 2 in ergopti_hotstrings.lua the old
// baseline named) and is frozen here at the 124 measured after the kanata and
// updates submenus moved onto `list` providers — freezing at the pre-migration
// figure would have quietly given back the twelve rows those two blocks cost.
//
// It may now fall, and each `list` migration is what lowers it. See the paragraph
// above for why nothing else does. 124 → 120 the same day, when the two
// Linux-only gesture rows moved from `dynamic` to `list` — the slot list alone is
// thirty-odd rows with a nested action picker each, all of which the renderer now
// materialises from data.
// linux 120 → 115 on 2026-08-06. Two migrations, and only one of them was about
// row counts:
//   - the three metrics privacy filters became `type = "check"`, a NEW
//     declarative type in the shared renderer. Until it existed, every type that
//     carried behaviour handed the manifest key back to a driver function that
//     built the row itself — which is the whole reason this number was 639
//     across the three drivers. A shared renderer that could not build a
//     checkbox was never going to centralise a menu.
//   - the debug submenu moved onto the manifest and gained the two rows this
//     driver had never built.
//
// ── The `check` type, and why all three fell in one commit ──
//
// windows 220 → 217, macos 301 → 298, linux 120 → 115 on 2026-08-06.
//
// The three privacy filters are ONE manifest declaration now, and each driver's
// renderer materialises it: `type = "check"` carries the label key, the
// checked_when predicate and the disabled_when predicate, and the driver
// registers only a named command. Both renderers gained the type in the same
// change — _shared/lua/menu/renderer.lua and windows/infra/manifest_menu.ahk —
// because a shared declaration that only one renderer understands is a row that
// disappears on the other two.
//
// This is the lever the rest of the migration turns on. Until it existed, EVERY
// manifest type that carried behaviour ("action", "dynamic") handed the id back
// to a driver function that built the row itself, so routing a menu through the
// renderer moved nothing and the honest count stayed near 639. A `list` provider
// was the only thing that had ever moved it, and a list cannot express a single
// checkbox.
//
// windows 217 → 206, macos 298 → 289, linux 115 → 109 on 2026-08-06: the
// word-expanders submenu. Each driver rebuilt the same twenty-odd rows in its
// own row API — the bulk actions, the catalogue in catalogue order, the custom
// delimiters with their delete sub-row, the add button. It is `type = "list"`
// now and each driver answers with the same {label, action, checked, items}
// data, which the renderer materialises.
//
// windows 206 → 204, linux 109 → 107: the two whole-tree bulk rows. They were
// ONE `dynamic` row that expanded to two, so the manifest described neither and
// macOS — which had no handler for that id at all — rendered nothing. They are
// two `command` rows now.
//
// windows 204 → 197, linux 107 → 86 on 2026-08-06: the five hotstring category
// blocks — standard, dynamic, ergopti, personal and extensions. Linux already
// held its rows as data, so the whole tree moved. Windows attaches
// SubMenus[Category], a Menu assembled by another subsystem, so its ROW moved
// and the tree behind it did not: the AHK renderer gained a narrow `submenu`
// field for exactly that hand-over, and turning that tree into data is the next
// migration rather than a precondition for this one.
//
// macos 289 → 277 on 2026-08-06: the Karabiner submenu. Thirty-six rows with no
// manifest entry at all — the last menu in the project that nothing described.
// Its deep pickers keep their own recursion and reach the renderer through
// MenuUtils.as_provider_row, because rewriting a tree to move a menu onto the
// renderer is a different job from moving the menu.
//
// macos 277 → 274: the active-layouts list. `dynamic:active_layouts` has been
// declared for this platform since the manifest was written and answered by
// nobody — the rows were built in place, so the declaration named a slot the
// driver never filled and no gate could see it until the handler gate learned to
// look at `list` rows too.
//
// windows 197 → 196, macos 274 → 262, linux 86 → 84: the wrap-symbol picker.
// The manifest called it platforms = ["ahk"] and all three drivers had been
// building it — the third time that exact shape has been found here, a
// restriction recording who wrote the feature first rather than what the
// platforms can do. It also settled WHERE it hangs: Windows and Linux showed it
// as a sibling row, macOS as a submenu of the wrap-text toggle.
//
// macos 262 → 260: the LLM model and generation rows. Both are declared in
// `llm_menu` and macOS read that key for neither — it built the two rows in
// place AND wrote out the separator the manifest puts between them, so three
// pieces of one declaration were reproduced by hand.
//
// macos 260 → 259: the gesture menu's four slot groups and its circular-spaces
// toggle. The slot ids come from the manifest's OWN `gesture_slots` table, so
// those rows were already manifest data being appended by hand.
//
// macos 259 → 227: the LLM model selector. Thirty-two rows, and the biggest
// single file left on this driver. It used to hand over an hs.menubar tree that
// an adapter rewrote into provider rows at EVERY menu build; it returns provider
// rows directly now, and only the api-backend branch — which still builds a tree
// of its own — is adapted. A conversion layer that covers everything is a layer
// that never goes away.
//
// linux 84 → 81: the global-actions submenu, now three `command` rows and a
// declared separator rather than four hand-written entries on each driver.
//
// linux 81 → 75: the five metrics readouts this driver answers in its log
// rather than in a window. They are Linux's OWN rows — the other two open a
// metrics window for the same figures — and nothing described them, so no gate
// could compare, reason about or find them. Declared with the reason attached,
// which is what the manifest is for when a row really is driver-specific.
//
// macos 227 → 229, and this is the one direction the header above tells you not
// to move. It is not two new hand-built rows: it is two rows that already
// existed changing dialect. The IA menu's model and generation rows used to
// reach the renderer as `list` provider rows (`label`/`items`), which this
// predicate does not see; all eight of that menu's rows now reach it as
// `dynamic` handler rows (`title`/`menu`), which it does.
//
// The trade was deliberate. Those two rows were the only ones the renderer
// materialised, and their placement was the only thing shared — so macOS drew
// the model row ninth while Windows drew it second, from one spec that claimed
// to own the order. All eight rows are placed by the manifest now, in one
// order, on both drivers. Two rows lost `list` materialisation; eight gained a
// shared position. Whoever decomposes this menu further should win those two
// back by making the rows themselves declarable, not by unpicking the order.
//
// linux 75 → 69: the seven selection operations — CapsWord, the three case
// transforms, select word, select line, paste without formatting — reach the
// renderer as provider data instead of being appended by the driver. They were
// seven rows of a SHARED menu that no manifest described, so no gate could
// compare them with what the other two drivers put in the same place.
//
// macos 229 → 228: the two separators the keyboard-layout menu wrote out around
// its install and logo blocks are `---` rows in the manifest now. The blocks
// themselves reach the renderer as provider data, but their rows are still
// written in this driver's dialect, so the predicate keeps counting them — see
// the paragraph above about what this number measures.
//
// windows 196 → 195, macos 227 → 226, linux 69 → 68 on 2026-08-07: the
// repeat-key toggle. One checkbox, drawn three times from a declaration that
// named only the slot — AutoHotkey with RegisterMenuItem + M.Check, macOS and
// Linux each with their own table. It is `type = "check"` now and each driver
// supplies just the toggle and the state behind the tick. All three fall
// together, which is what a real migration looks like on this ratchet.
const BASELINE = {
	// 174 → 160: the wrap-symbols tree. It reached the renderer through a `list`
	// provider but as a finished native Menu, so every level of it was assembled
	// in the driver — fourteen rows of bulk actions, per-family groups, the
	// custom pairs and their delete entries. The renderer builds all of it now,
	// nesting included.
	// 160 → 152: not a migration. menu_engine.ahk's MenuAdd* helpers joined the
	// renderer set, because the predicate already counts every `MenuAdd*(` call a
	// driver makes and was counting the RegisterMenuItem inside the helper too —
	// the same row charged where it was asked for and again where it was drawn.
	// 94 → 86: the tap-holds menu. Its two buttons are `command` declarations and
	// the per-key tree is a `list` — the key, its disable / tap / hold rows, and
	// the hold options inside that. Three levels, drawn by the renderer.
	// 105 → 94: the profile picker with its per-app overrides, and the remote-API
	// endpoint list. That is the whole IA menu now: only the top-level dispatch
	// stays native, because it reads the tray's own state to paint the health dot.
	// 116 → 105: the backend picker and the whole model tree — provider, model,
	// then the per-model specs sheet, the deepest tree the driver draws. The
	// catalogue keeps its own function boundary (_LLM_Menu_AppendCatalogue) only
	// because a regression test pins the call that appends it.
	// 137 → 116: the five IA settings submenus — count, trigger, generation,
	// display, navigation. Each was a native Menu with the ticks and the greying
	// applied by hand; every action rebuilds the tray rather than repainting it,
	// so all five are row data and the renderer draws them.
	// 144 → 137: the bundled-extensions tree. Three levels deep — extension, TOML
	// file, its sections — which is exactly what the renderer's nesting allows,
	// and every leaf is a label or « open the file », so none of it mutates the
	// live menu.
	// 152 → 144: the delays-and-colours submenu. It was a native Menu handed over
	// in `submenu`; none of its rows mutates the live menu — each opens a prompt
	// and the tray rebuilds after — so nothing held them back from being data.
	windows: 86,
	// 228 → 227: the pause/resume layout pickers moved with them, and the
	// separator that framed them is a `---` row too.
	// 223 → 211: the gesture slot rows. slotItem built them in this driver's
	// dialect and the provider translated each one on the way out, so the tree
	// was still assembled here and every row of it counted. They are provider
	// data now and the renderer materialises them — which also retired the
	// adapter call and the section() helper that had no caller left.
	// 211 → 191: the Karabiner menu. Every row in that file flows into
	// karabiner_menu through one of three list providers, which translated each
	// one on the way out — so the tree was still assembled there. They are
	// provider data now.
	// 191 → 153: the personal-hotstrings tree and the keyboard-layout blocks.
	// Both fed a provider through as_provider_row, so the driver assembled the
	// tree and the renderer materialised a translation of it. They emit provider
	// rows themselves now, which retired the adapter in the layout menu — it had
	// become the identity function — and the import it was the only user of.
	// 144 → 135: the hotstrings-parameters builders. They fed three providers
	// through as_provider_row, so the driver assembled the trees and the renderer
	// materialised translations of them. They emit provider rows now, and the
	// import the adapter was the only user of went with them.
	// 135 → 124: the hotstring category and personal builders. Only the
	// extension rows are still adapted, and the comment beside as_rows says so.
	// 124 → 122: the two menubar-WPM rows became `check`. They were dynamic
	// handlers building a checkbox the renderer already knows how to draw.
	// 122 → 120: the Ctrl and Cmd shortcut groups. The shared renderer's `group`
	// branch materialises `items` now, the same way a `list` row's provider rows
	// are, so a group builder hands over DATA instead of a finished tree.
	// 120 → 118, windows 178 → 176: the two metrics window buttons. A label, a
	// greying rule and a click — declared `command` now, built once each.
	// 118 → 117, windows 176 → 175: the at-rest encryption switch, which also
	// stopped reading under two different names on the three drivers.
	// 117 → 116, windows 175 → 174: the WPM-position reset. Its two neighbours
	// stay `dynamic` because they mutate the live menu; this one sets nothing.
	// 65 → 56: the script-control shortcut tree — three key submenus and the whole
	// action list under each — and the MLX port rows the IA menu appends to the
	// model selector's tree. The parent row of each stays the driver's: both carry
	// the current binding in their label.
	// 82 → 65: the profile picker, with its per-profile edit/delete submenu. One
	// line in it is NOT a row and must never be renamed: prompt_shortcut takes a
	// `title` of its own, and the predicate counts it because it cannot tell a
	// dialog from a row.
	// 108 → 82: the rest of the IA menu's contents — the API entries and their
	// model picker, the display panel, the backend switcher, the temperature
	// rows, and the generation, navigation and prediction-count submenus. The
	// PARENT rows stay the driver's: their labels carry a health dot, a model
	// name, a count. What hung off them never needed to.
	// 116 → 108: the IA trigger panel, the macOS twin of the Windows submenu
	// converted the same day. The shared renderer gained R.render_rows for it — a
	// subtree whose parent row is still the driver's can now hand its contents
	// over as data instead of staying hand-built because one row above it is.
	macos: 56,
	// 68 → 66: the preview-bubble switches. Both Lua drivers built the same tree
	// of four; it is a `list` now and the renderer materialises it. macOS holds
	// at 226 because its rows are still written in the driver dialect and
	// converted at the provider — the distinction this header is about.
	// 66 → 64, windows 195 → 194: the magic-key row and its reset. Two rows,
	// built three times, from a declaration that named only the slot.
	// 64 → 58, windows 194 → 193: the delays-and-colours row, the last of the
	// hotstring-parameters group to move. Its submenu is still each driver's,
	// handed over as `submenu`; what left the drivers is the row and, on Linux,
	// the six delay entries inside it.
	// 58 → 55: the locale rows. They are provider data now, and the tick is the
	// tray's own check item instead of a "✓" glued to a translated label.
	// 55 → 53: the Applications submenu, two command rows and their separator.
	// 53 → 51, with windows 189 → 187 and macos 225 → 223: the two whole-tree
	// gesture actions. One declaration each, three drivers registering only the
	// click — all three fall together, which is what a real migration looks like.
	// 51 → 49: the base-layout rows, derived from the decoder's own table
	// instead of two names written into the builder.
	// 49 → 50, and this is the one direction the header warns about, so the
	// reason is here. The About entry was a single clickable row on this driver —
	// one site — and is a SUBMENU now, because about_menu is declared and its
	// changelog row is the renderer's. A submenu costs its container, which the
	// driver has to name: the same incompressible "one wrapper per entry" this
	// file already carries for the other twelve. One row moved into the renderer
	// and one wrapper appeared to hold it.
	linux: 50
};

// Floors on the TOTAL count. A predicate that silently stops matching would
// otherwise drive the outside-count to zero and pass while measuring nothing.
//
// macos lowered 260 → 220 on 2026-08-06, and the reason matters because it is
// the second time a guard in this repository has been found measuring the OLD
// shape of the thing it guards. The Lua predicates key on `title =`, which is
// the hs.menubar field — and a row that MOVES to the renderer stops using it,
// because provider data says `label =`. So every successful migration shrinks
// this total by construction, and the floor eventually fires on progress.
//
// It is not raised back and it is not removed: it still catches a predicate that
// stopped matching. It is set below the count a fully-migrated macOS would show
// rather than just under today's, so it cannot fire on the next migration
// either. If it ever fires again, check whether `title =` is still the field
// this driver's rows use BEFORE assuming the tree shrank.
const MIN_TOTAL = {
	// windows lowered 180 → 120 on 2026-08-07, for the reason given for macOS
	// below: the predicate keys on the driver's own row calls, so every
	// conversion of a native Menu tree to provider rows shrinks the total by
	// construction and the floor eventually fires on progress. 120 is below what
	// a driver with a fully migrated menu would still show, not merely under
	// today's number.
	// windows lowered 120 → 80 on 2026-08-07, same reason again: the IA menu was
	// the driver's biggest reservoir of hand-built rows and converting it took the
	// total to 115, four under the floor. 80 is under what a Windows driver whose
	// menu is fully migrated would still show — the renderer's own Add calls, the
	// tray root, and the handful of rows that mutate a live menu.
	windows: 80,
	// macos lowered 220 → 120 on 2026-08-07, for the reason stated above it: the
	// predicate keys on `title =`, so every conversion of a builder to provider
	// data shrinks the total by construction and the floor eventually fires on
	// progress. 120 is below what a driver with a fully migrated menu would still
	// show — the submenu wrappers and the rows no declaration can carry — rather
	// than merely under today's number.
	// macos lowered 120 → 100 on 2026-08-07, for the reason stated above it: the
	// predicate keys on `title =`, so every conversion of a builder to provider
	// data shrinks the total by construction and the floor eventually fires on
	// progress.
	// macos lowered 100 → 60 on 2026-08-07, same reason a third time: the IA menu
	// was this driver's biggest reservoir of hand-built rows and converting it
	// took the total to 85, fifteen under the floor. 60 is under what a macOS
	// driver whose menu is fully migrated would still show — the renderer's own
	// rows, the pickers other subsystems own, and the dialog titles the predicate
	// counts because it cannot tell them from a row.
	macos: 60,
	// linux lowered 80 → 55 on 2026-08-06 and 55 → 30 on 2026-08-07, both times
	// for the reason given for macOS above: the predicate keys on `title =`, so
	// every successful migration shrinks the total by construction and the floor
	// eventually fires on progress. 30 is below what a driver with a fully
	// migrated menu would still show, not merely under today's number.
	linux: 30
};

const DRIVER_SPEC = {
	windows: {
		exts: ['.ahk'],
		// RegisterMenuItem(...) and the MenuAdd* helpers are the sanctioned row
		// calls; `<something>Menu.Add(` / `Sub*.Add(` is a row added straight to a
		// Menu object. Restricting the receiver keeps Array.Add and Map.Add out.
		patterns: [/\bRegisterMenuItem\s*\(/, /\bMenuAdd[A-Za-z]*\s*\(/, /\b(?:[A-Za-z_]*Menu|Sub[A-Za-z_]*|M)\.Add\s*\(/],
		// ui/menu/menu_engine.ahk joined the set on 2026-08-07, and this is a
		// correction of DOUBLE COUNTING rather than a migration. Its three
		// MenuAdd* helpers are this driver's row materialisation — the manifest
		// renderer calls them at four places — and the predicate above already
		// counts every `MenuAdd*(` call a driver file makes. Counting the
		// RegisterMenuItem inside the helper as well charged the same row twice:
		// once where it was asked for, once where it was drawn.
		renderers: new Set(['infra/manifest_menu.ahk', 'ui/menu/menu_engine.ahk'])
	},
	macos: {
		exts: ['.lua'],
		// hs.menubar consumes an array of row tables; a row is a `title =` that
		// sits with an action, a checkmark, or a nested menu.
		patterns: [/\btitle\s*=\s*\S/],
		context: /\b(?:fn|checked|disabled|menu)\s*=/,
		renderers: new Set(['infra/manifest_menu.lua', 'ui/menu/builder.lua'])
	},
	linux: {
		exts: ['.lua'],
		// Same row shape as macOS — `{ title = …, fn = … }`.
		patterns: [/\btitle\s*=\s*\S/],
		context: /\b(?:fn|checked|disabled|menu)\s*=/,
		// This driver's renderer lives entirely in _shared/lua/menu/renderer.lua;
		// infra/manifest_menu.lua is the binding that hands it this platform's
		// token, its manifest path and its JSON decoder, and builds no row itself.
		// So the set is empty ON PURPOSE, and `sharedRenderer` says so — without it
		// the "a renderer that draws no rows is not a renderer" guard below reads
		// the empty count as a stale path and refuses to measure anything.
		renderers: new Set([]),
		sharedRenderer: true
	}
};

// How far above or below a row's own line the action field may sit for the row
// to count. Three lines covers the formatting in use without swallowing the
// next table.
const CONTEXT_LINES = 3;

const errors = [];
const summary = [];

/** Counts rows in one driver, split by whether the file is its renderer. */
function countRows(driver, spec) {
	const base = path.join(DRIVERS, driver);
	let total = 0;
	let inRenderer = 0;
	const offenders = new Map();

	(function walk(dir) {
		if (!fs.existsSync(dir)) return;
		for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
			const p = path.join(dir, e.name);
			if (e.isDirectory()) {
				if (e.name !== 'tests' && e.name !== 'vendor' && e.name !== '_generated' && e.name !== 'node_modules') {
					walk(p);
				}
				continue;
			}
			if (!spec.exts.includes(path.extname(e.name))) continue;

			const rel = path.relative(base, p).split(path.sep).join('/');
			const lines = fs.readFileSync(p, 'utf8').split(/\r?\n/);
			let n = 0;
			lines.forEach((line, i) => {
				const t = line.trimStart();
				if (t.startsWith('--') || t.startsWith(';') || t.startsWith('//')) return;
				if (!spec.patterns.some((rx) => rx.test(line))) return;
				if (spec.context) {
					const window = lines.slice(Math.max(0, i - CONTEXT_LINES), i + CONTEXT_LINES + 1).join('\n');
					if (!spec.context.test(window)) return;
				}
				n++;
			});
			if (n === 0) continue;
			total += n;
			if (spec.renderers.has(rel)) inRenderer += n;
			else offenders.set(rel, n);
		}
	})(base);

	return { total, inRenderer, outside: total - inRenderer, offenders };
}

for (const [driver, spec] of Object.entries(DRIVER_SPEC)) {
	const { total, inRenderer, outside, offenders } = countRows(driver, spec);

	if (total < MIN_TOTAL[driver]) {
		errors.push(
			`${driver}: found only ${total} menu row(s) (floor ${MIN_TOTAL[driver]}). The row predicate has ` +
				'stopped matching, which would drive the outside-count to zero and pass this ratchet while ' +
				'measuring nothing.'
		);
		continue;
	}

	// A renderer that draws no rows is not a renderer; the path is probably stale.
	// Unless the driver has no renderer of its own — Linux renders entirely through
	// the shared module, so zero here is the correct answer rather than a stale
	// path, and treating it as an error is what let the old definition stand.
	if (inRenderer === 0 && !spec.sharedRenderer) {
		errors.push(
			`${driver}: no rows found in ${[...spec.renderers].join(', ')} — the renderer path is wrong, ` +
				'so every row counts as a bypass and the baseline below is meaningless'
		);
		continue;
	}

	summary.push(`${driver} ${outside}/${BASELINE[driver]}`);

	// --measure prints what the frozen header can only assert. The header's own
	// totals had drifted (it said "linux 100 - 97" against a measured 99 - 96)
	// because nothing could re-derive them, which is how a comment stops being
	// evidence and becomes folklore.
	if (MEASURE) {
		console.log(`${driver}: ${total} row site(s), ${inRenderer} in the renderer, ${outside} outside`);
		for (const [file, n] of [...offenders].sort((a, b) => b[1] - a[1]).slice(0, 8)) {
			console.log(`    ${String(n).padStart(3)}  ${file}`);
		}
	}

	if (outside > BASELINE[driver]) {
		const worst = [...offenders].sort((a, b) => b[1] - a[1]).slice(0, 5);
		errors.push(
			`${driver}: menu rows built outside the renderer rose to ${outside} (baseline ` +
				`${BASELINE[driver]}). A row created outside the renderer is a row no manifest describes — ` +
				'it has no platforms field and no gate can compare it across drivers. Add the row to ' +
				`_shared/modules/features/manifest.toml [menu.*] instead. Do NOT raise the baseline.\n` +
				`      largest bypasses: ${worst.map(([f, n]) => `${f} (${n})`).join(', ')}`
		);
	}
}

// ==================================================
// ==================================================
// ======= 2/ The migration needs its own dial ======
// ==================================================
// ==================================================

// The count above cannot see the Linux migration at all. It treats
// menu_builder.lua as "the Linux renderer", so all 134 of that file's row sites
// count as INSIDE and Linux reads 2/2 no matter what moves. Repointing it would
// take Linux from 2 to 134 — a change of DEFINITION that reads as a regression,
// and a judgment about what the number means rather than a fact to be measured.
//
// So this counts the other direction instead: how many `list` providers the
// Linux driver registers. A `list` is the one manifest type whose rows the
// shared renderer materialises — `dynamic` and `action` hand the rendering
// straight back to platform code — so it is exactly the unit of progress, and a
// number that only goes UP needs nobody's arbitration to be honest.
//
// Raise it as blocks move. Never lower it: a provider that disappears is rows
// going back into the driver.
const LIST_PROVIDERS_FLOOR = { linux: 7 };

const MENU_MANIFEST = path.join(DRIVERS, '_shared', 'modules', 'menu', 'menu_manifest.json');
const LINUX_SRC = path.join(DRIVERS, 'linux', 'ui', 'menu', 'menu_builder.lua');
if (fs.existsSync(LINUX_SRC) && fs.existsSync(MENU_MANIFEST)) {
	const menuManifest = JSON.parse(fs.readFileSync(MENU_MANIFEST, 'utf8'));
	const src = fs.readFileSync(LINUX_SRC, 'utf8');
	// Each `local providers = { ["id"] = function … }` block is one migrated
	// submenu. Keyed on that exact name because it is the sixth argument of
	// ManifestMenu.build — the provider table — and naming it anything else would
	// make the block invisible here, which is a rename the reader can see rather
	// than a regex that quietly matches the wrong table.
	const declared = new Set();
	for (const rows of Object.values(menuManifest)) {
		if (!Array.isArray(rows)) continue;
		for (const row of rows) {
			if (row.type !== 'list' || typeof row.id !== 'string') continue;
			const on = Array.isArray(row.platforms) ? row.platforms : ['ahk', 'hs', 'linux'];
			if (on.includes('linux')) declared.add(row.id);
		}
	}

	// Counted against what the MANIFEST declares, not against the driver's own
	// spelling. A first version counted the table's keys, and renaming one left
	// the number unchanged while the submenu went empty — the provider was still
	// there, answering an id nobody asks for.
	const providers = new Set(
		[...src.matchAll(/local\s+providers\s*=\s*\{([\s\S]*?)\n\t\}/g)].flatMap((m) =>
			[...m[1].matchAll(/\["([a-z0-9_]+)"\]\s*=/g)].map((k) => k[1])
		)
	);
	const found = [...providers].filter((id) => declared.has(id)).length;
	if (found < LIST_PROVIDERS_FLOOR.linux) {
		errors.push(
			`linux: ${found} list provider(s) registered, down from ${LIST_PROVIDERS_FLOOR.linux}. A ` +
				'provider that disappears is rows moving back into the driver, which is the migration ' +
				'running backwards.'
		);
	} else {
		summary.push(`linux list providers ${found}/${LIST_PROVIDERS_FLOOR.linux}`);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] menu rows built outside the renderer:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(`\x1b[32m[OK] No new menu rows outside the renderer (${summary.join(', ')}).\x1b[0m`);
