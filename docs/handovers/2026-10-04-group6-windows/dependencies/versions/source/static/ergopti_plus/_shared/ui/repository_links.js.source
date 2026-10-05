// _shared/ui/repository_links.js

/**
 * ==============================================================================
 * MODULE: Repository Link Policy
 * DESCRIPTION:
 * Decides which links in remote release notes the shared pages make
 * clickable: absolute https URLs on this repository's github.com surface.
 *
 * FEATURES & RATIONALE:
 * 1. One predicate for every page that renders release notes (the Versions
 *    window and the update prompt's notes pane), so they cannot drift.
 * 2. Defence in depth: the page only offers a link; every native host checks
 *    the same repository allowlist again before it opens anything.
 * ==============================================================================
 */

(function (global) {
	'use strict';

	/**
	 * Returns whether a URL belongs to the repository's HTTPS surface.
	 * @param {string} value - Candidate URL.
	 * @param {string} owner - Repository owner.
	 * @param {string} repo - Repository name.
	 * @return {boolean}
	 */
	function isRepositoryUrl(value, owner, repo) {
		if (typeof value !== 'string' || value === '') return false;
		if (typeof owner !== 'string' || owner === '' || typeof repo !== 'string' || repo === '') {
			return false;
		}
		var parsed;
		try {
			parsed = new URL(value);
		} catch (error) {
			return false;
		}
		var root = '/' + owner + '/' + repo;
		return (
			parsed.protocol === 'https:' &&
			parsed.hostname === 'github.com' &&
			parsed.username === '' &&
			parsed.password === '' &&
			parsed.port === '' &&
			(parsed.pathname === root || parsed.pathname.indexOf(root + '/') === 0)
		);
	}

	global.isRepositoryUrl = isRepositoryUrl;
})(window);
