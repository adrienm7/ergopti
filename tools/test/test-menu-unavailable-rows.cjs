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
 * A row its `disabled_when` greys where it is drawn can say why in the same
 * form (`disabled_reason_key`, on a command row): the Uninstall row of a local
 * version run from source. One rule for both, which differ only in how the
 * condition is evaluated.
 *
 * WHAT THIS HOLDS:
 *   1. Every declaration is one of the two values, on a row whose platforms
 *      leave some platform out; a hidden row has no reason_key; a greyed row
 *      has an i18n label and a reason_key; a disabled_reason_key sits on a
 *      command row with an i18n label and the disabled_when that greys it
 *      (the generator refuses the same).
 *   2. Every greyed row's reason opens with a short head in every locale, so
 *      the stand-in label stays narrow on every tray.
 *   3. Both renderers draw the stand-in (shared Lua and AutoHotkey), for both
 *      conditions; each driver's suite renders one.
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
	if (row.disabled_reason_key !== undefined) {
		if (typeof row.disabled_reason_key !== 'string' || row.disabled_reason_key === '')
			errors.push(`${where}: disabled_reason_key must name a locale key.`);
		if (row.type !== 'command')
			errors.push(`${where}: disabled_reason_key is read on command rows only.`);
		if (!Array.isArray(row.disabled_when) || row.disabled_when.length === 0)
			errors.push(`${where}: disabled_reason_key needs the disabled_when that greys the row.`);
		if (typeof row.i18n !== 'string') errors.push(`${where}: a greyed row needs an i18n label.`);
	}
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
	const drawn = { type: 'command', id: 'y', i18n: 'menu.y', disabled_when: ['installed_build'] };
	assert.deepEqual(rowErrors('f', { ...drawn, disabled_reason_key: 'r' }), []);
	assert.equal(rowErrors('f', { ...drawn, disabled_reason_key: '' }).length, 1);
	assert.equal(rowErrors('f', { ...drawn, type: 'check', disabled_reason_key: 'r' }).length, 1);
	assert.equal(
		rowErrors('f', { ...drawn, disabled_when: undefined, disabled_reason_key: 'r' }).length,
		1
	);
	assert.equal(rowErrors('f', { ...drawn, i18n: undefined, disabled_reason_key: 'r' }).length, 1);
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

/**
 * Holds a greyed row's reason to a short head in every locale.
 * @param {string} where Row name for the messages.
 * @param {string} key The reason's locale key.
 */
function checkReasonHead(where, key) {
	for (const { file, table } of locales) {
		const text = table[key];
		if (typeof text !== 'string' || text === '') {
			errors.push(`${where}: ${file} has no text for ${key}.`);
		} else if (reasonHead(text).length === 0 || reasonHead(text).length > MAX_HEAD) {
			errors.push(
				`${where}: ${file} opens ${key} with "${reasonHead(text)}", ` +
					`which must be 1 to ${MAX_HEAD} characters before its colon.`
			);
		}
	}
}

let declared = 0;
let greyed = 0;
let disabledWithReason = 0;
for (const [menu, rows] of Object.entries(manifest)) {
	if (!Array.isArray(rows)) continue;
	for (const row of rows) {
		if (!row || typeof row !== 'object') continue;
		if (row.unavailable === undefined && row.disabled_reason_key === undefined) continue;
		const where = `${menu}.${row.id || row.i18n || row.type}`;
		errors.push(...rowErrors(where, row));
		if (typeof row.disabled_reason_key === 'string') {
			disabledWithReason += 1;
			checkReasonHead(where, row.disabled_reason_key);
		}
		if (row.unavailable === undefined) continue;
		declared += 1;
		if (row.unavailable !== 'grey' || typeof row.reason_key !== 'string') continue;
		greyed += 1;
		checkReasonHead(where, row.reason_key);
	}
}
if (declared < 4) errors.push(`found ${declared} declared row(s), expected at least 4.`);
if (greyed < 1) errors.push('found no greyed row — the stand-in is untested by the manifest.');
if (disabledWithReason < 1)
	errors.push('found no disabled_reason_key — the runtime stand-in is untested by the manifest.');

/**
 * Extract one complete top-level native owner, without matching another helper.
 * @param {string} text Native source.
 * @param {string} name Function name.
 * @returns {string}
 */
function ahkOwner(text, name) {
	const match = text.match(new RegExp('^' + name + '\\([^\\n]*\\) \\{\\n([\\s\\S]*?)^\\}', 'm'));
	return match ? match[1].replace(/^\s*;.*$/gm, '') : '';
}

/**
 * The command-data owner passes the disabled reason to the original inert owner.
 * Provider data is not asserted to render reasons by itself: this checks only
 * the full command renderer, which owns the disabled stand-in publication.
 * @param {string} text Native renderer source.
 * @returns {boolean}
 */
function ahkDisabledReasonStandIn(text) {
	const data = ahkOwner(text, '_MR_CommandRowData');
	const render = ahkOwner(text, '_MR_RenderCommand');
	const standIn = ahkOwner(text, '_MR_RenderGreyedStandIn');
	return (
		/Disabled := MenuRenderer_ResolveDisabledWhen\(ManifestKey, Id, StateGetters\)/.test(data) &&
		/ReasonKey := _MR_Get\(Item, "disabled_reason_key"\)/.test(data) &&
		/if Disabled && ReasonKey != ""\s+return Map\("label", t\(I18nKey\), "disabled", true, "disabled_reason_key", ReasonKey\)/.test(
			data
		) &&
		/Row := _MR_CommandRowData\(Item, ManifestKey, Commands, StateGetters\)/.test(render) &&
		/if !\(Row is Map\)\s+return 0/.test(render) &&
		/if Row\.Has\("disabled_reason_key"\)\s+return _MR_RenderGreyedStandIn\(ResultMenu,\s*Map\("id", _MR_Get\(Item, "id"\), "i18n", _MR_Get\(Item, "i18n"\),\s*"reason_key", Row\["disabled_reason_key"\]\), ManifestKey\)/.test(
			render
		) &&
		/ReasonKey := _MR_Get\(Item, "reason_key"\)/.test(standIn) &&
		/Label := t\(I18nKey\) \. " — " \. _MR_ReasonHead\(t\(ReasonKey\)\)/.test(standIn) &&
		/ResultMenu\.Add\(Label, \(\*\) => ""\)/.test(standIn) &&
		/ResultMenu\.Disable\(Label\)/.test(standIn)
	);
}

// Literal owner shapes pin every link; production source alone cannot prove
// the scanner is sensitive to a lost reason, condition, callback or disable.
const AHK_STAND_IN_FIXTURE = `
_MR_CommandRowData(Item, ManifestKey, Commands, StateGetters) {
	Disabled := MenuRenderer_ResolveDisabledWhen(ManifestKey, Id, StateGetters)
	ReasonKey := _MR_Get(Item, "disabled_reason_key")
	if Disabled && ReasonKey != ""
		return Map("label", t(I18nKey), "disabled", true, "disabled_reason_key", ReasonKey)
}
_MR_RenderCommand(ResultMenu, Item, ManifestKey, Commands, StateGetters) {
	Row := _MR_CommandRowData(Item, ManifestKey, Commands, StateGetters)
	if !(Row is Map)
		return 0
	if Row.Has("disabled_reason_key")
		return _MR_RenderGreyedStandIn(ResultMenu,
			Map("id", _MR_Get(Item, "id"), "i18n", _MR_Get(Item, "i18n"),
				"reason_key", Row["disabled_reason_key"]), ManifestKey)
}
_MR_RenderGreyedStandIn(ResultMenu, Item, ManifestKey) {
	ReasonKey := _MR_Get(Item, "reason_key")
	Label := t(I18nKey) . " — " . _MR_ReasonHead(t(ReasonKey))
	ResultMenu.Add(Label, (*) => "")
	ResultMenu.Disable(Label)
}
`;
assert.equal(ahkDisabledReasonStandIn(AHK_STAND_IN_FIXTURE), true);
for (const [before, after] of [
	['MenuRenderer_ResolveDisabledWhen(', 'AnotherCondition('],
	['if Disabled && ReasonKey != ""', 'if ReasonKey != ""'],
	['"disabled", true', '"disabled", false'],
	['Row := _MR_CommandRowData(', 'Row := AnotherDataOwner('],
	['if !(Row is Map)', 'if false'],
	['if Row.Has("disabled_reason_key")', 'if false'],
	['Row["disabled_reason_key"]', 'Row["another_reason"]'],
	['_MR_ReasonHead(t(ReasonKey))', 't(ReasonKey)'],
	['ResultMenu.Add(Label, (*) => "")', 'ResultMenu.Add(Label, Action)'],
	['ResultMenu.Disable(Label)', 'ResultMenu.Enable(Label)']
]) {
	assert.notEqual(AHK_STAND_IN_FIXTURE.replace(before, after), AHK_STAND_IN_FIXTURE);
	assert.equal(ahkDisabledReasonStandIn(AHK_STAND_IN_FIXTURE.replace(before, after)), false);
}

// One stand-in for both conditions: each full renderer draws the row its
// disabled_when greys through the same native stand-in as an unavailable row.
const STAND_IN = {
	'renderer.lua': (text) =>
		/greyed_stand_in\(manifest_key,\s*\{[^}]*reason_key = item\.disabled_reason_key/.test(text),
	'manifest_menu.ahk': ahkDisabledReasonStandIn
};
for (const file of RENDERERS) {
	const text = fs.readFileSync(file, 'utf8');
	if (!/unavailable/.test(text) || !/"grey"/.test(text))
		errors.push(`${path.relative(ROOT, file)} does not draw a greyed stand-in.`);
	if (!STAND_IN[path.basename(file)](text))
		errors.push(
			`${path.relative(ROOT, file)} does not draw a row its disabled_when greys with a reason ` +
				'through the greyed stand-in.'
		);
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] A row a platform lacks must be declared hidden or greyed:\x1b[0m');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] ${declared} row(s) declare how a platform lacks them (${greyed} greyed with a ` +
		`short reason in all 21 locales), ${disabledWithReason} greyed by disabled_when with one; ` +
		`both renderers draw the stand-in for both.\x1b[0m`
);
