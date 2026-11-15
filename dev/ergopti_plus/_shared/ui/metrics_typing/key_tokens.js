// _shared/ui/metrics_typing/key_tokens.js

/**
 * ==============================================================================
 * MODULE: N-gram Key Tokens
 * DESCRIPTION:
 * Reads a stored n-gram key back into its tokens, the dashboard's half of
 * _shared/metrics/engine/privacy/token_encoding.lua. A key is a run of markers of the
 * closed list, the escape "[[" for a typed "[", and single characters, so every
 * page that needs to count, split or show a key goes through here rather than
 * guessing from brackets. token_encoding_vectors.json pins it with the walkers.
 * ==============================================================================
 */

/**
 * Whether a token of key_tokens is a marker rather than a typed character.
 * @param {string} token
 * @returns {boolean}
 */
function is_key_marker(token) {
	return token.length > 1 && token[0] === '[';
}

/**
 * Splits a key into tokens: "[" for a typed bracket, a marker as written, or one
 * code point. The dashboard lowercases keys, so markers match in any case. A "["
 * that opens neither reads as typed, so an unexpected key still renders.
 * @param {string} key
 * @returns {string[]}
 */
function key_tokens(key) {
	const tokens = [];
	let index = 0;
	while (index < key.length) {
		if (key[index] !== '[') {
			const character = String.fromCodePoint(key.codePointAt(index));
			tokens.push(character);
			index += character.length;
			continue;
		}
		if (key.startsWith(KEYSTATS_LITERAL_BRACKET, index)) {
			tokens.push('[');
			index += KEYSTATS_LITERAL_BRACKET.length;
			continue;
		}
		const closing = key.indexOf(']', index);
		const spelling = closing < 0 ? '' : key.slice(index, closing + 1);
		const is_marker = KEYSTATS_MARKERS.has(spelling.toUpperCase());
		tokens.push(is_marker ? spelling : '[');
		index += is_marker ? spelling.length : 1;
	}
	return tokens;
}

/**
 * The code points of a key once its typed brackets are unescaped. The bigram
 * analyses compare single characters, and a marker keeps its several code points
 * so that those analyses go on skipping it.
 * @param {string} key
 * @returns {string[]}
 */
function key_chars(key) {
	return key_tokens(key).flatMap((token) => Array.from(token));
}

/**
 * The key as the user reads it, which is what a search has to match.
 * @param {string} key
 * @returns {string}
 */
function key_text(key) {
	return key_tokens(key).join('');
}
