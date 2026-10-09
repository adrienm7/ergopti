// _shared/ui/redact.js

/**
 * ==============================================================================
 * MODULE: Diagnostics Redaction (Shared Page Port)
 * DESCRIPTION:
 * Removes what must not leave the machine from diagnostic text before it is
 * copied, saved or sent to a GitHub issue: token-like secrets, the home folder
 * and the account name. The diagnostics page builds that text and shows a
 * preview of it, so the page redacts it; the rules are data in
 * _shared/modules/diagnostics/redaction.json, handed over by the host.
 *
 * FEATURES & RATIONALE:
 * 1. One algorithm, three languages: the Lua port
 *    (_shared/lua/diagnostics/redact.lua) and the AHK port
 *    (windows/infra/redact.ahk) replay the same vectors
 *    (_shared/tests/corpus/diagnostics/redaction_vectors.json).
 * 2. Secrets first, so a token that happens to contain the account name is
 *    removed whole rather than half-rewritten.
 * 3. The home folder in every spelling a log can hold (both slash styles),
 *    case-insensitively where the file system is (Windows), and only as a
 *    whole path: /Users/jdoe2 is not /Users/jdoe.
 * 4. The account name only as a whole word of a minimum length: a one-letter
 *    account name replaced everywhere would shred the report.
 * 5. Case folding is ASCII-only, as in the other ports. toLowerCase() would
 *    also fold non-ASCII letters and change the length of some strings, which
 *    would shift every index found in the folded copy.
 * ==============================================================================
 */

(function (global) {
	'use strict';

	// ====================================
	// ====================================
	// ======= 1/ Character Classes =======
	// ====================================
	// ====================================

	// The charsets redaction.json may name
	var CHARSETS = {
		alnum: /^[A-Za-z0-9]$/,
		word: /^[A-Za-z0-9_]$/,
		word_dash: /^[A-Za-z0-9_-]$/
	};

	// A character that continues an identifier: a match next to one is part of a
	// longer word and is left alone
	var WORD_CHAR = /^[A-Za-z0-9_]$/;

	// A character that continues a path segment after the home folder
	var PATH_CHAR = /^[A-Za-z0-9_.-]$/;

	// The characters a bearer token is made of
	var BEARER_CHAR = /^[A-Za-z0-9._~+/=-]$/;

	// Blanks between a key, its separator and its value
	var BLANK = /^[ \t]$/;

	// Quotes around a key or a value
	var QUOTE = /^["']$/;

	// The characters that end an unquoted key=value secret. Spelled out rather
	// than \s: a JavaScript \s also matches a no-break space, Lua's %s does not
	var VALUE_STOP = /^[ \t\n\v\f\r"',;)}&]$/;

	/**
	 * True when the character at `index` exists and matches the class.
	 * @param {string} text
	 * @param {number} index 0-based.
	 * @param {RegExp} pattern Matches one character.
	 * @returns {boolean}
	 */
	function charIs(text, index, pattern) {
		if (index < 0 || index >= text.length) return false;
		return pattern.test(text.charAt(index));
	}

	/**
	 * Counts the code points of a string (a surrogate pair is one).
	 * @param {string} text
	 * @returns {number}
	 */
	function codePointCount(text) {
		return Array.from(text).length;
	}

	/**
	 * Lower-cases A-Z only, keeping every other character and the length.
	 * @param {string} text
	 * @returns {string}
	 */
	function asciiLower(text) {
		return text.replace(/[A-Z]/g, function (ch) {
			return String.fromCharCode(ch.charCodeAt(0) + 32);
		});
	}

	/**
	 * Returns the index of the last character of the run of `pattern` starting
	 * at `from`.
	 * @param {string} text
	 * @param {number} from 0-based.
	 * @param {RegExp} pattern
	 * @returns {number} The run's last index, from - 1 when the run is empty.
	 */
	function runEnd(text, from, pattern) {
		var i = from;
		while (charIs(text, i, pattern)) i++;
		return i - 1;
	}

	// ======================================
	// ======================================
	// ======= 2/ Generic Replacement =======
	// ======================================
	// ======================================

	/**
	 * Replaces every accepted occurrence of `needle`, scanning left to right.
	 * @param {string} text
	 * @param {string} needle Non-empty literal.
	 * @param {boolean} caseInsensitive ASCII-only folding.
	 * @param {function(string, number, number): (null|{text: string, last: number})} accept
	 *   Receives the text and the first and last index of the occurrence; returns
	 *   the replacement and the last index it consumes, or null to keep it.
	 * @returns {string}
	 */
	function replaceOccurrences(text, needle, caseInsensitive, accept) {
		var haystack = caseInsensitive ? asciiLower(text) : text;
		var target = caseInsensitive ? asciiLower(needle) : needle;
		var out = '';
		var pos = 0;
		for (;;) {
			var first = haystack.indexOf(target, pos);
			if (first < 0) break;
			var last = first + target.length - 1;
			var accepted = accept(text, first, last);
			if (accepted) {
				out += text.substring(pos, first) + accepted.text;
				pos = accepted.last + 1;
			} else {
				out += text.substring(pos, first + 1);
				pos = first + 1;
			}
		}
		return out + text.substring(pos);
	}

	// ============================
	// ============================
	// ======= 3/ The Rules =======
	// ============================
	// ============================

	/**
	 * Replaces token-like secrets (prefix + a long run of its charset).
	 * @param {string} text
	 * @param {object} rules Decoded redaction.json.
	 * @returns {string}
	 */
	function redactTokens(text, rules) {
		rules.token_prefixes.forEach(function (token) {
			var pattern = CHARSETS[token.charset];
			if (!pattern) throw new Error('redact: unknown charset ' + token.charset);
			text = replaceOccurrences(text, token.prefix, false, function (source, first, last) {
				if (charIs(source, first - 1, WORD_CHAR)) return null;
				var stop = runEnd(source, last + 1, pattern);
				if (stop - last < token.min_length) return null;
				return { text: rules.secret_placeholder, last: stop };
			});
		});
		return text;
	}

	/**
	 * Replaces the credential of an "Authorization: Bearer <token>" value.
	 * @param {string} text
	 * @param {object} rules
	 * @returns {string}
	 */
	function redactBearer(text, rules) {
		return replaceOccurrences(text, 'bearer', true, function (source, first, last) {
			if (charIs(source, first - 1, WORD_CHAR)) return null;
			var spaces = runEnd(source, last + 1, BLANK);
			if (spaces === last) return null;
			var stop = runEnd(source, spaces + 1, BEARER_CHAR);
			if (stop - spaces < rules.bearer_min_length) return null;
			return { text: source.substring(first, spaces + 1) + rules.secret_placeholder, last: stop };
		});
	}

	/**
	 * Replaces the value of a key=value or "key": "value" secret, keeping the key.
	 * @param {string} text
	 * @param {object} rules
	 * @returns {string}
	 */
	function redactKeyValues(text, rules) {
		rules.secret_keys.forEach(function (key) {
			text = replaceOccurrences(text, key, true, function (source, first, last) {
				if (charIs(source, first - 1, WORD_CHAR) || charIs(source, last + 1, WORD_CHAR))
					return null;
				var i = last + 1;
				if (charIs(source, i, QUOTE)) i++;
				i = runEnd(source, i, BLANK) + 1;
				if (!charIs(source, i, /^[=:]$/)) return null;
				i = runEnd(source, i + 1, BLANK) + 1;
				if (charIs(source, i, QUOTE)) i++;
				var stop = i;
				while (stop < source.length && !charIs(source, stop, VALUE_STOP)) stop++;
				stop--;
				if (codePointCount(source.substring(i, stop + 1)) < rules.secret_value_min_length)
					return null;
				return { text: source.substring(first, i) + rules.secret_placeholder, last: stop };
			});
		});
		return text;
	}

	/**
	 * Replaces the home folder, in both slash styles, by its placeholder.
	 * @param {string} text
	 * @param {object} rules
	 * @param {string|undefined} home
	 * @param {boolean} caseInsensitive
	 * @returns {string}
	 */
	function redactHome(text, rules, home, caseInsensitive) {
		if (typeof home !== 'string') return text;
		var trimmed = home.replace(/[\/\\]+$/, '');
		if (trimmed === '') return text;
		var spellings = [];
		[trimmed, trimmed.replace(/\\/g, '/'), trimmed.replace(/\//g, '\\')].forEach(
			function (spelling) {
				if (spellings.indexOf(spelling) < 0) spellings.push(spelling);
			}
		);
		spellings.forEach(function (spelling) {
			text = replaceOccurrences(text, spelling, caseInsensitive, function (source, first, last) {
				if (charIs(source, last + 1, PATH_CHAR)) return null;
				return { text: rules.home_placeholder, last: last };
			});
		});
		return text;
	}

	/**
	 * Replaces the account name, as a whole word, by its placeholder.
	 * @param {string} text
	 * @param {object} rules
	 * @param {string|undefined} user
	 * @param {boolean} caseInsensitive
	 * @returns {string}
	 */
	function redactAccount(text, rules, user, caseInsensitive) {
		if (typeof user !== 'string' || codePointCount(user) < rules.min_account_name_length)
			return text;
		return replaceOccurrences(text, user, caseInsensitive, function (source, first, last) {
			if (charIs(source, first - 1, WORD_CHAR) || charIs(source, last + 1, WORD_CHAR)) return null;
			return { text: rules.account_placeholder, last: last };
		});
	}

	// =============================
	// =============================
	// ======= 4/ Public API =======
	// =============================
	// =============================

	/**
	 * Redacts diagnostic text before it leaves the machine.
	 * @param {string} text
	 * @param {object} rules Decoded _shared/modules/diagnostics/redaction.json.
	 * @param {{home?: string, user?: string, case_insensitive?: boolean}} context
	 *   The platform's home folder, account name, and whether its paths compare
	 *   case-insensitively.
	 * @returns {string}
	 * @throws {Error} When the text is not a string or the rules are missing.
	 */
	function apply(text, rules, context) {
		if (typeof text !== 'string') throw new Error('redact: text must be a string');
		if (!rules || typeof rules !== 'object')
			throw new Error('redact: rules must be the decoded redaction.json');
		context = context && typeof context === 'object' ? context : {};
		var folded = context.case_insensitive === true;
		text = redactTokens(text, rules);
		text = redactBearer(text, rules);
		text = redactKeyValues(text, rules);
		text = redactHome(text, rules, context.home, folded);
		text = redactAccount(text, rules, context.user, folded);
		return text;
	}

	global.ErgoptiRedact = { apply: apply };
})(window);
