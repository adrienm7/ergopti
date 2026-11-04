// tools/lib/text-escape.cjs

/**
 * ==============================================================================
 * MODULE: Text Escapes
 * DESCRIPTION:
 * The escapes tools apply before they splice literal text into a regular
 * expression or a Markdown table cell.
 *
 * FEATURES & RATIONALE:
 * 1. Complete: the escape character itself is escaped first, so a literal
 *    ending in a backslash cannot cancel the escape added after it.
 * 2. One spelling: tools import these instead of repeating a partial
 *    `.replace(/\./g, ...)` that covers only the characters seen so far.
 * ==============================================================================
 */

'use strict';

/**
 * Escapes every regular-expression metacharacter of a literal.
 * @param {string} text Literal text.
 * @returns {string} Regular-expression source matching exactly that text.
 */
function escapeRegExp(text) {
	return String(text).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * Escapes a Markdown table cell and folds its line breaks. A GFM table row
 * reads `\x` as one escaped pair, so only a pipe and the backslashes right
 * before it can end a cell early: each such backslash is doubled and the pipe
 * escaped. Other backslashes stay as written, because a code span such as
 * `C:\Windows` shows a doubled backslash literally.
 * @param {string} text Cell text.
 * @returns {string} Text safe to place between two `|` delimiters.
 */
function escapeTableCell(text) {
	return String(text)
		.replace(/\\*\|/g, (run) => `${'\\'.repeat(2 * (run.length - 1))}\\|`)
		.replace(/\r?\n/g, ' ');
}

module.exports = { escapeRegExp, escapeTableCell };
