// tools/test/test-changelog-channel-sync.cjs

/**
 * ==============================================================================
 * MODULE: Versions Page Channel Sync Test
 * DESCRIPTION:
 * Runs the shared Versions page (_shared/ui/changelog/) against a recording DOM
 * and checks how it tells viewing a channel apart from subscribing to it.
 *
 * ROOT CAUSE ENCODED:
 * The page had two hardcoded tabs ("main" and "dev") that decided both what was
 * listed and, on some hosts, which channel the updater followed, while the menu
 * kept its own copy of the choice. The window could open on a channel the user
 * did not receive, and the menu and the page could disagree.
 *
 * FEATURES & RATIONALE:
 * 1. The tabs are the registry's channels, in stability order, and the window
 *    opens on the subscribed channel.
 * 2. A tab only asks the host for that channel's releases; subscribing is the
 *    banner's explicit request (set_channel), confirmed first on a host whose
 *    channel change restarts the app.
 * 3. The host's answer (setSubscribedChannel, or channel_changed on Linux)
 *    settles the banner, including a refusal and a change made from the menu.
 * 4. Each view lists the registry's visible tags for that channel.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { byTag, runPage } = require('./support/changelog-page-dom.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const EN = JSON.parse(fs.readFileSync(path.join(SHARED, 'data', 'locales', 'en.json'), 'utf8'));
const REGISTRY = JSON.parse(
	fs.readFileSync(path.join(SHARED, 'modules', 'updater', 'channels.json'), 'utf8')
);
const IDS = REGISTRY.channels.map((channel) => channel.id);
const MOST_STABLE = IDS[0];
const LEAST_STABLE = IDS[IDS.length - 1];

const failures = [];
let checks = 0;

function expect(condition, message) {
	checks += 1;
	if (!condition) failures.push(message);
}

// ==========================================
// ==========================================
// ======= 1/ Page Harness =================
// ==========================================
// ==========================================

/** Label of a channel as the page shows it. */
function label(id) {
	return EN[REGISTRY.channels.find((channel) => channel.id === id).label_key];
}

/** Replaces {channel} in an English template with a channel's label. */
function withChannel(key, id) {
	return EN[key].split('{channel}').join(label(id));
}

/**
 * Opens the page as a Linux-hosted window (bridge messages are recorded and
 * host answers arrive through __hostBridgeResponse).
 * @param {Object} globals - Host seeds (subscription, restart flag).
 */
function openPage(globals) {
	const page = runPage({ _i18n_strings: EN, __ergopti_host: 'linux', ...globals });
	const el = (id) => page.document.getElementById(id);
	return {
		...page,
		el,
		tabs: () => el('channel-toggle').children,
		activeTab: () =>
			el('channel-toggle').children.find((tab) => tab.className.split(' ').includes('active')),
		shown: (id) => el(id).style.display !== 'none',
		payloads: (action) =>
			page.posted.map((message) => message.payload).filter((p) => p && p.action === action),
		answer: (response) =>
			page.sandbox.__hostBridgeResponse('changelog_bridge', false, JSON.stringify(response)),
		clickTab: (id) =>
			el('channel-toggle')
				.children.find((tab) => tab.getAttribute('data-channel') === id)
				.onclick()
	};
}

// ==========================================
// ==========================================
// ======= 2/ Tabs and Opening Channel =====
// ==========================================
// ==========================================

function checkTabsFollowTheRegistry() {
	expect(IDS.length >= 2, 'the registry must declare at least two channels for these checks');
	const page = openPage({ __subscribed_channel: LEAST_STABLE });
	const tabs = page.tabs();
	expect(
		JSON.stringify(tabs.map((tab) => tab.getAttribute('data-channel'))) === JSON.stringify(IDS),
		'the tabs must be the registry channels, in stability order'
	);
	expect(
		tabs.every((tab) => tab.textContent === label(tab.getAttribute('data-channel'))),
		'each tab must read its channel label from the locale'
	);
	expect(
		page.activeTab() && page.activeTab().getAttribute('data-channel') === LEAST_STABLE,
		'the window must open on the subscribed channel'
	);
	expect(!page.shown('subscribe-banner'), 'no banner while the subscribed channel is on screen');
}

function checkLinuxOpensOnTheChannelItLoads() {
	// The Linux host is not seeded before the page runs: its answer to "ready"
	// names the channel it started loading (the subscribed one).
	const page = openPage({});
	page.answer({
		action: 'releases',
		channel: LEAST_STABLE,
		subscribed_channel: LEAST_STABLE,
		releases: [],
		cache_miss: true
	});
	expect(
		page.activeTab() && page.activeTab().getAttribute('data-channel') === LEAST_STABLE,
		'the tab of the channel the Linux host is loading must be active while it loads'
	);
	expect(!page.shown('subscribe-banner'), 'no banner while the subscribed channel loads');
	page.answer({ action: 'releases', channel: 'beta', releases: [], cache_miss: true });
	expect(
		page.activeTab() && page.activeTab().getAttribute('data-channel') === LEAST_STABLE,
		'a loading answer for a channel outside the registry must not move the tabs'
	);
}

function checkPreviewHasNoSubscription() {
	const page = openPage({});
	expect(
		page.activeTab() && page.activeTab().getAttribute('data-channel') === MOST_STABLE,
		'without a host subscription the page opens on the most stable channel'
	);
	page.clickTab(LEAST_STABLE);
	expect(!page.shown('subscribe-banner'), 'a page without a subscription must not offer one');
}

// ==========================================
// ==========================================
// ======= 3/ Viewing Versus Subscribing ===
// ==========================================
// ==========================================

function checkTabOnlyChangesTheView() {
	const page = openPage({ __subscribed_channel: LEAST_STABLE });
	page.clickTab(MOST_STABLE);
	const fetches = page.payloads('fetch');
	expect(
		fetches.length === 1 && fetches[0].channel === MOST_STABLE,
		'a tab must ask the host for that channel releases once'
	);
	expect(page.payloads('set_channel').length === 0, 'a tab must never change the subscription');
	expect(
		page.shown('subscribe-banner'),
		'the banner must appear on a channel the user does not receive'
	);
	expect(
		page.el('subscribe-text').textContent ===
			withChannel('changelog_window.subscribed_to', LEAST_STABLE),
		'the banner must name the channel the user receives'
	);
	expect(
		page.el('btn-subscribe').textContent === withChannel('changelog_window.subscribe', MOST_STABLE),
		'the banner button must offer the channel on screen'
	);
}

function checkBannerSubscribesThroughTheHost() {
	const page = openPage({ __subscribed_channel: LEAST_STABLE });
	page.clickTab(MOST_STABLE);
	page.el('btn-subscribe').dispatch('click');
	const requests = page.payloads('set_channel');
	expect(
		requests.length === 1 && requests[0].channel === MOST_STABLE,
		'the banner must ask the host to subscribe to the channel on screen'
	);
	expect(page.el('btn-subscribe').disabled === true, 'the button must wait for the host answer');
	page.el('btn-subscribe').dispatch('click');
	expect(page.payloads('set_channel').length === 1, 'a pending request must not be posted twice');

	page.answer({ action: 'channel_changed', channel: MOST_STABLE, ok: true });
	expect(!page.shown('subscribe-banner'), 'an accepted subscription must hide the banner');
	expect(
		page.activeTab().getAttribute('data-channel') === MOST_STABLE,
		'the host answer must not move the view'
	);
}

function checkRefusalIsShown() {
	const page = openPage({ __subscribed_channel: LEAST_STABLE });
	page.clickTab(MOST_STABLE);
	page.el('btn-subscribe').dispatch('click');
	page.answer({ action: 'channel_changed', channel: LEAST_STABLE, ok: false });
	expect(page.shown('subscribe-banner'), 'a refused subscription must stay visible');
	expect(
		page.el('subscribe-text').textContent === EN['changelog_window.subscribe_failed'],
		'a refused subscription must say so'
	);
	expect(page.el('btn-subscribe').disabled === false, 'the user must be able to try again');
}

function checkRestartIsConfirmedFirst() {
	const page = openPage({ __subscribed_channel: LEAST_STABLE, __channel_switch_restarts: true });
	page.clickTab(MOST_STABLE);
	page.el('btn-subscribe').dispatch('click');
	expect(
		page.payloads('set_channel').length === 0,
		'a restarting host must not be asked before confirmation'
	);
	expect(page.shown('subscribe-confirm'), 'the restart question must be shown');
	expect(
		page.el('subscribe-confirm-text').textContent ===
			withChannel('changelog_window.subscribe_restart', MOST_STABLE),
		'the question must name the channel and the restart'
	);
	page.el('btn-subscribe-cancel').dispatch('click');
	expect(!page.shown('subscribe-confirm'), 'cancel must withdraw the question');
	expect(page.payloads('set_channel').length === 0, 'cancel must not subscribe');

	page.el('btn-subscribe').dispatch('click');
	page.el('btn-subscribe-confirm').dispatch('click');
	const requests = page.payloads('set_channel');
	expect(
		requests.length === 1 && requests[0].channel === MOST_STABLE,
		'confirming must ask the host to subscribe'
	);
}

function checkMenuChangesReachTheOpenPage() {
	const page = openPage({ __subscribed_channel: LEAST_STABLE });
	page.clickTab(MOST_STABLE);
	expect(page.shown('subscribe-banner'), 'precondition: the banner offers the channel on screen');
	page.sandbox.setSubscribedChannel(MOST_STABLE, true);
	expect(!page.shown('subscribe-banner'), 'a change made from the menu must update the open page');

	const linux = openPage({});
	linux.answer({
		action: 'releases',
		channel: LEAST_STABLE,
		subscribed_channel: LEAST_STABLE,
		releases: []
	});
	linux.clickTab(MOST_STABLE);
	expect(linux.shown('subscribe-banner'), 'the Linux first answer must carry the subscription');
}

// ==========================================
// ==========================================
// ======= 4/ Listed Releases ==============
// ==========================================
// ==========================================

function listedTags(page) {
	return byTag(page.el('release-list'), 'div')
		.filter((node) => node.className === 'release-item-tag')
		.map((node) => node.textContent);
}

function checkViewsListTheirChannelTags() {
	const releases = [
		{ tag_name: 'v0.0.0-dev.12', body: 'dev', prerelease: true },
		{ tag_name: 'v1.4.0', body: 'stable', prerelease: false },
		{ tag_name: 'v2.0.0-rc.1', body: 'foreign family', prerelease: true }
	];
	const page = openPage({ __subscribed_channel: MOST_STABLE });
	page.sandbox.injectReleases(releases, MOST_STABLE);
	expect(
		JSON.stringify(listedTags(page)) === JSON.stringify(['v1.4.0']),
		`the ${MOST_STABLE} view must list only its own tags (got ${JSON.stringify(listedTags(page))})`
	);
	page.sandbox.injectReleases(releases, LEAST_STABLE);
	expect(
		JSON.stringify(listedTags(page)) === JSON.stringify(['v0.0.0-dev.12', 'v1.4.0']),
		`the ${LEAST_STABLE} view must list its tags and the more stable ones (got ${JSON.stringify(listedTags(page))})`
	);
	page.sandbox.injectReleases(releases, 'beta');
	expect(
		page.el('error-overlay').style.display === 'flex',
		'a list for an unknown channel must be refused'
	);
}

// ==========================================
// ==========================================
// ======= 5/ Report =======================
// ==========================================
// ==========================================

checkTabsFollowTheRegistry();
checkLinuxOpensOnTheChannelItLoads();
checkPreviewHasNoSubscription();
checkTabOnlyChangesTheView();
checkBannerSubscribesThroughTheHost();
checkRefusalIsShown();
checkRestartIsConfirmedFirst();
checkMenuChangesReachTheOpenPage();
checkViewsListTheirChannelTags();

if (failures.length > 0) {
	console.error(`\x1b[31m[FAIL] Versions page channel sync (${failures.length}/${checks}):\x1b[0m`);
	for (const failure of failures) console.error('  - ' + failure);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] Versions page views and subscriptions follow the registry and the host (${checks} checks).\x1b[0m`
);
