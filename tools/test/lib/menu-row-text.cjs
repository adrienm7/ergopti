// tools/test/lib/menu-row-text.cjs

/**
 * ==============================================================================
 * MODULE: Menu Row Text Judge
 * DESCRIPTION:
 * Says whether the visible text of one menu row is an unresolved identifier,
 * a raw key id or an abbreviation no locale translates (`lalt`, `LCtrl`).
 * `_shared/tests/lua/menu/row_text.lua` is the same rule for the Lua walks; both
 * read `_shared/tests/corpus/menu_row_text_allowlist.json`. French rows also
 * keep a space before `:`, `?`, `!` and `;` in both.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ERGOPTI = path.resolve(__dirname, '..', '..', '..', 'static', 'ergopti_plus');
const ALLOWLIST = path.join(ERGOPTI, '_shared', 'tests', 'corpus', 'menu_row_text_allowlist.json');
const KEY_NAMES = path.join(ERGOPTI, '_shared', 'layouts', 'data', 'keycodes', 'key_names.json');

// Spellings of the key name table that are also plain words of a sentence
// (« Insert a space », « tab »; `alt` is « all » in Danish and Norwegian, « old »
// in German, « sub » in Turkish): a row may hold them, so only the others count.
const PROSE_SPELLINGS = new Set([
	'alt',
	'tab',
	'space',
	'enter',
	'delete',
	'option',
	'return',
	'command',
	'control',
	'super',
	'caps',
	'escape',
	'shift',
	'meta',
	'insert',
	'home',
	'end'
]);

/**
 * Every key spelling a row must never show: the lowercase ids and aliases of
 * _shared/layouts/data/keycodes/key_names.json that read as no word, and the side
 * abbreviations the Tap-Hold rows used to print (LCtrl, RShift, LAlt…).
 * `_shared/tests/lua/menu/row_text.lua` builds the same set.
 * @returns {Set<string>}
 */
function loadRawKeySpellings() {
	const table = JSON.parse(fs.readFileSync(KEY_NAMES, 'utf8'));
	const out = new Set();
	for (const spelling of [...Object.keys(table.keys), ...Object.keys(table.aliases)])
		if (!PROSE_SPELLINGS.has(spelling)) out.add(spelling);
	for (const side of ['L', 'R'])
		for (const name of ['Ctrl', 'Shift', 'Alt', 'Win', 'Cmd', 'Option']) out.add(side + name);
	return out;
}

const RAW_KEY_SPELLINGS = loadRawKeySpellings();

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
	// Case-exact: « Ctrl » and « Alt » are the names, `ctrl`, `lalt`, `LCtrl` the ids.
	for (const word of label.split(/[^\p{L}\p{N}_]+/u))
		if (RAW_KEY_SPELLINGS.has(word)) return `shows the raw key "${word}"`;
	return '';
}

/**
 * Finds where a French text glues high punctuation to the word before it.
 * URL schemes are the technical tokens that legitimately do so.
 * @param {string} text French text.
 * @returns {string} The glued word and its mark, or '' for correct text.
 */
function frenchPunctuationDefect(text) {
	for (const match of text.matchAll(/(\S*[\p{L}\p{N})\]}»])([:?!;])(?=\s|$)/gu))
		if (!(match[2] === ':' && /(^|[^\p{L}])(https?|msteams)$/u.test(match[1]))) return match[0];
	return '';
}

module.exports = { frenchPunctuationDefect, loadAllowlist, RAW_KEY_SPELLINGS, rowTextDefect };
