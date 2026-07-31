// tools/test/test-menu-labels-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Menu Labels Single-Source Guard
 * DESCRIPTION:
 * Verifies that menu label formatters are single-sourced in
 * _shared/lua/menu/labels.lua: log_level_emoji, fmt_count, decorate_section.
 *
 * ROOT CAUSE ENCODED:
 * The log-level emoji map, count formatter, and section header decoration were
 * duplicated across macOS (Lua), Windows (AHK), and Linux (Lua). The Lua copies
 * were fused into _shared/lua/menu/labels.lua.
 *
 * IT CHECKED CONSUMPTION, WHICH IS NOT THE SAME AS ABSENCE:
 * The old gate named three macOS files and asserted each required the shared
 * module. Anything it did not name was free to re-implement the formatter — and
 * two files did: macos/ui/menu/menu_hotstrings.lua and menu_hotstrings_custom.lua
 * each carried their own byte-identical fmt_count. A "single-source" gate that
 * only inspects the files already known to comply cannot find a duplicate; it can
 * only confirm the compliance it already knew about.
 *
 * It is now an EXCLUSION ratchet over all three drivers: no file outside
 * _shared/lua/menu/labels.lua may define any of the three formatters, unless it
 * is named in DUPLICATES with a reason. Two things are asserted about that list —
 * a duplicate not on it fails, and an entry whose duplicate is gone fails too, so
 * the list shrinks as the migration proceeds and can never rot.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const p = require('path');

const ROOT = p.resolve(__dirname, '..', '..');
const SP = p.join(ROOT, 'static/ergopti_plus');
const CANONICAL = 'static/ergopti_plus/_shared/lua/menu/labels.lua';

const FORMATTERS = ['log_level_emoji', 'fmt_count', 'decorate_section'];

// A definition of one of the formatters, in either language. Lua:
// `function M.fmt_count(` / `local function fmt_count(`. AHK: `FmtCount(N) {`.
const LUA_DEF = (name) => new RegExp(`function\\s+(?:[\\w.]+\\.)?${name}\\s*\\(`);
const AHK_DEF = (name) => {
	const pascal = name
		.split('_')
		.map((w) => w[0].toUpperCase() + w.slice(1))
		.join('');
	// `_?` because AHK file-local helpers carry a leading underscore
	// (_LogLevelEmoji) while exported ones do not (FmtCount).
	return new RegExp(`^\\s*_?${pascal}\\s*\\([^)]*\\)\\s*\\{`, 'm');
};

// Known duplicates, each with the reason it still exists. The AHK copies are
// deliberate: the Windows menu is built in AutoHotkey and cannot require a Lua
// module, so they are hand-maintained and pinned by the section-decoration
// parity gate and the AHK suite instead. They go away when the menu renderer is
// shared.
const DUPLICATES = {
	'static/ergopti_plus/windows/lib/menu_helpers.ahk': ['fmt_count'],
	'static/ergopti_plus/windows/ui/menu/menu_rebuild.ahk': ['log_level_emoji']
};

const errors = [];

function read(rel) {
	return fs.readFileSync(p.join(ROOT, rel), 'utf8');
}

/**
 * Every production Lua/AHK source file across the three drivers and the shared
 * tree. Tests are excluded: they legitimately define stubs of these names.
 * @param {string} dir Absolute directory.
 * @param {string[]} acc Accumulator.
 * @returns {string[]} Absolute paths.
 */
function walk(dir, acc = []) {
	if (!fs.existsSync(dir)) return acc;
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = p.join(dir, e.name);
		if (e.isDirectory()) {
			if (e.name !== 'tests' && e.name !== 'node_modules') walk(full, acc);
		} else if (/\.(lua|ahk)$/.test(e.name)) {
			acc.push(full);
		}
	}
	return acc;
}

// ── 1. The canonical module must exist and export all three ─────────────────
if (!fs.existsSync(p.join(ROOT, CANONICAL))) {
	errors.push(`${CANONICAL}: missing — menu label formatters must be single-sourced`);
} else {
	const src = read(CANONICAL);
	for (const fn of FORMATTERS) {
		if (!src.includes('function M.' + fn)) {
			errors.push(`${CANONICAL}: missing function M.${fn}`);
		}
	}
}

// ── 2. Nobody else may define them ──────────────────────────────────────────
const files = walk(SP);
if (files.length < 500) {
	errors.push(`walk found only ${files.length} source file(s) — the scan is broken, and this gate would pass over nothing`);
}

const found = {}; // rel → [formatter, …]
for (const abs of files) {
	const rel = p.relative(ROOT, abs).replace(/\\/g, '/');
	if (rel === CANONICAL) continue;
	const src = fs.readFileSync(abs, 'utf8');
	const isAhk = rel.endsWith('.ahk');
	for (const fn of FORMATTERS) {
		const re = isAhk ? AHK_DEF(fn) : LUA_DEF(fn);
		if (!re.test(src)) continue;
		// A one-line delegation (`function M.x(t) return Labels.x(t) end`) is a
		// re-export, not a re-implementation.
		const delegates = new RegExp(`${fn}\\s*\\([^)]*\\)[\\s\\S]{0,120}?Labels\\.${fn}`).test(src);
		if (delegates) continue;
		(found[rel] = found[rel] || []).push(fn);
	}
}

for (const [rel, fns] of Object.entries(found)) {
	const allowed = DUPLICATES[rel] || [];
	for (const fn of fns) {
		if (!allowed.includes(fn)) {
			errors.push(
				`${rel}: defines "${fn}" — that formatter lives in ${CANONICAL}. ` +
					'Require it (Lua) or add a DUPLICATES entry saying why it cannot be shared.'
			);
		}
	}
}

// An entry whose duplicate is gone must be deleted, or it silently permits the
// next one to reappear in the same file.
for (const [rel, fns] of Object.entries(DUPLICATES)) {
	for (const fn of fns) {
		if (!(found[rel] || []).includes(fn)) {
			errors.push(`DUPLICATES lists ${rel} → "${fn}", but no such definition exists any more. Delete the entry.`);
		}
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Menu labels are not single-sourced:\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}

const pinned = Object.values(DUPLICATES).reduce((n, v) => n + v.length, 0);
console.log(
	`\x1b[32m[OK] Menu labels single-sourced — ${FORMATTERS.length} formatters defined only in labels.lua ` +
		`across ${files.length} source file(s) (${pinned} pinned AHK duplicate(s)).\x1b[0m`
);
