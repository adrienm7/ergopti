// tools/test/test-changelog-network-resilience.cjs

/**
 * ==============================================================================
 * MODULE: Changelog Network Resilience Regression Test
 * DESCRIPTION:
 * Executes the shared changelog page against a recording DOM with controllable
 * timers and fetch. On a corporate network the page used to spin forever: the
 * native hosts never answered when api.github.com was blocked and nothing
 * bounded the wait. Every load must now end in data or in a visible error that
 * offers Retry and the releases page, and the public Atom feed must be usable
 * as the alternate source without ever handing remote HTML to a parser.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..', '..');
const PLUS = path.join(ROOT, 'static', 'ergopti_plus');
const SHARED_UI = path.join(PLUS, '_shared', 'ui');
const CHANGELOG = path.join(SHARED_UI, 'changelog');
const DEFAULTS = JSON.parse(
	fs.readFileSync(path.join(PLUS, '_shared', 'modules', 'updater', 'defaults.json'), 'utf8')
);
const FEED = fs.readFileSync(
	path.join(PLUS, '_shared', 'tests', 'corpus', 'updater', 'releases_feed.atom'),
	'utf8'
);
const EN = JSON.parse(
	fs.readFileSync(path.join(PLUS, '_shared', 'data', 'locales', 'en.json'), 'utf8')
);
const RELEASES_PAGE = 'https://github.com/adrienm7/ergopti/releases';

const failures = [];
let checks = 0;

function expect(condition, message) {
	checks += 1;
	if (!condition) failures.push(message);
}

// ==========================================
// ==========================================
// ======= 1/ Recording DOM ================
// ==========================================
// ==========================================

class FakeNode {
	constructor(tagName, nodeType) {
		this.tagName = tagName;
		this.nodeType = nodeType;
		this.children = [];
		this.attributes = {};
		this.listeners = {};
		this.style = {};
		this.className = '';
		this.id = '';
		this._text = '';
		const node = this;
		this.classList = {
			toggle(name, force) {
				const set = new Set(node.className.split(/\s+/).filter(Boolean));
				if (force === undefined ? !set.has(name) : force) set.add(name);
				else set.delete(name);
				node.className = Array.from(set).join(' ');
			}
		};
	}

	get textContent() {
		if (this.nodeType === 3) return this._text;
		return this.children.map((child) => child.textContent).join('');
	}

	set textContent(value) {
		if (this.nodeType === 3) {
			this._text = String(value);
			return;
		}
		this.children = value === '' ? [] : [makeText(String(value))];
	}

	set innerHTML(_value) {
		throw new Error('innerHTML is forbidden for remote release notes');
	}

	insertAdjacentHTML() {
		throw new Error('insertAdjacentHTML is forbidden for remote release notes');
	}

	appendChild(child) {
		this.children.push(child);
		return child;
	}

	replaceChildren(...children) {
		this.children = children;
	}

	setAttribute(name, value) {
		this.attributes[name] = String(value);
	}

	getAttribute(name) {
		return Object.prototype.hasOwnProperty.call(this.attributes, name)
			? this.attributes[name]
			: null;
	}

	addEventListener(type, handler) {
		(this.listeners[type] = this.listeners[type] || []).push(handler);
	}

	dispatch(type, event) {
		(this.listeners[type] || []).forEach((handler) => handler(event || { preventDefault() {} }));
	}
}

function makeText(value) {
	const node = new FakeNode('#text', 3);
	node._text = value;
	return node;
}

function elements(node, acc = []) {
	if (node.nodeType === 1) acc.push(node);
	node.children.forEach((child) => elements(child, acc));
	return acc;
}

function byTag(root, tag) {
	return elements(root).filter((node) => node.tagName === tag);
}

// ==========================================
// ==========================================
// ======= 2/ Page Harness =================
// ==========================================
// ==========================================

function pageScripts() {
	const html = fs.readFileSync(path.join(CHANGELOG, 'index.html'), 'utf8');
	const scripts = [];
	const pattern = /<script\s+src="([^"]+)"/g;
	let match;
	while ((match = pattern.exec(html)) !== null) scripts.push(match[1]);
	return scripts;
}

/**
 * Loads the page with a chosen host profile.
 * @param {{host: 'windows'|'linux'|'none', fetch?: Function}} options
 */
function runPage(options) {
	const byId = new Map();
	const posted = [];
	const timers = new Map();
	let timerId = 0;
	let clock = 0;
	const document = {
		readyState: 'complete',
		getElementById(id) {
			if (!byId.has(id)) {
				const node = new FakeNode('div', 1);
				node.id = id;
				byId.set(id, node);
			}
			return byId.get(id);
		},
		querySelectorAll: () => [],
		createElement: (tag) => new FakeNode(String(tag).toLowerCase(), 1),
		createTextNode: (value) => makeText(String(value)),
		addEventListener() {}
	};
	const sandbox = {
		console,
		URL,
		Date,
		JSON,
		Promise,
		AbortController,
		document,
		_i18n_strings: EN,
		makeHostBridge: (name) => (payload) => posted.push({ name, payload }),
		decodeHostBridgeResponse: (_isBase64, payload) => JSON.parse(payload),
		setTimeout(fn, delay) {
			timerId += 1;
			timers.set(timerId, { fn, due: clock + (delay || 0) });
			return timerId;
		},
		clearTimeout(id) {
			timers.delete(id);
		},
		fetch: options.fetch || (() => new Promise(() => {}))
	};
	sandbox.window = sandbox;
	if (options.host === 'windows') sandbox.chrome = { webview: { postMessage() {} } };
	if (options.host === 'linux') sandbox.__ergopti_host = 'linux';
	vm.createContext(sandbox);
	for (const src of pageScripts()) {
		const file = path.resolve(CHANGELOG, src);
		if (['host_bridge.js', 'i18n.js'].includes(path.basename(file))) continue;
		vm.runInContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: src });
	}
	/** Advances the fake clock and fires every timer that became due. */
	function advance(ms) {
		clock += ms;
		for (const [id, timer] of Array.from(timers.entries()).sort((a, b) => a[1].due - b[1].due)) {
			if (timer.due <= clock && timers.has(id)) {
				timers.delete(id);
				timer.fn();
			}
		}
	}
	const el = (id) => document.getElementById(id);
	return {
		sandbox,
		posted,
		advance,
		el,
		loading: () => el('loading-overlay').style.display === 'flex',
		errorShown: () => el('error-overlay').style.display === 'flex',
		errorText: () => el('error-text').textContent
	};
}

const flush = () => new Promise((resolve) => setImmediate(resolve));

// ==========================================
// ==========================================
// ======= 3/ Scenarios ====================
// ==========================================
// ==========================================

function checkSharedBudgets() {
	const sources = DEFAULTS.release_sources || {};
	const script = fs.readFileSync(path.join(CHANGELOG, 'script.js'), 'utf8');
	const watchdog = /var CHANGELOG_WATCHDOG_MS = (\d+);/.exec(script);
	const client = /var CLIENT_FETCH_TIMEOUT_MS = (\d+);/.exec(script);
	expect(
		watchdog && Number(watchdog[1]) === sources.ui_watchdog_sec * 1000,
		'the page watchdog must mirror release_sources.ui_watchdog_sec'
	);
	expect(
		client && Number(client[1]) === sources.source_timeout_sec * 1000,
		'the preview fetch budget must mirror release_sources.source_timeout_sec'
	);
	expect(
		sources.ui_watchdog_sec > sources.proxy_resolve_timeout_sec + 2 * sources.source_timeout_sec,
		'the watchdog must outlast proxy resolution plus both native sources'
	);
	for (const key of ['api_releases_url', 'atom_feed_url', 'releases_page_url']) {
		expect(
			typeof sources[key] === 'string' && sources[key].includes('{owner}/{repo}'),
			`release_sources.${key} must be an {owner}/{repo} template`
		);
	}
	expect(
		sources.atom_feed_url === 'https://github.com/{owner}/{repo}/releases.atom',
		'the alternate source must be the github.com Atom feed, reachable when only the API is blocked'
	);
	const index = fs.readFileSync(path.join(CHANGELOG, 'index.html'), 'utf8');
	expect(
		index.indexOf('src="../markdown.js"') < index.indexOf('src="atom_feed.js"') &&
			index.indexOf('src="atom_feed.js"') < index.indexOf('src="script.js"'),
		'the feed reader must load after the renderer and before the page script'
	);
	const feedReader = fs.readFileSync(path.join(CHANGELOG, 'atom_feed.js'), 'utf8');
	expect(
		!/\binnerHTML\b|\bouterHTML\b|insertAdjacentHTML|DOMParser|document\.write|\beval\s*\(|new Function/.test(
			feedReader
		),
		'the feed reader must never hand remote markup to an HTML parser or evaluator'
	);
	expect(
		!/<\/script/i.test(feedReader),
		'inlined hosts would truncate a script containing a closing tag'
	);
	for (const key of ['changelog_window.error_timeout', 'changelog_window.open_releases_page']) {
		expect(typeof EN[key] === 'string' && EN[key] !== '', `en.json must define ${key}`);
	}
}

function checkWatchdogEndsNativeWait() {
	const page = runPage({ host: 'windows' });
	expect(page.loading(), 'the page must start in its loading state');
	expect(
		page.posted.some((entry) => entry.payload === 'ready'),
		'the page must announce readiness to the native host'
	);
	page.advance(DEFAULTS.release_sources.ui_watchdog_sec * 1000 - 1);
	expect(page.loading() && !page.errorShown(), 'the watchdog must not fire before its budget');
	page.advance(1);
	expect(!page.loading(), 'a host that never answers must not leave the spinner running');
	expect(page.errorShown(), 'the watchdog must surface the error overlay');
	expect(
		page.errorText() === EN['changelog_window.error_timeout'],
		'the watchdog must show the translated timeout'
	);

	page.el('btn-releases-page').dispatch('click');
	const open = page.posted[page.posted.length - 1].payload;
	expect(
		open && open.action === 'open_url' && open.url === RELEASES_PAGE,
		'the error state must offer the releases page through the native opener'
	);

	page.el('btn-retry').dispatch('click');
	const fetchRequest = page.posted[page.posted.length - 1].payload;
	expect(
		fetchRequest && fetchRequest.action === 'fetch' && fetchRequest.channel === 'main',
		'Retry must ask the native host to fetch the current channel again'
	);
	expect(page.loading() && !page.errorShown(), 'Retry must return to a bounded loading state');
	page.advance(DEFAULTS.release_sources.ui_watchdog_sec * 1000);
	expect(
		page.errorShown() && !page.loading(),
		'a retried load must be bounded by its own watchdog'
	);

	page.sandbox.injectReleases(
		[
			{
				tag_name: 'v2.4.0',
				body: 'Late data',
				html_url: RELEASES_PAGE + '/tag/v2.4.0',
				prerelease: false
			}
		],
		'main'
	);
	expect(!page.errorShown() && !page.loading(), 'late native data must replace the error overlay');
	expect(page.el('release-tag').textContent === 'v2.4.0', 'late native data must render');
}

function checkDataDisarmsWatchdog() {
	const page = runPage({ host: 'windows' });
	page.sandbox.injectReleases([{ tag_name: 'v2.4.0', body: 'x', prerelease: false }], 'main');
	page.advance(DEFAULTS.release_sources.ui_watchdog_sec * 1000 * 2);
	expect(!page.errorShown(), 'the watchdog must be disarmed once data arrived');

	const errored = runPage({ host: 'windows' });
	errored.sandbox.injectError('Native failure marker');
	expect(
		errored.errorShown() && errored.errorText() === 'Native failure marker',
		'a native error must show verbatim'
	);
	errored.advance(DEFAULTS.release_sources.ui_watchdog_sec * 1000 * 2);
	expect(
		errored.errorText() === 'Native failure marker',
		'the watchdog must not overwrite a reported error'
	);
}

function checkRetryAfterPartialSuccess() {
	const page = runPage({ host: 'windows' });
	page.sandbox.injectReleases([{ tag_name: 'v2.4.0', body: 'x', prerelease: false }], 'main');
	page.sandbox.injectError('Transient');
	const before = page.posted.length;
	page.el('btn-retry').dispatch('click');
	expect(
		page.posted.length === before + 1 && page.posted[before].payload.action === 'fetch',
		'Retry must refetch even when an earlier load listed releases'
	);
}

function checkJsonIsParsedNotEvaluated() {
	const page = runPage({ host: 'windows' });
	page.sandbox.injectReleasesJson('<html><body>Blocked by corporate policy</body></html>', 'main');
	expect(page.errorShown() && !page.loading(), 'a proxy block page must end in a visible error');
	expect(
		page.errorText() === EN['changelog_window.error_parse'],
		'a non-JSON body must show the parse error'
	);

	page.sandbox.injectReleasesJson('1);window.pwned=1;(', 'main');
	expect(page.sandbox.pwned === undefined, 'a hostile API body must never execute');

	page.sandbox.injectReleasesJson('{"message":"API rate limit exceeded"}', 'main');
	expect(page.errorShown(), 'a JSON object instead of a release array must be an error');

	page.sandbox.injectReleasesJson(
		JSON.stringify([null, 3, { tag_name: 'v2.4.0', body: 'ok', prerelease: false }]),
		'main'
	);
	expect(
		!page.errorShown() && page.el('release-tag').textContent === 'v2.4.0',
		'malformed entries must be skipped while valid ones render'
	);
}

function renderedFeed(channel) {
	const page = runPage({ host: 'windows' });
	page.sandbox.injectReleasesFeed(FEED, channel);
	return page;
}

function checkAtomFallbackRendering() {
	const page = renderedFeed('dev');
	expect(!page.errorShown() && !page.loading(), 'the Atom feed must render as release data');
	const list = page.el('release-list');
	const tags = byTag(list, 'div')
		.filter((node) => node.className === 'release-item-tag')
		.map((node) => node.textContent);
	expect(
		JSON.stringify(tags) === JSON.stringify(['v0.0.0-dev.130', 'v2.4.0', 'v0.0.0-dev.129']),
		`feed entries must keep feed order and drop foreign repositories (got ${JSON.stringify(tags)})`
	);
	const records = page.sandbox.parseReleasesAtom(FEED, 'adrienm7', 'ergopti');
	expect(
		records[0].prerelease === true && records[1].prerelease === false,
		'the dev tag family must map to pre-releases and plain semver to stable'
	);
	expect(
		records[0].html_url === RELEASES_PAGE + '/tag/v0.0.0-dev.130',
		'each record must link its own repository tag page'
	);
	expect(
		records[0].published_at === '2026-09-22T14:35:46Z',
		'the entry update time must become the date'
	);
	expect(records[2].body === '', 'an empty entry must yield empty notes');

	const body = page.el('release-body');
	const text = body.textContent;
	expect(
		byTag(body, 'h2').some((h) => h.textContent === 'Ergopti 0.0.0-dev.130'),
		'feed h2 must render as h2'
	);
	expect(
		byTag(body, 'h3').some((h) => h.textContent === 'Fix'),
		'feed h3 must render as h3'
	);
	expect(
		byTag(body, 'strong').some(
			(node) => node.textContent === 'Release: Link downloads through the release page'
		),
		'feed strong text must render as strong'
	);
	expect(byTag(body, 'blockquote').length === 1, 'a feed blockquote must stay a blockquote');
	expect(byTag(body, 'ul').length >= 2, 'nested feed lists must stay nested');
	expect(
		byTag(body, 'li').some((li) => li.textContent === 'Nested item'),
		'the nested feed item must be its own li'
	);
	expect(
		byTag(body, 'em').some((node) => node.textContent === 'emphasis'),
		'feed emphasis must render'
	);
	expect(
		byTag(body, 'table').length === 1 &&
			byTag(body, 'th').length === 2 &&
			byTag(body, 'td').length === 2,
		'a feed table must render as a table'
	);
	expect(
		byTag(body, 'pre').some((pre) => pre.textContent === 'winget install ergopti && echo *done*'),
		'feed preformatted code must stay literal, entities decoded once'
	);
	expect(
		byTag(body, 'code').some((node) => node.textContent === 'v0.0.0-dev.129'),
		'inline feed code must render as code'
	);
	const anchors = byTag(body, 'a');
	expect(
		anchors.some((a) => a.textContent === 'v0.0.0-dev.129'),
		'a repository link from the feed must stay clickable'
	);
	expect(
		anchors.every((a) => a.getAttribute('href') === null),
		'feed links must never carry an href the WebView could navigate'
	);
	expect(text.includes("release's own page"), 'numeric character references must decode');
	expect(
		!text.includes('&#39;') && !text.includes('&lt;'),
		'no entity may reach the page undecoded'
	);
}

function checkAtomHostileContent() {
	const page = renderedFeed('main');
	const tags = byTag(page.el('release-list'), 'div')
		.filter((node) => node.className === 'release-item-tag')
		.map((node) => node.textContent);
	expect(
		JSON.stringify(tags) === '["v2.4.0"]',
		'the stable channel must list only stable feed entries'
	);
	const body = page.el('release-body');
	const text = body.textContent;
	expect(
		byTag(body, 'img').length === 0 && byTag(body, 'script').length === 0,
		'feed markup must never become elements'
	);
	expect(!text.includes('script body'), 'script element content must be dropped');
	expect(text.includes('image alt'), 'an image must degrade to its alt text');
	expect(
		text.includes('literal *stars* <b>.'),
		'literal Markdown and escaped markup must stay literal text'
	);
	expect(byTag(body, 'em').length === 0, 'escaped asterisks must not become emphasis');
	const anchors = byTag(body, 'a');
	expect(
		!anchors.some((a) => a.textContent === 'script link' || a.textContent === 'foreign link'),
		'javascript: and foreign links from the feed must not become clickable'
	);
	expect(
		text.includes('script link') && text.includes('foreign link'),
		'refused links must keep their label'
	);
	expect(page.sandbox.pwned === undefined, 'no feed content may execute');
}

function checkInvalidFeed() {
	const page = runPage({ host: 'windows' });
	page.sandbox.injectReleasesFeed('<html><body>Access denied</body></html>', 'dev');
	expect(
		page.errorShown() && page.errorText() === EN['changelog_window.error_parse'],
		'a non-feed page must be a parse error'
	);
}

function checkLinuxPushProtocol() {
	const page = runPage({ host: 'linux' });
	page.sandbox.__hostBridgeResponse(
		'changelog_bridge',
		false,
		JSON.stringify({ action: 'releases_error', message: 'Linux native failure' })
	);
	expect(
		page.errorShown() && page.errorText() === 'Linux native failure',
		'a Linux error push must be visible'
	);
	page.sandbox.__hostBridgeResponse(
		'changelog_bridge',
		false,
		JSON.stringify({ action: 'releases', channel: 'dev', feed: FEED })
	);
	expect(
		!page.errorShown() && page.el('release-tag').textContent === 'v0.0.0-dev.130',
		'a Linux feed push must render through the feed reader'
	);
}

async function checkPreviewFetch() {
	const budget = DEFAULTS.release_sources.source_timeout_sec * 1000;
	const hanging = runPage({
		host: 'none',
		fetch: (_url, init) =>
			new Promise((_resolve, reject) => {
				init.signal.addEventListener('abort', () => reject(new Error('aborted')));
			})
	});
	expect(hanging.loading(), 'a preview must start loading');
	hanging.advance(0);
	hanging.advance(budget);
	await flush();
	expect(
		hanging.errorShown() && hanging.errorText() === EN['changelog_window.error_network'],
		'a hanging preview fetch must abort at its budget and show the network error'
	);

	const limited = runPage({
		host: 'none',
		fetch: () => Promise.resolve({ ok: false, status: 403 })
	});
	limited.advance(0);
	await flush();
	expect(
		limited.errorText() === EN['changelog_window.error_rate_limited'],
		'HTTP 403 must show the rate-limit error'
	);

	const object = runPage({
		host: 'none',
		fetch: () =>
			Promise.resolve({ ok: true, status: 200, json: () => Promise.resolve({ message: 'x' }) })
	});
	object.advance(0);
	await flush();
	await flush();
	expect(object.errorShown(), 'a non-array preview response must not leave the spinner running');

	const fine = runPage({
		host: 'none',
		fetch: () =>
			Promise.resolve({
				ok: true,
				status: 200,
				json: () => Promise.resolve([{ tag_name: 'v2.4.0', body: 'ok', prerelease: false }])
			})
	});
	fine.advance(0);
	await flush();
	await flush();
	expect(
		!fine.loading() && fine.el('release-tag').textContent === 'v2.4.0',
		'a preview fetch must render data'
	);
}

async function main() {
	const scenarios = [
		checkSharedBudgets,
		checkWatchdogEndsNativeWait,
		checkDataDisarmsWatchdog,
		checkRetryAfterPartialSuccess,
		checkJsonIsParsedNotEvaluated,
		checkAtomFallbackRendering,
		checkAtomHostileContent,
		checkInvalidFeed,
		checkLinuxPushProtocol,
		checkPreviewFetch
	];
	for (const scenario of scenarios) {
		try {
			await scenario();
		} catch (error) {
			expect(false, `${scenario.name} raised: ${error.stack || error.message}`);
		}
	}
	console.log(`1..${checks}`);
	if (failures.length === 0) {
		console.log(`ok - ${checks} changelog network resilience checks passed`);
		process.exit(0);
	}
	failures.forEach((message, index) => console.log(`not ok ${index + 1} - ${message}`));
	process.exit(1);
}

main();
