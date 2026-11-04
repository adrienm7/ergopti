// tools/test/lib/json-text-mutations.cjs

/**
 * ==============================================================================
 * MODULE: JSON Text Mutations
 * DESCRIPTION:
 * Edits serialized JSON at a stated position, for refusal controls that feed a
 * reader one extra or doubled member.
 *
 * FEATURES & RATIONALE:
 * 1. Positional: the edit targets the opening brace of the top-level object
 *    instead of the first "{" a text search happens to find.
 * 2. Fail fast: text that is not an object is refused, so a control cannot
 *    silently stop mutating the input it is meant to break.
 * ==============================================================================
 */

'use strict';

/**
 * Inserts a member at the start of a serialized top-level JSON object.
 * @param {string} encoded Serialized JSON object.
 * @param {string} member Serialized `"key":value` text.
 * @returns {string} The object with that member first.
 * @throws {Error} When the text does not start with an object.
 */
function prependObjectMember(encoded, member) {
	if (!encoded.startsWith('{'))
		throw new Error('prependObjectMember: the text is not a JSON object');
	const rest = encoded.slice(1);
	return rest.startsWith('}') ? `{${member}${rest}` : `{${member},${rest}`;
}

module.exports = { prependObjectMember };
