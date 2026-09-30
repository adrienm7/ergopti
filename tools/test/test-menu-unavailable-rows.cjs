// tools/test/test-menu-unavailable-rows.cjs

/**
 * ==============================================================================
 * MODULE: Rows a Platform Lacks Are Hidden or Greyed, as Declared
 * DESCRIPTION:
 * The maintainer's two cases for a menu row restricted by `platforms`, each
 * declared on the row (2026-09-30):
 *   - NOT APPLICABLE on an OS (`unavailable = "hide"`): the row makes no sense
 *     there, is never drawn there and owes no reason, so it carries none.
 *   - NOT YET PORTED to an OS (`unavailable = "grey"`): the feature exists
 *     elsewhere, so the row is drawn disabled with its label and the short
 *     form of its translated reason (the text before its first colon).
 * A restricted row without the field is hidden, as before the field existed.
 *
 * WHAT THIS HOLDS:
 *   1. Every declaration is one of the two values, on a row whose platforms
 *      leave some platform out; a hidden row has no reason_key; a greyed row
 *      has an i18n label and a reason_key (the generator refuses the same).
 *   2. A greyed row's reason opens with a short head in every locale, so the
 *      stand-in label stays narrow on every tray.
 *   3. Both renderers draw the stand-in (shared Lua and AutoHotkey); each
 *      driver's suite renders one.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const assert = require('node:assert/strict');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const MANIFEST = path.join(SP, '_shared', 'modules', 'menu', 'menu_manifest.json');
const LOCALES = path.join(SP, '_shared', 'data', 'locales');
const RENDERERS = [
	path.join(SP, '_shared', 'lua', 'menu', 'renderer.lua'),
	path.join(SP, 'windows', 'infra', 'manifest_menu.ahk')
];

const PLATFORMS = ['ahk', 'hs', 'linux'];
// Wider than this, a greyed stand-in stretches the whole tray.
const MAX_HEAD = 40;

/**
 * The short head of a translated reason: its text before the first colon,
 * ASCII or full-width, as the renderers cut it.
 * @param {string} text
 * @returns {string}
 */
function reasonHead(text) {
	const cuts = [':', '：'].map((mark) => text.indexOf(mark)).filter((at) => at >= 0);
	return (cuts.length > 0 ? text.slice(0, Math.min(...cuts)) : text).trim();
}

/**
 * The declaration errors of one row.
 * @param {string} where Row name for the messages.
 * @param {object} row Manifest row.
 * @returns {string[]}
 */
function rowErrors(where, row) {
	const errors = [];
	if (row.unavailable === undefined) return errors;
	if (row.unavailable !== 'hide' && row.unavailable !== 'grey')
		errors.push(`${where}: unavailable must be "hide" or "grey".`);
	const restricted =
		Array.isArray(row.platforms) && PLATFORMS.some((p) => !row.platforms.includes(p));
	if (!restricted) errors.push(`${where}: unavailable needs platforms that leave one out.`);
	if (row.unavailable === 'hide' && row.reason_key !== undefined)
		errors.push(`${where}: a hidden row carries no reason_key.`);
	if (row.unavailable === 'grey') {
		if (typeof row.reason_key !== 'string')
			errors.push(`${where}: a greyed row needs a reason_key.`);
		if (typeof row.i18n !== 'string') errors.push(`${where}: a greyed row needs an i18n label.`);
	}
	return errors;
}

// The rules on the shapes they must tell apart.
{
	const base = { type: 'command', id: 'x', i18n: 'menu.x', platforms: ['ahk'] };
	assert.deepEqual(rowErrors('f', { ...base, unavailable: 'hide' }), []);
	assert.deepEqual(rowErrors('f', { ...base, unavailable: 'grey', reason_key: 'r' }), []);
	assert.equal(rowErrors('f', { ...base, unavailable: 'hide', reason_key: 'r' }).length, 1);
	assert.equal(rowErrors('f', { ...base, unavailable: 'grey' }).length, 1);
	assert.equal(
		rowErrors('f', { ...base, i18n: undefined, unavailable: 'grey', reason_key: 'r' }).length,
		1
	);
	assert.equal(rowErrors('f', { ...base, platforms: undefined, unavailable: 'hide' }).length, 1);
	assert.equal(rowErrors('f', { ...base, platforms: PLATFORMS, unavailable: 'hide' }).length, 1);
	assert.equal(rowErrors('f', { ...base, unavailable: 'greyed' }).length, 1);
	assert.equal(reasonHead('Not on macOS yet: its key combinations…'), 'Not on macOS yet');
	assert.equal(reasonHead('暂不适用于 macOS：在'), '暂不适用于 macOS');
	assert.equal(reasonHead('Catalogue reload — Linux only'), 'Catalogue reload — Linux only');
}

const errors = [];
const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
const locales = fs
	.readdirSync(LOCALES)
	.filter((file) => file.endsWith('.json'))
	.map((file) => ({ file, table: JSON.parse(fs.readFileSync(path.join(LOCALES, file), 'utf8')) }));
if (locales.length !== 21) errors.push(`read ${locales.length} locale file(s), expected 21.`);

let declared = 0;
let greyed = 0;
for (const [menu, rows] of Object.entries(manifest)) {
	if (!Array.isArray(rows)) continue;
	for (const row of rows) {
		if (!row || typeof row !== 'object' || row.unavailable === undefined) continue;
		declared += 1;
		const where = `${menu}.${row.id || row.i18n || row.type}`;
		errors.push(...rowErrors(where, row));
		if (row.unavailable !== 'grey' || typeof row.reason_key !== 'string') continue;
		greyed += 1;
		for (const { file, table } of locales) {
			const text = table[row.reason_key];
			if (typeof text !== 'string' || text === '') {
				errors.push(`${where}: ${file} has no text for ${row.reason_key}.`);
			} else if (reasonHead(text).length === 0 || reasonHead(text).length > MAX_HEAD) {
				errors.push(
					`${where}: ${file} opens ${row.reason_key} with "${reasonHead(text)}", ` +
						`which must be 1 to ${MAX_HEAD} characters before its colon.`
				);
			}
		}
	}
}
if (declared < 4) errors.push(`found ${declared} declared row(s), expected at least 4.`);
if (greyed < 1) errors.push('found no greyed row — the stand-in is untested by the manifest.');

for (const file of RENDERERS) {
	const text = fs.readFileSync(file, 'utf8');
	if (!/unavailable/.test(text) || !/"grey"/.test(text))
		errors.push(`${path.relative(ROOT, file)} does not draw a greyed stand-in.`);
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] A row a platform lacks must be declared hidden or greyed:\x1b[0m');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] ${declared} row(s) declare how a platform lacks them (${greyed} greyed with a ` +
		`short reason in all 21 locales); both renderers draw the stand-in.\x1b[0m`
);
