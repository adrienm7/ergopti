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
 * 1b. Mountable: LAYOUT_ANALYSIS_COMPARER.mount(root, {host}) fills any
 *    element; the site's page mounts its <main>, the app's Studio window its
 *    « Comparer » tab. The markup lives here, its strings in data-i18n*.
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
 *    of localStorage. LAYOUT_ANALYSIS_COMPARER.onResults(listener) lets an
 *    extra view (other analysers' scores) follow every comparison.
 * 8. Every metric and sourced value has an « i » button (info_popover.js):
 *    its popover says where the value comes from and links the sources.
 * 9. The ideal finger load of finger_imbalance is editable (eight targets
 *    summing to 100 %), kept with the other conveniences.
 * 10. The user's fingering profile (fingering_editor.js: finger of each key,
 *    home key of each finger) is edited here and applies to every analysis.
 * 11. A link may open the comparison on a corpus, a keyboard and a keyboard
 *    format (?corpus=<id>&keyboard=<id>&format=<id>, the site's benchmark page), over the saved
 *    choice; a value the page does not know is named in the console and the
 *    saved choice stays. It may also name the compared layouts, the one shown
 *    in detail and the one it is compared with (&layouts=a,b&details=a&versus=b),
 *    shown without replacing the visitor's saved selection; « Copy the link »
 *    writes that address (the user's own layouts and texts stay out of it).
 * 12. Details: a layout against another (the engine's diff, each difference
 *    with its verdict in words), each finger's share against its ideal load,
 *    hands and rows, and a one-hue key heatmap with its scale that shrinks
 *    with the page. The score settings are folded under the results.
 * ==============================================================================
 */

(function () {
	'use strict';

	const E = window.LAYOUT_ANALYSIS;
	const DATA = window.LAYOUT_ANALYSIS_DATA;
	const INFO = window.LAYOUT_ANALYSIS_INFO;
	const FINGERING = window.LAYOUT_ANALYSIS_FINGERING;
	const infoButton = INFO.button;
	const STORAGE_KEY = window.LAYOUT_ANALYSIS_FILES.SETTINGS_KEY;
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
	// Widest size of one key unit of the heatmap, in pixels; narrower screens
	// shrink the whole board instead of scrolling it.
	const HEAT_UNIT_PX = 44;
	// Width of the space bar in key units.
	const SPACE_UNITS = 6;
	// A key at least this share of the heatmap's maximum is dark enough for light ink.
	const HEAT_STRONG_SHARE = 0.55;
	// Where a shared link opens when the page has no web address of its own
	// (the app's Studio window): the site's Comparer.
	const SITE_COMPARER_URL = 'https://ergopti.fr/studio/comparer';
	// The link parameters this page reads; the others of the address are dropped.
	const LINK_PARAMS = ['corpus', 'keyboard', 'format', 'layouts', 'details', 'versus'];
	// The layout origins a link can name: the user's own layouts stay on their device.
	const SHAREABLE_ORIGINS = ['registry', 'reference', 'library'];
	const TEXT_DEBOUNCE_MS = 400;
	// The message the framing page listens for to size its frame.
	const HEIGHT_MESSAGE = 'ergopti-layout-analysis:height';
	// The app's keystats n-grams: the event its Studio window dispatches and the
	// corpus id they take (the default corpus in the app, maintainer 2026-11-14).
	const NGRAMS_EVENT = 'studio-ngrams';
	const MY_TYPING_ID = 'my_typing';

	// The site's standalone page mounts the Comparer into this element.
	const STANDALONE_ROOT_ID = 'layout-analysis';

	// The site passes ?lang=<code>; i18n.js loads that locale, then English and French.
	const lang = new URLSearchParams(location.search).get('lang');
	if (lang && /^[a-z]{2}$/.test(lang)) window._i18n_locale = lang;

	// The Comparer's markup; data-i18n* attributes are filled by applyStrings().
	const MARKUP = `<h1 data-i18n="layout_analysis.title"></h1>
<section class="la-controls" aria-labelledby="la-corpus-label">
	<div class="la-field">
		<label
			id="la-corpus-label"
			for="la-corpus"
			data-i18n="layout_analysis.corpus.label"
		></label>
		<select id="la-corpus"></select>
		<p id="la-corpus-info" class="la-muted"></p>
	</div>
	<div id="la-custom" class="la-field la-custom" hidden>
		<textarea
			id="la-text"
			rows="5"
			data-i18n-placeholder="layout_analysis.corpus.paste_placeholder"
		></textarea>
		<label class="la-file">
			<span class="la-file-button" data-i18n="layout_analysis.corpus.file"></span>
			<input
				id="la-file"
				type="file"
				accept=".txt,.md,.csv,.tsv,.html,.htm,.json,.tex,.docx,.odt,.pdf"
			/>
			<span id="la-file-name" class="la-muted"></span>
		</label>
		<p id="la-file-error" class="la-error" hidden></p>
	</div>
	<div class="la-field">
		<div class="la-heading">
			<label for="la-keyboard" data-i18n="layout_analysis.keyboard.label"></label>
			<button
				class="la-info"
				type="button"
				data-info="fingering"
				data-i18n-title="layout_analysis.info.button"
			>
				i
			</button>
		</div>
		<select id="la-keyboard" data-i18n-option-prefix="layout_analysis.keyboard"></select>
	</div>
	<div class="la-field">
		<label for="la-format" data-i18n="layout_analysis.format.label"></label>
		<select id="la-format" data-i18n-option-prefix="layout_analysis.format"></select>
	</div>
</section>

<section class="la-layouts" aria-labelledby="la-layouts-label">
	<h2 id="la-layouts-label" data-i18n="layout_analysis.layouts.label"></h2>
	<div class="la-row">
		<input
			id="la-filter"
			type="search"
			data-i18n-placeholder="layout_analysis.layouts.filter_placeholder"
		/>
		<button id="la-all" type="button" data-i18n="layout_analysis.layouts.all"></button>
		<button id="la-none" type="button" data-i18n="layout_analysis.layouts.none"></button>
		<label class="la-file">
			<span class="la-file-button" data-i18n="layout_analysis.layouts.import"></span>
			<input id="la-import" type="file" />
		</label>
	</div>
	<p id="la-import-report" class="la-muted" hidden></p>
	<div id="la-layout-list" class="la-layout-list"></div>
</section>

<p id="la-status" class="la-status" role="status" aria-live="polite"></p>

<section id="la-results" class="la-results" aria-labelledby="la-chart-label">
	<div class="la-heading la-heading-wide">
		<h2 id="la-chart-label" data-i18n="layout_analysis.chart.title"></h2>
		<button id="la-share" type="button" data-i18n="layout_analysis.share.button"></button>
	</div>
	<p id="la-share-status" class="la-muted" role="status" hidden></p>
	<p class="la-muted" data-i18n="layout_analysis.chart.caption"></p>
	<ul class="la-legend">
		<li><span class="la-swatch la-swatch-gain"></span><span data-i18n="layout_analysis.chart.gain"></span></li>
		<li><span class="la-swatch la-swatch-loss"></span><span data-i18n="layout_analysis.chart.loss"></span></li>
	</ul>
	<div id="la-chart" class="la-chart"></div>
	<div class="la-table-wrap">
		<table id="la-table" class="la-table"></table>
	</div>
</section>

<section id="la-analysers" class="la-card" hidden></section>

<section id="la-details" class="la-details" hidden>
	<h2 id="la-details-title"></h2>
	<p class="la-muted">
		<span id="la-details-credit"></span>
		<a id="la-details-link" target="_blank" rel="noopener" hidden></a>
	</p>
	<div class="la-field la-versus">
		<label for="la-versus" data-i18n="layout_analysis.details.versus"></label>
		<select id="la-versus"></select>
	</div>
	<h3 data-i18n="layout_analysis.details.heatmap"></h3>
	<label class="la-sr-only" for="la-heat-metric" data-i18n="layout_analysis.details.heatmap"></label>
	<select id="la-heat-metric" data-i18n-option-prefix="layout_analysis.heat">
		<option value="presses"></option>
		<option value="sfb"></option>
		<option value="sfs"></option>
		<option value="lsb"></option>
		<option value="scissors"></option>
		<option value="redirect"></option>
	</select>
	<div id="la-heatmap" class="la-heatmap"></div>
	<div id="la-heat-legend" class="la-heat-legend"></div>
	<div class="la-detail-grid">
		<div>
			<h3 data-i18n="layout_analysis.details.contributions"></h3>
			<div id="la-contributions" class="la-bars"></div>
		</div>
		<div>
			<h3 data-i18n="layout_analysis.details.fingers"></h3>
			<p class="la-muted" data-i18n="layout_analysis.details.fingers_caption"></p>
			<ul class="la-legend">
				<li><span class="la-swatch la-swatch-load"></span><span data-i18n="layout_analysis.details.share_mark"></span></li>
				<li><span class="la-swatch la-swatch-ideal"></span><span data-i18n="layout_analysis.details.ideal_mark"></span></li>
			</ul>
			<div id="la-fingers" class="la-bars"></div>
			<h3 data-i18n="layout_analysis.details.hands_rows"></h3>
			<div id="la-hands-rows" class="la-bars"></div>
		</div>
	</div>
	<h3 data-i18n="layout_analysis.details.metrics"></h3>
	<div class="la-table-wrap">
		<table id="la-metrics" class="la-table"></table>
	</div>
	<p id="la-unsupported" class="la-muted"></p>
</section>

<details id="la-settings" class="la-settings">
<summary data-i18n="layout_analysis.settings.title"></summary>
<section class="la-weights" aria-labelledby="la-weights-label">
	<div class="la-heading">
		<h2 id="la-weights-label" data-i18n="layout_analysis.weights.title"></h2>
		<button
			class="la-info"
			type="button"
			data-info="weights"
			data-i18n-title="layout_analysis.info.button"
		>
			i
		</button>
	</div>
	<p class="la-muted" data-i18n="layout_analysis.weights.help"></p>
	<button id="la-restore" type="button" data-i18n="layout_analysis.weights.restore"></button>
	<div id="la-weight-list" class="la-weight-list"></div>
</section>

<section class="la-weights" aria-labelledby="la-ideal-label">
	<div class="la-heading">
		<h2 id="la-ideal-label" data-i18n="layout_analysis.ideal.title"></h2>
		<button
			class="la-info"
			type="button"
			data-info="ideal_finger_load"
			data-i18n-title="layout_analysis.info.button"
		>
			i
		</button>
	</div>
	<p class="la-muted" data-i18n="layout_analysis.ideal.help"></p>
	<button
		id="la-ideal-restore"
		type="button"
		data-i18n="layout_analysis.ideal.restore"
	></button>
	<div id="la-ideal-list" class="la-weight-list"></div>
	<p id="la-ideal-sum" class="la-muted" role="status"></p>
</section>

<section class="la-weights" aria-labelledby="la-shortcuts-label">
	<div class="la-heading">
		<h2 id="la-shortcuts-label" data-i18n="layout_analysis.shortcuts.title"></h2>
		<button
			class="la-info"
			type="button"
			data-info="shortcut_letters"
			data-i18n-title="layout_analysis.info.button"
		>
			i
		</button>
	</div>
	<p class="la-muted" data-i18n="layout_analysis.shortcuts.help"></p>
	<button
		id="la-shortcuts-restore"
		type="button"
		data-i18n="layout_analysis.shortcuts.restore"
	></button>
	<h3 data-i18n="layout_analysis.shortcuts.letters"></h3>
	<div id="la-shortcut-letters" class="la-weight-list"></div>
	<h3 data-i18n="layout_analysis.shortcuts.ease"></h3>
	<div id="la-shortcut-ease" class="la-weight-list"></div>
	<p id="la-shortcuts-status" class="la-muted" role="status"></p>
</section>

<section class="la-weights" aria-labelledby="la-forms-label">
	<div class="la-heading">
		<h2 id="la-forms-label" data-i18n="layout_analysis.forms.title"></h2>
		<button
			class="la-info"
			type="button"
			data-info="compact_fit"
			data-i18n-title="layout_analysis.info.button"
		>
			i
		</button>
	</div>
	<p class="la-muted" data-i18n="layout_analysis.forms.help"></p>
	<button id="la-forms-restore" type="button" data-i18n="layout_analysis.forms.restore"></button>
	<div id="la-form-list" class="la-weight-list"></div>
	<p id="la-forms-status" class="la-muted" role="status"></p>
</section>

<section id="la-fingering" class="la-weights la-fingering"></section>
</details>`;

	let mounted = null;
	// The app's last keystats tables, kept when they arrive before the mount.
	let lastNgrams = null;

	/**
	 * Mounts the Comparer into an element: the site's page mounts it into its
	 * <main>, the app's Studio window into its « Comparer » tab.
	 * @param {HTMLElement} root - The element the Comparer fills.
	 * @param {{host?: object, reportHeight?: boolean}} [options] - host: the
	 *   LAYOUT_ANALYSIS_HOST contract (window.LAYOUT_ANALYSIS_HOST when absent);
	 *   reportHeight: post the page height to a framing parent (the site).
	 * @returns {{setCorpus: function, addLayouts: function, setFormat: function, onResults: function}}
	 * @throws {Error} On a missing root or a second mount.
	 */
	function mount(root, options) {
		if (!root || typeof root.append !== 'function')
			throw new Error('layout_analysis: mount needs an element');
		if (mounted) throw new Error('layout_analysis: the Comparer is already mounted');
		const opts = options || {};
		const HOST = opts.host || window.LAYOUT_ANALYSIS_HOST || {};
		root.classList.add('layout-analysis');
		// A constant of this script, no user data: safe as markup.
		root.innerHTML = MARKUP;

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
						// Until the visitor ticks a layout, a link's selection is not theirs to keep.
						selected: state.linkedSelection ? saved.selected : Array.from(state.selected),
						selectionChosen: state.linkedSelection ? saved.selectionChosen : state.selectionChosen,
						weights: state.weights,
						idealLoad: state.idealLoad,
						shortcuts: state.shortcuts,
						formWeights: state.formWeights,
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

		/**
		 * The layouts ticked until the user chooses (maintainer, 2026-11-15): the
		 * registry, reference and personal layouts, but of a family that ships
		 * one layout per board (Ergopti and Ergopti ANSI) only the one of the
		 * chosen keyboard's geometry; the other stays listed, unticked. A board
		 * with no row-staggered geometry (split, ortholinear) takes ISO's.
		 * @param {string} keyboard A model keyboard id.
		 * @returns {Set<string>} The ids to tick.
		 */
		function defaultSelection(keyboard) {
			const geometry = DATA.model.keyboards[keyboard].geometry || 'iso';
			const otherBoard = (layout) =>
				layout.geometry !== '' &&
				layout.geometry !== geometry &&
				layouts.some((other) => other.family === layout.family && other.geometry === geometry);
			return new Set(
				layouts
					.filter((l) => DEFAULT_ORIGINS.includes(l.origin) || l.origin === 'user')
					.filter((l) => !otherBoard(l))
					.map((l) => l.id)
			);
		}
		const corpora = (HOST.corpora || [])
			.map((corpus) => ({ id: corpus.id, title: corpus.title, host: corpus }))
			.concat(
				DATA.corpora.map((corpus) => ({ id: corpus.id, title: corpus.title, builtin: corpus }))
			)
			.concat([{ id: CUSTOM_ID }]);
		const linked = linkedChoices(corpora);
		const state = {
			corpus:
				linked.corpus ||
				(corpora.some((c) => c.id === saved.corpus) ? saved.corpus : corpora[0].id),
			keyboard: linked.keyboard || (DATA.model.keyboards[saved.keyboard] ? saved.keyboard : 'iso'),
			// The keyboard format (the editor's « Format » too, one stored choice for the
			// Studio's two tabs): compact_fit measures on it.
			format:
				linked.format ||
				(E.keyboardFormats().some((f) => f.id === window.LAYOUT_ANALYSIS_FILES.savedFormat())
					? window.LAYOUT_ANALYSIS_FILES.savedFormat()
					: E.defaultKeyboardFormat()),
			// Whether the user chose the ticked layouts; until then they follow the keyboard.
			selectionChosen: saved.selectionChosen === true && Array.isArray(saved.selected),
			selected: null,
			weights: Object.assign(E.defaultWeights(), validWeights(saved.weights)),
			idealLoad: validIdealLoad(saved.idealLoad),
			// The shortcut table of shortcut_left and the form factor weights of
			// compact_fit, the model's until the user edits them.
			shortcuts: validOr(E.shortcuts, saved.shortcuts, E.defaultShortcuts),
			formWeights: validOr(E.formFactorWeights, saved.formWeights, E.defaultFormFactorWeights),
			custom: saved.custom && saved.custom.tables ? saved.custom : null,
			tables: null,
			results: [],
			sort: { key: 'rank', descending: false },
			heat: 'presses',
			details: linked.details || null,
			// The layout the details compare with (diff), null for none.
			versus: linked.versus || null
		};
		// A link's layouts are shown, not saved: the visitor's own choice stays.
		state.linkedSelection = Boolean(linked.layouts);
		if (linked.layouts) {
			state.selected = new Set(linked.layouts);
			state.selectionChosen = true;
		} else {
			state.selected = state.selectionChosen
				? new Set(saved.selected.filter((id) => byId.has(id)))
				: defaultSelection(state.keyboard);
		}
		if (HOST.corpora && HOST.corpora.length > 0 && saved.corpus === undefined && !linked.corpus)
			state.corpus = HOST.corpora[0].id;

		/**
		 * The corpus, keyboard and keyboard format a link asks for
		 * (?corpus=&keyboard=&format=), each only when the page knows it; the
		 * ticked layouts stay the visitor's (selectionChosen) or the keyboard's.
		 * @returns {{corpus?: string, keyboard?: string, format?: string}}
		 */
		function linkedChoices(known) {
			const query = new URLSearchParams(location.search);
			const out = {};
			const corpus = query.get('corpus');
			if (corpus !== null) {
				if (known.some((c) => c.id === corpus && c.id !== CUSTOM_ID)) out.corpus = corpus;
				else console.warn(`layout comparer: the link names no built-in corpus ${corpus}`);
			}
			const keyboard = query.get('keyboard');
			if (keyboard !== null) {
				if (DATA.model.keyboards[keyboard]) out.keyboard = keyboard;
				else console.warn(`layout comparer: the link names no keyboard ${keyboard}`);
			}
			const format = query.get('format');
			if (format !== null) {
				if (E.keyboardFormats().some((f) => f.id === format)) out.format = format;
				else console.warn(`layout comparer: the link names no keyboard format ${format}`);
			}
			// The compared layouts, the one shown in detail and the one it is compared with.
			const named = query.get('layouts');
			if (named !== null) {
				const ids = named.split(',').filter((id) => id !== '');
				for (const id of ids)
					if (!byId.has(id)) console.warn(`layout comparer: the link names no layout ${id}`);
				const kept = ids.filter((id) => byId.has(id));
				if (kept.length > 0) out.layouts = kept;
			}
			for (const name of ['details', 'versus']) {
				const id = query.get(name);
				if (id === null) continue;
				if (byId.has(id)) out[name] = id;
				else console.warn(`layout comparer: the link names no layout ${id} (${name})`);
			}
			return out;
		}

		/** Whether a saved value still reads as a layout. */
		function isLayout(value) {
			try {
				E.layoutFromRows(value);
				return true;
			} catch {
				return false;
			}
		}

		/** A saved table the engine still accepts (check), else its default. */
		function validOr(check, value, fallback) {
			if (value === undefined) return fallback();
			try {
				return check(value);
			} catch (error) {
				console.warn(
					`layout comparer: a saved table is refused (${error.code}); the default applies`
				);
				return fallback();
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

		/** The prepared tables of the chosen corpus, or null when it has none yet. */
		async function corpusTables() {
			const corpus = corpora.find((c) => c.id === state.corpus);
			if (corpus.host) return E.prepareNgrams(corpus.host.tables);
			if (corpus.builtin) {
				return E.prepareNgrams(await window.LAYOUT_ANALYSIS_FILES.builtinTables(corpus.builtin));
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
		// Extra views (other analysers' scores) told about each comparison.
		const resultListeners = [];

		/** Analyses the selected layouts on the chosen corpus and redraws. */
		async function analyse() {
			const mine = ++generation;
			// A built-in corpus loads its tables once (up to a few megabytes): say so meanwhile.
			setBusy(true);
			let tables;
			try {
				tables = await corpusTables();
			} catch {
				if (mine !== generation) return;
				setBusy(false);
				showStatus(t('layout_analysis.status.corpus_failed'));
				return;
			}
			if (mine !== generation) return;
			setBusy(false);
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
				format: state.format,
				weights: state.weights,
				idealLoad: state.idealLoad,
				shortcuts: state.shortcuts,
				formWeights: state.formWeights,
				profile: FINGERING.current(state.keyboard) || undefined
			});
			const ms = Math.round(performance.now() - start);
			// The compared layouts themselves (rows, dead keys…), for extra scorers.
			const compared = new Map(chosen.map((layout) => [layout.id, layout]));
			state.compared = compared;
			for (const listener of resultListeners)
				listener(state.results, tables, { keyboard: state.keyboard, layouts: compared });
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

		/**
		 * Marks the results as being computed: the status says so at once and
		 * assistive technology waits for the new ranking before reading it.
		 */
		function setBusy(busy) {
			$('la-results').setAttribute('aria-busy', String(busy));
			$('la-results').classList.toggle('la-busy', busy);
			if (busy) showStatus(t('layout_analysis.status.loading'));
		}

		// ==========================
		// ======= 5/ Rendering =====
		// ==========================

		function render() {
			renderChart();
			renderTable();
			renderDetails();
		}

		/**
		 * Makes a row act as a button: a click or Enter / Space opens the
		 * layout's details, and it takes the keyboard focus in reading order.
		 */
		function openOnActivate(node, id, label) {
			node.tabIndex = 0;
			node.setAttribute('role', 'button');
			node.setAttribute('aria-label', label);
			node.addEventListener('click', () => showDetails(id));
			node.addEventListener('keydown', (event) => {
				if (event.key !== 'Enter' && event.key !== ' ') return;
				event.preventDefault();
				showDetails(id);
			});
		}

		/** Horizontal bars of the global score around zero, best first. */
		function renderChart() {
			const box = $('la-chart');
			box.replaceChildren();
			const shown = state.results.slice(0, CHART_MAX_BARS);
			if (shown.length === 0) return;
			const totals = shown.map((r) => r.score.total);
			const min = Math.min(0, ...totals);
			const max = Math.max(0, ...totals);
			const span = max - min || 1;
			const zero = ((0 - min) / span) * 100;
			for (const result of shown) {
				const row = el('div', 'la-chart-row');
				const value = format(result.score.total, 1);
				openOnActivate(
					row,
					result.layout.id,
					t('layout_analysis.chart.row', {
						layout: result.layout.name,
						rank: result.rank,
						score: value
					})
				);
				if (state.details === result.layout.id) row.classList.add('la-selected');
				row.append(el('span', 'la-chart-label', result.layout.name));
				const track = el('span', 'la-chart-track');
				// The zero line, so a negative score reads as one.
				if (min < 0) {
					const axis = el('span', 'la-zero');
					axis.style.left = `${zero}%`;
					track.append(axis);
				}
				const bar = el(
					'span',
					result.score.total >= 0 ? 'la-bar la-bar-gain' : 'la-bar la-bar-loss'
				);
				const end = ((result.score.total - min) / span) * 100;
				bar.style.left = `${Math.min(zero, end)}%`;
				bar.style.width = `${Math.abs(end - zero)}%`;
				track.append(bar);
				row.title = `${result.layout.name}: ${value} ${t('layout_analysis.unit.points')}`;
				row.append(track, el('span', 'la-chart-value', value));
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
					label: `${t(`layout_analysis.metric.${id}`)} (${unitText(id)})`,
					value: (r) => r.metrics[id],
					digits: metricDigits(id)
				}))
			);
			const head = el('tr');
			for (const column of columns) {
				const th = el('th', 'la-sortable');
				th.scope = 'col';
				// The sort is a button, so the keyboard reaches it.
				const sort = el('button', 'la-sort', column.label);
				sort.type = 'button';
				sort.addEventListener('click', () => {
					state.sort =
						state.sort.key === column.key
							? { key: column.key, descending: !state.sort.descending }
							: { key: column.key, descending: column.key === 'score' };
					renderTable();
				});
				th.append(sort);
				if (DATA.sources.items[column.key]) th.append(' ', infoButton(column.key));
				if (state.sort.key === column.key)
					th.setAttribute('aria-sort', state.sort.descending ? 'descending' : 'ascending');
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
				tr.tabIndex = 0;
				tr.addEventListener('click', () => showDetails(result.layout.id));
				tr.addEventListener('keydown', (event) => {
					if (event.key !== 'Enter') return;
					event.preventDefault();
					showDetails(result.layout.id);
				});
				tbody.append(tr);
			}
			table.append(thead, tbody);
		}

		function showDetails(id) {
			state.details = id;
			if (state.versus === id) state.versus = null;
			render();
			$('la-details').scrollIntoView({ block: 'nearest' });
		}

		/**
		 * Bars around zero: one per entry, labelled, signed (points gained in
		 * the gain colour, lost in the loss colour, the value's sign written).
		 */
		function signedBars(box, entries, digits, unit) {
			box.replaceChildren();
			const extent = Math.max(...entries.map(([, v]) => Math.abs(v)), 1e-9);
			for (const [label, value] of entries) {
				const row = el('div', 'la-chart-row');
				row.append(el('span', 'la-chart-label', label));
				const track = el('span', 'la-chart-track la-signed');
				const bar = el('span', value >= 0 ? 'la-bar la-bar-gain' : 'la-bar la-bar-loss');
				const width = (Math.abs(value) / extent) * 50;
				bar.style.left = value >= 0 ? '50%' : `${50 - width}%`;
				bar.style.width = `${width}%`;
				track.append(bar);
				const text = `${value > 0 ? '+' : ''}${format(value, digits)}`;
				row.title = `${label}: ${text} ${unit}`;
				row.append(track, el('span', 'la-chart-value', text));
				box.append(row);
			}
		}

		/**
		 * Magnitude bars from zero, in one colour, each with an optional target
		 * mark (the ideal finger load); the value is written in its unit.
		 * @param {HTMLElement} box
		 * @param {Array<{label: string, value: number, target?: number}>} entries
		 * @param {number} scale The value a full bar stands for.
		 */
		function loadBars(box, entries, scale) {
			box.replaceChildren();
			for (const entry of entries) {
				const row = el('div', 'la-chart-row');
				row.append(el('span', 'la-chart-label', entry.label));
				const track = el('span', 'la-chart-track');
				const bar = el('span', 'la-bar la-bar-load');
				bar.style.left = '0';
				bar.style.width = `${Math.min(100, (entry.value / scale) * 100)}%`;
				track.append(bar);
				let title = `${entry.label}: ${format(entry.value, 1)} %`;
				if (entry.target !== undefined) {
					const mark = el('span', 'la-target');
					mark.style.left = `${Math.min(100, (entry.target / scale) * 100)}%`;
					track.append(mark);
					title += ` (${t('layout_analysis.details.ideal_mark')}: ${format(entry.target, 1)} %)`;
				}
				row.title = title;
				row.append(track, el('span', 'la-chart-value', `${format(entry.value, 1)} %`));
				box.append(row);
			}
		}

		/** A metric's unit as written beside its value. */
		function unitText(id) {
			return E.METRICS[id].unit === 'mm' ? t('layout_analysis.unit.mm') : '%';
		}

		/**
		 * The board of the chosen keyboard, each key showing the layout's base
		 * character and shaded light to dark (one hue) by its share of the
		 * chosen per-key value (presses or a bad event); the legend gives the
		 * scale, the tooltip the value and, for SFBs, the worst partners. The
		 * board shrinks with the page instead of scrolling.
		 */
		function renderHeatmap(result) {
			const box = $('la-heatmap');
			box.replaceChildren();
			const board = E.keyboard(result.keyboard, result.profile || undefined);
			const layout = byId.get(result.layout.id);
			const modifiers = new Set(Object.values(DATA.model.modifier_keys));
			const values = board.codes.map((code) => result.keys[code][state.heat]);
			const max = Math.max(...values, 1e-9);
			const minX = Math.min(...board.x) - 0.5;
			const maxX = Math.max(...board.x) + 0.5;
			const maxY = Math.max(...board.y);
			const width = maxX - minX;
			// Positions in % of the board, so the whole board scales with its box.
			const across = (units) => `${(units / width) * 100}%`;
			const down = (units) => `${(units / maxY) * 100}%`;
			box.style.maxWidth = `${width * HEAT_UNIT_PX}px`;
			box.style.aspectRatio = `${width} / ${maxY}`;
			board.codes.forEach((code, k) => {
				if (modifiers.has(code)) return;
				const row = layout.rows[code];
				// A dead key shows its bare accent (what it types alone), marked as dead.
				const dead = row && row[0] && typeof row[0] === 'object' ? row[0].dead : null;
				const base =
					dead !== null
						? KEY_LEGEND.deadKeyText(((layout.dead || {})[dead] || {})[' '] || '') || dead
						: row && typeof row[0] === 'string'
							? row[0]
							: '';
				const key = el('span', 'la-key', code === 'Space' ? '␣' : base);
				if (dead !== null) key.classList.add(KEY_LEGEND.DEAD_KEY_CLASS);
				const share = values[k] / max;
				const span = code === 'Space' ? SPACE_UNITS : 1;
				const left = code === 'Space' ? board.x[k] - SPACE_UNITS / 2 : board.x[k] - 0.5;
				key.style.left = across(left - minX);
				key.style.top = down(board.y[k] - 1);
				key.style.width = across(span);
				key.style.height = down(1);
				key.style.setProperty('--la-share', `${Math.round(share * 100)}%`);
				if (share >= HEAT_STRONG_SHARE) key.classList.add('la-key-strong');
				const partners = result.keys[code].worst.sfb
					.map(
						([[other], pct]) => `${(layout.rows[other] || [''])[0] || other} ${format(pct, 2)} %`
					)
					.join(', ');
				key.title = `${t(`layout_analysis.heat.${state.heat}`)}: ${format(values[k], 2)} %${
					state.heat === 'sfb' && partners ? ` (${partners})` : ''
				}`;
				box.append(key);
			});
			// The scale: what the lightest and the darkest key stand for.
			const legend = $('la-heat-legend');
			legend.replaceChildren(
				el('span', '', `${format(0, 2)} %`),
				el('span', 'la-heat-ramp'),
				el('span', '', `${format(max === 1e-9 ? 0 : max, 2)} %`),
				el(
					'span',
					'la-muted',
					t('layout_analysis.heat.scale', { metric: t(`layout_analysis.heat.${state.heat}`) })
				)
			);
		}

		/** The versus choice: every other compared layout, or none. */
		function fillVersus(result) {
			const select = $('la-versus');
			const none = el('option', '', t('layout_analysis.details.versus_none'));
			none.value = '';
			const others = state.results
				.filter((r) => r.layout.id !== result.layout.id)
				.map((r) => {
					const option = el('option', '', r.layout.name);
					option.value = r.layout.id;
					return option;
				});
			select.replaceChildren(none, ...others);
			if (!state.results.some((r) => r.layout.id === state.versus)) state.versus = null;
			select.value = state.versus || '';
		}

		/**
		 * Every metric of the layout; with a layout to compare with, its value
		 * and the difference beside it, with which one the metric prefers in
		 * words (the engine's diff).
		 */
		function renderMetrics(result) {
			const table = $('la-metrics');
			table.replaceChildren();
			const other = state.results.find((r) => r.layout.id === state.versus) || null;
			const diff = other ? E.diff(result, other) : null;
			const head = el('tr');
			const columns = [t('layout_analysis.details.metric_column'), result.layout.name];
			if (other) columns.push(other.layout.name, t('layout_analysis.details.delta'));
			for (const label of columns) {
				const th = el('th', '', label);
				th.scope = 'col';
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			const tbody = el('tbody');
			// Each verdict in words with a mark, never by colour alone.
			const verdicts = {
				better: ['▲', t('layout_analysis.details.verdict_better')],
				worse: ['▼', t('layout_analysis.details.verdict_worse')],
				same: ['=', t('layout_analysis.details.verdict_same')],
				none: ['', t('layout_analysis.details.verdict_none')]
			};
			const verdictCell = (verdict) => {
				const cell = el('span', `la-verdict la-verdict-${verdict}`);
				const [mark, words] = verdicts[verdict];
				if (mark) cell.append(el('span', 'la-verdict-mark', mark), ' ');
				cell.append(words);
				return cell;
			};
			const addRow = (th, values, delta) => {
				const tr = el('tr');
				tr.append(th, ...values.map((text) => el('td', '', text)));
				if (delta) {
					const td = el('td', 'la-delta');
					td.append(delta.text, ' ', verdictCell(delta.verdict));
					tr.append(td);
				}
				tbody.append(tr);
			};
			const signed = (value, digits) => `${value > 0 ? '+' : ''}${format(value, digits)}`;
			if (diff) {
				const th = el('th', '', t('layout_analysis.table.score'));
				th.scope = 'row';
				addRow(th, [format(diff.score.a, 1), format(diff.score.b, 1)], {
					text: signed(diff.score.delta, 1),
					verdict: diff.score.verdict
				});
			}
			for (const id of Object.keys(E.METRICS)) {
				const th = el('th', '', t(`layout_analysis.metric.${id}`));
				th.scope = 'row';
				th.append(' ', infoButton(id));
				if (id === 'shortcut_left') th.append(' ', infoButton('shortcut_letters'));
				const digits = metricDigits(id);
				const unit = unitText(id);
				const values = [`${format(result.metrics[id], digits)} ${unit}`];
				let delta = null;
				if (diff) {
					const entry = diff.metrics[id];
					values.push(`${format(entry.b, digits)} ${unit}`);
					delta = { text: `${signed(entry.delta, digits)} ${unit}`, verdict: entry.verdict };
				}
				addRow(th, values, delta);
			}
			table.append(thead, tbody);
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
			INFO.routeLink(link);
			fillVersus(result);
			renderHeatmap(result);
			const contributions = Object.entries(result.score.contributions)
				.filter(([, v]) => v !== 0)
				.sort((a, b) => Math.abs(b[1]) - Math.abs(a[1]))
				.map(([id, v]) => [t(`layout_analysis.metric.${id}`), v]);
			signedBars($('la-contributions'), contributions, 1, t('layout_analysis.unit.points'));
			// Each finger against the ideal load the score aims for, on one scale.
			const shares = Object.entries(result.fingerShares);
			const fingerScale = Math.max(
				...shares.map(([id, v]) => Math.max(v, result.idealLoad[id])),
				1e-9
			);
			loadBars(
				$('la-fingers'),
				shares.map(([id, value]) => ({
					label: t(`layout_analysis.finger.${id}`),
					value,
					target: result.idealLoad[id]
				})),
				fingerScale
			);
			loadBars(
				$('la-hands-rows'),
				[
					{ label: t('layout_analysis.details.hand_left'), value: result.hands.left },
					{ label: t('layout_analysis.details.hand_right'), value: result.hands.right }
				].concat(
					['number_row', 'top_row', 'home_row', 'bottom_row'].map((id) => ({
						label: t(`layout_analysis.metric.${id}`),
						value: result.metrics[id]
					}))
				),
				100
			);
			renderMetrics(result);
			const missing = Object.entries(result.coverage.unsupportedChars)
				.sort((a, b) => b[1] - a[1])
				// An invisible character is named by its code point.
				.map(([char]) =>
					/^[\s\p{C}]$/u.test(char)
						? `U+${char.codePointAt(0).toString(16).toUpperCase().padStart(4, '0')}`
						: char
				)
				.join(' ');
			$('la-unsupported').textContent = [
				missing ? t('layout_analysis.details.unsupported', { chars: missing }) : '',
				result.coverage.missingKeys.length > 0
					? t('layout_analysis.details.missing_keys', {
							keys: result.coverage.missingKeys.join(' ')
						})
					: ''
			]
				.filter(Boolean)
				.join(' ');
		}

		/**
		 * The address of this comparison: the site's Comparer (or the page the
		 * visitor sees it framed in) with the corpus, keyboard, format, the
		 * shareable compared layouts and the details shown.
		 * @returns {{url: string, personal: boolean}} personal: some compared
		 *   layouts are the visitor's own and are not in the link.
		 */
		function shareLink() {
			let base = HOST.shareUrl || null;
			if (!base) {
				let shown = location;
				try {
					// The site frames this page; the link is the framing page's.
					if (window.top !== window && window.top.location.origin === location.origin)
						shown = window.top.location;
				} catch {
					// A frame from another origin: this page's own address.
				}
				base = /^https?:$/.test(shown.protocol)
					? `${shown.origin}${shown.pathname}`
					: SITE_COMPARER_URL;
			}
			const chosen = layouts.filter((l) => state.selected.has(l.id));
			const shareable = chosen.filter((l) => SHAREABLE_ORIGINS.includes(l.origin));
			const query = new URLSearchParams();
			const corpus = corpora.find((c) => c.id === state.corpus);
			if (corpus && corpus.builtin) query.set('corpus', state.corpus);
			query.set('keyboard', state.keyboard);
			query.set('format', state.format);
			query.set('layouts', shareable.map((l) => l.id).join(','));
			const canShare = (id) => shareable.some((l) => l.id === id);
			if (state.details && canShare(state.details)) query.set('details', state.details);
			if (state.versus && canShare(state.versus)) query.set('versus', state.versus);
			if (lang) query.set('lang', lang);
			return {
				url: `${base}?${query.toString().replace(/%2C/g, ',')}`,
				personal: shareable.length < chosen.length || !(corpus && corpus.builtin)
			};
		}

		/** Copies the comparison's link, or shows it when the clipboard refuses. */
		async function share() {
			const { url, personal } = shareLink();
			const status = $('la-share-status');
			status.hidden = false;
			try {
				await navigator.clipboard.writeText(url);
				status.textContent = personal
					? t('layout_analysis.share.copied_partial')
					: t('layout_analysis.share.copied');
			} catch {
				status.textContent = t('layout_analysis.share.failed', { url });
			}
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
						// The attribution the licence requires, then where the text comes from.
						source: `${corpus.builtin.attribution} — ${corpus.builtin.source}`
					})
				: corpus.host
					? t('layout_analysis.corpus.private')
					: t('layout_analysis.corpus.local');
			// A corpus counted from a word list says what its n-grams leave out.
			if (corpus.builtin && corpus.builtin.word_list)
				$('la-corpus-info').textContent += ` ${t('layout_analysis.corpus.word_list')}`;
		}

		/** The visitor picks the layouts: from now on the selection is theirs and kept. */
		function chooseSelection() {
			state.selectionChosen = true;
			state.linkedSelection = false;
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
					chooseSelection();
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
				} catch (error) {
					// Why the load is refused (its sum, a share, the finger order), in words.
					box.className = 'la-error';
					box.textContent = t('layout_analysis.ideal.refused', { reason: INFO.refusal(error) });
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

		/**
		 * One editable table of numbers (the shortcut letters, the key ease, the
		 * form factor weights): every change is checked by the engine as a whole;
		 * a refused one marks the inputs and says why, an accepted one is kept.
		 * @param {Array<{list: string, values: object, label: function(string): string, max?: number}>} parts
		 * @param {string} statusId The status line.
		 * @param {function(Array<object>): object} accept Builds and checks the whole value; throws on a refusal.
		 */
		function fillTable(parts, statusId, accept) {
			const inputs = parts.map(() => ({}));
			const changed = () => {
				const status = $(statusId);
				const read = inputs.map((group) =>
					Object.fromEntries(
						Object.entries(group).map(([id, input]) => [
							id,
							input.value === '' ? NaN : Number(input.value)
						])
					)
				);
				try {
					accept(read);
				} catch (error) {
					status.className = 'la-error';
					status.textContent = t('layout_analysis.table.refused', { reason: INFO.refusal(error) });
					for (const group of inputs)
						for (const input of Object.values(group)) input.setAttribute('aria-invalid', 'true');
					return;
				}
				status.className = 'la-muted';
				status.textContent = '';
				for (const group of inputs)
					for (const input of Object.values(group)) input.removeAttribute('aria-invalid');
				save();
				analyse();
			};
			parts.forEach((part, index) => {
				const list = $(part.list);
				list.replaceChildren();
				for (const [id, value] of Object.entries(part.values)) {
					const label = el('label', 'la-weight');
					label.append(el('span', '', part.label(id)));
					const input = el('input');
					input.type = 'number';
					input.min = '0';
					if (part.max !== undefined) input.max = String(part.max);
					input.step = 'any';
					input.dataset.id = id;
					input.value = String(value);
					input.addEventListener('input', changed);
					inputs[index][id] = input;
					label.append(input);
					list.append(label);
				}
			});
		}

		/** The shortcut letters' usefulness and their keys' ease (shortcut_left). */
		function fillShortcuts() {
			fillTable(
				[
					{
						list: 'la-shortcut-letters',
						values: state.shortcuts.letters,
						label: (letter) => letter.toUpperCase(),
						max: 10
					},
					{ list: 'la-shortcut-ease', values: state.shortcuts.ease, label: (code) => code, max: 1 }
				],
				'la-shortcuts-status',
				([letters, ease]) => {
					state.shortcuts = E.shortcuts({ letters, ease });
				}
			);
		}

		/** The compact form factors' weights (compact_fit). */
		function fillForms() {
			fillTable(
				[
					{
						list: 'la-form-list',
						values: state.formWeights,
						label: (id) => t(`layout_analysis.forms.${id}`)
					}
				],
				'la-forms-status',
				([weights]) => {
					state.formWeights = E.formFactorWeights(weights);
				}
			);
		}

		/** What a reader could not carry, worded in the page's language (eight at most). */
		function lossList(unmapped) {
			const words = unmapped.slice(0, 8).map((entry) => {
				const loss = window.LAYOUT_FORMATS.lossMessage(entry);
				return t(loss.key, loss.values);
			});
			return unmapped.length > 8 ? `${words.join(', ')}…` : words.join(', ');
		}

		/** Reads a layout file into the comparison, and says what could not be read. */
		async function importLayout(file) {
			const report = $('la-import-report');
			report.hidden = false;
			try {
				const bytes = new Uint8Array(await file.arrayBuffer());
				const result = window.LAYOUT_FORMATS.readBytes(file.name, bytes, {
					parseToml: window.exports && window.exports.parse,
					scancodes: DATA.scancodes,
					composer: window.LayoutComposer,
					// A top-level const of composer_data.js: a page global, not a window property.
					table: LAYOUT_COMPOSER_DATA,
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
								list: lossList(result.unmapped)
							});
				save();
				fillLayouts();
				analyse();
			} catch (error) {
				const refusal = window.LAYOUT_FORMATS.refusalMessage(error);
				report.textContent = t(refusal.key, refusal.values);
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
			// Every keyboard of the model: the row-staggered boards, then the split,
			// ortholinear and column-staggered ones.
			$('la-keyboard').replaceChildren(
				...Object.keys(DATA.model.keyboards).map((id) => {
					const option = el('option', '', t(`layout_analysis.keyboard.${id}`));
					option.value = id;
					return option;
				})
			);
			$('la-keyboard').value = state.keyboard;
			$('la-keyboard').addEventListener('change', (event) => {
				state.keyboard = event.target.value;
				if (!state.selectionChosen) {
					state.selected = defaultSelection(state.keyboard);
					fillLayouts();
				}
				fingeringView.draw();
				save();
				analyse();
			});
			$('la-format').replaceChildren(
				...E.keyboardFormats().map((entry) => {
					const option = el('option', '', t(`layout_analysis.format.${entry.id}`));
					option.value = entry.id;
					return option;
				})
			);
			$('la-format').value = state.format;
			$('la-format').addEventListener('change', (event) => setFormat(event.target.value));
			let timer = null;
			$('la-text').addEventListener('input', (event) => {
				clearTimeout(timer);
				timer = setTimeout(() => useText(event.target.value), TEXT_DEBOUNCE_MS);
			});
			$('la-file').addEventListener('change', async (event) => {
				const file = event.target.files && event.target.files[0];
				const error = $('la-file-error');
				error.hidden = true;
				// The browser's own « no file chosen » text is hidden with its input.
				$('la-file-name').textContent = file ? file.name : '';
				if (!file) return;
				try {
					const text = await window.LAYOUT_ANALYSIS_FILES.readText(file);
					$('la-text').value = text;
					useText(text);
				} catch (failure) {
					// Each refusal in words: an unknown type, a PDF that is locked or holds no
					// text (a scan), or a file that could not be read.
					const known = {
						file_unsupported: 'layout_analysis.corpus.file_unsupported',
						pdf_encrypted: 'layout_analysis.corpus.pdf_encrypted',
						pdf_no_text: 'layout_analysis.corpus.pdf_no_text'
					};
					error.textContent = t(known[failure.code] || 'layout_analysis.corpus.file_unreadable');
					error.hidden = false;
				}
			});
			$('la-filter').addEventListener('input', fillLayouts);
			// The file types every layout reader opens (layout_formats.js).
			$('la-import').accept = window.LAYOUT_FORMATS.EXTENSIONS.map((ext) => `.${ext}`).join(',');
			$('la-import').addEventListener('change', (event) => {
				const file = event.target.files && event.target.files[0];
				if (file) importLayout(file);
				event.target.value = '';
			});
			$('la-heat-metric').addEventListener('change', (event) => {
				state.heat = event.target.value;
				renderDetails();
			});
			$('la-versus').addEventListener('change', (event) => {
				state.versus = event.target.value || null;
				renderDetails();
			});
			$('la-share').addEventListener('click', share);
			$('la-all').addEventListener('click', () => {
				for (const id of visibleLayoutIds()) state.selected.add(id);
				chooseSelection();
				save();
				fillLayouts();
				analyse();
			});
			$('la-none').addEventListener('click', () => {
				for (const id of visibleLayoutIds()) state.selected.delete(id);
				chooseSelection();
				save();
				fillLayouts();
				analyse();
			});
			$('la-shortcuts-restore').addEventListener('click', () => {
				state.shortcuts = E.defaultShortcuts();
				fillShortcuts();
				$('la-shortcuts-status').textContent = '';
				save();
				analyse();
			});
			$('la-forms-restore').addEventListener('click', () => {
				state.formWeights = E.defaultFormFactorWeights();
				fillForms();
				$('la-forms-status').textContent = '';
				save();
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
				applyStrings();
				fillCorpora();
				fillWeights();
				fillIdealLoad();
				fillShortcuts();
				fillForms();
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
		/**
		 * Chooses the keyboard format (the Studio passes the editor's « Format »).
		 * @param {string} id A keyboard_formats id.
		 * @throws {Error} On an unknown format.
		 */
		function setFormat(id) {
			E.formatHiddenKeys(id);
			if (state.format === id) return;
			state.format = id;
			$('la-format').value = id;
			window.LAYOUT_ANALYSIS_FILES.saveFormat(id);
			analyse();
		}

		// The layouts open in « Éditer » (ids editor_…), listed as personal layouts
		// and replaced whenever the editor's tabs change.
		const editorIds = new Set();
		function useEditorLayouts(list) {
			const next = new Map();
			for (const value of Array.isArray(list) ? list : []) {
				try {
					const layout = E.layoutFromRows(Object.assign({}, value, { origin: 'user' }));
					if (layout.id.startsWith('editor_')) next.set(layout.id, layout);
				} catch (error) {
					console.warn(`layout comparer: an editor layout is refused (${error.message})`);
				}
			}
			for (const id of editorIds)
				if (!next.has(id)) {
					layouts.splice(layouts.indexOf(byId.get(id)), 1);
					byId.delete(id);
					state.selected.delete(id);
					editorIds.delete(id);
				}
			for (const [id, layout] of next) {
				if (byId.has(id)) layouts.splice(layouts.indexOf(byId.get(id)), 1, layout);
				else {
					layouts.push(layout);
					state.selected.add(id);
				}
				byId.set(id, layout);
				editorIds.add(id);
			}
			fillLayouts();
			if (state.tables) analyse();
		}

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

		/**
		 * Calls a listener after each comparison with (results, tables, {keyboard,
		 * layouts: Map id → the compared layout object}),
		 * and at once with the current ones: the hook of extra views.
		 * @param {function(object[], object, object): void} listener
		 */
		function onResults(listener) {
			if (typeof listener !== 'function')
				throw new Error('layout_analysis: onResults needs a function');
			resultListeners.push(listener);
			if (state.tables)
				listener(state.results, state.tables, {
					keyboard: state.keyboard,
					layouts: state.compared || new Map()
				});
		}

		/** Fills the markup's data-i18n, -placeholder, -title and option-prefix strings. */
		function applyStrings() {
			for (const node of root.querySelectorAll('[data-i18n]'))
				node.textContent = t(node.dataset.i18n);
			for (const node of root.querySelectorAll('[data-i18n-placeholder]'))
				node.placeholder = t(node.dataset.i18nPlaceholder);
			for (const node of root.querySelectorAll('[data-i18n-title]'))
				node.title = t(node.dataset.i18nTitle);
			for (const select of root.querySelectorAll('select[data-i18n-option-prefix]'))
				for (const option of select.options)
					option.textContent = t(`${select.dataset.i18nOptionPrefix}.${option.value}`);
		}

		document.addEventListener(NGRAMS_EVENT, (event) =>
			setCorpus({ id: MY_TYPING_ID, tables: event.detail, default: true })
		);

		// The fingering editor, drawn on the chosen keyboard.
		let fingeringView = null;

		function start() {
			applyStrings();
			fillCorpora();
			fillLayouts();
			fillWeights();
			fillIdealLoad();
			fillShortcuts();
			fillForms();
			fingeringView = FINGERING.mount($('la-fingering'), { keyboard: () => state.keyboard });
			window.LAYOUT_ANALYSIS_FILES.onEditorLayouts(useEditorLayouts);
			FINGERING.onChange(() => analyse());
			bind();
			analyse();
			if (opts.reportHeight) reportHeight();
			// The host's personal layouts (app data folder, site IndexedDB).
			if (HOST.store)
				HOST.store
					.list()
					.then(addLayouts, () => showStatus(t('layout_analysis.status.store_failed')));
		}

		start();
		if (lastNgrams) setCorpus({ id: MY_TYPING_ID, tables: lastNgrams, default: true });
		// The « Autres analyseurs » view (analyser_tab.js): both pages load it.
		window.LAYOUT_ANALYSER_TAB.attach(root.querySelector('#la-analysers'), {
			comparer: { onResults }
		});
		mounted = { setCorpus, addLayouts, setFormat, onResults };
		return mounted;
	}

	/** The mounted Comparer; the late-data calls need one. */
	function instance() {
		if (!mounted) throw new Error('layout_analysis: the Comparer is not mounted');
		return mounted;
	}

	window.LAYOUT_ANALYSIS_COMPARER = {
		mount,
		setCorpus: (corpus) => instance().setCorpus(corpus),
		addLayouts: (list) => instance().addLayouts(list),
		setFormat: (id) => instance().setFormat(id),
		onResults: (listener) => instance().onResults(listener)
	};
	// Keystats tables that arrive before the mount wait for it.
	document.addEventListener(NGRAMS_EVENT, (event) => {
		if (!mounted) lastNgrams = event.detail;
	});

	/** The site's page: mount into its <main>, and size the framing page. */
	function autostart() {
		const root = document.getElementById(STANDALONE_ROOT_ID);
		if (!root) return;
		mount(root, { reportHeight: true });
		// The layout the site's editor handed over with « Compare with other layouts ».
		const handed = window.LAYOUT_ANALYSIS_FILES.takeHandoff();
		if (handed) instance().addLayouts([handed]);
	}

	if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', autostart);
	else autostart();
})();
