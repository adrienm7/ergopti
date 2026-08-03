// tools/test/test-walker-constants-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Keylogger Walker Constants — Single Source
 * DESCRIPTION:
 * The two keylogger walkers are the clearest surviving case of §5.2 being
 * declared and not held. `_shared/lua/keylogger/aggregator_helpers.lua` holds the
 * bucket edges and caps the aggregation is defined by; the AutoHotkey walker
 * re-declares the same names as `static` literals inside its class, and the macOS
 * aggregator has its own copies too. Three declarations of one number.
 *
 * ONE of them was already gated — `TITLE_CAP_PER_APP_DAY`, by an AHK test written
 * after the cap was found declared and dead. The rest were not, so a change to a
 * bucket edge in the shared file reached macOS and left Windows aggregating
 * against the old edges, producing two histograms that cannot be compared and no
 * failure anywhere.
 *
 * WHAT IS CHECKED:
 * 1. Every constant the shared helpers declare, that the AutoHotkey walker also
 *    declares as a literal, holds the same value — scalars compared as numbers,
 *    bucket arrays compared element by element.
 * 2. The same for the macOS aggregator.
 * 3. The parses are floored: a regex that stopped matching would compare nothing
 *    and pass forever, which is the failure mode this whole family of gates has
 *    hit before.
 *
 * WHAT IT DELIBERATELY DOES NOT CHECK: the constants the AHK walker initialises
 * to 0 with a `<- keylogger.<key>` comment. Those are placeholders filled at boot
 * from the timing registry, and `test-keylogger-timings-single-source.cjs`
 * already holds that path. Asserting 0 == the registry value here would be
 * asserting the placeholder.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const P = (rel) => path.join(ROOT, 'static/ergopti_plus', rel);

const SHARED = '_shared/lua/keylogger/aggregator_helpers.lua';
const AHK_WALKER = 'windows/modules/keylogger/keylogger_walker_core.ahk';
const HS_AGGREGATOR = [
	'macos/modules/keylogger/aggregator/core.lua',
	'macos/modules/keylogger/aggregator/events.lua',
	'macos/modules/keylogger/aggregator/sql.lua',
	'macos/modules/keylogger/aggregator/state.lua'
];

const errors = [];

/** Reads a file, or records the miss and returns "". */
function read(rel) {
	const p = P(rel);
	if (!fs.existsSync(p)) {
		errors.push(`${rel} is missing — it moved, and this gate no longer describes anything`);
		return '';
	}
	return fs.readFileSync(p, 'utf8');
}

/** Normalises a literal: a number, or an array rendered as a comma list. */
function normalise(raw) {
	const t = raw.trim();
	if (t.startsWith('{') || t.startsWith('[')) {
		return t.slice(1, -1).split(',').map((x) => x.trim()).filter(Boolean).join(',');
	}
	return String(Number(t));
}




// ==================================================
// ==================================================
// ======= 1/ The Shared Declarations ===============
// ==================================================
// ==================================================

const sharedSrc = read(SHARED);
const shared = new Map();
for (const m of sharedSrc.matchAll(/^M\.([A-Z][A-Z0-9_]+)\s*=\s*(\{[^}]*\}|-?[\d.]+)\s*$/gm)) {
	shared.set(m[1], normalise(m[2]));
}
if (shared.size < 5) {
	errors.push(`parsed ${shared.size} shared constant(s) from ${SHARED} — expected at least 5; the parser drifted`);
}




// ==================================================
// ==================================================
// ======= 2/ The AutoHotkey Walker =================
// ==================================================
// ==================================================

const ahkSrc = read(AHK_WALKER);
// `static NAME := <literal>`, ignoring the boot-filled placeholders which carry a
// "<- keylogger.<key>" comment and are gated by the timings single-source test.
const ahk = new Map();
let ahkPlaceholders = 0;
for (const m of ahkSrc.matchAll(/^\s*static\s+([A-Z][A-Z0-9_]+)\s*:=\s*(\[[^\]]*\]|-?[\d.]+)\s*(;.*)?$/gm)) {
	if (m[3] && m[3].includes('<- keylogger.')) { ahkPlaceholders++; continue; }
	ahk.set(m[1], normalise(m[2]));
}
if (ahk.size < 5) {
	errors.push(`parsed ${ahk.size} literal constant(s) from ${AHK_WALKER} — expected at least 5; the parser drifted`);
}
if (ahkPlaceholders === 0) {
	errors.push(
		`parsed 0 boot-filled placeholder(s) in ${AHK_WALKER} — the "<- keylogger.<key>" convention this ` +
			'gate skips has gone, so the exclusion above may now be hiding real comparisons'
	);
}

let comparedAhk = 0;
for (const [name, value] of shared) {
	if (!ahk.has(name)) continue;
	comparedAhk++;
	if (ahk.get(name) !== value) {
		errors.push(
			`${name}: ${SHARED} says ${value}, ${AHK_WALKER} says ${ahk.get(name)}. Two walkers aggregating ` +
				'against different edges produce two histograms nobody can compare.'
		);
	}
}
if (comparedAhk === 0) {
	errors.push('no constant name is shared between the shared helpers and the AHK walker — the gate compares nothing');
}




// ==================================================
// ==================================================
// ======= 3/ The macOS Aggregator ==================
// ==================================================
// ==================================================

const hs = new Map();
for (const rel of HS_AGGREGATOR) {
	for (const m of read(rel).matchAll(/^\s*(?:local\s+|M\.)([A-Z][A-Z0-9_]+)\s*=\s*(\{[^}]*\}|-?[\d.]+)\s*$/gm)) {
		if (!hs.has(m[1])) hs.set(m[1], { value: normalise(m[2]), file: rel });
	}
}

let comparedHs = 0;
for (const [name, value] of shared) {
	if (!hs.has(name)) continue;
	comparedHs++;
	const got = hs.get(name);
	if (got.value !== value) {
		errors.push(
			`${name}: ${SHARED} says ${value}, ${got.file} says ${got.value}. The macOS aggregator carries its ` +
				'own copy of a number the shared helpers already own.'
		);
	}
}




// ==================================================
// ==================================================
// ======= 4/ Report ================================
// ==================================================
// ==================================================

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] the keylogger walkers disagree with the shared aggregation constants:\x1b[0m');
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] ${shared.size} shared aggregation constant(s); ${comparedAhk} re-declared by the AutoHotkey ` +
		`walker and ${comparedHs} by the macOS aggregator, all agreeing (${ahkPlaceholders} boot-filled ` +
		'placeholder(s) left to the timings gate).\x1b[0m'
);
