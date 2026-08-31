// _shared/ui/changelog/script.js

/**
 * ==============================================================================
 * MODULE: Changelog Window UI Script
 * DESCRIPTION:
 * Manages the release list sidebar and markdown content pane for the changelog
 * window. Fetches release data from the GitHub API via a native bridge (AHK
 * WebView2 or Hammerspoon usercontent), renders release notes as inert text, and
 * supports stable / pre-release channel switching.
 *
 * FEATURES & RATIONALE:
 * 1. Bridge-agnostic: postBridgeMessage() works on both WebView2 (Windows/AHK)
 *    and WKWebView (macOS/Hammerspoon) with automatic detection.
 * 2. Client-side fetch fallback: if the native bridge does not inject releases,
 *    the script fetches directly from the GitHub API so a browser preview works.
 * 3. Remote-content boundary: release body text never becomes active HTML.
 * ==============================================================================
 */

// Read native config immediately at module level — before any function runs —
// so _currentChannel is correct even if init() runs before DOMContentLoaded.
var _currentChannel = window.__changelog_channel === 'dev' ? 'dev' : 'main';
var _releases = [];
var _selectedIndex = -1;
var _currentReleaseUrl = null;
var _ghOwner = window.__changelog_gh_owner || 'adrienm7';
var _ghRepo = window.__changelog_gh_repo || 'ergopti';
var _bridgeSession =
	typeof window.__changelog_session === 'string' ? window.__changelog_session : '';
// Set to true once the native backend has responded for the current channel;
// prevents the client-side fallback from overwriting native data.
var _nativeResponded = false;
var _fallbackTimer = null;

// =========================================
// =========================================
// ======= 1/ Native Bridge Interface =======
// =========================================
// =========================================

var postBridgeMessage = makeHostBridge('changelog_bridge');

if (window.__ergopti_host === 'linux') {
	window.__hostBridgeResponse = function (bridge, isBase64, payload) {
		if (bridge !== 'changelog_bridge') return;
		var response = decodeHostBridgeResponse(isBase64, payload);
		if (!response || typeof response !== 'object') return;
		if (response.action === 'open_url') {
			if (!response.opened) {
				injectError(response.error || _t('changelog_window.error_network'));
			}
			return;
		}
		if (response.action !== 'releases' || response.cache_miss) return;
		injectReleases(response.releases, response.channel);
	};
}

/**
 * Posts a bridge payload bound to the Windows document session. Hosts that do
 * not publish a session token retain the historical payload shape.
 * @param {string|Object} payload
 */
function _postChangelogMessage(payload) {
	if (!_bridgeSession) {
		postBridgeMessage(payload);
		return;
	}
	var message = {};
	if (typeof payload === 'string') {
		message.action = payload;
	} else {
		Object.keys(payload).forEach(function (key) {
			message[key] = payload[key];
		});
	}
	message.session = _bridgeSession;
	postBridgeMessage(message);
}

/**
 * Called by the native backend to inject fetched release data.
 * Replaces any in-flight fetch and re-renders the release list.
 * @param {Array} releases - Array of GitHub release objects.
 * @param {string} channel - "main" or "dev".
 */
function injectReleases(releases, channel) {
	if (!Array.isArray(releases)) return;
	// Filter pre-releases on the JS side for the stable channel — avoids
	// fragile server-side JSON parsing (AHK brace-depth tracker was unreliable).
	if (channel === 'main') {
		releases = releases.filter(function (r) {
			return !r.prerelease;
		});
	}
	// Cancel the client-side fallback — native backend responded first.
	_nativeResponded = true;
	if (_fallbackTimer) {
		clearTimeout(_fallbackTimer);
		_fallbackTimer = null;
	}
	if (channel) {
		_currentChannel = channel;
		// Sync channel buttons to match what the native backend actually served.
		var btnStable = document.getElementById('btn-stable');
		var btnDev = document.getElementById('btn-dev');
		if (btnStable) btnStable.classList.toggle('active', channel === 'main');
		if (btnDev) btnDev.classList.toggle('active', channel === 'dev');
	}
	_releases = releases;
	_selectedIndex = -1;
	renderReleaseList();
	hideLoading();
	if (_releases.length > 0) {
		selectRelease(0);
	} else {
		clearContent();
	}
}

/**
 * Called by the native backend to signal a fetch error.
 * @param {string} message - Localised error message.
 */
function injectError(message) {
	showError(
		message || _t('changelog_window.error_network') || 'Impossible de charger les versions.'
	);
}

// Signal readiness so the native backend can flush queued calls.
function _initializePage() {
	var stable = document.getElementById('btn-stable');
	var dev = document.getElementById('btn-dev');
	var github = document.getElementById('btn-github');
	var retryButton = document.getElementById('btn-retry');
	if (stable)
		stable.addEventListener('click', function () {
			setChannel('main');
		});
	if (dev)
		dev.addEventListener('click', function () {
			setChannel('dev');
		});
	if (github) github.addEventListener('click', openOnGitHub);
	if (retryButton) retryButton.addEventListener('click', retry);
	_postChangelogMessage('ready');
}
if (document.readyState === 'loading')
	document.addEventListener('DOMContentLoaded', _initializePage);
else _initializePage();

// =======================================
// =======================================
// ======= 2/ i18n Helper & Config =======
// =======================================
// =======================================

function _t(key) {
	return (window._i18n_strings && window._i18n_strings[key]) || null;
}

/** Applies i18n strings to static data-i18n elements and dynamic labels. */
function applyLabels() {
	document.querySelectorAll('[data-i18n]').forEach(function (el) {
		var key = el.getAttribute('data-i18n');
		var val = _t(key);
		if (val) el.textContent = val;
	});

	var btnStable = document.getElementById('btn-stable');
	var btnDev = document.getElementById('btn-dev');
	if (btnStable) btnStable.textContent = _t('changelog_window.channel_stable') || 'Stable';
	if (btnDev) btnDev.textContent = _t('changelog_window.channel_dev') || 'Dev';

	var btnGh = document.getElementById('btn-github');
	if (btnGh) btnGh.textContent = _t('changelog_window.open_github') || 'Voir sur GitHub ↗';

	var btnRetry = document.getElementById('btn-retry');
	if (btnRetry) btnRetry.textContent = _t('changelog_window.retry') || 'Réessayer';
}

// Apply labels once i18n strings arrive (either from fetch or direct injection).
// i18n.js calls window.i18n_apply which is re-used here.
var _orig_i18n_apply = window.i18n_apply;
window.i18n_apply = function (strings) {
	if (typeof _orig_i18n_apply === 'function') _orig_i18n_apply(strings);
	applyLabels();
};
// Also apply immediately in case strings are already present.
if (window._i18n_strings) applyLabels();

// ========================================
// ========================================
// ======= 3/ Channel & Fetch Logic =======
// ========================================
// ========================================

/**
 * Switches the active channel and reloads releases.
 * @param {string} channel - "main" or "dev".
 */
function setChannel(channel) {
	if (channel === _currentChannel && _releases.length > 0) return;
	_currentChannel = channel;
	var btnStable = document.getElementById('btn-stable');
	var btnDev = document.getElementById('btn-dev');
	if (btnStable) btnStable.classList.toggle('active', channel === 'main');
	if (btnDev) btnDev.classList.toggle('active', channel === 'dev');

	// Ask the native backend to re-fetch; fall back to direct API call after 800 ms
	// only if the native backend has not responded (browser preview or no bridge).
	// Raw object, not JSON.stringify()-ed: makeHostBridge() (host_bridge.js)
	// already stringifies for WebView2 and posts the object as-is for WKWebView,
	// matching the openOnGitHub() call below and the Lua bridge's read-as-table
	// convention (action_picker / hotstring_editor / metrics_apps).
	_postChangelogMessage({ action: 'fetch', channel: channel });
	showLoading();
	_nativeResponded = false;
	_releases = [];
	_selectedIndex = -1;
	document.getElementById('release-list').replaceChildren();
	clearContent();

	// Cancel any existing fallback timer before arming a new one.
	if (_fallbackTimer) {
		clearTimeout(_fallbackTimer);
		_fallbackTimer = null;
	}
	_fallbackTimer = setTimeout(function () {
		if (!_nativeResponded) _clientFetch(channel);
	}, 800);
}

/**
 * Retries the current channel fetch after an error.
 */
function retry() {
	setChannel(_currentChannel);
}

/**
 * Direct GitHub API fetch — used as a fallback when the native backend
 * is unavailable or does not intercept the message.
 * @param {string} channel
 */
function _clientFetch(channel) {
	var url =
		channel === 'dev'
			? 'https://api.github.com/repos/' + _ghOwner + '/' + _ghRepo + '/releases?per_page=20'
			: 'https://api.github.com/repos/' + _ghOwner + '/' + _ghRepo + '/releases?per_page=20';

	fetch(url, { headers: { 'User-Agent': 'ErgoptiPlus-Changelog/1.0' } })
		.then(function (r) {
			return r.ok ? r.json() : Promise.reject(r.status);
		})
		.then(function (data) {
			if (!Array.isArray(data)) return;
			var filtered =
				channel === 'main'
					? data.filter(function (r) {
							return !r.prerelease;
						})
					: data;
			// If no stable releases exist, show all releases as a courtesy.
			if (channel === 'main' && filtered.length === 0) filtered = data;
			injectReleases(filtered, channel);
		})
		.catch(function (err) {
			injectError(
				_t('changelog_window.error_network') || 'Impossible de charger les versions. (' + err + ')'
			);
		});
}

// ========================================
// ========================================
// ======= 4/ Release List Rendering =======
// ========================================
// ========================================

/**
 * Formats an ISO date string into a short locale-aware date.
 * @param {string} iso - ISO 8601 date string.
 * @return {string}
 */
function _formatDate(iso) {
	if (!iso) return '';
	try {
		var d = new Date(iso);
		return d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
	} catch (e) {
		return iso.slice(0, 10);
	}
}

/** Rebuilds the sidebar release list from _releases. */
function renderReleaseList() {
	var list = document.getElementById('release-list');
	if (!list) return;
	list.replaceChildren();

	if (_releases.length === 0) {
		var empty = document.createElement('div');
		empty.style.cssText = 'color:#555;font-size:12px;padding:16px 14px;';
		empty.textContent = _t('changelog_window.no_releases') || 'Aucune version trouvée.';
		list.appendChild(empty);
		return;
	}

	_releases.forEach(function (release, idx) {
		var item = document.createElement('div');
		item.className = 'release-item' + (release.prerelease ? ' prerelease' : '');
		item.setAttribute('data-idx', idx);
		item.onclick = function () {
			selectRelease(idx);
		};

		var tag = document.createElement('div');
		tag.className = 'release-item-tag';
		tag.textContent = release.tag_name || '?';
		item.appendChild(tag);

		var date = document.createElement('div');
		date.className = 'release-item-date';
		date.textContent = _formatDate(release.published_at);
		item.appendChild(date);

		if (release.prerelease) {
			var badge = document.createElement('div');
			badge.className = 'release-item-badge badge-prerelease';
			badge.textContent = _t('changelog_window.badge_prerelease') || 'pre-release';
			item.appendChild(badge);
		} else if (idx === 0) {
			var badge2 = document.createElement('div');
			badge2.className = 'release-item-badge badge-latest';
			badge2.textContent = _t('changelog_window.badge_latest') || 'latest';
			item.appendChild(badge2);
		}

		list.appendChild(item);
	});
}

// =========================================
// =========================================
// ======= 5/ Content Pane Rendering =======
// =========================================
// =========================================

/** Clears the content pane and header. */
function clearContent() {
	var tagEl = document.getElementById('release-tag');
	var metaEl = document.getElementById('release-meta');
	var bodyEl = document.getElementById('release-body');
	var btnGh = document.getElementById('btn-github');
	if (tagEl) tagEl.textContent = '';
	if (metaEl) metaEl.textContent = '';
	if (bodyEl) bodyEl.replaceChildren();
	if (btnGh) btnGh.style.display = 'none';
	_currentReleaseUrl = null;
}

/**
 * Selects and displays a release by index.
 * @param {number} idx
 */
function selectRelease(idx) {
	if (idx < 0 || idx >= _releases.length) return;
	_selectedIndex = idx;

	// Update sidebar selection state.
	document.querySelectorAll('.release-item').forEach(function (el) {
		el.classList.toggle('selected', parseInt(el.getAttribute('data-idx'), 10) === idx);
	});

	var release = _releases[idx];
	_currentReleaseUrl = _isAllowedRepositoryUrl(release.html_url) ? release.html_url : null;

	// Populate header.
	var tagEl = document.getElementById('release-tag');
	var metaEl = document.getElementById('release-meta');
	var btnGh = document.getElementById('btn-github');
	if (tagEl) tagEl.textContent = release.tag_name || '';
	if (metaEl) {
		var parts = [];
		if (release.published_at) parts.push(_formatDate(release.published_at));
		metaEl.textContent = parts.join('  ·  ');
	}
	if (btnGh) {
		btnGh.style.display = _currentReleaseUrl ? 'block' : 'none';
	}

	// Render markdown body.
	var bodyEl = document.getElementById('release-body');
	if (!bodyEl) return;
	var raw = release.body || '';
	bodyEl.replaceChildren();
	if (!raw || raw.trim() === '') {
		var empty = document.createElement('p');
		empty.className = 'empty-notes';
		empty.textContent = _t('changelog_window.no_notes') || '(Aucune note de version disponible.)';
		bodyEl.appendChild(empty);
		return;
	}
	var notes = document.createElement('pre');
	notes.className = 'release-notes-plain';
	notes.textContent = raw;
	bodyEl.appendChild(notes);
}

/** Returns whether a URL belongs to this repository's HTTPS surface. */
function _isAllowedRepositoryUrl(value) {
	if (typeof value !== 'string' || value === '') return false;
	try {
		var parsed = new URL(value);
		var root = '/' + _ghOwner + '/' + _ghRepo;
		return (
			parsed.protocol === 'https:' &&
			parsed.hostname === 'github.com' &&
			parsed.username === '' &&
			parsed.password === '' &&
			parsed.port === '' &&
			(parsed.pathname === root || parsed.pathname.indexOf(root + '/') === 0)
		);
	} catch (error) {
		return false;
	}
}

/** Opens the currently selected release page on GitHub. */
function openOnGitHub() {
	var url = _currentReleaseUrl;
	if (!_isAllowedRepositoryUrl(url)) {
		// Fall back to the releases index.
		url = 'https://github.com/' + _ghOwner + '/' + _ghRepo + '/releases';
	}
	_postChangelogMessage({ action: 'open_url', url: url });
}

// ======================================
// ======================================
// ======= 6/ Loading & Error State =====
// ======================================
// ======================================

function showLoading() {
	var overlay = document.getElementById('loading-overlay');
	var errOverlay = document.getElementById('error-overlay');
	if (overlay) overlay.style.display = 'flex';
	if (errOverlay) errOverlay.style.display = 'none';
}

function hideLoading() {
	var overlay = document.getElementById('loading-overlay');
	if (overlay) overlay.style.display = 'none';
}

function showError(message) {
	hideLoading();
	var errOverlay = document.getElementById('error-overlay');
	var errText = document.getElementById('error-text');
	if (errText) errText.textContent = message;
	if (errOverlay) errOverlay.style.display = 'flex';
}

// ======================================
// ======================================
// ======= 7/ Initialisation ===========
// ======================================
// ======================================

(function init() {
	// Apply initial channel button state — _currentChannel already set at module level.
	var btnStable = document.getElementById('btn-stable');
	var btnDev = document.getElementById('btn-dev');
	if (btnStable) btnStable.classList.toggle('active', _currentChannel === 'main');
	if (btnDev) btnDev.classList.toggle('active', _currentChannel === 'dev');

	applyLabels();
	showLoading();

	// Give the native backend 800 ms to inject data; if it does not respond,
	// fall back to a direct API fetch so the UI is never stuck on a spinner.
	_nativeResponded = false;
	_fallbackTimer = setTimeout(function () {
		_fallbackTimer = null;
		if (!_nativeResponded) _clientFetch(_currentChannel);
	}, 800);
})();
