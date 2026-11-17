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
 *    a later one (the app's fresh read after its saved one) replaces its
 *    tables without changing the user's corpus;
 *    LAYOUT_ANALYSIS_COMPARER.addLayouts adds personal layouts; a host `store` ({list, save, remove}, promises) keeps imported layouts instead
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
 * 13. The heatmap shows the presses, the points each key costs the score or
 *    any per-key metric (costs and gains), each key naming its worst groups;
 *    against another layout it shows the key-by-key difference. Folded
 *    figures follow: the worst pairs and trigrams of the board, bigram and
 *    trigram classes, each finger's travel, modifiers and dead keys, and the
 *    layout's standing among the compared ones; every number is the engine's.
 * 14. The ranking table's columns (any metric) and row filters (name, family,
 *    score range) are the viewer's, kept with the other conveniences.
 * 15. The key pair matrix (how often, or score points, each key pair) scrolls
 *    inside its own box at phone width and is also a sortable table; the
 *    effort per word reads the corpus's word table (built-in or pasted).
 * ==============================================================================
 */

(function () {
	'use strict';

	const E = window.LAYOUT_ANALYSIS;
	const DATA = window.LAYOUT_ANALYSIS_DATA;
	const INFO = window.LAYOUT_ANALYSIS_INFO;
	const FINGERING = window.LAYOUT_ANALYSIS_FINGERING;
	const UNDO = window.LAYOUT_ANALYSIS_UNDO;
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
		'unsupported',
		'distinct_chars',
		'coverage_bonus',
		'simplicity'
	];
	// What the heatmap can show: the presses, the points each key costs the
	// score, or any per-key metric of the engine (its costs and its gains).
	const HEAT_PRESSES = 'presses';
	const HEAT_SCORE = 'score';
	const HEAT_CHOICES = [HEAT_PRESSES, HEAT_SCORE].concat(
		E.KEY_COST_METRICS,
		E.KEY_GAINS,
		E.KEY_INFO_METRICS
	);
	// The key pair matrix: its busiest keys on each axis (every letter of a
	// layout fits), how its cells are coloured, and the rows of its table.
	const MATRIX_MAX_KEYS = 32;
	const MATRIX_COUNT = 'count';
	const MATRIX_POINTS = 'points';
	const MATRIX_CHOICES = [MATRIX_COUNT, MATRIX_POINTS];
	const MATRIX_TABLE_ROWS = 100;
	// The word effort figure: its ranges of effort and its hardest words.
	const WORD_BINS = 10;
	const HARDEST_WORDS = 15;
	// Digits of a key's value in the heatmap.
	const HEAT_DIGITS = 2;
	// How many metrics a key's score tooltip names, worst first.
	const HEAT_SCORE_PARTS = 3;
	// A difference key is at most this mix of its colour, so its ink stays readable.
	const HEAT_DIFF_MAX_SHARE = 0.7;
	// The bigram classes and trigram classes shown as shares (engine metrics and
	// trigramClasses).
	const BIGRAM_CLASSES = [
		'sfb',
		'repeat',
		'lsb',
		'scissors',
		'half_scissors',
		'row_jump',
		'roll_in',
		'roll_out',
		'hand_change'
	];
	const TRIGRAM_CLASSES = [
		'roll3_in',
		'roll3_out',
		'alternation',
		'redirect',
		'roll_mixed',
		'same_finger'
	];
	// How many characters « typed via » lists, most frequent first.
	const TYPING_ROWS = 12;
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
	// The message the framing page listens for to size its frame.
	const HEIGHT_MESSAGE = 'ergopti-layout-analysis:height';
	// The app's keystats n-grams: the event its Studio window dispatches and the
	// corpus id they take (the default corpus in the app, maintainer 2026-11-14).
	const NGRAMS_EVENT = 'studio-ngrams';
	// The state of that read: 'loading', then the tables, or 'failed'.
	const NGRAMS_STATE_EVENT = 'studio-ngrams-state';
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
	<details id="la-layouts-box" class="la-layouts-box">
	<summary id="la-layouts-summary"></summary>
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
	</details>
</section>

<p id="la-status" class="la-status" role="status" aria-live="polite"></p>

<section id="la-results" class="la-results" aria-labelledby="la-chart-label">
	<div class="la-heading la-heading-wide">
		<h2 id="la-chart-label" data-i18n="layout_analysis.chart.title"></h2>
		<button id="la-share" type="button" data-i18n="layout_analysis.share.button"></button>
	</div>
	<p id="la-share-status" class="la-muted" role="status" hidden></p>
	<p class="la-muted" data-i18n="layout_analysis.chart.caption"></p>
	<div id="la-chart" class="la-chart"></div>
	<details id="la-table-options" class="la-table-options">
		<summary data-i18n="layout_analysis.table.options"></summary>
		<fieldset class="la-columns">
			<legend data-i18n="layout_analysis.table.columns"></legend>
			<div id="la-column-list" class="la-column-list"></div>
		</fieldset>
		<div class="la-table-filters">
			<label class="la-filter-field">
				<span data-i18n="layout_analysis.table.filter_name"></span>
				<input id="la-row-name" type="search" />
			</label>
			<label class="la-filter-field">
				<span data-i18n="layout_analysis.table.filter_family"></span>
				<select id="la-row-family"></select>
			</label>
			<label class="la-filter-field">
				<span data-i18n="layout_analysis.table.score_min"></span>
				<input id="la-row-min" type="number" step="any" />
			</label>
			<label class="la-filter-field">
				<span data-i18n="layout_analysis.table.score_max"></span>
				<input id="la-row-max" type="number" step="any" />
			</label>
		</div>
		<button id="la-table-reset" type="button" data-i18n="layout_analysis.table.reset"></button>
	</details>
	<p id="la-table-count" class="la-muted" role="status"></p>
	<div class="la-table-wrap" tabindex="0">
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
	<div class="la-heat-controls">
		<label class="la-sr-only" for="la-heat-metric" data-i18n="layout_analysis.details.heatmap"></label>
		<select id="la-heat-metric"></select>
		<label id="la-heat-diff-field" class="la-check" hidden>
			<input id="la-heat-diff" type="checkbox" />
			<span id="la-heat-diff-label"></span>
		</label>
	</div>
	<div id="la-heatmap" class="la-heatmap"></div>
	<div id="la-heat-legend" class="la-heat-legend"></div>
	<details id="la-heat-table-box" class="la-section">
		<summary data-i18n="layout_analysis.heat.table"></summary>
		<div class="la-table-wrap" tabindex="0">
			<table id="la-heat-table" class="la-table"></table>
		</div>
	</details>
	<details class="la-section">
		<summary data-i18n="layout_analysis.worst.title"></summary>
		<p class="la-muted" data-i18n="layout_analysis.worst.caption"></p>
		<label for="la-worst-event" data-i18n="layout_analysis.worst.event"></label>
		<select id="la-worst-event"></select>
		<div class="la-table-wrap" tabindex="0">
			<table id="la-worst" class="la-table"></table>
		</div>
	</details>
	<details class="la-section">
		<summary data-i18n="layout_analysis.matrix.title"></summary>
		<p id="la-matrix-caption" class="la-muted"></p>
		<label for="la-matrix-by" data-i18n="layout_analysis.matrix.by"></label>
		<select id="la-matrix-by"></select>
		<div id="la-matrix-legend" class="la-heat-legend"></div>
		<div class="la-matrix-wrap" tabindex="0" role="region" aria-labelledby="la-matrix-caption">
			<table id="la-matrix" class="la-matrix"></table>
		</div>
		<h4 data-i18n="layout_analysis.matrix.table"></h4>
		<p id="la-matrix-count" class="la-muted"></p>
		<div class="la-table-wrap" tabindex="0">
			<table id="la-matrix-pairs" class="la-table"></table>
		</div>
	</details>
	<details class="la-section">
		<summary data-i18n="layout_analysis.words.title"></summary>
		<p class="la-muted" data-i18n="layout_analysis.words.caption"></p>
		<p id="la-words-none" class="la-muted" data-i18n="layout_analysis.words.none" hidden></p>
		<div id="la-words-body">
			<p id="la-words-mean" class="la-muted"></p>
			<h4 id="la-words-bins-label" data-i18n="layout_analysis.words.distribution"></h4>
			<div id="la-words-bins" class="la-bars" aria-labelledby="la-words-bins-label"></div>
			<h4 data-i18n="layout_analysis.words.hardest"></h4>
			<div class="la-table-wrap" tabindex="0">
				<table id="la-words" class="la-table"></table>
			</div>
		</div>
	</details>
	<details class="la-section">
		<summary data-i18n="layout_analysis.classes.title"></summary>
		<h4 id="la-bigram-classes-label" data-i18n="layout_analysis.classes.bigrams"></h4>
		<div id="la-bigram-classes" class="la-bars" aria-labelledby="la-bigram-classes-label"></div>
		<h4 id="la-trigram-classes-label" data-i18n="layout_analysis.classes.trigrams"></h4>
		<div id="la-trigram-classes" class="la-bars" aria-labelledby="la-trigram-classes-label"></div>
	</details>
	<details class="la-section">
		<summary id="la-travel-label" data-i18n="layout_analysis.travel.title"></summary>
		<p class="la-muted" data-i18n="layout_analysis.travel.caption"></p>
		<div id="la-travel" class="la-bars" aria-labelledby="la-travel-label"></div>
	</details>
	<details class="la-section">
		<summary id="la-layers-label" data-i18n="layout_analysis.layers.title"></summary>
		<p class="la-muted" data-i18n="layout_analysis.layers.caption"></p>
		<div id="la-layers" class="la-bars" aria-labelledby="la-layers-label"></div>
	</details>
	<details class="la-section">
		<summary id="la-standing-label" data-i18n="layout_analysis.standing.title"></summary>
		<p class="la-muted" data-i18n="layout_analysis.standing.caption"></p>
		<div id="la-standing" class="la-bars" aria-labelledby="la-standing-label"></div>
	</details>
	<div class="la-detail-grid">
		<div>
			<h3 id="la-contributions-label" data-i18n="layout_analysis.details.contributions"></h3>
			<div id="la-contributions" class="la-bars" aria-labelledby="la-contributions-label"></div>
		</div>
		<div>
			<h3 id="la-fingers-label" data-i18n="layout_analysis.details.fingers"></h3>
			<p class="la-muted" data-i18n="layout_analysis.details.fingers_caption"></p>
			<ul class="la-legend">
				<li><span class="la-swatch la-swatch-load"></span><span data-i18n="layout_analysis.details.share_mark"></span></li>
				<li><span class="la-swatch la-swatch-ideal"></span><span data-i18n="layout_analysis.details.ideal_mark"></span></li>
			</ul>
			<div id="la-fingers" class="la-bars" aria-labelledby="la-fingers-label"></div>
			<h3 id="la-hands-rows-label" data-i18n="layout_analysis.details.hands_rows"></h3>
			<div id="la-hands-rows" class="la-bars" aria-labelledby="la-hands-rows-label"></div>
		</div>
	</div>
	<h3 data-i18n="layout_analysis.details.metrics"></h3>
	<div class="la-table-wrap" tabindex="0">
		<table id="la-metrics" class="la-table"></table>
	</div>
	<p id="la-unsupported" class="la-muted"></p>
	<h3 data-i18n="layout_analysis.details.typing"></h3>
	<p id="la-typing-caption" class="la-muted"></p>
	<div class="la-table-wrap" tabindex="0">
		<table id="la-typing" class="la-table"></table>
	</div>
	<h3 data-i18n="layout_analysis.details.simplicity"></h3>
	<table id="la-simplicity" class="la-table"></table>
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

	/**
	 * The « My typing » read as the Comparer lists it: none when the user has no
	 * keystats store yet.
	 * @param {{state: string, reason?: string}} detail
	 * @returns {{state: string, reason: string}|null}
	 */
	function readingState(detail) {
		if (!detail || (detail.state !== 'loading' && detail.state !== 'failed')) return null;
		return { state: detail.state, reason: String(detail.reason || '') };
	}

	let mounted = null;
	// The app's last keystats tables, kept when they arrive before the mount.
	let lastNgrams = null;
	// The app's keystats read: null (none: the site, or no store yet), else
	// { state: 'loading' | 'failed', reason }.
	let myTypingState = null;

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
		// Every number in the language of the page's strings (info_popover.js).
		const format = INFO.format;
		const metricDigits = E.metricDigits;

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
						imported,
						// The ranking table's columns and filters, and the heatmap's choice.
						table: state.table,
						heat: state.heat,
						heatDiff: state.heatDiff,
						matrixBy: state.matrixBy
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
			const spec = DATA.model.keyboards[keyboard];
			// A JIS or ABNT board takes the layouts made for ISO (its layout_geometry).
			const geometry = spec.layout_geometry || spec.geometry || 'iso';
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
			table: validTable(saved.table),
			heat: HEAT_CHOICES.includes(saved.heat) ? saved.heat : HEAT_PRESSES,
			// With a layout to compare with, the heatmap shows the key-by-key difference.
			heatDiff: saved.heatDiff === true,
			// The key pair matrix's colour (how often, or score points) and its table's sort.
			matrixBy: MATRIX_CHOICES.includes(saved.matrixBy) ? saved.matrixBy : MATRIX_COUNT,
			matrixSort: { key: 'count', descending: true },
			// The chosen corpus's word table (word → count), null when it has none.
			words: null,
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

		/**
		 * The ranking table's saved columns (metric ids the engine still has, the
		 * default set when none) and row filters (a name, a family, a score range).
		 */
		function validTable(table) {
			const value = table && typeof table === 'object' ? table : {};
			const columns = Array.isArray(value.columns)
				? value.columns.filter((id) => id in E.METRICS)
				: TABLE_METRICS.slice();
			const bound = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
			return {
				columns,
				name: typeof value.name === 'string' ? value.name : '',
				family: typeof value.family === 'string' ? value.family : '',
				min: bound(value.min),
				max: bound(value.max)
			};
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

		/**
		 * The chosen corpus's word table, once its tables are loaded: a built-in
		 * corpus's (shipped with its n-grams), a host's when it sends one, the
		 * user's text's; null for a corpus of letter counts only (count tables,
		 * the keystats).
		 */
		function corpusWords() {
			const corpus = corpora.find((c) => c.id === state.corpus);
			if (corpus.host) return corpus.host.tables.words || null;
			if (corpus.builtin) {
				const raw = (window.LAYOUT_ANALYSIS_CORPORA || {})[corpus.id];
				return (raw && raw.words) || null;
			}
			return (state.custom && state.custom.words) || null;
		}

		/** Reduces the user's text to tables and its word table, once per distinct text. */
		function useText(text) {
			const trimmed = text.trim();
			if (trimmed === '') {
				state.custom = null;
			} else {
				const hash = E.hashText(trimmed);
				if (!state.custom || state.custom.hash !== hash || !state.custom.words)
					state.custom = {
						hash,
						tables: E.ngramsFromText(trimmed),
						words: E.wordsFromText(trimmed)
					};
			}
			save();
			analyse();
		}

		// ==========================
		// ======= 4/ Analysis ======
		// ==========================

		/** The options every analysis of the page uses: board, format, weights and tables. */
		function analysisOptions() {
			return {
				keyboard: state.keyboard,
				format: state.format,
				weights: state.weights,
				idealLoad: state.idealLoad,
				shortcuts: state.shortcuts,
				formWeights: state.formWeights,
				profile: FINGERING.current(state.keyboard) || undefined
			};
		}

		// The layout shown in detail, analysed again with every key's worst groups
		// (keyGroups): a ranking counts only the SFB ones. Kept per result, so a new
		// analysis (new results) analyses it again.
		const detailed = new WeakMap();
		function detailOf(result) {
			if (!detailed.has(result))
				detailed.set(
					result,
					E.analyse(
						byId.get(result.layout.id),
						state.tables,
						Object.assign(analysisOptions(), { keyGroups: true })
					)
				);
			return detailed.get(result);
		}

		let generation = 0;
		// Extra views (other analysers' scores) told about each comparison.
		const resultListeners = [];

		/** Analyses the selected layouts on the chosen corpus and redraws. */
		/** The collapsed list's line: how many layouts are compared, and which. */
		function showLayoutsSummary() {
			const names = layouts.filter((l) => state.selected.has(l.id)).map((l) => l.name);
			$('la-layouts-summary').textContent = t('layout_analysis.layouts.summary', {
				count: names.length,
				names: names.join(', ')
			});
		}

		async function analyse() {
			showLayoutsSummary();
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
			state.words = tables ? corpusWords() : null;
			const chosen = layouts.filter((layout) => state.selected.has(layout.id));
			if (!tables || chosen.length === 0) {
				state.results = [];
				showStatus(t('layout_analysis.status.empty'));
				render();
				return;
			}
			const start = performance.now();
			state.results = E.compare(chosen, tables, analysisOptions());
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

		/**
		 * The required characters a layout lacks, as the page writes them: the
		 * space by its name, the letters as they are.
		 * @param {string[]} chars - result.coverage.missingRequired.
		 * @returns {string}
		 */
		function missingText(chars) {
			return chars
				.map((char) => (char === ' ' ? t('layout_analysis.incomplete.space') : char))
				.join(' ');
		}

		/** The flag an incomplete layout carries in the chart and the table. */
		function incompleteFlag(result) {
			return el(
				'span',
				'la-incomplete-flag',
				t('layout_analysis.incomplete.flag', {
					chars: missingText(result.coverage.missingRequired)
				})
			);
		}

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

		/**
		 * Horizontal bars of the global score, best first. The score has no
		 * natural zero (each metric adds or removes its weighted value), so the
		 * bars run from the weakest layout shown to the best one: the longest is
		 * the best, and each value names its gap to the first. The user's own
		 * layouts take the accent colour.
		 */
		function renderChart() {
			const box = $('la-chart');
			box.replaceChildren();
			const shown = state.results.slice(0, CHART_MAX_BARS);
			if (shown.length === 0) return;
			const totals = shown.map((r) => r.score.total);
			const best = Math.max(...totals);
			const worst = Math.min(...totals);
			const span = best - worst;
			for (const result of shown) {
				const row = el('div', 'la-chart-row');
				const value = format(result.score.total, 1);
				const gap = result.score.total - best;
				// An incomplete layout ranks after the complete ones and says what it lacks.
				const flag = result.incomplete ? incompleteFlag(result) : null;
				openOnActivate(
					row,
					result.layout.id,
					t('layout_analysis.chart.row', {
						layout: flag ? `${result.layout.name} (${flag.textContent})` : result.layout.name,
						rank: result.rank,
						score: value
					})
				);
				if (state.details === result.layout.id) row.classList.add('la-selected');
				if (flag) row.classList.add('la-incomplete');
				// The name starts with the visible text, name then value (WCAG 2.5.3);
				// the spaces between the cells, unrendered in the grid, keep the
				// two words apart in that visible text.
				const label = el('span', 'la-chart-label', result.layout.name);
				if (flag) label.append(' ', flag);
				row.append(label, ' ');
				const track = el('span', 'la-chart-track');
				const layout = byId.get(result.layout.id);
				const personal = !layout || !SHAREABLE_ORIGINS.includes(layout.origin);
				const bar = el('span', personal ? 'la-bar la-bar-mine' : 'la-bar la-bar-score');
				// The weakest keeps a sliver, so every row shows a bar; one layout alone is full.
				const share = span > 0 ? (result.score.total - worst) / span : 1;
				bar.style.left = '0%';
				bar.style.width = `${3 + share * 97}%`;
				track.append(bar);
				row.title = `${result.layout.name}: ${value} ${t('layout_analysis.unit.points')}${
					flag ? ` (${flag.textContent})` : ''
				}`;
				const cell = el('span', 'la-chart-value', value);
				if (gap < 0) cell.append(' ', el('span', 'la-chart-gap', `(${format(gap, 1)})`));
				row.append(track, ' ', cell);
				box.append(row);
			}
		}

		/** A compared layout's family ('' for none). */
		function familyOf(result) {
			const layout = byId.get(result.layout.id);
			return (layout && layout.family) || '';
		}

		/** The results the table's row filters keep: name, family and score range. */
		function shownRows() {
			const { name, family, min, max } = state.table;
			const needle = name.trim().toLowerCase();
			return state.results.filter(
				(r) =>
					(!needle || r.layout.name.toLowerCase().includes(needle)) &&
					(!family || familyOf(r) === family) &&
					(min === null || r.score.total >= min) &&
					(max === null || r.score.total <= max)
			);
		}

		/** The column choices (every metric, in the engine's order) and the filters' values. */
		function fillTableOptions() {
			const list = $('la-column-list');
			list.replaceChildren(
				...Object.keys(E.METRICS).map((id) => {
					const label = el('label', 'la-check');
					const box = el('input');
					box.type = 'checkbox';
					box.value = id;
					box.checked = state.table.columns.includes(id);
					box.addEventListener('change', () => {
						// The engine's order, whatever order the boxes were ticked in.
						const ticked = new Set(
							Array.from(list.querySelectorAll('input:checked'), (input) => input.value)
						);
						state.table.columns = Object.keys(E.METRICS).filter((m) => ticked.has(m));
						save();
						renderTable();
					});
					label.append(box, el('span', '', t(`layout_analysis.metric.${id}`)));
					return label;
				})
			);
			const families = Array.from(new Set(layouts.map((l) => l.family).filter(Boolean))).sort();
			const all = el('option', '', t('layout_analysis.table.family_all'));
			all.value = '';
			$('la-row-family').replaceChildren(
				all,
				...families.map((family) => {
					// A family is named by its first layout's name (Ergopti, Bépo…).
					const option = el('option', '', layouts.find((l) => l.family === family).name);
					option.value = family;
					return option;
				})
			);
			if (!families.includes(state.table.family)) state.table.family = '';
			$('la-row-family').value = state.table.family;
			$('la-row-name').value = state.table.name;
			$('la-row-min').value = state.table.min === null ? '' : String(state.table.min);
			$('la-row-max').value = state.table.max === null ? '' : String(state.table.max);
		}

		/** The ranking table, sortable by any column, with its chosen columns and rows. */
		function renderTable() {
			const table = $('la-table');
			table.replaceChildren();
			const count = $('la-table-count');
			count.textContent = '';
			if (state.results.length === 0) return;
			const shown = shownRows();
			count.textContent = t('layout_analysis.table.count', {
				shown: shown.length,
				total: state.results.length
			});
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
				state.table.columns.map((id) => ({
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
			// A sorted column the user hid sorts by rank again.
			if (!columns.some((c) => c.key === state.sort.key))
				state.sort = { key: 'rank', descending: false };
			const sortColumn = columns.find((c) => c.key === state.sort.key);
			const rows = shown.slice().sort((a, b) => {
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
					const cell = el(
						'td',
						'',
						column.digits === undefined ? String(value) : format(value, column.digits)
					);
					if (column.key === 'name' && result.incomplete) cell.append(' ', incompleteFlag(result));
					tr.append(cell);
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
			box.setAttribute('role', 'table');
			const extent = Math.max(...entries.map(([, v]) => Math.abs(v)), 1e-9);
			for (const [label, value] of entries) {
				const track = el('span', 'la-chart-track la-signed');
				const bar = el('span', value >= 0 ? 'la-bar la-bar-gain' : 'la-bar la-bar-loss');
				const width = (Math.abs(value) / extent) * 50;
				bar.style.left = value >= 0 ? '50%' : `${50 - width}%`;
				bar.style.width = `${width}%`;
				track.append(bar);
				const text = `${value > 0 ? '+' : ''}${format(value, digits)}`;
				const row = barRow(label, track, text, ` ${unit}`);
				row.title = `${label}: ${text} ${unit}`;
				box.append(row);
			}
		}

		/**
		 * One bar of a figure, read as a table row by assistive technology:
		 * the label is its row header, the value its cell, the drawn bar
		 * hidden (it repeats the value). The box holding the rows is the table,
		 * named by its heading (aria-labelledby in the markup).
		 * @param {string} label
		 * @param {HTMLElement} track The drawn bar.
		 * @param {string} text The value as written beside the bar.
		 * @param {string} [spoken] What the cell adds for a screen reader only:
		 *   the unit, the ideal load.
		 * @returns {HTMLElement}
		 */
		function barRow(label, track, text, spoken) {
			const row = el('div', 'la-chart-row');
			row.setAttribute('role', 'row');
			const header = el('span', 'la-chart-label', label);
			header.setAttribute('role', 'rowheader');
			track.setAttribute('aria-hidden', 'true');
			const value = el('span', 'la-chart-value', text);
			value.setAttribute('role', 'cell');
			if (spoken) value.append(el('span', 'la-sr-only', spoken));
			row.append(header, track, value);
			return row;
		}

		/**
		 * Magnitude bars from zero, in one colour, each with an optional target
		 * mark (the ideal finger load); the value is written in its unit.
		 * @param {HTMLElement} box
		 * @param {Array<{label: string, value: number, target?: number, text?: string}>} entries
		 *   text: the value as written, when it is not the value in its unit.
		 * @param {number} scale The value a full bar stands for.
		 * @param {{unit?: string, digits?: number}} [written] The unit (%) and
		 *   decimals (1) of the values.
		 */
		function loadBars(box, entries, scale, written) {
			const unit = (written && written.unit) || '%';
			const digits = written && written.digits !== undefined ? written.digits : 1;
			const value = (v) => `${format(v, digits)} ${unit}`;
			box.replaceChildren();
			box.setAttribute('role', 'table');
			for (const entry of entries) {
				const track = el('span', 'la-chart-track');
				const bar = el('span', 'la-bar la-bar-load');
				bar.style.left = '0';
				bar.style.width = `${scale > 0 ? Math.min(100, (entry.value / scale) * 100) : 0}%`;
				track.append(bar);
				const text = entry.text === undefined ? value(entry.value) : entry.text;
				// The ideal mark is drawn only: a screen reader hears it with the value.
				let ideal = '';
				if (entry.target !== undefined) {
					const mark = el('span', 'la-target');
					mark.style.left = `${Math.min(100, (entry.target / scale) * 100)}%`;
					track.append(mark);
					ideal = ` (${t('layout_analysis.details.ideal_mark')}: ${value(entry.target)})`;
				}
				const row = barRow(entry.label, track, text, ideal);
				row.title = `${entry.label}: ${text}${ideal}`;
				box.append(row);
			}
		}

		/** A metric's unit as written beside its value. */
		function unitText(id) {
			const unit = E.METRICS[id].unit;
			if (unit === 'chars') return t('layout_analysis.unit.chars');
			return unit === 'mm' ? t('layout_analysis.unit.mm') : '%';
		}

		/** What a key types on its base layer, as the heatmap and the tables show it. */
		function keyText(layout, code) {
			if (code === 'Space') return '␣';
			const row = layout.rows[code];
			// A dead key shows its bare accent (what it types alone).
			const dead = row && row[0] && typeof row[0] === 'object' ? row[0].dead : null;
			if (dead !== null)
				return KEY_LEGEND.deadKeyText(((layout.dead || {})[dead] || {})[' '] || '') || dead;
			return row && typeof row[0] === 'string' && row[0] !== '' ? row[0] : code;
		}

		/** The name of a heatmap choice. */
		function heatName(id) {
			if (id === HEAT_PRESSES) return t('layout_analysis.heat.presses');
			if (id === HEAT_SCORE) return t('layout_analysis.panel.heat.score');
			return t(`layout_analysis.metric.${id}`);
		}

		/** The unit of a heatmap choice's values. */
		function heatUnit(id) {
			if (id === HEAT_PRESSES) return '%';
			if (id === HEAT_SCORE) return t('layout_analysis.unit.points');
			return unitText(id);
		}

		/**
		 * Each key's value for the chosen heatmap: the engine's per-key value
		 * (keyValues) or the points it costs the score (keyScoreCost); with a
		 * layout to compare with and the difference asked for, this layout's
		 * value minus the other's on the same physical key (keyDiff).
		 * @returns {object} code → value.
		 */
		function heatValues(detail, other) {
			if (state.heat === HEAT_SCORE) {
				const own = E.keyScoreCost(detail, state.weights);
				if (!other) return own;
				const theirs = E.keyScoreCost(other, state.weights);
				return Object.fromEntries(Object.keys(own).map((code) => [code, own[code] - theirs[code]]));
			}
			return other ? E.keyDiff(detail, other, state.heat) : E.keyValues(detail, state.heat);
		}

		/**
		 * A key's tooltip line: its value in the chosen unit, then its worst
		 * groups for a bad event, or the metrics it costs the most points on.
		 */
		function heatTitle(detail, layout, code, value, signed) {
			const unit = heatUnit(state.heat);
			const written = `${signed && value > 0 ? '+' : ''}${format(value, HEAT_DIGITS)} ${unit}`;
			let title = `${keyText(layout, code)} · ${heatName(state.heat)}: ${written}`;
			if (signed) return title;
			const key = detail.keys[code];
			if (E.KEY_EVENTS.includes(state.heat) && key.worst[state.heat].length > 0) {
				const groups = key.worst[state.heat]
					.map(
						([others, share]) =>
							`${[code]
								.concat(others)
								.map((c) => keyText(layout, c))
								.join(' ')} ${format(share, HEAT_DIGITS)} %`
					)
					.join(', ');
				title += ` — ${t('layout_analysis.panel.heat.worst', { groups })}`;
			} else if (state.heat === HEAT_SCORE) {
				const used = Object.assign(E.defaultWeights(), state.weights);
				const parts = E.KEY_COST_METRICS.map((id) => [id, (used[id] || 0) * key.cost[id]])
					.filter(([, part]) => part > 0)
					.sort((a, b) => b[1] - a[1])
					.slice(0, HEAT_SCORE_PARTS)
					.map(([id, part]) => `${t(`layout_analysis.metric.${id}`)} ${format(part, HEAT_DIGITS)}`);
				if (parts.length > 0) title += ` (${parts.join(' · ')})`;
			}
			return title;
		}

		/**
		 * Where each drawn key is, in words a screen reader and the table can
		 * say: its row from the top and its rank from the left in that row.
		 * @param {{codes: string[], x: number[], y: number[]}} board
		 * @param {string[]} shown The drawn codes.
		 * @returns {Map<string, {row: number, column: number}>}
		 */
		function keyPositions(board, shown) {
			const drawn = new Set(shown);
			const keys = board.codes
				.map((code, k) => ({ code, x: board.x[k], y: board.y[k] }))
				.filter((key) => drawn.has(key.code));
			const rows = Array.from(new Set(keys.map((key) => key.y))).sort((a, b) => a - b);
			const out = new Map();
			rows.forEach((y, r) => {
				keys
					.filter((key) => key.y === y)
					.sort((a, b) => a.x - b.x)
					.forEach((key, c) => out.set(key.code, { row: r + 1, column: c + 1 }));
			});
			return out;
		}

		/**
		 * The heatmap's numbers as a table, its text alternative: every drawn
		 * key with its place, its finger and its value, largest first (by size
		 * for a difference, its sign written).
		 * @param {object} layout
		 * @param {Array<{code: string, where: string, finger: string, value: number}>} rows
		 * @param {boolean} signed A difference with another layout.
		 */
		function renderHeatTable(layout, rows, signed) {
			const table = $('la-heat-table');
			const unit = heatUnit(state.heat);
			const head = el('tr');
			for (const label of [
				t('layout_analysis.heat.table_key'),
				t('layout_analysis.heat.table_position'),
				t('layout_analysis.heat.table_finger'),
				`${heatName(state.heat)} (${unit})`
			]) {
				const th = el('th', '', label);
				th.scope = 'col';
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			const tbody = el('tbody');
			for (const row of rows.slice().sort((a, b) => Math.abs(b.value) - Math.abs(a.value))) {
				const tr = el('tr');
				const th = el('th', 'la-keys', keyText(layout, row.code));
				th.scope = 'row';
				const written = `${signed && row.value > 0 ? '+' : ''}${format(row.value, HEAT_DIGITS)}`;
				tr.append(
					th,
					el('td', '', row.where),
					el('td', '', row.finger ? t(`layout_analysis.finger.${row.finger}`) : ''),
					el('td', '', written)
				);
				tbody.append(tr);
			}
			table.replaceChildren(thead, tbody);
		}

		/**
		 * The board of the chosen keyboard, each key showing the layout's base
		 * character. One layout: shaded light to dark (one hue) by its share of
		 * the largest value of the chosen per-key metric. Against another layout
		 * (the difference): orange where this layout puts more, blue where less,
		 * stronger with the size of the gap, each tooltip signed. The legend
		 * gives the scale; every key is reachable from the keyboard with its
		 * value as its name. The board shrinks with the page instead of scrolling.
		 */
		function renderHeatmap(result) {
			const box = $('la-heatmap');
			box.replaceChildren();
			const detail = detailOf(result);
			const versus = state.results.find((r) => r.layout.id === state.versus) || null;
			const field = $('la-heat-diff-field');
			field.hidden = !versus;
			if (versus)
				$('la-heat-diff-label').textContent = t('layout_analysis.heat.diff', {
					layout: versus.layout.name
				});
			$('la-heat-diff').checked = state.heatDiff;
			const other = versus && state.heatDiff ? versus : null;
			const board = E.keyboard(result.keyboard, result.profile || undefined);
			const layout = byId.get(result.layout.id);
			const modifiers = new Set(Object.values(DATA.model.modifier_keys));
			const byCode = heatValues(detail, other);
			const shown = board.codes.filter((code) => !modifiers.has(code));
			const extent = Math.max(...shown.map((code) => Math.abs(byCode[code])), 0);
			const minX = Math.min(...board.x) - 0.5;
			const maxX = Math.max(...board.x) + 0.5;
			const maxY = Math.max(...board.y);
			const width = maxX - minX;
			// Positions in % of the board, so the whole board scales with its box.
			const across = (units) => `${(units / width) * 100}%`;
			const down = (units) => `${(units / maxY) * 100}%`;
			box.style.maxWidth = `${width * HEAT_UNIT_PX}px`;
			box.style.aspectRatio = `${width} / ${maxY}`;
			box.classList.toggle('la-heatmap-diff', Boolean(other));
			const position = keyPositions(board, shown);
			const tableRows = [];
			board.codes.forEach((code, k) => {
				if (modifiers.has(code)) return;
				const key = el('span', 'la-key', keyText(layout, code));
				const row = layout.rows[code];
				if (row && row[0] && typeof row[0] === 'object')
					key.classList.add(KEY_LEGEND.DEAD_KEY_CLASS);
				const value = byCode[code];
				const share = extent > 0 ? Math.abs(value) / extent : 0;
				const span = code === 'Space' ? SPACE_UNITS : 1;
				const left = code === 'Space' ? board.x[k] - SPACE_UNITS / 2 : board.x[k] - 0.5;
				key.style.left = across(left - minX);
				key.style.top = down(board.y[k] - 1);
				key.style.width = across(span);
				key.style.height = down(1);
				if (other) {
					key.classList.add(value > 0 ? 'la-key-more' : value < 0 ? 'la-key-less' : 'la-key-same');
					key.style.setProperty('--la-share', `${Math.round(share * HEAT_DIFF_MAX_SHARE * 100)}%`);
				} else {
					key.style.setProperty('--la-share', `${Math.round(share * 100)}%`);
					if (share >= HEAT_STRONG_SHARE) key.classList.add('la-key-strong');
				}
				const title = heatTitle(detail, layout, code, value, Boolean(other));
				const where = t('layout_analysis.heat.position', position.get(code));
				key.title = title;
				key.tabIndex = 0;
				key.setAttribute('role', 'img');
				// The name also says where the key is, which the drawing shows.
				key.setAttribute('aria-label', `${title} (${where})`);
				box.append(key);
				tableRows.push({ code, where, finger: DATA.model.fingers[board.finger[k]], value });
			});
			renderHeatTable(layout, tableRows, Boolean(other));
			const legend = $('la-heat-legend');
			const unit = heatUnit(state.heat);
			if (other) {
				// Both directions in words with a sign, never by colour alone.
				const swatch = (kind, mark, words) => {
					const item = el('span', 'la-heat-key');
					item.append(el('span', `la-swatch la-swatch-${kind}`), `${mark} ${words}`);
					return item;
				};
				legend.replaceChildren(
					swatch('more', '+', t('layout_analysis.heat.diff_more', { layout: other.layout.name })),
					swatch('less', '−', t('layout_analysis.heat.diff_less', { layout: other.layout.name })),
					el('span', 'la-muted', `± ${format(extent, HEAT_DIGITS)} ${unit}`)
				);
				return;
			}
			// The scale: what the lightest and the darkest key stand for.
			legend.replaceChildren(
				el('span', '', `${format(0, HEAT_DIGITS)} ${unit}`),
				el('span', 'la-heat-ramp'),
				el('span', '', `${format(extent, HEAT_DIGITS)} ${unit}`),
				el('span', 'la-muted', t('layout_analysis.heat.scale', { metric: heatName(state.heat) }))
			);
		}

		/** The heatmap's choices: the presses, the score, then every per-key metric. */
		function fillHeatChoices() {
			const select = $('la-heat-metric');
			select.replaceChildren(
				...HEAT_CHOICES.map((id) => {
					const option = el('option', '', heatName(id));
					option.value = id;
					return option;
				})
			);
			select.value = state.heat;
			const events = $('la-worst-event');
			const chosen = events.value || E.KEY_EVENTS[0];
			events.replaceChildren(
				...E.KEY_EVENTS.map((id) => {
					const option = el('option', '', t(`layout_analysis.metric.${id}`));
					option.value = id;
					return option;
				})
			);
			events.value = chosen;
			const by = $('la-matrix-by');
			by.replaceChildren(
				...MATRIX_CHOICES.map((id) => {
					const option = el('option', '', t(`layout_analysis.matrix.by_${id}`));
					option.value = id;
					return option;
				})
			);
			by.value = state.matrixBy;
		}

		/**
		 * The heaviest key groups of the chosen bad event over the whole board
		 * (the engine's topGroups): the keys as typed, how often the corpus has
		 * them, and their share of the bigrams or trigrams.
		 */
		function renderWorst(result) {
			const detail = detailOf(result);
			const layout = byId.get(result.layout.id);
			const event = $('la-worst-event').value || E.KEY_EVENTS[0];
			const table = $('la-worst');
			const head = el('tr');
			for (const label of [
				t('layout_analysis.worst.keys'),
				t('layout_analysis.worst.count'),
				t('layout_analysis.worst.share')
			]) {
				const th = el('th', '', label);
				th.scope = 'col';
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			const tbody = el('tbody');
			const groups = detail.topGroups[event];
			if (groups.length === 0) {
				const tr = el('tr');
				const td = el('td', 'la-muted', t('layout_analysis.worst.none'));
				td.colSpan = 3;
				tr.append(td);
				tbody.append(tr);
			}
			for (const group of groups) {
				const tr = el('tr');
				tr.append(
					el('td', 'la-keys', group.keys.map((code) => keyText(layout, code)).join(' ')),
					el('td', '', format(group.count, 0)),
					el('td', '', `${format(group.share, HEAT_DIGITS)} %`)
				);
				tbody.append(tr);
			}
			table.replaceChildren(thead, tbody);
		}

		// The pair matrix and word efforts of a result, kept per result and weights
		// (a weight change re-scores the same results without a new analysis).
		const figureCache = new WeakMap();
		function cachedFigure(result, name, compute) {
			if (!figureCache.has(result)) figureCache.set(result, {});
			const entry = figureCache.get(result);
			const key = `${JSON.stringify(state.weights)}|${name === 'words' ? state.corpus : ''}`;
			if (!entry[name] || entry[name].key !== key || entry[name].words !== state.words)
				entry[name] = { key, words: state.words, value: compute() };
			return entry[name].value;
		}

		/** A table header row of sort buttons; the sort is the viewer's (state[sortName]). */
		function sortableHead(columns, sortName, redraw) {
			const head = el('tr');
			for (const column of columns) {
				const th = el('th', 'la-sortable');
				th.scope = 'col';
				const sort = el('button', 'la-sort', column.label);
				sort.type = 'button';
				sort.addEventListener('click', () => {
					const current = state[sortName];
					state[sortName] =
						current.key === column.key
							? { key: column.key, descending: !current.descending }
							: { key: column.key, descending: column.numeric };
					redraw();
				});
				th.append(sort);
				if (state[sortName].key === column.key)
					th.setAttribute('aria-sort', state[sortName].descending ? 'descending' : 'ascending');
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			return thead;
		}

		/**
		 * The key pair matrix (the engine's bigramMatrix): the busiest keys on
		 * both axes, first key by row, second by column, each cell coloured by
		 * how often the pair occurs (one hue, light to dark) or by the score
		 * points it gains (blue, « + ») or costs (orange, « − ») into the
		 * neutral surface. The figure scrolls inside its own box on a narrow
		 * screen; every pair is also in a sortable table, and each cell names
		 * its pair, share, count, kind and points to assistive technology.
		 */
		function renderMatrix(result) {
			const layout = byId.get(result.layout.id);
			const matrix = cachedFigure(result, 'matrix', () =>
				E.bigramMatrix(layout, state.tables, analysisOptions())
			);
			const byPoints = state.matrixBy === MATRIX_POINTS;
			const keys = matrix.keys.slice(0, MATRIX_MAX_KEYS);
			$('la-matrix-caption').textContent = t('layout_analysis.matrix.caption', {
				keys: keys.length,
				all: matrix.keys.length
			});
			const value = (pair) => (byPoints ? pair.points : pair.share);
			const at = new Map(matrix.pairs.map((pair) => [pair.keys.join(' '), pair]));
			const shown = matrix.pairs.filter(
				(pair) => keys.includes(pair.keys[0]) && keys.includes(pair.keys[1])
			);
			const extent = Math.max(...shown.map((pair) => Math.abs(value(pair))), 0);
			const eventsText = (pair) =>
				pair.events.map((id) => t(`layout_analysis.metric.${id}`)).join(', ');
			const signed = (v, digits) => `${v > 0 ? '+' : ''}${format(v, digits)}`;
			const describe = (pair) =>
				t('layout_analysis.matrix.cell', {
					first: keyText(layout, pair.keys[0]),
					second: keyText(layout, pair.keys[1]),
					share: format(pair.share, HEAT_DIGITS),
					count: format(pair.count, 0),
					events: eventsText(pair),
					points: signed(pair.points, HEAT_DIGITS)
				});
			const table = $('la-matrix');
			const head = el('tr');
			head.append(el('td'));
			for (const code of keys) {
				const th = el('th', 'la-keys', keyText(layout, code));
				th.scope = 'col';
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			const tbody = el('tbody');
			for (const first of keys) {
				const tr = el('tr');
				const th = el('th', 'la-keys', keyText(layout, first));
				th.scope = 'row';
				tr.append(th);
				for (const second of keys) {
					const td = el('td', 'la-cell');
					const pair = at.get(`${first} ${second}`);
					if (pair) {
						const v = value(pair);
						const share = extent > 0 ? Math.abs(v) / extent : 0;
						if (byPoints) {
							// The sign in the cell, never the colour alone.
							td.classList.add(v > 0 ? 'la-cell-gain' : v < 0 ? 'la-cell-loss' : 'la-cell-zero');
							td.style.setProperty(
								'--la-share',
								`${Math.round(share * HEAT_DIFF_MAX_SHARE * 100)}%`
							);
							td.append(el('span', '', v > 0 ? '+' : v < 0 ? '−' : ''));
						} else {
							td.classList.add('la-cell-count');
							td.style.setProperty('--la-share', `${Math.round(share * 100)}%`);
						}
						const text = describe(pair);
						td.title = text;
						td.append(el('span', 'la-sr-only', text));
					}
					tr.append(td);
				}
				tbody.append(tr);
			}
			table.replaceChildren(thead, tbody);
			const legend = $('la-matrix-legend');
			const unit = byPoints ? t('layout_analysis.unit.points') : '%';
			if (byPoints) {
				const swatch = (kind, mark, words) => {
					const item = el('span', 'la-heat-key');
					item.append(el('span', `la-swatch la-swatch-${kind}`), `${mark} ${words}`);
					return item;
				};
				legend.replaceChildren(
					swatch('less', '+', t('layout_analysis.chart.gain')),
					swatch('more', '−', t('layout_analysis.chart.loss')),
					el('span', 'la-muted', `± ${format(extent, HEAT_DIGITS)} ${unit}`)
				);
			} else {
				legend.replaceChildren(
					el('span', '', `${format(0, HEAT_DIGITS)} ${unit}`),
					el('span', 'la-heat-ramp'),
					el('span', '', `${format(extent, HEAT_DIGITS)} ${unit}`),
					el(
						'span',
						'la-muted',
						t('layout_analysis.heat.scale', { metric: t('layout_analysis.matrix.by_count') })
					)
				);
			}
			renderMatrixPairs(layout, matrix, eventsText, signed);
		}

		/** Every pair of the matrix as a sortable table, the most frequent ones. */
		function renderMatrixPairs(layout, matrix, eventsText, signed) {
			const rows = matrix.pairs.slice(0, MATRIX_TABLE_ROWS);
			$('la-matrix-count').textContent = t('layout_analysis.matrix.table_count', {
				shown: rows.length,
				total: matrix.pairs.length
			});
			const columns = [
				{
					key: 'first',
					label: t('layout_analysis.matrix.first'),
					numeric: false,
					value: (p) => keyText(layout, p.keys[0])
				},
				{
					key: 'second',
					label: t('layout_analysis.matrix.second'),
					numeric: false,
					value: (p) => keyText(layout, p.keys[1])
				},
				{
					key: 'count',
					label: t('layout_analysis.worst.count'),
					numeric: true,
					value: (p) => p.count
				},
				{
					key: 'share',
					label: `${t('layout_analysis.worst.share')} (%)`,
					numeric: true,
					value: (p) => p.share
				},
				{
					key: 'events',
					label: t('layout_analysis.matrix.events'),
					numeric: false,
					value: eventsText
				},
				{
					key: 'points',
					label: `${t('layout_analysis.matrix.points')} (${t('layout_analysis.unit.points')})`,
					numeric: true,
					value: (p) => p.points
				}
			];
			const redraw = () => renderMatrixPairs(layout, matrix, eventsText, signed);
			const thead = sortableHead(columns, 'matrixSort', redraw);
			const column = columns.find((c) => c.key === state.matrixSort.key) || columns[2];
			const sorted = rows.slice().sort((a, b) => {
				const x = column.value(a);
				const y = column.value(b);
				const order = typeof x === 'string' ? x.localeCompare(y) : x - y;
				return state.matrixSort.descending ? -order : order;
			});
			const tbody = el('tbody');
			for (const pair of sorted) {
				const tr = el('tr');
				tr.append(
					el('td', 'la-keys', keyText(layout, pair.keys[0])),
					el('td', 'la-keys', keyText(layout, pair.keys[1])),
					el('td', '', format(pair.count, 0)),
					el('td', '', format(pair.share, HEAT_DIGITS)),
					el('td', '', eventsText(pair)),
					el('td', '', signed(pair.points, HEAT_DIGITS))
				);
				tbody.append(tr);
			}
			$('la-matrix-pairs').replaceChildren(thead, tbody);
		}

		/**
		 * Effort per word (the engine's wordEfforts on the corpus's word table):
		 * the mean, how the occurrences spread over ranges of effort, and the
		 * hardest words with what costs them most. A corpus of letter counts
		 * only says it has no word table.
		 */
		function renderWords(result) {
			const words = state.words && Object.keys(state.words).length > 0 ? state.words : null;
			$('la-words-none').hidden = Boolean(words);
			$('la-words-body').hidden = !words;
			if (!words) return;
			const layout = byId.get(result.layout.id);
			const efforts = cachedFigure(result, 'words', () =>
				E.wordEfforts(layout, words, analysisOptions())
			);
			const points = t('layout_analysis.unit.points');
			$('la-words-mean').textContent = t('layout_analysis.words.mean', {
				mean: format(efforts.mean, 1),
				words: format(efforts.words.length, 0),
				unsupported: format(efforts.unsupported.length, 0)
			});
			const bins = E.effortDistribution(efforts.words, WORD_BINS);
			loadBars(
				$('la-words-bins'),
				bins.map((bin) => ({
					label: t('layout_analysis.words.bin', {
						from: format(bin.from, 0),
						to: format(bin.to, 0)
					}),
					value: bin.share
				})),
				Math.max(...bins.map((bin) => bin.share), 0)
			);
			const head = el('tr');
			for (const label of [
				t('layout_analysis.words.word'),
				t('layout_analysis.worst.count'),
				`${t('layout_analysis.words.effort')} (${points})`,
				t('layout_analysis.words.part')
			]) {
				const th = el('th', '', label);
				th.scope = 'col';
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			const tbody = el('tbody');
			for (const entry of efforts.words.slice(0, HARDEST_WORDS)) {
				const [worst] = Object.entries(entry.parts).sort((a, b) => b[1] - a[1]);
				const tr = el('tr');
				tr.append(
					el('td', 'la-keys', entry.word),
					el('td', '', format(entry.count, 0)),
					el('td', '', format(entry.effort, 1)),
					el(
						'td',
						'',
						worst && worst[1] > 0
							? `${t(`layout_analysis.metric.${worst[0]}`)} ${format(worst[1], 1)}`
							: ''
					)
				);
				tbody.append(tr);
			}
			$('la-words').replaceChildren(thead, tbody);
		}

		/**
		 * The other figures of the details: bigram and trigram classes, each
		 * finger's travel, modifiers and dead keys, and the standing among the
		 * compared layouts, all from the engine's numbers.
		 */
		function renderFigures(result) {
			const metricLabel = (id) => t(`layout_analysis.metric.${id}`);
			loadBars(
				$('la-bigram-classes'),
				BIGRAM_CLASSES.map((id) => ({ label: metricLabel(id), value: result.metrics[id] })),
				100
			);
			const trigramLabel = {
				roll_mixed: t('layout_analysis.classes.roll_mixed'),
				same_finger: t('layout_analysis.classes.same_finger')
			};
			loadBars(
				$('la-trigram-classes'),
				TRIGRAM_CLASSES.map((id) => ({
					label: trigramLabel[id] || metricLabel(id),
					value: result.trigramClasses[id]
				})),
				100
			);
			const travel = Object.entries(result.fingerDistance);
			loadBars(
				$('la-travel'),
				travel.map(([id, mm]) => ({ label: t(`layout_analysis.finger.${id}`), value: mm })),
				Math.max(...travel.map(([, mm]) => mm), 0),
				{ unit: t('layout_analysis.unit.mm'), digits: 2 }
			);
			loadBars(
				$('la-layers'),
				['modifier_usage', 'dead_key_usage'].map((id) => ({
					label: metricLabel(id),
					value: result.metrics[id]
				})),
				100
			);
			const standing = E.standing(state.results, result.layout.id);
			loadBars(
				$('la-standing'),
				Object.entries(standing).map(([id, entry]) => ({
					label: metricLabel(id),
					value: entry.others > 0 ? entry.beats / entry.others : 0,
					text: t('layout_analysis.standing.value', { beats: entry.beats, others: entry.others })
				})),
				1
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

		/**
		 * How the layout types the corpus where it offers a choice: the share of
		 * the characters typed otherwise than their cheapest way out of context,
		 * each concerned character's ways with their shares, then the simplicity
		 * rules.
		 */
		function renderTyping(result, layout) {
			const rows = E.typingRows(result, layout, TYPING_ROWS);
			$('la-typing-caption').textContent =
				rows.length > 0
					? t('layout_analysis.details.typing_caption', {
							share: format(result.typing.changed, 2),
							count: result.typing.alternatives
						})
					: t('layout_analysis.details.typing_none');
			const table = $('la-typing');
			table.replaceChildren();
			table.hidden = rows.length === 0;
			if (rows.length > 0) {
				const head = el('tr');
				for (const key of ['typing_char', 'typing_ways']) {
					const th = el('th', '', t(`layout_analysis.details.${key}`));
					th.scope = 'col';
					head.append(th);
				}
				const thead = el('thead');
				thead.append(head);
				const tbody = el('tbody');
				for (const row of rows) {
					const tr = el('tr');
					// An invisible character is named by its code point.
					const name = /^[\s\p{C}]$/u.test(row.char)
						? `U+${row.char.codePointAt(0).toString(16).toUpperCase().padStart(4, '0')}`
						: row.char;
					const th = el('th', '', name);
					th.scope = 'row';
					const ways = row.ways
						.map(
							(way) =>
								`${t(`layout_analysis.typing.${way.kind}`)} ${way.keys} (${format(way.share, 0)} %)`
						)
						.join(' · ');
					tr.append(th, el('td', '', ways));
					tbody.append(tr);
				}
				table.append(thead, tbody);
			}
			const simplicity = $('la-simplicity');
			simplicity.replaceChildren();
			const body = el('tbody');
			for (const [id, rule] of Object.entries(result.simplicity)) {
				const tr = el('tr');
				const th = el('th', '', t(`layout_analysis.simplicity.${id}`));
				th.scope = 'row';
				const value = rule
					? `${format(rule.value, 0)} %`
					: t('layout_analysis.simplicity.not_measured');
				tr.append(th, el('td', '', value));
				body.append(tr);
			}
			simplicity.append(body);
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
			renderWorst(result);
			renderMatrix(result);
			renderWords(result);
			renderFigures(result);
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
			renderTyping(result, layout);
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
				result.incomplete
					? t('layout_analysis.incomplete.details', {
							chars: missingText(result.coverage.missingRequired)
						})
					: '',
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
			// The user's own text first, under its own heading (maintainer,
			// 2026-11-17): « My typing » while the app reads it, then the pasted
			// text; the built-in texts below.
			const mine = el('optgroup');
			mine.label = t('layout_analysis.corpus.group_mine');
			const texts = el('optgroup');
			texts.label = t('layout_analysis.corpus.group_texts');
			const hasMyTyping = corpora.some((c) => c.id === MY_TYPING_ID);
			if (!hasMyTyping && myTypingState) {
				const waiting = el(
					'option',
					'',
					t(
						myTypingState.state === 'loading'
							? 'layout_analysis.corpus.my_typing_loading'
							: 'layout_analysis.corpus.my_typing_unavailable'
					)
				);
				waiting.value = MY_TYPING_ID;
				waiting.disabled = true;
				if (myTypingState.reason) waiting.title = myTypingState.reason;
				mine.append(waiting);
			}
			for (const corpus of corpora) {
				const label =
					corpus.id === CUSTOM_ID
						? t('layout_analysis.corpus.custom')
						: corpus.id === MY_TYPING_ID && !corpus.title
							? t('layout_analysis.corpus.my_typing')
							: corpus.builtin && corpus.builtin.title_key
								? t(corpus.builtin.title_key)
								: corpus.title;
				const option = el('option', '', label);
				option.value = corpus.id;
				(corpus.builtin ? texts : mine).append(option);
			}
			select.append(...[mine, texts].filter((group) => group.children.length > 0));
			select.value = state.corpus;
			select.classList.toggle('la-corpus-mine', state.corpus === MY_TYPING_ID);
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
				timer = setTimeout(
					() => useText(event.target.value),
					window.LAYOUT_ANALYSIS_FILES.TEXT_DEBOUNCE_MS
				);
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
				save();
				renderDetails();
			});
			$('la-heat-diff').addEventListener('change', (event) => {
				state.heatDiff = event.target.checked;
				save();
				renderDetails();
			});
			$('la-worst-event').addEventListener('change', renderDetails);
			$('la-matrix-by').addEventListener('change', (event) => {
				state.matrixBy = event.target.value;
				save();
				renderDetails();
			});
			// The table's row filters: an empty or unreadable bound filters nothing.
			const bound = (input) => {
				const value = Number(input.value);
				return input.value === '' || !Number.isFinite(value) ? null : value;
			};
			const filtered = () => {
				state.table.name = $('la-row-name').value;
				state.table.family = $('la-row-family').value;
				state.table.min = bound($('la-row-min'));
				state.table.max = bound($('la-row-max'));
				save();
				renderTable();
			};
			for (const id of ['la-row-name', 'la-row-min', 'la-row-max'])
				$(id).addEventListener('input', filtered);
			$('la-row-family').addEventListener('change', filtered);
			$('la-table-reset').addEventListener('click', () => {
				state.table = validTable(null);
				fillTableOptions();
				save();
				renderTable();
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
			// Each restore acts at once and offers to put the user's values back
			// (undo_offer.js); a section already at its defaults has nothing to undo.
			const restorer = (buttonId, nameKey, part, defaults, refill) => {
				const button = $(buttonId);
				const undo = UNDO.create(button.closest('section'));
				button.after(undo.node);
				button.addEventListener('click', () => {
					const before = JSON.stringify(state[part]);
					state[part] = defaults();
					refill();
					if (before === JSON.stringify(state[part])) {
						undo.clear();
						return;
					}
					undo.offer({
						name: t(nameKey),
						focus: button,
						undo: () => {
							state[part] = JSON.parse(before);
							refill();
						}
					});
				});
			};
			restorer(
				'la-shortcuts-restore',
				'layout_analysis.shortcuts.title',
				'shortcuts',
				E.defaultShortcuts,
				() => {
					fillShortcuts();
					$('la-shortcuts-status').textContent = '';
					save();
					analyse();
				}
			);
			restorer(
				'la-forms-restore',
				'layout_analysis.forms.title',
				'formWeights',
				E.defaultFormFactorWeights,
				() => {
					fillForms();
					$('la-forms-status').textContent = '';
					save();
					analyse();
				}
			);
			restorer(
				'la-ideal-restore',
				'layout_analysis.ideal.title',
				'idealLoad',
				E.defaultIdealLoad,
				() => {
					fillIdealLoad();
					save();
					analyse();
				}
			);
			restorer('la-restore', 'layout_analysis.weights.title', 'weights', E.defaultWeights, () => {
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
				fillTableOptions();
				fillHeatChoices();
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
		 * Adds or replaces a corpus after load (the app's keystats tables arrive
		 * when the Studio opens: the last saved read at once, then a fresh one).
		 * A new corpus is listed first and selected when it is the default; a
		 * replaced one keeps the user's current choice, and is analysed again only
		 * while it is the chosen corpus.
		 * @param {{id: string, title?: string, tables: object, default?: boolean}} corpus
		 * @throws {Error} On tables the engine cannot read.
		 */
		function setCorpus(corpus) {
			E.prepareNgrams(corpus.tables);
			const entry = { id: corpus.id, title: corpus.title || '', host: { tables: corpus.tables } };
			const at = corpora.findIndex((c) => c.id === corpus.id);
			if (at >= 0) {
				corpora.splice(at, 1, entry);
				fillCorpora();
				if (state.corpus === corpus.id) analyse();
				return;
			}
			corpora.unshift(entry);
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
		// « My typing » listed at once, greyed while the app reads it or when it cannot.
		document.addEventListener(NGRAMS_STATE_EVENT, (event) => {
			myTypingState = readingState(event.detail);
			fillCorpora();
		});

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
			fillTableOptions();
			fillHeatChoices();
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
	// Keystats tables that arrive before the mount wait for it, and so does their state.
	document.addEventListener(NGRAMS_EVENT, (event) => {
		if (!mounted) lastNgrams = event.detail;
	});
	document.addEventListener(NGRAMS_STATE_EVENT, (event) => {
		if (!mounted) myTypingState = readingState(event.detail);
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
