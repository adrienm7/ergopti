// tools/test/test-hotstring-buffer-cap-parity.cjs

/**
 * ==============================================================================
 * MODULE: Hotstring Buffer-Cap Parity Guard
 * DESCRIPTION:
 * The rolling typing-buffer cap bounds the longest trigger that can ever match:
 * "triggers longer than this will never match." All drivers match the SAME shared
 * hotstring definitions, so the cap must be identical everywhere or a long trigger
 * would fire on some drivers and silently not on others.
 *
 * ROOT CAUSE ENCODED:
 * The cap had diverged — _shared/lua/hotstring_engine/init.lua BUFFER_MAX_CHARS =
 * 256 (used by macOS + Linux, which require the shared engine) vs Windows'
 * hardcoded 64 in two AHK files. Windows therefore failed to match triggers of
 * 65-256 chars that macOS/Linux matched. Windows was converged UP to the shared
 * 256 (a longer buffer only adds matching capability — zero regression for short
 * triggers). This guard pins the shared canon equal to both Windows mirrors so
 * the three can never drift again, and enforces the intra-Windows single value.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static/ergopti_plus');

function read(rel) {
	return fs.readFileSync(path.join(SP, rel), 'utf8');
}

function extract(rel, re, label) {
	const m = read(rel).match(re);
	if (!m) {
		throw new Error(`could not find ${label} in ${rel}`);
	}
	return Number(m[1]);
}

const errors = [];
let canon = null;

try {
	// Shared canonical (macOS + Linux require this engine, so they inherit it).
	canon = extract('_shared/lua/hotstring_engine/init.lua', /BUFFER_MAX_CHARS\s*=\s*(\d+)/, 'BUFFER_MAX_CHARS');

	// Windows mirrors — AHK cannot require the shared Lua, so the two literals
	// must equal the canon (and each other).
	const winInputhook = extract('windows/infra/hotstrings/hotstring_inputhook.ahk', /_MAX_BUFFER_LEN\s*:=\s*(\d+)/, '_MAX_BUFFER_LEN');
	const winEngine = extract('windows/infra/hotstrings/hotstring_engine_main.ahk', /HSE_MAX_BUFFER_LEN\s*:=\s*(\d+)/, 'HSE_MAX_BUFFER_LEN');

	if (winInputhook !== canon) {
		errors.push(`windows _MAX_BUFFER_LEN (${winInputhook}) != shared BUFFER_MAX_CHARS (${canon})`);
	}
	if (winEngine !== canon) {
		errors.push(`windows HSE_MAX_BUFFER_LEN (${winEngine}) != shared BUFFER_MAX_CHARS (${canon})`);
	}
	if (winInputhook !== winEngine) {
		errors.push(`intra-Windows drift: _MAX_BUFFER_LEN (${winInputhook}) != HSE_MAX_BUFFER_LEN (${winEngine})`);
	}
} catch (e) {
	errors.push(e.message);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Hotstring buffer cap is not single-sourced across drivers:\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] Hotstring buffer cap parity — shared BUFFER_MAX_CHARS = Windows _MAX_BUFFER_LEN = HSE_MAX_BUFFER_LEN = ${canon}.\x1b[0m`
);
