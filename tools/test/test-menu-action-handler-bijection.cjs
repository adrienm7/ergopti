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
const BASELINE = { ahk: 0, hs: 20, linux: 27 };

// Floors: a driver whose scan collapses would report zero unresolved rows and
// pass while having read nothing.
const MIN_DECLARED = { ahk: 30, hs: 30, linux: 20 };

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
			if (row.type !== 'action' && row.type !== 'dynamic') continue;
			if (typeof row.id !== 'string' || row.id === '') continue;
			if (!visibleOn(row, key)) continue;
			declared.push({ section, id: row.id });
		}
	}

	if (declared.length < MIN_DECLARED[key]) {
		errors.push(
			`${key}: only ${declared.length} action/dynamic row(s) declared (floor ${MIN_DECLARED[key]}) — ` +
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
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] menu rows with no handler:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(`\x1b[32m[OK] No new unresolved menu rows (${summary.join(', ')}).\x1b[0m`);
