// src/lib/js/driverWindowHost.js
//
// Plays the native host's role for the driver's real webview windows when
// they are embedded outside the driver: the website's /ergopti-plus page and
// the promo video under video/. Both import this module so the demo data and
// the injection contracts exist once.
//
// The windows are the same HTML/JS/CSS bundles the drivers open natively,
// served as-is from static/ergopti_plus/_shared/ui/<id>/. Injection goes
// through the entry points the drivers call (i18n_apply, initData,
// injectModels), so an embedded window can never diverge from the real UI.

/** Locales the demo datasets below are written in. */
export const DEMO_LOCALES = ['fr', 'en'];

/** Retry interval and cap for the dashboard chart nudge. */
const NUDGE_INTERVAL_MS = 600;
const NUDGE_MAX_TRIES = 20;

// Demo identity shown in the personal windows, per locale.
const DEMO_PEOPLE = {
	fr: {
		signature: 'Cordialement,\nAdrien',
		email: 'adrien@exemple.fr',
		sections: { signatures: 'Signatures', work: 'Travail' },
		labels: {
			first_name: 'Prénom',
			last_name: 'Nom',
			email: 'E-mail',
			phone: 'Téléphone',
			address: 'Adresse',
			iban: 'IBAN'
		}
	},
	en: {
		signature: 'Best regards,\nAdrien',
		email: 'adrien@example.com',
		sections: { signatures: 'Signatures', work: 'Work' },
		labels: {
			first_name: 'First name',
			last_name: 'Last name',
			email: 'Email',
			phone: 'Phone',
			address: 'Address',
			iban: 'IBAN'
		}
	}
};

const DEMO_PHONE = '+33 6 12 34 56 78';
const DEMO_ADDRESS = '15 rue Lafayette, 75009 Paris';
const DEMO_IBAN = 'FR76 1234 5678 9012 3456 789';

/**
 * Return the demo identity for a locale, failing on an unsupported one so a
 * caller never renders a half-translated window.
 * @param {string} locale
 * @returns {typeof DEMO_PEOPLE.en}
 */
function demoPerson(locale) {
	const person = DEMO_PEOPLE[locale];
	if (!person) throw new Error(`No driver demo data for locale "${locale}"`);
	return person;
}

/**
 * URL of a driver window. The two dashboards support a bridge-less bootstrap:
 * a "#prefetch=<url>" hash makes them load the synthetic demo blob shipped
 * under static/demo/ (see tools/dev/gen-demo-metrics.cjs).
 * @param {string} id - Window id, a folder name under _shared/ui/.
 * @param {string} [base] - URL prefix under which static/ is served.
 * @returns {string}
 */
export function driverWindowSrc(id, base = '') {
	const page = `${base}/ergopti_plus/_shared/ui/${id}/index.html`;
	return id.startsWith('metrics_') ? `${page}#prefetch=${base}/demo/${id}_prefetch.json` : page;
}

// One fetch of each locale's strings, shared by every embedded window.
/** @type {Map<string, Promise<Record<string, string>>>} */
const stringsCache = new Map();

/**
 * Fetch (once) the driver's locale strings.
 * @param {string} base
 * @param {string} locale
 * @returns {Promise<Record<string, string>>}
 */
function localeStrings(base, locale) {
	const key = `${base}|${locale}`;
	if (!stringsCache.has(key)) {
		stringsCache.set(
			key,
			fetch(`${base}/ergopti_plus/_shared/data/locales/${locale}.json`).then((r) => {
				if (!r.ok) throw new Error(`Locale ${locale} unavailable: HTTP ${r.status}`);
				return r.json();
			})
		);
	}
	return stringsCache.get(key);
}

/**
 * Parse a "30.53B" / "350M" parameter string into billions.
 * @param {unknown} raw
 * @returns {number}
 */
function parseParams(raw) {
	if (typeof raw !== 'string' || raw === '') return 0;
	const m = raw.match(/([\d.]+)\s*([BMK]?)/i);
	if (!m) return 0;
	const value = parseFloat(m[1]);
	const unit = (m[2] || 'B').toUpperCase();
	if (unit === 'B') return value;
	if (unit === 'M') return value / 1000;
	return value;
}

/**
 * Feed the model browser with the real catalog, exactly like the native
 * hosts do: flatten models.json into injectModels() rows.
 * @param {Window} win
 * @param {string} base
 * @param {string} locale
 */
async function injectModelBrowser(win, base, locale) {
	win.i18n_apply?.(await localeStrings(base, locale));
	const res = await fetch(`${base}/ergopti_plus/_shared/modules/llm/models.json`);
	if (!res.ok) throw new Error(`Model catalog unavailable: HTTP ${res.status}`);
	const catalog = await res.json();
	const models = [];
	for (const provider of catalog) {
		for (const family of provider.families ?? []) {
			for (const m of family.models ?? []) {
				const total = parseParams(m.parameters?.total);
				const activeB = parseParams(m.parameters?.active);
				models.push({
					name: m.name,
					family: family.label,
					provider: provider.label,
					params_b: total,
					active_b: activeB,
					is_moe: activeB > 0 && activeB < total,
					ram_gb:
						m.hardware_requirements?.ollama?.ram_gb ?? m.hardware_requirements?.mlx?.ram_gb ?? 0,
					speed_tok_s: m.capabilities?.speed_tok_s ?? 0,
					type: m.type || 'chat',
					installed: false,
					url: m.urls?.hf || ''
				});
			}
		}
	}
	const defaultModel = models.find((m) => /qwen/i.test(m.name)) ?? models[0];
	if (defaultModel) defaultModel.installed = true;
	win.injectModels?.({ backend: 'ollama', active: defaultModel?.name ?? '', models });
}

/**
 * @typedef {{
 *   trigger: string,
 *   output: string,
 *   is_word: boolean,
 *   auto_expand: boolean,
 *   is_case_sensitive: boolean,
 *   final_result: boolean
 * }} HotstringEntry
 * @typedef {{
 *   trigger_char: string,
 *   star: string,
 *   compact_view: boolean,
 *   auto_close: boolean,
 *   open_mode: string,
 *   sections: Array<{name: string, description: string, _exp: boolean, entries: HotstringEntry[]}>
 * }} HotstringEditorData
 */

/**
 * The hotstring editor's demo dataset, in the shape of its initData()
 * contract. Exported so a caller can show the same rows elsewhere.
 * @param {string} locale
 * @returns {HotstringEditorData}
 */
export function hotstringEditorDemo(locale) {
	const person = demoPerson(locale);
	const entry = (trigger, output) => ({
		trigger,
		output,
		is_word: false,
		auto_expand: false,
		is_case_sensitive: false,
		final_result: false
	});
	return {
		trigger_char: '★',
		star: '★',
		compact_view: false,
		auto_close: false,
		open_mode: 'menu',
		sections: [
			{
				name: 'signatures',
				description: person.sections.signatures,
				_exp: true,
				entries: [
					entry('sig★', person.signature),
					entry('np★', 'Adrien Moyaux'),
					entry('em★', person.email)
				]
			},
			{
				name: 'work',
				description: person.sections.work,
				_exp: true,
				entries: [entry('adr★', DEMO_ADDRESS), entry('iban★', DEMO_IBAN), entry('tel★', DEMO_PHONE)]
			}
		]
	};
}

/**
 * Feed the personal-info editor with demo fields and the locale strings so
 * its chrome labels render. Every edit is reported to onInfoChange, so the
 * caller can rebuild dynamic-hotstring examples live.
 * @param {Window} win
 * @param {string} base
 * @param {string} locale
 * @param {((fields: Record<string, string>) => void) | null} onInfoChange
 */
async function injectPersonalInfo(win, base, locale, onInfoChange) {
	const strings = await localeStrings(base, locale);
	const person = demoPerson(locale);
	const values = {
		first_name: 'Adrien',
		last_name: 'Moyaux',
		email: person.email,
		phone: DEMO_PHONE,
		address: DEMO_ADDRESS,
		iban: DEMO_IBAN
	};
	win.initData?.({
		strings,
		fields: Object.entries(values).map(([key, value]) => ({
			key,
			label: person.labels[key],
			value
		}))
	});

	if (onInfoChange) {
		const rows = win.document.getElementById('rows');
		rows?.addEventListener('input', () => {
			const edited = {};
			rows.querySelectorAll('input').forEach((inp) => {
				edited[inp.getAttribute('name')] = inp.value;
			});
			onInfoChange(edited);
		});
	}
}

/**
 * Poll until a condition holds.
 * @param {() => unknown} ready
 * @param {string} what - Described in the timeout error.
 * @returns {Promise<void>}
 */
function waitFor(ready, what) {
	return new Promise((resolve, reject) => {
		let tries = 0;
		const timer = setInterval(() => {
			tries++;
			if (ready()) {
				clearInterval(timer);
				resolve();
			} else if (tries >= NUDGE_MAX_TRIES) {
				clearInterval(timer);
				reject(new Error(`${what} never happened`));
			}
		}, NUDGE_INTERVAL_MS);
	});
}

/**
 * Bring a dashboard to its rendered state, each through its own entry point.
 * - metrics_typing loads Chart.js with defer; when the prefetch JSON (local,
 *   fast) resolves first, render_charts() early-returns and the charts stay
 *   empty until a filter interaction. apply_local_filters() is a global,
 *   idempotent re-render; calling it after Chart.js lands closes the race.
 * - metrics_apps loads Chart.js synchronously and renders as soon as its
 *   prefetch blob is bootstrapped; renderDashboard() records the aggregate.
 * @param {Window} win
 * @param {string} id
 * @param {{animate?: boolean}} options - animate false freezes the charts in
 *   their final state, for frame-by-frame capture.
 * @returns {Promise<void>} Resolves once the charts are drawn.
 */
async function renderMetricsCharts(win, id, { animate = true } = {}) {
	const rerender = metricsRerender(win, id);
	await waitFor(rerender.ready, `${id} rendering`);
	if (!animate) win.Chart.defaults.animation = false;
	rerender.run();
}

/**
 * The idempotent re-render entry point of a metrics dashboard.
 * @param {Window} win
 * @param {string} id
 * @returns {{ready: () => unknown, run: () => void}}
 */
function metricsRerender(win, id) {
	return id === 'metrics_apps'
		? {
				ready: () => win._lastAggData && typeof win.renderDashboard === 'function',
				// The category chips are built once at boot; rebuild them so
				// they pick up strings injected after the page loaded.
				run: () => {
					win.rebuildFilterButtons();
					win.renderDashboard();
				}
			}
		: {
				ready: () =>
					win.Chart &&
					typeof win.apply_local_filters === 'function' &&
					typeof win.render_charts === 'function',
				// The speed card is drawn once; redraw it too so its unit picks
				// up strings injected after the page loaded. apply_local_filters()
				// skips the charts when its projection is cached, so charts built
				// before the strings landed would keep raw legend keys:
				// render_charts() rebuilds them with the current strings.
				run: () => {
					win.recompute_speed_kpi();
					win.apply_local_filters();
					win.render_charts();
				}
			};
}

/**
 * Bring a populated window to one final state, whatever order its own
 * asynchronous work ran in. A dashboard may draw its charts from its own data
 * before the host's strings and layout land (raw legend keys, half-height
 * canvases), and canvas redraws leave no trace in the DOM to wait on; call
 * this once the window has gone idle, so every capture of it is identical.
 * @param {Window} win - The window's contentWindow.
 * @param {string} id - Window id.
 */
export function settleDriverWindow(win, id) {
	if (id.startsWith('metrics_')) metricsRerender(win, id).run();
	const instances = win.Chart?.instances;
	for (const chart of instances ? Object.values(instances) : []) {
		chart.resize();
		chart.update('none');
	}
}

/**
 * Populate a loaded driver window through the entry point the driver uses
 * for it.
 * @param {Window} win - The window's contentWindow (same origin).
 * @param {string} id - Window id, a folder name under _shared/ui/.
 * @param {{
 *   base?: string,
 *   locale?: string,
 *   animate?: boolean,
 *   onInfoChange?: ((fields: Record<string, string>) => void) | null
 * }} [options]
 * @returns {Promise<void>} Resolves once the window shows its data.
 */
export async function hostDriverWindow(
	win,
	id,
	{ base = '', locale = 'fr', animate = true, onInfoChange = null } = {}
) {
	if (id === 'model_browser') return injectModelBrowser(win, base, locale);
	if (id === 'hotstring_editor') {
		win.i18n_apply?.(await localeStrings(base, locale));
		win.initData?.(hotstringEditorDemo(locale));
		return;
	}
	if (id === 'personal_info_editor') return injectPersonalInfo(win, base, locale, onInfoChange);
	if (id.startsWith('metrics_')) {
		win.i18n_apply?.(await localeStrings(base, locale));
		return renderMetricsCharts(win, id, { animate });
	}
	// changelog needs nothing: it self-bootstraps from GitHub.
}
