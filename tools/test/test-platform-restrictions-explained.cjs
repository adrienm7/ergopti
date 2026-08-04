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
 * **none** of them does. The user sees a menu that simply lacks a row, with
 * nothing anywhere saying whether that is deliberate, unimplemented, or
 * impossible.
 *
 * WHY THE BASELINE ROSE FROM 76 TO 142 ON 2026-08-02 — READ THIS BEFORE
 * TREATING IT AS A REGRESSION:
 * Not one feature changed availability. What changed is that the driver silos
 * were dissolved, and with them the excuse that was hiding two thirds of the
 * population.
 *
 * The rule has always been that a table restating the restriction its own
 * enclosing section already declares says nothing new. Before Lot 4 that
 * enclosing section was `sections.ahk.*`, so every AHK-only feature in the AHK
 * silo was an artifact by construction — 127 of them, excused on the shape of
 * the file rather than on anything true about the product. The user still met
 * every one of those missing rows; the gate simply was not counting them.
 *
 * After Lot 4 a feature lives under `sections.shortcuts` (ahk + hs) and states
 * `platforms = ["ahk"]` itself. Same feature, same availability, same missing
 * row — now visible to the count. The artifact rule survives in the form that
 * was always the honest one: a restriction the enclosing section already makes
 * is still excluded, because the user meets ONE missing submenu rather than
 * fourteen missing rows inside a submenu they never see.
 *
 * So 76 was an undercount and 142 is the measurement. Lowering it means writing
 * reasons, not restoring a namespace.
 *
 * WHY A RATCHET AND NOT A REQUIREMENT:
 * Requiring all 142 now means 142 new locale keys across 21 locales — nearly
 * 3 000 translated strings, in 19 languages nobody here can check. Machine-
 * filling them would put unverifiable text in front of users in every language,
 * which is worse than the silence it replaces. The count is frozen instead: a
 * NEW platform restriction must explain itself, and the existing ones can be
 * described as they are revisited. Lower this baseline as reasons are written.
 * Never raise it.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const MANIFEST = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'modules', 'features', 'manifest.toml');

// Frozen on 2026-08-02 at 142: 87 features + 45 menu rows + 10 sections
// restricted to one platform with no reason_key. 127 restrictions that a parent
// section already makes are excluded by construction — see the header for why
// this is 142 rather than the 76 measured under the driver silos.
//
// 2026-08-03: 142 → 139. Three came off together, and it is the first time this
// number has moved at all, because until that day it could not: `reason_key` had
// no reader anywhere in the repo, and the generator did not even emit it — each
// driver's generated manifest carries only the features it HAS, so a driver
// could not enumerate its own absences, let alone explain one. Writing reasons
// into that would have been writing configuration nothing could ever read.
// The chain now exists (generator → manifest_reader.coverage_gaps() →
// healthcheck), and `script.alt_gr_is_kana_remap` is the first one written
// through it end to end.
//
// 2026-08-04: 139 → 138. `llm.models.mlx`, on the same criterion as the first:
// MLX is Apple's on-device inference framework, built on Metal and Apple
// Silicon's unified memory, and no Windows or Linux build of it exists. The
// restriction therefore stays true however much of this repository gets written,
// which is the test — a reason is only writable when it survives the assumption
// that everything else is finished.
//
// A candidate that looked far larger was rejected the same day, and it is worth
// recording so nobody re-derives it: the 34 hs-only `features.gestures` entries
// would drop this number to 105 for one shared key. But `platforms = ["hs"]`
// excludes Linux as well as Windows, and the Linux driver ships the gestures
// module, its menu and its defaults — what it has no reader for is touch input,
// which manager.lua's own header calls a TODO. So the Linux half of that reason
// would read "not coded yet", the one thing the model reason forbids, and 21
// translated strings would have frozen it in place.
const BASELINE = 138;

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

// Section path -> the single platform it restricts to, when it restricts to one.
const sectionRestriction = new Map();
for (const t of tables) {
	if (!t.name.startsWith('sections.')) continue;
	const pm = t.body.join('\n').match(PLATFORMS_LINE);
	if (!pm) continue;
	const plats = [...pm[1].matchAll(/"(\w+)"/g)].map((x) => x[1]);
	if (plats.length === 1 && plats[0] !== 'both') {
		sectionRestriction.set(t.name.slice('sections.'.length), plats[0]);
	}
}

/**
 * The single platform the nearest enclosing section restricts to, if any.
 * @param {string} tableName - e.g. "features.shortcuts.keyboard" or "sections.layout".
 * @returns {string|null}
 */
function sectionPlatform(tableName) {
	const parts = tableName.split('.');
	parts.shift(); // Drop the "features"/"sections" root.
	// A section is judged against its PARENT, a feature against its own section.
	if (tableName.startsWith('sections.')) parts.pop();
	while (parts.length > 0) {
		const hit = sectionRestriction.get(parts.join('.'));
		if (hit) return hit;
		parts.pop();
	}
	return null;
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

	// A table that restates the restriction its own section already declares is
	// saying nothing new about the product. Before Lot 4 that showed up as a
	// table under `sections.ahk.*` declaring platforms = ["ahk"] — a tautology
	// about the file's shape. The silos are gone, but the shape survives: a
	// feature under `sections.shortcuts.keyboard` (ahk-only) declaring ahk-only
	// is the same tautology, and the user meets ONE missing submenu, not
	// fourteen missing rows inside a submenu they never see.
	//
	// Counting declarations rather than restrictions is what made this number
	// triple during Lot 4 without a single feature changing availability: the
	// moved features had inherited their platform from the silo section, and
	// pinning it on each of them turned one statement into many.
	const isArtifact = sectionPlatform(t.name) === plats[0];

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
		`  ${artifacts.length} restatement(s) excluded — a table whose enclosing section already\n` +
			'  restricts to that same platform says nothing new: the user meets one missing submenu,\n' +
			'  not every row inside a submenu they never see.'
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
		`(${real.length} real, ${artifacts.length} section restatement(s) excluded).\x1b[0m`
);
