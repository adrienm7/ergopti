// tools/test/test-locale-hints-quote-live-labels.cjs

/**
 * ==============================================================================
 * MODULE: A Hint That Names A Menu Row Quotes Its Current Label
 * DESCRIPTION:
 * Some messages tell the user where to click: « icône → 📊 Métriques →
 * « Activer les métriques » ». Such a path is only useful while every step it
 * quotes is the label the tray actually draws, in the same locale.
 *
 * WHY IT EXISTS: the Metrics switch became a checkbox labelled « Activer les
 * métriques », and the Windows dialog shown when Metrics is off went on sending
 * users to « ❌ Métriques désactivées (cliquer pour activer) », a row that no
 * longer exists in any language. Nothing links the two strings, so nothing
 * noticed. Each pair below is a hint and the label keys it must quote.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const LOCALES = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'data', 'locales');

// A floor, so a scan that reads nothing cannot pass.
const MIN_LOCALES = 21;

// Each hint and the menu labels, in click order, it must quote verbatim.
const HINTS = [
	{
		hint: 'keylogger_ui.metrics_disabled_body',
		labels: ['menu.metrics.title', 'menu.metrics.enable']
	}
];

const errors = [];
const files = fs
	.readdirSync(LOCALES)
	.filter((f) => f.endsWith('.json'))
	.sort();
if (files.length < MIN_LOCALES) {
	errors.push(`found ${files.length} locale catalogue(s), expected at least ${MIN_LOCALES}`);
}

let checked = 0;
for (const file of files) {
	const catalogue = JSON.parse(fs.readFileSync(path.join(LOCALES, file), 'utf8'));
	for (const { hint, labels } of HINTS) {
		const text = catalogue[hint];
		if (typeof text !== 'string' || text === '') {
			errors.push(`${file}: ${hint} is missing`);
			continue;
		}
		let from = 0;
		for (const key of labels) {
			const label = catalogue[key];
			if (typeof label !== 'string' || label === '') {
				errors.push(`${file}: ${key} is missing, so ${hint} has nothing to quote`);
				continue;
			}
			const at = text.indexOf(label, from);
			if (at < 0) {
				errors.push(
					`${file}: ${hint} does not quote ${key} ("${label}") after the step before it — it sends the ` +
						`user to a row the tray does not draw:\n        ${text}`
				);
				continue;
			}
			from = at + label.length;
			checked += 1;
		}
	}
}

if (checked === 0 && errors.length === 0) {
	errors.push('no hint was checked — the gate compared nothing');
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] a hint quotes a menu label the tray no longer draws:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] ${HINTS.length} hint(s) quote the live menu labels in ${files.length} locale(s) ` +
		`(${checked} quotation(s) checked).\x1b[0m`
);
