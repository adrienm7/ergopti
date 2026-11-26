// _shared/ui/issue_link.js

/**
 * ==============================================================================
 * MODULE: GitHub Issue Link Builder (Shared)
 * DESCRIPTION:
 * Builds the prefilled "new issue" URL of the repository's GitHub issue forms,
 * bounded to a byte budget. Pure: the caller passes the templates document
 * (_shared/diagnostics/data/issue_templates.json) and the repository read
 * from _shared/updater/data/defaults.json, so neither the owner nor the
 * repository is ever typed here.
 *
 * FEATURES & RATIONALE:
 * 1. Issue forms are prefilled by field id; `body=` is ignored for them, and
 *    labels come from the form's YAML because the `labels=` parameter only
 *    applies to users with triage permission.
 * 2. The budget is measured on the percent-encoded string: an accented letter
 *    costs 6 bytes and an emoji 12, and GitHub answers 414 a little above 8 KB.
 *    A signed-out click goes through /login?return_to=<the URL encoded again>,
 *    where each %XX becomes %25XX: when the templates set max_redirect_bytes,
 *    that redirect is bounded too, so a dense prefill is cut where a
 *    letter-dense one is not.
 * 3. A prefill is a convenience, so an oversized one is cut rather than
 *    refused: the last parameter first, at a whole code point, ending with the
 *    truncation marker; a parameter that cannot keep one code point is dropped;
 *    the title goes last and the template never.
 * 4. A cut field can carry a note (one line saying where the complete text is),
 *    appended after the truncation marker and counted in the budget: the
 *    caller passes it only for the field that holds the complete report.
 * 5. The complete report the user pastes into the form is bounded too:
 *    fitLines keeps whole lines under GitHub's issue body limit, closes a
 *    code block it cut open, and ends with the truncation marker and a note
 *    saying where the rest is.
 * 6. One algorithm, three languages: the Lua port
 *    (_shared/diagnostics/engine/reports/issue_link.lua) and the AHK port
 *    (windows/diagnostics/engine/reports/issue_link.ahk) replay the same vectors
 *    (_shared/tests/corpus/diagnostics/issue_link_vectors.json).
 * ==============================================================================
 */

(function (global) {
	'use strict';

	// RFC 3986 unreserved characters: the only ones a query value keeps literally
	var UNRESERVED = /^[A-Za-z0-9\-._~]$/;

	// A lone UTF-16 surrogate has no UTF-8 form; it is encoded as U+FFFD, the
	// replacement character, exactly as the AHK port does
	var REPLACEMENT_CODE_POINT = 0xfffd;

	/**
	 * Splits a string into code points (a surrogate pair is one code point).
	 * @param {string} text
	 * @returns {string[]}
	 */
	function codePoints(text) {
		return Array.from(text);
	}

	/**
	 * Percent-encodes one code point as UTF-8.
	 * @param {string} ch One code point.
	 * @returns {string}
	 */
	function encodeCodePoint(ch) {
		if (UNRESERVED.test(ch)) return ch;
		var cp = ch.codePointAt(0);
		if (cp >= 0xd800 && cp <= 0xdfff) cp = REPLACEMENT_CODE_POINT;
		var bytes;
		if (cp < 0x80) bytes = [cp];
		else if (cp < 0x800) bytes = [0xc0 | (cp >> 6), 0x80 | (cp & 0x3f)];
		else if (cp < 0x10000)
			bytes = [0xe0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3f), 0x80 | (cp & 0x3f)];
		else {
			bytes = [
				0xf0 | (cp >> 18),
				0x80 | ((cp >> 12) & 0x3f),
				0x80 | ((cp >> 6) & 0x3f),
				0x80 | (cp & 0x3f)
			];
		}
		var out = '';
		for (var i = 0; i < bytes.length; i++) {
			out += '%' + (bytes[i] < 16 ? '0' : '') + bytes[i].toString(16).toUpperCase();
		}
		return out;
	}

	/**
	 * Percent-encodes a query value: UTF-8, only unreserved characters literal.
	 * @param {string} text
	 * @returns {string}
	 */
	function percentEncode(text) {
		var parts = codePoints(String(text));
		var out = '';
		for (var i = 0; i < parts.length; i++) out += encodeCodePoint(parts[i]);
		return out;
	}

	/**
	 * Joins the parameters behind the base URL.
	 * @param {string} base
	 * @param {Array<[string, string]>} params
	 * @returns {string}
	 */
	function joinUrl(base, params) {
		var query = [];
		for (var i = 0; i < params.length; i++) {
			query.push(params[i][0] + '=' + percentEncode(params[i][1]));
		}
		return base + '?' + query.join('&');
	}

	/**
	 * Bytes a URL grows by when GitHub's login redirect encodes it again: every
	 * character outside the unreserved set (a %XX triplet's "%", a delimiter)
	 * becomes three.
	 * @param {string} encoded An already percent-encoded string.
	 * @returns {number}
	 */
	function reencodedGrowth(encoded) {
		var growth = 0;
		for (var i = 0; i < encoded.length; i++) {
			if (!UNRESERVED.test(encoded[i])) growth += 2;
		}
		return growth;
	}

	/**
	 * Cuts one value so it fits both budgets with the marker: its encoded form
	 * within `urlRoom` bytes and that form encoded again within `redirectRoom`.
	 * @param {string} value
	 * @param {number} urlRoom Encoded bytes the value may take, marker included.
	 * @param {number} redirectRoom Re-encoded bytes it may take, marker included.
	 * @param {string} marker
	 * @returns {string|null} The cut value, or null when not one code point fits.
	 */
	function cutValue(value, urlRoom, redirectRoom, marker) {
		var encodedMarker = percentEncode(marker);
		var room = urlRoom - encodedMarker.length;
		var redirect = redirectRoom - encodedMarker.length - reencodedGrowth(encodedMarker);
		var parts = codePoints(value);
		var kept = '';
		var used = 0;
		var usedRedirect = 0;
		// Strictly shorter than the value: a cut that keeps everything is no cut
		for (var i = 0; i < parts.length - 1; i++) {
			var encoded = encodeCodePoint(parts[i]);
			var cost = encoded.length;
			var redirectCost = cost + reencodedGrowth(encoded);
			if (used + cost > room || usedRedirect + redirectCost > redirect) break;
			kept += parts[i];
			used += cost;
			usedRedirect += redirectCost;
		}
		return kept === '' ? null : kept + marker;
	}

	/**
	 * Builds the prefilled issue URL.
	 * @param {object} templates The issue_templates.json document.
	 * @param {{owner: string, repo: string}} repository From updater defaults.json.
	 * @param {string} templateId Key of templates.templates ("bug", "feature").
	 * @param {Object<string, string>} values Title and field values by id.
	 * @param {Object<string, string>} [notes] One line per field id, appended on
	 *   its own line after the truncation marker when that field is cut.
	 * @returns {string}
	 * @throws {Error} On an unknown template or a URL that cannot fit at all.
	 */
	function buildIssueUrl(templates, repository, templateId, values, notes) {
		var template = templates && templates.templates && templates.templates[templateId];
		if (!template) throw new Error('issue_link: unknown template "' + templateId + '"');
		if (!repository || !repository.owner || !repository.repo) {
			throw new Error('issue_link: the repository needs an owner and a repo');
		}
		var max = templates.max_url_bytes;
		var marker = templates.truncation_marker;
		// The login redirect of a signed-out click carries the URL encoded again
		var redirectMax = templates.max_redirect_bytes;
		var redirectPrefix = templates.login_redirect_prefix;
		if (redirectMax !== undefined && typeof redirectPrefix !== 'string') {
			throw new Error('issue_link: max_redirect_bytes needs login_redirect_prefix');
		}
		var redirectLength = function (url) {
			return redirectPrefix.length + url.length + reencodedGrowth(url);
		};
		var pattern = String(templates.issue_new_url);
		if (pattern.indexOf('{owner}') < 0 || pattern.indexOf('{repo}') < 0) {
			throw new Error('issue_link: issue_new_url must contain {owner} and {repo}');
		}
		// Function replacements: an owner is data, never a replacement pattern
		var base = pattern
			.replace('{owner}', function () {
				return repository.owner;
			})
			.replace('{repo}', function () {
				return repository.repo;
			});
		values = values || {};
		notes = notes || {};

		var params = [['template', template.file]];
		if (values.title) params.push(['title', template.title_prefix + values.title]);
		for (var f = 0; f < template.fields.length; f++) {
			var id = template.fields[f];
			if (values[id]) params.push([id, String(values[id])]);
		}

		for (var i = params.length - 1; i >= 1; i--) {
			var joined = joinUrl(base, params);
			var over = joined.length - max;
			var redirectOver = redirectMax === undefined ? 0 : redirectLength(joined) - redirectMax;
			if (over <= 0 && redirectOver <= 0) break;
			var ending = notes[params[i][0]] ? marker + '\n\n' + notes[params[i][0]] : marker;
			var encodedValue = percentEncode(params[i][1]);
			var cut = cutValue(
				params[i][1],
				encodedValue.length - Math.max(over, 0),
				encodedValue.length + reencodedGrowth(encodedValue) - Math.max(redirectOver, 0),
				ending
			);
			if (cut === null) params.splice(i, 1);
			else {
				params[i] = [params[i][0], cut];
				break;
			}
		}

		var url = joinUrl(base, params);
		if (url.length > max) {
			throw new Error('issue_link: ' + url.length + ' bytes left after every cut, budget ' + max);
		}
		if (redirectMax !== undefined && redirectLength(url) > redirectMax) {
			throw new Error(
				'issue_link: a ' +
					redirectLength(url) +
					'-byte login redirect left after every cut, budget ' +
					redirectMax
			);
		}
		return url;
	}

	// A line opening or closing a Markdown code block
	var FENCE = '```';

	/**
	 * UTF-8 length of a string; a lone surrogate counts as U+FFFD.
	 * @param {string} text
	 * @returns {number}
	 */
	function utf8Bytes(text) {
		var parts = codePoints(text);
		var total = 0;
		for (var i = 0; i < parts.length; i++) {
			var cp = parts[i].codePointAt(0);
			total += cp < 0x80 ? 1 : cp < 0x800 ? 2 : cp < 0x10000 ? 3 : 4;
		}
		return total;
	}

	/**
	 * Bounds a text to a UTF-8 byte budget at whole lines. A text that fits is
	 * returned unchanged; otherwise the longest prefix of whole lines that fits
	 * with its ending is kept, a code block it leaves open is closed (a kept
	 * prefix ending on the opening line drops that line instead), and the
	 * truncation marker, a blank line and the note follow.
	 * @param {string} text
	 * @param {number} maxBytes
	 * @param {string} marker
	 * @param {string} note
	 * @returns {string}
	 * @throws {Error} When not one line fits with the ending.
	 */
	function fitLines(text, maxBytes, marker, note) {
		text = String(text);
		if (utf8Bytes(text) <= maxBytes) return text;
		var ending = marker + '\n\n' + note;
		var endingBytes = utf8Bytes(ending);
		var lines = text.split('\n');
		var prefixBytes = [0];
		var open = false;
		var best = -1;
		var bestOpen = false;
		// Strictly fewer lines than the text: a cut that keeps everything is no cut
		for (var k = 1; k < lines.length; k++) {
			var line = lines[k - 1];
			prefixBytes[k] = (k === 1 ? 0 : prefixBytes[k - 1] + 1) + utf8Bytes(line);
			var fence = line.slice(0, FENCE.length) === FENCE;
			if (fence) open = !open;
			// A block cut right after its opening line keeps nothing of it
			var count = fence && open ? k - 1 : k;
			var countOpen = fence && open ? false : open;
			if (count < 1) continue;
			var cost = prefixBytes[count] + 1 + (countOpen ? FENCE.length + 1 : 0) + endingBytes;
			if (cost <= maxBytes) {
				best = count;
				bestOpen = countOpen;
			}
		}
		if (best < 1) {
			throw new Error('issue_link: not one line fits ' + maxBytes + ' bytes with its ending');
		}
		return lines.slice(0, best).join('\n') + '\n' + (bestOpen ? FENCE + '\n' : '') + ending;
	}

	var api = { percentEncode: percentEncode, buildIssueUrl: buildIssueUrl, fitLines: fitLines };
	global.ErgoptiIssueLink = api;
})(window);
