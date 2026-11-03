// tools/lib/feature-family-rule.cjs

/**
 * ==============================================================================
 * MODULE: Feature Family Rule
 * DESCRIPTION:
 * The maintainer's rule of 2026-11-02 over the manifest rows. A feature changes
 * the keyboard or the behaviour: its default is neutral, so an empty configuration
 * leaves the keyboard alone. A setting says how a feature works once active: its
 * recommended value equals its default. A row the rule refuses carries its reason
 * in the manifest (rule_exception), and an exception nothing needs is refused too,
 * so a reason cannot outlive the row it explained.
 *
 * The generator applies this while it builds and the CI gate applies it to seeded
 * violations; both read this one definition.
 * ==============================================================================
 */

'use strict';

const { isDeepStrictEqual } = require('node:util');

const FAMILIES = ['feature', 'setting'];
const PLATFORMS = ['ahk', 'hs', 'linux'];
const NEUTRAL_VALUES = [false, 'none', ''];
// Long enough to state a reason, short of which it is a label.
const MIN_REASON_LENGTH = 40;

/**
 * Reads one value of a row on one platform.
 * @param {object} row Manifest row.
 * @param {string} field "default" or "recommended".
 * @param {string} platform Platform id.
 * @returns {*} The value, undefined when the row has none there.
 */
function valueOn(row, field, platform) {
	return row[`${field}_per_platform`]?.[platform] ?? row[field];
}

/**
 * Lists why one row refuses its family's rule on one platform.
 * @param {object} row Manifest row with a known family.
 * @param {string} platform Platform id.
 * @returns {string[]} One message per broken clause.
 */
function clausesBroken(row, platform) {
	const neutral = valueOn(row, 'default', platform);
	const recommended = valueOn(row, 'recommended', platform);
	if (neutral === undefined || recommended === undefined) return [];
	if (row.family === 'setting') {
		return isDeepStrictEqual(neutral, recommended)
			? []
			: [`a setting recommends its default on ${platform}`];
	}
	const table = row.type === 'feature';
	const broken = [];
	if (!NEUTRAL_VALUES.includes(table ? neutral.enabled : neutral))
		broken.push(`a feature defaults to a neutral value on ${platform}`);
	if (table) {
		// The other keys of a feature's table say how it works: its own settings.
		const { enabled: _neutral, ...parameters } = neutral;
		const { enabled: _recommended, ...recommendedParameters } = recommended;
		if (!isDeepStrictEqual(parameters, recommendedParameters))
			broken.push(`the settings inside a feature recommend their default on ${platform}`);
	}
	return broken;
}

/**
 * Lists every row that breaks the rule, for the generator and the gate.
 * @param {object[]} rows Manifest rows; `name` or `path` identifies each one.
 * @returns {string[]} One message per violation.
 */
function familyRuleViolations(rows) {
	const violations = [];
	for (const row of rows) {
		const name = row.path || row.name;
		if (!FAMILIES.includes(row.family)) {
			violations.push(`${name}: declares no family (feature or setting)`);
			continue;
		}
		if (row.active_by_default !== undefined && row.family !== 'feature')
			violations.push(`${name}: active_by_default is only for a feature`);
		const exception = row.rule_exception;
		if (
			exception !== undefined &&
			(typeof exception !== 'string' || exception.trim().length < MIN_REASON_LENGTH)
		)
			violations.push(`${name}: rule_exception must state the reason`);
		const platforms = row.platforms?.length ? row.platforms : PLATFORMS;
		const broken = platforms.flatMap((platform) => clausesBroken(row, platform));
		if (broken.length > 0 && exception === undefined)
			violations.push(`${name}: ${broken[0]}, or declares a rule_exception`);
		if (broken.length === 0 && exception !== undefined)
			violations.push(`${name}: rule_exception explains nothing, the row follows the rule`);
	}
	return violations;
}

module.exports = { familyRuleViolations, NEUTRAL_VALUES };
