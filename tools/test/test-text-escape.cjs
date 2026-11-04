// tools/test/test-text-escape.cjs

/**
 * ==============================================================================
 * MODULE: Text Escapes Test
 * DESCRIPTION:
 * Holds tools/lib/text-escape.cjs to complete escapes: a literal spliced into
 * a regular expression matches only itself, and a Markdown table cell never
 * ends early, even when its text holds a backslash right before a pipe.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const { escapeRegExp, escapeTableCell } = require('../lib/text-escape.cjs');

// =====================================
// ===== 1/ Regular expressions ========
// =====================================

for (const literal of ['a.b', 'C:\\temp\\x.log', 'a\\.b', '(x|y)*', '[^]$', 'a{2}+?']) {
	const pattern = new RegExp(`^${escapeRegExp(literal)}$`);
	assert.ok(pattern.test(literal), `${JSON.stringify(literal)} matches itself`);
}
// A literal ending in a backslash must not swallow the escape added after it.
assert.ok(
	new RegExp(`^${escapeRegExp('a\\')}b$`).test('a\\b'),
	'a trailing backslash stays literal'
);
assert.ok(!new RegExp(`^${escapeRegExp('a.b')}$`).test('axb'), 'a dot is not a wildcard');

// ======================================
// ===== 2/ Markdown table cells ========
// ======================================

/**
 * Splits one GFM table row the way the GFM table scanner does: a backslash
 * and the character after it form one pair, any other pipe ends a cell.
 * @param {string} row Row text without its outer pipes.
 * @returns {string[]} Raw cell texts.
 */
function splitRow(row) {
	const cells = [''];
	for (let i = 0; i < row.length; i++) {
		if (row[i] === '\\' && i + 1 < row.length) {
			cells[cells.length - 1] += row[i] + row[i + 1];
			i++;
		} else if (row[i] === '|') cells.push('');
		else cells[cells.length - 1] += row[i];
	}
	return cells;
}

for (const text of ['a|b', 'a\\|b', 'a\\\\|b', 'ends with \\', '\\|\\|', 'plain']) {
	const cells = splitRow(` ${escapeTableCell(text)} | next `);
	assert.equal(cells.length, 2, `${JSON.stringify(text)} stays one cell`);
}
assert.equal(
	escapeTableCell('`C:\\Windows\\x.exe`'),
	'`C:\\Windows\\x.exe`',
	'a backslash before no pipe is kept'
);
assert.equal(escapeTableCell('one\r\ntwo\nthree'), 'one two three', 'line breaks fold to spaces');

console.log('[OK] text escapes: regular expressions and Markdown table cells.');
