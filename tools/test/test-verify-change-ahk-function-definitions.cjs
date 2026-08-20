// tools/test/test-verify-change-ahk-function-definitions.cjs

/**
 * ==============================================================================
 * MODULE: verify-change AHK Function-Definition Scanner Tests
 * DESCRIPTION:
 * Proves the silent-failure pre-check recognizes real multiline/nested AHK
 * definitions without laundering a column-zero call site into a definition.
 *
 * FEATURES & RATIONALE:
 * 1. A multiline production signature previously made `verify-change --plan`
 *    fail even though both the function and its causal AHK positive control
 *    existed.
 * 2. Nested defaults and strings contain parentheses, so a lazy regex is not a
 *    safe substitute for balanced scanning.
 * 3. A call can also begin at column zero; only a braced definition satisfies
 *    the pre-check.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const { hasAhkFunctionDefinition } = require('./verify-change.cjs');

const multiline = String.raw`
_Updater_CancelSelfUpdateTransaction(LogMessage, RebuildMenu := true,
	SurfacePausedRequest := false) {
	Worker.terminate()
}
`;
assert.equal(
	hasAhkFunctionDefinition(multiline, '_Updater_CancelSelfUpdateTransaction'),
	true,
	'a real multiline signature must satisfy the silent-failure pre-check',
);

const nestedDefaults = [
	'Resolve(Config := Map("predicate", IsReady("value)")), /* signature comment */',
	'\tMessage := "escaped backtick: `` and quote: `"") {',
	'\treturn Config',
	'}',
].join('\n');
assert.equal(
	hasAhkFunctionDefinition(nestedDefaults, 'Resolve'),
	true,
	'nested defaults, quoted parentheses and comments must not truncate a signature',
);

const callOnly = String.raw`
_Updater_CancelSelfUpdateTransaction(
	"ordinary call", true)

Sibling() {
	return true
}
`;
assert.equal(
	hasAhkFunctionDefinition(callOnly, '_Updater_CancelSelfUpdateTransaction'),
	false,
	'a column-zero call site must not masquerade as a function definition',
);

const blockCommentOnly = String.raw`
/**
Ghost() {
	return "not executable"
}
*/
`;
assert.equal(
	hasAhkFunctionDefinition(blockCommentOnly, 'Ghost'),
	false,
	'a pseudo-definition inside a block comment must not prove that a scanned symbol exists',
);

const singleQuotedNoise = [
	"Pattern := 'an embedded \" and Ghost() { stay string data }'",
	'Real() {',
	'\treturn true',
	'}',
].join('\n');
assert.equal(
	hasAhkFunctionDefinition(singleQuotedNoise, 'Ghost'),
	false,
	'a pseudo-definition inside an AHK single-quoted string must not satisfy the pre-check',
);
assert.equal(
	hasAhkFunctionDefinition(singleQuotedNoise, 'Real'),
	true,
	'a real definition after a single-quoted string must remain reachable',
);

console.log('verify-change AHK function-definition scanner: OK');
