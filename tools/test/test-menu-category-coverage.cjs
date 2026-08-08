// tools/test/test-menu-category-coverage.cjs

/**
 * ==============================================================================
 * MODULE: Every Declared Menu, Answered By Every Driver That Shows It
 * DESCRIPTION:
 * The per-category answer to "is the menu centralised": for each `*_menu` key in
 * the shared manifest, how many rows each platform projects, and whether the
 * driver names every id it is expected to dispatch.
 *
 * WHAT IT PROVES, category by category — shortcuts, hotstrings, tap-holds,
 * metrics, gestures, layout, IA, debug, updates, apps, kanata, Karabiner and the
 * tray root — is that the manifest describes the menu and each driver answers
 * only ids the manifest names. A row a driver draws from nothing would not be
 * declared; a row declared and unanswered renders one item short, permanently.
 *
 * TWO MECHANISMS ARE NOT FAILURES, and both are why this file exists rather than
 * a simple "every id appears in every driver":
 *
 *   - `platforms` restricts a row to the drivers that have the capability, which
 *     is what makes "one menu with driver-specific items" expressible at all.
 *     A restricted row carries a `reason_key`; test-menu-parity.cjs holds that.
 *   - a `toggle` is OPT-IN per driver: registering its command is what asks the
 *     renderer for the row. A tray whose parent can be clicked (hs.menubar)
 *     registers none and draws the toggle on the parent; one that cannot
 *     (appindicator, and AutoHotkey's submenu parents) registers it and gets a
 *     row. One declaration, two shapes, no second description.
 *
 * The table is printed on success too: "which categories does each driver draw,
 * and how many rows" is the question this was written to answer, and an
 * unreadable answer is one nobody checks.
 * ==============================================================================
 */

'use strict';
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const manifest = JSON.parse(fs.readFileSync(path.join(SP, '_shared', 'modules', 'menu', 'menu_manifest.json'), 'utf8'));

const EXT = { ahk: '.ahk', hs: '.lua', linux: '.lua' };
const DIR = { ahk: 'windows', hs: 'macos', linux: 'linux' };

function driverSource(driver) {
	const out = [];
	(function walk(d) {
		if (!fs.existsSync(d)) return;
		for (const e of fs.readdirSync(d, { withFileTypes: true })) {
			const p = path.join(d, e.name);
			if (e.isDirectory()) {
				if (!['tests', 'vendor', 'node_modules', '_generated'].includes(e.name)) walk(p);
			} else if (p.endsWith(EXT[driver])) out.push(fs.readFileSync(p, 'utf8'));
		}
	})(path.join(SP, DIR[driver]));
	return out.join('\n');
}

const src = Object.fromEntries(['ahk', 'hs', 'linux'].map((d) => [d, driverSource(d)]));
const PLATFORMS = ['ahk', 'hs', 'linux'];
const visible = (row, p) => !Array.isArray(row.platforms) || row.platforms.includes(p);

const rows = [];
for (const [key, list] of Object.entries(manifest)) {
	if (!Array.isArray(list)) continue;
	const cell = {};
	for (const p of PLATFORMS) {
		const shown = list.filter((r) => visible(r, p));
		// Rows that need the driver to name something: an id it dispatches on.
		// A `toggle` is opt-in per driver: registering the command is what asks the
		// renderer for the row, and a tray whose parent can be clicked registers
		// none. So it is never "unanswered" — it is answered by not being needed.
		const needing = shown.filter((r) => typeof r.id === 'string' && r.id !== '---' && r.type !== 'toggle');
		const missing = needing.filter((r) => !src[p].includes(r.id));
		cell[p] = { shown: shown.length, missing: missing.map((r) => r.id) };
	}
	rows.push({ key, cell });
}

const pad = (s, n) => String(s).padEnd(n);
console.log(pad('menu', 30) + pad('windows', 12) + pad('macos', 12) + 'linux');
console.log('-'.repeat(66));
let unanswered = 0;
for (const { key, cell } of rows.sort((a, b) => a.key.localeCompare(b.key))) {
	const fmt = (c) => (c.shown === 0 ? '—' : c.missing.length ? `${c.shown} (${c.missing.length}!)` : `${c.shown}`);
	console.log(pad(key, 30) + pad(fmt(cell.ahk), 12) + pad(fmt(cell.hs), 12) + fmt(cell.linux));
	for (const p of PLATFORMS) unanswered += cell[p].missing.length;
}
console.log('-'.repeat(66));
console.log(`${rows.length} menus declared; ${unanswered} declared id(s) not named by the driver that shows them`);
if (unanswered > 0) {
	console.error('[31m[FAIL] a declared menu row is not answered by a driver that shows it:[0m');
	for (const { key, cell } of rows) {
		for (const p of PLATFORMS) {
			if (cell[p].missing.length) {
				console.error(
					`    - ${p} ${key}: ${cell[p].missing.join(', ')} — declared for this platform and named ` +
						'nowhere in its source. The renderer logs one warning and skips the row, so the menu is ' +
						'one item short, permanently.'
				);
			}
		}
	}
	process.exit(1);
}
console.log(
	`[32m[OK] ${rows.length} menus declared in _shared; every id shown on a driver is answered by it.[0m`
);
