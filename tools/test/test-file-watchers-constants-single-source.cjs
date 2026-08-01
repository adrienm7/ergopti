// tools/test/test-file-watchers-constants-single-source.cjs

/**
 * ==============================================================================
 * MODULE: File Watchers Constants SSoT Gate
 * DESCRIPTION:
 * `SCAN_MAX_DEPTH` and the debounce interval are the two tunable constants
 * that must stay identical between Linux and macOS `infra/file_watchers.lua`.
 * If they drift, one driver skips directories the other would scan, or debounce
 * timing diverges — breaking the cross-driver contract silently.
 *
 * ROOT CAUSE ENCODED:
 * The Linux `infra/file_watchers.lua` was written to mirror the macOS
 * `infra/file_watchers.lua` contract. Both share the same:
 *   - SCAN_MAX_DEPTH = 16  (cycle guard — max recursive depth for personal dirs)
 *   - debounce = 0.5 s     (rapid-save collapse window before triggering reload)
 *
 * This gate fails if either constant diverges between the two drivers.
 * It also ratchet-checks the macOS debounce (hardcoded literal 0.5 in
 * hs.timer.doAfter) against the Linux `_debounce_sec = 0.5` declaration.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const LINUX = path.join(ROOT, 'static/ergopti_plus/linux/infra/file_watchers.lua');
const MACOS = path.join(ROOT, 'static/ergopti_plus/macos/infra/file_watchers.lua');

function read(f) {
	return fs.readFileSync(f, 'utf8');
}

const errors = [];

// ── 1. Read both sources ──────────────────────────────────────────────────
const linuxSrc = read(LINUX);
const macosSrc = read(MACOS);

// ── 2. Extract SCAN_MAX_DEPTH from each driver ────────────────────────────
function extractMaxDepth(src, driverLabel) {
	const m = src.match(/SCAN_MAX_DEPTH\s*=\s*(\d+)/);
	if (!m) {
		errors.push(`${driverLabel}: SCAN_MAX_DEPTH not found`);
		return null;
	}
	const val = parseInt(m[1], 10);
	if (val !== 16) {
		errors.push(`${driverLabel}: SCAN_MAX_DEPTH = ${val} — expected 16`);
	}
	return val;
}

const linuxDepth = extractMaxDepth(linuxSrc, 'linux/infra/file_watchers.lua');
const macosDepth = extractMaxDepth(macosSrc, 'macos/infra/file_watchers.lua');

// ── 3. Verify they match ──────────────────────────────────────────────────
if (linuxDepth !== null && macosDepth !== null && linuxDepth !== macosDepth) {
	errors.push(`SCAN_MAX_DEPTH mismatch: Linux=${linuxDepth}, macOS=${macosDepth}`);
}

// ── 4. Extract debounce interval ──────────────────────────────────────────
// Linux: `local _debounce_sec = 0.5`
const linuxDebounceM = linuxSrc.match(/_debounce_sec\s*=\s*([\d.]+)/);
if (!linuxDebounceM) {
	errors.push('linux/infra/file_watchers.lua: _debounce_sec declaration not found');
} else {
	const linuxDebounce = parseFloat(linuxDebounceM[1]);
	if (linuxDebounce !== 0.5) {
		errors.push(`linux/infra/file_watchers.lua: _debounce_sec = ${linuxDebounce} — expected 0.5`);
	}
}

// macOS: `hs.timer.doAfter(0.5, ...)` — the literal 0.5 in the timer call
const macosDebounceM = macosSrc.match(/doAfter\(\s*([\d.]+)\s*,/);
if (!macosDebounceM) {
	errors.push('macos/infra/file_watchers.lua: hs.timer.doAfter(0.5, ...) not found');
} else {
	const macosDebounce = parseFloat(macosDebounceM[1]);
	if (macosDebounce !== 0.5) {
		errors.push(`macos/infra/file_watchers.lua: doAfter delay = ${macosDebounce} — expected 0.5`);
	}
}

// ── 5. Ratchet: macOS comment must mention 0.5 s for documentation parity ──
if (!macosSrc.includes('0.5 s timer')) {
	errors.push('macos/infra/file_watchers.lua: missing debounce documentation ("0.5 s timer")');
}

// ── 6. Ratchet: Linux comment must mention "matches macOS" for traceability ──
if (!linuxSrc.includes('matches macOS')) {
	errors.push('linux/infra/file_watchers.lua: missing cross-reference comment ("matches macOS")');
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] file_watchers constants diverged between Linux and macOS:\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}

console.log(
	'\x1b[32m[OK] file_watchers constants SSoT — SCAN_MAX_DEPTH=16, debounce=0.5s match across Linux + macOS infra/file_watchers.lua.\x1b[0m'
);
