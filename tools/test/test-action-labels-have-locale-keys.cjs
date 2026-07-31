// tools/test/test-action-labels-have-locale-keys.cjs

/**
 * ==============================================================================
 * MODULE: Action Label Coverage Guard
 * DESCRIPTION:
 * Every action registered in the macOS gesture registry must have a label key in
 * en.json, and every locale must carry it.
 *
 * ROOT CAUSE ENCODED:
 * macos/modules/gestures/actions.lua carried a 132-entry hardcoded English LABELS
 * table as a last-resort fallback "so new locales never show raw keys". Every one
 * of those 132 entries had a locale key — the table was a second copy of the
 * translations, unreachable, and free to drift from the real ones without anyone
 * noticing, because unreachable code shows no symptom.
 *
 * Deleting it is only safe while the premise holds, so the premise is what this
 * guards: if an action is ever registered without a locale key, this fails and
 * names it, rather than the picker quietly showing the user a raw identifier like
 * "app_window_previous".
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const ACTIONS = path.join(SP, 'macos', 'modules', 'gestures', 'actions.lua');
const LOCALES = path.join(SP, '_shared', 'data', 'locales');

const src = fs.readFileSync(ACTIONS, 'utf8');
const sg = [...src.matchAll(/\bsg\(\s*"([\w.]+)"/g)].map((m) => m[1]);
const ax = [...src.matchAll(/\bax\(\s*"([\w.]+)"/g)].map((m) => m[1]);

const errors = [];

if (sg.length < 50) {
	errors.push(`found only ${sg.length} sg() registration(s) — the registry shape changed, and this guard is checking nothing`);
}

const localeFiles = fs.readdirSync(LOCALES).filter((f) => f.endsWith('.json'));
if (localeFiles.length < 20) {
	errors.push(`found only ${localeFiles.length} locale file(s) — expected the full set`);
}

const locales = {};
for (const f of localeFiles) {
	locales[f.replace(/\.json$/, '')] = JSON.parse(fs.readFileSync(path.join(LOCALES, f), 'utf8'));
}

/**
 * The label key an action resolves through, in the order get_label() tries them.
 * @param {object} strings One locale's flat key map.
 * @param {string} name Action id.
 * @param {string} kind "sg" or "ax".
 * @returns {string|null} The key that resolves, or null.
 */
function resolves(strings, name, kind) {
	if (kind === 'sg' && typeof strings[`sg_actions.${name}`] === 'string') return `sg_actions.${name}`;
	if (typeof strings[`ax_actions.${name}`] === 'string') return `ax_actions.${name}`;
	if (typeof strings[`sg_actions.${name}`] === 'string') return `sg_actions.${name}`;
	return null;
}

for (const [kind, names] of [['sg', sg], ['ax', ax]]) {
	for (const name of names) {
		const missingIn = [];
		for (const [code, strings] of Object.entries(locales)) {
			if (!resolves(strings, name, kind)) missingIn.push(code);
		}
		if (missingIn.length > 0) {
			errors.push(
				`${kind}("${name}") has no label key in ${missingIn.length} locale(s): ${missingIn.join(', ')}. ` +
					'The picker would show the raw identifier. Add the key rather than reviving a hardcoded ' +
					'English fallback — a second copy of the translations drifts from the real ones with no symptom.'
			);
		}
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Registered actions without a label key:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] All ${sg.length + ax.length} registered action(s) resolve a label in every one of ` +
		`${localeFiles.length} locale(s).\x1b[0m`
);
