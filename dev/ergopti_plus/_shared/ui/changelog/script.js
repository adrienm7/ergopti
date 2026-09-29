// _shared/ui/changelog/script.js

/**
 * ==============================================================================
 * MODULE: Changelog Window UI Script
 * DESCRIPTION:
 * Manages the release list sidebar and markdown content pane for the changelog
 * window. Fetches release data from the GitHub API via a native bridge (AHK
 * WebView2, Hammerspoon usercontent or the Linux WebKit host), renders release
 * notes as sanitized Markdown through the shared renderer (../markdown.js), and
 * shows the releases of every update channel of the shared registry.
 *
 * FEATURES & RATIONALE:
 * 1. Bridge-agnostic: postBridgeMessage() works on WebView2 (Windows/AHK),
 *    WKWebView (macOS/Hammerspoon) and WebKitGTK (Linux).
 * 2. Native hosts own the network: they try the GitHub API, then the public
 *    releases Atom feed (./atom_feed.js converts it), honouring the system
 *    proxy. A browser preview without a host fetches the API directly.
 * 3. Bounded loading: every load arms a watchdog, so a host or network that
 *    never answers ends in a visible error with Retry and a link to the
 *    releases page instead of an endless spinner.
 * 4. Remote-content boundary: release body text never becomes active HTML; it
 *    reaches the DOM through createElement/createTextNode only, and host JSON
 *    arrives as a string that is parsed, never evaluated.
 * 5. Changelog first: CI orders a release body for github.com (downloads, then
 *    the changelog folded). The body is split into sections (./release_body.js)
 *    and shown as the changelog, expanded, then the downloads, collapsed.
 * 6. Channels from the registry: the tabs, the tag filter of each view and the
 *    ids the hosts accept come from the shared update-channel registry
 *    (../_generated/update_channel_registry.js, read by ../update_channels.js).
 *    A tab only changes what is shown; the window opens on the channel the user
 *    subscribed to, and a banner offers to subscribe to the one on screen. The
 *    host owns the subscription and answers with setSubscribedChannel().
 * ==============================================================================
 */

// Read native config immediately at module level — before any function runs —
// so the channels are correct even if init() runs before DOMContentLoaded.
var _channels = createUpdateChannels(window.UPDATE_CHANNEL_REGISTRY);
// The channel the user receives updates from, as the host reports it (null
// until a host says: a browser preview has no subscription).
var _subscribedChannel = _channels.resolve(window.__subscribed_channel);
// The channel whose releases are on screen: the subscribed one when the window
// opens, then whichever tab the user picks.
var _currentChannel =
	_channels.resolve(window.__changelog_channel) || _subscribedChannel || _channels.ids[0];
// Hosts whose channel change restarts the app ask the user to confirm first.
var _switchRestarts = window.__channel_switch_restarts === true;
// Banner state: 'idle', 'confirming' (restart question shown), 'pending'
// (request posted, waiting for the host) or 'failed' (the host refused).
var _subscribeState = 'idle';
var _releases = [];
var _selectedIndex = -1;
var _currentReleaseUrl = null;
var _ghOwner = window.__changelog_gh_owner || 'adrienm7';
var _ghRepo = window.__changelog_gh_repo || 'ergopti';
var _bridgeSession =
	typeof window.__changelog_session === 'string' ? window.__changelog_session : '';
// Upper bound for one load, from request to data or error. Mirrors
// release_sources.ui_watchdog_sec in _shared/modules/updater/defaults.json and
// exceeds the hosts' proxy-resolution plus API plus feed budgets (pinned by
// tools/test/test-changelog-network-resilience.cjs).
var CHANGELOG_WATCHDOG_MS = 45000;
// Per-request budget of the browser-preview fetch. Mirrors
// release_sources.source_timeout_sec in the same defaults file.
var CLIENT_FETCH_TIMEOUT_MS = 15000;
// Identifies the active load; a late timer or fetch of a superseded load is
// ignored instead of overwriting the current state.
var _loadToken = 0;
var _watchdogTimer = null;
var _hasNativeHost = _detectNativeHost();

/**
 * Reports whether a native host owns this page's network access.
 * @return {boolean}
 */
function _detectNativeHost() {
	if (window.__ergopti_host === 'linux') return true;
	if (
		window.chrome &&
		window.chrome.webview &&
		typeof window.chrome.webview.postMessage === 'function'
	) {
		return true;
	}
	return !!(
		window.webkit &&
		window.webkit.messageHandlers &&
		window.webkit.messageHandlers.changelog_bridge
	);
}

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
		if (response.action === 'releases_error') {
			// Only changelog keys are looked up; anything else shows the network error.
			var key = /^changelog_window\.error_[a-z_]+$/.test(response.error_key || '')
				? response.error_key
				: 'changelog_window.error_network';
			injectError(_t(key));
			return;
		}
		if (response.action === 'channel_changed') {
			setSubscribedChannel(response.channel, response.ok !== false);
			return;
		}
		// Release answers also say which channel the user receives updates from;
		// they leave a pending subscription request to its own answer.
		if (typeof response.subscribed_channel === 'string') {
			_adoptSubscription(response.subscribed_channel);
			_renderSubscribeBanner();
		}
		if (response.action !== 'releases') return;
		if (response.cache_miss) {
			// The Linux host seeds nothing before the page runs: its answer to
			// "ready" names the channel it is loading, whose tab is shown meanwhile.
			var loading = _channels.resolve(response.channel);
			if (loading && loading !== _currentChannel) {
				_currentChannel = loading;
				_renderChannelTabs();
				_renderSubscribeBanner();
			}
			return;
		}
		if (typeof response.feed === 'string') injectReleasesFeed(response.feed, response.channel);
		else if (typeof response.json === 'string') injectReleasesJson(response.json, response.channel);
		else injectReleases(response.releases, response.channel);
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
 * @param {string} channel - Registry channel the list is shown for.
 */
function injectReleases(releases, channel) {
	if (!Array.isArray(releases)) {
		injectError(_t('changelog_window.error_parse'));
		return;
	}
	var shown = channel === undefined ? _currentChannel : _channels.resolve(channel);
	if (!shown) {
		injectError(_t('changelog_window.error_parse'));
		return;
	}
	// Remote records are data of unknown shape; only objects are listed, and a
	// channel's view lists its own tags and those of every more stable channel
	// (decided by the tag family, never by GitHub's prerelease flag).
	releases = releases.filter(function (r) {
		return r !== null && typeof r === 'object' && _channels.visibleIn(shown, r.tag_name);
	});
	_endLoad();
	hideError();
	_currentChannel = shown;
	_renderChannelTabs();
	_renderSubscribeBanner();
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
	_endLoad();
	showError(
		message || _t('changelog_window.error_network') || 'Impossible de charger les versions.'
	);
}

/**
 * Called by a native host with the GitHub API response text. The text is
 * parsed as data (never evaluated as script) and must be a release array.
 * @param {string} text - Raw API response body.
 * @param {string} channel - Registry channel the list is shown for.
 */
function injectReleasesJson(text, channel) {
	var releases;
	try {
		releases = JSON.parse(text);
	} catch (error) {
		releases = null;
	}
	if (!Array.isArray(releases)) {
		injectError(_t('changelog_window.error_parse'));
		return;
	}
	injectReleases(releases, channel);
}

/**
 * Called by a native host with the releases Atom feed text, the alternate
 * source used when the GitHub API is unreachable.
 * @param {string} xml - Raw feed document.
 * @param {string} channel - Registry channel the list is shown for.
 */
function injectReleasesFeed(xml, channel) {
	var releases;
	try {
		releases = parseReleasesAtom(xml, _ghOwner, _ghRepo);
	} catch (error) {
		injectError(_t('changelog_window.error_parse'));
		return;
	}
	// The feed carries no pre-release flag: the registry states which channels
	// GitHub marks as pre-releases.
	releases.forEach(function (release) {
		var owner = _channels.channelForTag(release.tag_name);
		release.prerelease = owner !== null && _channels.channel(owner).githubPrerelease;
	});
	injectReleases(releases, channel);
}

// Signal readiness so the native backend can flush queued calls.
function _initializePage() {
	var github = document.getElementById('btn-github');
	var retryButton = document.getElementById('btn-retry');
	var releasesPage = document.getElementById('btn-releases-page');
	var subscribe = document.getElementById('btn-subscribe');
	var confirm = document.getElementById('btn-subscribe-confirm');
	var cancel = document.getElementById('btn-subscribe-cancel');
	if (subscribe) subscribe.addEventListener('click', requestSubscription);
	if (confirm) confirm.addEventListener('click', confirmSubscription);
	if (cancel) cancel.addEventListener('click', cancelSubscription);
	if (github) github.addEventListener('click', openOnGitHub);
	if (retryButton) retryButton.addEventListener('click', retry);
	if (releasesPage) releasesPage.addEventListener('click', openReleasesPage);
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

	_renderChannelTabs();
	_renderSubscribeBanner();

	var btnGh = document.getElementById('btn-github');
	if (btnGh) btnGh.textContent = _t('changelog_window.open_github') || 'Voir sur GitHub ↗';

	var btnRetry = document.getElementById('btn-retry');
	if (btnRetry) btnRetry.textContent = _t('changelog_window.retry') || 'Réessayer';

	var btnPage = document.getElementById('btn-releases-page');
	var pageLabel = _t('changelog_window.open_releases_page');
	if (btnPage && pageLabel) btnPage.textContent = pageLabel;
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
 * Shows another channel's releases. A tab changes only what is on screen,
 * never the channel the user receives updates from (see requestSubscription).
 * @param {string} channel - Registry channel id.
 */
function setChannel(channel) {
	var shown = _channels.resolve(channel);
	if (!shown) return;
	if (shown === _currentChannel && _releases.length > 0) return;
	_requestReleases(shown);
}

/** Formats a template's {channel} placeholder with a channel's short label. */
function _withChannel(key, channel) {
	var record = _channels.channel(channel);
	var label = record ? _t(record.labelKey) || '' : '';
	return (_t(key) || '').split('{channel}').join(label);
}

/** Draws one tab per registry channel, in stability order, the shown one active. */
function _renderChannelTabs() {
	var toggle = document.getElementById('channel-toggle');
	if (!toggle) return;
	toggle.replaceChildren();
	_channels.ids.forEach(function (id) {
		var tab = document.createElement('button');
		tab.className = 'channel-btn' + (id === _currentChannel ? ' active' : '');
		tab.setAttribute('data-channel', id);
		tab.textContent = _t(_channels.channel(id).labelKey) || '';
		tab.onclick = function () {
			setChannel(id);
		};
		toggle.appendChild(tab);
	});
}

/**
 * Shows the subscription banner while the page shows a channel the user does
 * not receive updates from, in the state of the last subscription request.
 */
function _renderSubscribeBanner() {
	var banner = document.getElementById('subscribe-banner');
	if (!banner) return;
	var differs = _subscribedChannel !== null && _currentChannel !== _subscribedChannel;
	banner.style.display = differs || _subscribeState === 'failed' ? 'flex' : 'none';
	var text = document.getElementById('subscribe-text');
	if (text) {
		text.textContent =
			_subscribeState === 'failed'
				? _t('changelog_window.subscribe_failed') || ''
				: _withChannel('changelog_window.subscribed_to', _subscribedChannel);
	}
	var button = document.getElementById('btn-subscribe');
	if (button) {
		button.textContent = _withChannel('changelog_window.subscribe', _currentChannel);
		button.disabled = _subscribeState === 'pending';
		button.style.display = differs && _subscribeState !== 'confirming' ? '' : 'none';
	}
	var confirmRow = document.getElementById('subscribe-confirm');
	if (confirmRow) confirmRow.style.display = _subscribeState === 'confirming' ? 'flex' : 'none';
	var question = document.getElementById('subscribe-confirm-text');
	if (question)
		question.textContent = _withChannel('changelog_window.subscribe_restart', _currentChannel);
	var confirmButton = document.getElementById('btn-subscribe-confirm');
	if (confirmButton) confirmButton.textContent = _t('button.confirm') || '';
	var cancelButton = document.getElementById('btn-subscribe-cancel');
	if (cancelButton) cancelButton.textContent = _t('button.cancel') || '';
}

/**
 * Asks to receive updates from the channel on screen. A host whose channel
 * change restarts the app first asks the user to confirm.
 */
function requestSubscription() {
	if (_subscribedChannel === null || _currentChannel === _subscribedChannel) return;
	if (_subscribeState === 'pending') return;
	if (_switchRestarts && _subscribeState !== 'confirming') {
		_subscribeState = 'confirming';
		_renderSubscribeBanner();
		return;
	}
	_subscribeState = 'pending';
	_renderSubscribeBanner();
	_postChangelogMessage({ action: 'set_channel', channel: _currentChannel });
}

/** Confirms the restart the host announced, then asks for the subscription. */
function confirmSubscription() {
	if (_subscribeState !== 'confirming') return;
	_subscribeState = 'pending';
	_renderSubscribeBanner();
	_postChangelogMessage({ action: 'set_channel', channel: _currentChannel });
}

/** Withdraws the pending restart question. */
function cancelSubscription() {
	if (_subscribeState !== 'confirming') return;
	_subscribeState = 'idle';
	_renderSubscribeBanner();
}

/**
 * Called by a native host with the channel the user receives updates from:
 * when the page opens, after a set_channel request (ok false when the host
 * refused it) and when the menu changed it while the page is open.
 * @param {string} channel - Registry channel id.
 * @param {boolean} ok - False when a subscription request failed.
 */
function setSubscribedChannel(channel, ok) {
	_adoptSubscription(channel);
	_subscribeState = ok === false ? 'failed' : 'idle';
	_renderSubscribeBanner();
}

/** Records the host's subscribed channel; an id outside the registry is ignored. */
function _adoptSubscription(channel) {
	var subscribed = _channels.resolve(channel);
	if (subscribed) _subscribedChannel = subscribed;
}

/**
 * Starts one bounded load of a channel, replacing any load in flight.
 * @param {string} channel - Registry channel id.
 */
function _requestReleases(channel) {
	_currentChannel = channel;
	if (_subscribeState !== 'pending') _subscribeState = 'idle';
	_renderChannelTabs();
	_renderSubscribeBanner();

	_releases = [];
	_selectedIndex = -1;
	var list = document.getElementById('release-list');
	if (list) list.replaceChildren();
	clearContent();
	var token = _beginLoad();

	// Raw object, not JSON.stringify()-ed: makeHostBridge() (host_bridge.js)
	// already stringifies for WebView2 and posts the object as-is for WKWebView,
	// matching the openOnGitHub() call below and the Lua bridge's read-as-table
	// convention (action_picker / hotstring_editor / metrics_apps).
	if (_hasNativeHost) _postChangelogMessage({ action: 'fetch', channel: channel });
	else _clientFetch(channel, token);
}

/**
 * Retries the current channel after an error, even when a previous load had
 * already listed releases.
 */
function retry() {
	_requestReleases(_currentChannel);
}

/**
 * Starts the watchdog of a new load and shows the spinner.
 * @return {number} Token identifying the load.
 */
function _beginLoad() {
	_loadToken += 1;
	var token = _loadToken;
	if (_watchdogTimer) clearTimeout(_watchdogTimer);
	showLoading();
	_watchdogTimer = setTimeout(function () {
		if (token !== _loadToken) return;
		_watchdogTimer = null;
		showError(_t('changelog_window.error_timeout') || _t('changelog_window.error_network') || '');
	}, CHANGELOG_WATCHDOG_MS);
	return token;
}

/** Disarms the watchdog once the active load has produced data or an error. */
function _endLoad() {
	if (_watchdogTimer) {
		clearTimeout(_watchdogTimer);
		_watchdogTimer = null;
	}
}

/**
 * Direct GitHub API fetch for a browser preview, where no native host owns the
 * network. Bounded by CLIENT_FETCH_TIMEOUT_MS.
 * @param {string} channel
 * @param {number} token - Load that owns this request.
 */
function _clientFetch(channel, token) {
	var url = 'https://api.github.com/repos/' + _ghOwner + '/' + _ghRepo + '/releases?per_page=20';
	if (typeof fetch !== 'function') {
		injectError(_t('changelog_window.error_network'));
		return;
	}
	var controller = typeof AbortController === 'function' ? new AbortController() : null;
	var timer = setTimeout(function () {
		if (controller) controller.abort();
	}, CLIENT_FETCH_TIMEOUT_MS);

	fetch(url, controller ? { signal: controller.signal } : {})
		.then(function (r) {
			return r.ok ? r.json() : Promise.reject({ status: r.status });
		})
		.then(function (data) {
			clearTimeout(timer);
			if (token !== _loadToken) return;
			if (!Array.isArray(data)) {
				injectError(_t('changelog_window.error_parse'));
				return;
			}
			injectReleases(data, channel);
		})
		.catch(function (err) {
			clearTimeout(timer);
			if (token !== _loadToken) return;
			var status = err && typeof err.status === 'number' ? err.status : 0;
			var key =
				status === 403 || status === 429
					? 'changelog_window.error_rate_limited'
					: 'changelog_window.error_network';
			injectError(_t(key));
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
		bodyEl.appendChild(_emptyNotes());
		return;
	}
	// Remote Markdown becomes DOM nodes only (never parsed HTML). Links stay
	// href-less; a click reaches the native open_url action, and only for URLs
	// on this repository's HTTPS surface — the same allowlist the hosts enforce.
	var markdownOptions = {
		allow: _isAllowedRepositoryUrl,
		open: function (url) {
			_postChangelogMessage({ action: 'open_url', url: url });
		}
	};
	// CI orders the body for github.com (downloads first, changelog folded);
	// the sections are read before rendering, which strips their markers.
	var parts = splitReleaseBody(raw);
	if (parts.format === 'unknown') {
		renderMarkdownInto(bodyEl, raw, markdownOptions);
		return;
	}
	_renderReleaseSections(bodyEl, parts, markdownOptions);
}

/**
 * Renders a split release body: the changelog first and expanded, then the
 * downloads (with the intro lines that present them) folded, then the footer.
 * @param {Element} bodyEl - Content pane.
 * @param {Object} parts - splitReleaseBody() result.
 * @param {Object} markdownOptions - Link policy for renderMarkdownInto().
 */
function _renderReleaseSections(bodyEl, parts, markdownOptions) {
	var changelog = _makeReleaseSection(
		'release-section-changelog',
		'changelog_window.section_changelog',
		true
	);
	if (parts.changelog !== '') renderMarkdownInto(changelog.body, parts.changelog, markdownOptions);
	else changelog.body.appendChild(_emptyNotes());
	bodyEl.appendChild(changelog.details);

	var downloadsSource = [parts.intro, parts.downloads]
		.filter(function (source) {
			return source !== '';
		})
		.join('\n\n');
	if (downloadsSource !== '') {
		var downloads = _makeReleaseSection(
			'release-section-downloads',
			'changelog_window.section_downloads',
			false
		);
		renderMarkdownInto(downloads.body, downloadsSource, markdownOptions);
		bodyEl.appendChild(downloads.details);
	}

	if (parts.footer !== '') {
		var footer = document.createElement('div');
		footer.className = 'release-footer';
		renderMarkdownInto(footer, parts.footer, markdownOptions);
		bodyEl.appendChild(footer);
	}
}

/**
 * Builds one collapsible page section titled by a locale key. The key is also
 * set as data-i18n, so a late locale load relabels it through applyLabels().
 * @return {{details: Element, body: Element}}
 */
function _makeReleaseSection(className, titleKey, open) {
	var details = document.createElement('details');
	details.className = 'release-section ' + className;
	if (open) details.setAttribute('open', '');
	var summary = document.createElement('summary');
	summary.className = 'release-section-title';
	summary.setAttribute('data-i18n', titleKey);
	summary.textContent = _t(titleKey) || '';
	details.appendChild(summary);
	var body = document.createElement('div');
	body.className = 'release-section-body';
	details.appendChild(body);
	return { details: details, body: body };
}

/** Builds the "no release notes" paragraph. */
function _emptyNotes() {
	var empty = document.createElement('p');
	empty.className = 'empty-notes';
	empty.setAttribute('data-i18n', 'changelog_window.no_notes');
	empty.textContent = _t('changelog_window.no_notes') || '';
	return empty;
}

/** Returns whether a URL belongs to this repository's HTTPS surface. */
function _isAllowedRepositoryUrl(value) {
	return isRepositoryUrl(value, _ghOwner, _ghRepo);
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

/** Opens the repository releases index, the manual route when loading fails. */
function openReleasesPage() {
	_postChangelogMessage({
		action: 'open_url',
		url: 'https://github.com/' + _ghOwner + '/' + _ghRepo + '/releases'
	});
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

function hideError() {
	var errOverlay = document.getElementById('error-overlay');
	if (errOverlay) errOverlay.style.display = 'none';
}

// ======================================
// ======================================
// ======= 7/ Initialisation ===========
// ======================================
// ======================================

(function init() {
	// Draws the registry tabs and the banner; _currentChannel is set at module level.
	applyLabels();

	// A native host starts the first fetch itself once the page is ready; the
	// watchdog bounds that wait. A browser preview fetches directly.
	var token = _beginLoad();
	if (!_hasNativeHost) {
		setTimeout(function () {
			if (token === _loadToken) _clientFetch(_currentChannel, token);
		}, 0);
	}
})();
