// tools/test/test-menu-labels-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Menu Labels Single-Source Guard
 * DESCRIPTION:
 * Verifies that menu label formatters are single-sourced:
 *   - _shared/lua/menu/labels.lua exists and exports log_level_emoji,
 *     fmt_count, and decorate_section.
 *   - macOS consumes it via require("menu.labels") in i18n.lua,
 *     hotstring_counter.lua, and builder.lua.
 *
 * ROOT CAUSE ENCODED:
 * The log-level emoji map, count formatter, and section header decoration were
 * duplicated across macOS (Lua), Windows (AHK), and Linux (Lua). The Lua copies
 * were fused into _shared/lua/menu/labels.lua and macOS now reads from it.
 * The AHK copies (FmtCount in menu_helpers.ahk, log-level emoji map in
 * menu_rebuild.ahk) remain hand-maintained but are pinned by separate drift
 * gates (section-decoration-parity + the AHK test suite).
 * ==============================================================================
 */

'use strict';

const fs   = require('fs');
const p    = require('path');

const ROOT = p.resolve(__dirname, '..', '..');
const SP   = p.join(ROOT, 'static/ergopti_plus');

const errors = [];

function fileExistsSP(rel) {
	return fs.existsSync(p.join(SP, rel));
}
function read(rel) {
	return fs.readFileSync(p.join(ROOT, rel), 'utf8');
}

// ── 1. Shared labels.lua must exist ─────────────────────────────────────────
if (!fileExistsSP('_shared/lua/menu/labels.lua')) {
	errors.push('_shared/lua/menu/labels.lua: missing — menu label formatters must be single-sourced');
} else {
	const src = read('static/ergopti_plus/_shared/lua/menu/labels.lua');
	for (const fn of ['log_level_emoji', 'fmt_count', 'decorate_section']) {
		if (!src.includes('function M.' + fn)) {
			errors.push(`_shared/lua/menu/labels.lua: missing function M.${fn}`);
		}
	}
}

// ── 2. macOS must consume it ────────────────────────────────────────────────
for (const [file, name] of [
	['static/ergopti_plus/macos/lib/i18n.lua', 'macos/lib/i18n.lua'],
	['static/ergopti_plus/macos/ui/menu/hotstring_counter.lua', 'macos/ui/menu/hotstring_counter.lua'],
	['static/ergopti_plus/macos/ui/menu/builder.lua', 'macos/ui/menu/builder.lua'],
]) {
	const src = fileExistsSP(file.replace('static/ergopti_plus/', '')) ? read(file) : '';
	if (!src.includes('require("menu.labels")') && !src.includes("require('menu.labels')")) {
		errors.push(`${name}: must require("menu.labels")`);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Menu labels are not single-sourced:\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}

console.log('\x1b[32m[OK] Menu labels single-sourced — labels.lua consumed by macOS (i18n, hotstring_counter, builder).\x1b[0m');
