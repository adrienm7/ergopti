// _shared/modules/updater/version.js

/**
 * Cross-driver version comparison: the canonical semver ordering the AHK,
 * macOS and Linux updaters replay (version_vectors.json). Which release a
 * channel offers is decided by the update-channel registry (channels.json).
 */

'use strict';

/**
 * @param {string} tag
 * @returns {string}
 */
function normalizeTag(tag) {
	if (tag == null) return '';
	let t = String(tag).trim();
	if (t.startsWith('v') || t.startsWith('V')) t = t.slice(1);
	return t;
}

/**
 * @param {string} tag
 * @returns {{ major: number, minor: number, patch: number, prerelease: string[]|null }|null}
 */
function parseVersion(tag) {
	const norm = normalizeTag(tag);
	const m = norm.match(/^(\d+)\.(\d+)\.(\d+)(?:-(.+))?$/);
	if (!m || (m[4] && (m[4].startsWith('.') || m[4].endsWith('.') || m[4].includes('..'))))
		return null;
	return {
		major: Number(m[1]),
		minor: Number(m[2]),
		patch: Number(m[3]),
		prerelease: m[4] ? m[4].split('.') : null
	};
}

/** Compare decimal strings exactly without floating-point conversion. */
function compareDecimal(a, b) {
	const left = a.replace(/^0+/, '');
	const right = b.replace(/^0+/, '');
	if (left.length !== right.length) return left.length > right.length ? 1 : -1;
	return left === right ? 0 : left > right ? 1 : -1;
}

/**
 * Semver prerelease identifier compare (numeric when all digits).
 * @param {string} a
 * @param {string} b
 * @returns {number} 1 | -1 | 0
 */
function comparePrereleaseId(a, b) {
	const aNum = /^\d+$/.test(a);
	const bNum = /^\d+$/.test(b);
	if (aNum !== bNum) return aNum ? -1 : 1;
	if (aNum && bNum) {
		return compareDecimal(a, b);
	}
	if (aNum !== bNum) return aNum ? -1 : 1;
	if (a > b) return 1;
	if (a < b) return -1;
	return 0;
}

/**
 * @param {string[]|null} a
 * @param {string[]|null} b
 * @returns {number} 1 if a>b, -1 if a<b, 0 if equal
 */
function comparePrerelease(a, b) {
	if (!a && !b) return 0;
	if (!a && b) return 1;
	if (a && !b) return -1;
	const len = Math.max(a.length, b.length);
	for (let i = 0; i < len; i += 1) {
		const ai = a[i];
		const bi = b[i];
		if (ai === undefined) return -1;
		if (bi === undefined) return 1;
		const cmp = comparePrereleaseId(ai, bi);
		if (cmp !== 0) return cmp;
	}
	return 0;
}

/**
 * @param {string} a
 * @param {string} b
 * @returns {number} 1 if a>b, -1 if a<b, 0 if equal
 */
function compareVersions(a, b) {
	const pa = parseVersion(a);
	const pb = parseVersion(b);
	if (!pa || !pb) {
		// Non-semver tag(s): refuse to order them. Fail closed (return 0 = "not
		// newer") rather than guess lexicographically — "10" vs "9" and other
		// ambiguous tags must never trigger or suppress an update by accident.
		// Mirrors macOS lib/updater.lua and AHK _Updater_CompareVersions; the
		// three are kept in lock-step by the version-compare parity gate (D-1).
		return 0;
	}
	// Retain parseVersion's public numeric fields; compare the original digits.
	const aCore = normalizeTag(a).match(/^(\d+)\.(\d+)\.(\d+)/);
	const bCore = normalizeTag(b).match(/^(\d+)\.(\d+)\.(\d+)/);
	for (let index = 1; index <= 3; index += 1) {
		const order = compareDecimal(aCore[index], bCore[index]);
		if (order !== 0) return order;
	}
	return comparePrerelease(pa.prerelease, pb.prerelease);
}

/**
 * @param {string} latest
 * @param {string} current
 * @returns {boolean}
 */
function isNewerVersion(latest, current) {
	return compareVersions(latest, current) > 0;
}

/**
 * @returns {object[]}
 */
function versionTestVectors() {
	return [
		{
			id: 'prerelease_increment',
			current: '2.5.0-dev.3',
			latest: '2.5.0-dev.4',
			expectNewer: true
		},
		{
			id: 'prerelease_numeric_order',
			current: '2.5.0-dev.10',
			latest: '2.5.0-dev.4',
			expectNewer: false
		},
		{
			id: 'same_prerelease',
			current: 'v2.5.0-dev.3',
			latest: '2.5.0-dev.3',
			expectNewer: false
		},
		{
			id: 'patch_bump',
			current: '2.4.9',
			latest: '2.5.0-dev.1',
			expectNewer: true
		},
		{
			id: 'stable_over_prerelease_same_core',
			current: '2.5.0-dev.4',
			latest: '2.5.0',
			expectNewer: true
		},
		{
			id: 'prerelease_not_newer_than_stable',
			current: '2.5.0',
			latest: '2.5.0-dev.4',
			expectNewer: false
		}
	];
}

export { normalizeTag, parseVersion, compareVersions, isNewerVersion, versionTestVectors };
