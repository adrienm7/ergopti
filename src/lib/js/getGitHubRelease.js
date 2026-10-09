// src/lib/js/getGitHubRelease.js
//
// Resolves download URLs from GitHub Releases, routing to the latest
// stable release on production and to the latest pre-release on dev.
//
// All release assets (keyboard layout installers, ErgoptiPlus binaries,
// installation scripts) are fetched from here rather than served from static/.

import { branchForInstall } from '$lib/js/isDev.js';

const REPO = 'adrienm7/ergopti';
const API_BASE = `https://api.github.com/repos/${REPO}`;
const DL_BASE = `https://github.com/${REPO}/releases/download`;

/** @typedef {{tag_name: string, prerelease: boolean, assets: Array<{name: string, browser_download_url: string}>}} GitHubRelease */

// In-memory cache so a single page load only hits the API once per channel.
/** @type {Record<string, {tag: string, assets: Record<string, string>} | null>} */
const _cache = {};

/**
 * Fetch the appropriate GitHub endpoint for the current
 * channel (stable = latest non-prerelease, dev = latest prerelease).
 *
 * @param {'main'|'dev'} channel
 * @returns {Promise<{tag: string, assets: Record<string, string>} | null>}
 */
async function fetchRelease(channel) {
	if (channel in _cache) return _cache[channel];

	try {
		// Stable releases can be buried beyond the dev list's first page.
		// GitHub's latest endpoint selects stable independently of that page.
		const endpoint = channel === 'dev' ? '/releases?per_page=10' : '/releases/latest';
		const res = await fetch(`${API_BASE}${endpoint}`);
		if (!res.ok) {
			_cache[channel] = null;
			return null;
		}
		/** @type {GitHubRelease | GitHubRelease[]} */
		const payload = await res.json();

		const release =
			channel === 'dev'
				? /** @type {GitHubRelease[]} */ (payload).find((r) => r.prerelease)
				: /** @type {GitHubRelease} */ (payload);

		if (!release || (channel === 'main' && release.prerelease)) {
			_cache[channel] = null;
			return null;
		}

		/** @type {Record<string, string>} */
		const assets = {};
		for (const asset of release.assets) {
			assets[asset.name] = asset.browser_download_url;
		}

		const result = { tag: release.tag_name, assets };
		_cache[channel] = result;
		return result;
	} catch {
		_cache[channel] = null;
		return null;
	}
}

/**
 * Returns a reactive store-like object wrapping the async release fetch.
 * Components `await` this once on mount and receive a plain object with:
 *   - `tag`    — the release tag (e.g. "v2.2.1")
 *   - `url(assetName)` — returns the download URL for a named asset, or null
 *
 * @returns {Promise<{tag: string, url: (name: string) => string | null} | null>}
 */
export async function getRelease() {
	const channel = /** @type {'main'|'dev'} */ (branchForInstall());
	const release = await fetchRelease(channel);
	if (!release) return null;

	return {
		tag: release.tag,
		/**
		 * Returns the browser_download_url for the given asset filename.
		 * @param {string} name
		 * @returns {string | null}
		 */
		url(name) {
			return release.assets[name] ?? null;
		}
	};
}

/**
 * Returns the raw-content URL for a file in the repo at the branch
 * matching the current channel. Used for installation scripts that are
 * served from the repository tree rather than from release assets.
 *
 * @param {string} repoPath - path relative to the repo root (e.g. "static/ergopti/linux/xkb_installation/install.sh")
 * @returns {string}
 */
export function getRawUrl(repoPath) {
	const branch = branchForInstall();
	return `https://raw.githubusercontent.com/${REPO}/${branch}/${repoPath}`;
}
