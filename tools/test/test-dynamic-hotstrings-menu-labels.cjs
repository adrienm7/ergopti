// tools/test/test-dynamic-hotstrings-menu-labels.cjs

/**
 * ==============================================================================
 * MODULE: Dynamic Hotstrings Menu Label Resolution Regression Guard
 * DESCRIPTION:
 * Encodes the root cause of a bug where every dynamic-hotstrings entry in the
 * Windows tray menu showed its raw snake_case id (e.g.
 * "text_expansion_personal_information") instead of its translated label.
 *
 * The manifest path/description_key use the short "dynamic" category segment
 * (hotstrings.dynamic.<section>), but the shared locale files store these labels
 * under the folded MENU-category name "dynamichotstrings" (e.g.
 * dynamichotstrings.textexpansionpersonalinformation). The AHK label resolver's
 * candidate-key generator only stripped underscores, so it produced
 * "dynamic.<section>" candidates and never "dynamichotstrings.<section>" — no
 * candidate matched and the menu fell back to the raw id.
 *
 * FEATURES & RATIONALE:
 * 1. Asserts the resolver bridges "dynamic" -> "dynamichotstrings" (the fix is
 *    present in manifest_descriptions.ahk).
 * 2. Asserts the reference locale actually carries the dynamichotstrings.*
 *    labels the resolver targets — so resolution succeeds end to end. A
 *    regression in EITHER layer reintroduces the snake_case menu and fails here.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const PASS_SYMBOL = '✓';
const FAIL_SYMBOL = '✗';

const REPO_ROOT = path.resolve(__dirname, '../..');
const RESOLVER = 'static/ergopti_plus/windows/infra/manifest_descriptions.ahk';
const EN_LOCALE = 'static/ergopti_plus/_shared/data/locales/en.json';

// A sample of dynamic-hotstring sections + their folded locale keys. These are
// the exact labels the tray menu renders for [hotstrings.dynamic.*] entries.
const EXPECTED_LOCALE_KEYS = [
	'dynamichotstrings.textexpansionpersonalinformation',
	'dynamichotstrings.date',
	'dynamichotstrings.phoneprefixes'
];

let total_pass = 0;
let total_fail = 0;

function check(label, cond, detail) {
	if (cond) {
		total_pass++;
		console.log(`  ${PASS_SYMBOL}  ${label}`);
	} else {
		total_fail++;
		console.log(`  ${FAIL_SYMBOL}  ${label}`);
		if (detail) console.log(`       ${detail}`);
	}
}

console.log('\n=== Dynamic Hotstrings Menu Label Resolution ===');

// 1. The resolver must bridge "dynamic" -> "dynamichotstrings".
let resolverSrc = '';
try {
	resolverSrc = fs.readFileSync(path.join(REPO_ROOT, RESOLVER), 'utf8');
} catch (err) {
	check('resolver file readable', false, err.message);
}
check(
	'resolver emits a "dynamichotstrings." candidate for .dynamic. paths',
	/\.dynamic\./.test(resolverSrc) && /["']dynamichotstrings\.["']/.test(resolverSrc),
	`Bridge not found in ${RESOLVER} — dynamic sections will fall back to raw ids.`
);

// 2. The reference locale must carry the dynamichotstrings.* labels.
let locale = {};
try {
	locale = JSON.parse(fs.readFileSync(path.join(REPO_ROOT, EN_LOCALE), 'utf8').replace(/^﻿/, ''));
} catch (err) {
	check('en.json readable + parseable', false, err.message);
}
for (const key of EXPECTED_LOCALE_KEYS) {
	check(
		`locale has "${key}"`,
		typeof locale[key] === 'string' && locale[key].length > 0,
		`Missing/empty in ${EN_LOCALE} — the dynamic-hotstring label would be blank or raw.`
	);
}

console.log(`\nResults: ${total_pass} passed, ${total_fail} failed.`);

if (total_fail > 0) {
	process.exit(1);
}
