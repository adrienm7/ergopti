// tools/locale/report-identical-to-english.cjs

/**
 * ==============================================================================
 * MODULE: Values Equal To English Report
 * DESCRIPTION:
 * Prints, per locale, how many catalogue values are identical to en.json, how
 * many of those are covered by the allowlist and how many are not. With
 * `--list <locale>` it prints the uncovered keys of that locale with their
 * English value, which is the work list for a translator.
 *
 * FEATURES & RATIONALE:
 * 1. Read-only. The shrink-only gate lives in
 *    tools/test/test-locale-catalogue-complete.cjs; this report only shows the
 *    numbers behind it so a review can see the progress per locale.
 * 2. The allowlist is the single source for what counts as legitimately equal
 *    (key names, product names, units, words spelled the same).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const LOCALES = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'data', 'locales');
const ALLOWLIST = path.join(ROOT, 'tools', 'lint', 'locale-identical-to-english-allowlist.json');
const REFERENCE = 'en';

// =========================================
// =========================================
// ======= 1/ Loading the catalogues =======
// =========================================
// =========================================

const allow = JSON.parse(fs.readFileSync(ALLOWLIST, 'utf8')).entries;
const catalogues = new Map();
for (const f of fs.readdirSync(LOCALES).sort()) {
	if (f.endsWith('.json')) {
		catalogues.set(
			f.slice(0, -'.json'.length),
			JSON.parse(fs.readFileSync(path.join(LOCALES, f), 'utf8'))
		);
	}
}
const reference = catalogues.get(REFERENCE);

/** True when the allowlist covers this key for this locale. */
function isListed(key, code) {
	const entry = allow[key];
	return entry !== undefined && (entry.locales === '*' || entry.locales.includes(code));
}

// =====================================
// =====================================
// ======= 2/ Report generation =======
// =====================================
// =====================================

const listIndex = process.argv.indexOf('--list');
if (listIndex !== -1) {
	const code = process.argv[listIndex + 1];
	if (!catalogues.has(code) || code === REFERENCE) {
		console.error(`unknown locale "${code}"`);
		process.exit(2);
	}
	const kv = catalogues.get(code);
	for (const [key, en] of Object.entries(reference)) {
		if (!key.startsWith('_meta.') && kv[key] === en && !isListed(key, code)) {
			console.log(`${key}\t${JSON.stringify(en)}`);
		}
	}
} else {
	console.log('locale  identical  allowlisted  untranslated');
	for (const [code, kv] of catalogues) {
		if (code === REFERENCE) continue;
		const same = Object.entries(reference).filter(
			([key, en]) => !key.startsWith('_meta.') && kv[key] === en
		);
		const listed = same.filter(([key]) => isListed(key, code)).length;
		console.log(
			`${code.padEnd(6)}  ${String(same.length).padStart(9)}  ${String(listed).padStart(11)}  ` +
				`${String(same.length - listed).padStart(12)}`
		);
	}
}
