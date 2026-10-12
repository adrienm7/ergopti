// tools/test/test-webview-host-strings-survive-failed-fetch.cjs

/**
 * ==============================================================================
 * MODULE: Host-Delivered Strings Survive the Page's Own Locale Fetch
 * DESCRIPTION:
 * Runs the real shared i18n loader, then the real diagnostics page and error
 * window, the way macOS hosts them: an inline page whose fetch of file:// locale
 * files is always refused, and a host that delivers the strings itself.
 *
 * ROOT CAUSE ENCODED:
 * i18n.js replaced window._i18n_strings on every apply(), and its fetch cascade
 * always ends with an apply, even when every fetch failed. On macOS the host
 * injects the full catalogue when the page finishes loading, and the page's
 * doomed cascade settles around the same time. Whenever the refusal landed
 * last, the empty result wiped the host's strings and the page re-rendered:
 * every section title, field label and problem line of the diagnostics page,
 * and the heading of the error window, showed its raw key. The toolbar kept its
 * text, which made the page look half translated rather than broken.
 *
 * The second half pins the delivery that removes the race altogether: a host
 * that seeds window._i18n_strings before the page runs gets translated text at
 * the first render and no fetch at all.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const I18N_JS = path.join(SHARED, 'ui', 'i18n.js');
const en = JSON.parse(fs.readFileSync(path.join(SHARED, 'data', 'locales', 'en.json'), 'utf8'));

const failures = [];
const fail = (message) => failures.push(message);

// The macOS refusal: WKWebView rejects file:// from an about:blank page, and the
// rejection reaches the page a moment after the host's injection
const REFUSAL_DELAY_MS = 5;

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Keys of en.json that appear verbatim in rendered text. */
function rawKeys(text) {
	return (String(text).match(/\b[a-z_]+(?:\.[a-z0-9_]+)+\b/g) || []).filter(
		(key) => typeof en[key] === 'string'
	);
}

// ================================================
// ================================================
// ======= 1/ The Loader Alone, Every Order =======
// ================================================
// ================================================

/** One element carrying a data-i18n key. */
function labelElement(key) {
	return {
		tagName: 'SPAN',
		textContent: '',
		getAttribute(name) {
			return name === 'data-i18n' ? key : null;
		}
	};
}

/**
 * Runs i18n.js over a two-label page.
 * @param {object} opts { seed, fetchResult: 'refused'|object, calls: host steps }
 */
async function runLoader(opts) {
	const labels = [labelElement('k.one'), labelElement('k.two')];
	const fetched = [];
	const win = { _i18n_locale: 'en', __i18n_base: 'file:///locales/' };
	if (opts.seed) win._i18n_strings = opts.seed;
	const document = {
		readyState: 'complete',
		currentScript: null,
		addEventListener() {},
		querySelectorAll(selector) {
			return selector === '[data-i18n]' ? labels : [];
		}
	};
	const fetchStub = (url) => {
		fetched.push(String(url));
		return new Promise((resolve, reject) =>
			setTimeout(() => {
				if (opts.fetchResult === 'refused') reject(new TypeError('Load failed'));
				else resolve({ ok: true, json: () => Promise.resolve(opts.fetchResult) });
			}, REFUSAL_DELAY_MS)
		);
	};
	const context = {
		window: win,
		document,
		fetch: fetchStub,
		console: { warn() {}, log() {}, error() {} },
		setTimeout,
		Promise
	};
	vm.createContext(context);
	vm.runInContext(fs.readFileSync(I18N_JS, 'utf8'), context, { filename: I18N_JS });
	for (const call of opts.calls || []) call(win);
	await wait(REFUSAL_DELAY_MS * 8);
	return { labels, fetched, store: win._i18n_strings || {} };
}

async function checkLoader() {
	const host = { 'k.one': 'One', 'k.two': 'Two' };

	// (host-injection-then-refusal) the shipped macOS race
	{
		const r = await runLoader({
			fetchResult: 'refused',
			calls: [(win) => win.i18n_apply(host)]
		});
		if (r.labels[0].textContent !== 'One' || r.store['k.two'] !== 'Two')
			fail(
				`(host-injection-then-refusal) the refused fetch wiped the host's strings: ` +
					`store=${JSON.stringify(r.store)}`
			);
	}

	// (host-outranks-fetch) a fetch that succeeds after the host spoke fills gaps only
	{
		const r = await runLoader({
			fetchResult: { 'k.one': 'Fetched one', 'k.two': 'Fetched two', 'k.extra': 'Extra' },
			calls: [(win) => win.i18n_apply({ 'k.one': 'One' })]
		});
		if (r.store['k.one'] !== 'One')
			fail(
				`(host-outranks-fetch) the page's fetch overwrote the host's string: ${r.store['k.one']}`
			);
		if (r.store['k.two'] !== 'Fetched two' || r.store['k.extra'] !== 'Extra')
			fail(
				`(host-outranks-fetch) the fetch did not fill the host's gaps: ${JSON.stringify(r.store)}`
			);
	}

	// (seeded-store-skips-fetch) strings delivered with the page need no fetch
	{
		const r = await runLoader({ seed: host, fetchResult: 'refused' });
		if (r.fetched.length !== 0)
			fail(`(seeded-store-skips-fetch) a complete seed still fetched: ${r.fetched.join(', ')}`);
		if (r.labels[0].textContent !== 'One' || r.labels[1].textContent !== 'Two')
			fail(
				`(seeded-store-skips-fetch) the seeded strings never reached the page: ` +
					`"${r.labels[0].textContent}" / "${r.labels[1].textContent}"`
			);
	}

	// (later-apply-merges) a smaller later delivery keeps what came before
	{
		const r = await runLoader({
			seed: host,
			fetchResult: 'refused',
			calls: [(win) => win.i18n_apply({ 'k.one': 'Uno' })]
		});
		if (r.store['k.one'] !== 'Uno' || r.store['k.two'] !== 'Two')
			fail(`(later-apply-merges) a later apply dropped earlier keys: ${JSON.stringify(r.store)}`);
	}
}

// ==================================================
// ==================================================
// ======= 2/ The Real Pages, Hosted as macOS =======
// ==================================================
// ==================================================

/** One element: the few properties and methods the pages touch. */
function element(id, tag) {
	return {
		id,
		tagName: (tag || 'div').toUpperCase(),
		innerHTML: '',
		textContent: '',
		className: '',
		hidden: false,
		checked: false,
		disabled: false,
		open: false,
		listeners: {},
		attributes: {},
		addEventListener(type, handler) {
			(this.listeners[type] = this.listeners[type] || []).push(handler);
		},
		getAttribute(name) {
			return this.attributes[name];
		},
		focus() {},
		closest() {
			return null;
		}
	};
}

/**
 * Loads a shared page as the macOS host does: scripts parsed while the document
 * is still loading, every locale fetch refused.
 * @param {string} app Directory under _shared/ui.
 * @param {string} bridge Message handler name.
 * @param {object|null} seed Strings the host's boot script delivers, or null.
 */
function loadPage(app, bridge, seed) {
	const dir = path.join(SHARED, 'ui', app);
	const html = fs.readFileSync(path.join(dir, 'index.html'), 'utf8');
	const elements = {};
	for (const match of html.matchAll(/<(\w+)[^>]*\bid="([^"]+)"/g))
		elements[match[2]] = element(match[2], match[1]);
	const labels = [];
	for (const match of html.matchAll(/<(\w+)[^>]*\bdata-i18n="([^"]+)"/g)) {
		const el = element('', match[1]);
		el.attributes['data-i18n'] = match[2];
		labels.push(el);
	}
	const ready = [];
	const document = {
		readyState: 'loading',
		currentScript: null,
		addEventListener(type, handler) {
			if (type === 'DOMContentLoaded') ready.push(handler);
		},
		dispatchEvent() {},
		getElementById: (id) => elements[id] || null,
		querySelectorAll(selector) {
			if (selector === '[data-i18n]') return labels;
			if (selector.includes('button'))
				return Object.values(elements).filter((el) => el.tagName === 'BUTTON');
			return [];
		}
	};
	const fetched = [];
	const sandbox = { document, console: { warn() {}, error() {}, log() {} }, setTimeout, Promise };
	sandbox.window = sandbox;
	sandbox.webkit = { messageHandlers: { [bridge]: { postMessage() {} } } };
	sandbox.atob = (text) => Buffer.from(text, 'base64').toString('binary');
	sandbox.TextDecoder = TextDecoder;
	sandbox.__i18n_base = 'file:///Applications/Ergopti.app/Contents/Resources/_shared/data/locales/';
	sandbox._i18n_locale = 'en';
	if (seed) sandbox._i18n_strings = seed;
	sandbox.fetch = (url) => {
		fetched.push(String(url));
		return new Promise((_, reject) =>
			setTimeout(() => reject(new TypeError('Load failed')), REFUSAL_DELAY_MS)
		);
	};
	vm.createContext(sandbox);
	const scripts = [...html.matchAll(/<script src="([^"]+)"><\/script>/g)].map((m) => m[1]);
	if (!scripts.some((rel) => /(^|\/)i18n\.js$/.test(rel)))
		fail(`${app}/index.html no longer loads the shared i18n.js — this guard is aimed at nothing`);
	for (const rel of scripts)
		vm.runInContext(fs.readFileSync(path.join(dir, rel), 'utf8'), sandbox, { filename: rel });
	return { sandbox, elements, labels, fetched, domReady: () => ready.forEach((h) => h()) };
}

const schema = JSON.parse(
	fs.readFileSync(path.join(SHARED, 'modules', 'diagnostics', 'schema.json'), 'utf8')
);
// The host supplies export labels independently of the active page locale.
schema.export_strings = Object.fromEntries(
	Object.entries(en).filter(([key]) => key.startsWith('healthcheck.'))
);
const redaction = JSON.parse(
	fs.readFileSync(path.join(SHARED, 'modules', 'diagnostics', 'redaction.json'), 'utf8')
);

/** The diagnostics init message, with an ERROR in the snapshot. */
const DIAGNOSTICS_INIT = {
	type: 'init',
	config: { schema, redaction, context: { home: '/Users/a', user: 'a' }, mode: null },
	snapshot: {
		schema_version: 2,
		driver: 'macos',
		generated_at: '2026-09-29T15:00:00Z',
		detailed: false,
		sections: {
			versions: { ergopti_version: '0.0.0-dev.146' },
			system: { os: 'macOS 15' },
			input: { paused: false },
			issues: { err_count: 1 }
		},
		probes: { github_api: { state: 'pending' } }
	}
};

/** The error window's init message for the boot ERROR the maintainer saw. */
const ERROR_INIT = {
	type: 'init',
	kind: 'error',
	module: 'shortcuts',
	message: "M.enable(): unknown hotkey 'at_hash'.",
	log_path: '/x/errors.log',
	text: 'report',
	more: 0
};

const ERROR_TEXT_IDS = ['heading', 'intro', 'logged', 'btn-open-log', 'disable-hint'];

async function checkPages() {
	for (const seeded of [false, true]) {
		const mode = seeded ? 'seeded by the boot script' : 'injected after load';

		// Diagnostics page
		{
			const page = loadPage('healthcheck', 'healthcheck', seeded ? en : null);
			page.domReady();
			page.sandbox.receiveDiagnostics(DIAGNOSTICS_INIT);
			if (!seeded) page.sandbox.i18n_apply(en);
			await wait(REFUSAL_DELAY_MS * 10);
			const shown = page.elements.content.innerHTML;
			const preview = page.elements['preview-text'].textContent;
			if (!preview.startsWith('# ErgoptiPlus diagnostics\n\n'))
				fail(`(diagnostics ${mode}) the complete English export preview is missing`);
			if (!preview.includes(en['healthcheck.export.privacy_notice']))
				fail(`(diagnostics ${mode}) the English export privacy notice is missing`);
			const raw = rawKeys(shown);
			if (!shown.includes(en['healthcheck.section.summary']))
				fail(`(diagnostics ${mode}) the summary section title is missing from the page`);
			if (raw.length)
				fail(
					`(diagnostics ${mode}) ${raw.length} raw key(s) shown once the refused fetch ` +
						`settled: ${[...new Set(raw)].slice(0, 5).join(', ')}`
				);
			if (seeded && page.fetched.length)
				fail(`(diagnostics ${mode}) a complete seed still fetched ${page.fetched.length} file(s)`);
		}

		// Error window
		{
			const page = loadPage('error_dialog', 'error_dialog', seeded ? en : null);
			page.domReady();
			page.sandbox.receiveErrorDialog(ERROR_INIT);
			if (!seeded) page.sandbox.i18n_apply(en);
			await wait(REFUSAL_DELAY_MS * 10);
			const shown = ERROR_TEXT_IDS.map((id) => page.elements[id].textContent).join('\n');
			const raw = rawKeys(shown);
			if (raw.length)
				fail(`(error window ${mode}) raw key(s) shown: ${[...new Set(raw)].join(', ')}`);
			if (!shown.includes(en['error_dialog.heading']))
				fail(`(error window ${mode}) the heading is not the English text: ${shown.split('\n')[0]}`);
			// i18n.js writes a <title> label to document.title, not to the element
			const blank = page.labels.filter((el) =>
				el.tagName === 'TITLE' ? !page.sandbox.document.title : el.textContent === ''
			);
			if (blank.length)
				fail(
					`(error window ${mode}) ${blank.length} data-i18n label(s) left blank: ` +
						blank.map((el) => el.attributes['data-i18n']).join(', ')
				);
		}
	}
}

// ===============================
// ===============================
// ======= 3/ Run & Report =======
// ===============================
// ===============================

(async () => {
	await checkLoader();
	await checkPages();
	if (failures.length) {
		console.error(`FAIL - ${failures.length} host-string failure(s):`);
		for (const message of failures) console.error(`  - ${message}`);
		process.exit(1);
	}
	console.log('OK - host-delivered strings survive the page locale fetch on every page checked');
})().catch((err) => {
	console.error(`FAIL - the check itself crashed: ${err && err.stack ? err.stack : err}`);
	process.exit(1);
});
