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

// Frozen baselines: rows built OUTSIDE the renderer, per driver, on 2026-08-01.
// windows 230 total - 8 in renderer, macos 330 - 29, linux 100 - 97.
const BASELINE = {
	windows: 222,
	macos: 301,
	linux: 3
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
		renderers: new Set(['lib/manifest_menu.ahk'])
	},
	macos: {
		exts: ['.lua'],
		// hs.menubar consumes an array of row tables; a row is a `title =` that
		// sits with an action, a checkmark, or a nested menu.
		patterns: [/\btitle\s*=\s*\S/],
		context: /\b(?:fn|checked|disabled|menu)\s*=/,
		renderers: new Set(['lib/manifest_menu.lua', 'ui/menu/builder.lua'])
	},
	linux: {
		exts: ['.lua'],
		// Same row shape as macOS — `{ title = …, fn = … }`.
		patterns: [/\btitle\s*=\s*\S/],
		context: /\b(?:fn|checked|disabled|menu)\s*=/,
		renderers: new Set(['modules/menu/menu_builder.lua'])
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

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] menu rows built outside the renderer:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(`\x1b[32m[OK] No new menu rows outside the renderer (${summary.join(', ')}).\x1b[0m`);
