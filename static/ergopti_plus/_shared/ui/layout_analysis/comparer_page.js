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
 *    pasted text's tables, the layouts imported from files) are kept in
 *    localStorage when it is available; the page works the same without it.
 * 5. A layout file of any common format (layout_formats.js) joins the
 *    comparison; what it could not read is listed.
 * 6. Framed by the site, it posts its height to the parent
 *    ({type: 'ergopti-layout-analysis:height', height}) on load and resize.
 * 7. Late host data: the app's 'studio-ngrams' event (or
 *    LAYOUT_ANALYSIS_COMPARER.setCorpus) adds « My typing » and selects it;
 *    LAYOUT_ANALYSIS_COMPARER.addLayouts adds personal layouts; a host
 *    `store` ({list, save, remove}, promises) keeps imported layouts instead
 *    of localStorage.
 * 8. Every metric and sourced value has an « i » button: its popover says
 *    where the value comes from and links the sources (DATA.sources, from
 *    sources.json). A host may define LAYOUT_ANALYSIS_HOST.openLink(url) to
 *    open links itself (the app's browser); otherwise they open a new tab.
 * 9. The ideal finger load of finger_imbalance is editable (eight targets
 *    summing to 100 %), kept with the other conveniences.
 * ==============================================================================
 */

(function () {
	'use strict';

	const E = window.LAYOUT_ANALYSIS;
	const DATA = window.LAYOUT_ANALYSIS_DATA;
	const HOST = window.LAYOUT_ANALYSIS_HOST || {};
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
	// Size of one key unit of the heatmap, in pixels.
	const HEAT_UNIT_PX = 44;
	const TEXT_DEBOUNCE_MS = 400;
	// The « i » popover: its widest size and its gap to the window's edges.
	const POPOVER_WIDTH_PX = 360;
	const POPOVER_GUTTER_PX = 12;
	// The message the framing page listens for to size its frame.
	const HEIGHT_MESSAGE = 'ergopti-layout-analysis:height';
	// The app's keystats n-grams: the event its Studio window dispatches and the
	// corpus id they take (the default corpus in the app, maintainer 2026-11-14).
	const NGRAMS_EVENT = 'studio-ngrams';
	const MY_TYPING_ID = 'my_typing';

	// The site passes ?lang=<code>; i18n.js loads that locale, then English and French.
	const lang = new URLSearchParams(location.search).get('lang');
	if (lang && /^[a-z]{2}$/.test(lang)) window._i18n_locale = lang;

	// ============================
	// ======= 1/ Helpers =========
	// ============================

	/** Translates a locale key; an unknown key shows itself so the gap is visible. */
	function t(key, values) {
		const strings = window._i18n_strings || {};
		let text = typeof strings[key] === 'string' ? strings[key] : key;
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
					idealLoad: state.idealLoad,
					custom: state.custom,
					imported
				})
			);
		} catch {
			// A private window or a full quota: the page keeps working unsaved.
		}
	}

	// ==========================
	// ======= 2/ State =========
	// ==========================

	const saved = loadSaved();
	// Layouts the user imported from files, kept with the other conveniences.
	const imported = Array.isArray(saved.imported) ? saved.imported.filter(isLayout) : [];
	const layouts = E.libraryLayouts()
		.concat((HOST.layouts || []).map(E.layoutFromRows))
		.concat(imported.map(E.layoutFromRows));
	const byId = new Map(layouts.map((layout) => [layout.id, layout]));
	const corpora = (HOST.corpora || [])
		.map((corpus) => ({ id: corpus.id, title: corpus.title, host: corpus }))
		.concat(DATA.corpora.map((corpus) => ({ id: corpus.id, title: corpus.title, builtin: corpus })))
		.concat([{ id: CUSTOM_ID }]);
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
		idealLoad: validIdealLoad(saved.idealLoad),
		custom: saved.custom && saved.custom.tables ? saved.custom : null,
		tables: null,
		results: [],
		sort: { key: 'rank', descending: false },
		heat: 'presses',
		details: null
	};
	if (HOST.corpora && HOST.corpora.length > 0 && saved.corpus === undefined)
		state.corpus = HOST.corpora[0].id;

	/** Whether a saved value still reads as a layout. */
	function isLayout(value) {
		try {
			E.layoutFromRows(value);
			return true;
		} catch {
			return false;
		}
	}

	/** Keeps only the saved weights the engine still scores. */
	function validWeights(weights) {
		const out = {};
		const defaults = E.defaultWeights();
		for (const [id, value] of Object.entries(weights || {}))
			if (id in defaults && Number.isFinite(value) && value >= 0) out[id] = value;
		return out;
	}

	/** The saved ideal finger load when the engine still accepts it, else the default. */
	function validIdealLoad(load) {
		if (!load) return E.defaultIdealLoad();
		try {
			return Object.assign({}, E.idealLoad(load));
		} catch {
			return E.defaultIdealLoad();
		}
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
			showStatus(t('layout_analysis.status.corpus_failed'));
			return;
		}
		if (mine !== generation) return;
		state.tables = tables;
		const chosen = layouts.filter((layout) => state.selected.has(layout.id));
		if (!tables || chosen.length === 0) {
			state.results = [];
			showStatus(t('layout_analysis.status.empty'));
			render();
			return;
		}
		const start = performance.now();
		state.results = E.compare(chosen, tables, {
			keyboard: state.keyboard,
			weights: state.weights,
			idealLoad: state.idealLoad
		});
		const ms = Math.round(performance.now() - start);
		showStatus(
			t('layout_analysis.status.ready', {
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
			{ key: 'rank', label: t('layout_analysis.table.rank'), value: (r) => r.rank },
			{ key: 'name', label: t('layout_analysis.table.layout'), value: (r) => r.layout.name },
			{
				key: 'score',
				label: t('layout_analysis.table.score'),
				value: (r) => r.score.total,
				digits: 1
			}
		].concat(
			TABLE_METRICS.map((id) => ({
				key: id,
				label: t(`layout_analysis.metric.${id}`),
				value: (r) => r.metrics[id],
				digits: metricDigits(id)
			}))
		);
		const head = el('tr');
		for (const column of columns) {
			const th = el('th', 'la-sortable', column.label);
			th.scope = 'col';
			if (DATA.sources.items[column.key]) th.append(' ', infoButton(column.key));
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

	/**
	 * The board of the chosen keyboard, each key showing the layout's base
	 * character and coloured from green to red by its share of the chosen
	 * per-key value (presses or a bad event); the tooltip gives the value and,
	 * for SFBs, the worst partners.
	 */
	function renderHeatmap(result) {
		const box = $('la-heatmap');
		box.replaceChildren();
		const board = E.keyboard(result.keyboard);
		const layout = byId.get(result.layout.id);
		const modifiers = new Set(Object.values(DATA.model.modifier_keys));
		const values = board.codes.map((code) => result.keys[code][state.heat]);
		const max = Math.max(...values, 1e-9);
		const minX = Math.min(...board.x) - 0.5;
		const maxX = Math.max(...board.x) + 0.5;
		const maxY = Math.max(...board.y);
		box.style.width = `${(maxX - minX) * HEAT_UNIT_PX}px`;
		box.style.height = `${maxY * HEAT_UNIT_PX}px`;
		board.codes.forEach((code, k) => {
			if (modifiers.has(code)) return;
			const row = layout.rows[code];
			const base = row && typeof row[0] === 'string' ? row[0] : row && row[0] ? '◌' : '';
			const key = el('span', 'la-key', code === 'Space' ? '␣' : base);
			const share = values[k] / max;
			key.style.left = `${(board.x[k] - 0.5 - minX) * HEAT_UNIT_PX}px`;
			key.style.top = `${(board.y[k] - 1) * HEAT_UNIT_PX}px`;
			key.style.width = `${(code === 'Space' ? 6 : 1) * HEAT_UNIT_PX - 4}px`;
			if (code === 'Space') key.style.left = `${(board.x[k] - 3 - minX) * HEAT_UNIT_PX}px`;
			key.style.background = `color-mix(in srgb, var(--la-bad) ${Math.round(share * 100)}%, var(--la-good))`;
			const partners = (result.keys[code].sfbWith || [])
				.map(([other, pct]) => `${(layout.rows[other] || [''])[0] || other} ${format(pct, 2)} %`)
				.join(', ');
			key.title = `${t(`layout_analysis.heat.${state.heat}`)}: ${format(values[k], 2)} %${
				state.heat === 'sfb' && partners ? ` (${partners})` : ''
			}`;
			box.append(key);
		});
	}

	/** One layout's contributions, finger load and every metric. */
	function renderDetails() {
		const section = $('la-details');
		const result = state.results.find((r) => r.layout.id === state.details);
		section.hidden = !result;
		if (!result) return;
		$('la-details-title').textContent = t('layout_analysis.details.title', {
			layout: result.layout.name,
			rank: result.rank
		});
		const layout = byId.get(result.layout.id);
		const credit = $('la-details-credit');
		credit.textContent =
			layout.authors.length > 0
				? t('layout_analysis.details.by', { authors: layout.authors.join(', ') })
				: layout.source
					? t('layout_analysis.details.from', { source: layout.source })
					: '';
		const link = $('la-details-link');
		link.hidden = !layout.url;
		link.href = layout.url || '#';
		link.textContent = layout.url;
		routeLink(link);
		renderHeatmap(result);
		const contributions = Object.entries(result.score.contributions)
			.filter(([, v]) => v !== 0)
			.sort((a, b) => Math.abs(b[1]) - Math.abs(a[1]))
			.map(([id, v]) => [t(`layout_analysis.metric.${id}`), v]);
		signedBars($('la-contributions'), contributions, 1);
		signedBars(
			$('la-fingers'),
			DATA.model.fingers.map((id) => [t(`layout_analysis.finger.${id}`), result.fingers[id]]),
			1
		);
		const table = $('la-metrics');
		table.replaceChildren();
		for (const id of Object.keys(E.METRICS)) {
			const tr = el('tr');
			const th = el('th', '', t(`layout_analysis.metric.${id}`));
			th.scope = 'row';
			th.append(' ', infoButton(id));
			if (id === 'shortcut_left') th.append(' ', infoButton('shortcut_letters'));
			const unit = E.METRICS[id].unit === 'mm' ? t('layout_analysis.unit.mm') : '%';
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
		$('la-unsupported').textContent = missing
			? t('layout_analysis.details.unsupported', { chars: missing })
			: '';
	}

	// ===========================
	// ======= 6/ Controls =======
	// ===========================

	function fillCorpora() {
		const select = $('la-corpus');
		select.replaceChildren();
		for (const corpus of corpora) {
			const label =
				corpus.id === CUSTOM_ID
					? t('layout_analysis.corpus.custom')
					: corpus.id === MY_TYPING_ID && !corpus.title
						? t('layout_analysis.corpus.my_typing')
						: corpus.title;
			const option = el('option', '', label);
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
			? t('layout_analysis.corpus.info', {
					chars: format(corpus.builtin.characters, 0),
					licence: corpus.builtin.licence,
					source: corpus.builtin.source
				})
			: corpus.host
				? t('layout_analysis.corpus.private')
				: t('layout_analysis.corpus.local');
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
			const name = el('span', '', t(`layout_analysis.metric.${id}`));
			name.append(' ', infoButton(id));
			label.append(name);
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

	function fillIdealLoad() {
		const list = $('la-ideal-list');
		list.replaceChildren();
		const inputs = {};
		const showSum = () => {
			const sum = Object.keys(inputs).reduce((total, id) => total + Number(inputs[id].value), 0);
			const box = $('la-ideal-sum');
			box.textContent = t('layout_analysis.ideal.sum', { sum: format(sum, 1) });
			let load;
			try {
				load = E.idealLoad(
					Object.fromEntries(
						Object.keys(inputs).map((id) => [
							id,
							inputs[id].value === '' ? NaN : Number(inputs[id].value)
						])
					)
				);
			} catch {
				box.className = 'la-error';
				for (const input of Object.values(inputs)) input.setAttribute('aria-invalid', 'true');
				return;
			}
			box.className = 'la-muted';
			for (const input of Object.values(inputs)) input.removeAttribute('aria-invalid');
			state.idealLoad = Object.assign({}, load);
			save();
			analyse();
		};
		for (const id of Object.keys(E.defaultIdealLoad())) {
			const label = el('label', 'la-weight');
			label.append(el('span', '', t(`layout_analysis.finger.${id}`)));
			const input = el('input');
			input.type = 'number';
			input.min = '0';
			input.max = '100';
			input.step = 'any';
			input.value = String(state.idealLoad[id]);
			input.addEventListener('input', showSum);
			inputs[id] = input;
			label.append(input);
			list.append(label);
		}
		$('la-ideal-sum').textContent = t('layout_analysis.ideal.sum', {
			sum: format(
				Object.values(state.idealLoad).reduce((a, b) => a + b, 0),
				1
			)
		});
	}

	// ==========================
	// ======= Info popovers ====
	// ==========================

	let popoverOwner = null;

	/** An « i » button that opens the sources of one metric or value. */
	function infoButton(item) {
		const button = el('button', 'la-info', 'i');
		button.type = 'button';
		button.dataset.info = item;
		labelInfoButton(button);
		return button;
	}

	function labelInfoButton(button) {
		const label = t('layout_analysis.info.button');
		button.setAttribute('aria-label', label);
		button.title = label;
		button.setAttribute('aria-expanded', String(button === popoverOwner));
		button.setAttribute('aria-controls', 'la-popover');
	}

	/** Opens links through the host when it has a browser of its own. */
	function routeLink(link) {
		link.target = '_blank';
		link.rel = 'noopener';
		if (typeof HOST.openLink !== 'function') return;
		link.onclick = (event) => {
			event.preventDefault();
			HOST.openLink(link.href);
		};
	}

	/** The default values an explanation quotes, from the data (one source of truth). */
	function infoValues(item) {
		if (item !== 'ideal_finger_load') return {};
		const load = E.defaultIdealLoad();
		return {
			pinky: format(load.lp, 1),
			ring: format(load.lr, 1),
			middle: format(load.lm, 1),
			index: format(load.li, 1)
		};
	}

	function openInfo(button) {
		const item = button.dataset.info;
		const refs = DATA.sources.items[item];
		if (!refs) throw new Error(`layout_analysis: no sources for ${item}`);
		const popover = $('la-popover');
		$('la-popover-text').textContent = t(`layout_analysis.info.${item}`, infoValues(item));
		const list = $('la-popover-links');
		list.replaceChildren();
		for (const id of refs) {
			const ref = DATA.sources.references[id];
			const li = el('li');
			const a = el('a', '', ref.title);
			a.href = ref.url;
			routeLink(a);
			li.append(a);
			if (!ref.checked) li.append(` (${t('layout_analysis.info.unchecked')})`);
			list.append(li);
		}
		closeInfo();
		popoverOwner = button;
		button.setAttribute('aria-expanded', 'true');
		popover.hidden = false;
		const box = button.getBoundingClientRect();
		const width = Math.min(
			POPOVER_WIDTH_PX,
			document.documentElement.clientWidth - 2 * POPOVER_GUTTER_PX
		);
		popover.style.width = `${width}px`;
		const left = Math.min(
			Math.max(POPOVER_GUTTER_PX, box.left),
			document.documentElement.clientWidth - width - POPOVER_GUTTER_PX
		);
		popover.style.left = `${left + window.scrollX}px`;
		popover.style.top = `${box.bottom + window.scrollY + POPOVER_GUTTER_PX / 2}px`;
		$('la-popover-close').focus();
	}

	function closeInfo() {
		const popover = $('la-popover');
		if (popover.hidden) return;
		popover.hidden = true;
		const owner = popoverOwner;
		popoverOwner = null;
		if (owner && owner.isConnected) {
			owner.setAttribute('aria-expanded', 'false');
			owner.focus();
		}
	}

	function bindInfo() {
		// One listener for every « i » button, static or redrawn.
		document.addEventListener(
			'click',
			(event) => {
				const button = event.target.closest('.la-info');
				if (button) {
					// Inside a sortable header or a weight label: open only.
					event.preventDefault();
					event.stopPropagation();
					if (button === popoverOwner) closeInfo();
					else openInfo(button);
					return;
				}
				if (!event.target.closest('#la-popover')) closeInfo();
			},
			true
		);
		document.addEventListener('keydown', (event) => {
			if (event.key === 'Escape') closeInfo();
		});
		$('la-popover-close').addEventListener('click', closeInfo);
	}

	/** Decodes a picked layout file: UTF-16 with its byte-order mark (KLC) or UTF-8. */
	async function fileText(file) {
		const bytes = new Uint8Array(await file.arrayBuffer());
		if (bytes[0] === 0xff && bytes[1] === 0xfe)
			return new TextDecoder('utf-16le').decode(bytes.subarray(2));
		if (bytes[0] === 0xfe && bytes[1] === 0xff)
			return new TextDecoder('utf-16be').decode(bytes.subarray(2));
		return new TextDecoder().decode(bytes).replace(/^\uFEFF/, '');
	}

	/** Reads a layout file into the comparison, and says what could not be read. */
	async function importLayout(file) {
		const report = $('la-import-report');
		report.hidden = false;
		try {
			const result = window.LAYOUT_FORMATS.read(file.name, await fileText(file), {
				parseToml: window.exports && window.exports.parse,
				scancodes: DATA.scancodes,
				composer: window.LayoutComposer,
				table: window.LAYOUT_COMPOSER_DATA,
				analysis: E
			});
			const layout = E.layoutFromRows(
				Object.assign({}, result.layout, { origin: 'user', source: file.name })
			);
			let id = `user_${layout.id}`;
			for (let n = 2; byId.has(id); n++) id = `user_${layout.id}_${n}`;
			layout.id = id;
			layouts.push(layout);
			byId.set(id, layout);
			if (HOST.store) await HOST.store.save(layout);
			else imported.push(layout);
			state.selected.add(id);
			report.textContent =
				result.unmapped.length === 0
					? t('layout_analysis.layouts.imported', { name: layout.name, format: result.format })
					: t('layout_analysis.layouts.import_partial', {
							name: layout.name,
							format: result.format,
							count: result.unmapped.length,
							list: result.unmapped
								.slice(0, 8)
								.map((u) => u.detail)
								.join(', ')
						});
			save();
			fillLayouts();
			analyse();
		} catch (error) {
			report.textContent = t('layout_analysis.layouts.import_failed', {
				reason: error.code || error.message
			});
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
						? t('layout_analysis.corpus.file_unsupported')
						: t('layout_analysis.corpus.file_unreadable');
				error.hidden = false;
			}
		});
		$('la-filter').addEventListener('input', fillLayouts);
		$('la-import').addEventListener('change', (event) => {
			const file = event.target.files && event.target.files[0];
			if (file) importLayout(file);
			event.target.value = '';
		});
		$('la-heat-metric').addEventListener('change', (event) => {
			state.heat = event.target.value;
			renderDetails();
		});
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
		$('la-ideal-restore').addEventListener('click', () => {
			state.idealLoad = E.defaultIdealLoad();
			fillIdealLoad();
			save();
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
			fillIdealLoad();
			document.querySelectorAll('.la-info').forEach(labelInfoButton);
			render();
			analyse();
		});
	}

	/**
	 * Tells the framing page (the site's /studio/comparer) how tall the page
	 * is, so the frame fits without an inner scroll bar; a page opened on its
	 * own has no parent to tell.
	 */
	function reportHeight() {
		if (window.parent === window) return;
		const post = () =>
			window.parent.postMessage(
				{ type: HEIGHT_MESSAGE, height: document.documentElement.scrollHeight },
				'*'
			);
		post();
		if (typeof ResizeObserver === 'function') new ResizeObserver(post).observe(document.body);
	}

	// ==========================
	// ======= 7/ Host API ======
	// ==========================

	/**
	 * Adds or replaces a corpus after load (the app's keystats tables arrive on
	 * the user's request): listed first, and selected when it is the default.
	 * @param {{id: string, title?: string, tables: object, default?: boolean}} corpus
	 * @throws {Error} On tables the engine cannot read.
	 */
	function setCorpus(corpus) {
		E.prepareNgrams(corpus.tables);
		const entry = { id: corpus.id, title: corpus.title || '', host: { tables: corpus.tables } };
		const at = corpora.findIndex((c) => c.id === corpus.id);
		if (at >= 0) corpora.splice(at, 1, entry);
		else corpora.unshift(entry);
		if (corpus.default) state.corpus = corpus.id;
		fillCorpora();
		save();
		analyse();
	}

	/** Adds the host's layouts (e.g. the user's own from « Éditer ») to the list, ticked. */
	function addLayouts(list) {
		for (const value of list) {
			const layout = E.layoutFromRows(Object.assign({ origin: 'user' }, value));
			if (!byId.has(layout.id)) layouts.push(layout);
			else layouts.splice(layouts.indexOf(byId.get(layout.id)), 1, layout);
			byId.set(layout.id, layout);
			state.selected.add(layout.id);
		}
		fillLayouts();
		analyse();
	}

	window.LAYOUT_ANALYSIS_COMPARER = { setCorpus, addLayouts };
	document.addEventListener(NGRAMS_EVENT, (event) =>
		setCorpus({ id: MY_TYPING_ID, tables: event.detail, default: true })
	);

	function start() {
		fillCorpora();
		fillLayouts();
		fillWeights();
		fillIdealLoad();
		document.querySelectorAll('.la-info').forEach(labelInfoButton);
		bind();
		bindInfo();
		analyse();
		reportHeight();
		// The host's personal layouts (app data folder, site IndexedDB).
		if (HOST.store)
			HOST.store
				.list()
				.then(addLayouts, () => showStatus(t('layout_analysis.status.store_failed')));
	}

	if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
	else start();
})();
