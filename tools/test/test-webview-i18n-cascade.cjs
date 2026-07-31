// tools/test/test-webview-i18n-cascade.cjs

/**
 * ==============================================================================
 * MODULE: Webview i18n Fallback-Cascade Guard
 * DESCRIPTION:
 * Executes the real _shared/ui/i18n.js against a minimal DOM stub and asserts
 * that a locale which fails to load, or which resolves only part of the page,
 * degrades to English (then French) rather than to a blank window.
 *
 * ROOT CAUSE ENCODED:
 * All 368 data-i18n elements across the eleven shared webviews ship with an
 * EMPTY body — the visible text exists only in the locale JSON. The loader had
 * a single fetch and no chain: `if (strings) apply(strings)`. So any failure of
 * that one request — a 404 on an unshipped locale code, a file:// restriction,
 * a malformed JSON — skipped apply() entirely and left every label empty. The
 * window rendered blank, and the only trace was a console.warn in a webview
 * with no visible console.
 *
 * That is strictly worse than the native menus, which fall back to the raw key
 * name: ugly, but legible and diagnosable. A blank window looks like a hang.
 *
 * WHY IT EXECUTES RATHER THAN GREPS:
 * A source-text check ("does i18n.js mention 'en'?") would pass on a cascade
 * that is written but never reached — which is exactly the failure it is meant
 * to catch. The stub below runs load(), resolves the stubbed fetches, and reads
 * the text the elements actually ended up with.
 *
 * The fetch counter matters as much as the text: a cascade that always fetches
 * three files would pass every text assertion while tripling the request count
 * for the 20 locales that need no fallback at all.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..', '..');
const I18N_JS = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'ui', 'i18n.js');
const LOCALES = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'data', 'locales');

const errors = [];

// ── A DOM stub, just wide enough for what i18n.js touches ───────────────────

/** One element carrying data-i18n attributes. */
function make_el(attrs, tag) {
	return {
		tagName: (tag || 'SPAN').toUpperCase(),
		_attrs: attrs,
		textContent: '',
		title: '',
		placeholder: '',
		getAttribute(name) {
			return Object.prototype.hasOwnProperty.call(this._attrs, name) ? this._attrs[name] : null;
		},
		querySelectorAll() {
			return [];
		}
	};
}

/**
 * Builds the sandbox a page would provide.
 * @param {object[]} elements Stub elements the selectors should return.
 * @param {object} locale_files code → string map (a code absent here 404s).
 * @param {string} active The window._i18n_locale value.
 */
function make_context(elements, locale_files, active) {
	const fetched = [];
	const document = {
		readyState: 'complete',
		currentScript: null,
		title: '',
		addEventListener() {},
		querySelectorAll(sel) {
			// The four selectors i18n.js uses, matched by the attribute they name.
			if (sel === '[data-i18n]') return elements.filter((e) => e.getAttribute('data-i18n') !== null);
			if (sel === '[data-i18n-title]')
				return elements.filter((e) => e.getAttribute('data-i18n-title') !== null);
			if (sel === '[data-i18n-placeholder]')
				return elements.filter((e) => e.getAttribute('data-i18n-placeholder') !== null);
			if (sel === 'select[data-i18n-option-prefix]')
				return elements.filter((e) => e.getAttribute('data-i18n-option-prefix') !== null);
			return [];
		}
	};

	const win = { _i18n_locale: active, __i18n_base: 'https://stub/locales/' };

	function fetch_stub(url) {
		const code = String(url).replace(/^.*\//, '').replace(/\.json$/, '');
		fetched.push(code);
		const body = locale_files[code];
		if (body === undefined) return Promise.resolve({ ok: false, json: () => Promise.resolve(null) });
		return Promise.resolve({ ok: true, json: () => Promise.resolve(body) });
	}

	const ctx = {
		window: win,
		document,
		fetch: fetch_stub,
		location: { href: 'https://stub/ui/page/index.html' },
		console: { warn() {}, log() {}, error() {} },
		Promise,
		Object,
		Array,
		String
	};
	ctx.globalThis = ctx;
	ctx.self = ctx;
	return { ctx, fetched, win };
}

/** Runs i18n.js in the sandbox and lets every stubbed promise settle. */
async function run(elements, locale_files, active) {
	const src = fs.readFileSync(I18N_JS, 'utf8');
	const { ctx, fetched, win } = make_context(elements, locale_files, active);
	vm.createContext(ctx);
	vm.runInContext(src, ctx, { filename: 'i18n.js' });
	// The cascade is at most chain-length deep; drain more turns than it can use.
	for (let i = 0; i < 12; i++) await Promise.resolve();
	return { fetched, strings: win._i18n_strings || {} };
}

function check(label, cond, detail) {
	if (!cond) errors.push(`${label}: ${detail}`);
}

(async () => {
	// ── 1. The shipped shape: an empty body, so a miss is invisible ───────────
	//
	// Guard the premise itself. If the pages ever gain inline fallback text, a
	// failed fetch stops being fatal and this whole gate is arguing about
	// something that no longer exists — better to know than to keep passing.
	const UI = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'ui');
	let total = 0;
	for (const d of fs.readdirSync(UI, { withFileTypes: true })) {
		if (!d.isDirectory()) continue;
		const f = path.join(UI, d.name, 'index.html');
		if (!fs.existsSync(f)) continue;
		const html = fs.readFileSync(f, 'utf8');
		for (const m of html.matchAll(/<(\w+)([^>]*\bdata-i18n="[^"]+"[^>]*)>([^<]*)</g)) {
			total++;
			void m;
		}
	}
	check(
		'premise',
		total > 100,
		`found only ${total} data-i18n element(s) in the shared webviews — the scan is broken`
	);

	// ── 2. A locale that does not load at all must not blank the page ─────────
	const els = () => [
		make_el({ 'data-i18n': 'k.one' }),
		make_el({ 'data-i18n': 'k.two' }),
		make_el({ 'data-i18n-title': 'k.tip' }),
		make_el({ 'data-i18n-placeholder': 'k.ph' })
	];

	const EN = { 'k.one': 'One', 'k.two': 'Two', 'k.tip': 'Tip', 'k.ph': 'Type…' };
	const FR = { 'k.one': 'Un', 'k.two': 'Deux', 'k.tip': 'Astuce', 'k.ph': 'Saisir…' };

	{
		const e = els();
		// "xx" is not shipped, so its fetch 404s — the original failure mode.
		const r = await run(e, { en: EN, fr: FR }, 'xx');
		check(
			'missing-locale',
			e[0].textContent === 'One' && e[1].textContent === 'Two',
			`an unshipped locale left the page blank instead of falling back to English ` +
				`(got "${e[0].textContent}" / "${e[1].textContent}"). This is the shipped bug: ` +
				`one failed fetch, 368 empty elements, no visible error.`
		);
		check(
			'missing-locale-attrs',
			e[2].title === 'Tip' && e[3].placeholder === 'Type…',
			`title/placeholder attributes did not fall back (got "${e[2].title}" / "${e[3].placeholder}")`
		);
	}

	// ── 3. A partial locale takes the fallback only for the keys it lacks ─────
	{
		const e = els();
		const partial = { 'k.one': 'Uno' };
		const r = await run(e, { es: partial, en: EN, fr: FR }, 'es');
		check(
			'partial-locale-keeps-active',
			e[0].textContent === 'Uno',
			`the active locale lost to its own fallback (got "${e[0].textContent}", expected "Uno") — ` +
				`the cascade must fill gaps, never overwrite`
		);
		check(
			'partial-locale-fills-gaps',
			e[1].textContent === 'Two' && e[2].title === 'Tip',
			`gaps were not filled from English (got "${e[1].textContent}" / "${e[2].title}")`
		);
		check(
			'partial-locale-order',
			r.fetched[0] === 'es' && r.fetched.indexOf('en') === 1,
			`fallback order was ${JSON.stringify(r.fetched)} — English must be consulted before French`
		);
	}

	// ── 4. A complete locale costs exactly one request ────────────────────────
	{
		const e = els();
		const r = await run(e, { de: { ...EN }, en: EN, fr: FR }, 'de');
		check(
			'complete-locale-single-fetch',
			r.fetched.length === 1 && r.fetched[0] === 'de',
			`a complete locale fetched ${JSON.stringify(r.fetched)} — it must stop at the active ` +
				`locale, or every one of the 21 pays three requests to fix a case that never happens`
		);
	}

	// ── 5. The chain never repeats the active locale ──────────────────────────
	{
		const e = els();
		// English active, and deliberately missing a key so the chain advances.
		const r = await run(e, { en: { 'k.one': 'One' }, fr: FR }, 'en');
		check(
			'no-duplicate-in-chain',
			r.fetched.filter((c) => c === 'en').length === 1,
			`"en" was fetched ${r.fetched.filter((c) => c === 'en').length} times (${JSON.stringify(r.fetched)}) — ` +
				`the active locale must not reappear as its own fallback`
		);
		check(
			'english-active-falls-to-french',
			e[1].textContent === 'Deux',
			`with English active and incomplete, French did not fill the gap (got "${e[1].textContent}")`
		);
	}

	// ── 6. The chain the code declares must be shipped ────────────────────────
	//
	// A cascade naming a locale that is not on disk is a cascade to nothing.
	for (const code of ['en', 'fr']) {
		check(
			'chain-locale-exists',
			fs.existsSync(path.join(LOCALES, `${code}.json`)),
			`the fallback chain names "${code}" but ${code}.json is not in _shared/data/locales/`
		);
	}

	if (errors.length > 0) {
		console.error('\x1b[31m[ERROR] Webview i18n cascade:\x1b[0m');
		for (const e of errors) console.error('    - ' + e);
		process.exit(1);
	}
	console.log(
		`\x1b[32m[OK] Webview i18n degrades to en → fr instead of a blank window ` +
			`(${total} data-i18n element(s) depend on it, none with inline text).\x1b[0m`
	);
})();
