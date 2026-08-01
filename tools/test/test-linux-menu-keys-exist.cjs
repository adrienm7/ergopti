// tools/test/test-linux-menu-keys-exist.cjs

/**
 * ==============================================================================
 * MODULE: Linux Menu i18n Key Guard
 * DESCRIPTION:
 * Asserts that every key the Linux menu builder asks for exists in the canonical
 * en.json.
 *
 * ROOT CAUSE ENCODED:
 * i18n_safe() used to take a French second argument at all 30 call sites, so a
 * key that did not resolve rendered French — to a user of any of the 21
 * languages. Those fallbacks are gone, which is the right shape (a raw key on
 * screen is ugly and diagnosable; a silently wrong language is neither) but it
 * moves the failure mode: a mistyped or renamed key now shows the dotted key in
 * the tray menu instead. Nothing else checks these keys — the locale-parity
 * audit compares the 21 locale FILES against each other and never looks at what
 * the code asks for.
 *
 * FEATURES & RATIONALE:
 * 1. Keys are extracted from source, so a new menu row is covered the day it
 *    lands rather than the day someone remembers this file.
 * 2. A floor on the extracted count: a regex that stops matching would report
 *    zero missing keys and read exactly like success.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SOURCE = path.join(ROOT, 'static', 'ergopti_plus', 'linux', 'ui', 'menu', 'menu_builder.lua');
const EN = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'data', 'locales', 'en.json');

// Measured at 30 calls when this landed. Set below that so ordinary growth does
// not trip it, far enough above zero that a broken extraction fails loudly.
const MIN_CALLS = 20;

const src = fs.readFileSync(SOURCE, 'utf8');
const en = JSON.parse(fs.readFileSync(EN, 'utf8'));

// Accented literals still hardcoded in the builder. Exactly one is legitimate —
// the "Français" row of the language picker, which is written in its own
// language on purpose, like every other entry in that list. The ratchet only
// turns down; NEVER raise it to let a new French label through.
const FRENCH_LITERAL_BASELINE = 1;
const FRENCH = /[éèêëàâçûùôîïœÉÈÀÇÎÔÛ]/;

const frenchLiterals = [];
src.split(/\r?\n/).forEach((line, i) => {
	if (/^\s*--/.test(line)) return;
	for (const m of line.matchAll(/"([^"\n]{2,})"/g)) {
		if (FRENCH.test(m[1])) frenchLiterals.push(`${i + 1}: ${JSON.stringify(m[1])}`);
	}
});

const calls = [...src.matchAll(/i18n_safe\(\s*"([^"]+)"/g)].map((m) => m[1]);
const distinct = [...new Set(calls)];
const missing = distinct.filter((k) => !Object.prototype.hasOwnProperty.call(en, k));

const failures = [];
if (calls.length < MIN_CALLS) {
	failures.push(
		`only ${calls.length} i18n_safe() call(s) found (expected at least ${MIN_CALLS}) — ` +
			'the extraction is broken, not the menu'
	);
}
for (const k of missing) {
	failures.push(`menu_builder.lua asks for "${k}", which en.json does not define — it would render as the raw key`);
}
if (frenchLiterals.length > FRENCH_LITERAL_BASELINE) {
	failures.push(
		`hardcoded French literals rose to ${frenchLiterals.length} (baseline ${FRENCH_LITERAL_BASELINE}):\n      ` +
			frenchLiterals.join('\n      ') +
			'\n    Route the label through i18n_safe with a key defined in en.json.'
	);
}

if (failures.length > 0) {
	console.error('\x1b[31m[FAIL] Linux menu i18n keys:\x1b[0m');
	for (const f of failures) console.error(`  - ${f}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] Every Linux menu key resolves (${calls.length} call(s), ${distinct.length} distinct); ` +
		`${frenchLiterals.length}/${FRENCH_LITERAL_BASELINE} hardcoded French literal(s).\x1b[0m`
);
