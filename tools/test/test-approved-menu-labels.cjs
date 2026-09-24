// tools/test/test-approved-menu-labels.cjs

/**
 * ==============================================================================
 * MODULE: Approved Menu Labels Stay Approved And Translated
 * DESCRIPTION:
 * A handful of tray labels were renamed by product decision. This gate pins the
 * approved French and English wording of each renamed key, and requires every
 * other locale to carry its own translation rather than the English text: most
 * of these keys had been left in English in 19 locales (« Release Notes »,
 * « Error log »), which a key-parity check cannot see because the key exists.
 *
 * Each entry names the decision it comes from, so a later rename edits the
 * table here in the same commit as the locales.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const LOCALES = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'data', 'locales');

// key -> approved wording. `translated: false` exempts a value that is
// legitimately the same in several languages.
const APPROVED = {
	// The errors file holds today's WARNING and ERROR lines; the gesture and
	// shortcut action that opens it reads like the Debug row.
	'sg_actions.open_error_log': { fr: '📄 Fichier des erreurs du jour', en: "📄 Today's errors file" }
};

const errors = [];
const files = fs.readdirSync(LOCALES).filter((f) => f.endsWith('.json'));
if (files.length !== 21) errors.push(`read ${files.length} locale file(s), expected 21.`);
const tables = Object.fromEntries(
	files.map((f) => [f.replace(/\.json$/, ''), JSON.parse(fs.readFileSync(path.join(LOCALES, f), 'utf8'))])
);
if (!tables.en || !tables.fr) errors.push('en.json and fr.json must both be present.');

let checked = 0;
for (const [key, spec] of Object.entries(APPROVED)) {
	for (const [loc, table] of Object.entries(tables)) {
		const value = table[key];
		if (typeof value !== 'string' || value === '') {
			errors.push(`${loc}.json has no value for ${key}.`);
			continue;
		}
		checked += 1;
		if (spec[loc] !== undefined && value !== spec[loc]) {
			errors.push(`${loc}.json reads "${value}" for ${key}, approved: "${spec[loc]}".`);
		}
		if (loc !== 'en' && spec.translated !== false && value === tables.en[key]) {
			errors.push(`${loc}.json still carries the English "${value}" for ${key}.`);
		}
	}
}
if (checked < Object.keys(APPROVED).length * 21) errors.push(`checked ${checked} value(s) — the scan is incomplete.`);

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] Approved menu labels:\x1b[0m');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] ${Object.keys(APPROVED).length} approved label(s) hold in ${files.length} locales, all translated.\x1b[0m`
);
