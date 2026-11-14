// _shared/ui/layout_analysis/comparer_page.js

/**
 * ==============================================================================
 * MODULE: Layout Comparer Page
 * DESCRIPTION:
 * The « Comparer » tab of Ergopti Studio, the same page on ergopti.fr
 * (/studio/comparer) and in the app's Studio window: pick a corpus (built-in,
 * pasted, a file, or one the host provides such as the user's own keystats),
 * a keyboard and layouts; see the ranking, the global score chart, each
 * layout's contributions and finger load; edit every weight and watch the
 * ranking move. Everything runs in the page; no text leaves the device.
 *
 * FEATURES & RATIONALE:
 * 1. Instant: a corpus becomes n-gram tables once (cached by its hash);
 *    changing a weight re-scores without re-analysis.
 * 2. Host hook: a host may define window.LAYOUT_ANALYSIS_HOST before this
 *    script runs, with `corpora` ({id, title, tables}[], listed first and the
 *    first one selected) and `layouts` (library-shape layouts, e.g. the
 *    user's own from « Éditer »). The site defines none.
 * 3. Every visible string is a locale key (21 locales).
 * 4. Per-viewer conveniences (weights, selection, corpus, keyboard, the last
 *    pasted text's tables) are kept in localStorage when it is available;
 *    the page works the same without it.
 * ==============================================================================
 */

(function () {
	'use strict';

	const E = window.LAYOUT_ANALYSIS;
	const DATA = window.LAYOUT_ANALYSIS_DATA;
	const HOST = window.LAYOUT_ANALYSIS_HOST || {};
	const PREFIX = 'layout_analysis.';
	const STORAGE_KEY = 'ergopti.layout_analysis.v1';
	const CUSTOM_ID = 'custom';
	// The metrics shown as table columns; every metric is in the details.
	const TABLE_METRICS = [
		'sfb',
		'sfs',
		'lsb',
		'scissors',
		'roll_in',
		'roll_out',
		'alternation',
		'redirect',
		'redirect_bad',
		'home_row',
		'distance',
		'unsupported'
	];
	// Layouts ticked on a first visit: the registry and the two references.
	const DEFAULT_ORIGINS = ['registry', 'reference'];
	const CHART_MAX_BARS = 40;
	const TEXT_DEBOUNCE_MS = 400;

	// The site passes ?lang=<code>; i18n.js loads that locale, then English and French.
	const lang = new URLSearchParams(location.search).get('lang');
	if (lang && /^[a-z]{2}$/.test(lang)) window._i18n_locale = lang;

	// ============================
	// ======= 1/ Helpers =========
	// ============================

	/** Translates a locale key; an unknown key shows itself so the gap is visible. */
	function t(key, values) {
		const strings = window._i18n_strings || {};
		const full = PREFIX + key;
		let text = typeof strings[full] === 'string' ? strings[full] : full;
		for (const [name, value] of Object.entries(values || {}))
			text = text.split(`{${name}}`).join(String(value));
		return text;
	}

	/** Creates an element with a class and optional text. */
	function el(tag, className, text) {
		const node = document.createElement(tag);
		if (className) node.className = className;
		if (text !== undefined) node.textContent = text;
		return node;
	}

	const $ = (id) => document.getElementById(id);
	const format = (value, digits) =>
		Number(value).toLocaleString(window._i18n_locale || undefined, {
			minimumFractionDigits: digits,
			maximumFractionDigits: digits
		});
	const metricDigits = (id) => (E.METRICS[id].unit === 'mm' ? 1 : 2);

	/** Reads the saved conveniences; an unavailable storage gives none. */
	function loadSaved() {
		try {
			const raw = window.localStorage.getItem(STORAGE_KEY);
			return raw ? JSON.parse(raw) : {};
		} catch {
			return {};
		}
	}

	/** Saves the conveniences; an unavailable or full storage keeps none. */
	function save() {
		try {
			window.localStorage.setItem(
				STORAGE_KEY,
				JSON.stringify({
					corpus: state.corpus,
					keyboard: state.keyboard,
					selected: Array.from(state.selected),
					weights: state.weights,
					custom: state.custom
				})
			);
		} catch {
			// A private window or a full quota: the page keeps working unsaved.
		}
	}

	// ==========================
	// ======= 2/ State =========
	// ==========================

	const layouts = E.libraryLayouts().concat((HOST.layouts || []).map(E.layoutFromRows));
	const byId = new Map(layouts.map((layout) => [layout.id, layout]));
	const corpora = (HOST.corpora || [])
		.map((corpus) => ({ id: corpus.id, title: corpus.title, host: corpus }))
		.concat(DATA.corpora.map((corpus) => ({ id: corpus.id, title: corpus.title, builtin: corpus })))
		.concat([{ id: CUSTOM_ID }]);
	const saved = loadSaved();
	const state = {
		corpus: corpora.some((c) => c.id === saved.corpus) ? saved.corpus : corpora[0].id,
		keyboard: DATA.model.keyboards[saved.keyboard] ? saved.keyboard : 'iso',
		selected: new Set(
			Array.isArray(saved.selected)
				? saved.selected.filter((id) => byId.has(id))
				: layouts
						.filter((l) => DEFAULT_ORIGINS.includes(l.origin) || l.origin === 'user')
						.map((l) => l.id)
		),
		weights: Object.assign(E.defaultWeights(), validWeights(saved.weights)),
		custom: saved.custom && saved.custom.tables ? saved.custom : null,
		tables: null,
		results: [],
		sort: { key: 'rank', descending: false },
		details: null
	};
	if (HOST.corpora && HOST.corpora.length > 0 && saved.corpus === undefined)
		state.corpus = HOST.corpora[0].id;

	/** Keeps only the saved weights the engine still scores. */
	function validWeights(weights) {
		const out = {};
		const defaults = E.defaultWeights();
		for (const [id, value] of Object.entries(weights || {}))
			if (id in defaults && Number.isFinite(value) && value >= 0) out[id] = value;
		return out;
	}

	// ==========================
	// ======= 3/ Corpora =======
	// ==========================

	const loadedScripts = new Map();

	/** Loads a built-in corpus's generated tables once. */
	function loadScript(src) {
		if (!loadedScripts.has(src))
			loadedScripts.set(
				src,
				new Promise((resolve, reject) => {
					const script = document.createElement('script');
					script.src = src;
					script.onload = resolve;
					script.onerror = () => reject(new Error(src));
					document.head.append(script);
				})
			);
		return loadedScripts.get(src);
	}

	/** The prepared tables of the chosen corpus, or null when it has none yet. */
	async function corpusTables() {
		const corpus = corpora.find((c) => c.id === state.corpus);
		if (corpus.host) return E.prepareNgrams(corpus.host.tables);
		if (corpus.builtin) {
			await loadScript(corpus.builtin.script);
			return E.prepareNgrams(window.LAYOUT_ANALYSIS_CORPORA[corpus.id]);
		}
		return state.custom ? E.prepareNgrams(state.custom.tables) : null;
	}

	/** Reduces the user's text to tables, once per distinct text. */
	function useText(text) {
		const trimmed = text.trim();
		if (trimmed === '') {
			state.custom = null;
		} else {
			const hash = E.hashText(trimmed);
			if (!state.custom || state.custom.hash !== hash)
				state.custom = { hash, tables: E.ngramsFromText(trimmed) };
		}
		save();
		analyse();
	}

	// ==========================
	// ======= 4/ Analysis ======
	// ==========================

	let generation = 0;

	/** Analyses the selected layouts on the chosen corpus and redraws. */
	async function analyse() {
		const mine = ++generation;
		let tables;
		try {
			tables = await corpusTables();
		} catch {
			showStatus(t('status.corpus_failed'));
			return;
		}
		if (mine !== generation) return;
		state.tables = tables;
		const chosen = layouts.filter((layout) => state.selected.has(layout.id));
		if (!tables || chosen.length === 0) {
			state.results = [];
			showStatus(t('status.empty'));
			render();
			return;
		}
		const start = performance.now();
		state.results = E.compare(chosen, tables, { keyboard: state.keyboard, weights: state.weights });
		const ms = Math.round(performance.now() - start);
		showStatus(
			t('status.ready', {
				count: chosen.length,
				chars: format(tables.totalChars, 0),
				ms
			})
		);
		render();
	}

	/** Re-scores after a weight change, without re-analysis. */
	function rescore() {
		state.results = E.rescore(state.results, state.weights);
		save();
		render();
	}

	function showStatus(text) {
		$('la-status').textContent = text;
	}

	// ==========================
	// ======= 5/ Rendering =====
	// ==========================

	function render() {
		renderChart();
		renderTable();
		renderDetails();
	}

	/** Horizontal bars of the global score, best first. */
	function renderChart() {
		const box = $('la-chart');
		box.replaceChildren();
		const shown = state.results.slice(0, CHART_MAX_BARS);
		if (shown.length === 0) return;
		const totals = shown.map((r) => r.score.total);
		const min = Math.min(0, ...totals);
		const max = Math.max(0, ...totals);
		const span = max - min || 1;
		for (const result of shown) {
			const row = el('div', 'la-chart-row');
			row.append(el('span', 'la-chart-label', result.layout.name));
			const track = el('span', 'la-chart-track');
			const bar = el('span', result.score.total >= 0 ? 'la-bar la-bar-good' : 'la-bar la-bar-bad');
			const zero = ((0 - min) / span) * 100;
			const end = ((result.score.total - min) / span) * 100;
			bar.style.left = `${Math.min(zero, end)}%`;
			bar.style.width = `${Math.abs(end - zero)}%`;
			track.append(bar);
			row.append(track, el('span', 'la-chart-value', format(result.score.total, 1)));
			row.addEventListener('click', () => showDetails(result.layout.id));
			box.append(row);
		}
	}

	/** The ranking table, sortable by any column. */
	function renderTable() {
		const table = $('la-table');
		table.replaceChildren();
		if (state.results.length === 0) return;
		const columns = [
			{ key: 'rank', label: t('table.rank'), value: (r) => r.rank },
			{ key: 'name', label: t('table.layout'), value: (r) => r.layout.name },
			{ key: 'score', label: t('table.score'), value: (r) => r.score.total, digits: 1 }
		].concat(
			TABLE_METRICS.map((id) => ({
				key: id,
				label: t(`metric.${id}`),
				value: (r) => r.metrics[id],
				digits: metricDigits(id)
			}))
		);
		const head = el('tr');
		for (const column of columns) {
			const th = el('th', 'la-sortable', column.label);
			th.scope = 'col';
			if (state.sort.key === column.key)
				th.setAttribute('aria-sort', state.sort.descending ? 'descending' : 'ascending');
			th.addEventListener('click', () => {
				state.sort =
					state.sort.key === column.key
						? { key: column.key, descending: !state.sort.descending }
						: { key: column.key, descending: column.key === 'score' };
				renderTable();
			});
			head.append(th);
		}
		const thead = el('thead');
		thead.append(head);
		const sortColumn = columns.find((c) => c.key === state.sort.key);
		const rows = state.results.slice().sort((a, b) => {
			const x = sortColumn.value(a);
			const y = sortColumn.value(b);
			const order = typeof x === 'string' ? x.localeCompare(y) : x - y;
			return state.sort.descending ? -order : order;
		});
		const tbody = el('tbody');
		for (const result of rows) {
			const tr = el('tr');
			if (state.details === result.layout.id) tr.className = 'la-selected';
			for (const column of columns) {
				const value = column.value(result);
				tr.append(
					el('td', '', column.digits === undefined ? String(value) : format(value, column.digits))
				);
			}
			tr.addEventListener('click', () => showDetails(result.layout.id));
			tbody.append(tr);
		}
		table.append(thead, tbody);
	}

	function showDetails(id) {
		state.details = id;
		render();
		$('la-details').scrollIntoView({ block: 'nearest' });
	}

	/** Bars around zero: one per entry, labelled, signed. */
	function signedBars(box, entries, digits) {
		box.replaceChildren();
		const extent = Math.max(...entries.map(([, v]) => Math.abs(v)), 1e-9);
		for (const [label, value] of entries) {
			const row = el('div', 'la-chart-row');
			row.append(el('span', 'la-chart-label', label));
			const track = el('span', 'la-chart-track la-signed');
			const bar = el('span', value >= 0 ? 'la-bar la-bar-good' : 'la-bar la-bar-bad');
			const width = (Math.abs(value) / extent) * 50;
			bar.style.left = value >= 0 ? '50%' : `${50 - width}%`;
			bar.style.width = `${width}%`;
			track.append(bar);
			row.append(track, el('span', 'la-chart-value', format(value, digits)));
			box.append(row);
		}
	}

	/** One layout's contributions, finger load and every metric. */
	function renderDetails() {
		const section = $('la-details');
		const result = state.results.find((r) => r.layout.id === state.details);
		section.hidden = !result;
		if (!result) return;
		$('la-details-title').textContent = t('details.title', {
			layout: result.layout.name,
			rank: result.rank
		});
		const contributions = Object.entries(result.score.contributions)
			.filter(([, v]) => v !== 0)
			.sort((a, b) => Math.abs(b[1]) - Math.abs(a[1]))
			.map(([id, v]) => [t(`metric.${id}`), v]);
		signedBars($('la-contributions'), contributions, 1);
		signedBars(
			$('la-fingers'),
			DATA.model.fingers.map((id) => [t(`finger.${id}`), result.fingers[id]]),
			1
		);
		const table = $('la-metrics');
		table.replaceChildren();
		for (const id of Object.keys(E.METRICS)) {
			const tr = el('tr');
			const th = el('th', '', t(`metric.${id}`));
			th.scope = 'row';
			const unit = E.METRICS[id].unit === 'mm' ? t('unit.mm') : '%';
			tr.append(th, el('td', '', `${format(result.metrics[id], metricDigits(id))} ${unit}`));
			table.append(tr);
		}
		const missing = Object.entries(result.coverage.unsupportedChars)
			.sort((a, b) => b[1] - a[1])
			// An invisible character is named by its code point.
			.map(([char]) =>
				/^[\s\p{C}]$/u.test(char)
					? `U+${char.codePointAt(0).toString(16).toUpperCase().padStart(4, '0')}`
					: char
			)
			.join(' ');
		$('la-unsupported').textContent = missing ? t('details.unsupported', { chars: missing }) : '';
	}

	// ===========================
	// ======= 6/ Controls =======
	// ===========================

	function fillCorpora() {
		const select = $('la-corpus');
		select.replaceChildren();
		for (const corpus of corpora) {
			const option = el('option', '', corpus.id === CUSTOM_ID ? t('corpus.custom') : corpus.title);
			option.value = corpus.id;
			select.append(option);
		}
		select.value = state.corpus;
		showCorpusInfo();
	}

	function showCorpusInfo() {
		const corpus = corpora.find((c) => c.id === state.corpus);
		$('la-custom').hidden = corpus.id !== CUSTOM_ID;
		$('la-corpus-info').textContent = corpus.builtin
			? t('corpus.info', {
					chars: format(corpus.builtin.characters, 0),
					licence: corpus.builtin.licence,
					source: corpus.builtin.source
				})
			: corpus.host
				? t('corpus.private')
				: t('corpus.local');
	}

	function fillLayouts() {
		const list = $('la-layout-list');
		list.replaceChildren();
		const filter = $('la-filter').value.trim().toLowerCase();
		for (const layout of layouts) {
			if (filter && !layout.name.toLowerCase().includes(filter) && !layout.id.includes(filter))
				continue;
			const label = el('label', 'la-layout');
			const box = el('input');
			box.type = 'checkbox';
			box.checked = state.selected.has(layout.id);
			box.addEventListener('change', () => {
				if (box.checked) state.selected.add(layout.id);
				else state.selected.delete(layout.id);
				save();
				analyse();
			});
			label.append(box, el('span', '', layout.name));
			list.append(label);
		}
	}

	function fillWeights() {
		const list = $('la-weight-list');
		list.replaceChildren();
		for (const id of Object.keys(E.defaultWeights())) {
			const label = el('label', 'la-weight');
			label.append(el('span', '', t(`metric.${id}`)));
			const input = el('input');
			input.type = 'number';
			input.min = '0';
			input.step = 'any';
			input.value = String(state.weights[id]);
			input.addEventListener('input', () => {
				const value = Number(input.value);
				if (input.value === '' || !Number.isFinite(value) || value < 0) {
					input.setAttribute('aria-invalid', 'true');
					return;
				}
				input.removeAttribute('aria-invalid');
				state.weights[id] = value;
				rescore();
			});
			label.append(input);
			list.append(label);
		}
	}

	function visibleLayoutIds() {
		const filter = $('la-filter').value.trim().toLowerCase();
		return layouts
			.filter((l) => !filter || l.name.toLowerCase().includes(filter) || l.id.includes(filter))
			.map((l) => l.id);
	}

	function bind() {
		$('la-corpus').addEventListener('change', (event) => {
			state.corpus = event.target.value;
			showCorpusInfo();
			save();
			analyse();
		});
		$('la-keyboard').value = state.keyboard;
		$('la-keyboard').addEventListener('change', (event) => {
			state.keyboard = event.target.value;
			save();
			analyse();
		});
		let timer = null;
		$('la-text').addEventListener('input', (event) => {
			clearTimeout(timer);
			timer = setTimeout(() => useText(event.target.value), TEXT_DEBOUNCE_MS);
		});
		$('la-file').addEventListener('change', async (event) => {
			const file = event.target.files && event.target.files[0];
			const error = $('la-file-error');
			error.hidden = true;
			if (!file) return;
			try {
				const text = await window.LAYOUT_ANALYSIS_FILES.readText(file);
				$('la-text').value = text;
				useText(text);
			} catch (failure) {
				error.textContent =
					failure.code === 'file_unsupported'
						? t('corpus.file_unsupported')
						: t('corpus.file_unreadable');
				error.hidden = false;
			}
		});
		$('la-filter').addEventListener('input', fillLayouts);
		$('la-all').addEventListener('click', () => {
			for (const id of visibleLayoutIds()) state.selected.add(id);
			save();
			fillLayouts();
			analyse();
		});
		$('la-none').addEventListener('click', () => {
			for (const id of visibleLayoutIds()) state.selected.delete(id);
			save();
			fillLayouts();
			analyse();
		});
		$('la-restore').addEventListener('click', () => {
			state.weights = E.defaultWeights();
			fillWeights();
			rescore();
		});
		// Dynamic labels follow the strings, whenever they land.
		document.addEventListener('i18n:applied', () => {
			fillCorpora();
			fillWeights();
			render();
			analyse();
		});
	}

	function start() {
		fillCorpora();
		fillLayouts();
		fillWeights();
		bind();
		analyse();
	}

	if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
	else start();
})();
