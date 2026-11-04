// tools/test/lib/html-scan.cjs

/**
 * ==============================================================================
 * MODULE: HTML Scan
 * DESCRIPTION:
 * The few HTML readings the test harnesses make of the repository's own pages:
 * dropping comments, and listing script elements or resource tags.
 *
 * FEATURES & RATIONALE:
 * 1. HTML rules, not lookalikes: tag names match in any case, an end tag may
 *    carry whitespace before its ">", and a comment closes at "-->", "--!>",
 *    or abruptly at "<!-->" and "<!--->", as the HTML tokenizer reads them.
 * 2. One pass: comments are removed by a left-to-right scan, so removing one
 *    cannot splice its neighbours into a new "<!--".
 * 3. Fail fast: an unclosed comment is refused instead of hiding the rest of
 *    the page from the harness.
 * ==============================================================================
 */

'use strict';

/**
 * Removes every comment of an HTML text.
 * @param {string} html Page text.
 * @returns {string} The text without its comments.
 * @throws {Error} When a comment is never closed.
 */
function stripHtmlComments(html) {
	const parts = [];
	let position = 0;
	for (;;) {
		const start = html.indexOf('<!--', position);
		if (start === -1) break;
		parts.push(html.slice(position, start));
		const body = start + 4;
		if (html.startsWith('>', body)) {
			position = body + 1;
			continue;
		}
		if (html.startsWith('->', body)) {
			position = body + 2;
			continue;
		}
		const close = /--!?>/g;
		close.lastIndex = body;
		const end = close.exec(html);
		if (!end) throw new Error(`unclosed HTML comment at offset ${start}`);
		position = end.index + end[0].length;
	}
	parts.push(html.slice(position));
	return parts.join('');
}

// A script element: the start tag, its raw text, then the first end tag, which
// HTML reads as "</script" followed by whitespace, "/" or ">".
const SCRIPT_ELEMENT = /<script(?=[\s/>])([^>]*)>([\s\S]*?)<\/script(?:[\s/][^>]*)?>/gi;

/**
 * Lists the script elements of an HTML text in document order.
 * @param {string} html Page text.
 * @returns {{attributes: string, body: string}[]} Raw attribute text and body.
 */
function scriptElements(html) {
	return [...html.matchAll(SCRIPT_ELEMENT)].map((match) => ({
		attributes: match[1],
		body: match[2]
	}));
}

/**
 * Lists the start tags of the named elements, outside comments.
 * @param {string} html Page text.
 * @param {string[]} names Lower-case element names.
 * @returns {{name: string, tag: string}[]} Lower-case name and raw tag text.
 */
function startTags(html, names) {
	const tag = /<([A-Za-z][A-Za-z0-9-]*)(?=[\s/>])[^>]*>/g;
	const wanted = new Set(names);
	const found = [];
	for (const match of stripHtmlComments(html).matchAll(tag)) {
		const name = match[1].toLowerCase();
		if (wanted.has(name)) found.push({ name, tag: match[0] });
	}
	return found;
}

module.exports = { stripHtmlComments, scriptElements, startTags };
