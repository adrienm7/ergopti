// tools/test/test-changelog-release-install.cjs

/**
 * ==============================================================================
 * MODULE: Versions Page One-Click Install Test
 * DESCRIPTION:
 * Runs the shared Versions page (_shared/ui/changelog/) against a recording DOM
 * with a fixture release list and checks the one-click install of a chosen
 * release and the restore of the configuration backup it made.
 *
 * ROOT CAUSE ENCODED:
 * The page listed every release with « View on GitHub » and nothing else:
 * going back to a release meant finding its asset on GitHub, installing it by
 * hand and hoping the configuration survived.
 *
 * FEATURES & RATIONALE:
 * 1. Every release but the installed one carries the install button, labelled
 *    « Go back to this version » when it is older than the installed build by
 *    the shared semver order; the installed row is marked and has none.
 * 2. One click posts exactly install_release with the tag and the channel on
 *    screen, and nothing else is asked; the button waits for the host.
 * 3. A failure stays in the window with its translated reason, the backup it
 *    kept and a Retry button that posts the same request again. A reason key
 *    outside the install family is not shown.
 * 4. A host that cannot install (a source run) greys every button with its
 *    reason; a host that announced no build shows none.
 * 5. The restore banner names the backup and posts restore_backup with its id.
 * 6. Feed-only list (the API gave none): a host whose updater verifies on its
 *    own (macOS, Sparkle) offers the channel's newest release only, through
 *    install_through_updater and the handed_off phase; older rows, hosts
 *    without that updater and API lists keep the direct request.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { runPage } = require('./support/changelog-page-dom.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const EN = JSON.parse(fs.readFileSync(path.join(SHARED, 'data', 'locales', 'en.json'), 'utf8'));
const REGISTRY = JSON.parse(
	fs.readFileSync(path.join(SHARED, 'modules', 'updater', 'channels.json'), 'utf8')
);
const LEAST_STABLE = REGISTRY.channels[REGISTRY.channels.length - 1].id;

// The dev view lists every dev build and the stable releases, newest first.
const RELEASES = [
	{ tag_name: 'v0.0.0-dev.142', published_at: '2026-09-30T10:00:00Z', prerelease: true },
	{ tag_name: 'v0.0.0-dev.141', published_at: '2026-09-29T10:00:00Z', prerelease: true },
	{ tag_name: 'v0.0.0-dev.140', published_at: '2026-09-28T10:00:00Z', prerelease: true },
	{ tag_name: 'v0.0.0-dev.139', published_at: '2026-09-27T10:00:00Z', prerelease: true }
].map((release) => ({
	...release,
	body: 'Notes',
	html_url: `https://github.com/adrienm7/ergopti/releases/tag/${release.tag_name}`
}));
const INSTALLED = '0.0.0-dev.140';

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

/** Replaces every {name} placeholder of an English template. */
function fill(key, values) {
	return Object.keys(values).reduce(
		(text, name) => text.split(`{${name}}`).join(values[name]),
		EN[key]
	);
}

/**
 * Opens the page on the least stable channel with host seeds, then lists the
 * fixture releases.
 * @param {Object} globals - Host seeds.
 */
function openPage(globals) {
	const page = runPage({
		_i18n_strings: EN,
		__ergopti_host: 'linux',
		__subscribed_channel: LEAST_STABLE,
		...globals
	});
	page.sandbox.injectReleases(RELEASES, LEAST_STABLE);
	const el = (id) => page.document.getElementById(id);
	return {
		...page,
		el,
		shown: (id) => el(id).style.display !== 'none',
		select: (tag) => page.sandbox.selectRelease(RELEASES.findIndex((r) => r.tag_name === tag)),
		row: (tag) =>
			el('release-list').children.find(
				(item) => item.children[0] && item.children[0].textContent === tag
			),
		payloads: (action) =>
			page.posted.map((message) => message.payload).filter((p) => p && p.action === action),
		answer: (response) =>
			page.sandbox.__hostBridgeResponse('changelog_bridge', false, JSON.stringify(response))
	};
}

// ==========================================
// ==========================================
// ======= 2/ Buttons Per Release ===========
// ==========================================
// ==========================================

function checkEveryOtherReleaseCarriesTheButton() {
	const page = openPage({ __installed_version: INSTALLED });
	for (const release of RELEASES) {
		page.select(release.tag_name);
		const installed = release.tag_name === `v${INSTALLED}`;
		expect(
			page.shown('btn-install') === !installed,
			`${release.tag_name}: the install button must be ${installed ? 'absent' : 'shown'}`
		);
		expect(page.shown('btn-github'), `${release.tag_name}: « View on GitHub » stays beside it`);
		if (installed) {
			expect(
				page.shown('install-note') &&
					page.el('install-note').textContent === EN['changelog_window.installed_note'],
				'the installed release must say it is the installed one'
			);
			continue;
		}
		const older = release.tag_name === 'v0.0.0-dev.139';
		expect(
			page.el('btn-install').textContent ===
				EN[older ? 'changelog_window.rollback_release' : 'changelog_window.install_release'],
			`${release.tag_name}: the button must read « ${older ? 'Go back to' : 'Install'} this version »`
		);
		expect(page.el('btn-install').disabled === false, `${release.tag_name}: the button is usable`);
	}
	const marked = page.row('v0.0.0-dev.140');
	expect(
		marked && marked.className.split(' ').includes('installed'),
		'the installed release row must be marked'
	);
	expect(
		marked &&
			marked.children.some((child) => child.textContent === EN['changelog_window.badge_installed']),
		'the installed release row must carry the installed badge'
	);
	expect(
		!page.row('v0.0.0-dev.141').className.split(' ').includes('installed'),
		'no other row is marked installed'
	);
}

function checkOneClickPostsTheRequest() {
	const page = openPage({ __installed_version: INSTALLED });
	page.select('v0.0.0-dev.139');
	expect(
		page.posted.length === 0 || page.payloads('install_release').length === 0,
		'nothing is posted before the click'
	);
	page.el('btn-install').dispatch('click');
	const requests = page.payloads('install_release');
	expect(
		requests.length === 1 &&
			requests[0].tag === 'v0.0.0-dev.139' &&
			requests[0].channel === LEAST_STABLE &&
			Object.keys(requests[0]).sort().join(',') === 'action,channel,tag',
		`one click must post exactly install_release with the tag and the channel (got ${JSON.stringify(requests)})`
	);
	expect(page.el('btn-install').disabled === true, 'the button waits for the host');
	expect(
		page.shown('install-panel') &&
			page.el('install-text').textContent ===
				fill('changelog_window.install_backing_up', { tag: 'v0.0.0-dev.139' }),
		'the window must say the configuration is being backed up first'
	);
	page.el('btn-install').dispatch('click');
	page.select('v0.0.0-dev.142');
	page.el('btn-install').dispatch('click');
	expect(page.payloads('install_release').length === 1, 'no second install while one runs');
}

function checkProgressFailureAndRetry() {
	const page = openPage({ __installed_version: INSTALLED });
	page.select('v0.0.0-dev.139');
	page.el('btn-install').dispatch('click');
	page.sandbox.setInstallProgress({ tag: 'v0.0.0-dev.139', phase: 'downloading' });
	expect(
		page.el('install-text').textContent ===
			fill('changelog_window.install_downloading', { tag: 'v0.0.0-dev.139' }),
		'the host phase must be shown'
	);
	expect(!page.shown('btn-install-retry'), 'no Retry while the install runs');

	page.sandbox.setInstallProgress({
		tag: 'v0.0.0-dev.139',
		phase: 'failed',
		reason_key: 'changelog_window.install_error_no_asset',
		backup_path: '~/.config/ergopti_plus/backups/pre-install-x'
	});
	const text = page.el('install-text').textContent;
	expect(
		text.includes(fill('changelog_window.install_error_no_asset', { tag: 'v0.0.0-dev.139' })) &&
			text.includes('~/.config/ergopti_plus/backups/pre-install-x'),
		`a refusal must name its reason and the backup it kept (got ${text})`
	);
	expect(page.el('install-panel').className === 'failed', 'the failure is styled as one');
	expect(page.shown('btn-install-retry'), 'a failure offers Retry');
	expect(page.el('btn-install').disabled === false, 'a failed install frees the button');
	page.el('btn-install-retry').dispatch('click');
	const requests = page.payloads('install_release');
	expect(
		requests.length === 2 &&
			requests[1].tag === 'v0.0.0-dev.139' &&
			requests[1].channel === LEAST_STABLE,
		'Retry must post the same install request again'
	);

	page.sandbox.setInstallProgress({
		tag: 'v0.0.0-dev.139',
		phase: 'failed',
		reason_key: 'menu.global.uninstall'
	});
	expect(
		page.el('install-text').textContent === EN['changelog_window.install_error_unexpected'],
		'a reason key outside the install family must show the generic failure'
	);
	page.sandbox.setInstallProgress({ tag: 'v0.0.0-dev.139', phase: 'exploded' });
	expect(
		page.el('install-text').textContent === EN['changelog_window.install_error_unexpected'],
		'an unknown phase must be ignored'
	);
}

// ==========================================
// ==========================================
// ======= 3/ Hosts That Cannot Install =====
// ==========================================
// ==========================================

function checkSourceRunGreysEveryButton() {
	const page = openPage({
		__installed_version: 'local',
		__install_blocked_key: 'changelog_window.install_blocked_source'
	});
	for (const release of RELEASES) {
		page.select(release.tag_name);
		expect(
			page.shown('btn-install'),
			`${release.tag_name}: the button stays visible on a source run`
		);
		expect(page.el('btn-install').disabled === true, `${release.tag_name}: greyed on a source run`);
		expect(
			page.el('btn-install').title === EN['changelog_window.install_blocked_source'] &&
				page.el('install-note').textContent === EN['changelog_window.install_blocked_source'],
			`${release.tag_name}: the reason must be shown`
		);
	}
	page.el('btn-install').dispatch('click');
	expect(page.payloads('install_release').length === 0, 'a greyed button posts nothing');
}

function checkNoAnnouncedBuildShowsNoButton() {
	const page = openPage({});
	page.select('v0.0.0-dev.139');
	expect(!page.shown('btn-install'), 'a host that names no build offers no install');
	page.sandbox.requestInstall();
	expect(page.payloads('install_release').length === 0, 'and posts none');
}

function checkLinuxAnnouncesItsContext() {
	const page = openPage({});
	page.answer({
		action: 'releases',
		channel: LEAST_STABLE,
		releases: [],
		cache_miss: true,
		install: {
			installed: INSTALLED,
			blocked_key: '',
			backup: {
				id: 'pre-install-20260930-101500',
				created_at: '2026-09-30T10:15:00Z',
				tag: 'v0.0.0-dev.139'
			}
		}
	});
	page.select('v0.0.0-dev.141');
	expect(page.shown('btn-install'), 'the Linux context turns the buttons on');
	expect(
		page.row('v0.0.0-dev.140').className.split(' ').includes('installed'),
		'the Linux context marks the installed row'
	);
	expect(page.shown('restore-banner'), 'a restorable backup shows the restore banner');
	expect(
		page.el('restore-text').textContent.includes('v0.0.0-dev.139'),
		'the banner names the release installed after the backup'
	);
	page.el('btn-restore').dispatch('click');
	const restores = page.payloads('restore_backup');
	expect(
		restores.length === 1 && restores[0].id === 'pre-install-20260930-101500',
		'the restore button must post restore_backup with the backup id'
	);
	page.el('btn-restore').dispatch('click');
	expect(page.payloads('restore_backup').length === 1, 'a pending restore is not posted twice');
	page.answer({
		action: 'restore_progress',
		phase: 'failed',
		reason_key: 'changelog_window.restore_error_unexpected',
		backup_path: '/b/pre-restore'
	});
	expect(
		page.el('restore-text').textContent ===
			fill('changelog_window.restore_error_unexpected', { path: '/b/pre-restore' }),
		'a failed restore names the backup of the configuration it replaced'
	);
	page.answer({ action: 'install_progress', tag: 'v0.0.0-dev.141', phase: 'installing' });
	expect(
		page.el('install-text').textContent ===
			fill('changelog_window.install_installing', { tag: 'v0.0.0-dev.141' }),
		'Linux install progress reaches the panel'
	);
}

// ==========================================
// ==========================================
// ======= 4/ Feed-Only Lists ===============
// ==========================================
// ==========================================

// The Atom feed of the same releases plus a later stable one, newest first. It
// names no files and no digests (sparkle-handoff-2026-10-22).
const FEED_TAGS = [
	'v1.4.0',
	'v0.0.0-dev.142',
	'v1.3.0',
	'v0.0.0-dev.141',
	'v0.0.0-dev.140',
	'v0.0.0-dev.139'
];
const FEED = [
	'<?xml version="1.0" encoding="UTF-8"?>',
	'<feed xmlns="http://www.w3.org/2005/Atom">',
	...FEED_TAGS.map(
		(tag, index) =>
			`<entry><updated>2026-10-${String(20 - index).padStart(2, '0')}T10:00:00Z</updated>` +
			`<link rel="alternate" type="text/html" href="https://github.com/adrienm7/ergopti/releases/tag/${tag}"/>` +
			`<title>${tag}</title><content type="html">&lt;p&gt;Notes&lt;/p&gt;</content></entry>`
	),
	'</feed>'
].join('\n');

/**
 * Opens the page on the least stable channel and lists the feed.
 * @param {Object} globals - Host seeds.
 */
function openFeedPage(globals) {
	const page = runPage({
		_i18n_strings: EN,
		__ergopti_host: 'linux',
		__subscribed_channel: LEAST_STABLE,
		...globals
	});
	page.sandbox.injectReleasesFeed(FEED, LEAST_STABLE);
	const el = (id) => page.document.getElementById(id);
	const tags = () =>
		el('release-list')
			.children.map((item) => item.children[0] && item.children[0].textContent)
			.filter(Boolean);
	return {
		...page,
		el,
		tags,
		shown: (id) => el(id).style.display !== 'none',
		select: (tag) => page.sandbox.selectRelease(tags().indexOf(tag)),
		payloads: (action) =>
			page.posted.map((message) => message.payload).filter((p) => p && p.action === action)
	};
}

function checkFeedNewestReleaseIsHandedToTheUpdater() {
	const page = openFeedPage({ __installed_version: INSTALLED, __feed_install_handoff: true });
	expect(
		page.tags()[0] === 'v1.4.0' && page.tags().includes('v0.0.0-dev.142'),
		`the dev view lists the feed, newest first (got ${page.tags().join(', ')})`
	);
	page.select('v0.0.0-dev.142');
	expect(page.shown('btn-install'), 'the channel’s newest feed release carries the button');
	expect(
		page.el('btn-install').textContent === EN['changelog_window.install_release'] &&
			page.el('btn-install').disabled === false,
		'it reads « Install this version » and is usable'
	);
	expect(
		page.shown('install-note') &&
			page.el('install-note').textContent === EN['changelog_window.install_handoff_note'],
		'the note says the built-in updater installs it after checking its signature'
	);
	page.el('btn-install').dispatch('click');
	const handoffs = page.payloads('install_through_updater');
	expect(
		handoffs.length === 1 &&
			handoffs[0].tag === 'v0.0.0-dev.142' &&
			handoffs[0].channel === LEAST_STABLE &&
			Object.keys(handoffs[0]).sort().join(',') === 'action,channel,tag',
		`one click must post exactly install_through_updater with the tag and the channel (got ${JSON.stringify(handoffs)})`
	);
	expect(page.payloads('install_release').length === 0, 'the hand-off is not a direct install');
	expect(
		page.shown('install-panel') &&
			page.el('install-text').textContent ===
				fill('changelog_window.install_handed_off', { tag: 'v0.0.0-dev.142' }),
		'the window says the updater checks the signature and asks in its own window'
	);
	expect(page.el('btn-install').disabled === true, 'the button waits for the host');
	page.el('btn-install').dispatch('click');
	expect(page.payloads('install_through_updater').length === 1, 'no second hand-off meanwhile');

	page.sandbox.setInstallProgress({ tag: 'v0.0.0-dev.142', phase: 'handed_off' });
	expect(
		page.el('install-text').textContent ===
			fill('changelog_window.install_handed_off', { tag: 'v0.0.0-dev.142' }) &&
			page.el('install-panel').className === '',
		'the handed_off phase is shown as progress, not as a failure'
	);
	expect(
		page.el('btn-install').disabled === false,
		'once handed off the updater owns it: its dialog may be cancelled, so the button is free'
	);
	expect(!page.shown('btn-install-retry'), 'a hand-off offers no Retry');

	page.sandbox.setInstallProgress({
		tag: 'v0.0.0-dev.142',
		phase: 'failed',
		reason_key: 'changelog_window.install_error_handoff'
	});
	expect(
		page.el('install-text').textContent === EN['changelog_window.install_error_handoff'],
		'a refused hand-off names its reason'
	);
	page.el('btn-install-retry').dispatch('click');
	expect(
		page.payloads('install_through_updater').length === 2 &&
			page.payloads('install_release').length === 0,
		'Retry hands off again and never turns into a direct install'
	);
}

function checkFeedOlderReleasesKeepTheWarning() {
	const page = openFeedPage({ __installed_version: INSTALLED, __feed_install_handoff: true });
	for (const tag of ['v1.4.0', 'v1.3.0', 'v0.0.0-dev.141', 'v0.0.0-dev.139']) {
		page.select(tag);
		expect(
			!page.shown('install-note') ||
				page.el('install-note').textContent !== EN['changelog_window.install_handoff_note'],
			`${tag}: only the channel’s newest release is installed by the updater`
		);
		page.el('btn-install').dispatch('click');
		page.sandbox.setInstallProgress({
			tag,
			phase: 'failed',
			reason_key: 'changelog_window.install_error_no_details'
		});
		expect(
			page.el('install-text').textContent === EN['changelog_window.install_error_no_details'],
			`${tag}: the host's no-details warning is shown`
		);
	}
	expect(
		page.payloads('install_through_updater').length === 0 &&
			page.payloads('install_release').length === 4,
		'older rows post the direct install, which the host refuses with the existing warning'
	);
}

function checkFeedOtherChannelOffersItsOwnNewest() {
	const page = openFeedPage({ __installed_version: INSTALLED, __feed_install_handoff: true });
	page.sandbox.setChannel('main');
	expect(
		page.payloads('fetch').length === 0 && page.tags()[0] === 'v1.4.0',
		'a tab filters the feed locally'
	);
	page.select('v1.4.0');
	page.el('btn-install').dispatch('click');
	const handoffs = page.payloads('install_through_updater');
	expect(
		handoffs.length === 1 && handoffs[0].tag === 'v1.4.0' && handoffs[0].channel === 'main',
		'a switch of channel hands that channel’s newest release to the updater (the shared offer rule)'
	);
}

function checkFeedHandoffNeedsTheHostAndTheFeed() {
	const noHost = openFeedPage({ __installed_version: INSTALLED });
	noHost.select('v0.0.0-dev.142');
	noHost.el('btn-install').dispatch('click');
	expect(
		noHost.payloads('install_through_updater').length === 0 &&
			noHost.payloads('install_release').length === 1,
		'a host without a verifying updater (Windows, Linux) keeps the direct request and its warning'
	);

	const api = openPage({ __installed_version: INSTALLED, __feed_install_handoff: true });
	api.select('v0.0.0-dev.142');
	api.el('btn-install').dispatch('click');
	expect(
		api.payloads('install_through_updater').length === 0 &&
			api.payloads('install_release').length === 1,
		'an API list names the digests: its newest release installs directly'
	);

	const upToDate = openFeedPage({
		__installed_version: '0.0.0-dev.142',
		__feed_install_handoff: true
	});
	upToDate.select('v0.0.0-dev.141');
	upToDate.el('btn-install').dispatch('click');
	expect(
		upToDate.payloads('install_through_updater').length === 0,
		'nothing newer on the installed channel: the updater is offered nothing'
	);

	const failedLoad = openFeedPage({ __installed_version: INSTALLED, __feed_install_handoff: true });
	failedLoad.sandbox.injectError('x');
	failedLoad.sandbox.injectReleases(RELEASES, LEAST_STABLE);
	failedLoad.select('v0.0.0-dev.142');
	failedLoad.el('btn-install').dispatch('click');
	expect(
		failedLoad.payloads('install_through_updater').length === 0,
		'a later API list replaces the feed and its hand-off'
	);
}

// ==========================================
// ==========================================
// ======= 5/ Report =======================
// ==========================================
// ==========================================

checkEveryOtherReleaseCarriesTheButton();
checkOneClickPostsTheRequest();
checkProgressFailureAndRetry();
checkSourceRunGreysEveryButton();
checkNoAnnouncedBuildShowsNoButton();
checkLinuxAnnouncesItsContext();
checkFeedNewestReleaseIsHandedToTheUpdater();
checkFeedOlderReleasesKeepTheWarning();
checkFeedOtherChannelOffersItsOwnNewest();
checkFeedHandoffNeedsTheHostAndTheFeed();

if (failures.length > 0) {
	console.error(
		`\x1b[31m[FAIL] Versions page one-click install (${failures.length}/${checks}):\x1b[0m`
	);
	for (const failure of failures) console.error('  - ' + failure);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] Versions page installs a chosen release in one click through the host (${checks} checks).\x1b[0m`
);
