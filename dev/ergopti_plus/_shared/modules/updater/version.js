// _shared/modules/updater/version.js

/**
 * Cross-driver version comparison and GitHub Releases URL helpers.
 * Both AHK (lib/updater.ahk) and Hammerspoon (lib/updater.lua) MUST
 * produce the same isNewerVersion() results as this module.
 */

'use strict';

const DEFAULT_GH_OWNER = 'adrienm7';
const DEFAULT_GH_REPO = 'ergopti';
const DEV_RELEASES_PAGE_SIZE = 10;

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
	if (!m) return null;
	return {
		major: Number(m[1]),
		minor: Number(m[2]),
		patch: Number(m[3]),
		prerelease: m[4] ? m[4].split('.') : null
	};
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
	if (aNum && bNum) {
		const ai = Number(a);
		const bi = Number(b);
		if (ai > bi) return 1;
		if (ai < bi) return -1;
		return 0;
	}
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
	if (pa.major !== pb.major) return pa.major > pb.major ? 1 : -1;
	if (pa.minor !== pb.minor) return pa.minor > pb.minor ? 1 : -1;
	if (pa.patch !== pb.patch) return pa.patch > pb.patch ? 1 : -1;
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
 * @param {string} channel "main" | "dev"
 * @param {object} [opts]
 * @returns {string}
 */
function releaseApiUrl(channel, opts = {}) {
	const owner = opts.owner ?? DEFAULT_GH_OWNER;
	const repo = opts.repo ?? DEFAULT_GH_REPO;
	const base = `https://api.github.com/repos/${owner}/${repo}/releases`;
	if (channel === 'dev') {
		const page = opts.devPageSize ?? DEV_RELEASES_PAGE_SIZE;
		return `${base}?per_page=${page}`;
	}
	return `${base}/latest`;
}

/**
 * Extracts tag_name from a single-release JSON object string.
 * @param {string} json
 * @returns {string}
 */
function parseTagName(json) {
	const m = json.match(/"tag_name"\s*:\s*"([^"]+)"/);
	return m ? m[1] : '';
}

/**
 * Picks the highest-semver prerelease from a GitHub releases array JSON string.
 * GitHub lists by publish date, not semver — a newer stable at the top must not
 * hide a higher prerelease further down the page.
 * @param {string} json
 * @returns {string}
 */
function pickLatestPrereleaseJson(json) {
	const chunks = splitReleasesArray(json);
	let bestChunk = '';
	let bestTag = '';
	for (const chunk of chunks) {
		if (!parsePrereleaseFlag(chunk)) continue;
		const tag = parseTagName(chunk);
		if (!tag) continue;
		if (!bestTag || compareVersions(tag, bestTag) > 0) {
			bestTag = tag;
			bestChunk = chunk;
		}
	}
	if (bestChunk) return bestChunk;
	return chunks[0] ?? json;
}

/**
 * @param {string} json
 * @returns {string}
 */
function unwrapFirstPrereleaseJson(json) {
	return pickLatestPrereleaseJson(json);
}

/**
 * @param {string} json
 * @returns {boolean}
 */
function parsePrereleaseFlag(json) {
	const m = json.match(/"prerelease"\s*:\s*(true|false)/);
	return m ? m[1] === 'true' : false;
}

/**
 * @param {string} json
 * @returns {string[]}
 */
function splitReleasesArray(json) {
	const out = [];
	const trimmed = json.trimStart();
	if (!trimmed.startsWith('[')) return out;
	let pos = 1;
	let depth = 0;
	let start = 0;
	let inStr = false;
	let esc = false;
	while (pos < trimmed.length) {
		const c = trimmed[pos];
		if (inStr) {
			if (esc) esc = false;
			else if (c === '\\') esc = true;
			else if (c === '"') inStr = false;
		} else if (c === '"') {
			inStr = true;
		} else if (c === '{') {
			if (depth === 0) start = pos;
			depth += 1;
		} else if (c === '}') {
			depth -= 1;
			if (depth === 0 && start > 0) {
				out.push(trimmed.slice(start, pos + 1));
				start = 0;
			}
		}
		pos += 1;
	}
	return out;
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

export {
	DEFAULT_GH_OWNER,
	DEFAULT_GH_REPO,
	DEV_RELEASES_PAGE_SIZE,
	normalizeTag,
	parseVersion,
	parseTagName,
	compareVersions,
	isNewerVersion,
	releaseApiUrl,
	pickLatestPrereleaseJson,
	unwrapFirstPrereleaseJson,
	splitReleasesArray,
	parsePrereleaseFlag,
	versionTestVectors
};
