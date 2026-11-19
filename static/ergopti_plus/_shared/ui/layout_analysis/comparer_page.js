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
 * 16. Sub-tabs (maintainer, 2026-11-18): overview, fingers and hands,
 *    bigrams, trigrams, rows and distance, side-by-side heat maps, coverage
 *    and more, other analysers, one layout. Every figure follows the filters
 *    (name, family, origin, language, completeness, score) and has a table;
 *    the corpus picker groups the built-in texts by language, each entry
 *    naming its kind.
 * ==============================================================================
 */

(function () {
	'use strict';

	const E = window.LAYOUT_ANALYSIS;
	const DATA = window.LAYOUT_ANALYSIS_DATA;
	const INFO = window.LAYOUT_ANALYSIS_INFO;
	const FINGERING = window.LAYOUT_ANALYSIS_FINGERING;
	// The score settings every Studio score reads (score_settings.js).
	const SCORE_SETTINGS = window.LAYOUT_ANALYSIS_SCORE_SETTINGS;
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
	// The class of a rank's cell: an ordinal, the one number a table writes
	// without a unit (studio-numbers.cjs).
	const RANK_CELL = 'la-rank';
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
		'pinky_ring',
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
	// The layouts scored between two yields to the page: one slice stays a short
	// task (each layout takes some 6 to 50 ms, by the corpus), so the page
	// answers while the whole library is scored and shows it as it comes.
	const ANALYSE_SLICE = 4;
	// The best so far is drawn again at most this often while the slices run
	// (ms), and at most once per this many times its own drawing cost, so the
	// drawing never takes more than a fifth of the time (649 layouts,
	// 2026-11-19: a full redraw of every tab cost 300 to 800 ms each time).
	const PARTIAL_RENDER_MS = 400;
	const PARTIAL_RENDER_FACTOR = 4;
	// The letter heading of a layout whose name starts with a digit or a sign.
	const LETTER_OTHER = '#';
	// The collapsed layout list names this many compared layouts, then counts the rest.
	const SUMMARY_NAMES = 8;
	const CHART_MAX_BARS = 40;
	// Widest size of one key unit of the heatmap, in pixels; narrower screens
	// shrink the whole board instead of scrolling it.
	const HEAT_UNIT_PX = 44;
	// Widest the space bar is drawn, in key units (the ISO and ANSI bar, shortened).
	const SPACE_UNITS = 6;
	const SPACE_CODE = 'Space';
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
	// Which text each layout types (maintainer, 2026-11-17): the keys typed
	// (the raw text, hotstring abbreviations included), the final text (after
	// hotstring expansions and AI completions), or the final text except the
	// layouts ticked « + » (Ergopti+ hotstrings), which type the keys typed. Only
	// a corpus that brings both texts (« My typing », schema 2) tells them apart.
	const TEXT_TYPED = window.LAYOUT_ANALYSIS_FILES.TEXT_MODES.typed;
	const TEXT_MIXED = window.LAYOUT_ANALYSIS_FILES.TEXT_MODES.mixed;
	const TEXT_MODES = Object.values(window.LAYOUT_ANALYSIS_FILES.TEXT_MODES);
	// A layout ticked « + » is ranked as « <name>+ » under the id « <id>+ »: a
	// library id never holds a « + », so the two never collide.
	const PLUS_SUFFIX = '+';

	// The Comparer's tabs, in order, at the top of the page (maintainer,
	// 2026-11-18): « Home » (the corpus, the layouts and the score settings),
	// then the results: the ranking, the figures by theme (after KLAnext's
	// result tabs), the other analysers and one layout in detail. A fresh visit
	// opens « Home », a link to a comparison its ranking, a link naming a
	// layout to detail the last.
	const TABS = [
		'home',
		'overview',
		'fingers',
		'bigrams',
		'trigrams',
		'rows',
		'heatmaps',
		'misc',
		'analysers',
		'details'
	];
	const HOME_TAB = 'home';
	const DEFAULT_TAB = 'overview';
	const DETAILS_TAB = 'details';
	// The score settings' weight groups, each a titled sub-section; every
	// weight of the score is in exactly one (test-layout-comparer-page.cjs).
	const WEIGHT_GROUPS = {
		pairs: ['sfb', 'sfs', 'sfb_distance', 'lsb', 'scissors', 'half_scissors', 'pinky_ring'],
		rolls: [
			'roll_in',
			'roll_out',
			'roll3_in',
			'roll3_out',
			'alternation',
			'redirect',
			'redirect_bad'
		],
		load: ['finger_imbalance', 'hand_imbalance', 'pinky_load'],
		position: ['home_row', 'distance', 'outer_column'],
		access: ['modifier_usage', 'altgr_usage', 'dead_key_usage'],
		bonuses: [
			'unsupported',
			'compact_fit',
			'char_coverage',
			'coverage_bonus',
			'simplicity',
			'direct_digits',
			'shortcut_left'
		]
	};
	// Each weight group's accent: its slot of theme.css « Chart look », drawn
	// on the section's edge and icon only, so the text keeps its contrast (the
	// static sections name theirs in the markup, la-accent-<slot>).
	const SECTION_SLOT = { pairs: 1, rolls: 2, load: 3, position: 4, access: 5, bonuses: 6 };
	// The settings sections' icons (24 × 24 strokes), decorative: each section
	// is named by its heading.
	const SECTION_ICONS = {
		pairs: 'M6 3h12v7H6zM6 14h12v7H6zM12 10v4',
		rolls: 'M4 17c2-7 9-10 15-6M16 8l3 3-3 3',
		load: 'M5 21V12M9 21V7M13 21V5M17 21V9M21 21V14',
		position: 'M12 3v5M12 16v5M3 12h5M16 12h5M12 9a3 3 0 1 0 0.01 0',
		access: 'M4 10h9v10H4zM10 4h10v10h-4M7 15h3',
		bonuses: 'M12 3l2.7 5.6 6.1.9-4.4 4.3 1 6.1L12 17l-5.4 2.9 1-6.1-4.4-4.3 6.1-.9z',
		config: 'M8 3v12M4 11l4 4 4-4M16 21V9M12 13l4-4 4 4',
		weights: 'M12 4v16M5 8h14M5 8l-3 6h6zM19 8l-3 6h6zM8 20h8',
		ideal: 'M6 21v-9M10 21V5M14 21V4M18 21V8M3 21h18',
		shortcuts: 'M3 7h18v10H3zM7 11h1M11 11h1M15 11h1M7 14h10',
		forms: 'M3 8h18v8H3zM3 12h18M9 8v8M15 8v8'
	};
	const SVG_NS = 'http://www.w3.org/2000/svg';
	// Each tab's icon (24 × 24 strokes, the settings sections' set) and its
	// accent slot of theme.css « Chart look » (maintainer, 2026-11-18: the tabs
	// say at a glance what each holds). Both are decorative: the tab's text
	// names it, and the chosen tab is marked by its bar and weight too.
	const TAB_ICONS = {
		home: 'M3 11l9-7 9 7M5 10v10h14V10M10 20v-6h4v6',
		overview: 'M4 20V11M10 20V4M16 20v-7M2 20h20',
		fingers: 'M7 21v-7l-2-3M10 14V5M13 14V3M16 14V5M19 14V8M7 14h12v2a5 5 0 0 1-5 5h-2',
		bigrams: 'M3 7h7v10H3zM14 7h7v10h-7z',
		trigrams: 'M2 8h5v8H2zM9.5 8h5v8h-5zM17 8h5v8h-5z',
		rows: 'M3 6h18M5 12h16M7 18h14',
		heatmaps: 'M3 3h8v8H3zM13 3h8v8h-8zM3 13h8v8H3zM13 13h8v8h-8z',
		misc: 'M12 3v18M3 12h18M6 6l12 12M18 6L6 18',
		analysers: 'M10 4a6 6 0 1 0 0.01 0M15 15l6 6',
		details: 'M7 3h7l5 5v13H7zM14 3v5h5M10 13h6M10 17h6'
	};
	const TAB_SLOT = {
		home: 1,
		overview: 2,
		fingers: 3,
		bigrams: 4,
		trigrams: 5,
		rows: 6,
		heatmaps: 1,
		misc: 2,
		analysers: 3,
		details: 4
	};

	// The metrics each themed tab charts, one bar chart each and one table;
	// every metric of the engine is in exactly one tab (test-layout-comparer-page.cjs).
	const TAB_METRICS = {
		fingers: ['finger_imbalance', 'hand_imbalance', 'pinky_load'],
		bigrams: [
			'sfb',
			'sfs',
			'sfb_distance',
			'lsb',
			'scissors',
			'half_scissors',
			'pinky_ring',
			'row_jump',
			'repeat',
			'roll_in',
			'roll_out',
			'hand_change'
		],
		trigrams: ['roll3_in', 'roll3_out', 'alternation', 'redirect', 'redirect_bad'],
		rows: ['home_row', 'top_row', 'bottom_row', 'number_row', 'distance', 'outer_column'],
		misc: [
			'unsupported',
			'char_coverage',
			'distinct_chars',
			'coverage_bonus',
			'simplicity',
			'compact_fit',
			'direct_digits',
			'shortcut_left',
			'modifier_usage',
			'altgr_usage',
			'dead_key_usage'
		]
	};
	// The parts of the stacked figures, each drawn in its categorical slot of
	// theme.css « Chart look », in this fixed order (colour follows the part).
	const TRIGRAM_MIX = [
		'roll3_in',
		'roll3_out',
		'alternation',
		'redirect',
		'roll_mixed',
		'same_finger'
	];
	const ROW_MIX = ['number_row', 'top_row', 'home_row', 'bottom_row'];
	// The metrics whose best layout the overview names, beside the score.
	const LEADER_METRICS = [
		'sfb',
		'sfs',
		'lsb',
		'scissors',
		'redirect',
		'distance',
		'home_row',
		'roll_in',
		'finger_imbalance'
	];
	// How many boards the side-by-side heat maps draw, the first of the ranking.
	const HEATS_COUNTS = [2, 4, 6, 9, 12];
	const DEFAULT_HEATS_COUNT = 6;
	// A filter set to this value keeps everything.
	const ALL = '';
	const COMPLETE_CHOICES = ['all', 'yes', 'no'];
	// The narrowest page that opens the filters at first (a phone folds them).
	const FILTERS_OPEN_MIN_PX = 720;

	// The site's standalone page mounts the Comparer into this element.
	const STANDALONE_ROOT_ID = 'layout-analysis';

	// The site passes ?lang=<code>; i18n.js loads that locale, then English and French.
	const lang = new URLSearchParams(location.search).get('lang');
	if (lang && /^[a-z]{2}$/.test(lang)) window._i18n_locale = lang;

	// The Comparer's markup; data-i18n* attributes are filled by applyStrings().
	const MARKUP = `<div class="la-top">
	<h1 id="la-title" data-i18n="layout_analysis.title"></h1>
	<button id="la-share" type="button" data-i18n="layout_analysis.share.button"></button>
</div>
<p id="la-share-status" class="la-muted" role="status" hidden></p>

<div id="la-tabs" class="la-tabs" role="tablist" aria-labelledby="la-title"></div>
<p id="la-status" class="la-status" role="status" aria-live="polite"></p>

<div id="la-panel-home" class="la-tab-panel la-home" role="tabpanel" aria-labelledby="la-tab-home" hidden>
<div class="la-setup">
<section class="la-card la-corpus-card" aria-labelledby="la-corpus-label">
	<div class="la-field">
		<label
			id="la-corpus-label"
			class="la-card-title"
			for="la-corpus"
			data-i18n="layout_analysis.corpus.label"
		></label>
		<select id="la-corpus"></select>
		<p id="la-corpus-info" class="la-muted"></p>
	</div>
	<div id="la-text-mode-field" class="la-field" hidden>
		<label for="la-text-mode" data-i18n="layout_analysis.text_mode.label"></label>
		<select id="la-text-mode" data-i18n-option-prefix="layout_analysis.text_mode">
			<option value="typed"></option>
			<option value="final"></option>
			<option value="mixed"></option>
		</select>
		<p id="la-text-mode-info" class="la-muted"></p>
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
</section>

<section class="la-card la-options" aria-labelledby="la-options-label">
	<h2 id="la-options-label" class="la-card-title" data-i18n="layout_analysis.options.title"></h2>
	<div class="la-option-pair">
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
	</div>
</section>
</div>

<section class="la-card la-layouts" aria-labelledby="la-layouts-label">
	<h2 id="la-layouts-label" class="la-card-title" data-i18n="layout_analysis.layouts.label"></h2>
	<details id="la-layouts-box" class="la-layouts-box">
	<summary id="la-layouts-summary"></summary>
	<div class="la-row">
		<label class="la-filter-field la-pick-search">
			<span data-i18n="layout_analysis.layouts.search"></span>
			<input
				id="la-filter"
				type="search"
				aria-describedby="la-pick-count"
				data-i18n-placeholder="layout_analysis.layouts.filter_placeholder"
			/>
		</label>
		<label class="la-filter-field">
			<span data-i18n="layout_analysis.filter.origin"></span>
			<select id="la-pick-origin"></select>
		</label>
		<label class="la-filter-field">
			<span data-i18n="layout_analysis.filter.language"></span>
			<select id="la-pick-language"></select>
		</label>
	</div>
	<p id="la-pick-count" class="la-pick-count" role="status" aria-live="polite"></p>
	<div class="la-row la-pick-actions">
		<button id="la-every" type="button" data-i18n="layout_analysis.layouts.every"></button>
		<button id="la-clear" type="button" data-i18n="layout_analysis.layouts.clear"></button>
		<button id="la-all" type="button" data-i18n="layout_analysis.layouts.all"></button>
		<button id="la-none" type="button" data-i18n="layout_analysis.layouts.none"></button>
		<label class="la-file">
			<span class="la-file-button" data-i18n="layout_analysis.layouts.import"></span>
			<input id="la-import" type="file" />
		</label>
	</div>
	<p id="la-import-report" class="la-muted" hidden></p>
	<nav id="la-letters" class="la-letters"></nav>
	<div id="la-layout-list" class="la-layout-list"></div>
	</details>
</section>

<details id="la-settings" class="la-settings">
<summary data-i18n="layout_analysis.settings.title"></summary>
<section class="la-weights la-config la-accent-1" data-section-icon="config" aria-labelledby="la-config-label">
	<div class="la-heading">
		<h2 id="la-config-label" data-i18n="layout_analysis.config.title"></h2>
	</div>
	<p class="la-muted" data-i18n="layout_analysis.config.help"></p>
	<div class="la-config-actions">
		<button id="la-config-export" type="button" data-i18n="layout_analysis.config.export"></button>
		<label class="la-file">
			<span class="la-file-button" data-i18n="layout_analysis.config.import"></span>
			<input id="la-config-import" type="file" accept=".json,application/json" />
		</label>
		<button id="la-config-reset" type="button" data-i18n="layout_analysis.config.reset"></button>
	</div>
	<p id="la-config-status" class="la-muted" role="status"></p>
</section>

<section class="la-weights la-accent-2" data-section-icon="weights" aria-labelledby="la-weights-label">
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
	<div id="la-weight-list" class="la-weight-groups"></div>
</section>

<section class="la-weights la-accent-3" data-section-icon="ideal" aria-labelledby="la-ideal-label">
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
	<div class="la-ideal-layout">
		<svg
			id="la-ideal-hands"
			class="la-ideal-hands"
			viewBox="0 0 220 120"
			aria-hidden="true"
			focusable="false"
		></svg>
		<div id="la-ideal-list" class="la-weight-list"></div>
	</div>
	<p id="la-ideal-sum" class="la-muted" role="status"></p>
</section>

<section class="la-weights la-accent-4" data-section-icon="shortcuts" aria-labelledby="la-shortcuts-label">
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

<section class="la-weights la-accent-6" data-section-icon="forms" aria-labelledby="la-forms-label">
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
</details>
</div>

<section id="la-results" class="la-results" aria-labelledby="la-results-label">
	<h2 id="la-results-label" class="la-sr-only" data-i18n="layout_analysis.results.title"></h2>
	<details id="la-filters-box" class="la-filters-box">
	<summary>
		<span id="la-filters-label" class="la-filters-title" data-i18n="layout_analysis.filter.title"></span>
		<span id="la-table-count" class="la-muted" role="status"></span>
	</summary>
	<div class="la-filters" role="group" aria-labelledby="la-filters-label">
		<label class="la-filter-field la-filter-name">
			<span data-i18n="layout_analysis.table.filter_name"></span>
			<input id="la-row-name" type="search" />
		</label>
		<label class="la-filter-field">
			<span data-i18n="layout_analysis.table.filter_family"></span>
			<select id="la-row-family"></select>
		</label>
		<label class="la-filter-field">
			<span data-i18n="layout_analysis.filter.origin"></span>
			<select id="la-row-origin"></select>
		</label>
		<label class="la-filter-field">
			<span data-i18n="layout_analysis.filter.language"></span>
			<select id="la-row-language"></select>
		</label>
		<label class="la-filter-field">
			<span data-i18n="layout_analysis.filter.complete"></span>
			<select id="la-row-complete" data-i18n-option-prefix="layout_analysis.filter.complete_choice">
				<option value="all"></option>
				<option value="yes"></option>
				<option value="no"></option>
			</select>
		</label>
		<label class="la-filter-field la-filter-score">
			<span data-i18n="layout_analysis.table.score_min"></span>
			<input id="la-row-min" type="number" step="any" />
		</label>
		<label class="la-filter-field la-filter-score">
			<span data-i18n="layout_analysis.table.score_max"></span>
			<input id="la-row-max" type="number" step="any" />
		</label>
		<button id="la-table-reset" type="button" data-i18n="layout_analysis.table.reset"></button>
	</div>
	</details>

	<div id="la-panel-overview" class="la-tab-panel" role="tabpanel" aria-labelledby="la-tab-overview">
		<div class="la-overview">
			<section class="la-figure" aria-labelledby="la-chart-label">
				<h3 id="la-chart-label" data-i18n="layout_analysis.chart.title"></h3>
				<p class="la-muted" data-i18n="layout_analysis.chart.caption"></p>
				<div id="la-chart" class="la-chart"></div>
			</section>
			<section class="la-leaders-box" aria-labelledby="la-leaders-label">
				<h3 id="la-leaders-label" data-i18n="layout_analysis.leaders.title"></h3>
				<dl id="la-leaders" class="la-leaders"></dl>
			</section>
			<section class="la-figure la-figure-wide" aria-labelledby="la-ranking-label">
				<h3 id="la-ranking-label" data-i18n="layout_analysis.ranking.title"></h3>
				<details id="la-table-options" class="la-table-options">
					<summary data-i18n="layout_analysis.table.columns"></summary>
					<div id="la-column-list" class="la-column-list"></div>
				</details>
				<label class="la-check">
					<input id="la-table-relative" type="checkbox" aria-describedby="la-table-relative-help" />
					<span id="la-table-relative-label"></span>
				</label>
				<p id="la-table-relative-help" class="la-muted" hidden></p>
				<div class="la-table-wrap" tabindex="0" role="region" aria-labelledby="la-ranking-label">
					<table id="la-table" class="la-table"></table>
				</div>
			</section>
			<section class="la-figure la-figure-wide" aria-labelledby="la-ngrams-label">
				<h3 id="la-ngrams-label" data-i18n="layout_analysis.ngrams.title"></h3>
				<p id="la-ngrams-caption" class="la-muted"></p>
				<div class="la-ngrams-view">
					<div id="la-ngrams-board" class="la-heatmap la-ngrams-board" aria-hidden="true"></div>
					<div id="la-ngrams-list"></div>
				</div>
			</section>
		</div>
	</div>

	<div id="la-panel-fingers" class="la-tab-panel" role="tabpanel" aria-labelledby="la-tab-fingers" hidden>
		<p class="la-muted la-tab-intro" data-i18n="layout_analysis.tab.intro_fingers"></p>
		<section class="la-figure la-figure-wide" aria-labelledby="la-finger-table-label">
			<h3 id="la-finger-table-label" data-i18n="layout_analysis.fingers.title"></h3>
			<p class="la-muted" data-i18n="layout_analysis.fingers.caption"></p>
			<ul class="la-legend">
				<li><span class="la-swatch la-swatch-more"></span><span data-i18n="layout_analysis.fingers.over"></span></li>
				<li><span class="la-swatch la-swatch-less"></span><span data-i18n="layout_analysis.fingers.under"></span></li>
			</ul>
			<div class="la-table-wrap" tabindex="0" role="region" aria-labelledby="la-finger-table-label">
				<table id="la-finger-table" class="la-table la-heat-table"></table>
			</div>
		</section>
		<section class="la-figure la-figure-wide" aria-labelledby="la-hands-label">
			<h3 id="la-hands-label" data-i18n="layout_analysis.hands.title"></h3>
			<p class="la-muted" data-i18n="layout_analysis.hands.caption"></p>
			<ul id="la-hands-legend" class="la-legend"></ul>
			<div id="la-hands" class="la-bars" aria-labelledby="la-hands-label"></div>
		</section>
		<div id="la-charts-fingers" class="la-chart-grid"></div>
	</div>

	<div id="la-panel-bigrams" class="la-tab-panel" role="tabpanel" aria-labelledby="la-tab-bigrams" hidden>
		<p class="la-muted la-tab-intro" data-i18n="layout_analysis.tab.intro_bigrams"></p>
		<div id="la-charts-bigrams" class="la-chart-grid"></div>
	</div>

	<div id="la-panel-trigrams" class="la-tab-panel" role="tabpanel" aria-labelledby="la-tab-trigrams" hidden>
		<p class="la-muted la-tab-intro" data-i18n="layout_analysis.tab.intro_trigrams"></p>
		<section class="la-figure la-figure-wide" aria-labelledby="la-trigram-mix-label">
			<h3 id="la-trigram-mix-label" data-i18n="layout_analysis.trigram_mix.title"></h3>
			<p class="la-muted" data-i18n="layout_analysis.trigram_mix.caption"></p>
			<div id="la-trigram-mix"></div>
		</section>
		<div id="la-charts-trigrams" class="la-chart-grid"></div>
	</div>

	<div id="la-panel-rows" class="la-tab-panel" role="tabpanel" aria-labelledby="la-tab-rows" hidden>
		<p class="la-muted la-tab-intro" data-i18n="layout_analysis.tab.intro_rows"></p>
		<section class="la-figure la-figure-wide" aria-labelledby="la-row-mix-label">
			<h3 id="la-row-mix-label" data-i18n="layout_analysis.row_mix.title"></h3>
			<p class="la-muted" data-i18n="layout_analysis.row_mix.caption"></p>
			<div id="la-row-mix"></div>
		</section>
		<section class="la-figure la-figure-wide" aria-labelledby="la-travel-table-label">
			<h3 id="la-travel-table-label" data-i18n="layout_analysis.travel.title"></h3>
			<p class="la-muted" data-i18n="layout_analysis.travel.caption"></p>
			<div id="la-travel-legend" class="la-heat-legend"></div>
			<div class="la-table-wrap" tabindex="0" role="region" aria-labelledby="la-travel-table-label">
				<table id="la-travel-table" class="la-table la-heat-table"></table>
			</div>
		</section>
		<div id="la-charts-rows" class="la-chart-grid"></div>
	</div>

	<div id="la-panel-heatmaps" class="la-tab-panel" role="tabpanel" aria-labelledby="la-tab-heatmaps" hidden>
		<p class="la-muted la-tab-intro" data-i18n="layout_analysis.tab.intro_heatmaps"></p>
		<div class="la-heat-controls">
			<label class="la-filter-field">
				<span data-i18n="layout_analysis.heats.metric"></span>
				<select id="la-heats-metric"></select>
			</label>
			<label class="la-filter-field">
				<span data-i18n="layout_analysis.heats.count"></span>
				<select id="la-heats-count"></select>
			</label>
			<label class="la-check">
				<input id="la-heats-shared" type="checkbox" />
				<span data-i18n="layout_analysis.heats.shared"></span>
			</label>
		</div>
		<div id="la-heats-legend" class="la-heat-legend"></div>
		<div id="la-heats" class="la-heat-grid"></div>
	</div>

	<div id="la-panel-misc" class="la-tab-panel" role="tabpanel" aria-labelledby="la-tab-misc" hidden>
		<p class="la-muted la-tab-intro" data-i18n="layout_analysis.tab.intro_misc"></p>
		<div id="la-charts-misc" class="la-chart-grid"></div>
	</div>

	<div id="la-panel-analysers" class="la-tab-panel" role="tabpanel" aria-labelledby="la-tab-analysers" hidden>
		<section id="la-analysers" class="la-card" hidden></section>
	</div>

	<div id="la-panel-details" class="la-tab-panel" role="tabpanel" aria-labelledby="la-tab-details" hidden>
	<div class="la-field la-details-pick">
		<label for="la-details-layout" data-i18n="layout_analysis.details.layout"></label>
		<select id="la-details-layout"></select>
	</div>
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
		<div class="la-detail-grid">
			<div class="la-detail-main">
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
				<div id="la-heatmap-image"></div>
				<div id="la-heat-legend" class="la-heat-legend"></div>
				<details id="la-heat-table-box" class="la-section">
					<summary data-i18n="layout_analysis.heat.table"></summary>
					<div class="la-table-wrap" tabindex="0">
						<table id="la-heat-table" class="la-table"></table>
					</div>
				</details>
				<div class="la-detail-loads">
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
			<div>
				<h3 id="la-contributions-label" data-i18n="layout_analysis.details.contributions"></h3>
				<div id="la-contributions" class="la-bars" aria-labelledby="la-contributions-label"></div>
			</div>
		</div>
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
		<h3 data-i18n="layout_analysis.details.metrics"></h3>
		<div class="la-table-wrap" tabindex="0">
			<table id="la-metrics" class="la-table"></table>
		</div>
		<p id="la-unsupported" class="la-muted"></p>
		<div class="la-detail-grid">
			<div>
				<h3 data-i18n="layout_analysis.details.typing"></h3>
				<p id="la-typing-caption" class="la-muted"></p>
				<div class="la-table-wrap" tabindex="0">
					<table id="la-typing" class="la-table"></table>
				</div>
			</div>
			<div>
				<h3 data-i18n="layout_analysis.details.simplicity"></h3>
				<table id="la-simplicity" class="la-table"></table>
			</div>
		</div>
	</section>
	</div>
</section>`;

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

		/** Translates a locale key (info_popover.js t(): numbers as every number shown). */
		const t = INFO.t;

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
		// A number and its unit, tied by a no-break space (info_popover.js).
		const measure = INFO.measure;
		const withUnit = INFO.withUnit;
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
						textMode: state.textMode,
						plus: Array.from(state.plus),
						imported,
						// The ranking table's columns and filters, and the heatmap's choice.
						table: state.table,
						heat: state.heat,
						heatDiff: state.heatDiff,
						matrixBy: state.matrixBy,
						// The sub-tab the visitor last chose, the side-by-side heat maps'
						// choices and the layout list's filters.
						tab: state.tabSaved,
						heats: state.heats,
						pick: state.pick
					})
				);
				// The editor's panel and the optimizer of this page score with them too.
				SCORE_SETTINGS.notify();
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
		 * The layouts ticked until the user chooses: every layout the page lists
		 * (maintainer, 2026-11-18, after the registry and reference ones of
		 * 2026-11-15), but of a family that ships one layout per board (Ergopti
		 * and Ergopti ANSI) only the one of the chosen keyboard's geometry; the
		 * other stays listed, unticked. A board with no row-staggered geometry
		 * (split, ortholinear) takes ISO's. The page scores them by slices
		 * (ANALYSE_SLICE), so the whole library keeps it responsive.
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
			return new Set(layouts.filter((l) => !otherBoard(l)).map((l) => l.id));
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
			// The weights, ideal load, shortcut table (shortcut_left) and form factor
			// weights (compact_fit), read as every Studio score reads them.
			...SCORE_SETTINGS.parse(saved),
			custom: saved.custom && saved.custom.tables ? saved.custom : null,
			// Which text each layout types, and the layouts ticked « + » (TEXT_MIXED).
			textMode: TEXT_MODES.includes(saved.textMode) ? saved.textMode : TEXT_TYPED,
			plus: new Set(Array.isArray(saved.plus) ? saved.plus : []),
			tables: null,
			// The keys typed, which the « + » layouts type in TEXT_MIXED; null otherwise.
			rawTables: null,
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
			versus: linked.versus || null,
			// The sub-tab shown: a link's layout in detail opens « One layout »,
			// else the visitor's last choice (tabSaved, kept only when they click).
			tab: linked.details
				? DETAILS_TAB
				: linked.corpus || linked.layouts
					? DEFAULT_TAB
					: TABS.includes(saved.tab)
						? saved.tab
						: HOME_TAB,
			tabSaved: TABS.includes(saved.tab) ? saved.tab : HOME_TAB,
			// Each themed table's sort, by table name.
			tabSorts: {},
			heats: validHeats(saved.heats),
			pick: validFilters(saved.pick, ['origin', 'language'])
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
			const text = (v) => (typeof v === 'string' ? v : ALL);
			return {
				columns,
				name: text(value.name),
				family: text(value.family),
				origin: text(value.origin),
				language: text(value.language),
				complete: COMPLETE_CHOICES.includes(value.complete) ? value.complete : COMPLETE_CHOICES[0],
				min: bound(value.min),
				max: bound(value.max),
				// The relative view: each value as its difference to the reference layout.
				relative: value.relative === true
			};
		}

		/** The saved choices of the side-by-side heat maps, the defaults otherwise. */
		function validHeats(heats) {
			const value = heats && typeof heats === 'object' ? heats : {};
			return {
				metric: HEAT_CHOICES.includes(value.metric) ? value.metric : HEAT_PRESSES,
				count: HEATS_COUNTS.includes(value.count) ? value.count : DEFAULT_HEATS_COUNT,
				shared: value.shared !== false
			};
		}

		/** Saved filter values (strings) by name; a missing one keeps everything. */
		function validFilters(filters, names) {
			const value = filters && typeof filters === 'object' ? filters : {};
			return Object.fromEntries(
				names.map((name) => [name, typeof value[name] === 'string' ? value[name] : ALL])
			);
		}

		// ==========================
		// ======= 3/ Corpora =======
		// ==========================

		/**
		 * The final-text tables of a corpus that brings two texts (« My typing »
		 * since schema 2: the keys typed at the top level, the final text under
		 * `final`), or null for a corpus of one text. A built-in corpus is a
		 * book's n-gram tables: no keys were typed for it, and the Ergopti+
		 * hotstrings cannot be undone at n-gram level (an abbreviation replaces
		 * whole words, which character trigrams do not delimit), so it has one.
		 */
		function finalTables(corpus) {
			return corpus && corpus.host && corpus.host.tables.final ? corpus.host.tables.final : null;
		}

		/** Whether the chosen corpus tells the keys typed from the final text. */
		function hasTwoTexts() {
			return Boolean(finalTables(corpora.find((c) => c.id === state.corpus)));
		}

		/**
		 * The prepared tables of the chosen corpus by the text mode: `plain`, the
		 * text every layout types (null when the corpus has none yet), and `raw`,
		 * the keys typed that the layouts ticked « + » type (TEXT_MIXED on a
		 * corpus of two texts; null otherwise).
		 * @returns {Promise<{plain: object|null, raw: object|null}>}
		 */
		async function corpusTables() {
			const corpus = corpora.find((c) => c.id === state.corpus);
			if (corpus.host) {
				const plain = window.LAYOUT_ANALYSIS_FILES.plainTables(
					corpus.host.tables,
					appliedTextMode()
				);
				return {
					plain: E.prepareNgrams(plain),
					raw:
						finalTables(corpus) && appliedTextMode() === TEXT_MIXED
							? E.prepareNgrams(corpus.host.tables)
							: null
				};
			}
			if (corpus.builtin) {
				return {
					plain: E.prepareNgrams(await window.LAYOUT_ANALYSIS_FILES.builtinTables(corpus.builtin)),
					raw: null
				};
			}
			return { plain: state.custom ? E.prepareNgrams(state.custom.tables) : null, raw: null };
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

		// The « + » layouts compared (id « <id>+ » → the layout under its « + »
		// name), rebuilt by each analysis; they are not in the layout list.
		const plusById = new Map();

		/** A compared layout by its result's id: a listed layout or a « + » one. */
		function layoutOf(id) {
			return byId.get(id) || plusById.get(id);
		}

		/** The prepared tables a result was analysed on: a « + » layout types the keys typed. */
		function tablesOf(result) {
			return plusById.has(result.layout.id) ? state.rawTables : state.tables;
		}

		/** A layout ticked « + »: the same keys under « <name>+ ». */
		function plusLayout(layout) {
			return Object.assign({}, layout, {
				id: layout.id + PLUS_SUFFIX,
				name: layout.name + PLUS_SUFFIX
			});
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
						layoutOf(result.layout.id),
						tablesOf(result),
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
			$('la-layouts-summary').textContent =
				names.length > SUMMARY_NAMES
					? t('layout_analysis.layouts.summary_more', {
							count: names.length,
							names: names.slice(0, SUMMARY_NAMES).join(', '),
							more: names.length - SUMMARY_NAMES
						})
					: t('layout_analysis.layouts.summary', {
							count: names.length,
							names: names.join(', ')
						});
		}

		/** Gives the page a turn (input, paint) before the next slice of scoring. */
		function nextTask() {
			return new Promise((resolve) => {
				const channel = new MessageChannel();
				channel.port1.onmessage = () => resolve();
				channel.port2.postMessage(null);
			});
		}

		async function analyse() {
			showLayoutsSummary();
			const mine = ++generation;
			// A built-in corpus loads its tables once (up to a few megabytes): say so meanwhile.
			setBusy(true);
			let tables;
			let raw;
			try {
				({ plain: tables, raw } = await corpusTables());
			} catch {
				if (mine !== generation) return;
				setBusy(false);
				showStatus(t('layout_analysis.status.corpus_failed'));
				return;
			}
			if (mine !== generation) return;
			state.tables = tables;
			state.rawTables = raw;
			state.words = tables ? corpusWords() : null;
			showTextMode();
			const chosen = layouts.filter((layout) => state.selected.has(layout.id));
			// The « + » layouts type the keys typed, beside the others on the final text.
			plusById.clear();
			if (raw)
				for (const layout of layouts)
					if (state.plus.has(layout.id)) {
						const plus = plusLayout(layout);
						plusById.set(plus.id, plus);
					}
			if (!tables || chosen.length + plusById.size === 0) {
				setBusy(false);
				state.results = [];
				showStatus(t('layout_analysis.status.empty'));
				render();
				return;
			}
			const start = performance.now();
			const options = analysisOptions();
			// Each layout on its text: the « + » layouts on the keys typed.
			const pending = chosen
				.map((layout) => [layout, tables])
				.concat(Array.from(plusById.values(), (layout) => [layout, raw]));
			// The compared layouts themselves (rows, dead keys…), for extra scorers.
			const compared = new Map(pending.map(([layout]) => [layout.id, layout]));
			state.compared = compared;
			const scored = [];
			let drawn = start;
			let drawEvery = PARTIAL_RENDER_MS;
			for (let at = 0; at < pending.length; at += ANALYSE_SLICE) {
				for (const [layout, table] of pending.slice(at, at + ANALYSE_SLICE))
					scored.push(E.analyse(layout, table, options));
				if (scored.length === pending.length) break;
				showStatus(
					t('layout_analysis.status.scoring', { done: scored.length, count: pending.length })
				);
				// The best so far (chart and leaders, not the table or the other tabs),
				// drawn now and then while the rest is scored, less often as it costs
				// more, and not at all behind « Home ».
				if (state.tab !== HOME_TAB && performance.now() - drawn >= drawEvery) {
					state.results = E.rank(scored.slice());
					const began = performance.now();
					renderLeaders();
					renderChart();
					drawn = performance.now();
					drawEvery = Math.max(PARTIAL_RENDER_MS, PARTIAL_RENDER_FACTOR * (drawn - began));
				}
				await nextTask();
				if (mine !== generation) return;
			}
			state.results = E.rank(scored);
			setBusy(false);
			const ms = Math.round(performance.now() - start);
			for (const listener of resultListeners)
				listener(state.results, tables, {
					keyboard: state.keyboard,
					layouts: compared,
					tablesOf
				});
			showStatus(
				t('layout_analysis.status.ready', {
					count: state.results.length,
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

		// Literal keys, so the locale gate finds every string these labels show.
		const TAB_LABEL = {
			home: () => t('layout_analysis.tab.home'),
			overview: () => t('layout_analysis.tab.overview'),
			fingers: () => t('layout_analysis.tab.fingers'),
			bigrams: () => t('layout_analysis.tab.bigrams'),
			trigrams: () => t('layout_analysis.tab.trigrams'),
			rows: () => t('layout_analysis.tab.rows'),
			heatmaps: () => t('layout_analysis.tab.heatmaps'),
			misc: () => t('layout_analysis.tab.misc'),
			analysers: () => t('layout_analysis.tab.analysers'),
			details: () => t('layout_analysis.tab.details')
		};
		const DIRECTION_LABEL = {
			lower: () => t('layout_analysis.analysers.better.lower'),
			higher: () => t('layout_analysis.analysers.better.higher'),
			none: () => t('layout_analysis.details.verdict_none')
		};

		/** A metric's name as the page writes it. */
		function metricName(id) {
			return t(`layout_analysis.metric.${id}`);
		}

		/** A trigram class's name: a metric's, or one of the two classes that are not metrics. */
		function trigramClassName(id) {
			if (id === 'roll_mixed') return t('layout_analysis.classes.roll_mixed');
			if (id === 'same_finger') return t('layout_analysis.classes.same_finger');
			return metricName(id);
		}

		/**
		 * Where a layout comes from, as the filters group it: the registry, the
		 * references, the user's own, or the library collection it was imported from.
		 */
		function originOf(layout) {
			return layout.origin === 'library' ? layout.source : layout.origin;
		}

		/** An origin's name in the filters. */
		function originName(origin) {
			if (origin === 'registry') return t('layout_analysis.filter.origin_registry');
			if (origin === 'reference') return t('layout_analysis.filter.origin_reference');
			if (origin === 'user') return t('layout_analysis.filter.origin_user');
			const source = DATA.library_sources[origin];
			if (!source) throw new Error(`layout comparer: no library collection ${origin}`);
			return t('layout_analysis.filter.origin_collection', { name: source.name });
		}

		/** A language's own name in the page's language (« Français », « Deutsch » in English: « French »…). */
		function languageName(code) {
			const name = new Intl.DisplayNames([INFO.locale()], { type: 'language' }).of(code);
			return name.charAt(0).toUpperCase() + name.slice(1);
		}

		/**
		 * Fills a select with [value, label] entries and keeps its value when it
		 * is still offered, else the first entry's.
		 * @returns {string} The value chosen.
		 */
		function fillSelect(select, entries, value) {
			select.replaceChildren(
				...entries.map(([id, label]) => {
					const option = el('option', '', label);
					option.value = id;
					return option;
				})
			);
			select.value = entries.some(([id]) => id === value) ? value : entries[0][0];
			return select.value;
		}

		/** The distinct values of a list, the most frequent first, then by name. */
		function byFrequency(values, name) {
			const counts = new Map();
			for (const value of values) counts.set(value, (counts.get(value) || 0) + 1);
			return Array.from(counts.keys()).sort(
				(a, b) => counts.get(b) - counts.get(a) || name(a).localeCompare(name(b))
			);
		}

		/** Whether a result is one of the user's own layouts (accent colour). */
		function isPersonal(result) {
			const layout = layoutOf(result.layout.id);
			return !layout || !SHAREABLE_ORIGINS.includes(layout.origin);
		}

		function render() {
			const count = $('la-table-count');
			count.textContent =
				state.results.length > 0
					? t('layout_analysis.table.count', {
							shown: shownRows().length,
							total: state.results.length
						})
					: '';
			renderActive();
		}

		/**
		 * Draws the overview and the sub-tab shown; the others are drawn when
		 * they are chosen.
		 */
		function renderActive() {
			const draw = {
				overview: () => {
					renderLeaders();
					renderChart();
					renderTable();
					renderNgrams();
				},
				fingers: () => {
					renderFingerTable();
					renderHands();
					renderMetricTab('fingers');
				},
				bigrams: () => renderMetricTab('bigrams'),
				trigrams: () => {
					renderTrigramMix();
					renderMetricTab('trigrams');
				},
				rows: () => {
					renderRowMix();
					renderTravelTable();
					renderMetricTab('rows');
				},
				// « Home » holds controls only, filled as they change.
				home: () => {},
				heatmaps: renderHeatGrid,
				misc: () => renderMetricTab('misc'),
				// The other analysers' view follows the Comparer by itself (analyser_tab.js).
				analysers: () => {},
				details: () => {
					fillDetailsPick();
					renderDetails();
				}
			};
			// The ranking is cheap and always current, whichever tab is shown.
			draw.overview();
			if (state.tab !== DEFAULT_TAB) draw[state.tab]();
		}

		/** The tab strip: one button per sub-tab, its panel shown when it is chosen. */
		function fillTabs() {
			const list = $('la-tabs');
			list.replaceChildren(
				...TABS.map((id) => {
					const button = el('button', `la-tab la-tab-accent-${TAB_SLOT[id]}`);
					button.append(tabIcon(id), el('span', 'la-tab-label', TAB_LABEL[id]()));
					button.type = 'button';
					button.id = `la-tab-${id}`;
					button.setAttribute('role', 'tab');
					button.setAttribute('aria-controls', `la-panel-${id}`);
					button.addEventListener('click', () => chooseTab(id, true));
					// Arrows, Home and End move between the tabs (the ARIA tabs pattern).
					button.addEventListener('keydown', (event) => {
						const at = TABS.indexOf(id);
						const next = {
							ArrowRight: TABS[(at + 1) % TABS.length],
							ArrowLeft: TABS[(at - 1 + TABS.length) % TABS.length],
							Home: TABS[0],
							End: TABS[TABS.length - 1]
						}[event.key];
						if (!next) return;
						event.preventDefault();
						chooseTab(next, true);
						$(`la-tab-${next}`).focus();
					});
					return button;
				})
			);
			showTab();
		}

		/** A tab's decorative icon (TAB_ICONS): its text names the tab. */
		function tabIcon(id) {
			const svg = document.createElementNS(SVG_NS, 'svg');
			svg.setAttribute('class', 'la-tab-icon');
			svg.setAttribute('viewBox', '0 0 24 24');
			svg.setAttribute('aria-hidden', 'true');
			svg.setAttribute('focusable', 'false');
			const path = document.createElementNS(SVG_NS, 'path');
			path.setAttribute('d', TAB_ICONS[id]);
			svg.append(path);
			return svg;
		}

		/** Marks the chosen tab and shows its panel only. */
		function showTab() {
			for (const id of TABS) {
				const button = $(`la-tab-${id}`);
				const chosen = id === state.tab;
				button.setAttribute('aria-selected', String(chosen));
				button.tabIndex = chosen ? 0 : -1;
				$(`la-panel-${id}`).hidden = !chosen;
			}
			// The results' filters narrow the figures, not « Home »'s controls.
			$('la-filters-box').hidden = state.tab === HOME_TAB;
		}

		/** Shows a sub-tab; the visitor's own choice is kept for the next visit. */
		function chooseTab(id, byUser) {
			state.tab = id;
			if (byUser) {
				state.tabSaved = id;
				save();
			}
			showTab();
			renderActive();
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
		 * layouts take the accent colour. The filters choose the layouts drawn.
		 */
		function renderChart() {
			const box = $('la-chart');
			box.replaceChildren();
			const rows = shownRows();
			const shown = rows.slice(0, CHART_MAX_BARS);
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
				const bar = el('span', isPersonal(result) ? 'la-bar la-bar-mine' : 'la-bar la-bar-score');
				// The weakest keeps a sliver, so every row shows a bar; one layout alone is full.
				const share = span > 0 ? (result.score.total - worst) / span : 1;
				bar.style.left = '0%';
				bar.style.width = `${3 + share * 97}%`;
				track.append(bar);
				row.title = `${result.layout.name}: ${withUnit(value, t('layout_analysis.unit.points'))}${
					flag ? ` (${flag.textContent})` : ''
				}`;
				const cell = el('span', 'la-chart-value', value);
				if (gap < 0) cell.append(' ', el('span', 'la-chart-gap', `(${format(gap, 1)})`));
				row.append(track, ' ', cell);
				box.append(row);
			}
			if (rows.length > shown.length) box.append(moreNote(shown.length, rows.length));
		}

		/** The line under a chart that shows the first of the layouts only. */
		function moreNote(shown, total) {
			return el('p', 'la-muted', t('layout_analysis.chart.more', { shown, total }));
		}

		/**
		 * The overview's tiles: the best complete layout shown by the score and by
		 * a few telling metrics, each opening that layout's details.
		 */
		function renderLeaders() {
			const box = $('la-leaders');
			box.replaceChildren();
			const complete = shownRows().filter((r) => !r.incomplete);
			box.closest('section').hidden = complete.length === 0;
			if (complete.length === 0) return;
			const tile = (label, result, text) => {
				const item = el('div', isPersonal(result) ? 'la-leader la-leader-mine' : 'la-leader');
				const value = el('dd', 'la-leader-value', text);
				const name = el('button', 'la-leader-name', result.layout.name);
				name.type = 'button';
				name.addEventListener('click', () => showDetails(result.layout.id));
				const who = el('dd', 'la-leader-who');
				who.append(name);
				item.append(el('dt', '', label), value, who);
				box.append(item);
			};
			tile(
				t('layout_analysis.chart.title'),
				complete[0],
				measure(complete[0].score.total, 1, t('layout_analysis.unit.points'))
			);
			for (const id of LEADER_METRICS) {
				const higher = E.METRICS[id].better === 'higher';
				const best = complete.reduce((a, b) =>
					(higher ? b.metrics[id] > a.metrics[id] : b.metrics[id] < a.metrics[id]) ? b : a
				);
				tile(metricName(id), best, measure(best.metrics[id], metricDigits(id), unitText(id)));
			}
		}

		/** A compared layout's family ('' for none). */
		function familyOf(result) {
			const layout = layoutOf(result.layout.id);
			return (layout && layout.family) || '';
		}

		/**
		 * The results the filters keep, in the ranking's order: name, family,
		 * origin, language, completeness and score range. Every figure and table
		 * of the sub-tabs draws these.
		 */
		function shownRows() {
			const { name, family, origin, language, complete, min, max } = state.table;
			const needle = name.trim().toLowerCase();
			return state.results.filter((r) => {
				const layout = layoutOf(r.layout.id);
				return (
					(!needle || r.layout.name.toLowerCase().includes(needle)) &&
					(!family || familyOf(r) === family) &&
					(!origin || originOf(layout) === origin) &&
					(!language || layout.language === language) &&
					(complete === 'all' || (complete === 'yes') === !r.incomplete) &&
					(min === null || r.score.total >= min) &&
					(max === null || r.score.total <= max)
				);
			});
		}

		/** The origins and languages of the listed layouts, the most frequent first. */
		function layoutFacets() {
			return {
				origins: byFrequency(layouts.map(originOf), originName),
				languages: byFrequency(layouts.map((l) => l.language).filter(Boolean), languageName)
			};
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
					label.append(box, el('span', '', metricName(id)));
					return label;
				})
			);
			const families = Array.from(new Set(layouts.map((l) => l.family).filter(Boolean))).sort();
			state.table.family = fillSelect(
				$('la-row-family'),
				[[ALL, t('layout_analysis.table.family_all')]].concat(
					// A family is named by its first layout's name (Ergopti, Bépo…).
					families.map((family) => [family, layouts.find((l) => l.family === family).name])
				),
				state.table.family
			);
			const { origins, languages } = layoutFacets();
			const originEntries = [[ALL, t('layout_analysis.filter.origin_all')]].concat(
				origins.map((id) => [id, originName(id)])
			);
			const languageEntries = [[ALL, t('layout_analysis.filter.language_all')]].concat(
				languages.map((id) => [id, languageName(id)])
			);
			state.table.origin = fillSelect($('la-row-origin'), originEntries, state.table.origin);
			state.table.language = fillSelect(
				$('la-row-language'),
				languageEntries,
				state.table.language
			);
			state.pick.origin = fillSelect($('la-pick-origin'), originEntries, state.pick.origin);
			state.pick.language = fillSelect($('la-pick-language'), languageEntries, state.pick.language);
			$('la-row-complete').value = state.table.complete;
			$('la-row-name').value = state.table.name;
			$('la-row-min').value = state.table.min === null ? '' : String(state.table.min);
			$('la-row-max').value = state.table.max === null ? '' : String(state.table.max);
		}

		/**
		 * A ranking table of results, sortable by any column (a header button,
		 * its order in aria-sort): rank, layout, score and the given metrics. A
		 * row opens the layout's details by a click or Enter; an incomplete
		 * layout carries its flag.
		 * @param {HTMLTableElement} table
		 * @param {object[]} rows The results, in the ranking's order.
		 * @param {string[]} metricIds The metric columns.
		 * @param {{key: string, descending: boolean}} sort
		 * @param {function({key: string, descending: boolean}): void} resort
		 *   Called with the new sort when a header is chosen.
		 * @param {object} [reference] The result the relative view measures the
		 *   score and the metrics against (referenceResult), or none.
		 * @returns {{key: string, descending: boolean}} The sort applied (rank
		 *   when the sorted column is gone).
		 */
		function rankingTable(table, rows, metricIds, sort, resort, reference) {
			table.replaceChildren();
			if (rows.length === 0) return sort;
			const columns = [
				{ key: 'rank', label: t('layout_analysis.table.rank'), value: (r) => r.rank, digits: 0 },
				{ key: 'name', label: t('layout_analysis.table.layout'), value: (r) => r.layout.name },
				{
					key: 'score',
					label: t('layout_analysis.table.score'),
					// Its popover: the weights' explanation and the score's formula.
					info: 'weights',
					value: (r) => r.score.total,
					digits: 1,
					unit: t('layout_analysis.unit.points')
				}
			].concat(
				metricIds.map((id) => ({
					key: id,
					// The usual acronym when the name has one (« SFB »), the full
					// name in the button's accessible name and the « i » popover.
					label: INFO.metricShort(id) || metricName(id),
					name: metricName(id),
					info: id,
					value: (r) => r.metrics[id],
					digits: metricDigits(id),
					unit: unitText(id),
					// The order a first click asks for: the metric's better value first.
					higher: E.METRICS[id].better !== 'lower'
				}))
			);
			// A sorted column the user hid sorts by rank again.
			const applied = columns.some((c) => c.key === sort.key)
				? sort
				: { key: 'rank', descending: false };
			const head = el('tr');
			for (const column of columns) {
				// A metric's header wraps on two lines at most (style.css la-th-metric).
				const th = el('th', column.name ? 'la-sortable la-th-metric' : 'la-sortable');
				th.scope = 'col';
				// The sort is a button, so the keyboard reaches it.
				const button = el('button', 'la-sort', column.label);
				button.type = 'button';
				button.dataset.sort = column.key;
				// An acronym's button is named in full; the name starts the same (WCAG 2.5.3).
				if (column.name && column.name !== column.label)
					button.setAttribute('aria-label', column.name);
				button.addEventListener('click', () => {
					resort(
						applied.key === column.key
							? { key: column.key, descending: !applied.descending }
							: { key: column.key, descending: column.key === 'score' || Boolean(column.higher) }
					);
					// The table is drawn again: the focus stays on the same header.
					const again = table.isConnected ? table : document.getElementById(table.id) || table;
					const focus = again.querySelector(`button[data-sort="${column.key}"]`);
					if (focus) focus.focus();
				});
				const info =
					column.info && DATA.sources.items[column.info] ? infoButton(column.info) : null;
				if (column.name) {
					// The « i » stays beside the header's last line, never on a line of its own.
					const head = el('span', 'la-th-head');
					head.append(button, info);
					th.append(head);
				} else {
					th.append(button);
					if (info) th.append(' ', info);
				}
				if (applied.key === column.key)
					th.setAttribute('aria-sort', applied.descending ? 'descending' : 'ascending');
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			const sortColumn = columns.find((c) => c.key === applied.key);
			const sorted = rows.slice().sort((a, b) => {
				const x = sortColumn.value(a);
				const y = sortColumn.value(b);
				const order = typeof x === 'string' ? x.localeCompare(y) : x - y;
				return applied.descending ? -order : order;
			});
			const tbody = el('tbody');
			for (const result of sorted) {
				const tr = el('tr');
				if (state.details === result.layout.id) tr.className = 'la-selected';
				if (isPersonal(result)) tr.classList.add('la-row-mine');
				// The relative view: the score and each metric as their difference to the reference.
				const versus = reference ? E.diff(result, reference) : null;
				for (const column of columns) {
					const value = column.value(result);
					const cell =
						// The rank is an ordinal: it reads as is in the relative view too.
						versus && column.digits !== undefined && column.key !== 'rank'
							? relativeCell(
									column.key === 'score' ? versus.score : versus.metrics[column.key],
									column.digits,
									column.unit
								)
							: el(
									'td',
									column.key === 'rank' ? RANK_CELL : '',
									column.digits === undefined
										? String(value)
										: column.unit === undefined
											? format(value, column.digits)
											: measure(value, column.digits, column.unit)
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
			return applied;
		}

		/**
		 * The overview's worst n-grams of the layout shown in detail (else the
		 * best ranked): each bad event's heaviest pairs and trigrams, their keys
		 * outlined on its board when a row is hovered or focused (worst_groups.js).
		 */
		function renderNgrams() {
			const result =
				state.results.find((r) => r.layout.id === state.details) || state.results[0] || null;
			const box = $('la-ngrams-list');
			if (!result) {
				box.replaceChildren();
				$('la-ngrams-board').replaceChildren();
				return;
			}
			const layout = layoutOf(result.layout.id);
			// Every key uncoloured: the board only shows where the n-gram's keys are.
			const board = E.keyboard(result.keyboard, result.profile || undefined);
			const flat = Object.fromEntries(board.codes.map((code) => [code, 0]));
			drawBoard($('la-ngrams-board'), result, layout, flat, {
				other: false,
				focusable: false,
				title: (code) => keyText(layout, code)
			});
			$('la-ngrams-caption').textContent = t('layout_analysis.ngrams.caption', {
				layout: result.layout.name
			});
			window.LAYOUT_ANALYSIS_WORST.draw(box, {
				groups: detailOf(result).topGroups,
				layout,
				highlight: window.LAYOUT_ANALYSIS_WORST.highlighter(() => $('la-ngrams-board'))
			});
		}

		/**
		 * One cell of the relative view: a difference to the reference, signed,
		 * with which side the metric prefers as a mark and in words (never by
		 * the mark alone).
		 * @param {{delta: number, verdict: string}} entry - From E.diff().
		 * @param {number} digits - The column's decimals.
		 * @param {string} [unit] - The column's unit, shown beside the difference.
		 * @returns {HTMLTableCellElement}
		 */
		function relativeCell(entry, digits, unit) {
			const marks = { better: '▲', worse: '▼', same: '=', none: '' };
			const cell = el(
				'td',
				'la-delta',
				`${entry.delta > 0 ? '+' : ''}${unit === undefined ? format(entry.delta, digits) : measure(entry.delta, digits, unit)}`
			);
			if (marks[entry.verdict]) {
				const mark = el(
					'span',
					`la-verdict la-verdict-${entry.verdict}`,
					` ${marks[entry.verdict]}`
				);
				mark.setAttribute('aria-hidden', 'true');
				cell.append(
					mark,
					el('span', 'la-sr-only', ` ${t(`layout_analysis.details.verdict_${entry.verdict}`)}`)
				);
			}
			return cell;
		}

		/**
		 * The language the relative view picks its reference by: a corpus's own
		 * (a built-in text, the app's), else the page's (the user's own text).
		 * @param {{builtin?: object, host?: object}} [corpus] - An entry of corpora.
		 * @param {string} pageLocale - The page's language code.
		 * @returns {string} A language code.
		 */
		function referenceLanguage(corpus, pageLocale) {
			const own = corpus && (corpus.builtin || corpus.host);
			return own && typeof own.language === 'string' ? own.language : pageLocale;
		}

		// The reference analysed for the relative view when it is not compared,
		// per analysis (generation) and layout id.
		let referenceAnalysis = null;

		/**
		 * The result the relative view measures against on this corpus
		 * (E.referenceLayout: AZERTY on a French text, QWERTY otherwise): the
		 * compared one, else that layout analysed once on the same text with
		 * the same options and scored with the current weights.
		 * @returns {object|null} An analyse() result; null without a text.
		 */
		function referenceResult() {
			const id = E.referenceLayout(
				referenceLanguage(
					corpora.find((c) => c.id === state.corpus),
					INFO.locale()
				)
			);
			const compared = state.results.find((r) => r.layout.id === id);
			if (compared) return compared;
			if (!state.tables || !byId.has(id)) return null;
			if (
				!referenceAnalysis ||
				referenceAnalysis.generation !== generation ||
				referenceAnalysis.id !== id
			)
				referenceAnalysis = {
					generation,
					id,
					result: E.analyse(byId.get(id), state.tables, analysisOptions())
				};
			const result = referenceAnalysis.result;
			result.score = E.score(result, state.weights);
			return result;
		}

		/** The overview's ranking table, with the viewer's columns and the filters' rows. */
		function renderTable() {
			const reference = state.results.length > 0 ? referenceResult() : null;
			const toggle = $('la-table-relative');
			toggle.checked = state.table.relative;
			toggle.disabled = reference === null;
			const name = reference ? reference.layout.name : '';
			$('la-table-relative-label').textContent = t('layout_analysis.table.relative', {
				layout: name
			});
			const help = $('la-table-relative-help');
			help.hidden = !state.table.relative || reference === null;
			help.textContent = t('layout_analysis.table.relative_help', { layout: name });
			state.sort = rankingTable(
				$('la-table'),
				shownRows(),
				state.table.columns,
				state.sort,
				(sort) => {
					state.sort = sort;
					renderTable();
				},
				state.table.relative ? reference : null
			);
		}

		/**
		 * A bar of one result in a figure from zero: the user's own layouts in the
		 * accent colour, an incomplete one faded with its flag in words. Read as a
		 * table row (barRow); a click opens the layout's details, whose keyboard
		 * way is the table under the figure.
		 */
		function resultBar(result, value, scale, text) {
			const track = el('span', 'la-chart-track');
			const bar = el('span', isPersonal(result) ? 'la-bar la-bar-mine' : 'la-bar la-bar-score');
			bar.style.left = '0';
			bar.style.width = `${scale > 0 ? Math.max(0, Math.min(100, (value / scale) * 100)) : 0}%`;
			track.append(bar);
			const flag = result.incomplete ? incompleteFlag(result) : null;
			const row = barRow(result.layout.name, track, text);
			if (flag) {
				row.classList.add('la-incomplete');
				row.firstChild.append(' ', flag);
			}
			if (state.details === result.layout.id) row.classList.add('la-selected');
			row.classList.add('la-clickable');
			row.title = `${result.layout.name}: ${text}${flag ? ` (${flag.textContent})` : ''}`;
			row.addEventListener('click', () => showDetails(result.layout.id));
			return row;
		}

		/**
		 * The results ordered for a figure of one value: complete layouts first
		 * (incomplete ones rank last everywhere), each group by the value, the
		 * better first (the larger first for a value not scored), then by rank.
		 */
		function figureOrder(rows, value, better) {
			const sign = better === 'lower' ? 1 : -1;
			return rows
				.slice()
				.sort(
					(a, b) =>
						Number(a.incomplete) - Number(b.incomplete) ||
						sign * (value(a) - value(b)) ||
						a.rank - b.rank
				);
		}

		/** One metric's bar chart over the results shown: named, its direction in words. */
		function metricChart(id, rows) {
			const section = el('section', 'la-figure');
			const titleId = `la-chart-${id}`;
			const title = el('h3', '', `${metricName(id)} (${unitText(id)})`);
			title.id = titleId;
			if (DATA.sources.items[id]) title.append(' ', infoButton(id));
			section.setAttribute('aria-labelledby', titleId);
			const better = E.METRICS[id].better;
			section.append(title, el('p', 'la-muted la-direction', DIRECTION_LABEL[better]()));
			const box = el('div', 'la-bars');
			box.setAttribute('role', 'table');
			box.setAttribute('aria-labelledby', titleId);
			const sorted = figureOrder(rows, (r) => r.metrics[id], better);
			const shown = sorted.slice(0, CHART_MAX_BARS);
			const scale = Math.max(...shown.map((r) => r.metrics[id]), 0);
			const digits = metricDigits(id);
			const unit = unitText(id);
			for (const result of shown)
				box.append(
					resultBar(result, result.metrics[id], scale, measure(result.metrics[id], digits, unit))
				);
			section.append(box);
			if (sorted.length > shown.length) section.append(moreNote(shown.length, sorted.length));
			return section;
		}

		/** A themed tab's sortable table: rank, layout, score and the tab's metrics. */
		function metricTable(name, metricIds, rows) {
			const section = el('section', 'la-figure la-figure-wide');
			const titleId = `la-table-${name}-label`;
			const title = el('h3', '', t('layout_analysis.heat.table'));
			title.id = titleId;
			section.setAttribute('aria-labelledby', titleId);
			const wrap = el('div', 'la-table-wrap');
			wrap.tabIndex = 0;
			wrap.setAttribute('role', 'region');
			wrap.setAttribute('aria-labelledby', titleId);
			const table = el('table', 'la-table');
			table.id = `la-table-${name}`;
			wrap.append(table);
			section.append(title, wrap);
			const sortOf = () => state.tabSorts[name] || { key: 'rank', descending: false };
			const draw = (target) =>
				rankingTable(target, rows, metricIds, sortOf(), (sort) => {
					state.tabSorts[name] = sort;
					draw($(`la-table-${name}`));
				});
			draw(table);
			return section;
		}

		/** A themed tab: one chart per metric, then the table of them all. */
		function renderMetricTab(tab) {
			const rows = shownRows();
			const grid = $(`la-charts-${tab}`);
			grid.replaceChildren();
			if (rows.length === 0) return;
			grid.append(
				...TAB_METRICS[tab].map((id) => metricChart(id, rows)),
				metricTable(tab, TAB_METRICS[tab], rows)
			);
		}

		/**
		 * A table header row of sort buttons over a table of its own (a heat
		 * table): the sort is the viewer's, kept in state.tabSorts[name].
		 */
		function tabSortHead(columns, name, redraw) {
			tabSort(name);
			return sortableHead(columns, null, redraw, {
				get: () => state.tabSorts[name],
				set: (sort) => {
					state.tabSorts[name] = sort;
				}
			});
		}

		/** A tab table's sort, by rank until the viewer chooses a column. */
		function tabSort(name) {
			if (!state.tabSorts[name]) state.tabSorts[name] = { key: 'rank', descending: false };
			return state.tabSorts[name];
		}

		/** Sorts rows by the column a tab table's sort names. */
		function sortedBy(rows, columns, sort) {
			const column = columns.find((c) => c.key === sort.key) || columns[0];
			return rows.slice().sort((a, b) => {
				const x = column.value(a);
				const y = column.value(b);
				const order = typeof x === 'string' ? x.localeCompare(y) : x - y;
				return sort.descending ? -order : order;
			});
		}

		/** A row of a heat table: the layout as its header, opening its details. */
		function heatTableRow(result) {
			const tr = el('tr');
			if (state.details === result.layout.id) tr.className = 'la-selected';
			const th = el('th', '', result.layout.name);
			th.scope = 'row';
			if (result.incomplete) th.append(' ', incompleteFlag(result));
			tr.append(th);
			tr.tabIndex = 0;
			tr.addEventListener('click', () => showDetails(result.layout.id));
			tr.addEventListener('keydown', (event) => {
				if (event.key !== 'Enter') return;
				event.preventDefault();
				showDetails(result.layout.id);
			});
			return tr;
		}

		/**
		 * Finger load against the ideal, every layout shown: each finger's share
		 * of the non-thumb presses, its gap to the ideal written under it (signed),
		 * the cell orange above the ideal and blue below, stronger with the gap,
		 * mixed into the neutral surface. The ideal load is the first row.
		 */
		function renderFingerTable() {
			const table = $('la-finger-table');
			const rows = shownRows();
			table.replaceChildren();
			if (rows.length === 0) return;
			const ideal = rows[0].idealLoad;
			const fingers = Object.keys(ideal);
			const columns = [
				{ key: 'name', label: t('layout_analysis.table.layout'), value: (r) => r.layout.name }
			]
				.concat(
					fingers.map((id) => ({
						key: id,
						label: t(`layout_analysis.finger.${id}`),
						numeric: true,
						value: (r) => r.fingerShares[id]
					}))
				)
				.concat([
					{
						key: 'finger_imbalance',
						label: metricName('finger_imbalance'),
						numeric: true,
						value: (r) => r.metrics.finger_imbalance
					},
					{
						key: 'rank',
						label: t('layout_analysis.table.rank'),
						numeric: true,
						value: (r) => r.rank
					}
				]);
			const thead = tabSortHead(columns, 'fingers_load', renderFingerTable);
			const extent = Math.max(
				...rows.flatMap((r) => fingers.map((id) => Math.abs(r.fingerShares[id] - ideal[id]))),
				1e-9
			);
			const tbody = el('tbody');
			const idealRow = el('tr', 'la-ideal-row');
			const idealHead = el('th', '', t('layout_analysis.details.ideal_mark'));
			idealHead.scope = 'row';
			idealRow.append(idealHead, ...fingers.map((id) => el('td', '', measure(ideal[id], 1, '%'))));
			idealRow.append(el('td'), el('td'));
			tbody.append(idealRow);
			for (const result of sortedBy(rows, columns, tabSort('fingers_load'))) {
				const tr = heatTableRow(result);
				for (const id of fingers) {
					const value = result.fingerShares[id];
					// A gap that rounds to zero is written without a sign (never « -0.0 »).
					const gap = Math.abs(value - ideal[id]) < 0.05 ? 0 : value - ideal[id];
					const td = el(
						'td',
						`la-cell ${gap > 0 ? 'la-cell-over' : gap < 0 ? 'la-cell-under' : ''}`
					);
					td.style.setProperty(
						'--la-share',
						`${Math.round((Math.abs(gap) / extent) * HEAT_DIFF_MAX_SHARE * 100)}%`
					);
					const signed = `${gap > 0 ? '+' : ''}${format(gap, 1)}`;
					td.append(el('span', '', measure(value, 1, '%')), el('small', 'la-gap', signed));
					td.title = `${t(`layout_analysis.finger.${id}`)}: ${measure(value, 1, '%')} (${t(
						'layout_analysis.details.ideal_mark'
					)} ${measure(ideal[id], 1, '%')}, ${signed})`;
					tr.append(td);
				}
				tr.append(
					el(
						'td',
						'',
						measure(
							result.metrics.finger_imbalance,
							metricDigits('finger_imbalance'),
							unitText('finger_imbalance')
						)
					),
					el('td', RANK_CELL, format(result.rank, 0))
				);
				tbody.append(tr);
			}
			table.append(thead, tbody);
		}

		/**
		 * Hand balance, the most balanced first: each layout's left and right
		 * shares of the non-thumb presses in one bar (two categorical slots, a
		 * surface gap between them), the middle marked, both values written.
		 */
		function renderHands() {
			const box = $('la-hands');
			box.replaceChildren();
			box.setAttribute('role', 'table');
			const left = t('layout_analysis.details.hand_left');
			const right = t('layout_analysis.details.hand_right');
			$('la-hands-legend').replaceChildren(
				legendItem('la-swatch-cat-1', left),
				legendItem('la-swatch-cat-2', right)
			);
			const sorted = figureOrder(shownRows(), (r) => r.metrics.hand_imbalance, 'lower');
			const shown = sorted.slice(0, CHART_MAX_BARS);
			for (const result of shown) {
				const track = el('span', 'la-chart-track la-stack');
				const share = result.hands.left;
				const leftBar = el('span', 'la-bar la-seg la-seg-1');
				leftBar.style.left = '0';
				leftBar.style.width = `${share}%`;
				const rightBar = el('span', 'la-bar la-seg la-seg-2');
				rightBar.style.left = `${share}%`;
				rightBar.style.width = `${result.hands.right}%`;
				const middle = el('span', 'la-target');
				middle.style.left = '50%';
				track.append(leftBar, rightBar, middle);
				const text = `${measure(result.hands.left, 1, '%')} · ${measure(result.hands.right, 1, '%')}`;
				const row = barRow(
					result.layout.name,
					track,
					text,
					` (${left} ${measure(result.hands.left, 1, '%')}, ${right} ${measure(result.hands.right, 1, '%')})`
				);
				if (result.incomplete) {
					row.classList.add('la-incomplete');
					row.firstChild.append(' ', incompleteFlag(result));
				}
				if (state.details === result.layout.id) row.classList.add('la-selected');
				row.classList.add('la-clickable');
				row.title = `${result.layout.name}: ${left} ${measure(result.hands.left, 1, '%')}, ${right} ${measure(result.hands.right, 1, '%')}`;
				row.addEventListener('click', () => showDetails(result.layout.id));
				box.append(row);
			}
			if (sorted.length > shown.length) box.append(moreNote(shown.length, sorted.length));
		}

		/** A legend entry: a swatch of a class and its name. */
		function legendItem(swatch, label) {
			const item = el('li');
			item.append(el('span', `la-swatch ${swatch}`), el('span', '', label));
			return item;
		}

		/**
		 * A stacked figure: each layout shown (ranking order) in one bar split
		 * into its parts (categorical slots in a fixed order, a surface gap
		 * between them), with a legend, and its values as a folded table.
		 * @param {HTMLElement} box
		 * @param {Array<{id: string, label: string}>} parts
		 * @param {function(object, string): number} value A result's share of a part (%).
		 * @param {string} name Its tables' name (the sort's).
		 * @param {string|null} written The part whose value is written beside
		 *   each bar (the home row), or null when no part speaks for the bar.
		 */
		function stackedFigure(box, parts, value, name, written) {
			box.replaceChildren();
			const rows = shownRows();
			if (rows.length === 0) return;
			const legend = el('ul', 'la-legend');
			parts.forEach((part, i) => legend.append(legendItem(`la-swatch-cat-${i + 1}`, part.label)));
			const bars = el('div', 'la-bars');
			bars.setAttribute('role', 'table');
			bars.setAttribute('aria-labelledby', box.closest('section').getAttribute('aria-labelledby'));
			const shown = rows.slice(0, CHART_MAX_BARS);
			for (const result of shown) {
				const track = el('span', 'la-chart-track la-stack');
				let at = 0;
				parts.forEach((part, i) => {
					const share = value(result, part.id);
					const segment = el('span', `la-bar la-seg la-seg-${i + 1}`);
					segment.style.left = `${at}%`;
					segment.style.width = `${Math.max(0, share)}%`;
					at += Math.max(0, share);
					track.append(segment);
				});
				const said = parts
					.map((part) => `${part.label} ${measure(value(result, part.id), 1, '%')}`)
					.join(', ');
				// One part's value beside the bar at most; all of them are in the title and the table.
				const row = barRow(
					result.layout.name,
					track,
					written ? measure(value(result, written), 1, '%') : '',
					` (${said})`
				);
				if (result.incomplete) {
					row.classList.add('la-incomplete');
					row.firstChild.append(' ', incompleteFlag(result));
				}
				if (state.details === result.layout.id) row.classList.add('la-selected');
				row.classList.add('la-clickable');
				row.title = `${result.layout.name}: ${said}`;
				row.addEventListener('click', () => showDetails(result.layout.id));
				bars.append(row);
			}
			const tableBox = el('details', 'la-section');
			tableBox.append(el('summary', '', t('layout_analysis.heat.table')));
			const wrap = el('div', 'la-table-wrap');
			wrap.tabIndex = 0;
			const table = el('table', 'la-table');
			table.id = `la-table-${name}`;
			wrap.append(table);
			tableBox.append(wrap);
			const columns = [
				{ key: 'name', label: t('layout_analysis.table.layout'), value: (r) => r.layout.name }
			]
				.concat(
					parts.map((part) => ({
						key: part.id,
						label: part.label,
						numeric: true,
						value: (r) => value(r, part.id)
					}))
				)
				.concat([
					{
						key: 'rank',
						label: t('layout_analysis.table.rank'),
						numeric: true,
						value: (r) => r.rank
					}
				]);
			const drawTable = () => {
				const target = $(`la-table-${name}`) || table;
				const tbody = el('tbody');
				for (const result of sortedBy(rows, columns, tabSort(name))) {
					const tr = heatTableRow(result);
					for (const part of parts)
						tr.append(el('td', '', measure(value(result, part.id), 1, '%')));
					tr.append(el('td', RANK_CELL, format(result.rank, 0)));
					tbody.append(tr);
				}
				target.replaceChildren(tabSortHead(columns, name, drawTable), tbody);
			};
			box.append(legend, bars);
			if (rows.length > shown.length) box.append(moreNote(shown.length, rows.length));
			box.append(tableBox);
			drawTable();
		}

		/** How the trigrams split into their six classes, layout by layout. */
		function renderTrigramMix() {
			stackedFigure(
				$('la-trigram-mix'),
				TRIGRAM_MIX.map((id) => ({ id, label: trigramClassName(id) })),
				(result, id) => result.trigramClasses[id],
				'trigram_mix',
				null
			);
		}

		/** Each layout's presses on the number, top, home and bottom rows. */
		function renderRowMix() {
			stackedFigure(
				$('la-row-mix'),
				ROW_MIX.map((id) => ({ id, label: metricName(id) })),
				(result, id) => result.metrics[id],
				'row_mix',
				'home_row'
			);
		}

		/**
		 * Each finger's travel (mm per typed character), every layout shown, on
		 * one blue ramp from zero to the longest; the total is the distance.
		 */
		function renderTravelTable() {
			const table = $('la-travel-table');
			const rows = shownRows();
			table.replaceChildren();
			$('la-travel-legend').replaceChildren();
			if (rows.length === 0) return;
			const fingers = Object.keys(rows[0].fingerDistance);
			const mm = t('layout_analysis.unit.mm');
			const columns = [
				{ key: 'name', label: t('layout_analysis.table.layout'), value: (r) => r.layout.name }
			]
				.concat(
					fingers.map((id) => ({
						key: id,
						label: t(`layout_analysis.finger.${id}`),
						numeric: true,
						value: (r) => r.fingerDistance[id]
					}))
				)
				.concat([
					{
						key: 'distance',
						label: metricName('distance'),
						numeric: true,
						value: (r) => r.metrics.distance
					},
					{
						key: 'rank',
						label: t('layout_analysis.table.rank'),
						numeric: true,
						value: (r) => r.rank
					}
				]);
			const extent = Math.max(...rows.flatMap((r) => fingers.map((id) => r.fingerDistance[id])), 0);
			const tbody = el('tbody');
			for (const result of sortedBy(rows, columns, tabSort('travel'))) {
				const tr = heatTableRow(result);
				for (const id of fingers) {
					const value = result.fingerDistance[id];
					const share = extent > 0 ? value / extent : 0;
					const td = el('td', 'la-cell la-cell-count', measure(value, 2, mm));
					td.style.setProperty('--la-share', `${Math.round(share * 100)}%`);
					td.title = `${t(`layout_analysis.finger.${id}`)}: ${measure(value, 2, mm)}`;
					tr.append(td);
				}
				tr.append(
					el('td', '', measure(result.metrics.distance, metricDigits('distance'), mm)),
					el('td', RANK_CELL, format(result.rank, 0))
				);
				tbody.append(tr);
			}
			table.append(tabSortHead(columns, 'travel', renderTravelTable), tbody);
			$('la-travel-legend').replaceChildren(
				el('span', '', measure(0, 2, mm)),
				el('span', 'la-heat-ramp'),
				el('span', '', measure(extent, 2, mm))
			);
		}

		/**
		 * The side-by-side heat maps: the first boards of the results shown (the
		 * ranking's order), each layout on its own board coloured by the chosen
		 * per-key value, on one scale for all or each on its own; each board has
		 * its values as a folded table and opens the layout's details.
		 */
		function renderHeatGrid() {
			const grid = $('la-heats');
			grid.replaceChildren();
			$('la-heats-legend').replaceChildren();
			const { metric, count, shared } = state.heats;
			const boards = shownRows()
				.slice(0, count)
				.map((result) => ({ result, values: heatValuesOf(result, metric, null) }));
			if (boards.length === 0) return;
			const unit = heatUnit(metric);
			const modifiers = new Set(Object.values(DATA.model.modifier_keys));
			// The space bar takes a share of the presses no other key comes near: the
			// scale is the other keys', and the space bar is drawn at its darkest.
			const extentOf = (values) =>
				Math.max(
					...Object.entries(values)
						.filter(([code]) => !modifiers.has(code) && code !== SPACE_CODE)
						.map(([, v]) => Math.abs(v)),
					0
				);
			const common = Math.max(...boards.map((b) => extentOf(b.values)), 0);
			const ramp = (extent) => [
				el('span', '', measure(0, HEAT_DIGITS, unit)),
				el('span', 'la-heat-ramp'),
				el('span', '', `≥ ${measure(extent, HEAT_DIGITS, unit)}`)
			];
			if (shared)
				$('la-heats-legend').replaceChildren(
					...ramp(common),
					el('span', 'la-muted', t('layout_analysis.heat.scale', { metric: heatName(metric) }))
				);
			for (const { result, values } of boards) {
				const layout = layoutOf(result.layout.id);
				const card = el(
					'section',
					isPersonal(result) ? 'la-figure la-heat-card la-heat-mine' : 'la-figure la-heat-card'
				);
				const titleId = `la-heats-${grid.children.length}`;
				const title = el('h3');
				title.id = titleId;
				const open = el(
					'button',
					'la-link-button',
					t('layout_analysis.details.title', { layout: result.layout.name, rank: result.rank })
				);
				open.type = 'button';
				open.addEventListener('click', () => showDetails(result.layout.id));
				title.append(open);
				if (result.incomplete) title.append(' ', incompleteFlag(result));
				card.setAttribute('aria-labelledby', titleId);
				const box = el('div', 'la-heatmap la-heatmap-small');
				const extent = shared ? common : extentOf(values);
				const tableRows = drawBoard(box, result, layout, values, {
					extent,
					other: false,
					focusable: false,
					title: (code, value) =>
						`${keyText(layout, code)} · ${heatName(metric)}: ${measure(value, HEAT_DIGITS, unit)}`
				});
				card.append(title, box);
				// Each card's heatmap as a PNG or SVG image (board_image.js).
				card.append(
					window.LAYOUT_BOARD_IMAGE.buttons({
						id: `la-heat-image-${titleId}`,
						board: () => box,
						options: () => ({
							title: `${result.layout.name} · ${heatName(metric)}`,
							words: [result.layout.name, 'heatmap', metric]
						})
					})
				);
				if (!shared) {
					const legend = el('div', 'la-heat-legend');
					legend.append(...ramp(extent));
					card.append(legend);
				}
				const tableBox = el('details', 'la-section');
				tableBox.append(el('summary', '', t('layout_analysis.heat.table')));
				const wrap = el('div', 'la-table-wrap');
				wrap.tabIndex = 0;
				const table = el('table', 'la-table');
				heatTableInto(table, layout, tableRows, metric, false);
				wrap.append(table);
				tableBox.append(wrap);
				card.append(tableBox);
				grid.append(card);
			}
		}

		/** The layout list of « One layout »: every compared layout, in the ranking's order. */
		function fillDetailsPick() {
			// Before the first results (a link's layout waits for them) nothing is replaced.
			if (state.results.length > 0 && !state.results.some((r) => r.layout.id === state.details))
				state.details = state.results[0].layout.id;
			fillSelect(
				$('la-details-layout'),
				state.results.length > 0
					? state.results.map((r) => [r.layout.id, `${format(r.rank, 0)}. ${r.layout.name}`])
					: [['', t('layout_analysis.status.empty')]],
				state.details || ''
			);
		}

		/** Opens a layout's details in « One layout ». */
		function showDetails(id) {
			state.details = id;
			if (state.versus === id) state.versus = null;
			state.tab = DETAILS_TAB;
			showTab();
			render();
			$('la-tabs').scrollIntoView({ block: 'nearest' });
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
				const text = withUnit(`${value > 0 ? '+' : ''}${format(value, digits)}`, unit);
				const row = barRow(label, track, text);
				row.title = `${label}: ${text}`;
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
			const value = (v) => measure(v, digits, unit);
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
			return INFO.metricUnit(id);
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
			return heatValuesOf(detail, state.heat, other);
		}

		/** Each key's value of a heatmap choice for one result (heatValues), any choice. */
		function heatValuesOf(result, metric, other) {
			if (metric === HEAT_SCORE) {
				const own = E.keyScoreCost(result, state.weights);
				if (!other) return own;
				const theirs = E.keyScoreCost(other, state.weights);
				return Object.fromEntries(Object.keys(own).map((code) => [code, own[code] - theirs[code]]));
			}
			return other ? E.keyDiff(result, other, metric) : E.keyValues(result, metric);
		}

		/**
		 * A key's tooltip line: its value in the chosen unit, then its worst
		 * groups for a bad event, or the metrics it costs the most points on.
		 */
		function heatTitle(detail, layout, code, value, signed) {
			const unit = heatUnit(state.heat);
			const written = `${signed && value > 0 ? '+' : ''}${measure(value, HEAT_DIGITS, unit)}`;
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
								.join(' ')} ${measure(share, HEAT_DIGITS, '%')}`
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
			heatTableInto($('la-heat-table'), layout, rows, state.heat, signed);
		}

		/** The heatmap's numbers of one choice as a table (renderHeatTable), into any table. */
		function heatTableInto(table, layout, rows, metric, signed) {
			const unit = heatUnit(metric);
			const head = el('tr');
			for (const label of [
				t('layout_analysis.heat.table_key'),
				t('layout_analysis.heat.table_position'),
				t('layout_analysis.heat.table_finger'),
				heatName(metric)
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
				const written = `${signed && row.value > 0 ? '+' : ''}${measure(row.value, HEAT_DIGITS, unit)}`;
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
		 * Draws a board of a result's keyboard into a box, each key showing the
		 * layout's base character, positioned in % so the board scales with its
		 * box. One layout: the heat scale (theme.css), blue for the least to red
		 * for the most, by the key's share of the extent. A difference (other): orange where this layout puts more,
		 * blue where less, mixed into the neutral surface.
		 * @param {HTMLElement} box
		 * @param {object} result
		 * @param {object} layout
		 * @param {object} byCode code → value.
		 * @param {{extent?: number, other: boolean, focusable: boolean,
		 *   title: function(string, number): string}} options extent: the value
		 *   of the darkest key (the box's own largest when absent); focusable:
		 *   every key takes the focus with its value as its name.
		 * @returns {Array<{code: string, where: string, finger: string, value: number}>}
		 *   The drawn keys, the rows of the board's table.
		 */
		function drawBoard(box, result, layout, byCode, options) {
			box.replaceChildren();
			const board = E.keyboard(result.keyboard, result.profile || undefined);
			const modifiers = new Set(Object.values(DATA.model.modifier_keys));
			const shown = board.codes.filter((code) => !modifiers.has(code));
			const extent =
				options.extent !== undefined
					? options.extent
					: Math.max(...shown.map((code) => Math.abs(byCode[code])), 0);
			const minX = Math.min(...board.x) - 0.5;
			const maxX = Math.max(...board.x) + 0.5;
			const maxY = Math.max(...board.y);
			const width = maxX - minX;
			// Positions in % of the board, so the whole board scales with its box.
			const across = (units) => `${(units / width) * 100}%`;
			const down = (units) => `${(units / maxY) * 100}%`;
			box.style.maxWidth = `${width * HEAT_UNIT_PX}px`;
			box.style.aspectRatio = `${width} / ${maxY}`;
			box.classList.toggle('la-heatmap-diff', options.other);
			const position = keyPositions(board, shown);
			const tableRows = [];
			board.codes.forEach((code, k) => {
				if (modifiers.has(code)) return;
				const key = el('span', 'la-key', keyText(layout, code));
				// The worst n-grams outline keys by their code (worst_groups.js).
				key.dataset.code = code;
				const row = layout.rows[code];
				if (row && row[0] && typeof row[0] === 'object')
					key.classList.add(KEY_LEGEND.DEAD_KEY_CLASS);
				const value = byCode[code];
				const share = extent > 0 ? Math.min(1, Math.abs(value) / extent) : 0;
				// The space bar as wide as the board makes it, at most SPACE_UNITS: a split
				// board's one-unit thumb key, JIS's shorter bar beside its thumb keys.
				const span = code === 'Space' ? Math.min(SPACE_UNITS, board.width[k]) : 1;
				const left = board.x[k] - span / 2;
				key.style.left = across(left - minX);
				key.style.top = down(board.y[k] - 1);
				key.style.width = across(span);
				key.style.height = down(1);
				if (options.other) {
					key.classList.add(value > 0 ? 'la-key-more' : value < 0 ? 'la-key-less' : 'la-key-same');
					key.style.setProperty('--la-share', `${Math.round(share * HEAT_DIFF_MAX_SHARE * 100)}%`);
				} else {
					key.style.setProperty('--la-share', `${Math.round(share * 100)}%`);
				}
				const title = options.title(code, value);
				const where = t('layout_analysis.heat.position', position.get(code));
				key.title = title;
				key.setAttribute('role', 'img');
				// The name also says where the key is, which the drawing shows.
				key.setAttribute('aria-label', `${title} (${where})`);
				if (options.focusable) key.tabIndex = 0;
				box.append(key);
				tableRows.push({ code, where, finger: DATA.model.fingers[board.finger[k]], value });
			});
			return tableRows;
		}

		/**
		 * The board of the chosen keyboard in the details, each key showing the
		 * layout's base character. One layout: coloured on the heat scale (blue to red) by
		 * its share of the largest value of the chosen per-key metric. Against
		 * another layout (the difference): orange where this layout puts more,
		 * blue where less, stronger with the size of the gap, each tooltip
		 * signed. The legend gives the scale; every key is reachable from the
		 * keyboard with its value as its name. The board shrinks with the page
		 * instead of scrolling.
		 */
		function renderHeatmap(result) {
			const box = $('la-heatmap');
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
			const layout = layoutOf(result.layout.id);
			const byCode = heatValues(detail, other);
			const tableRows = drawBoard(box, result, layout, byCode, {
				other: Boolean(other),
				focusable: true,
				title: (code, value) => heatTitle(detail, layout, code, value, Boolean(other))
			});
			// The heatmap as a PNG or SVG image (board_image.js).
			$('la-heatmap-image').replaceChildren(
				window.LAYOUT_BOARD_IMAGE.buttons({
					id: 'la-heatmap-image',
					board: () => $('la-heatmap'),
					options: () => ({
						title: `${result.layout.name} · ${heatName(state.heat)}`,
						words: [result.layout.name, 'heatmap', state.heat]
					})
				})
			);
			const extent = Math.max(...tableRows.map((row) => Math.abs(row.value)), 0);
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
					el('span', 'la-muted', `± ${measure(extent, HEAT_DIGITS, unit)}`)
				);
				return;
			}
			// The scale: what the lightest and the darkest key stand for.
			legend.replaceChildren(
				el('span', '', measure(0, HEAT_DIGITS, unit)),
				el('span', 'la-heat-ramp'),
				el('span', '', measure(extent, HEAT_DIGITS, unit)),
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
			// The side-by-side heat maps offer the same choices, and how many boards.
			fillSelect(
				$('la-heats-metric'),
				HEAT_CHOICES.map((id) => [id, heatName(id)]),
				state.heats.metric
			);
			fillSelect(
				$('la-heats-count'),
				HEATS_COUNTS.map((n) => [String(n), format(n, 0)]),
				String(state.heats.count)
			);
			$('la-heats-shared').checked = state.heats.shared;
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
			const layout = layoutOf(result.layout.id);
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
					el('td', '', measure(group.count, 0, t('layout_analysis.unit.times'))),
					el('td', '', measure(group.share, HEAT_DIGITS, '%'))
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

		/**
		 * A table header row of sort buttons; the sort is the viewer's
		 * (state[sortName], or the holder's get and set). After a redraw the focus
		 * returns to the same header, found by its data-sort in the document.
		 */
		function sortableHead(columns, sortName, redraw, holder) {
			const get = holder ? holder.get : () => state[sortName];
			const set = holder
				? holder.set
				: (sort) => {
						state[sortName] = sort;
					};
			const head = el('tr');
			const scope = `${sortName || 'tab'}-${columns.map((c) => c.key).join('.')}`;
			for (const column of columns) {
				const th = el('th', 'la-sortable');
				th.scope = 'col';
				const sort = el('button', 'la-sort', column.label);
				sort.type = 'button';
				sort.dataset.sortScope = scope;
				sort.dataset.sort = column.key;
				sort.addEventListener('click', () => {
					const current = get();
					set(
						current.key === column.key
							? { key: column.key, descending: !current.descending }
							: { key: column.key, descending: Boolean(column.numeric) }
					);
					redraw();
					const again = root.querySelector(
						`button[data-sort-scope="${scope}"][data-sort="${column.key}"]`
					);
					if (again) again.focus();
				});
				th.append(sort);
				if (get().key === column.key)
					th.setAttribute('aria-sort', get().descending ? 'descending' : 'ascending');
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			return thead;
		}
		/**
		 * The key pair matrix (the engine's bigramMatrix): the busiest keys on
		 * both axes, first key by row, second by column, each cell coloured by
		 * how often the pair occurs (the heat scale, blue to red) or by the score
		 * points it gains (blue, « + ») or costs (orange, « − ») into the
		 * neutral surface. The figure scrolls inside its own box on a narrow
		 * screen; every pair is also in a sortable table, and each cell names
		 * its pair, share, count, kind and points to assistive technology.
		 */
		function renderMatrix(result) {
			const layout = layoutOf(result.layout.id);
			const matrix = cachedFigure(result, 'matrix', () =>
				E.bigramMatrix(layout, tablesOf(result), analysisOptions())
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
					el('span', 'la-muted', `± ${measure(extent, HEAT_DIGITS, unit)}`)
				);
			} else {
				legend.replaceChildren(
					el('span', '', measure(0, HEAT_DIGITS, unit)),
					el('span', 'la-heat-ramp'),
					el('span', '', measure(extent, HEAT_DIGITS, unit)),
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
					label: t('layout_analysis.worst.share'),
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
					label: t('layout_analysis.matrix.points'),
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
					el('td', '', measure(pair.count, 0, t('layout_analysis.unit.times'))),
					el('td', '', measure(pair.share, HEAT_DIGITS, '%')),
					el('td', '', eventsText(pair)),
					el('td', '', withUnit(signed(pair.points, HEAT_DIGITS), t('layout_analysis.unit.points')))
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
			const layout = layoutOf(result.layout.id);
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
					el('td', '', measure(entry.count, 0, t('layout_analysis.unit.times'))),
					el('td', '', measure(entry.effort, 1, points)),
					el(
						'td',
						'',
						worst && worst[1] > 0
							? `${t(`layout_analysis.metric.${worst[0]}`)} ${measure(worst[1], 1, points)}`
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
				['modifier_usage', 'altgr_usage', 'dead_key_usage'].map((id) => ({
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
				const points = t('layout_analysis.unit.points');
				addRow(th, [measure(diff.score.a, 1, points), measure(diff.score.b, 1, points)], {
					text: withUnit(signed(diff.score.delta, 1), points),
					verdict: diff.score.verdict
				});
			}
			for (const id of Object.keys(E.METRICS)) {
				const th = el('th', '', t(`layout_analysis.metric.${id}`));
				th.scope = 'row';
				th.append(' ', infoButton(id));
				const digits = metricDigits(id);
				const unit = unitText(id);
				const values = [measure(result.metrics[id], digits, unit)];
				let delta = null;
				if (diff) {
					const entry = diff.metrics[id];
					values.push(measure(entry.b, digits, unit));
					delta = { text: withUnit(signed(entry.delta, digits), unit), verdict: entry.verdict };
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
								`${t(`layout_analysis.typing.${way.kind}`)} ${way.keys} (${measure(way.share, 0, '%')})`
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
					? measure(rule.value, 0, '%')
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
			const layout = layoutOf(result.layout.id);
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
		 * @returns {{url: string, own: object[], personal: boolean}} own: the
		 *   compared layouts that are the visitor's own, which share() puts in the
		 *   link's fragment; personal: the text is the visitor's own, not in it.
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
				own: chosen.filter((l) => !SHAREABLE_ORIGINS.includes(l.origin)),
				personal: !(corpus && corpus.builtin)
			};
		}

		/** Copies the comparison's link, or shows it when the clipboard refuses. */
		async function share() {
			const { url, own, personal } = shareLink();
			const status = $('la-share-status');
			status.hidden = false;
			// The visitor's own layouts travel in the fragment (layout_formats.js toLink).
			let link = url;
			try {
				if (own.length > 0) link = `${url}#${await window.LAYOUT_FORMATS.toLink(own)}`;
			} catch (error) {
				const refusal = window.LAYOUT_FORMATS.refusalMessage(error);
				status.textContent = t(refusal.key, refusal.values);
				return;
			}
			try {
				await navigator.clipboard.writeText(link);
				status.textContent =
					link.length > window.LAYOUT_FORMATS.LINK_LONG
						? t('layout_analysis.share.copied_long', { size: format(link.length / 1024, 0) })
						: personal
							? t('layout_analysis.share.copied_partial')
							: t('layout_analysis.share.copied');
			} catch {
				status.textContent = t('layout_analysis.share.failed', { url: link });
			}
		}

		// ===========================
		// ======= 6/ Controls =======
		// ===========================

		function fillCorpora() {
			// The user's own texts first (maintainer, 2026-11-17): « My typing »,
			// listed at once while the app reads it, then the pasted text.
			const mine = [];
			if (!corpora.some((c) => c.id === MY_TYPING_ID) && myTypingState)
				mine.push({
					id: MY_TYPING_ID,
					label: t(
						myTypingState.state === 'loading'
							? 'layout_analysis.corpus.my_typing_loading'
							: 'layout_analysis.corpus.my_typing_unavailable'
					),
					disabled: true,
					title: myTypingState.reason
				});
			for (const corpus of corpora.filter((c) => !c.builtin))
				mine.push({
					id: corpus.id,
					label:
						corpus.id === CUSTOM_ID
							? t('layout_analysis.corpus.custom')
							: corpus.id === MY_TYPING_ID && !corpus.title
								? t('layout_analysis.corpus.my_typing')
								: corpus.title
				});
			window.LAYOUT_ANALYSIS_FILES.fillCorpusPicker($('la-corpus'), {
				mine,
				builtins: corpora.filter((c) => c.builtin).map((c) => c.builtin),
				value: state.corpus,
				t,
				locale: INFO.locale()
			});
			$('la-corpus').classList.toggle('la-corpus-mine', state.corpus === MY_TYPING_ID);
			showCorpusInfo();
		}

		/**
		 * The text the layouts type: the chosen mode on « My typing », the one
		 * corpus that can bring the keys typed and the final text apart; the
		 * keys typed on every other corpus, whose single text both are, so the
		 * saved mode is kept but not applied there.
		 * @returns {string} A TEXT_MODES value.
		 */
		function appliedTextMode() {
			return state.corpus === MY_TYPING_ID ? state.textMode : TEXT_TYPED;
		}

		/**
		 * The text mode control, under the corpus picker and shown on « My
		 * typing » only (maintainer, 2026-11-18): elsewhere the choice means
		 * nothing (appliedTextMode). Its value, and why it is greyed on a read
		 * of one text, or what the chosen mode does.
		 */
		function showTextMode() {
			$('la-text-mode-field').hidden = state.corpus !== MY_TYPING_ID;
			const select = $('la-text-mode');
			const two = hasTwoTexts();
			select.value = state.textMode;
			select.disabled = !two;
			$('la-text-mode-info').textContent = two
				? t(`layout_analysis.text_mode.info_${state.textMode}`)
				: t('layout_analysis.text_mode.one_text');
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

		/** Text as the layout search compares it: lower case, without accents. */
		function folded(text) {
			return String(text).normalize('NFD').replace(/\p{M}/gu, '').toLowerCase();
		}

		/** The words the layout search reads: the name, id, family and authors. */
		function searchText(layout) {
			const authors = Array.isArray(layout.authors)
				? layout.authors.join(' ')
				: layout.authors || '';
			return folded([layout.name, layout.id, layout.family || '', authors].join(' '));
		}

		/**
		 * The letter heading a layout is listed under: the first letter of its
		 * name without its accent (« É » under « E »), « # » for a digit or a sign.
		 */
		function letterOf(layout) {
			const first = folded(layout.name).charAt(0).toUpperCase();
			return /\p{L}/u.test(first) ? first : LETTER_OTHER;
		}

		/** Whether the layout list's filters (text, origin, language) show a layout. */
		function pickShows(layout) {
			const filter = folded($('la-filter').value.trim());
			return (
				(!filter || filter.split(/\s+/).every((word) => searchText(layout).includes(word))) &&
				(!state.pick.origin || originOf(layout) === state.pick.origin) &&
				(!state.pick.language || layout.language === state.pick.language)
			);
		}

		/**
		 * The layout list (maintainer, 2026-11-18): one column in alphabetical
		 * order under a heading per first letter, a letter index that jumps to
		 * each heading, the ticked layouts marked, and a count the search and
		 * the ticks announce.
		 */
		function fillLayouts() {
			const list = $('la-layout-list');
			const letters = $('la-letters');
			const shown = layouts
				.filter(pickShows)
				.sort((a, b) => folded(a.name).localeCompare(folded(b.name)) || a.id.localeCompare(b.id));
			const groups = new Map();
			for (const layout of shown) {
				const letter = letterOf(layout);
				if (!groups.has(letter)) groups.set(letter, []);
				groups.get(letter).push(layout);
			}
			const sections = [];
			const jumps = [];
			for (const [letter, members] of groups) {
				const id = `la-letter-${letter === LETTER_OTHER ? 'other' : letter}`;
				const section = el('section', 'la-letter-group');
				section.setAttribute('aria-labelledby', id);
				const heading = el('h3', 'la-letter', letter);
				heading.id = id;
				heading.tabIndex = -1;
				const items = el('ul', 'la-letter-items');
				for (const layout of members) items.append(layoutItem(layout));
				section.append(heading, items);
				sections.push(section);
				const jump = el('a', 'la-letter-jump', letter);
				jump.href = `#${id}`;
				jump.title = t('layout_analysis.layouts.jump', { letter });
				jump.addEventListener('click', (event) => {
					event.preventDefault();
					heading.scrollIntoView({ block: 'start' });
					const first = section.querySelector('input');
					(first || heading).focus({ preventScroll: true });
				});
				jumps.push(jump);
			}
			list.replaceChildren(...sections);
			letters.replaceChildren(...jumps);
			letters.setAttribute('aria-label', t('layout_analysis.layouts.letters'));
			letters.hidden = jumps.length < 2;
			showPickCount(shown.length);
		}

		/** The live line under the search: how many layouts are shown and ticked. */
		function showPickCount(shown) {
			$('la-pick-count').textContent = t('layout_analysis.layouts.count', {
				shown,
				total: layouts.length,
				selected: layouts.filter((layout) => state.selected.has(layout.id)).length
			});
		}

		/** One layout of the list: its box and name, its family, its « + » twin. */
		function layoutItem(layout) {
			const item = el('li', 'la-layout-item');
			const label = el('label', 'la-layout');
			const box = el('input');
			box.type = 'checkbox';
			box.checked = state.selected.has(layout.id);
			item.classList.toggle('la-picked', box.checked);
			box.addEventListener('change', () => {
				if (box.checked) state.selected.add(layout.id);
				else state.selected.delete(layout.id);
				item.classList.toggle('la-picked', box.checked);
				chooseSelection();
				save();
				showPickCount(visibleLayoutIds().length);
				analyse();
			});
			label.append(box, el('span', 'la-layout-name', layout.name));
			const authors = Array.isArray(layout.authors) ? layout.authors.join(', ') : '';
			// The authors beside the label, so the box is named by the layout alone.
			item.append(label);
			if (authors) item.append(el('span', 'la-layout-meta', authors));
			// « + »: this layout also ranks as « <name>+ », typing the keys typed with
			// the Ergopti+ hotstrings, while the others type the final text.
			if (appliedTextMode() !== TEXT_MIXED) return item;
			const plusLabel = el('label', 'la-plus');
			const plus = el('input');
			plus.type = 'checkbox';
			plus.checked = state.plus.has(layout.id);
			plus.disabled = !hasTwoTexts();
			plusLabel.title = hasTwoTexts()
				? t('layout_analysis.text_mode.plus_title', { layout: layout.name + PLUS_SUFFIX })
				: t('layout_analysis.text_mode.one_text');
			plus.addEventListener('change', () => {
				if (plus.checked) state.plus.add(layout.id);
				else state.plus.delete(layout.id);
				save();
				analyse();
			});
			plusLabel.append(plus, el('span', '', layout.name + PLUS_SUFFIX));
			item.append(plusLabel);
			return item;
		}

		// The file name a score settings export is saved under.
		const SCORE_CONFIG_FILE = 'ergopti-score-settings.json';

		/** Shows one line of the score settings status; error marks a refusal. */
		function configStatus(text, error) {
			const status = $('la-config-status');
			status.className = error ? 'la-error' : 'la-muted';
			status.textContent = text;
		}

		/** Fills every score settings control again, then analyses with them. */
		function applyScoreSettings() {
			fillWeights();
			fillIdealLoad();
			fillShortcuts();
			fillForms();
			save();
			// The access weights may have changed: the layouts are typed again.
			analyse();
		}

		/**
		 * The score settings file: export (the host's download path in the app,
		 * a browser download on the site), a strict import that applies a file
		 * whole or not at all, and a reset of every setting with an « Undo ».
		 */
		function wireScoreConfig() {
			const parts = ['weights', 'idealLoad', 'shortcuts', 'formWeights'];
			$('la-config-export').addEventListener('click', async () => {
				const text = `${JSON.stringify(
					E.scoreConfig({
						weights: state.weights,
						idealLoad: state.idealLoad,
						shortcuts: state.shortcuts,
						formWeights: state.formWeights
					}),
					null,
					'\t'
				)}\n`;
				if (typeof HOST.saveFile === 'function') {
					try {
						const where = await HOST.saveFile(SCORE_CONFIG_FILE, text);
						configStatus(t('layout_analysis.config.exported', { path: where }), false);
					} catch (error) {
						configStatus(
							t('layout_analysis.config.save_failed', {
								code: (error && error.code) || String(error)
							}),
							true
						);
					}
					return;
				}
				const url = URL.createObjectURL(new Blob([text], { type: 'application/json' }));
				const link = el('a');
				link.href = url;
				link.download = SCORE_CONFIG_FILE;
				document.body.append(link);
				link.click();
				link.remove();
				setTimeout(() => URL.revokeObjectURL(url), 0);
				configStatus(t('layout_analysis.config.downloaded', { name: SCORE_CONFIG_FILE }), false);
			});
			const input = $('la-config-import');
			input.addEventListener('change', async () => {
				const file = input.files && input.files[0];
				input.value = '';
				if (!file) return;
				let settings;
				try {
					settings = E.readScoreConfig(JSON.parse(await file.text()));
				} catch (error) {
					// Nothing is applied: the reason says what to change in the file.
					configStatus(
						t('layout_analysis.config.refused', { name: file.name, reason: INFO.refusal(error) }),
						true
					);
					return;
				}
				Object.assign(state, settings);
				applyScoreSettings();
				configStatus(t('layout_analysis.config.imported', { name: file.name }), false);
			});
			const reset = $('la-config-reset');
			const undo = UNDO.create(reset.closest('section'));
			$('la-config-status').before(undo.node);
			reset.addEventListener('click', () => {
				const before = JSON.stringify(parts.map((part) => state[part]));
				state.weights = E.defaultWeights();
				state.idealLoad = Object.assign({}, E.defaultIdealLoad());
				state.shortcuts = E.defaultShortcuts();
				state.formWeights = E.defaultFormFactorWeights();
				applyScoreSettings();
				configStatus('', false);
				if (before === JSON.stringify(parts.map((part) => state[part]))) {
					undo.clear();
					return;
				}
				undo.offer({
					name: t('layout_analysis.config.title'),
					focus: reset,
					undo: () => {
						JSON.parse(before).forEach((value, i) => {
							state[parts[i]] = value;
						});
						applyScoreSettings();
					}
				});
			});
		}

		/** A section's decorative icon (SECTION_ICONS): its heading names it. */
		function sectionIcon(id) {
			const svg = document.createElementNS(SVG_NS, 'svg');
			svg.setAttribute('viewBox', '0 0 24 24');
			svg.setAttribute('class', 'la-section-icon');
			svg.setAttribute('aria-hidden', 'true');
			svg.setAttribute('focusable', 'false');
			const path = document.createElementNS(SVG_NS, 'path');
			path.setAttribute('d', SECTION_ICONS[id]);
			svg.append(path);
			return svg;
		}

		/** Puts each static settings section's icon before its heading text, once. */
		function placeSectionIcons() {
			for (const section of document.querySelectorAll('#la-settings [data-section-icon]')) {
				const heading = section.querySelector('.la-heading h2');
				if (heading.querySelector('.la-section-icon')) continue;
				heading.prepend(sectionIcon(section.dataset.sectionIcon));
			}
		}

		/**
		 * The bars of the ideal finger load, one per finger, left hand then right,
		 * each as tall as its share: a picture of the inputs beside it, which stay
		 * the controls (the figure is hidden from assistive technology).
		 * @param {object} values - finger id → share (%), possibly not a number.
		 */
		function drawIdealHands(values) {
			const svg = $('la-ideal-hands');
			svg.replaceChildren();
			const fingers = Object.keys(E.defaultIdealLoad());
			const shares = fingers.map((id) => (Number.isFinite(values[id]) ? values[id] : 0));
			const top = Math.max(20, ...shares);
			const width = 20;
			const base = 100;
			fingers.forEach((id, i) => {
				// A gap between the hands: the four left fingers, then the four right.
				const x = 10 + i * 24 + (i >= fingers.length / 2 ? 12 : 0);
				const height = Math.max(4, (shares[i] / top) * 80);
				const bar = document.createElementNS(SVG_NS, 'rect');
				bar.setAttribute('x', String(x));
				bar.setAttribute('y', String(base - height));
				bar.setAttribute('width', String(width));
				bar.setAttribute('height', String(height));
				bar.setAttribute('rx', '9');
				bar.setAttribute('class', 'la-ideal-finger');
				const value = document.createElementNS(SVG_NS, 'text');
				value.setAttribute('x', String(x + width / 2));
				value.setAttribute('y', String(base - height - 4));
				value.setAttribute('class', 'la-ideal-value');
				value.textContent = format(shares[i], 0);
				bar.dataset.finger = id;
				svg.append(bar, value);
			});
			// Each hand's palm under its four fingers.
			for (const x of [8, 116]) {
				const palm = document.createElementNS(SVG_NS, 'rect');
				palm.setAttribute('x', String(x));
				palm.setAttribute('y', String(base + 2));
				palm.setAttribute('width', '96');
				palm.setAttribute('height', '16');
				palm.setAttribute('rx', '8');
				palm.setAttribute('class', 'la-ideal-palm');
				svg.append(palm);
			}
		}

		/**
		 * One weight's control: its name (the label of its input), its « i », the
		 * input with the points it is worth per unit, and the metric's definition
		 * (the « i » text, one source with the popover) as the input's description.
		 */
		function weightControl(id) {
			const metric = E.METRICS[id];
			const control = el('div', 'la-weight-card');
			const inputId = `la-weight-${id}`;
			const top = el('div', 'la-weight-top');
			const label = el('label', 'la-weight-name', t(`layout_analysis.metric.${id}`));
			label.htmlFor = inputId;
			top.append(label, infoButton(id));
			const field = el('div', 'la-weight-field');
			const input = el('input');
			input.id = inputId;
			input.type = 'number';
			input.min = '0';
			input.step = 'any';
			input.value = String(state.weights[id]);
			input.setAttribute('aria-describedby', `${inputId}-unit ${inputId}-help`);
			const unit = el(
				'span',
				'la-weight-unit',
				t(`layout_analysis.weights.per_${metric.better}`, {
					unit: metric.unit === 'mm' ? t('layout_analysis.unit.mm') : '%'
				})
			);
			unit.id = `${inputId}-unit`;
			field.append(input, unit);
			const help = el('p', 'la-weight-help', t(`layout_analysis.info.${id}`));
			help.id = `${inputId}-help`;
			control.append(top, field, help);
			return { control, input };
		}

		function fillWeights() {
			const list = $('la-weight-list');
			list.replaceChildren();
			const grouped = Object.values(WEIGHT_GROUPS).flat();
			for (const id of Object.keys(E.defaultWeights()))
				if (!grouped.includes(id))
					throw new Error(`layout_analysis: the weight ${id} is in no WEIGHT_GROUPS group`);
			for (const [group, ids] of Object.entries(WEIGHT_GROUPS)) {
				const section = el('section', `la-weight-group la-accent-${SECTION_SLOT[group]}`);
				const headingId = `la-weight-group-${group}`;
				section.setAttribute('aria-labelledby', headingId);
				const heading = el('h3', 'la-group-heading');
				heading.id = headingId;
				heading.append(
					sectionIcon(group),
					el('span', '', t(`layout_analysis.weights.group.${group}`))
				);
				const grid = el('div', 'la-weight-list');
				section.append(
					heading,
					el('p', 'la-muted', t(`layout_analysis.weights.group_help.${group}`)),
					grid
				);
				list.append(section);
				for (const id of ids) {
					const { control, input } = weightControl(id);
					grid.append(control);
					wireWeight(id, input);
				}
			}
			placeSectionIcons();
		}

		/** Re-scores (or, for an access weight, analyses again) as a weight is edited. */
		function wireWeight(id, input) {
			input.addEventListener('input', () => {
				const value = Number(input.value);
				if (input.value === '' || !Number.isFinite(value) || value < 0) {
					input.setAttribute('aria-invalid', 'true');
					return;
				}
				input.removeAttribute('aria-invalid');
				state.weights[id] = value;
				// An access weight chooses the ways of typing: the layouts are typed again.
				if (E.ACCESS_WEIGHTS.includes(id)) {
					save();
					analyse();
				} else rescore();
			});
		}

		function fillIdealLoad() {
			const list = $('la-ideal-list');
			list.replaceChildren();
			const inputs = {};
			const showSum = () => {
				drawIdealHands(
					Object.fromEntries(
						Object.keys(inputs).map((id) => [
							id,
							inputs[id].value === '' ? NaN : Number(inputs[id].value)
						])
					)
				);
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
			drawIdealHands(state.idealLoad);
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
			return layouts.filter(pickShows).map((l) => l.id);
		}

		function bind() {
			$('la-corpus').addEventListener('change', (event) => {
				state.corpus = event.target.value;
				showCorpusInfo();
				showTextMode();
				fillLayouts();
				save();
				analyse();
			});
			$('la-text-mode').addEventListener('change', (event) => {
				state.textMode = event.target.value;
				fillLayouts();
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
			// The filters choose the layouts every sub-tab draws.
			const filtered = () => {
				state.table.name = $('la-row-name').value;
				state.table.family = $('la-row-family').value;
				state.table.origin = $('la-row-origin').value;
				state.table.language = $('la-row-language').value;
				state.table.complete = $('la-row-complete').value;
				state.table.min = bound($('la-row-min'));
				state.table.max = bound($('la-row-max'));
				save();
				render();
			};
			for (const id of ['la-row-name', 'la-row-min', 'la-row-max'])
				$(id).addEventListener('input', filtered);
			for (const id of ['la-row-family', 'la-row-origin', 'la-row-language', 'la-row-complete'])
				$(id).addEventListener('change', filtered);
			$('la-table-relative').addEventListener('change', (event) => {
				state.table.relative = event.target.checked;
				save();
				renderTable();
			});
			$('la-table-reset').addEventListener('click', () => {
				state.table = validTable(null);
				fillTableOptions();
				save();
				render();
			});
			// The layout list's filters, which « Select all shown » follows.
			for (const [id, name] of [
				['la-pick-origin', 'origin'],
				['la-pick-language', 'language']
			])
				$(id).addEventListener('change', (event) => {
					state.pick[name] = event.target.value;
					save();
					fillLayouts();
				});
			$('la-heats-metric').addEventListener('change', (event) => {
				state.heats.metric = event.target.value;
				save();
				renderHeatGrid();
			});
			$('la-heats-count').addEventListener('change', (event) => {
				state.heats.count = Number(event.target.value);
				save();
				renderHeatGrid();
			});
			$('la-heats-shared').addEventListener('change', (event) => {
				state.heats.shared = event.target.checked;
				save();
				renderHeatGrid();
			});
			$('la-details-layout').addEventListener('change', (event) => {
				if (event.target.value) showDetails(event.target.value);
			});
			$('la-versus').addEventListener('change', (event) => {
				state.versus = event.target.value || null;
				renderDetails();
			});
			$('la-share').addEventListener('click', share);
			// Every layout or none, whatever the search shows.
			for (const [id, tick] of [
				['la-every', true],
				['la-clear', false]
			])
				$(id).addEventListener('click', () => {
					state.selected = tick ? new Set(layouts.map((l) => l.id)) : new Set();
					chooseSelection();
					save();
					fillLayouts();
					analyse();
				});
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
			wireScoreConfig();
			restorer('la-restore', 'layout_analysis.weights.title', 'weights', E.defaultWeights, () => {
				fillWeights();
				// The access weights may change with the others: the layouts are typed again.
				save();
				analyse();
			});
			// Dynamic labels follow the strings, whenever they land.
			document.addEventListener('i18n:applied', () => {
				applyStrings();
				fillCorpora();
				fillLayouts();
				fillWeights();
				fillIdealLoad();
				fillShortcuts();
				fillForms();
				fillTableOptions();
				fillHeatChoices();
				fillTabs();
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
			// The final text of « My typing » (schema 2) is read the same way.
			if (corpus.tables.final !== undefined) E.prepareNgrams(corpus.tables.final);
			const entry = { id: corpus.id, title: corpus.title || '', host: { tables: corpus.tables } };
			const at = corpora.findIndex((c) => c.id === corpus.id);
			if (at >= 0) {
				corpora.splice(at, 1, entry);
				fillCorpora();
				// A refresh may bring or drop the final text: the « + » boxes follow it.
				fillLayouts();
				if (state.corpus === corpus.id) analyse();
				return;
			}
			corpora.unshift(entry);
			if (corpus.default) state.corpus = corpus.id;
			fillCorpora();
			fillLayouts();
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
			// A new origin or language joins the filters.
			fillTableOptions();
			fillLayouts();
			analyse();
		}

		/**
		 * Calls a listener after each comparison with (results, tables, {keyboard,
		 * layouts: Map id → the compared layout object, tablesOf: result → the
		 * prepared tables it was analysed on (a « + » layout types the keys typed)}),
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
					layouts: state.compared || new Map(),
					tablesOf
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
			showTextMode();
			fillLayouts();
			fillWeights();
			fillIdealLoad();
			fillShortcuts();
			fillForms();
			fillTableOptions();
			fillHeatChoices();
			fillTabs();
			// The filters stay open where the width holds them in a row, and
			// wherever one is set, so a narrowed list never hides its reason.
			const { name, family, origin, language, complete, min, max } = state.table;
			$('la-filters-box').open =
				window.matchMedia(`(min-width: ${FILTERS_OPEN_MIN_PX}px)`).matches ||
				Boolean(name || family || origin || language) ||
				complete !== COMPLETE_CHOICES[0] ||
				min !== null ||
				max !== null;
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
		openLinkLayouts();
	}

	/**
	 * The visitor's own layouts a shared link carries in its fragment (the
	 * framing page's, on the site), compared as personal layouts named « from
	 * a link »; a fragment that does not read is refused in words, whole.
	 */
	function openLinkLayouts() {
		let hash = location.hash;
		try {
			if (window.top !== window && window.top.location.origin === location.origin)
				hash = window.top.location.hash;
		} catch {
			// A frame from another origin: this page's own address.
		}
		const t = INFO.t;
		// The mark becomes part of the layouts' names: wait for the page's strings.
		const ready = () =>
			typeof (window._i18n_strings || {})['layout_analysis.share.from_link'] === 'string';
		const strings = ready()
			? Promise.resolve()
			: new Promise((resolve) => {
					document.addEventListener('i18n:applied', function wait() {
						if (!ready()) return;
						document.removeEventListener('i18n:applied', wait);
						resolve();
					});
				});
		strings
			.then(() => window.LAYOUT_FORMATS.fromLink(hash, E))
			.then(
				(list) => {
					if (list.length === 0) return;
					const mark = t('layout_analysis.share.from_link');
					instance().addLayouts(
						list.map((l) => Object.assign({}, l, { name: `${l.name} (${mark})` }))
					);
				},
				(error) => {
					const refusal = window.LAYOUT_FORMATS.refusalMessage(error);
					const status = document.getElementById('la-share-status');
					status.hidden = false;
					status.textContent = t('layout_analysis.share.link_refused', {
						reason: t(refusal.key, refusal.values)
					});
				}
			);
	}

	if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', autostart);
	else autostart();
})();
