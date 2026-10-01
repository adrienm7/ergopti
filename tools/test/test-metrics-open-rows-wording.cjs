// tools/test/test-metrics-open-rows-wording.cjs

/**
 * ==============================================================================
 * MODULE: Metrics Menu Opening Rows Wording Tests
 * DESCRIPTION:
 * The Metrics menu has two rows that each open a window: the typing metrics
 * and the time spent in applications. In the 21 locales both rows start with
 * the same words and only their end names the window (the maintainer's rule
 * of 2026-10-01, metrics-open-rows-wording).
 *
 * FEATURES & RATIONALE:
 * 1. The rows read « Afficher les métriques de frappe » and « Afficher le
 *    temps sur les applications »: two sentences with nothing in common, for
 *    two rows that do the same thing to two windows.
 * 2. The common beginning is measured, not eyeballed: at least a third of the
 *    shorter label, and never the whole of it, so the two rows stay distinct.
 * 3. A locale whose verb comes last names the action first and the window
 *    after a colon, which keeps the rule without bending its grammar.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const locales = path.resolve(__dirname, '../../static/ergopti_plus/_shared/data/locales');
const KEYS = ['menu.metrics.show_typing', 'menu.metrics.show_apps'];
const MINIMUM_SHARE = 1 / 3;

const files = fs.readdirSync(locales).filter((name) => name.endsWith('.json'));
assert.equal(files.length, 21, 'the 21 locales are checked');

for (const file of files) {
	const strings = JSON.parse(fs.readFileSync(path.join(locales, file), 'utf8'));
	const [typing, apps] = KEYS.map((key) => strings[key]);
	assert.ok(typeof typing === 'string' && typeof apps === 'string', `${file}: both rows are named`);
	const first = [...typing];
	const second = [...apps];
	let common = 0;
	while (common < first.length && common < second.length && first[common] === second[common])
		common++;
	const shorter = Math.min(first.length, second.length);
	assert.ok(
		common >= Math.ceil(shorter * MINIMUM_SHARE),
		`${file}: « ${typing} » and « ${apps} » share only their first ${common} character(s)`
	);
	assert.ok(common < shorter, `${file}: the two rows must still name different windows`);
}

console.log(
	'[OK] metrics menu: the two rows that open a window start with the same words in the 21 locales.'
);
