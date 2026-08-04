// tools/test/test-menu-manifest-single-reader.cjs

/**
 * ==============================================================================
 * MODULE: One Reader Per Driver For menu_manifest.json
 * DESCRIPTION:
 * The menu manifest is a static asset every driver parses once at boot. macOS
 * parsed it THREE times, from three files, with two independent session caches
 * and two byte-identical error messages:
 *
 *   infra/manifest_menu.lua      get_manifest_root()   — the owner
 *   ui/menu/builder.lua          load_manifest()       — a second copy
 *   ui/menu/menu_remap.lua       inline, as a fallback "in case manifest_menu is
 *                                not loaded yet" — which require makes
 *                                impossible, so it was a reader on a path
 *                                nothing could reach
 *
 * Three copies of a file read is three places for a path change to land in one
 * of, and it cost a duplicate decode of an 11.9 KB file on the boot path — the
 * exact cost the Windows manifest loader's own comment records having removed.
 *
 * WHY A GATE AND NOT JUST THE FIX:
 * the third copy was introduced BY a deduplication, as the safety net of the
 * call that replaced it. That is the shape this cannot be left open to: nobody
 * adds a second reader on purpose, they add a fallback next to the first.
 *
 * FEATURES & RATIONALE:
 * 1. Counts readers, not mentions. A file naming the manifest in a docstring is
 *    not a reader; a file naming it within a few lines of a read call is.
 * 2. Ratcheted per driver, downward only, so a driver that legitimately has one
 *    reader today cannot quietly grow a second.
 * 3. A floor on the total, because a detector that stops matching would report
 *    zero readers — and zero readers means the menu cannot be built at all.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const MANIFEST_FILE = 'menu_manifest.json';

// How far from the filename a read call still counts as "this file reads it".
// Six lines covers the open/read/close/decode sequence both languages use,
// including the pcall wrappers and the error branch between them.
const NEAR_LINES = 6;

/**
 * Blanks out comment text so prose cannot be mistaken for a call.
 *
 * Not fastidiousness: the first run of this gate flagged ui/menu/builder.lua,
 * whose only remaining mention of the manifest is the comment explaining that it
 * no longer reads the file — a comment that necessarily names hs.json.decode to
 * say so. A detector that reads documentation as evidence reports the fix as the
 * defect.
 * @param {string} text
 * @param {string} marker Line-comment marker: "--" for Lua, ";" for AHK.
 * @returns {string} Same line count, comment bodies removed.
 */
function stripComments(text, marker) {
	return text
		.split('\n')
		.map((line) => {
			const at = line.indexOf(marker);
			return at < 0 ? line : line.slice(0, at);
		})
		.join('\n');
}

const DRIVERS = {
	macos: { ext: /\.lua$/, comment: '--', read: /io\.open|json\.decode/ },
	windows: { ext: /\.ahk$/, comment: ';', read: /FileRead|Jxon_Load|JSON\.parse|_MM_ReadJson/ },
	// Linux does not read the menu manifest at all — its tray menu is built by
	// hand. Zero is the correct count, and pinning it here is what makes the
	// eventual renderer port show up as a deliberate +1 rather than as noise.
	linux: { ext: /\.lua$/, comment: '--', read: /io\.open|json\.decode/ }
};

// Frozen 2026-08-04, after the macOS deduplication took it from 3 to 1.
// Windows was already at 1 — infra/menu_manifest.ahk — which is the measurement
// that makes macOS's three a defect rather than the house style. Linux is 0
// because it never reads the file: its tray menu is built by hand, and pinning
// the zero is what will make the eventual renderer port show up as a deliberate
// +1 instead of as noise.
// Lower it when a driver loses a reader; never raise it to make a change pass.
const BASELINE = { macos: 1, windows: 1, linux: 0 };

// Floor on the total. A detector that matched nothing would report every driver
// at zero and pass this gate while the menu had no source of truth at all.
const MIN_TOTAL_READERS = 2;

const SKIP_DIRS = new Set(['tests', 'vendor', 'node_modules', '_generated']);

/**
 * Production files under `dir` that actually read the menu manifest.
 * @param {string} dir Driver root.
 * @param {{ext: RegExp, read: RegExp}} spec
 * @returns {string[]} Driver-relative paths, with the offending line number.
 */
function readersIn(dir, spec) {
	const found = [];
	(function walk(current) {
		if (!fs.existsSync(current)) return;
		for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
			const p = path.join(current, entry.name);
			if (entry.isDirectory()) {
				if (!SKIP_DIRS.has(entry.name)) walk(p);
				continue;
			}
			if (!spec.ext.test(entry.name)) continue;
			const raw = fs.readFileSync(p, 'utf8');
			if (!raw.includes(MANIFEST_FILE)) continue;
			const lines = raw.split('\n');
			// The filename is looked for anywhere — a path is often a string
			// literal — but the READ CALL only in code, so a comment explaining
			// that this file no longer reads the manifest is not evidence that
			// it does.
			const codeLines = stripComments(raw, spec.comment).split('\n');
			for (let i = 0; i < lines.length; i++) {
				if (!lines[i].includes(MANIFEST_FILE)) continue;
				const window = codeLines.slice(Math.max(0, i - NEAR_LINES), i + NEAR_LINES + 1).join('\n');
				if (spec.read.test(window)) {
					found.push(`${path.relative(dir, p).replace(/\\/g, '/')}:${i + 1}`);
					return;
				}
			}
		}
	})(dir);
	return found;
}

const errors = [];
const summary = [];
let total = 0;

for (const [driver, spec] of Object.entries(DRIVERS)) {
	const readers = readersIn(path.join(SP, driver), spec);
	total += readers.length;
	summary.push(`${driver} ${readers.length}/${BASELINE[driver]}`);

	if (readers.length > BASELINE[driver]) {
		errors.push(
			`${driver}: ${readers.length} file(s) read ${MANIFEST_FILE} (baseline ${BASELINE[driver]}):\n` +
				readers.map((r) => '        ' + r).join('\n') +
				'\n      Route the extra one through the driver\'s existing manifest accessor. A second ' +
				'reader is almost never added deliberately — it arrives as a fallback beside the first, ' +
				'which is exactly how macOS ended up with three.'
		);
	}
	if (readers.length < BASELINE[driver]) {
		errors.push(
			`${driver}: only ${readers.length} reader(s) found where ${BASELINE[driver]} were recorded. ` +
				'Either a reader was removed — lower the baseline and say so — or the detector stopped ' +
				'matching this driver, in which case the count above means nothing.'
		);
	}
}

if (total < MIN_TOTAL_READERS) {
	errors.push(
		`only ${total} manifest reader(s) found across all drivers (floor ${MIN_TOTAL_READERS}). The ` +
			'detector has stopped matching, so every per-driver count above is zero for the wrong reason.'
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] menu_manifest.json readers:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(`\x1b[32m[OK] menu_manifest.json readers per driver: ${summary.join(', ')}.\x1b[0m`);
