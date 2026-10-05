// _shared/ui/version_order.js

/**
 * ==============================================================================
 * MODULE: Release Version Order (page port)
 * DESCRIPTION:
 * The shared semver order for the pages that load plain scripts: the Versions
 * page labels a release « Install this version » or « Go back to this
 * version » by comparing its tag with the installed build.
 *
 * FEATURES & RATIONALE:
 * 1. One vector table: the canonical order is _shared/modules/updater/
 *    version.js, an ES module a page cannot load as a plain script. This port
 *    replays the same _shared/modules/updater/version_vectors.json in
 *    tools/test/test-version-compare-contract.cjs, like the Lua and AHK ports.
 * 2. Fail closed: a tag that is not semver orders as equal (0), so a page never
 *    calls a release older or newer on a guess.
 * 3. Classic script: one top-level var, so the Node tests read it from the same
 *    vm context the page scripts run in (project-shared-ui-logic-is-a-classic-script).
 * ==============================================================================
 */

var ReleaseVersionOrder = (function () {
	'use strict';

	var SEMVER = /^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$/;
	var DIGITS = /^\d+$/;

	/**
	 * Strips the blanks and the leading "v" a release tag may carry.
	 * @param {*} tag
	 * @return {string}
	 */
	function normalize(tag) {
		if (tag === null || tag === undefined) return '';
		var text = String(tag).trim();
		var first = text.charAt(0);
		if (first === 'v' || first === 'V') text = text.slice(1);
		return text;
	}

	/**
	 * Parses a tag into its numeric core and prerelease identifiers.
	 * @param {*} tag
	 * @return {?{major: number, minor: number, patch: number, prerelease: ?string[]}}
	 */
	function parse(tag) {
		var match = normalize(tag).match(SEMVER);
		if (!match) return null;
		return {
			major: Number(match[1]),
			minor: Number(match[2]),
			patch: Number(match[3]),
			prerelease: match[4] ? match[4].split('.') : null
		};
	}

	/** Orders two prerelease identifiers, numerically when both are digits. */
	function compareIdentifier(a, b) {
		if (DIGITS.test(a) && DIGITS.test(b)) {
			var left = Number(a);
			var right = Number(b);
			if (left === right) return 0;
			return left > right ? 1 : -1;
		}
		if (a === b) return 0;
		return a > b ? 1 : -1;
	}

	/** Orders two prerelease lists; a release without one is the greater. */
	function comparePrerelease(a, b) {
		if (!a && !b) return 0;
		if (!a) return 1;
		if (!b) return -1;
		var length = Math.max(a.length, b.length);
		for (var i = 0; i < length; i += 1) {
			if (a[i] === undefined) return -1;
			if (b[i] === undefined) return 1;
			var order = compareIdentifier(a[i], b[i]);
			if (order !== 0) return order;
		}
		return 0;
	}

	/**
	 * Orders two release tags: 1 when a is newer, -1 when older, 0 when equal
	 * or when either is not semver.
	 * @param {*} a
	 * @param {*} b
	 * @return {number}
	 */
	function compare(a, b) {
		var left = parse(a);
		var right = parse(b);
		if (!left || !right) return 0;
		if (left.major !== right.major) return left.major > right.major ? 1 : -1;
		if (left.minor !== right.minor) return left.minor > right.minor ? 1 : -1;
		if (left.patch !== right.patch) return left.patch > right.patch ? 1 : -1;
		return comparePrerelease(left.prerelease, right.prerelease);
	}

	return { normalize: normalize, parse: parse, compare: compare };
})();
