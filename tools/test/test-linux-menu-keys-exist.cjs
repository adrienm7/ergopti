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
 * 2. The extracted count equals a second, looser count of the same calls: a
 *    regex that stops matching would report zero missing keys and read
 *    exactly like success.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
// The Linux tray root is read with its split section modules folded back in.
const { readSourceFile } = require('../lib/linux-menu-parts.cjs');
const { compareKnownDebt } = require('./lib/known-debt.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SOURCE = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'linux',
	'menu',
	'ui',
	'builder',
	'builder.lua'
);
const EN = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'_shared',
	'core',
	'i18n',
	'data',
	'locales',
	'en.json'
);

const src = readSourceFile(SOURCE);
const en = JSON.parse(fs.readFileSync(EN, 'utf8'));

// Accented literals still hardcoded in the builder, keyed by the literal, each
// with the reason it stays. The count of 1 admitted the "Français" row of the
// language picker until that row moved out of the builder; on 2026-11-22 the
// builder held none, so the ledger is empty. It only shrinks: NEVER add an
// entry to let a new French label through.
const FRENCH_LITERAL_LEDGER = {};
const FRENCH = /[éèêëàâçûùôîïœÉÈÀÇÎÔÛ]/;

const frenchLiterals = [];
src.split(/\r?\n/).forEach((line, i) => {
	if (/^\s*--/.test(line)) return;
	for (const m of line.matchAll(/"([^"\n]{2,})"/g)) {
		if (FRENCH.test(m[1])) frenchLiterals.push({ line: i + 1, literal: m[1] });
	}
});

// Unaccented French is still French. The accent test above reported 1/1 while
// the builder held twelve more — "Statistiques de session", "WPM actuel",
// "Canal stable", "(config non disponible)" and the rest — every one of them
// shown, in French, to a user of any of the other twenty languages. None
// carries an accent, so none was visible to a check built around accents.
//
// This asks the question the other way round: a `title =` is a menu row's label,
// and a label belongs in the catalogue. What may still be written inline is
// listed rather than pattern-matched, because every exemption is a decision
// someone made once and should have to make again to add another.
//
//   "-"                        the separator; not a label at all
//   "Français" / "English"     the language picker, each written in its own
//                              language on purpose
//   "qwerty" / "azerty"        layout identifiers, not words
//
// A row whose label is composed at runtime — i18n_safe(...) .. something — is
// not matched here: the regex requires the literal to be the whole value.
const INLINE_TITLE_EXEMPT = new Set(['-', 'Français', 'English', 'qwerty ', 'azerty ', '    ']);
const INLINE_TITLE_BASELINE = 0;

const inlineTitles = [];
src.split(/\r?\n/).forEach((line, i) => {
	if (/^\s*--/.test(line)) return;
	const m = line.match(/\btitle\s*=\s*"([^"\n]*)"\s*(?:,|\}|$)/);
	if (m && !INLINE_TITLE_EXEMPT.has(m[1])) {
		inlineTitles.push(`${i + 1}: ${JSON.stringify(m[1])}`);
	}
});

// The closing paren is required, so a COMPOSED key — i18n_safe("category." .. id)
// — is not mistaken for a literal one. Those cannot be checked here: the key is
// only known at runtime, and reporting the prefix as missing sends the reader to
// look for a translation of "category." that should not exist. Every such call
// site guards itself instead, by comparing the result against the key it asked
// for and falling back when the two are equal.
const calls = [...src.matchAll(/i18n_safe\(\s*"([^"]+)"\s*\)/g)].map((m) => m[1]);
const distinct = [...new Set(calls)];
const missing = distinct.filter((k) => !Object.prototype.hasOwnProperty.call(en, k));

const failures = [];
// A second, looser count of the same calls: every call that opens on a string
// literal, less those that compose it. The key regex must find each one, so a
// regex that stops matching fails here instead of reporting zero missing keys.
const literalOpenings = [...src.matchAll(/i18n_safe\(\s*"/g)].length;
const composedOpenings = [...src.matchAll(/i18n_safe\(\s*"[^"\n]*"\s*\.\./g)].length;
if (calls.length === 0 || calls.length !== literalOpenings - composedOpenings) {
	failures.push(
		`the key extraction found ${calls.length} i18n_safe() call(s), but ${literalOpenings - composedOpenings} ` +
			'open on a whole string literal — the extraction is broken, not the menu'
	);
}
for (const k of missing) {
	failures.push(
		`menu/ui/builder/builder.lua asks for "${k}", which en.json does not define — it would render as the raw key`
	);
}
const { added: newFrench, fixed: goneFrench } = compareKnownDebt(
	frenchLiterals.map((f) => f.literal),
	FRENCH_LITERAL_LEDGER
);
for (const literal of newFrench) {
	const lines = frenchLiterals.filter((f) => f.literal === literal).map((f) => f.line);
	failures.push(
		`hardcoded French literal ${JSON.stringify(literal)} (line ${lines.join(', ')}) is not in FRENCH_LITERAL_LEDGER. ` +
			'Route the label through i18n_safe with a key defined in en.json.'
	);
}
for (const literal of goneFrench) {
	failures.push(
		`${JSON.stringify(literal)} is no longer in the builder; remove it from FRENCH_LITERAL_LEDGER.`
	);
}

if (inlineTitles.length > INLINE_TITLE_BASELINE) {
	failures.push(
		`${inlineTitles.length} menu row(s) carry an inline label instead of a catalogue key ` +
			`(baseline ${INLINE_TITLE_BASELINE}):\n      ` +
			inlineTitles.join('\n      ') +
			'\n    Route the label through i18n_safe with a key defined in en.json, or add it to ' +
			'INLINE_TITLE_EXEMPT with the reason it is not a translatable label.'
	);
}

if (failures.length > 0) {
	console.error('\x1b[31m[FAIL] Linux menu i18n keys:\x1b[0m');
	for (const f of failures) console.error(`  - ${f}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] Every Linux menu key resolves (${calls.length} call(s), ${distinct.length} distinct); ` +
		`${frenchLiterals.length} accented literal(s), each in FRENCH_LITERAL_LEDGER, ` +
		`${inlineTitles.length}/${INLINE_TITLE_BASELINE} inline label(s).\x1b[0m`
);
