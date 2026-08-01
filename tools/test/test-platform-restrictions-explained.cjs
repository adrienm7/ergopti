// tools/test/test-platform-restrictions-explained.cjs

/**
 * ==============================================================================
 * MODULE: Platform-Coverage Report and Ratchet (I2)
 * DESCRIPTION:
 * Every declaration that restricts a feature or a menu row to one platform is
 * counted, classified, and — once it carries no `reason_key` — frozen. Run with
 * `--report` to print the full inventory.
 *
 * THE INVARIANT:
 * "A feature missing on a platform carries a translated `reason_key`." Today
 * **none** of them does: 93 declarations restrict to a single platform and zero
 * name a reason. The user sees a menu that simply lacks a row, with nothing
 * anywhere saying whether that is deliberate, unimplemented, or impossible.
 *
 * WHY THE COUNT HERE IS 76 AND NOT 93:
 * Seventeen of the 93 are **artifacts of the namespace, not statements about the
 * product**: a table that already lives under `sections.ahk.*` and then declares
 * `platforms = ["ahk"]` is saying the AHK section is AHK-only, which is a
 * tautology. Those disappear with the Lot 4 rename, and demanding a translated
 * sentence for each would be writing prose for something that should not exist.
 * The 76 that remain are real — 46 menu rows and 30 features that genuinely
 * appear on one platform and not another.
 *
 * WHY A RATCHET AND NOT A REQUIREMENT:
 * Requiring all 76 now means 76 new locale keys across 21 locales — 1 596
 * translated strings, in 19 languages nobody here can check. Machine-filling
 * them would put unverifiable text in front of users in every language, which is
 * worse than the silence it replaces. The count is frozen instead: a NEW
 * platform restriction must explain itself, and the existing 76 can be described
 * as they are revisited. Lower this baseline as reasons are written. Never raise
 * it.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const MANIFEST = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'modules', 'features', 'manifest.toml');

// Frozen on 2026-08-01: 46 menu rows + 30 features restricted to one platform
// with no reason_key. The 17 namespace artifacts are excluded by construction.
const BASELINE = 76;

// Floor: the manifest holds 500 tables, so a low parse means the scan broke and
// the ratchet would pass having measured nothing.
const MIN_TABLES = 300;

const REPORT = process.argv.includes('--report');

const TABLE_HEADER = /^(\[+)([A-Za-z0-9_.]+)(\]+)\s*$/;
const PLATFORMS_LINE = /^platforms\s*=\s*(\[[^\]]*\])/m;
const REASON_LINE = /^reason_key\s*=\s*"/m;

const errors = [];

if (!fs.existsSync(MANIFEST)) {
	console.error('\x1b[31m[ERROR] manifest.toml is missing.\x1b[0m');
	process.exit(1);
}

const src = fs.readFileSync(MANIFEST, 'utf8');
const lines = src.split(/\r?\n/);

// Walk the file once, accumulating each table's body under its header.
const tables = [];
let current = null;
for (const line of lines) {
	const m = line.match(TABLE_HEADER);
	if (m) {
		if (current) tables.push(current);
		current = { name: m[2], body: [] };
		continue;
	}
	if (current) current.body.push(line);
}
if (current) tables.push(current);

if (tables.length < MIN_TABLES) {
	errors.push(
		`parsed only ${tables.length} table(s) (floor ${MIN_TABLES}) — the scan is broken, and this ` +
			'ratchet would then find no restrictions at all and pass'
	);
}

const real = [];
const artifacts = [];

for (const t of tables) {
	const body = t.body.join('\n');
	const pm = body.match(PLATFORMS_LINE);
	if (!pm) continue;
	const plats = [...pm[1].matchAll(/"(\w+)"/g)].map((x) => x[1]);
	// Only a single-platform declaration is a restriction. "both", or two or
	// more names, means the row is available everywhere it applies.
	if (plats.length !== 1 || plats[0] === 'both') continue;

	const segments = t.name.split('.');
	const namespace = segments.length > 1 ? segments[1] : '';
	// A table under `sections.ahk.*` declaring platforms = ["ahk"] restates its
	// own namespace. That is a fact about the file's shape, not about the product.
	const isArtifact = namespace === plats[0];

	const entry = { name: t.name, platform: plats[0], explained: REASON_LINE.test(body) };
	(isArtifact ? artifacts : real).push(entry);
}

const unexplained = real.filter((r) => !r.explained);

if (REPORT) {
	const byRoot = {};
	for (const r of real) {
		const root = r.name.split('.')[0];
		(byRoot[root] = byRoot[root] || []).push(r);
	}
	console.log(`Platform-coverage report — ${real.length} real restriction(s), ` +
		`${real.length - unexplained.length} explained, ${unexplained.length} not.\n`);
	for (const [root, rows] of Object.entries(byRoot).sort()) {
		console.log(`  ${root} (${rows.length})`);
		for (const r of rows) {
			console.log(`     ${r.explained ? '✓' : ' '} ${r.platform.padEnd(6)} ${r.name}`);
		}
		console.log('');
	}
	console.log(
		`  ${artifacts.length} namespace artifact(s) excluded — a table under sections.<driver>.* that\n` +
			'  declares that same driver restates its own namespace and disappears with the Lot 4 rename.'
	);
}

if (unexplained.length > BASELINE) {
	errors.push(
		`platform restrictions with no reason_key rose to ${unexplained.length} (baseline ${BASELINE}). A ` +
			'row that appears on one platform and not another must say why, or the user meets a menu that ' +
			'is simply missing something with nothing anywhere explaining whether that is deliberate, ' +
			'unimplemented, or impossible. Add reason_key (and its locale entry in all 21 catalogues). ' +
			'Do NOT raise the baseline.'
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] platform coverage:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] platform restrictions without a reason: ${unexplained.length}/${BASELINE} ` +
		`(${real.length} real, ${artifacts.length} namespace artifact(s) excluded).\x1b[0m`
);
