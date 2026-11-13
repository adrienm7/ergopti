// tools/test/test-feature-family-rule.cjs

/**
 * ==============================================================================
 * MODULE: Feature Family Rule Gate
 * DESCRIPTION:
 * The rule of 2026-11-02: every manifest row is a feature or a setting, a feature
 * defaults to neutral, a setting recommends its default, and « Restore recommended »
 * reaches every row. Exceptions are declared in the manifest with their reason.
 *
 * WHAT THIS PINS:
 *   1. Every row follows its family's rule (tools/lib/feature-family-rule.cjs),
 *      and a seeded violation of each clause fails.
 *   2. A catalogue hotstring section recommends what its own driver spelling
 *      recommends: Windows persists hotstrings.<group>.<section>, macOS and Linux
 *      hotstrings.modules.<group>.<section>, and the two used to disagree, so the
 *      same restore turned the catalogue on there and off on Windows.
 *   3. Every row belongs to the global scope, or says why no restore touches it.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const paths = require('../lib/paths.cjs');
const { familyRuleViolations } = require('../lib/feature-family-rule.cjs');

const REASON = 'A reason long enough to explain why this row is an exception.';

/**
 * Lists the catalogue sections whose row disagrees with the driver spelling.
 * @param {object} manifest Parsed manifest with flattened entries.
 * @returns {string[]} One message per section.
 */
function sectionDrift(manifest) {
	const groups = manifest.sections.hotstrings.subsections.filter(
		(group) => group !== 'dynamic' && group !== 'personal'
	);
	const modules = manifest.scopes.hotstrings.dynamic_defaults.find(
		(definition) => definition.prefix === 'hotstrings.modules'
	);
	assert(groups.length >= 8 && modules, 'the catalogue groups and their spelling must be loaded');
	return manifest.entries
		.filter((entry) => groups.some((group) => entry.section === `hotstrings.${group}`))
		.filter((entry) => entry.recommended.enabled !== modules.recommended)
		.map((entry) => `${entry.section}.${entry.id} recommends ${entry.recommended.enabled}`);
}

/**
 * Expands the prefixes a scope reaches, its includes followed.
 * @param {object} scopes Scope declarations.
 * @param {string} id Scope identifier.
 * @returns {string[]} Prefixes.
 */
function scopePrefixes(scopes, id) {
	const scope = scopes[id];
	return [
		...scope.prefixes,
		...(scope.includes || []).flatMap((child) => scopePrefixes(scopes, child))
	];
}

/**
 * Lists the rows no restore reaches and that do not say why, and the exemptions
 * a row inside the global scope no longer needs.
 * @param {object} manifest Parsed manifest with flattened entries.
 * @returns {string[]} One message per row.
 */
function restoreGaps(manifest) {
	const prefixes = scopePrefixes(manifest.scopes, 'global');
	const gaps = [];
	for (const entry of manifest.entries) {
		const name = `${entry.section}.${entry.id}`;
		const inside = prefixes.some((prefix) => name === prefix || name.startsWith(`${prefix}.`));
		if (!inside && typeof entry.restore_exempt_reason !== 'string')
			gaps.push(`${name}: no restore reaches it and it does not say why`);
		if (inside && entry.restore_exempt_reason !== undefined)
			gaps.push(`${name}: its restore exemption contradicts its scope`);
	}
	return gaps;
}

/** Runs the gate over the real manifest, then over seeded violations. */
async function main() {
	const { parse } = await import('smol-toml');
	const manifest = parse(
		fs
			.readFileSync(paths.shared('settings/data/features/manifest.toml'), 'utf8')
			.replace(
				/^\[\[features\.([^\]]+)\]\]$/gm,
				(_match, section) => `[[entries]]\nsection = "${section}"`
			)
	);
	assert(manifest.entries.length > 300, 'the real feature registry must be loaded');
	const rows = manifest.entries.map((entry) => ({
		...entry,
		name: `${entry.section}.${entry.id}`
	}));
	assert.deepEqual(familyRuleViolations(rows), [], 'every row follows its family rule');
	assert.deepEqual(sectionDrift(manifest), [], 'a catalogue section recommends one value');
	assert.deepEqual(restoreGaps(manifest), [], 'every row is restored or says why not');

	const row = (name) => {
		const found = rows.find((entry) => entry.name === name);
		assert(found, `${name} is a real row`);
		return structuredClone(found);
	};
	const seeds = [
		{
			name: 'a setting that recommends another value',
			row: { ...row('hotstrings.idle_reset_seconds'), recommended: 7 },
			message: /a setting recommends its default/
		},
		{
			name: 'a per-platform recommendation of a setting',
			row: (() => {
				const seeded = row('llm.models.selected');
				seeded.recommended_per_platform = { ...seeded.recommended_per_platform, hs: 'ollama' };
				return seeded;
			})(),
			message: /a setting recommends its default on hs/
		},
		{
			name: 'a feature that starts on',
			row: { ...row('gestures.tap_3'), default: 'left_click_toggle' },
			message: /a feature defaults to a neutral value/
		},
		{
			name: 'a table feature that starts on',
			row: (() => {
				const seeded = row('hotstrings.rolls.hc');
				seeded.default.enabled = true;
				return seeded;
			})(),
			message: /a feature defaults to a neutral value/
		},
		{
			name: 'a delay inside a feature that differs from its default',
			row: (() => {
				const seeded = row('hotstrings.rolls.hc');
				seeded.recommended.time_activation_seconds = 9;
				return seeded;
			})(),
			message: /the settings inside a feature recommend their default/
		},
		{
			name: 'a row without a family',
			row: (() => {
				const seeded = row('metrics.enabled');
				delete seeded.family;
				return seeded;
			})(),
			message: /declares no family/
		},
		{
			name: 'an exception with no reason',
			row: { ...row('shortcuts.script_control.script_altgr_enter'), rule_exception: 'ok' },
			message: /must state the reason/
		},
		{
			name: 'an exception nothing needs',
			row: { ...row('metrics.enabled'), rule_exception: REASON },
			message: /explains nothing/
		},
		{
			name: 'an exception lost by a row that needs one',
			row: (() => {
				const seeded = row('layout.direct_access_digits');
				delete seeded.rule_exception;
				return seeded;
			})(),
			message: /declares a rule_exception/
		},
		{
			name: 'a setting active by default',
			row: { ...row('metrics.private_filter_enabled'), active_by_default: true },
			message: /active_by_default is only for a feature/
		}
	];
	for (const seed of seeds) {
		const found = familyRuleViolations([seed.row]);
		assert(
			found.some((message) => seed.message.test(message)),
			`${seed.name} must fail the gate, found ${JSON.stringify(found)}`
		);
	}

	const drifted = structuredClone(manifest);
	drifted.entries.find(
		(entry) => entry.section === 'hotstrings.rolls' && entry.id === 'hc'
	).recommended.enabled = false;
	assert.deepEqual(
		sectionDrift(drifted),
		['hotstrings.rolls.hc recommends false'],
		'a section off on Windows alone must fail'
	);

	const unreached = structuredClone(manifest);
	unreached.scopes.keyboard_layout.prefixes = unreached.scopes.keyboard_layout.prefixes.filter(
		(prefix) => prefix !== 'ui'
	);
	assert.deepEqual(
		restoreGaps(unreached),
		['ui.menubar_icon: no restore reaches it and it does not say why'],
		'a row out of every scope must fail'
	);
	const exempted = structuredClone(manifest);
	exempted.entries.find((entry) => entry.id === 'locale').restore_exempt_reason = REASON;
	assert.deepEqual(
		restoreGaps(exempted),
		['script.locale: its restore exemption contradicts its scope'],
		'a stale exemption must fail'
	);

	const exceptions = rows.filter((entry) => entry.rule_exception !== undefined);
	console.log(
		`Feature family rule passed: ${rows.length} rows, ${exceptions.length} declared exceptions, ` +
			`${seeds.length + 3} seeded violations refused.`
	);
}

main().catch((error) => {
	console.error(error.stack);
	process.exitCode = 1;
});
