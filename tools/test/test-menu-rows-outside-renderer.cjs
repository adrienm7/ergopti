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
const BASELINE = {
	windows: 220,
	macos: 301,
	linux: 2
};

// Floors on the TOTAL count. A predicate that silently stops matching would
// otherwise drive the outside-count to zero and pass while measuring nothing.
const MIN_TOTAL = {
	windows: 180,
	macos: 260,
	linux: 80
};

const DRIVER_SPEC = {
	windows: {
		exts: ['.ahk'],
		// RegisterMenuItem(...) and the MenuAdd* helpers are the sanctioned row
		// calls; `<something>Menu.Add(` / `Sub*.Add(` is a row added straight to a
		// Menu object. Restricting the receiver keeps Array.Add and Map.Add out.
		patterns: [/\bRegisterMenuItem\s*\(/, /\bMenuAdd[A-Za-z]*\s*\(/, /\b(?:[A-Za-z_]*Menu|Sub[A-Za-z_]*|M)\.Add\s*\(/],
		renderers: new Set(['infra/manifest_menu.ahk'])
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
		renderers: new Set(['ui/menu/menu_builder.lua'])
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
	if (inRenderer === 0) {
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
const LIST_PROVIDERS_FLOOR = { linux: 1 };

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
