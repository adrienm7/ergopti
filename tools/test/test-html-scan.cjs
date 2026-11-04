// tools/test/test-html-scan.cjs

/**
 * ==============================================================================
 * MODULE: HTML Scan Test
 * DESCRIPTION:
 * Holds tools/test/lib/html-scan.cjs to the HTML tokenizer's reading: tag
 * names in any case, end tags with trailing whitespace or text, every comment
 * closing form, and a refusal of an unclosed comment.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const { stripHtmlComments, scriptElements, startTags } = require('./lib/html-scan.cjs');

assert.equal(
	stripHtmlComments('a<!-- x -->b<!-->c<!--->d<!-- y --!>e'),
	'abcde',
	'every comment closing form ends the comment'
);
assert.throws(() => stripHtmlComments('a<!-- open'), /unclosed HTML comment/);
assert.deepEqual(
	scriptElements('<SCRIPT src="a">x</script >y<script>z</SCRIPT\t\n bar><scripts>no</scripts>'),
	[
		{ attributes: ' src="a"', body: 'x' },
		{ attributes: '', body: 'z' }
	],
	'script elements match in any case and end at any HTML end tag'
);
assert.deepEqual(
	startTags('<LINK rel="a"><!-- <script src="hidden"> --><Script src="b"><linked>', [
		'link',
		'script'
	]),
	[
		{ name: 'link', tag: '<LINK rel="a">' },
		{ name: 'script', tag: '<Script src="b">' }
	],
	'start tags outside comments are listed under their lower-case name'
);

console.log('[OK] HTML scan: comments, script elements and start tags.');
