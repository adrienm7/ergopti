// tools/test/lib/menu-row-text.cjs

/**
 * ==============================================================================
 * MODULE: Menu Row Text Judge
 * DESCRIPTION:
 * Says whether the visible text of one menu row is an unresolved identifier.
 * `_shared/lua/test/menu_row_text.lua` is the same rule for the Lua walks; both
 * read `_shared/tests/corpus/menu_row_text_allowlist.json`.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ERGOPTI = path.resolve(__dirname, '..', '..', '..', 'static', 'ergopti_plus');
const ALLOWLIST = path.join(ERGOPTI, '_shared', 'tests', 'corpus', 'menu_row_text_allowlist.json');

/**
 * Loads the allowlisted patterns.
 * @returns {RegExp[]} One expression per entry; each entry must say why.
 */
function loadAllowlist() {
	const { entries } = JSON.parse(fs.readFileSync(ALLOWLIST, 'utf8'));
	return entries.map((entry) => {
		if (typeof entry.reason !== 'string' || entry.reason.trim() === '')
			throw new Error(`Allowlist entry ${entry.pattern} gives no reason.`);
		return new RegExp(entry.pattern);
	});
}

/**
 * Names what is wrong with one row's text.
 * @param {string} text Visible row text.
 * @param {Set<string>} identifiers Every feature id, feature path and menu id.
 * @param {RegExp[]} allowlist Allowlisted patterns.
 * @returns {string} The defect, or '' for a text that reads as text.
 */
function rowTextDefect(text, identifiers, allowlist) {
	if (allowlist.some((pattern) => pattern.test(text))) return '';
	// A hotstring row ends with its entry count, which is no part of the label.
	const label = text.replace(/\s*\(\d+\)$/, '').trim();
	if (identifiers.has(label)) return 'equals an id or a config path';
	// Segments start with a letter: « v2.2.1 » is a version, not a key.
	if (/(^|\s)[a-z][a-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+(\s|$)/.test(label))
		return 'reads as a dotted key';
	if (/(^|[^\p{L}\p{N}_])[a-z0-9]+(_[a-z0-9]+)+($|[^\p{L}\p{N}_])/u.test(label))
		return 'reads as snake_case';
	if (/\{\d*\}|%[sd]/.test(label)) return 'holds an unfilled placeholder';
	return '';
}

module.exports = { loadAllowlist, rowTextDefect };
