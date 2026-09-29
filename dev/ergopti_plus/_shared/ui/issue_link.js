// _shared/ui/issue_link.js

/**
 * ==============================================================================
 * MODULE: GitHub Issue Link Builder (Shared)
 * DESCRIPTION:
 * Builds the prefilled "new issue" URL of the repository's GitHub issue forms,
 * bounded to a byte budget. Pure: the caller passes the templates document
 * (_shared/modules/diagnostics/issue_templates.json) and the repository read
 * from _shared/modules/updater/defaults.json, so neither the owner nor the
 * repository is ever typed here.
 *
 * FEATURES & RATIONALE:
 * 1. Issue forms are prefilled by field id; `body=` is ignored for them, and
 *    labels come from the form's YAML because the `labels=` parameter only
 *    applies to users with triage permission.
 * 2. The budget is measured on the percent-encoded string: an accented letter
 *    costs 6 bytes and an emoji 12, and GitHub answers 414 a little above 8 KB.
 * 3. A prefill is a convenience, so an oversized one is cut rather than
 *    refused: the last parameter first, at a whole code point, ending with the
 *    truncation marker; a parameter that cannot keep one code point is dropped;
 *    the title goes last and the template never.
 * 4. One algorithm, three languages: the Lua port
 *    (_shared/lua/diagnostics/issue_link.lua) and the AHK port
 *    (windows/infra/issue_link.ahk) replay the same vectors
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
	 * Cuts one value so its encoded form fits `budget` bytes with the marker.
	 * @param {string} value
	 * @param {number} budget Encoded bytes the value may take, marker included.
	 * @param {string} marker
	 * @returns {string|null} The cut value, or null when not one code point fits.
	 */
	function cutValue(value, budget, marker) {
		var room = budget - percentEncode(marker).length;
		var parts = codePoints(value);
		var kept = '';
		var used = 0;
		// Strictly shorter than the value: a cut that keeps everything is no cut
		for (var i = 0; i < parts.length - 1; i++) {
			var cost = encodeCodePoint(parts[i]).length;
			if (used + cost > room) break;
			kept += parts[i];
			used += cost;
		}
		return kept === '' ? null : kept + marker;
	}

	/**
	 * Builds the prefilled issue URL.
	 * @param {object} templates The issue_templates.json document.
	 * @param {{owner: string, repo: string}} repository From updater defaults.json.
	 * @param {string} templateId Key of templates.templates ("bug", "feature").
	 * @param {Object<string, string>} values Title and field values by id.
	 * @returns {string}
	 * @throws {Error} On an unknown template or a URL that cannot fit at all.
	 */
	function buildIssueUrl(templates, repository, templateId, values) {
		var template = templates && templates.templates && templates.templates[templateId];
		if (!template) throw new Error('issue_link: unknown template "' + templateId + '"');
		if (!repository || !repository.owner || !repository.repo) {
			throw new Error('issue_link: the repository needs an owner and a repo');
		}
		var max = templates.max_url_bytes;
		var marker = templates.truncation_marker;
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

		var params = [['template', template.file]];
		if (values.title) params.push(['title', template.title_prefix + values.title]);
		for (var f = 0; f < template.fields.length; f++) {
			var id = template.fields[f];
			if (values[id]) params.push([id, String(values[id])]);
		}

		for (var i = params.length - 1; i >= 1; i--) {
			var over = joinUrl(base, params).length - max;
			if (over <= 0) break;
			var cut = cutValue(params[i][1], percentEncode(params[i][1]).length - over, marker);
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
		return url;
	}

	var api = { percentEncode: percentEncode, buildIssueUrl: buildIssueUrl };
	global.ErgoptiIssueLink = api;
})(window);
