// tools/test/test-feature-namespace-ratchet.cjs

/**
 * ==============================================================================
 * MODULE: Feature-Namespace Ratchet (I2)
 * DESCRIPTION:
 * The number of tables in `manifest.toml` namespaced by DRIVER rather than by
 * meaning may never rise.
 *
 * THE ROOT CAUSE THIS FREEZES:
 * A feature must live at its semantic path — `hotstrings.autocorrection`, not
 * `ahk.hotstrings.autocorrection`. The manifest does both. Measured on
 * 2026-08-01: **223 driver-namespaced tables** (`features.hs` 114,
 * `features.ahk` 92, `sections.ahk` 12, `sections.hs` 5) alongside **129 already
 * namespaced by meaning** (`features.hotstrings` 69, `features.llm` 29,
 * `features.shortcuts` 23, `features.metrics` 5, `features.script` 3). The right
 * pattern is not hypothetical — it is already in the same file, used by a third
 * of it.
 *
 * The cost is concrete. `linux` appears nowhere in the namespace, so a Linux
 * feature has no path to live at; the driver was written outside the manifest
 * instead, which is why it renders none of its menu from it. Every new
 * `features.ahk.*` table makes the eventual rename bigger and one more config key
 * that existing installs have on disk.
 *
 * WHY A RATCHET AND NOT THE RENAME:
 * The section path IS the config key. `ahk.shortcuts.alt_gr_lalt` is what a
 * user's config.toml contains today, what the menu manifest targets, and what
 * `Features[…]` reads at runtime. Renaming 223 of them is a schema break needing
 * a migration for installed configs — Lot 4, and a decision about existing users
 * rather than a refactor to slip into a test commit. Freezing the count means the
 * migration stays the size it is now instead of growing while it waits.
 *
 * Lower this baseline as tables move. Never raise it.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const MANIFEST = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'modules', 'features', 'manifest.toml');

// Frozen on 2026-08-01: features.hs 114 + features.ahk 92 + sections.ahk 12 +
// sections.hs 5.
const BASELINE = 223;

// Floor on the total table count: a parse that stops matching would report zero
// driver-namespaced tables and pass while reading nothing.
const MIN_TABLES = 300;

// The driver names that must not appear as a namespace segment. "linux" is
// deliberately absent — it never became one, and the point is that no driver
// should be one.
const DRIVER_NAMES = new Set(['ahk', 'hs']);

// [features.x.y] and [[features.x.y]] alike.
const TABLE_HEADER = /^\[+([A-Za-z0-9_.]+)\]+\s*$/;

const errors = [];

if (!fs.existsSync(MANIFEST)) {
	console.error('\x1b[31m[ERROR] manifest.toml is missing.\x1b[0m');
	process.exit(1);
}

const lines = fs.readFileSync(MANIFEST, 'utf8').split(/\r?\n/);

let totalTables = 0;
let driverNamespaced = 0;
const byNamespace = new Map();

for (const line of lines) {
	const m = line.match(TABLE_HEADER);
	if (!m) continue;
	totalTables++;
	const parts = m[1].split('.');
	// Only the segment directly under features./sections. is a namespace.
	if (parts.length < 2) continue;
	if (parts[0] !== 'features' && parts[0] !== 'sections') continue;
	if (!DRIVER_NAMES.has(parts[1])) continue;
	driverNamespaced++;
	const key = `${parts[0]}.${parts[1]}`;
	byNamespace.set(key, (byNamespace.get(key) || 0) + 1);
}

if (totalTables < MIN_TABLES) {
	errors.push(
		`parsed only ${totalTables} table header(s) (floor ${MIN_TABLES}) — the TOML scan is broken, and ` +
			'this ratchet would then report zero driver-namespaced tables and pass'
	);
}

if (driverNamespaced > BASELINE) {
	const breakdown = [...byNamespace]
		.sort((a, b) => b[1] - a[1])
		.map(([k, n]) => `${k} ${n}`)
		.join(', ');
	errors.push(
		`driver-namespaced tables rose to ${driverNamespaced} (baseline ${BASELINE}): ${breakdown}. A ` +
			'feature belongs at its semantic path — hotstrings.autocorrection, not ' +
			'ahk.hotstrings.autocorrection — which a third of this file already does. The section path is ' +
			'also the config key users have on disk, so every new one makes the eventual migration bigger. ' +
			'Do NOT raise the baseline.'
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] feature namespace ratchet:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] driver-namespaced manifest tables: ${driverNamespaced}/${BASELINE} ` +
		`(of ${totalTables} total).\x1b[0m`
);
