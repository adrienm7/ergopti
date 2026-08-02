// tools/test/test-feature-namespace-ratchet.cjs

/**
 * ==============================================================================
 * MODULE: Feature-Namespace Invariant (I2)
 * DESCRIPTION:
 * No table in `manifest.toml` may be namespaced by DRIVER rather than by
 * meaning. A feature lives at its semantic path — `hotstrings.autocorrection`,
 * never `ahk.hotstrings.autocorrection`.
 *
 * THE ROOT CAUSE THIS FREEZES:
 * The manifest used to do both. Measured on 2026-08-01: 223 driver-namespaced
 * tables (`features.hs` 114, `features.ahk` 92, `sections.ahk` 12, `sections.hs`
 * 5) alongside 129 already namespaced by meaning. Lot 4 moved all 223 to their
 * semantic paths and this file, which was a ratchet holding the count from
 * rising, became the assertion that it stays at zero.
 *
 * The cost the silos carried was concrete. `linux` never appeared in the
 * namespace, so a Linux feature had no path to live at; the driver was written
 * outside the manifest instead, which is why it rendered none of its menu from
 * it. What a driver supports is now a `platforms` field — data on a feature that
 * lives at one address — instead of the address itself.
 *
 * A per-driver difference in a DEFAULT is still legitimate and still expressible:
 * `default_per_platform = { ahk = X, hs = Y }`. That is the one thing the silos
 * were genuinely used for, and it survives in a form where the divergence is
 * visible on the feature rather than implied by where it was filed.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const MANIFEST = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'modules', 'features', 'manifest.toml');

// Floor on the total table count: a parse that stops matching would report zero
// driver-namespaced tables and pass while reading nothing.
const MIN_TABLES = 300;

// The driver names that must not appear as a namespace segment. "linux" is
// deliberately absent — it never became one, and the point is that no driver
// should be one.
const DRIVER_NAMES = new Set(['ahk', 'hs', 'linux', 'windows', 'macos']);

// [features.x.y] and [[features.x.y]] alike.
const TABLE_HEADER = /^\[+([A-Za-z0-9_.]+)\]+\s*$/;

const errors = [];

if (!fs.existsSync(MANIFEST)) {
	console.error('\x1b[31m[ERROR] manifest.toml is missing.\x1b[0m');
	process.exit(1);
}

const lines = fs.readFileSync(MANIFEST, 'utf8').split(/\r?\n/);

let totalTables = 0;
const offenders = [];

for (const line of lines) {
	const m = line.match(TABLE_HEADER);
	if (!m) continue;
	totalTables++;
	const parts = m[1].split('.');
	// Only the segment directly under features./sections. is a namespace.
	if (parts.length < 2) continue;
	if (parts[0] !== 'features' && parts[0] !== 'sections') continue;
	if (!DRIVER_NAMES.has(parts[1])) continue;
	offenders.push(m[1]);
}

if (totalTables < MIN_TABLES) {
	errors.push(
		`parsed only ${totalTables} table header(s) (floor ${MIN_TABLES}) — the TOML scan is broken, and ` +
			'this gate would then report zero driver-namespaced tables and pass'
	);
}

if (offenders.length > 0) {
	const shown = [...new Set(offenders)].slice(0, 12).join(', ');
	errors.push(
		`${offenders.length} driver-namespaced table(s): ${shown}. A feature belongs at its semantic ` +
			'path — hotstrings.autocorrection, not ahk.hotstrings.autocorrection. Which driver supports ' +
			'it is the "platforms" field; a default that differs per driver is "default_per_platform". ' +
			'The section path is also the config key users have on disk, so a driver namespace here is a ' +
			'schema break waiting to happen.'
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] feature namespace invariant:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] no driver-namespaced manifest tables (${totalTables} table header(s) scanned).\x1b[0m`
);
